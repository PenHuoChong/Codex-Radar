[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'TokenRader.Explorer.psm1') -Force
$temp=Join-Path ([IO.Path]::GetTempPath()) ('radar-explorer-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
function Assert-Backfill([bool]$Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
try {
    $sessions=Join-Path $temp 'sessions'; [void][IO.Directory]::CreateDirectory($sessions)
    $paths=[pscustomobject]@{MainIndexPath=(Join-Path $temp 'main.db');ExplorerIndexPath=(Join-Path $temp 'explorer/index.db');SessionsRoot=$sessions;PricingPath=(Join-Path $root 'pricing.json')}
    $sid='11111111-1111-1111-1111-111111111111'
    $path=Join-Path $sessions ('rollout-'+$sid+'.jsonl')
    $meta=@{type='session_meta';timestamp='2026-01-01T00:00:00Z';payload=@{id=$sid;cwd=(Join-Path $temp 'project')}}
    $context=@{type='turn_context';timestamp='2026-01-01T00:00:00Z';payload=@{model='gpt-6-astra';service_tier='default'}}
    $token=@{type='event_msg';timestamp='2026-01-01T00:00:01Z';payload=@{type='token_count';info=@{total_token_usage=@{input_tokens=100;cached_input_tokens=20;output_tokens=10;total_tokens=110};last_token_usage=@{input_tokens=100;cached_input_tokens=20;output_tokens=10;total_tokens=110}}}}
    $text=(@($meta,$context,$token)|ForEach-Object {$_|ConvertTo-Json -Depth 9 -Compress}) -join "`n"
    [IO.File]::WriteAllText($path,$text+"`n",[Text.UTF8Encoding]::new($false))
    $oldEnv=$env:TOKEN_RADER_INDEX_DB
    $first=Update-TokenRaderExplorerIndex -ProjectRoot $root -Paths $paths
    Assert-Backfill ($first.SyncComplete -and $first.ImportedRecords -eq 1) 'first isolated backfill failed'
    Assert-Backfill ($env:TOKEN_RADER_INDEX_DB -eq $oldEnv -and -not (Test-Path $paths.MainIndexPath)) 'backfill touched shared index routing or main DB'
    $second=Update-TokenRaderExplorerIndex -ProjectRoot $root -Paths $paths
    Assert-Backfill ($second.ImportedRecords -eq 0) 'unchanged files reimported'
    $token.timestamp='2026-01-01T00:00:02Z'
    $token.payload.info.total_token_usage.input_tokens=200
    $token.payload.info.total_token_usage.total_tokens=210
    $line=$token|ConvertTo-Json -Depth 9 -Compress
    [IO.File]::AppendAllText($path,$line.Substring(0,40),[Text.UTF8Encoding]::new($false))
    $half=Update-TokenRaderExplorerIndex -ProjectRoot $root -Paths $paths
    Assert-Backfill ($half.ImportedRecords -eq 0) 'half line counted'
    [IO.File]::AppendAllText($path,$line.Substring(40)+"`n",[Text.UTF8Encoding]::new($false))
    $append=Update-TokenRaderExplorerIndex -ProjectRoot $root -Paths $paths
    Assert-Backfill ($append.ImportedRecords -eq 1) 'completed append not counted once'
    $cancel=New-Object Threading.CancellationTokenSource
    $cancel.Cancel(); $caught=$false
    try { Update-TokenRaderExplorerIndex -ProjectRoot $root -Paths $paths -CancellationToken $cancel.Token | Out-Null } catch {$caught=$true}
    $cancel.Dispose()
    Assert-Backfill $caught 'cancelled backfill ran'
    Write-Output 'EXPLORER_BACKFILL_TESTS_PASSED'
} finally {
    $resolved=[IO.Path]::GetFullPath($temp)
    $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) {throw 'Unsafe test cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
