[CmdletBinding()]
param(
    [string]$IndexerDllPath = ''
)

# These are synthetic compatibility checks only.  They deliberately never
# discover, open, or modify a real Codex home, auth file, or session log.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-UsageCompatibility {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw ('USAGE COMPATIBILITY TEST FAILED: ' + $Message) }
}

function Assert-UsageCompatibilityEqual {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([string]$Expected -ne [string]$Actual) {
        throw ('USAGE COMPATIBILITY TEST FAILED: {0}. Expected=[{1}] Actual=[{2}]' -f $Message, $Expected, $Actual)
    }
}

function Assert-UsageCompatibilityNear {
    param(
        [double]$Expected,
        [double]$Actual,
        [double]$Tolerance,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw ('USAGE COMPATIBILITY TEST FAILED: {0}. Expected=[{1}] Actual=[{2}]' -f $Message, $Expected, $Actual)
    }
}

function New-CompatibilityUsage {
    param(
        [Parameter(Mandatory = $true)][Int64]$InputTokens,
        [Int64]$CachedTokens = 0,
        [Int64]$OutputTokens = 0,
        [hashtable]$Aliases = $null
    )

    $usage = [ordered]@{
        input_tokens = $InputTokens
        cached_input_tokens = $CachedTokens
        output_tokens = $OutputTokens
        reasoning_output_tokens = 0L
        total_tokens = $InputTokens + $OutputTokens
    }
    if ($null -ne $Aliases) {
        foreach ($key in @($Aliases.Keys)) { $usage[[string]$key] = $Aliases[$key] }
    }
    return $usage
}

function New-CompatibilityTokenLine {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [hashtable]$Total = $null,
        [hashtable]$Last = $null,
        [string]$RequestId = ''
    )

    $info = [ordered]@{}
    if ($null -ne $Total) { $info['total_token_usage'] = $Total }
    if ($null -ne $Last) { $info['last_token_usage'] = $Last }
    $payload = [ordered]@{
        type = 'token_count'
        info = $info
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) { $payload['request_id'] = $RequestId }
    [ordered]@{
        timestamp = $Timestamp
        type = 'event_msg'
        payload = $payload
    } | ConvertTo-Json -Depth 20 -Compress
}

function New-CompatibilityTurnContextLine {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [string]$Model = 'gpt-5.6-sol'
    )
    [ordered]@{
        timestamp = $Timestamp
        type = 'turn_context'
        payload = [ordered]@{ model = $Model }
    } | ConvertTo-Json -Depth 8 -Compress
}

function Write-CompatibilityJsonl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )
    [IO.File]::WriteAllText(
        $Path,
        (($Lines -join "`n") + "`n"),
        (New-Object Text.UTF8Encoding($false))
    )
}

function Get-CompatibilityTrackerDeltas {
    param(
        [Parameter(Mandatory = $true)][string]$JsonlPath,
        [Parameter(Mandatory = $true)][string]$FixturePath
    )

    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) { throw 'Node.js 22+ is required to run the vendored TokenTracker helper fixture.' }

    # This runner reads exactly the same synthetic JSONL file used by the
    # local parser.  It invokes only the upstream helper's scoped cumulative
    # usage API; it never imports a package, installs hooks, or reads logs.
    $runner = @'
const fs = require("node:fs");
const path = process.argv[2];
const helper = require(process.argv[3]);
const state = helper.createUsageDeltaState();
const deltas = [];
const lines = fs.readFileSync(path, "utf8").split(/\r?\n/).filter(Boolean);
for (const line of lines) {
  const record = JSON.parse(line);
  const info = record && record.payload && record.payload.info;
  if (!info || !record.payload || record.payload.type !== "token_count") continue;
  const delta = helper.consumeUsageDelta(
    state,
    info.last_token_usage || null,
    info.total_token_usage || null,
  );
  const value = (name) => delta && Object.prototype.hasOwnProperty.call(delta, name)
    ? delta[name]
    : null;
  deltas.push({
    input_tokens: value("input_tokens"),
    cached_input_tokens: value("cached_input_tokens"),
    cache_creation_input_tokens: value("cache_creation_input_tokens"),
    output_tokens: value("output_tokens"),
    reasoning_output_tokens: value("reasoning_output_tokens"),
    total_tokens: value("total_tokens"),
  });
}
process.stdout.write(JSON.stringify({
  deltas,
  sawDivergentCumulative: !!state.sawDivergentCumulative,
  sawInterleaved: !!state.sawInterleaved,
  baselines: helper.snapshotUsageBaselines(state).length,
}));
'@

    # Windows PowerShell 5.1 can split a multiline -e argument at embedded
    # newlines.  Use a disposable synthetic runner file so the same test is
    # reliable in both Windows PowerShell and PowerShell 7.
    $runnerPath = Join-Path $env:TEMP ('token-rader-usage-compat-runner-' + [Guid]::NewGuid().ToString('N') + '.js')
    try {
        [IO.File]::WriteAllText($runnerPath, $runner, (New-Object Text.UTF8Encoding($false)))
        $output = & $node.Source $runnerPath $JsonlPath $FixturePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ('TokenTracker helper fixture failed: ' + ([string]$output -join ' '))
        }
        $text = ([string]$output -join '').Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'TokenTracker helper fixture returned no JSON.' }
        return $text | ConvertFrom-Json
    } finally {
        if (Test-Path -LiteralPath $runnerPath) { Remove-Item -LiteralPath $runnerPath -Force }
    }
}

function Get-CompatibilityAggregate {
    param(
        [Parameter(Mandatory = $true)]$TrackerResult
    )

    [Int64]$inputTotal = 0
    [Int64]$cachedTotal = 0
    [Int64]$outputTotal = 0
    [Int64]$reasoningTotal = 0
    [Int64]$deltaCount = 0
    [Int64]$cacheCreationInput = 0
    foreach ($delta in @($TrackerResult.deltas)) {
        if ($null -eq $delta -or $null -eq $delta.total_tokens) { continue }
        $deltaCount++
        $inputTotal += [Int64]$delta.input_tokens
        $cachedTotal += [Int64]$delta.cached_input_tokens
        $outputTotal += [Int64]$delta.output_tokens
        $reasoningTotal += [Int64]$delta.reasoning_output_tokens
        $cacheCreationInput += [Int64]$delta.cache_creation_input_tokens
    }
    [pscustomobject]@{
        Count = $deltaCount
        Input = $inputTotal
        Cached = $cachedTotal
        Output = $outputTotal
        Reasoning = $reasoningTotal
        CacheCreationInput = $cacheCreationInput
    }
}

function Get-CompatibilityLegacyResult {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [Parameter(Mandatory = $true)]$Pricing
    )

    $result = Get-TokenRaderSessionResult -FilePath $Path -SessionsRoot $SessionsRoot -PricingDocument $Pricing
    Assert-UsageCompatibility ($null -ne $result) ('legacy local result exists for ' + [IO.Path]::GetFileName($Path))
    return $result
}

function Get-CompatibilityLegacyCacheCreation {
    param([Parameter(Mandatory = $true)][string]$Path)

    $coreModule = Get-Module TokenRader.Core
    $parsed = & $coreModule { param($sourcePath) Get-TokenRaderUsageEvents -FilePath $sourcePath } $Path
    [Int64]$total = 0
    foreach ($event in @($parsed.Events)) { $total += [Int64]$event.CacheCreationTokens }
    return [pscustomobject]@{
        Events = @($parsed.Events)
        CacheCreationTokens = $total
    }
}

function Get-CompatibilityIndexedAggregate {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Int64]$LongContextThreshold = 0
    )

    $db = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;New=True;'
    $db.Open()
    try {
        [TokenRaderIndexer]::CreateSchema($db)
        [Int64]$length = [IO.FileInfo]::new($Path).Length
        [void][TokenRaderIndexer]::ImportFile($db, $Path, 0L, $length, $SessionId, 1L)
        $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        $thresholds['gpt-5.6-sol'] = $LongContextThreshold
        $starts = @{ $Path = 0L }
        $ends = @{ $Path = $length }
        return [TokenRaderIndexer]::AggregateIntervalRecords(
            $db,
            $starts,
            $ends,
            [DateTimeOffset]::Parse('2026-09-01T00:00:00Z'),
            $thresholds,
            [Threading.CancellationToken]::None,
            $null
        )
    } finally {
        $db.Dispose()
    }
}

function Get-CompatibilityIndexedAggregateSplit {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Int64]$SplitOffset,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    # Import the same synthetic file in two frozen ranges.  This exercises the
    # persisted cumulative baseline and the last-only invalidation path that a
    # one-pass import cannot cover.
    $db = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;New=True;'
    $db.Open()
    try {
        [TokenRaderIndexer]::CreateSchema($db)
        [Int64]$length = [IO.FileInfo]::new($Path).Length
        if ($SplitOffset -le 0 -or $SplitOffset -ge $length) {
            throw ('Synthetic split offset must be inside file: {0} / {1}' -f $SplitOffset, $length)
        }
        [void][TokenRaderIndexer]::ImportFile($db, $Path, 0L, $SplitOffset, $SessionId, 1L)
        [void][TokenRaderIndexer]::ImportFile($db, $Path, $SplitOffset, $length, $SessionId, 2L)
        $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        $thresholds['gpt-5.6-sol'] = 0L
        $starts = @{ $Path = 0L }
        $ends = @{ $Path = $length }
        return [TokenRaderIndexer]::AggregateIntervalRecords(
            $db,
            $starts,
            $ends,
            [DateTimeOffset]::Parse('2026-09-01T00:00:00Z'),
            $thresholds,
            [Threading.CancellationToken]::None,
            $null
        )
    } finally {
        $db.Dispose()
    }
}

function Assert-CompatibilityLocalAggregate {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Legacy,
        [Parameter(Mandatory = $true)]$Indexed
    )

    Assert-UsageCompatibilityEqual $Expected.Count $Legacy.CountedEvents ($Name + ' legacy counted events')
    Assert-UsageCompatibilityEqual $Expected.Input $Legacy.Usage.Input ($Name + ' legacy input')
    Assert-UsageCompatibilityEqual $Expected.Cached $Legacy.Usage.Cached ($Name + ' legacy cached input')
    Assert-UsageCompatibilityEqual $Expected.Output $Legacy.Usage.Output ($Name + ' legacy output')

    Assert-UsageCompatibilityEqual $Expected.Count $Indexed.CountedEvents ($Name + ' compiled counted events')
    Assert-UsageCompatibilityEqual $Expected.Input $Indexed.TotalInput ($Name + ' compiled input')
    Assert-UsageCompatibilityEqual $Expected.Cached $Indexed.TotalCached ($Name + ' compiled cached input')
    Assert-UsageCompatibilityEqual $Expected.Output $Indexed.TotalOutput ($Name + ' compiled output')
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$fixturePath = Join-Path $PSScriptRoot 'fixtures\TokenTracker-codex-token-usage.js'
Assert-UsageCompatibility (Test-Path -LiteralPath $fixturePath) 'vendored TokenTracker helper fixture exists'
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force

$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
$indexerDll = if ([string]::IsNullOrWhiteSpace($IndexerDllPath)) {
    Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll'
} else {
    (Resolve-Path -LiteralPath $IndexerDllPath).Path
}
if (-not (Test-Path -LiteralPath $sqliteDll)) { throw ('SQLite dependency missing: ' + $sqliteDll) }
if (-not (Test-Path -LiteralPath $indexerDll)) {
    throw ('Indexer dependency missing; run Build.ps1 first: ' + $indexerDll)
}
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path $indexerDll }

$prices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
$tempRoot = Join-Path $env:TEMP ('token-rader-usage-compat-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$intentionalDifferences = New-Object System.Collections.Generic.List[string]

try {
    $modelContext = New-CompatibilityTurnContextLine -Timestamp '2026-09-01T00:00:00Z'

    # Complete totals/calls are the strict parity baseline.  The duplicate
    # cumulative snapshot is present with a different timestamp and must be
    # charged once by both implementations.
    $completePath = Join-Path $tempRoot 'complete.jsonl'
    $completeLines = @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:00:01Z' `
            -Total (New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20) `
            -Last (New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20)),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:00:02Z' `
            -Total (New-CompatibilityUsage -InputTokens 120 -CachedTokens 15 -OutputTokens 30) `
            -Last (New-CompatibilityUsage -InputTokens 40 -CachedTokens 5 -OutputTokens 10)),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:00:03Z' `
            -Total (New-CompatibilityUsage -InputTokens 120 -CachedTokens 15 -OutputTokens 30) `
            -Last (New-CompatibilityUsage -InputTokens 40 -CachedTokens 5 -OutputTokens 10)),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:00:04Z' `
            -Total (New-CompatibilityUsage -InputTokens 140 -CachedTokens 20 -OutputTokens 40) `
            -Last (New-CompatibilityUsage -InputTokens 20 -CachedTokens 5 -OutputTokens 10))
    )
    Write-CompatibilityJsonl -Path $completePath -Lines $completeLines
    $completeTracker = Get-CompatibilityTrackerDeltas -JsonlPath $completePath -FixturePath $fixturePath
    $completeTrackerAggregate = Get-CompatibilityAggregate -TrackerResult $completeTracker
    Assert-UsageCompatibilityEqual 3 $completeTrackerAggregate.Count 'Tracker complete cumulative count'
    Assert-UsageCompatibilityEqual 140 $completeTrackerAggregate.Input 'Tracker complete cumulative input'
    Assert-UsageCompatibilityEqual 20 $completeTrackerAggregate.Cached 'Tracker complete cumulative cached input'
    Assert-UsageCompatibilityEqual 40 $completeTrackerAggregate.Output 'Tracker complete cumulative output'
    $completeLegacy = Get-CompatibilityLegacyResult -Path $completePath -SessionsRoot $tempRoot -Pricing $prices
    $completeIndexed = Get-CompatibilityIndexedAggregate -Path $completePath -SessionId '91000000-0000-0000-0000-000000000001'
    Assert-CompatibilityLocalAggregate -Name 'complete' -Expected $completeTrackerAggregate -Legacy $completeLegacy -Indexed $completeIndexed

    # A missing cumulative total is not evidence that two identical last-only
    # calls are duplicates.  The scoped upstream helper returns each last call
    # independently, and both local paths must preserve those two calls.
    $lastOnlyPath = Join-Path $tempRoot 'last-only-identical.jsonl'
    $identicalLast = New-CompatibilityUsage -InputTokens 20 -CachedTokens 4 -OutputTokens 3
    Write-CompatibilityJsonl -Path $lastOnlyPath -Lines @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:01:01Z' -Last $identicalLast),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:01:02Z' -Last $identicalLast)
    )
    $lastOnlyTracker = Get-CompatibilityTrackerDeltas -JsonlPath $lastOnlyPath -FixturePath $fixturePath
    $lastOnlyTrackerAggregate = Get-CompatibilityAggregate -TrackerResult $lastOnlyTracker
    Assert-UsageCompatibilityEqual 2 $lastOnlyTrackerAggregate.Count 'Tracker last-only identical count'
    Assert-UsageCompatibilityEqual 40 $lastOnlyTrackerAggregate.Input 'Tracker last-only identical input'
    Assert-UsageCompatibilityEqual 8 $lastOnlyTrackerAggregate.Cached 'Tracker last-only identical cached input'
    Assert-UsageCompatibilityEqual 6 $lastOnlyTrackerAggregate.Output 'Tracker last-only identical output'
    $lastOnlyLegacy = Get-CompatibilityLegacyResult -Path $lastOnlyPath -SessionsRoot $tempRoot -Pricing $prices
    $lastOnlyIndexed = Get-CompatibilityIndexedAggregate -Path $lastOnlyPath -SessionId '91000000-0000-0000-0000-000000000002'
    Assert-CompatibilityLocalAggregate -Name 'last-only-identical' -Expected $lastOnlyTrackerAggregate -Legacy $lastOnlyLegacy -Indexed $lastOnlyIndexed

    # A missing-total record and a later complete record can be the same call
    # when Codex exposes a stable request id.  The complete observation wins
    # regardless of arrival order. TokenTracker's scoped helper has no
    # request-id input and therefore returns both deltas; local TokenRader
    # must use the explicit identity and count the complete call once.
    $missingTotalReconcilePath = Join-Path $tempRoot 'missing-total-request-reconcile.jsonl'
    $requestOnlyCall = New-CompatibilityUsage -InputTokens 20 -CachedTokens 2 -OutputTokens 5
    $requestCompleteCall = New-CompatibilityUsage -InputTokens 40 -CachedTokens 4 -OutputTokens 8
    $requestTotal = New-CompatibilityUsage -InputTokens 100 -CachedTokens 10 -OutputTokens 20
    Write-CompatibilityJsonl -Path $missingTotalReconcilePath -Lines @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:01:11Z' -Last $requestOnlyCall -RequestId 'request-R'),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:01:12Z' -Total $requestTotal -Last $requestCompleteCall -RequestId 'request-R')
    )
    $missingTotalReconcileTracker = Get-CompatibilityTrackerDeltas -JsonlPath $missingTotalReconcilePath -FixturePath $fixturePath
    $missingTotalReconcileTrackerAggregate = Get-CompatibilityAggregate -TrackerResult $missingTotalReconcileTracker
    Assert-UsageCompatibilityEqual 2 $missingTotalReconcileTrackerAggregate.Count 'Tracker missing-total request-id count'
    Assert-UsageCompatibilityEqual 60 $missingTotalReconcileTrackerAggregate.Input 'Tracker missing-total request-id input'
    $missingTotalReconcileLegacy = Get-CompatibilityLegacyResult -Path $missingTotalReconcilePath -SessionsRoot $tempRoot -Pricing $prices
    $missingTotalReconcileIndexed = Get-CompatibilityIndexedAggregate -Path $missingTotalReconcilePath -SessionId '91000000-0000-0000-0000-000000000006'
    $localMissingTotalReconcileExpected = [pscustomobject]@{ Count = 1; Input = 40; Cached = 4; Output = 8 }
    Assert-CompatibilityLocalAggregate -Name 'missing-total-request-reconcile' -Expected $localMissingTotalReconcileExpected `
        -Legacy $missingTotalReconcileLegacy -Indexed $missingTotalReconcileIndexed

    $missingTotalReconcileReversePath = Join-Path $tempRoot 'missing-total-request-reconcile-reverse.jsonl'
    Write-CompatibilityJsonl -Path $missingTotalReconcileReversePath -Lines @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:01:21Z' -Total $requestTotal -Last $requestCompleteCall -RequestId 'request-R'),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:01:22Z' -Last $requestOnlyCall -RequestId 'request-R')
    )
    $missingTotalReconcileReverseTracker = Get-CompatibilityTrackerDeltas -JsonlPath $missingTotalReconcileReversePath -FixturePath $fixturePath
    $missingTotalReconcileReverseTrackerAggregate = Get-CompatibilityAggregate -TrackerResult $missingTotalReconcileReverseTracker
    Assert-UsageCompatibilityEqual 2 $missingTotalReconcileReverseTrackerAggregate.Count 'Tracker reverse request-id count'
    Assert-UsageCompatibilityEqual 60 $missingTotalReconcileReverseTrackerAggregate.Input 'Tracker reverse request-id input'
    $missingTotalReconcileReverseLegacy = Get-CompatibilityLegacyResult -Path $missingTotalReconcileReversePath -SessionsRoot $tempRoot -Pricing $prices
    $missingTotalReconcileReverseIndexed = Get-CompatibilityIndexedAggregate -Path $missingTotalReconcileReversePath -SessionId '91000000-0000-0000-0000-000000000007'
    Assert-CompatibilityLocalAggregate -Name 'missing-total-request-reconcile-reverse' -Expected $localMissingTotalReconcileExpected `
        -Legacy $missingTotalReconcileReverseLegacy -Indexed $missingTotalReconcileReverseIndexed
    [void]$intentionalDifferences.Add('Tracker does not receive request identity in this scoped helper and returns both missing-total/complete deltas; local TokenRader deduplicates the same request id.')

    # With no last usage, a first total-only snapshot is a baseline: its real
    # call boundary is unknowable.  Later cumulative growth, duplicate totals,
    # and a reset are evidence-bearing and are processed as diff/null/reset.
    $missingLastPath = Join-Path $tempRoot 'missing-last-diff-reset.jsonl'
    $total100 = New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20
    $total150 = New-CompatibilityUsage -InputTokens 120 -CachedTokens 15 -OutputTokens 30
    $total40 = New-CompatibilityUsage -InputTokens 30 -CachedTokens 4 -OutputTokens 10
    Write-CompatibilityJsonl -Path $missingLastPath -Lines @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:02:01Z' -Total $total100),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:02:02Z' -Total $total150),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:02:03Z' -Total $total150),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:02:04Z' -Total $total40)
    )
    $missingLastTracker = Get-CompatibilityTrackerDeltas -JsonlPath $missingLastPath -FixturePath $fixturePath
    $missingLastTrackerAggregate = Get-CompatibilityAggregate -TrackerResult $missingLastTracker
    # The upstream helper charges its first total-only snapshot.  The local
    # conservative boundary intentionally leaves that one as baseline-only.
    Assert-UsageCompatibilityEqual 3 $missingLastTrackerAggregate.Count 'Tracker missing-last diff/duplicate/reset count'
    Assert-UsageCompatibilityEqual 150 $missingLastTrackerAggregate.Input 'Tracker missing-last diff/duplicate/reset input'
    Assert-UsageCompatibilityEqual 19 $missingLastTrackerAggregate.Cached 'Tracker missing-last diff/duplicate/reset cached input'
    Assert-UsageCompatibilityEqual 40 $missingLastTrackerAggregate.Output 'Tracker missing-last diff/duplicate/reset output'
    $missingLastLegacy = Get-CompatibilityLegacyResult -Path $missingLastPath -SessionsRoot $tempRoot -Pricing $prices
    $missingLastIndexed = Get-CompatibilityIndexedAggregate -Path $missingLastPath -SessionId '91000000-0000-0000-0000-000000000003'
    $localMissingLastExpected = [pscustomobject]@{ Count = 1; Input = 40; Cached = 5; Output = 10 }
    Assert-CompatibilityLocalAggregate -Name 'missing-last-diff-reset' -Expected $localMissingLastExpected -Legacy $missingLastLegacy -Indexed $missingLastIndexed
    [void]$intentionalDifferences.Add('Tracker charges the first total-only snapshot and a lower reset snapshot; local TokenRader keeps both ambiguous boundaries as baselines.')

    # A last-only call can be included in a later cumulative total.  The local
    # conservative boundary invalidates the old cumulative anchor, keeps the
    # observable last-only call, and treats the later total as baseline-only;
    # it therefore never charges that call a second time.  The upstream helper
    # is intentionally scoped to its delta API and returns both observable
    # deltas, so this is reported as a known cross-tool semantic difference
    # rather than forced dollar parity.
    $mixedPath = Join-Path $tempRoot 'mixed-total-last-only.jsonl'
    $mixedTotal100 = New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20
    $mixedLast20 = New-CompatibilityUsage -InputTokens 16 -CachedTokens 2 -OutputTokens 4
    $mixedTotal140 = New-CompatibilityUsage -InputTokens 112 -CachedTokens 14 -OutputTokens 28
    Write-CompatibilityJsonl -Path $mixedPath -Lines @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:03:01Z' -Total $mixedTotal100 -Last $mixedTotal100),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:03:02Z' -Last $mixedLast20),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:03:03Z' -Total $mixedTotal140)
    )
    $mixedTracker = Get-CompatibilityTrackerDeltas -JsonlPath $mixedPath -FixturePath $fixturePath
    $mixedTrackerAggregate = Get-CompatibilityAggregate -TrackerResult $mixedTracker
    Assert-UsageCompatibilityEqual 3 $mixedTrackerAggregate.Count 'Tracker mixed total/last-only count'
    Assert-UsageCompatibilityEqual 128 $mixedTrackerAggregate.Input 'Tracker mixed total/last-only input'
    $mixedLegacy = Get-CompatibilityLegacyResult -Path $mixedPath -SessionsRoot $tempRoot -Pricing $prices
    $mixedIndexed = Get-CompatibilityIndexedAggregate -Path $mixedPath -SessionId '91000000-0000-0000-0000-000000000004'
    $localMixedExpected = [pscustomobject]@{ Count = 2; Input = 96; Cached = 12; Output = 24 }
    Assert-CompatibilityLocalAggregate -Name 'mixed-total-last-only' -Expected $localMixedExpected -Legacy $mixedLegacy -Indexed $mixedIndexed
    [void]$intentionalDifferences.Add('Tracker returns a missing-total last-only delta before a later cumulative snapshot; local TokenRader reconciles that pending call to avoid double counting.')

    # A total-only cumulative delta can retain token evidence without exposing
    # a request boundary.  Above the model's long-context threshold it must not
    # be priced as a definite long request.  The aggregate still keeps the
    # tokens and marks the derived bucket as non-observable/uncertain.
    $ambiguousTotalPath = Join-Path $tempRoot 'ambiguous-total-only-300k.jsonl'
    $zeroTotal = New-CompatibilityUsage -InputTokens 0 -CachedTokens 0 -OutputTokens 0
    $ambiguousTotal = New-CompatibilityUsage -InputTokens 300000 -CachedTokens 0 -OutputTokens 0
    Write-CompatibilityJsonl -Path $ambiguousTotalPath -Lines @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:03:11Z' -Total $zeroTotal),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:03:12Z' -Total $ambiguousTotal)
    )
    $ambiguousIndexed = Get-CompatibilityIndexedAggregate -Path $ambiguousTotalPath `
        -SessionId '91000000-0000-0000-0000-000000000008' -LongContextThreshold 272000
    Assert-UsageCompatibilityEqual 1 $ambiguousIndexed.CountedEvents 'ambiguous total-only retained event count'
    Assert-UsageCompatibilityEqual 300000 $ambiguousIndexed.TotalInput 'ambiguous total-only retains aggregate tokens'
    Assert-UsageCompatibilityEqual 300000 $ambiguousIndexed.StandardContextInput 'ambiguous total-only remains standard evidence'
    Assert-UsageCompatibilityEqual 0 $ambiguousIndexed.LongContextEvents 'ambiguous total-only is not definite long context'
    $ambiguousBuckets = @($ambiguousIndexed.Buckets | Where-Object { -not [bool]$_.RequestInputObservable })
    Assert-UsageCompatibilityEqual 1 $ambiguousBuckets.Count 'ambiguous total-only has one derived bucket'
    $ambiguousBucket = $ambiguousBuckets[0]
    Assert-UsageCompatibilityEqual 300000 $ambiguousBucket.Input 'ambiguous derived bucket retains tokens'
    Assert-UsageCompatibility ($null -ne $ambiguousBucket.PSObject.Properties['LongContextPricingUncertain']) 'ambiguous bucket exposes pricing uncertainty'
    Assert-UsageCompatibility ([bool]$ambiguousBucket.LongContextPricingUncertain) 'ambiguous bucket marks long-context uncertainty'

    $costCommand = Get-Command Get-TokenRaderCost -ErrorAction Stop
    Assert-UsageCompatibility $costCommand.Parameters.ContainsKey('RequestInputObservable') 'cost API exposes request-input observability'
    $ambiguousUsage = [pscustomobject]@{
        Input = 300000L
        Cached = 0L
        Uncached = 300000L
        Output = 0L
        ReasoningOutput = 0L
        Total = 300000L
        CacheHitRate = 0.0
    }
    $ambiguousCostArgs = @{
        Usage = $ambiguousUsage
        Model = 'gpt-5.6-sol'
        PricingDocument = $prices
        Scope = 'call'
        RequestInputObservable = $false
        LongContextPricingUncertain = $true
    }
    $ambiguousCost = & $costCommand @ambiguousCostArgs
    Assert-UsageCompatibility (-not [bool]$ambiguousCost.Known) 'ambiguous total-only cost is not known'
    Assert-UsageCompatibilityEqual 'missing_request_input' $ambiguousCost.PricingReason 'ambiguous total-only pricing diagnostic'

    # Three derived 100K deltas are individually below the threshold.  Their
    # aggregate sum is 300K, but that sum must not be reinterpreted as one
    # 300K request when the bucket carries an explicit per-delta bounded flag.
    $derivedTotalsPath = Join-Path $tempRoot 'derived-three-100k.jsonl'
    $derivedTotal100 = New-CompatibilityUsage -InputTokens 100000 -CachedTokens 0 -OutputTokens 0
    $derivedTotal200 = New-CompatibilityUsage -InputTokens 200000 -CachedTokens 0 -OutputTokens 0
    $derivedTotal300 = New-CompatibilityUsage -InputTokens 300000 -CachedTokens 0 -OutputTokens 0
    Write-CompatibilityJsonl -Path $derivedTotalsPath -Lines @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:03:21Z' -Total $zeroTotal),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:03:22Z' -Total $derivedTotal100),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:03:23Z' -Total $derivedTotal200),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:03:24Z' -Total $derivedTotal300)
    )
    $derivedIndexed = Get-CompatibilityIndexedAggregate -Path $derivedTotalsPath `
        -SessionId '91000000-0000-0000-0000-000000000009' -LongContextThreshold 272000
    Assert-UsageCompatibilityEqual 3 $derivedIndexed.CountedEvents 'three derived deltas counted'
    Assert-UsageCompatibilityEqual 300000 $derivedIndexed.TotalInput 'three derived deltas retain aggregate tokens'
    Assert-UsageCompatibilityEqual 300000 $derivedIndexed.StandardContextInput 'three derived deltas remain standard context'
    Assert-UsageCompatibilityEqual 0 $derivedIndexed.LongContextEvents 'three derived deltas do not become one long request'
    $derivedBuckets = @($derivedIndexed.Buckets | Where-Object { -not [bool]$_.RequestInputObservable })
    Assert-UsageCompatibilityEqual 1 $derivedBuckets.Count 'three derived deltas merge into one bounded bucket'
    $derivedBucket = $derivedBuckets[0]
    Assert-UsageCompatibilityEqual 300000 $derivedBucket.Input 'bounded derived bucket input'
    Assert-UsageCompatibility (-not [bool]$derivedBucket.LongContextPricingUncertain) 'bounded derived bucket is not long-context uncertain'
    $derivedCostArgs = @{
        Usage = $ambiguousUsage
        Model = 'gpt-5.6-sol'
        PricingDocument = $prices
        Scope = 'call'
        RequestInputObservable = $false
        LongContextPricingUncertain = $false
        LongContextApplied = $false
    }
    $derivedCost = & $costCommand @derivedCostArgs
    Assert-UsageCompatibility ([bool]$derivedCost.Known) 'bounded derived aggregate remains priceable'
    Assert-UsageCompatibilityEqual 'priced' $derivedCost.PricingReason 'bounded derived pricing diagnostic'

    # Re-import the same file after the last-only record.  The second import
    # must restore the invalidated cumulative baseline instead of charging the
    # total-only row as a delta from the pre-last-only total.  Compare this
    # frozen two-range result with a one-pass import of identical lines.
    $incrementalPath = Join-Path $tempRoot 'incremental-baseline-one-pass.jsonl'
    $incrementalLines = @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:05:01Z' `
            -Total (New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20) `
            -Last (New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20)),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:05:02Z' `
            -Last (New-CompatibilityUsage -InputTokens 16 -CachedTokens 2 -OutputTokens 4)),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:05:03Z' `
            -Total (New-CompatibilityUsage -InputTokens 140 -CachedTokens 14 -OutputTokens 28)),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:05:04Z' `
            -Total (New-CompatibilityUsage -InputTokens 180 -CachedTokens 18 -OutputTokens 36))
    )
    Write-CompatibilityJsonl -Path $incrementalPath -Lines $incrementalLines
    $incrementalOnePass = Get-CompatibilityIndexedAggregate -Path $incrementalPath `
        -SessionId '91000000-0000-0000-0000-000000000010'
    $splitPath = Join-Path $tempRoot 'incremental-baseline-split.jsonl'
    Write-CompatibilityJsonl -Path $splitPath -Lines @($incrementalLines[0..2])
    [Int64]$splitOffset = [IO.FileInfo]::new($splitPath).Length
    $splitSuffix = (($incrementalLines[3..($incrementalLines.Count - 1)] -join "`n") + "`n")
    [IO.File]::AppendAllText($splitPath, $splitSuffix, (New-Object Text.UTF8Encoding($false)))
    $incrementalSplit = Get-CompatibilityIndexedAggregateSplit -Path $splitPath `
        -SplitOffset $splitOffset -SessionId '91000000-0000-0000-0000-000000000011'
    Assert-UsageCompatibilityEqual 3 $incrementalOnePass.CountedEvents 'one-pass incremental count'
    Assert-UsageCompatibilityEqual 136 $incrementalOnePass.TotalInput 'one-pass incremental baseline/reset input'
    Assert-UsageCompatibilityEqual 16 $incrementalOnePass.TotalCached 'one-pass incremental baseline/reset cache'
    Assert-UsageCompatibilityEqual 32 $incrementalOnePass.TotalOutput 'one-pass incremental baseline/reset output'
    foreach ($propertyName in @('CountedEvents', 'TotalInput', 'TotalCached', 'TotalOutput', 'TotalReasoning', 'CacheCreationTokens', 'LongContextEvents', 'StandardContextInput')) {
        Assert-UsageCompatibilityEqual $incrementalOnePass.$propertyName $incrementalSplit.$propertyName `
            ('split import matches one-pass for ' + $propertyName)
    }

    # The two ecosystems expose different cache-write field families.  Check
    # zero precedence independently on the identical records and keep the
    # resulting token totals separate: local pricing treats writes as a subset
    # of uncached input, while Tracker normalizes cache_creation_input_tokens
    # into its usage signature.
    $cachePath = Join-Path $tempRoot 'cache-write-aliases.jsonl'
    $cachePublic1 = [ordered]@{ cache_creation_input_tokens = 0L; cache_write_input_tokens = 17L }
    $cachePublic2 = [ordered]@{ cache_write_input_tokens = 19L }
    $cachePublic3 = [ordered]@{ cache_creation_input_tokens = 0L; cache_write_input_tokens = 23L }
    $cachePublic4 = [ordered]@{ cache_creation_input_tokens = 21L; cache_write_input_tokens = 25L }
    $cacheLines = @(
        $modelContext,
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:04:01Z' `
            -Total (New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20 -Aliases $cachePublic1) `
            -Last (New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20 -Aliases ([ordered]@{
                cache_creation_tokens = 0L
                cache_write_tokens = 7L
                cache_creation_input_tokens = 0L
                cache_write_input_tokens = 17L
            }))),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:04:02Z' `
            -Total (New-CompatibilityUsage -InputTokens 160 -CachedTokens 20 -OutputTokens 40 -Aliases $cachePublic2) `
            -Last (New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20 -Aliases ([ordered]@{
                cache_write_tokens = 9L
                cache_write_input_tokens = 19L
            }))),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:04:03Z' `
            -Total (New-CompatibilityUsage -InputTokens 240 -CachedTokens 30 -OutputTokens 60 -Aliases $cachePublic3) `
            -Last (New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20 -Aliases ([ordered]@{
                cache_creation_tokens = 11L
                cache_write_tokens = 13L
                cache_creation_input_tokens = 0L
                cache_write_input_tokens = 23L
            }))),
        (New-CompatibilityTokenLine -Timestamp '2026-09-01T00:04:04Z' `
            -Total (New-CompatibilityUsage -InputTokens 320 -CachedTokens 40 -OutputTokens 80 -Aliases $cachePublic4) `
            -Last (New-CompatibilityUsage -InputTokens 80 -CachedTokens 10 -OutputTokens 20 -Aliases ([ordered]@{
                cache_write_tokens = 15L
                cache_creation_input_tokens = 21L
                cache_write_input_tokens = 25L
            })))
    )
    Write-CompatibilityJsonl -Path $cachePath -Lines $cacheLines
    $cacheTracker = Get-CompatibilityTrackerDeltas -JsonlPath $cachePath -FixturePath $fixturePath
    $cacheTrackerAggregate = Get-CompatibilityAggregate -TrackerResult $cacheTracker
    Assert-UsageCompatibilityEqual 40 $cacheTrackerAggregate.CacheCreationInput 'Tracker cache-write aliases use zero-before-fallback precedence'
    $cacheLegacy = Get-CompatibilityLegacyCacheCreation -Path $cachePath
    Assert-UsageCompatibilityEqual 35 $cacheLegacy.CacheCreationTokens 'legacy cache-write aliases use zero-before-fallback precedence'
    $cacheIndexed = Get-CompatibilityIndexedAggregate -Path $cachePath -SessionId '91000000-0000-0000-0000-000000000005'
    Assert-UsageCompatibilityEqual 35 $cacheIndexed.CacheCreationTokens 'compiled cache-write aliases use zero-before-fallback precedence'
    Assert-UsageCompatibility ([bool]$cacheIndexed.CacheWriteObservable) 'compiled cache-write aliases remain observable'
    [void]$intentionalDifferences.Add('Tracker and local TokenRader use different cache-write alias families; cache dollars are compared only within each implementation.')

    # Cache creation/write tokens are a subset of uncached input.  They must be
    # priced once at the write multiplier and removed from ordinary input, not
    # added on top of the full uncached amount.
    $costUsage = [pscustomobject]@{
        Input = 1000L
        Cached = 100L
        Uncached = 900L
        Output = 100L
        ReasoningOutput = 0L
        Total = 1100L
        CacheHitRate = 10.0
    }
    $cost = Get-TokenRaderCost -Usage $costUsage -Model 'gpt-5.6-sol' -PricingDocument $prices -Scope call `
        -CacheCreationTokens 400 -CacheWriteObservable $true
    Assert-UsageCompatibilityNear 0.002 ([double]$cost.CacheCreationCost) 0.0000000001 'cache creation cost is charged once'
    Assert-UsageCompatibilityNear 0.00604 ([double]$cost.TotalCost) 0.0000000001 'cache creation is not double counted in ordinary input cost'

    Write-Output ('USAGE_COMPATIBILITY_TESTS_PASSED intentional_differences={0}' -f $intentionalDifferences.Count)
    foreach ($difference in $intentionalDifferences) { Write-Output ('  EXPECTED_DIFFERENCE: ' + $difference) }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolved = (Resolve-Path -LiteralPath $tempRoot).Path
        $tempResolved = (Resolve-Path -LiteralPath $env:TEMP).Path
        if ($resolved.StartsWith($tempResolved, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}
