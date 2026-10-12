Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $projectRoot 'TokenRader.Core.psm1'
$pricingPath = Join-Path $projectRoot 'pricing.json'
$module = Import-Module -Name $corePath -Force -PassThru

function Assert-SubscriptionReference {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('SUBSCRIPTION REFERENCE TEST FAILED: ' + $Message) }
}

function Assert-SubscriptionNear {
    param([double]$Expected, [double]$Actual, [string]$Message, [double]$Tolerance = 0.000000001)
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw ('SUBSCRIPTION REFERENCE TEST FAILED: {0}; expected=[{1:R}] actual=[{2:R}]' -f $Message, $Expected, $Actual)
    }
}

function New-SubscriptionUsage {
    param([Int64]$InputTokens, [Int64]$CachedTokens, [Int64]$OutputTokens)
    [pscustomobject]@{
        Input = $InputTokens; Cached = $CachedTokens; Uncached = $InputTokens - $CachedTokens
        Output = $OutputTokens; Total = $InputTokens + $OutputTokens; ReasoningOutput = [Int64]0
    }
}

function New-SubscriptionTokenRecord {
    param(
        [string]$Timestamp, [Int64]$TotalInput, [Int64]$TotalCached, [Int64]$TotalOutput,
        [Int64]$CallInput, [Int64]$CallCached, [Int64]$CallOutput, [Int64]$CacheCreationTokens = 0
    )
    [ordered]@{
        timestamp = $Timestamp
        type = 'event_msg'
        payload = [ordered]@{
            type = 'token_count'
            info = [ordered]@{
                total_token_usage = [ordered]@{
                    input_tokens = $TotalInput; cached_input_tokens = $TotalCached
                    output_tokens = $TotalOutput; reasoning_output_tokens = 0
                    total_tokens = $TotalInput + $TotalOutput
                }
                last_token_usage = [ordered]@{
                    input_tokens = $CallInput; cached_input_tokens = $CallCached
                    output_tokens = $CallOutput; reasoning_output_tokens = 0
                    total_tokens = $CallInput + $CallOutput
                    cache_creation_input_tokens = $CacheCreationTokens
                }
                model_context_window = 1050000
            }
        }
    }
}

function Write-SubscriptionSession {
    param([string]$Path, [string]$SessionId, [string]$ProjectPath, [string]$ParentId = '', [object[]]$TokenRecords)
    $records = [System.Collections.Generic.List[object]]::new()
    $meta = [ordered]@{
        timestamp = '2026-10-12T11:59:59Z'
        type = 'session_meta'
        payload = [ordered]@{ id = $SessionId; cwd = $ProjectPath; model_provider = 'openai' }
    }
    if (-not [string]::IsNullOrWhiteSpace($ParentId)) {
        $meta.payload['parent_thread_id'] = $ParentId
        $meta.payload['forked_from_id'] = $ParentId
    }
    $records.Add($meta)
    $records.Add([ordered]@{
        timestamp = '2026-10-12T12:00:00Z'
        type = 'turn_context'
        payload = [ordered]@{ model = 'gpt-6.1-sol'; service_tier = 'priority' }
    })
    foreach ($record in @($TokenRecords)) { $records.Add($record) }
    $lines = @($records | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 14 -Compress })
    [IO.File]::WriteAllLines($Path, [string[]]$lines, [Text.UTF8Encoding]::new($false))
}

function Copy-SubscriptionObject {
    param($Value)
    return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 40 -Compress)
}

function Get-SubscriptionPricingCacheKey {
    param($PricingDocument, $CoreModule)
    return & $CoreModule { param($p) Get-TokenRaderPricingCacheKey -PricingDocument $p } $PricingDocument
}

$raw = Get-TokenRaderPrices -PricingPath $pricingPath
$subscription = Get-TokenRaderPrices -PricingPath $pricingPath -SubscriptionReference
Assert-SubscriptionReference ($subscription.PricingBasis -eq 'subscription_reference_v1') 'projected document declares its independent basis'
Assert-SubscriptionReference ($subscription.QuotaPricingBasis -eq 'plan_standard_api_reference') 'projected document remains usable for quota evidence'
Assert-SubscriptionReference ($null -eq $raw.PSObject.Properties['PricingBasis']) 'default pricing load preserves the raw API document shape'

$rawSol = Resolve-TokenRaderPrice -Model 'gpt-6.1-sol' -PricingDocument $raw
$refSol = Resolve-TokenRaderPrice -Model 'gpt-6.1-sol' -PricingDocument $subscription
$rawAstra = Resolve-TokenRaderPrice -Model 'gpt-6-astra' -PricingDocument $raw
$refAstra = Resolve-TokenRaderPrice -Model 'gpt-6-astra' -PricingDocument $subscription
Assert-SubscriptionReference ($null -ne $rawSol -and $null -ne $refSol -and $null -ne $refAstra) 'synthetic price models resolve'
Assert-SubscriptionReference ($refSol.PricingBasis -eq 'subscription_reference_v1' -and $refAstra.PricingBasis -eq 'subscription_reference_v1') 'each projected model is basis-tagged'
Assert-SubscriptionNear ([double]$rawSol.input) ([double]$refSol.input) 'base reference input remains ordinary API valuation'
Assert-SubscriptionNear ([double]$rawSol.cachedInput) ([double]$refSol.cachedInput) 'base reference cached input remains ordinary API valuation'
Assert-SubscriptionNear ([double]$rawSol.output) ([double]$refSol.output) 'base reference output remains ordinary API valuation'
Assert-SubscriptionReference ([Int64]$refSol.longContextThreshold -eq 0 -and [double]$refSol.longContextInputMultiplier -eq 1 -and [double]$refSol.longContextOutputMultiplier -eq 1) 'projected context rates are flat'
Assert-SubscriptionNear ([double]$refSol.input) ([double]$refSol.cacheWrite) 'reference cache writes use ordinary input price'
Assert-SubscriptionNear 2.5 ([double]$refSol.serviceTiers.priority.referenceModeMultiplier) 'GPT-6.1 Sol Fast multiplier is explicit 2.5x'
Assert-SubscriptionNear 8.0 ([double]$refSol.serviceTiers.ultrafast.referenceModeMultiplier) 'GPT-6.1 Sol Ultrafast multiplier is explicit 8x'
Assert-SubscriptionReference ([double]$rawSol.serviceTiers.priority.input -gt [double]$rawSol.input) 'raw API Fast rate remains independent from the projected reference'
Assert-SubscriptionReference ($null -eq $rawSol.serviceTiers.PSObject.Properties['ultrafast']) 'raw API pricing did not acquire subscription-only Ultrafast'
Assert-SubscriptionNear 2.5 ([double]$refAstra.serviceTiers.priority.referenceModeMultiplier) 'Astra Fast multiplier is explicit 2.5x'
Assert-SubscriptionNear 8.0 ([double]$refAstra.serviceTiers.ultrafast.referenceModeMultiplier) 'Astra Ultrafast multiplier is explicit 8x'

$usage = New-SubscriptionUsage -InputTokens 300000 -CachedTokens 100000 -OutputTokens 20000
$rawFlat = Get-TokenRaderCost -Usage $usage -Model 'gpt-6.1-sol' -PricingDocument $raw -Scope call -ServiceTier default -LongContextApplied $false
$refLong = Get-TokenRaderCost -Usage $usage -Model 'gpt-6.1-sol' -PricingDocument $subscription -Scope call -ServiceTier default -LongContextApplied $true -CacheCreationTokens 50000 -CacheWriteObservable $true
$expectedFlat = (([double]$usage.Uncached * [double]$refSol.input) + ([double]$usage.Cached * [double]$refSol.cachedInput) + ([double]$usage.Output * [double]$refSol.output)) / 1000000.0
Assert-SubscriptionReference ([bool]$refLong.Known -and [string]$refLong.PricingBasis -eq 'subscription_reference_v1') 'projected long-context call remains priced'
Assert-SubscriptionNear $expectedFlat ([double]$refLong.TotalCost) 'persisted LongContextApplied true cannot restore API long-context premium'
Assert-SubscriptionReference (-not [bool]$refLong.LongContextApplied) 'projected cost does not relabel persisted API long-context classification as a surcharge'
Assert-SubscriptionNear 1.0 ([double]$refLong.InputMultiplier) 'persisted flag cannot change projected input multiplier'
Assert-SubscriptionNear 1.0 ([double]$refLong.OutputMultiplier) 'persisted flag cannot change projected output multiplier'
Assert-SubscriptionNear ((50000.0 * [double]$refSol.input) / 1000000.0) ([double]$refLong.CacheCreationCost) 'projected cache-write subset costs the ordinary input rate'
$atThresholdUsage = New-SubscriptionUsage -InputTokens 272000 -CachedTokens 100000 -OutputTokens 20000
$aboveThresholdUsage = New-SubscriptionUsage -InputTokens 272001 -CachedTokens 100000 -OutputTokens 20000
$atThreshold = Get-TokenRaderCost -Usage $atThresholdUsage -Model 'gpt-6.1-sol' -PricingDocument $subscription -Scope call -ServiceTier default -LongContextApplied $false
$aboveThreshold = Get-TokenRaderCost -Usage $aboveThresholdUsage -Model 'gpt-6.1-sol' -PricingDocument $subscription -Scope call -ServiceTier default -LongContextApplied $true
Assert-SubscriptionNear 0.000002 ([double]$aboveThreshold.TotalCost - [double]$atThreshold.TotalCost) '272001st input token adds one flat token rate, not a context premium'

$refFast = Get-TokenRaderCost -Usage $usage -Model 'gpt-6.1-sol' -PricingDocument $subscription -Scope call -ServiceTier fast -LongContextApplied $true -CacheCreationTokens 50000 -CacheWriteObservable $true
Assert-SubscriptionReference ([bool]$refFast.Known -and [string]$refFast.ServiceTier -eq 'priority') 'Fast alias resolves to projected Fast tier'
Assert-SubscriptionNear ($expectedFlat * 2.5) ([double]$refFast.TotalCost) 'Fast is exactly 2.5x of flat reference without cache-write premium'
$apiFast = Get-TokenRaderCost -Usage $usage -Model 'gpt-6.1-sol' -PricingDocument $raw -Scope call -ServiceTier fast -LongContextApplied $true -CacheCreationTokens 50000 -CacheWriteObservable $true
$rawFastPrice = $rawSol.serviceTiers.priority
$expectedApiFast = ((150000.0 * [double]$rawFastPrice.input) + (50000.0 * [double]$rawFastPrice.cacheWrite)) * 2.0 / 1000000.0 +
    (100000.0 * [double]$rawFastPrice.cachedInput) * 2.0 / 1000000.0 + (20000.0 * [double]$rawFastPrice.output) * 1.5 / 1000000.0
Assert-SubscriptionNear $expectedApiFast ([double]$apiFast.TotalCost) 'default raw pricing keeps published API Fast and long-context/cache-write rates'
Assert-SubscriptionReference ([double]$apiFast.TotalCost -ne [double]$refFast.TotalCost) 'subscription reference does not overwrite API billing semantics'

$planFast = Get-TokenRaderPlanNormalizedCost -Usage $usage -Model 'gpt-6.1-sol' -PricingDocument $subscription -ServiceTier fast -LongContextApplied $true
Assert-SubscriptionReference ([bool]$planFast.Known -and [string]$planFast.PricingBasis -eq 'subscription_reference_v1') 'plan-normalized compatibility result uses the projection'
Assert-SubscriptionNear ([double]$refFast.TotalCost) ([double]$planFast.TotalCost) 'plan-normalized path does not multiply projected Fast twice'
Assert-SubscriptionNear 2.5 ([double]$planFast.Multiplier) 'informational Fast multiplier stays 2.5x'

$smallUsage = New-SubscriptionUsage -InputTokens 100000 -CachedTokens 25000 -OutputTokens 10000
foreach ($modelId in @('gpt-6-astra','gpt-6-sol','gpt-6-luna','gpt-6.1-sol','gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna','gpt-5.5','gpt-5.4')) {
    $expectedFactor = if ($modelId -eq 'gpt-5.4') { 2.0 } else { 2.5 }
    $standard = Get-TokenRaderCost -Usage $smallUsage -Model $modelId -PricingDocument $subscription -Scope call -ServiceTier default -LongContextApplied $false
    $fast = Get-TokenRaderCost -Usage $smallUsage -Model $modelId -PricingDocument $subscription -Scope call -ServiceTier priority -LongContextApplied $false
    Assert-SubscriptionReference ([bool]$standard.Known -and [bool]$fast.Known) ('standard/Fast pricing known for ' + $modelId)
    Assert-SubscriptionNear ($standard.TotalCost * $expectedFactor) ([double]$fast.TotalCost) ($modelId + ' exact Fast reference factor')
}
$astraFast = Get-TokenRaderCost -Usage $smallUsage -Model 'gpt-6-astra' -PricingDocument $subscription -Scope call -ServiceTier priority
$astraUltra = Get-TokenRaderCost -Usage $smallUsage -Model 'gpt-6-astra' -PricingDocument $subscription -Scope call -ServiceTier ultrafast
$solUltra = Get-TokenRaderCost -Usage $smallUsage -Model 'gpt-6.1-sol' -PricingDocument $subscription -Scope call -ServiceTier ultrafast
$solStandard = Get-TokenRaderCost -Usage $smallUsage -Model 'gpt-6.1-sol' -PricingDocument $subscription -Scope call -ServiceTier default
$unknownUltra = Get-TokenRaderCost -Usage $smallUsage -Model 'gpt-6-sol' -PricingDocument $subscription -Scope call -ServiceTier ultrafast
$unknownModel = Get-TokenRaderCost -Usage $smallUsage -Model 'gpt-6.2-sol' -PricingDocument $subscription -Scope call -ServiceTier default
Assert-SubscriptionReference ([bool]$astraFast.Known -and [bool]$astraUltra.Known -and [bool]$solUltra.Known) 'only explicit Astra/Sol 6.1 Ultrafast references resolve'
Assert-SubscriptionNear ([double]$astraFast.TotalCost * (8.0 / 2.5)) ([double]$astraUltra.TotalCost) 'Astra Ultrafast is 8x Standard, not Fast times another 8x'
Assert-SubscriptionNear ([double]$solStandard.TotalCost * 8.0) ([double]$solUltra.TotalCost) 'GPT-6.1 Sol Ultrafast is exactly 8x Standard'
Assert-SubscriptionReference (-not [bool]$unknownUltra.Known) 'Ultrafast is not inferred for another GPT-6 model'
Assert-SubscriptionReference (-not [bool]$unknownModel.Known -and [string]$unknownModel.PricingReason -eq 'unknown_model') 'unknown model is not guessed'

$partialAggregate = [pscustomobject]@{
    Buckets = @(
        [pscustomobject]@{ Model='gpt-6.1-sol'; ServiceTier='priority'; Input=100000L; Cached=25000L; Output=10000L; Reasoning=0L; Events=1L; LongContext=$false; CacheCreationTokens=0L; CacheWriteObservable=$true; RequestInputObservable=$true; LongContextPricingUncertain=$false; ModelContextWindow=1050000L; ServiceTierSource='response'; ServiceTierEvidenceComplete=$true },
        [pscustomobject]@{ Model='gpt-6-sol'; ServiceTier='ultrafast'; Input=200000L; Cached=0L; Output=20000L; Reasoning=0L; Events=1L; LongContext=$false; CacheCreationTokens=0L; CacheWriteObservable=$true; RequestInputObservable=$true; LongContextPricingUncertain=$false; ModelContextWindow=1050000L; ServiceTierSource='response'; ServiceTierEvidenceComplete=$true }
    )
    Models = @('gpt-6.1-sol','gpt-6-sol')
    TotalInput = 300000L; TotalCached = 25000L; TotalOutput = 30000L; TotalReasoning = 0L
}
$partial = & $module { param($a,$p) ConvertFrom-TokenRaderPricedAggregate -Aggregate $a -PricingDocument $p } $partialAggregate $subscription
Assert-SubscriptionReference (-not [bool]$partial.PricingComplete -and -not [bool]$partial.PlanPricingComplete) 'one unsupported mode keeps mixed pricing explicitly partial'
Assert-SubscriptionReference ([bool]$partial.Items[0].Cost.Known -and -not [bool]$partial.Items[1].Cost.Known) 'unsupported tier does not erase the known model amount or become free'
Assert-SubscriptionReference ($partial.UnknownModels -contains 'gpt-6-sol') 'partial diagnostic names the unsupported model'

$rawKey = Get-SubscriptionPricingCacheKey -PricingDocument $raw -CoreModule $module
$subscriptionKey = Get-SubscriptionPricingCacheKey -PricingDocument $subscription -CoreModule $module
Assert-SubscriptionReference ($rawKey -ne $subscriptionKey) 'raw API and projected subscription caches are separate'
$changedProjection = Copy-SubscriptionObject $subscription
$changedSol = Resolve-TokenRaderPrice -Model 'gpt-6.1-sol' -PricingDocument $changedProjection
$changedSol.serviceTiers.priority.input = [double]$changedSol.serviceTiers.priority.input + 0.01
$changedRateKey = Get-SubscriptionPricingCacheKey -PricingDocument $changedProjection -CoreModule $module
Assert-SubscriptionReference ($subscriptionKey -ne $changedRateKey) 'cache key changes when a projected rate changes'
$changedVerification = Copy-SubscriptionObject $subscription
$changedVerifiedSol = Resolve-TokenRaderPrice -Model 'gpt-6.1-sol' -PricingDocument $changedVerification
$changedVerifiedSol.verifiedAt = '2099-01-01'
$changedVerificationKey = Get-SubscriptionPricingCacheKey -PricingDocument $changedVerification -CoreModule $module
Assert-SubscriptionReference ($subscriptionKey -ne $changedVerificationKey) 'cache key changes when per-model reference verification changes'

# A single synthetic parent/child log tree exercises the same projected prices
# through interval, project, history and Explorer queries. Child copied history
# must still be removed before any of those views sum its dollar amount.
if (-not (Initialize-TokenRaderIndexer)) { throw 'Indexer unavailable; build the project before running this test.' }
$oldDbPath = $env:TOKEN_RADER_INDEX_DB
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-SubscriptionReference-' + [Guid]::NewGuid().ToString('N'))
$sessionsRoot = Join-Path $tempRoot 'sessions'
$dbPath = Join-Path $tempRoot 'data\private\main.db'
$projectPath = Join-Path $tempRoot 'Synthetic Project'
$anchor = [DateTimeOffset]::Parse('2026-10-13T00:00:00Z')
$parentId = '10000000-0000-0000-0000-000000000001'
$childId = '20000000-0000-0000-0000-000000000001'
$parentPath = Join-Path $sessionsRoot ('rollout-' + $parentId + '.jsonl')
$childPath = Join-Path $sessionsRoot ('rollout-' + $childId + '.jsonl')

try {
    [void][IO.Directory]::CreateDirectory($sessionsRoot)
    [void][IO.Directory]::CreateDirectory($projectPath)
    $firstCall = New-SubscriptionTokenRecord -Timestamp '2026-10-12T12:00:01Z' -TotalInput 300000 -TotalCached 100000 -TotalOutput 20000 -CallInput 300000 -CallCached 100000 -CallOutput 20000 -CacheCreationTokens 50000
    $secondCall = New-SubscriptionTokenRecord -Timestamp '2026-10-12T12:00:30Z' -TotalInput 310000 -TotalCached 100000 -TotalOutput 20050 -CallInput 10000 -CallCached 0 -CallOutput 50
    Write-SubscriptionSession -Path $parentPath -SessionId $parentId -ProjectPath $projectPath -TokenRecords @($firstCall)
    $copiedParentCall = New-SubscriptionTokenRecord -Timestamp '2026-10-12T12:00:10Z' -TotalInput 300000 -TotalCached 100000 -TotalOutput 20000 -CallInput 300000 -CallCached 100000 -CallOutput 20000 -CacheCreationTokens 50000
    Write-SubscriptionSession -Path $childPath -SessionId $childId -ProjectPath $projectPath -ParentId $parentId -TokenRecords @($copiedParentCall, $secondCall)
    $pricingCopyPath = Join-Path $tempRoot 'pricing.json'
    Copy-Item -LiteralPath $pricingPath -Destination $pricingCopyPath

    Close-TokenRaderIndex
    $env:TOKEN_RADER_INDEX_DB = $dbPath
    New-TokenRaderIndex -SessionsRoot $sessionsRoot -Force | Out-Null

    $endOffsets = @{}
    $endOffsets[$parentPath] = [Int64](Get-Item -LiteralPath $parentPath).Length
    $endOffsets[$childPath] = [Int64](Get-Item -LiteralPath $childPath).Length
    $baseline = [pscustomobject]@{
        StartedAt = [DateTimeOffset]::MinValue; SessionsRoot = $sessionsRoot; StartOffsets = @{}
        Files = @(); RateLimits = $null; StartRateLimits = $null
    }
    $interval = Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $subscription -EndOffsets $endOffsets -EndedAt $anchor -ScanRateLimits:$false
    Assert-SubscriptionReference ([bool]$interval.PricingComplete) 'projected interval remains fully priced'
    Assert-SubscriptionReference ([Int64]$interval.CountedEvents -eq 2L) 'interval still counts unique parent/child calls only'
    Assert-SubscriptionReference ([Int64]$interval.DuplicateEventsDropped -ge 1L) 'interval reports copied parent call deduplication'
    Assert-SubscriptionReference ([Int64]$interval.Usage.Input -eq 310000L) 'interval usage preserves parent/child deduplication'
    $indexConnection = (Get-TokenRaderIndex).Connection
    $contextCommand = $indexConnection.CreateCommand()
    try {
        $contextCommand.CommandText = 'SELECT long_context_applied FROM token_records WHERE source_path=@path AND total_input=300000 LIMIT 1'
        [void]$contextCommand.Parameters.AddWithValue('@path', $parentPath)
        $persistedLongContext = [Int64]$contextCommand.ExecuteScalar()
    } finally { $contextCommand.Dispose() }
    Assert-SubscriptionReference ($persistedLongContext -eq 1L) 'synthetic log persisted the API long-context classification before subscription pricing'
    Assert-SubscriptionNear 1.57625 ([double]$interval.TotalCost) 'indexed interval uses subscription Fast rates once with flat context/cache writes'
    Assert-SubscriptionNear ([double]$interval.TotalCost) ([double]$interval.PlanNormalizedTotalCost) 'indexed plan-normalized reference does not double multiply projected prices'

    $project = [pscustomobject]@{ FilePaths = @($parentPath, $childPath); ProjectPath = $projectPath; ProjectName = 'Synthetic Project' }
    $projectResult = Get-TokenRaderProjectResult -Project $project -SessionsRoot $sessionsRoot -PricingDocument $subscription
    Assert-SubscriptionReference ([Int64]$projectResult.CountedEvents -eq 2L -and [Int64]$projectResult.DuplicateEventsDropped -ge 1L) 'project view preserves parent/child deduplication'
    Assert-SubscriptionNear ([double]$interval.TotalCost) ([double]$projectResult.TotalCost) 'project and interval use the same projected dollars'

    $history = Get-TokenRaderUsageHistoryWindow -SessionsRoot $sessionsRoot -PricingDocument $subscription -AnchorAt $anchor -ForceRefresh
    Assert-SubscriptionReference ([bool]$history.PricingComplete -and [Int64]$history.CountedEvents -eq 2L) 'history view retains complete deduplicated usage'
    Assert-SubscriptionNear ([double]$interval.TotalCost) ([double]$history.TotalCost) 'history uses the same subscription reference cost'

    Import-Module (Join-Path $projectRoot 'TokenRader.Explorer.psm1') -Force
    $explorerPaths = [pscustomobject]@{
        MainIndexPath = $dbPath; ExplorerIndexPath = (Join-Path $tempRoot 'explorer\index.db')
        SessionsRoot = $sessionsRoot; PricingPath = $pricingCopyPath
    }
    $backfill = Update-TokenRaderExplorerIndex -ProjectRoot $tempRoot -Paths $explorerPaths
    Assert-SubscriptionReference ([bool]$backfill.SyncComplete -and [Int64]$backfill.ImportedRecords -ge 3L) 'isolated synthetic Explorer index loaded the same fixture'
    $explorerResult = Get-TokenRaderExplorerResult -ProjectRoot $tempRoot -Paths $explorerPaths -ProjectPath $projectPath `
        -StartAt ([DateTimeOffset]::Parse('2026-10-12T00:00:00Z')) -EndAt ([DateTimeOffset]::Parse('2026-10-13T00:00:00Z'))
    Assert-SubscriptionReference ([Int64]$explorerResult.Count -eq 2L -and [Int64]$explorerResult.DuplicateEventsDropped -ge 1L) 'Explorer still deduplicates copied parent events'
    Assert-SubscriptionNear ([double]$interval.TotalCost) ([double]$explorerResult.TotalCost) 'Explorer uses the same projected USD reference'

    Write-Output 'SUBSCRIPTION_REFERENCE_TESTS_PASSED'
} finally {
    try { Close-TokenRaderIndex } catch { }
    if ($null -eq $oldDbPath) { Remove-Item Env:\TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue }
    else { $env:TOKEN_RADER_INDEX_DB = $oldDbPath }
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $resolvedTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\', [char]'/') + [IO.Path]::DirectorySeparatorChar
    if ($resolvedTemp.StartsWith($resolvedTempParent, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemp).StartsWith('TokenRader-SubscriptionReference-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
