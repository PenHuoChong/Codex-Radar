[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PlanPricing {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('PLAN PRICING TEST FAILED: ' + $Message) }
}

function Assert-PlanPricingNear {
    param(
        [double]$Expected,
        [double]$Actual,
        [double]$Tolerance = 0.000000001,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw ('PLAN PRICING TEST FAILED: {0}; expected=[{1}] actual=[{2}]' -f $Message, $Expected, $Actual)
    }
}

function New-PlanPricingModel {
    param([string]$Id, [double]$InputRate, [double]$CachedRate, [double]$OutputRate)
    [pscustomobject]@{
        id = $Id; aliases = @(); input = $InputRate; cachedInput = $CachedRate; output = $OutputRate
        contextWindow = 1050000; longContextThreshold = 272000
        longContextInputMultiplier = 2.0; longContextOutputMultiplier = 1.5
        serviceTiers = [pscustomobject]@{
            priority = [pscustomobject]@{
                input = $InputRate * 2.0; cachedInput = $CachedRate * 2.0
                cacheWrite = $InputRate * 2.5; output = $OutputRate * 2.0
                longContextThreshold = 272000; longContextInputMultiplier = 2.0; longContextOutputMultiplier = 1.5
            }
        }
    }
}

function New-PlanPricingDocument {
    $fast = [ordered]@{
        'gpt-6-astra' = 2.5; 'gpt-6-sol' = 2.5; 'gpt-6-luna' = 2.5
        'gpt-5.6-sol' = 2.5; 'gpt-5.6-terra' = 2.5; 'gpt-5.6-luna' = 2.5
        'gpt-5.5' = 2.5; 'gpt-5.4' = 2.0
    }
    $raw = [ordered]@{
        currency = 'USD'; unitTokens = 1000000; verifiedAt = 'synthetic'
        QuotaPricingBasis = 'plan_standard_api_reference'
        subscriptionPricing = [ordered]@{
            basis = 'standard_api_normalized_reference'; cacheWritePremium = $false
            fastMultipliers = $fast
        }
        ManualServiceTiers = [ordered]@{ 'gpt-6-astra' = 'default'; 'gpt-6-sol' = 'priority' }
        models = @(
            (New-PlanPricingModel 'gpt-6-astra' 10.0 1.0 50.0),
            (New-PlanPricingModel 'gpt-6-sol' 2.0 0.2 10.0),
            (New-PlanPricingModel 'gpt-6-luna' 0.1 0.01 0.5),
            (New-PlanPricingModel 'gpt-5.6-sol' 2.0 0.2 10.0),
            (New-PlanPricingModel 'gpt-5.6-terra' 2.0 0.2 10.0),
            (New-PlanPricingModel 'gpt-5.6-luna' 0.1 0.01 0.5),
            (New-PlanPricingModel 'gpt-5.5' 2.0 0.2 10.0),
            (New-PlanPricingModel 'gpt-5.4' 2.0 0.2 10.0)
        )
    }
    return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $raw -Depth 20 -Compress)
}

function New-PlanPricingAggregateBucket {
    param(
        [string]$Model, [string]$ServiceTier, [long]$InputTokens = 1000000,
        [long]$CachedTokens = 200000, [long]$OutputTokens = 100000,
        [long]$CacheCreationTokens = 0, [string]$ServiceTierSource = 'response',
        [bool]$ServiceTierEvidenceComplete = $true
    )
    [pscustomobject]@{
        Model = $Model; ServiceTier = $ServiceTier; Input = $InputTokens; Cached = $CachedTokens
        Output = $OutputTokens; Reasoning = 0L; Events = 1L; LongContext = $false
        CacheCreationTokens = $CacheCreationTokens; CacheWriteObservable = $true
        RequestInputObservable = $true; LongContextPricingUncertain = $false
        ModelContextWindow = 1050000L; ServiceTierSource = $ServiceTierSource
        ServiceTierEvidenceComplete = $ServiceTierEvidenceComplete
    }
}

function Test-PlanPricingFinite {
    param($Value, [string]$Label)
    if ($null -eq $Value) { return }
    [double]$number = 0
    Assert-PlanPricing ([double]::TryParse([string]$Value, [ref]$number) -and
        -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)) ($Label + ' is finite')
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$coreModule = Get-Module TokenRader.Core
$pricing = New-PlanPricingDocument
$usage = [pscustomobject]@{ Input = 1000000L; Cached = 200000L; Uncached = 800000L; Output = 100000L; Total = 1100000L; ReasoningOutput = 0L }
$astra = Resolve-TokenRaderPrice -Model 'gpt-6-astra' -PricingDocument $pricing

# Plan reference always starts from Standard API rates. Cache-creation tokens
# are not a separate subscription premium; the existing API path still applies
# its ordinary published Fast/API rates without being rewritten by this mode.
$planFast = Get-TokenRaderPlanNormalizedCost -Usage $usage -Model 'gpt-6-astra' `
    -PricingDocument $pricing -ServiceTier 'priority' -LongContextApplied $false -ResolvedPrice $astra
Assert-PlanPricing ([bool]$planFast.Known) 'Astra Fast plan reference is known'
Assert-PlanPricingNear 2.5 ([double]$planFast.Multiplier) -Message 'Astra Fast uses the exact subscription factor'
Assert-PlanPricingNear 33.0 ([double]$planFast.TotalCost) -Message 'Fast reference is Standard API valuation times 2.5 with no cache-write premium'
$apiStandard = Get-TokenRaderCost -Usage $usage -Model 'gpt-6-astra' -PricingDocument $pricing -Scope call -ServiceTier 'default' -LongContextApplied $false -CacheCreationTokens 100000 -CacheWriteObservable $true
$apiFast = Get-TokenRaderCost -Usage $usage -Model 'gpt-6-astra' -PricingDocument $pricing -Scope call -ServiceTier 'priority' -LongContextApplied $false -CacheCreationTokens 100000 -CacheWriteObservable $true
Assert-PlanPricingNear 2.0 ([double]$apiFast.TotalCost / [double]$apiStandard.TotalCost) -Message 'existing API Fast billing remains its published 2x price'
Assert-PlanPricing ([double]$apiFast.TotalCost -ne [double]$planFast.TotalCost) 'plan reference did not overwrite the API cost calculation'

$longUsage = [pscustomobject]@{ Input = 300000L; Cached = 50000L; Uncached = 250000L; Output = 100000L; Total = 400000L; ReasoningOutput = 0L }
$longPlan = Get-TokenRaderPlanNormalizedCost -Usage $longUsage -Model 'gpt-6-astra' `
    -PricingDocument $pricing -ServiceTier 'priority' -LongContextApplied $true -ResolvedPrice $astra
Assert-PlanPricing ([bool]$longPlan.Known -and [bool]$longPlan.LongContextApplied) 'explicit long-context classification is preserved'
Assert-PlanPricingNear 2.0 ([double]$longPlan.InputMultiplier) -Message 'long-context Standard input multiplier is retained'
Assert-PlanPricingNear 1.5 ([double]$longPlan.OutputMultiplier) -Message 'long-context Standard output multiplier is retained'
Assert-PlanPricingNear 2.5 ([double]$longPlan.Multiplier) -Message 'Fast subscription factor is applied after long-context pricing'

# Mixed Astra/Sol/Luna buckets cover explicit Fast over a conflicting manual
# Standard choice and missing-tier manual Fast. Luna remains Standard.
$aggregate = [pscustomobject]@{
    Buckets = @(
        (New-PlanPricingAggregateBucket 'gpt-6-astra' 'priority' -CacheCreationTokens 100000),
        (New-PlanPricingAggregateBucket 'gpt-6-sol' '' -ServiceTierSource 'missing' -ServiceTierEvidenceComplete $false),
        (New-PlanPricingAggregateBucket 'gpt-6-luna' 'default')
    )
    Models = @('gpt-6-astra','gpt-6-sol','gpt-6-luna')
    TotalInput = 3000000L; TotalCached = 600000L; TotalOutput = 300000L; TotalReasoning = 0L
}
$priced = & $coreModule { param($value, $document) ConvertFrom-TokenRaderPricedAggregate -Aggregate $value -PricingDocument $document } $aggregate $pricing
Assert-PlanPricing ([bool]$priced.PlanPricingComplete) 'all mixed model factors are available'
Assert-PlanPricingNear 39.732 ([double]$priced.PlanNormalizedTotalCost) -Message 'mixed Astra/Sol Fast and Luna Standard total'
Test-PlanPricingFinite $priced.PlanNormalizedTotalCost 'mixed plan reference'
Assert-PlanPricingNear 32.312 ([double]$priced.TotalCost) -Message 'main API total is independent of plan pricing'
Assert-PlanPricing ($priced.Items[0].ServiceTier -eq 'priority' -and -not $priced.Items[0].ManualServiceTierApplied) 'explicit Fast wins over manual Standard'
Assert-PlanPricing ($priced.Items[1].ServiceTier -eq 'priority' -and $priced.Items[1].ManualServiceTierApplied) 'manual Fast fills only missing evidence'
Assert-PlanPricing ($priced.Items[2].ServiceTier -eq 'default') 'Luna Standard is not multiplied by Fast factor'

foreach ($model in $pricing.models) {
    $fast = Get-TokenRaderPlanNormalizedCost -Usage $usage -Model $model.id -PricingDocument $pricing -ServiceTier 'fast' -LongContextApplied $false
    $factor = if ($model.id -eq 'gpt-5.4') { 2.0 } else { 2.5 }
    Assert-PlanPricingNear $factor $fast.Multiplier -Message ('exact factor: ' + $model.id)
}
$legacy = New-PlanPricingDocument
$legacy.PSObject.Properties.Remove('QuotaPricingBasis')
$legacyPrice = & $coreModule { param($a,$p) ConvertFrom-TokenRaderPricedAggregate $a $p } $aggregate $legacy
Assert-PlanPricingNear $priced.TotalCost $legacyPrice.TotalCost -Message 'old workers preserve API dollars'
Assert-PlanPricing ($legacyPrice.QuotaPricingBasis -eq 'api_equivalent' -and $null -eq $legacyPrice.PlanNormalizedTotalCost) 'old worker did not opt into plan basis'
$legacyKey = & $coreModule { param($p) Get-TokenRaderPricingCacheKey $p } $legacy
$planKey = & $coreModule { param($p) Get-TokenRaderPricingCacheKey $p } $pricing
Assert-PlanPricing ($legacyKey -ne $planKey) 'cache keys separate API and plan'
$pricing.subscriptionPricing.fastMultipliers.'gpt-6-astra' = 3.0
$changedKey = & $coreModule { param($p) Get-TokenRaderPricingCacheKey $p } $pricing
Assert-PlanPricing ($changedKey -ne $planKey) 'cache invalidates when subscription factor changes'
$legacy.subscriptionPricing.fastMultipliers.'gpt-6-astra' = 3.0
$legacyChangedKey = & $coreModule { param($p) Get-TokenRaderPricingCacheKey $p } $legacy
Assert-PlanPricing ($legacyChangedKey -eq $legacyKey) 'plan metadata does not invalidate running legacy API caches'
$pricing = New-PlanPricingDocument

foreach ($bad in @(0, -1, [double]::NaN, [double]::PositiveInfinity, 'invalid')) {
    $pricing.subscriptionPricing.fastMultipliers.'gpt-6-astra' = $bad
    $rejected = Get-TokenRaderPlanNormalizedCost -Usage $usage -Model 'gpt-6-astra' -PricingDocument $pricing -ServiceTier 'fast' -LongContextApplied $false
    Assert-PlanPricing (-not $rejected.Known -and $null -eq $rejected.TotalCost) 'invalid factor must not invent dollars'
}
$pricing = New-PlanPricingDocument
$pricing.subscriptionPricing.fastMultipliers.PSObject.Properties.Remove('gpt-6-astra')
$partial = & $coreModule { param($a,$p) ConvertFrom-TokenRaderPricedAggregate $a $p } $aggregate $pricing
Assert-PlanPricing (-not $partial.PlanPricingComplete -and $partial.PricingComplete) 'missing plan factor must not change API completeness'
Assert-PlanPricingNear 6.732 $partial.PlanNormalizedTotalCost -Message 'partial reference contains only known plan buckets'
Assert-PlanPricingNear $priced.TotalCost $partial.TotalCost -Message 'missing plan factor preserves API total'
$pricing = New-PlanPricingDocument
$pricing.subscriptionPricing.PSObject.Properties.Remove('basis')
$rejected = Get-TokenRaderPlanNormalizedCost -Usage $usage -Model 'gpt-6-astra' -PricingDocument $pricing -ServiceTier default -LongContextApplied $false
Assert-PlanPricing (-not $rejected.Known) 'malformed metadata handled without strict-mode exception'
$pricing = New-PlanPricingDocument
foreach ($badUnit in @(0, -1, [double]::NaN, [double]::PositiveInfinity)) {
    $pricing.unitTokens = $badUnit
    $rejected = Get-TokenRaderPlanNormalizedCost -Usage $usage -Model 'gpt-6-astra' -PricingDocument $pricing -ServiceTier default -LongContextApplied $false
    Assert-PlanPricing (-not $rejected.Known) 'invalid unit token count rejected'
}
Write-Output 'PLAN_PRICING_TESTS_PASSED'
