[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not [string]::IsNullOrWhiteSpace($IndexerDll)) {
    Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
    Add-Type -Path $IndexerDll
}
$module = Import-Module (Join-Path $root 'TokenRader.Core.psm1') -Force -PassThru
$temp = Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-BoundaryDiagnostic-' + [guid]::NewGuid().ToString('N'))
$previousDb = $env:TOKEN_RADER_INDEX_DB
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert-Boundary([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('BOUNDARY DIAGNOSTIC TEST FAILED: ' + $Message) }
}
function Invoke-Boundary([string]$Sessions, [int]$Seconds) {
    & $module { param($Path, $Timeout) Sync-TokenRaderMeasurementBoundary -SessionsRoot $Path -TimeoutSeconds $Timeout } $Sessions $Seconds
}
function Get-RowCount($Connection) {
    $cmd = $Connection.CreateCommand()
    try { $cmd.CommandText = 'SELECT COUNT(*) FROM token_records'; return [long]$cmd.ExecuteScalar() }
    finally { $cmd.Dispose() }
}
function Get-BoundaryScalar($Connection, [string]$Sql) {
    $cmd = $Connection.CreateCommand()
    try { $cmd.CommandText = $Sql; return $cmd.ExecuteScalar() }
    finally { $cmd.Dispose() }
}
$context = '{"timestamp":"2026-10-05T00:00:30Z","type":"turn_context","payload":{"model":"gpt-5.4"}}'
$token = '{"timestamp":"2026-10-05T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}}}'
try {
    [void][IO.Directory]::CreateDirectory($temp)
    # Match the indexer's canonical paths when CI TEMP contains an 8.3 alias.
    $temp = [IO.Path]::GetFullPath((Get-Item -LiteralPath $temp).FullName)
    # Background synchronization uses ordinary Update, not the measurement
    # boundary helper. A late top-level type must still get whole-line proof.
    $sessions = Join-Path $temp 'pure-text-four-files'
    [void][IO.Directory]::CreateDirectory($sessions)
    $env:TOKEN_RADER_INDEX_DB = Join-Path $temp 'data/private/pure-text.db'
    $paths = @(1..4 | ForEach-Object {
        $path = Join-Path $sessions ("synthetic-pure-$_.jsonl")
        [IO.File]::WriteAllText($path, ('{"type":"session_meta","payload":{"id":"synthetic-pure-' + $_ + '"}}' + "`n"), $utf8)
        $path
    })
    $index = Initialize-TokenRaderIndexFromNow -SessionsRoot $sessions
    $pureText = '{"payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"' + ('x' * (1MB + 1)) + '"}]},"type":"response_item"}'
    foreach ($path in $paths) { [IO.File]::AppendAllText($path, $pureText + "`n" + $context + "`n" + $token + "`n", $utf8) }
    $index = Update-TokenRaderIndex -SessionsRoot $sessions -FullReconcile
    Assert-Boundary ($index.SyncComplete -and @($index.LastFailedFiles).Count -eq 0) 'ordinary update accepts four verified oversized text records'
    Assert-Boundary ((Get-RowCount $index.Connection) -eq 4) 'ordinary update imports all four later token events'
    $cmd = $index.Connection.CreateCommand()
    try {
        $cmd.CommandText = 'SELECT SUM(call_input),SUM(call_output) FROM token_records'
        $reader = $cmd.ExecuteReader()
        try {
            Assert-Boundary ($reader.Read() -and [long]$reader[0] -eq 40 -and [long]$reader[1] -eq 4) 'exact four-file numeric totals survive oversized text'
        } finally { $reader.Dispose() }
    } finally { $cmd.Dispose() }
    foreach ($path in $paths) {
        $offsets = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
        Assert-Boundary ($offsets[$path] -eq ([IO.FileInfo]$path).Length) 'successful update reaches exact complete EOF'
    }
    $index = Update-TokenRaderIndex -SessionsRoot $sessions
    Assert-Boundary ($index.SyncComplete -and (Get-RowCount $index.Connection) -eq 4) 'repeated ordinary refresh is idempotent'
    Close-TokenRaderIndex

    $sessions = Join-Path $temp 'oversized'
    [void][IO.Directory]::CreateDirectory($sessions)
    $env:TOKEN_RADER_INDEX_DB = Join-Path $temp 'data/private/oversized.db'
    $paths = @(1..5 | ForEach-Object {
        $path = Join-Path $sessions ("synthetic-$_.jsonl")
        [IO.File]::WriteAllText($path, ('{"type":"session_meta","payload":{"id":"synthetic-' + $_ + '"}}' + "`n"), $utf8)
        $path
    })
    $index = Initialize-TokenRaderIndexFromNow -SessionsRoot $sessions
    $before = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
    $large = $token.Substring(0, $token.Length - 1) + ',"padding":"' + ('x' * (1MB + 1)) + '"}' + "`n"
    foreach ($path in $paths) { [IO.File]::AppendAllText($path, $large, $utf8) }
    $message = ''
    try { Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles $paths | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Boundary ($message -match 'Oversized usage/context line cannot be safely indexed') 'ordinary update exposes deterministic safe cause'
    Assert-Boundary ($message -match '5' -and @($index.LastFailureDiagnostics | Where-Object { $_.Kind -ne 'safety' }).Count -eq 0) 'ordinary update does not mislabel five safety refusals as temporary reads'
    Assert-Boundary (-not $message.Contains($temp) -and -not $message.Contains('padding') -and -not $message.Contains('token_count')) 'background diagnostic never copies source path or JSON'
    Assert-Boundary (-not $index.SyncComplete -and (Get-RowCount $index.Connection) -eq 0) 'ordinary failed update retains incomplete state and rolls back rows'
    $after = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
    foreach ($path in $paths) { Assert-Boundary ($before[$path] -eq $after[$path]) 'ordinary failed update retains each original cursor' }
    $message = ''
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { Invoke-Boundary $sessions 3 | Out-Null } catch { $message = $_.Exception.Message }
    $watch.Stop()
    Assert-Boundary ($message -match 'Oversized usage/context line cannot be safely indexed') 'per-file root cause must survive'
    Assert-Boundary (-not $message.Contains($temp) -and -not $message.Contains('padding')) 'boundary diagnostic does not expose source paths or body'
    Assert-Boundary ($message -match '5' -and $message -notmatch '25') 'all five failures reported'
    Assert-Boundary (-not $message.Contains(('3 ' + [char]0x79D2 + [char]0x5185))) 'deterministic failure must not become timeout'
    Assert-Boundary ($watch.Elapsed.TotalSeconds -lt 5) 'deterministic failure must return promptly'
    Assert-Boundary ((Get-RowCount $index.Connection) -eq 0) 'failed batch must not insert partial rows'
    $after = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
    foreach ($path in $paths) { Assert-Boundary ($before[$path] -eq $after[$path]) 'failed cursor must stay unchanged' }
    Close-TokenRaderIndex

    $sessions = Join-Path $temp 'new-oversized'
    [void][IO.Directory]::CreateDirectory($sessions)
    $env:TOKEN_RADER_INDEX_DB = Join-Path $temp 'data/private/new-oversized.db'
    $path = Join-Path $sessions 'synthetic-new.jsonl'
    [IO.File]::WriteAllText($path, $context + "`n" + $large, $utf8)
    $message = ''
    try { New-TokenRaderIndex -SessionsRoot $sessions | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Boundary ($message -match '1' -and $message -match 'Oversized usage/context line cannot be safely indexed') 'initial full import exposes the same safe cause'
    Assert-Boundary (-not $message.Contains($temp) -and -not $message.Contains('padding')) 'initial import diagnostic excludes source data'
    Close-TokenRaderIndex

    $safeUnknown = & $module {
        Get-TokenRaderSafeIndexFailure -Exception ([InvalidOperationException]::new('synthetic-private-path and {"text":"synthetic private body"}'))
    }
    Assert-Boundary ($safeUnknown.Kind -eq 'unknown' -and $safeUnknown.Message.Contains('InvalidOperationException')) 'unknown exception preserves safe type'
    Assert-Boundary ($safeUnknown.Message -match 'HResult=-?[0-9]+') 'unknown exception retains numeric diagnostic code'
    Assert-Boundary (-not $safeUnknown.Message.Contains('synthetic-private') -and -not $safeUnknown.Message.Contains('text')) 'unknown exception does not copy arbitrary detail'
    $safeSqlite = & $module {
        Get-TokenRaderSafeIndexFailure -Exception ([System.Data.SQLite.SQLiteException]::new([System.Data.SQLite.SQLiteErrorCode]::Busy, 'synthetic private schema/body detail'))
    }
    Assert-Boundary ($safeSqlite.Kind -eq 'database' -and $safeSqlite.Message -match 'ResultCode=5' -and $safeSqlite.Message -match 'HResult=-?[0-9]+') 'SQLite failure exposes safe busy result code'
    Assert-Boundary (-not $safeSqlite.Message.Contains('synthetic private')) 'SQLite message does not copy arbitrary source detail'
    $legacySummary = & $module {
        Get-TokenRaderIndexFailureSummary -Index ([pscustomobject]@{ LastFailedFiles = @('synthetic'); LastFailureMessages = @('synthetic private legacy path/body') }) -Operation 'sync'
    }
    Assert-Boundary ($legacySummary -match '1' -and $legacySummary.StartsWith('sync')) 'summary handles legacy index without diagnostic property under strict mode'
    Assert-Boundary (-not $legacySummary.Contains('synthetic private')) 'legacy fallback does not display raw exception detail'

    # Replacement must not delete valid indexed evidence before the new source
    # has passed strict parsing. All files and rewrites here are synthetic.
    $sessions = Join-Path $temp 'replacement'
    [void][IO.Directory]::CreateDirectory($sessions)
    $env:TOKEN_RADER_INDEX_DB = Join-Path $temp 'data/private/replacement.db'
    $path = Join-Path $sessions 'synthetic-replacement.jsonl'
    [IO.File]::WriteAllText($path, $pureText + "`n" + $context + "`n" + $token + "`n" + (' ' * 2048) + "`n", $utf8)
    $index = New-TokenRaderIndex -SessionsRoot $sessions
    Assert-Boundary ((Get-RowCount $index.Connection) -eq 1) 'valid original source is indexed before replacement'
    $before = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
    $oldLength = ([IO.FileInfo]$path).Length
    [IO.File]::WriteAllText($path, $context + "`n" + $large, $utf8)
    Assert-Boundary (([IO.FileInfo]$path).Length -lt $oldLength) 'unsafe replacement fixture triggers replacement branch'
    $message = ''
    try { Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($path) | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Boundary ($message -match 'Oversized usage/context line cannot be safely indexed') 'unsafe replacement is refused explicitly'
    $after = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
    Assert-Boundary ((Get-RowCount $index.Connection) -eq 1 -and $before[$path] -eq $after[$path]) 'unsafe replacement preserves original records and cursor atomically'
    $cmd = $index.Connection.CreateCommand()
    try {
        $cmd.CommandText = 'SELECT SUM(call_input) FROM token_records'
        Assert-Boundary ([long]$cmd.ExecuteScalar() -eq 10) 'unsafe replacement retains original numeric evidence'
    } finally { $cmd.Dispose() }
    $replacementToken = $token.Replace('"input_tokens":10', '"input_tokens":23').Replace('"output_tokens":1', '"output_tokens":2')
    [IO.File]::WriteAllText($path, $context + "`n" + $replacementToken + "`n", $utf8)
    $index = Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($path)
    Assert-Boundary ($index.SyncComplete -and (Get-RowCount $index.Connection) -eq 1) 'later valid replacement commits once'
    $cmd = $index.Connection.CreateCommand()
    try {
        $cmd.CommandText = 'SELECT SUM(call_input) FROM token_records'
        Assert-Boundary ([long]$cmd.ExecuteScalar() -eq 23) 'valid replacement replaces rather than mixes numeric evidence'
    } finally { $cmd.Dispose() }
    $before = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
    Assert-Boundary ($before[$path] -eq ([IO.FileInfo]$path).Length) 'valid replacement advances exact frozen cursor'
    [IO.File]::WriteAllText($path, '{"type":"event_msg"', $utf8)
    $message = ''
    try { Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($path) | Out-Null } catch { $message = $_.Exception.Message }
    $after = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
    Assert-Boundary ($message.Length -gt 0 -and (Get-RowCount $index.Connection) -eq 1 -and $before[$path] -eq $after[$path]) 'unfinished nonempty replacement cannot erase old evidence'
    Assert-Boundary (@($index.LastFailureDiagnostics).Count -eq 1 -and $index.LastFailureDiagnostics[0].Kind -eq 'pending') 'unfinished replacement is temporary pending, not permanent safety rejection'
    [IO.File]::WriteAllText($path, '', $utf8)
    $index = Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($path)
    $after = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
    Assert-Boundary ($index.SyncComplete -and (Get-RowCount $index.Connection) -eq 0 -and $after[$path] -eq 0) 'empty replacement commits deletion and zero cursor together'
    Close-TokenRaderIndex

    $sessions = Join-Path $temp 'root-replacement'
    [void][IO.Directory]::CreateDirectory($sessions)
    $env:TOKEN_RADER_INDEX_DB = Join-Path $temp 'data/private/root-replacement.db'
    $parentPath = Join-Path $sessions 'synthetic-root-parent.jsonl'
    $childPath = Join-Path $sessions 'synthetic-root-child.jsonl'
    $otherPath = Join-Path $sessions 'synthetic-root-other.jsonl'
    $oldMeta = '{"type":"session_meta","payload":{"id":"synthetic-root-parent","parent_thread_id":"synthetic-old-root"}}'
    $newMeta = $oldMeta.Replace('synthetic-old-root', 'synthetic-new-root')
    $finalMeta = $oldMeta.Replace('synthetic-old-root', 'synthetic-final-root')
    $childMeta = '{"type":"session_meta","payload":{"id":"synthetic-root-child","parent_thread_id":"synthetic-root-parent"}}'
    $otherMeta = '{"type":"session_meta","payload":{"id":"synthetic-root-other"}}'
    $otherValid = $otherMeta + "`n" + $context + "`n" + $token + "`n"
    [IO.File]::WriteAllText($parentPath, $oldMeta + "`n" + $pureText + "`n" + $context + "`n" + $token + "`n" + (' ' * 2048) + "`n", $utf8)
    [IO.File]::WriteAllText($childPath, $childMeta + "`n" + $context + "`n" + $token + "`n", $utf8)
    [IO.File]::WriteAllText($otherPath, $otherValid, $utf8)
    $index = New-TokenRaderIndex -SessionsRoot $sessions
    $rootRowsSql = "SELECT COUNT(*) FROM token_records WHERE session_id IN ('synthetic-root-parent','synthetic-root-child') AND root_session_id='synthetic-old-root'"
    $rootMetadataSql = "SELECT COUNT(*) FROM file_metadata WHERE session_id IN ('synthetic-root-parent','synthetic-root-child') AND root_session_id='synthetic-old-root'"
    Assert-Boundary ((Get-BoundaryScalar $index.Connection $rootRowsSql) -eq 2 -and (Get-BoundaryScalar $index.Connection $rootMetadataSql) -eq 2) 'original parent and child share old root'
    [IO.File]::WriteAllText($parentPath, $newMeta + "`n" + $context + "`n" + $large, $utf8)
    $message = ''
    try { Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($parentPath) | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Boundary ($message -match 'Oversized usage/context' -and $index.RootBackfilledRows -eq 0) 'refused changed-parent source cannot run root backfill'
    Assert-Boundary ((Get-BoundaryScalar $index.Connection $rootRowsSql) -eq 2 -and (Get-BoundaryScalar $index.Connection $rootMetadataSql) -eq 2) 'refused replacement preserves token and metadata roots'
    [IO.File]::WriteAllText($parentPath, $newMeta + "`n" + $context + "`n" + $token + "`n" + (' ' * 2048) + "`n", $utf8)
    $index = Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($parentPath)
    Assert-Boundary ($index.SyncComplete -and $index.RootBackfilledRows -gt 0) 'valid retry completes deferred descendant root backfill'
    Assert-Boundary ((Get-BoundaryScalar $index.Connection ($rootRowsSql.Replace('synthetic-old-root', 'synthetic-new-root'))) -eq 2) 'successful retry updates both parent and child roots'

    # A different failure can defer ancestry after the changed parent itself
    # committed. The pending marker must heal descendants on that file retry.
    [IO.File]::WriteAllText($parentPath, $finalMeta + "`n" + $context + "`n" + $token + "`n", $utf8)
    [IO.File]::AppendAllText($otherPath, $large, $utf8)
    $message = ''
    try { Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($parentPath, $otherPath) | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Boundary ($message -match 'Oversized usage/context' -and $index.RootBackfilledRows -eq 0) 'unrelated failure defers descendant root rewrite'
    Assert-Boundary ((Get-BoundaryScalar $index.Connection "SELECT root_session_id FROM token_records WHERE session_id='synthetic-root-child'") -eq 'synthetic-new-root') 'deferred child retains previously committed root'
    Assert-Boundary ([TokenRaderIndexer]::GetSetting($index.Connection, 'pending_root_backfill') -eq '1') 'deferred root work persists a retry marker'
    [IO.File]::WriteAllText($otherPath, $otherValid, $utf8)
    $index = Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($otherPath)
    Assert-Boundary ($index.SyncComplete -and $index.RootBackfilledRows -gt 0) 'unrelated file retry re-evaluates full ancestry tree'
    Assert-Boundary ((Get-BoundaryScalar $index.Connection ($rootRowsSql.Replace('synthetic-old-root', 'synthetic-final-root'))) -eq 2) 'pending retry heals descendant root from accepted parent metadata'
    Assert-Boundary ([TokenRaderIndexer]::GetSetting($index.Connection, 'pending_root_backfill') -eq '0') 'successful ancestry pass clears pending marker'

    # The parent import can commit before the descendant backfill itself
    # fails. A retry sees an unchanged parent, so it must use persisted intent.
    $retryMeta = $oldMeta.Replace('synthetic-old-root', 'synthetic-db-root')
    [IO.File]::WriteAllText($parentPath, $retryMeta + "`n" + $context + "`n" + $token + "`n", $utf8)
    $cmd = $index.Connection.CreateCommand()
    try {
        $cmd.CommandText = "CREATE TRIGGER fail_root_backfill BEFORE UPDATE OF root_session_id ON token_records WHEN OLD.session_id='synthetic-root-child' BEGIN SELECT RAISE(ABORT,'synthetic root backfill failure'); END"
        [void]$cmd.ExecuteNonQuery()
    } finally { $cmd.Dispose() }
    $message = ''
    try { Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($parentPath) | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Boundary ($message -match 'synthetic root backfill failure') 'post-import descendant backfill failure propagates'
    Assert-Boundary ((Get-BoundaryScalar $index.Connection "SELECT root_session_id FROM token_records WHERE session_id='synthetic-root-parent'") -eq 'synthetic-db-root') 'parent replacement committed before backfill failure'
    Assert-Boundary ((Get-BoundaryScalar $index.Connection "SELECT parsed_offset FROM file_metadata WHERE session_id='synthetic-root-parent'") -eq ([IO.FileInfo]$parentPath).Length) 'failed backfill leaves parent source fully committed and unchanged for retry'
    Assert-Boundary ((Get-BoundaryScalar $index.Connection "SELECT root_session_id FROM token_records WHERE session_id='synthetic-root-child'") -eq 'synthetic-final-root' -and
        (Get-BoundaryScalar $index.Connection "SELECT root_session_id FROM file_metadata WHERE session_id='synthetic-root-child'") -eq 'synthetic-final-root') 'failed backfill rolls back both descendant rows and catalog roots'
    Assert-Boundary ([TokenRaderIndexer]::GetSetting($index.Connection, 'pending_root_backfill') -eq '1') 'backfill exception preserves intent persisted before parent import'
    $cmd = $index.Connection.CreateCommand()
    try { $cmd.CommandText = 'DROP TRIGGER fail_root_backfill'; [void]$cmd.ExecuteNonQuery() }
    finally { $cmd.Dispose() }
    $index = Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($parentPath)
    Assert-Boundary ($index.SyncComplete -and $index.LastImportedFiles -eq 0 -and $index.RootBackfilledRows -gt 0) 'unchanged-parent retry completes persisted descendant work without reimport'
    Assert-Boundary ((Get-BoundaryScalar $index.Connection ($rootRowsSql.Replace('synthetic-old-root', 'synthetic-db-root'))) -eq 2 -and
        (Get-BoundaryScalar $index.Connection ($rootMetadataSql.Replace('synthetic-old-root', 'synthetic-db-root'))) -eq 2) 'retry heals both parent and descendant token and catalog roots'
    Assert-Boundary ([TokenRaderIndexer]::GetSetting($index.Connection, 'pending_root_backfill') -eq '0') 'successful backfill retry clears persisted intent'
    Close-TokenRaderIndex

    $sessions = Join-Path $temp 'locked'
    [void][IO.Directory]::CreateDirectory($sessions)
    $env:TOKEN_RADER_INDEX_DB = Join-Path $temp 'data/private/locked.db'
    $path = Join-Path $sessions 'synthetic-lock.jsonl'
    [IO.File]::WriteAllText($path, ('{"type":"session_meta","payload":{"id":"synthetic-lock"}}' + "`n"), $utf8)
    $index = Initialize-TokenRaderIndexFromNow -SessionsRoot $sessions
    [IO.File]::AppendAllText($path, $token + "`n", $utf8)
    $lock = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $message = ''
        try { Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($path) | Out-Null } catch { $message = $_.Exception.Message }
        Assert-Boundary ($message -match 'IOException' -and @($index.LastFailureDiagnostics | Where-Object { $_.Kind -ne 'io' }).Count -eq 0) 'ordinary update distinguishes genuine temporary I/O'
        Assert-Boundary ($message -match 'HResult=-?[0-9]+') 'temporary I/O includes safe numeric diagnostic code'
        Assert-Boundary (-not $message.Contains($temp)) 'temporary I/O diagnostic omits private path'
        $message = ''
        try { Invoke-Boundary $sessions 1 | Out-Null } catch { $message = $_.Exception.Message }
        Assert-Boundary ($message -match 'IOException' -and $message -match 'HResult=-?[0-9]+') 'temporary IO boundary failure preserves safe category and code'
        Assert-Boundary (-not $message.Contains($temp) -and -not $message.Contains('synthetic-lock')) 'temporary IO boundary failure excludes source path'
        Assert-Boundary ((Get-RowCount $index.Connection) -eq 0) 'locked source must not produce rows'
    } finally { $lock.Dispose() }
    $index = Update-TokenRaderIndex -SessionsRoot $sessions -CandidateFiles @($path)
    Assert-Boundary ($index.SyncComplete -and (Get-RowCount $index.Connection) -eq 1) 'ordinary update recovers after temporary lock release'
    Invoke-Boundary $sessions 3 | Out-Null
    Assert-Boundary ((Get-RowCount $index.Connection) -eq 1) 'temporary failure must remain retryable'
    Write-Output 'BOUNDARY_FAILURE_DIAGNOSTICS_TESTS_PASSED'
} finally {
    Close-TokenRaderIndex
    if ($null -eq $previousDb) { Remove-Item Env:TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue }
    else { $env:TOKEN_RADER_INDEX_DB = $previousDb }
    $full = [IO.Path]::GetFullPath($temp)
    $base = [IO.Path]::GetFullPath((Get-Item -LiteralPath ([IO.Path]::GetTempPath())).FullName).TrimEnd('\') + '\'
    if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($full).StartsWith('TokenRader-BoundaryDiagnostic-')) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
