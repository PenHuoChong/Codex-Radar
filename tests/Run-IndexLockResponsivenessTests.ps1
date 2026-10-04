[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$uiSource = Get-Content -LiteralPath (Join-Path $projectRoot 'TokenRader.ps1') -Raw -Encoding UTF8
$refreshMatch = [regex]::Match($uiSource, '(?s)function Refresh-Application\b.*?(?=\r?\nfunction |\z)')
if (-not $refreshMatch.Success -or $refreshMatch.Value -match 'Get-TokenRaderSessionFiles|Get-TokenRaderProjects') {
    throw 'INDEX LOCK TEST FAILED: Refresh-Application must not fall back to a recursive raw-session scan.'
}
$startupStart = $uiSource.LastIndexOf('Set-PricingTable', [StringComparison]::Ordinal)
$showDialog = $uiSource.IndexOf('$script:Window.ShowDialog()', $startupStart, [StringComparison]::Ordinal)
if ($startupStart -lt 0 -or $showDialog -lt $startupStart -or
    $uiSource.Substring($startupStart, $showDialog - $startupStart) -match '\bOpen-TokenRaderIndex\b') {
    throw 'INDEX LOCK TEST FAILED: startup must defer index opening until the background worker runs.'
}

function Assert-IndexLockTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('INDEX LOCK TEST FAILED: ' + $Message) }
}

$previousIndexOverride = [Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB', 'Process')
$tempRoot = Join-Path $env:TEMP ('TokenRader-IndexLockTests-' + [Guid]::NewGuid().ToString('D'))
$sessionsRoot = Join-Path $tempRoot 'sessions'
$dbPath = Join-Path $tempRoot 'data\private\index.db'
$module = $null
$lockLease = $null
$testSucceeded = $false
try {
    New-Item -ItemType Directory -Path $sessionsRoot, (Split-Path -Parent $dbPath) -Force | Out-Null
    $env:TOKEN_RADER_INDEX_DB = $dbPath
    Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
    $module = Get-Module TokenRader.Core

    $now = [DateTimeOffset]::Now
    $logPath = Join-Path $sessionsRoot 'synthetic-lock-probe.jsonl'
    $records = @(
        [ordered]@{ timestamp = $now.AddMinutes(-2).ToString('o'); type = 'turn_context'; payload = [ordered]@{ model = 'synthetic-lock-probe' } }
        [ordered]@{ timestamp = $now.AddMinutes(-1).ToString('o'); type = 'event_msg'; payload = [ordered]@{ type = 'token_count'; request_id = 'synthetic-lock-probe-request'; info = [ordered]@{ total_token_usage = [ordered]@{ input_tokens = 1000; cached_input_tokens = 0; output_tokens = 100; total_tokens = 1100 }; last_token_usage = [ordered]@{ input_tokens = 1000; cached_input_tokens = 0; output_tokens = 100; total_tokens = 1100 }; model_context_window = 1000000 } } }
    )
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($logPath, (($records | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join "`n") + "`n", $utf8)

    Open-TokenRaderIndex -SessionsRoot $sessionsRoot | Out-Null
    $connection = (& $module { $script:TokenRaderIndex.Connection })
    $schemaVersionBefore = 0
    $schemaCommand = $connection.CreateCommand()
    try { $schemaCommand.CommandText = 'PRAGMA schema_version'; $schemaVersionBefore = [int]$schemaCommand.ExecuteScalar() } finally { $schemaCommand.Dispose() }
    & $module { Close-TokenRaderIndex }
    $lockLease = [TokenRaderIndexer]::AcquireFileLock(($dbPath + '.lock'), 100)
    Open-TokenRaderIndex -SessionsRoot $sessionsRoot -SchemaReady | Out-Null
    $schemaReadyConnection = (& $module { $script:TokenRaderIndex.Connection })
    $schemaCommand = $schemaReadyConnection.CreateCommand()
    try { $schemaCommand.CommandText = 'PRAGMA schema_version'; $schemaVersionAfter = [int]$schemaCommand.ExecuteScalar() } finally { $schemaCommand.Dispose() }
    Assert-IndexLockTest ($schemaVersionAfter -eq $schemaVersionBefore) 'SchemaReady open changed the SQLite schema while the writer lock was held.'
    $lockLease.Dispose(); $lockLease = $null

    $pricing = [pscustomobject]@{ verifiedAt = 'synthetic'; unitTokens = 1000000; models = @([pscustomobject]@{ id = 'synthetic-lock-probe'; aliases = @(); input = 1.0; cachedInput = 0.1; output = 2.0 }) }
    $originalCost = & $module { (Get-Item Function:\Get-TokenRaderCost).ScriptBlock }
    & $module {
        param($db, $original)
        $script:IndexLockTestDb = [string]$db
        $script:IndexLockTestOriginalCost = $original
        $script:IndexLockTestProbeCount = 0
        $script:IndexLockTestRevisionBumped = $false
        $wrapper = {
            param($Usage, [string]$Model, $PricingDocument, [string]$Scope = 'task', [Int64]$ModelContextWindow = 0,
                [Int64]$LongContextThreshold = 0, [Nullable[bool]]$LongContextApplied = $null,
                [Int64]$CacheCreationTokens = 0, [Nullable[bool]]$CacheWriteObservable = $null,
                [bool]$RequestInputObservable = $true, [Nullable[bool]]$LongContextPricingUncertain = $null,
                [AllowEmptyString()][string]$ServiceTier = '', [AllowNull()][AllowEmptyString()][string]$ServiceTierSource = $null,
                [Nullable[bool]]$ServiceTierEvidenceComplete = $null, $ResolvedPrice = $null)
            $lease = [TokenRaderIndexer]::AcquireFileLock(($script:IndexLockTestDb + '.lock'), 0)
            try { $script:IndexLockTestProbeCount++ } finally { $lease.Dispose() }
            if (-not $script:IndexLockTestRevisionBumped) {
                $lease = [TokenRaderIndexer]::AcquireFileLock(($script:IndexLockTestDb + '.lock'), 0)
                $writer = $null
                try {
                    $writer = New-Object System.Data.SQLite.SQLiteConnection ('Data Source=' + $script:IndexLockTestDb + ';Version=3;Default Timeout=2;')
                    $writer.Open()
                    [void][TokenRaderIndexer]::IncrementIndexRevision($writer)
                    $script:IndexLockTestRevisionBumped = $true
                } finally { if ($null -ne $writer) { $writer.Dispose() }; $lease.Dispose() }
            }
            & $script:IndexLockTestOriginalCost @PSBoundParameters
        }
        Set-Item -Path Function:\script:Get-TokenRaderCost -Value $wrapper
    } $dbPath $originalCost

    $anchor = $now.AddMinutes(1)
    $first = Get-TokenRaderUsageHistoryWindow -SessionsRoot $sessionsRoot -PricingDocument $pricing -AnchorAt $anchor -ForceRefresh
    $probe = & $module { [pscustomobject]@{ Count = $script:IndexLockTestProbeCount; RevisionBumped = $script:IndexLockTestRevisionBumped; Original = $script:IndexLockTestOriginalCost } }
    Assert-IndexLockTest ($probe.Count -gt 0) 'history pricing did not run its zero-timeout writer-lock probe.'
    Assert-IndexLockTest ([bool]$probe.RevisionBumped) 'the second synthetic SQLite connection did not advance IndexRevision mid-pricing.'
    Assert-IndexLockTest (-not [bool]$first.FromCache) 'the first history read unexpectedly came from cache.'
    $connection = (& $module { $script:TokenRaderIndex.Connection })
    Assert-IndexLockTest ([TokenRaderIndexer]::GetUsageHistoryCount($connection) -eq 0) 'history cached a snapshot after its read revision had advanced.'

    & $module { param($original) Set-Item -Path Function:\script:Get-TokenRaderCost -Value $original } $probe.Original
    $second = Get-TokenRaderUsageHistoryWindow -SessionsRoot $sessionsRoot -PricingDocument $pricing -AnchorAt $anchor
    Assert-IndexLockTest (-not [bool]$second.FromCache) 'history reused a cache from the prior index revision.'
    Assert-IndexLockTest ([TokenRaderIndexer]::GetUsageHistoryCount($connection) -eq 1) 'history failed to persist a snapshot for the stable revision.'
    $third = Get-TokenRaderUsageHistoryWindow -SessionsRoot $sessionsRoot -PricingDocument $pricing -AnchorAt $anchor
    Assert-IndexLockTest ([bool]$third.FromCache) 'history did not reuse the snapshot matching the stable index revision.'
    $testSucceeded = $true
} finally {
    if ($null -ne $lockLease) { $lockLease.Dispose() }
    if ($null -ne $module) {
        try {
            $original = & $module { $script:IndexLockTestOriginalCost }
            if ($null -ne $original) { & $module { param($value) Set-Item -Path Function:\script:Get-TokenRaderCost -Value $value } $original }
        } catch { }
        try { & $module { Close-TokenRaderIndex } } catch { }
        Remove-Module $module -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $previousIndexOverride) { Remove-Item Env:TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue }
    else { $env:TOKEN_RADER_INDEX_DB = $previousIndexOverride }

    $expectedTempParent = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if ($resolvedTempRoot.StartsWith($expectedTempParent, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTempRoot) -match '^TokenRader-IndexLockTests-[0-9a-f-]{36}$') {
        if (Test-Path -LiteralPath $resolvedTempRoot) { Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force }
    } elseif (Test-Path -LiteralPath $resolvedTempRoot) {
        throw 'INDEX LOCK TEST REFUSED CLEANUP: temporary root failed its synthetic-path safety check.'
    }
}
if (-not $testSucceeded) { throw 'INDEX LOCK TEST FAILED before all assertions completed.' }
'INDEX_LOCK_RESPONSIVENESS_TESTS_PASSED'
