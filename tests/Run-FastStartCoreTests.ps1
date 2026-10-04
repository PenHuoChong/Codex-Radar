[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-FastStartTest {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('FAST START CORE TEST FAILED: ' + $Message) }
}

function New-FastStartTokenRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][Int64]$TotalInput,
        [Parameter(Mandatory = $true)][Int64]$CallInput,
        [double]$UsedPercent = -1,
        [Int64]$ResetUnixSeconds = 0
    )
    $total = [ordered]@{
        input_tokens = $TotalInput
        cached_input_tokens = 0
        output_tokens = 10
        reasoning_output_tokens = 0
        total_tokens = $TotalInput + 10
    }
    $last = [ordered]@{
        input_tokens = $CallInput
        cached_input_tokens = 0
        output_tokens = 10
        reasoning_output_tokens = 0
        total_tokens = $CallInput + 10
    }
    $payload = [ordered]@{
        type = 'token_count'
        info = [ordered]@{ total_token_usage = $total; last_token_usage = $last; model_context_window = 1050000 }
    }
    if ($UsedPercent -ge 0) {
        $payload['rate_limits'] = [ordered]@{
            plan_type = 'pro'
            limit_id = 'codex'
            primary = [ordered]@{
                used_percent = $UsedPercent
                window_minutes = 300
                resets_at = $ResetUnixSeconds
            }
        }
    }
    [ordered]@{ timestamp = $Timestamp; type = 'event_msg'; payload = $payload }
}

function ConvertTo-FastStartLine {
    param([Parameter(Mandatory = $true)]$Record)
    return ($Record | ConvertTo-Json -Depth 12 -Compress)
}

function Write-FastStartHistoryFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$PaddingLine,
        [int]$PaddingCopies = 48
    )
    $stamp = '2026-09-01T00:00:00Z'
    $records = @(
        [ordered]@{ timestamp = $stamp; type = 'session_meta'; payload = [ordered]@{ id = $SessionId; cwd = 'C:\synthetic\fast-start' } },
        [ordered]@{ timestamp = $stamp; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-sol'; service_tier = 'default' } },
        (New-FastStartTokenRecord -Timestamp '2026-09-01T00:00:01Z' -TotalInput 1000 -CallInput 1000)
    )
    $lines = @($records | ForEach-Object { ConvertTo-FastStartLine $_ })
    for ($i = 0; $i -lt $PaddingCopies; $i++) { $lines += $PaddingLine }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    return [Int64]([IO.FileInfo]::new($Path).Length)
}

function Append-FastStartRecord {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Record)
    [IO.File]::AppendAllText($Path, ((ConvertTo-FastStartLine $Record) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Get-FastStartRows {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Sql,
        [hashtable]$Parameters = @{}
    )
    $table = [Data.DataTable]::new()
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Sql
        foreach ($key in $Parameters.Keys) { [void]$command.Parameters.AddWithValue($key, $Parameters[$key]) }
        $adapter = [System.Data.SQLite.SQLiteDataAdapter]::new($command)
        try { [void]$adapter.Fill($table) } finally { $adapter.Dispose() }
    } finally { $command.Dispose() }
    return ,$table
}

function Get-FastStartScalar {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Sql,
        [hashtable]$Parameters = @{}
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Sql
        foreach ($key in $Parameters.Keys) { [void]$command.Parameters.AddWithValue($key, $Parameters[$key]) }
        return $command.ExecuteScalar()
    } finally { $command.Dispose() }
}

function Get-FastStartLiveRowSignature {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string[]]$OldPaths,
        [Parameter(Mandatory = $true)][hashtable]$InitialLengths,
        [Parameter(Mandatory = $true)][string]$NewPath
    )
    $conditions = New-Object System.Collections.ArrayList
    $parameters = @{}
    $i = 0
    foreach ($path in $OldPaths) {
        $name = '@path' + $i
        $lengthName = '@length' + $i
        [void]$conditions.Add(('(source_path={0} AND source_offset_end>{1})' -f $name, $lengthName))
        $parameters[$name] = $path
        $parameters[$lengthName] = [Int64]$InitialLengths[$path]
        $i++
    }
    $parameters['@newPath'] = $NewPath
    [void]$conditions.Add('(source_path=@newPath)')
    $sql = 'SELECT session_id,source_path,source_offset_end,timestamp,call_input FROM token_records WHERE ' +
        ($conditions -join ' OR ') + ' ORDER BY source_path,source_offset_end'
    $rows = Get-FastStartRows -Connection $Connection -Sql $sql -Parameters $parameters
    $parts = foreach ($row in @($rows.Rows)) {
        '{0}|{1}|{2}|{3}|{4}' -f [string]$row['session_id'], [string]$row['source_path'],
            [Int64]$row['source_offset_end'], [string]$row['timestamp'], [Int64]$row['call_input']
    }
    return (@($parts) -join "`n")
}

function Get-FastStartCursorSignature {
    param([Parameter(Mandatory = $true)]$Connection)
    $rows = Get-FastStartRows -Connection $Connection -Sql 'SELECT path,parsed_offset FROM file_metadata ORDER BY path'
    $parts = foreach ($row in @($rows.Rows)) { '{0}|{1}' -f [string]$row['path'], [Int64]$row['parsed_offset'] }
    return (@($parts) -join "`n")
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('token-rader-fast-start-' + [Guid]::NewGuid().ToString('N'))
$fastSessions = Join-Path $tempRoot 'fast\sessions'
$fastDb = Join-Path $tempRoot 'fast\data\private\index\index.db'
$preserveSessions = Join-Path $tempRoot 'preserve\sessions'
$preserveDb = Join-Path $tempRoot 'preserve\data\private\index\index.db'
$previousDbOverride = $env:TOKEN_RADER_INDEX_DB
[void][IO.Directory]::CreateDirectory($fastSessions)
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $fastDb))
[void][IO.Directory]::CreateDirectory($preserveSessions)
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $preserveDb))

$module = $null
try {
    $env:TOKEN_RADER_INDEX_DB = $fastDb
    $module = Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force -PassThru
    $padding = ConvertTo-FastStartLine ([ordered]@{
        timestamp = '2026-09-01T00:00:02Z'
        type = 'synthetic_padding'
        payload = [ordered]@{ value = ('x' * 1800) }
    })
    $sessionA = '30000000-0000-0000-0000-000000000001'
    $sessionB = '30000000-0000-0000-0000-000000000002'
    $pathA = Join-Path $fastSessions ('rollout-' + $sessionA + '.jsonl')
    $pathB = Join-Path $fastSessions ('rollout-' + $sessionB + '.jsonl')
    $initialLengths = @{}
    $initialLengths[$pathA] = Write-FastStartHistoryFile -Path $pathA -SessionId $sessionA -PaddingLine $padding
    $initialLengths[$pathB] = Write-FastStartHistoryFile -Path $pathB -SessionId $sessionB -PaddingLine $padding

    $initialized = Initialize-TokenRaderIndexFromNow -SessionsRoot $fastSessions
    $index = Get-TokenRaderIndex
    Assert-FastStartTest ($initialized.HistoryComplete -eq $false) 'fresh startup marked skipped historical data complete'
    Assert-FastStartTest ($null -ne $initialized.CoverageStart) 'startup did not expose the coverage start boundary'
    Assert-FastStartTest ($initialized.HistoryRemainingFiles -ge 2) 'startup did not report the historical backlog'
    $metadata = Get-FastStartRows -Connection $index.Connection -Sql 'SELECT path,length,parsed_offset FROM file_metadata ORDER BY path'
    Assert-FastStartTest ($metadata.Rows.Count -eq 2) 'startup did not create cursors for every existing synthetic file'
    foreach ($path in @($pathA, $pathB)) {
        $fileRow = @($metadata.Rows | Where-Object { [string]::Equals([string]$_.Item('path'), $path, [StringComparison]::OrdinalIgnoreCase) })
        Assert-FastStartTest ($fileRow.Count -eq 1) ('startup did not register file cursor: ' + $path)
        Assert-FastStartTest ([Int64]$fileRow[0]['parsed_offset'] -eq [Int64]$initialLengths[$path]) ('startup did not freeze EOF: ' + $path)
        $historicalRows = Get-FastStartScalar -Connection $index.Connection -Sql 'SELECT COUNT(*) FROM token_records WHERE source_path=@path AND source_offset_end<=@end' -Parameters @{ '@path' = $path; '@end' = [Int64]$initialLengths[$path] }
        Assert-FastStartTest ([Int64]$historicalRows -eq 0) ('startup imported historical token rows: ' + $path)
    }

    # Appends to every frozen file and a brand-new file remain live index work.
    $reset = [DateTimeOffset]::UtcNow.AddDays(1).ToUnixTimeSeconds()
    Append-FastStartRecord -Path $pathA -Record (New-FastStartTokenRecord -Timestamp '2026-09-02T00:00:01Z' -TotalInput 2000 -CallInput 1000)
    Append-FastStartRecord -Path $pathA -Record (New-FastStartTokenRecord -Timestamp '2026-09-02T00:00:02Z' -TotalInput 3000 -CallInput 1000 -UsedPercent 10 -ResetUnixSeconds $reset)
    Append-FastStartRecord -Path $pathA -Record (New-FastStartTokenRecord -Timestamp '2026-09-03T00:00:01Z' -TotalInput 4000 -CallInput 1000 -UsedPercent 11 -ResetUnixSeconds $reset)
    Append-FastStartRecord -Path $pathB -Record (New-FastStartTokenRecord -Timestamp '2026-09-02T00:00:01Z' -TotalInput 2000 -CallInput 1000)
    $sessionC = '30000000-0000-0000-0000-000000000003'
    $newPath = Join-Path $fastSessions ('rollout-' + $sessionC + '.jsonl')
    $newLines = @(
        [ordered]@{ timestamp = '2026-10-05T00:00:00Z'; type = 'session_meta'; payload = [ordered]@{ id = $sessionC; cwd = 'C:\synthetic\fast-start' } },
        [ordered]@{ timestamp = '2026-10-05T00:00:00Z'; type = 'turn_context'; payload = [ordered]@{ model = 'gpt-5.6-sol'; service_tier = 'default' } },
        (New-FastStartTokenRecord -Timestamp '2026-10-05T00:00:01Z' -TotalInput 700 -CallInput 700)
    )
    [IO.File]::WriteAllText($newPath, ((@($newLines | ForEach-Object { ConvertTo-FastStartLine $_ }) -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    $sync = Update-TokenRaderIndex -SessionsRoot $fastSessions -FullReconcile -AllowIncomplete
    Assert-FastStartTest ($sync.SyncComplete) 'ordinary synchronization failed while historical coverage was partial'
    Assert-FastStartTest ([Int64]$sync.LastImportedRecords -eq 5) 'post-start appends/new file were not all indexed exactly once'
    $index = Get-TokenRaderIndex
    $coverage = Get-TokenRaderHistoryCoverage -Connection $index.Connection
    Assert-FastStartTest (-not $coverage.HistoryComplete -and $coverage.RemainingFiles -ge 2) 'ordinary synchronization erased the partial-history warning'
    $totalRows = Get-FastStartScalar -Connection $index.Connection -Sql 'SELECT COUNT(*) FROM token_records'
    Assert-FastStartTest ([Int64]$totalRows -eq 5) 'historical backlog leaked into startup rows or live additions were lost'

    # Even if a stale pair is present in the indexed suffix, quota calibration
    # must refuse evidence older than the frozen coverage boundary.
    $staleRows = Get-FastStartRows -Connection $index.Connection -Sql 'SELECT COUNT(*) AS n,MIN(timestamp) AS first_at FROM token_records WHERE five_hour_used IS NOT NULL'
    Assert-FastStartTest ([Int64]$staleRows.Rows[0]['n'] -eq 2) 'synthetic stale quota pair was not indexed for the coverage-gate test'
    $quotaStart = [pscustomobject]@{
        ObservedAt = [DateTimeOffset]::Parse('2026-09-02T00:00:02Z')
        UsedPercent = 10.0
        WindowMinutes = 300
        ResetsAt = [DateTimeOffset]::FromUnixTimeSeconds($reset)
        PlanType = 'pro'
        LimitId = 'codex'
    }
    $quotaEnd = [pscustomobject]@{
        ObservedAt = [DateTimeOffset]::UtcNow
        UsedPercent = 12.0
        WindowMinutes = 300
        ResetsAt = [DateTimeOffset]::FromUnixTimeSeconds($reset)
        PlanType = 'pro'
        LimitId = 'codex'
    }
    $prices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
    $prices | Add-Member -NotePropertyName ManualServiceTiers -NotePropertyValue @{'gpt-5.6-sol' = 'default'} -Force
    $offsetBaseline = CaptureMeasurementBaseline -SessionsRoot $fastSessions -PricingDocument $prices
    $quotaDiagnostics = @{}
    $quotaProbe = {
        param($connection, $ends, $start, $end, $priceDocument, $diagnostics)
        Get-TokenRaderQuotaWindowEvidence -StartWindow $start -EndWindow $end -WindowKind FiveHour `
            -Connection $connection -EndOffsets $ends -Thresholds @{'gpt-5.6-sol' = 0} `
            -PricingDocument $priceDocument -CancellationToken ([Threading.CancellationToken]::None) `
            -Cache @{} -DiagnosticState $diagnostics
    }
    $quotaEvidence = & $module $quotaProbe $index.Connection $offsetBaseline.StartOffsets $quotaStart $quotaEnd $prices $quotaDiagnostics
    Assert-FastStartTest ($null -eq $quotaEvidence) 'quota evidence crossed an incomplete history gap using a stale pair'
    Assert-FastStartTest (-not [string]::IsNullOrWhiteSpace([string]$quotaDiagnostics.ReasonCode) -and $quotaDiagnostics.ReasonCode -ne 'ok') 'stale-pair refusal did not retain a concrete diagnostic'

    # A measurement begun after fast startup is total-only for prior bytes.
    $measurementBaseline = CaptureMeasurementBaseline -SessionsRoot $fastSessions -PricingDocument $prices
    Append-FastStartRecord -Path $pathA -Record (New-FastStartTokenRecord -Timestamp ([DateTimeOffset]::UtcNow.ToString('o')) -TotalInput 5000 -CallInput 500)
    $measurement = Get-TokenRaderIndexedIntervalResult -Baseline $measurementBaseline -PricingDocument $prices `
        -SessionsRoot $fastSessions -ScanRateLimits $false
    Assert-FastStartTest ([Int64]$measurement.CountedEvents -eq 1) 'total-only measurement billed skipped historical backlog'
    Assert-FastStartTest ([Int64]$measurement.Usage.Total -eq 510) 'total-only measurement did not retain only the post-start call'

    $index = Get-TokenRaderIndex
    $liveBeforeBackfill = Get-FastStartLiveRowSignature -Connection $index.Connection -OldPaths @($pathA, $pathB) -InitialLengths $initialLengths -NewPath $newPath
    $cursorsBeforeBackfill = Get-FastStartCursorSignature -Connection $index.Connection
    $firstBatch = Invoke-TokenRaderHistoryBackfillBatch -SessionsRoot $fastSessions -MaxBytes 65536 -MaxMilliseconds 10000
    Assert-FastStartTest ($firstBatch.ProcessedBytes -gt 0) 'first bounded history batch made no progress'
    Assert-FastStartTest (-not $firstBatch.Completed) 'small first batch unexpectedly completed the synthetic backlog'
    [Int64]$historyImported = [Int64]$firstBatch.ImportedRecords

    $cancelSource = [Threading.CancellationTokenSource]::new()
    $cancelSource.Cancel()
    $cancelled = $false
    try {
        Invoke-TokenRaderHistoryBackfillBatch -SessionsRoot $fastSessions -MaxBytes 65536 -MaxMilliseconds 10000 `
            -CancellationToken $cancelSource.Token | Out-Null
    } catch [OperationCanceledException] { $cancelled = $true }
    finally { $cancelSource.Dispose() }
    Assert-FastStartTest $cancelled 'pre-cancelled historical batch did not cancel'
    $afterCancel = Get-TokenRaderHistoryCoverage -Connection $index.Connection
    Assert-FastStartTest (-not $afterCancel.HistoryComplete) 'cancellation incorrectly marked history complete'

    $batch = $firstBatch
    $batchCount = 1
    while (-not $batch.Completed -and $batchCount -lt 100) {
        $batch = Invoke-TokenRaderHistoryBackfillBatch -SessionsRoot $fastSessions -MaxBytes 65536 -MaxMilliseconds 10000
        $historyImported += [Int64]$batch.ImportedRecords
        $batchCount++
    }
    Assert-FastStartTest ($batch.Completed) 'resumed historical batches did not complete within the synthetic bound'
    Assert-FastStartTest ($historyImported -eq 2) 'historical backfill did not import exactly the two skipped original calls'
    $finalIndex = Get-TokenRaderIndex
    $liveAfterBackfill = Get-FastStartLiveRowSignature -Connection $finalIndex.Connection -OldPaths @($pathA, $pathB) -InitialLengths $initialLengths -NewPath $newPath
    $cursorsAfterBackfill = Get-FastStartCursorSignature -Connection $finalIndex.Connection
    Assert-FastStartTest ($liveAfterBackfill -ceq $liveBeforeBackfill) 'historical batches altered already-indexed live calls'
    Assert-FastStartTest ($cursorsAfterBackfill -ceq $cursorsBeforeBackfill) 'historical batches changed ordinary live file cursors'
    $completeCoverage = Get-TokenRaderHistoryCoverage -Connection $finalIndex.Connection
    Assert-FastStartTest ($completeCoverage.HistoryComplete -and $completeCoverage.RemainingFiles -eq 0) 'completed batches left a false history gap'

    $repeat = Invoke-TokenRaderHistoryBackfillBatch -SessionsRoot $fastSessions -MaxBytes 65536 -MaxMilliseconds 10000
    Assert-FastStartTest ($repeat.Completed -and [Int64]$repeat.ImportedRecords -eq 0) 'completed history backfill was not idempotent'
    $repeatedRows = Get-FastStartScalar -Connection $finalIndex.Connection -Sql 'SELECT COUNT(*) FROM token_records'
    Assert-FastStartTest ([Int64]$repeatedRows -eq 8) 'repeat backfill duplicated or lost indexed rows'

    # Re-initializing an already indexed synthetic catalog must preserve rows.
    & $module { Close-TokenRaderIndex }
    $env:TOKEN_RADER_INDEX_DB = $preserveDb
    $preserveId = '30000000-0000-0000-0000-000000000004'
    $preservePath = Join-Path $preserveSessions ('rollout-' + $preserveId + '.jsonl')
    [void](Write-FastStartHistoryFile -Path $preservePath -SessionId $preserveId -PaddingLine $padding -PaddingCopies 0)
    $fullIndex = New-TokenRaderIndex -SessionsRoot $preserveSessions
    $rowsBeforeReinitialize = Get-FastStartScalar -Connection $fullIndex.Connection -Sql 'SELECT COUNT(*) FROM token_records'
    Assert-FastStartTest ([Int64]$rowsBeforeReinitialize -eq 1) 'preservation fixture was not initially indexed'
    $reinitialized = Initialize-TokenRaderIndexFromNow -SessionsRoot $preserveSessions
    $preservedIndex = Get-TokenRaderIndex
    $rowsAfterReinitialize = Get-FastStartScalar -Connection $preservedIndex.Connection -Sql 'SELECT COUNT(*) FROM token_records'
    Assert-FastStartTest ([Int64]$rowsAfterReinitialize -eq [Int64]$rowsBeforeReinitialize) 'fast-start initialization removed existing indexed rows'

    Write-Output 'FAST_START_CORE_TESTS_PASSED'
} finally {
    if ($null -ne $module) { & $module { Close-TokenRaderIndex } }
    if ($null -eq $previousDbOverride) { Remove-Item Env:\TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue }
    else { $env:TOKEN_RADER_INDEX_DB = $previousDbOverride }
    if (Test-Path -LiteralPath $tempRoot) {
        $resolved = [IO.Path]::GetFullPath($tempRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup target' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
