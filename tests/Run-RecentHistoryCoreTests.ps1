[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $project 'TokenRader.Core.psm1') -Force -PassThru
$temp = Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-RecentCore-' + [guid]::NewGuid().ToString('N'))
$previous = $env:TOKEN_RADER_INDEX_DB
$now = [DateTimeOffset]::UtcNow
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert-Recent([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('RECENT HISTORY CORE TEST FAILED: ' + $Message) }
}
function New-RecentToken([DateTimeOffset]$At, [int]$Total, [int]$Percent) {
    return (@{ timestamp=$At.ToString('o'); type='event_msg'; payload=@{
        type='token_count'; info=@{
            total_token_usage=@{input_tokens=$Total;cached_input_tokens=0;output_tokens=0}
            last_token_usage=@{input_tokens=100;cached_input_tokens=0;output_tokens=0}
        }; rate_limits=@{plan_type='pro';limit_id='codex';secondary=@{
            used_percent=$Percent;window_minutes=10080;resets_at=$now.AddDays(2).ToUnixTimeSeconds()
        }}
    }} | ConvertTo-Json -Depth 10 -Compress) + "`n"
}
try {
    $sessions = Join-Path $temp 'sessions'
    [void][IO.Directory]::CreateDirectory($sessions)
    $env:TOKEN_RADER_INDEX_DB = Join-Path $temp 'data/private/index.db'
    $path = Join-Path $sessions 'synthetic-old-session.jsonl'
    $content = '{"type":"session_meta","payload":{"id":"recent-core-synthetic"}}' + "`n" +
        '{"type":"turn_context","payload":{"model":"gpt-5.4"}}' + "`n" +
        (New-RecentToken $now.AddHours(-25) 100 4) +
        (New-RecentToken $now.AddMinutes(-20) 200 5) +
        (New-RecentToken $now.AddMinutes(-10) 300 6)
    [IO.File]::WriteAllText($path, $content, $utf8)
    Initialize-TokenRaderIndexFromNow -SessionsRoot $sessions | Out-Null
    $prepared = Complete-TokenRaderRecentHistory -SessionsRoot $sessions -ProgressState ([hashtable]::Synchronized(@{}))
    Assert-Recent ([bool]$prepared.Completed) 'recent preparation finishes'
    Assert-Recent ([long]$prepared.ProcessedBytes -gt 0 -and -not $prepared.HistoryReused) 'initial preparation reports actual history work'
    $repeatProgress = [hashtable]::Synchronized(@{})
    $repeatPrepared = Complete-TokenRaderRecentHistory -SessionsRoot $sessions -ProgressState $repeatProgress
    Assert-Recent ($repeatPrepared.Completed -and $repeatPrepared.HistoryReused -and [long]$repeatPrepared.ProcessedBytes -eq 0) 'repeat preparation reuses completed history without scanning body'
    Assert-Recent ($repeatProgress.Stage -eq '复用已补齐日志，冻结测量起点') 'repeat preparation identifies reused history'
    $index = Get-TokenRaderIndex
    $coverage = Get-TokenRaderHistoryCoverage -Connection $index.Connection
    Assert-Recent (-not $coverage.HistoryComplete) 'old historical gap remains explicit'
    Assert-Recent $coverage.RecentHistoryComplete 'recent coverage is independently complete'
    Assert-Recent ($coverage.CoverageStart -le $now.AddMinutes(-20)) 'recent snapshot pair no longer clamped to startup'
    Assert-Recent (-not [TokenRaderIndexer]::HasHistoryGapInRange($index.Connection,$now.AddMinutes(-20),$now.AddMinutes(-10))) 'recent pair is covered'
    $cmd = $index.Connection.CreateCommand()
    try {
        $cmd.CommandText = 'SELECT COUNT(*) FROM token_records'
        Assert-Recent ([long]$cmd.ExecuteScalar() -eq 2) 'only last24h token events imported'
    } finally { $cmd.Dispose() }
    $frozen = [long]$prepared.EndOffsets[$path]
    [IO.File]::AppendAllText($path, (New-RecentToken ([DateTimeOffset]::UtcNow) 400 7), $utf8)
    $baseline = CaptureMeasurementBaseline -SessionsRoot $sessions -PreparedHistory $prepared
    Assert-Recent ([long]$baseline.StartOffsets[$path] -eq $frozen) 'baseline does not chase appended EOF'
    Assert-Recent ([long]$baseline.StartOffsets[$path] -lt ([IO.FileInfo]$path).Length) 'later append remains outside prepared boundary'
    Assert-Recent ([double]$baseline.RateLimits.Weekly.UsedPercent -eq 6) 'baseline quota uses same frozen offsets'
    $prices = Get-TokenRaderPrices -PricingPath (Join-Path $project 'pricing.json')
    $evidence = & $module {
        param($Connection,$Ends,$EndWindow,$Prices)
        Get-TokenRaderQuotaWindowEvidence -StartWindow $null -EndWindow $EndWindow -MainLastCountedAt $null `
            -WindowKind Weekly -RateLimitId codex -Connection $Connection -EndOffsets $Ends -Thresholds @{} `
            -PricingDocument $Prices -CancellationToken ([Threading.CancellationToken]::None) -DiagnosticState @{}
    } $index.Connection $prepared.EndOffsets $baseline.RateLimits.Weekly $prices
    Assert-Recent ($null -ne $evidence) 'earlier historical gap must not reject recent quota evidence'
    Write-Output 'RECENT_HISTORY_CORE_TESTS_PASSED'
} finally {
    Close-TokenRaderIndex
    if ($null -eq $previous) { Remove-Item Env:TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue }
    else { $env:TOKEN_RADER_INDEX_DB = $previous }
    $full = [IO.Path]::GetFullPath($temp)
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($full).StartsWith('TokenRader-RecentCore-')) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
