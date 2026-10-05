[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
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
$token = '{"timestamp":"2026-10-05T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}}}'
try {
    [void][IO.Directory]::CreateDirectory($temp)
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
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try { Invoke-Boundary $sessions 3 | Out-Null } catch { $message = $_.Exception.Message }
    $watch.Stop()
    Assert-Boundary ($message -match 'Oversized usage/context line cannot be safely indexed') 'per-file root cause must survive'
    Assert-Boundary ($message -match '5' -and $message -notmatch '25') 'all five failures reported'
    Assert-Boundary ($message -notmatch '3 秒内') 'deterministic failure must not become timeout'
    Assert-Boundary ($watch.Elapsed.TotalSeconds -lt 5) 'deterministic failure must return promptly'
    Assert-Boundary ((Get-RowCount $index.Connection) -eq 0) 'failed batch must not insert partial rows'
    $after = [TokenRaderIndexer]::CaptureFileCursorOffsets($index.Connection)
    foreach ($path in $paths) { Assert-Boundary ($before[$path] -eq $after[$path]) 'failed cursor must stay unchanged' }
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
        try { Invoke-Boundary $sessions 1 | Out-Null } catch { $message = $_.Exception.Message }
        Assert-Boundary ($message -match 'synthetic-lock') 'temporary IO failure must report underlying message'
        Assert-Boundary ((Get-RowCount $index.Connection) -eq 0) 'locked source must not produce rows'
    } finally { $lock.Dispose() }
    Invoke-Boundary $sessions 3 | Out-Null
    Assert-Boundary ((Get-RowCount $index.Connection) -eq 1) 'temporary failure must remain retryable'
    Write-Output 'BOUNDARY_FAILURE_DIAGNOSTICS_TESTS_PASSED'
} finally {
    Close-TokenRaderIndex
    if ($null -eq $previousDb) { Remove-Item Env:TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue }
    else { $env:TOKEN_RADER_INDEX_DB = $previousDb }
    $full = [IO.Path]::GetFullPath($temp)
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($full).StartsWith('TokenRader-BoundaryDiagnostic-')) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
