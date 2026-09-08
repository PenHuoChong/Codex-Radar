$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$coreModule = Get-Module TokenRader.Core

function Assert-QuotaFix {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERT FAILED: ' + $Message) }
}

function Assert-QuotaFixEqual {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -is [bool] -or $Actual -is [bool]) {
        if ([bool]$Expected -ne [bool]$Actual) { throw ('ASSERT FAILED: {0}; expected=[{1}] actual=[{2}]' -f $Message, $Expected, $Actual) }
        return
    }
    if ([string]$Expected -ne [string]$Actual) { throw ('ASSERT FAILED: {0}; expected=[{1}] actual=[{2}]' -f $Message, $Expected, $Actual) }
}

function Assert-QuotaFixNear {
    param([double]$Expected, [double]$Actual, [double]$Tolerance, [string]$Message)
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw ('ASSERT FAILED: {0}; expected=[{1}] actual=[{2}] tolerance=[{3}]' -f $Message, $Expected, $Actual, $Tolerance)
    }
}

function New-QuotaFixPricing {
    param([hashtable]$ManualServiceTiers = $null)
    $standardAstra = [pscustomobject]@{ input = 1.0; cachedInput = 0.1; output = 2.0 }
    $priorityAstra = [pscustomobject]@{ input = 2.0; cachedInput = 0.2; output = 4.0 }
    $standardLuna = [pscustomobject]@{ input = 0.5; cachedInput = 0.05; output = 1.0 }
    $priorityLuna = [pscustomobject]@{ input = 1.0; cachedInput = 0.1; output = 2.0 }
    $doc = [pscustomobject]@{
        verifiedAt = 'synthetic-quota-fix'
        unitTokens = 1000000
        models = @(
            [pscustomobject]@{
                id = 'synthetic-astra'
                aliases = @('AstraFast')
                input = $standardAstra.input
                cachedInput = $standardAstra.cachedInput
                output = $standardAstra.output
                serviceTiers = [pscustomobject]@{ default = $standardAstra; priority = $priorityAstra }
            }
            [pscustomobject]@{
                id = 'synthetic-luna'
                aliases = @('LunaStandard')
                input = $standardLuna.input
                cachedInput = $standardLuna.cachedInput
                output = $standardLuna.output
                serviceTiers = [pscustomobject]@{ default = $standardLuna; priority = $priorityLuna }
            }
        )
    }
    if ($null -ne $ManualServiceTiers) { $doc | Add-Member -NotePropertyName ManualServiceTiers -NotePropertyValue $ManualServiceTiers }
    return $doc
}

function New-QuotaFixBucket {
    param(
        [string]$Model,
        [string]$ServiceTier = '',
        [string]$ServiceTierSource = 'missing',
        [Int64]$InputTokens = 100000,
        [Int64]$OutputTokens = 10000
    )
    [pscustomobject]@{
        Model = $Model
        ServiceTier = $ServiceTier
        ServiceTierSource = $ServiceTierSource
        ServiceTierObservable = -not [string]::IsNullOrWhiteSpace($ServiceTier)
        LongContext = $false
        Input = $InputTokens
        Cached = [Int64]0
        Output = $OutputTokens
        Reasoning = [Int64]0
        Events = [Int64]1
        CacheCreationTokens = [Int64]0
        ModelContextWindow = [Int64]0
        LongContextThreshold = [Int64]0
        LongContextSource = 'no_threshold'
        CacheWriteObservable = $true
    }
}

function New-QuotaFixAggregate {
    param([object[]]$Buckets)
    $bucketList = @($Buckets)
    [pscustomobject]@{
        Buckets = $bucketList
        Models = @($bucketList | ForEach-Object { [string]$_.Model } | Sort-Object -Unique)
        TotalInput = [Int64](($bucketList | Measure-Object -Property Input -Sum).Sum)
        TotalCached = [Int64]0
        TotalOutput = [Int64](($bucketList | Measure-Object -Property Output -Sum).Sum)
        TotalReasoning = [Int64]0
        IdentityComplete = $true
        IdentitySources = @('request_id')
        UnidentifiedEvents = [Int64]0
        CountedEvents = [Int64]$bucketList.Count
        FirstCountedAt = $null
        LastCountedAt = $null
        ProcessingMilliseconds = [double]0
    }
}

function New-QuotaFixWindow {
    param(
        [double]$UsedPercent,
        [DateTimeOffset]$ObservedAt,
        [DateTimeOffset]$ResetsAt,
        [int]$WindowMinutes = 300,
        [string]$PlanType = 'synthetic',
        [string]$LimitId = 'synthetic-limit'
    )
    [pscustomobject]@{
        UsedPercent = $UsedPercent
        RemainingPercent = 100.0 - $UsedPercent
        WindowMinutes = $WindowMinutes
        ResetsAt = $ResetsAt
        ObservedAt = $ObservedAt
        PlanType = $PlanType
        LimitId = $LimitId
        ResetIdentity = (& $coreModule { param($m, $r) Get-TokenRaderResetIdentity -WindowMinutes $m -ResetsAt $r } $WindowMinutes $ResetsAt)
    }
}

function New-QuotaFixEvidence {
    param(
        [bool]$QuotaEvidenceComplete = $true,
        [bool]$ModeAssumptionApplied = $false,
        [double]$TotalCost = 1.0,
        [double]$EffectiveDeltaPercent = 0.2,
        [DateTimeOffset]$ObservedAt = ([DateTimeOffset]::Parse('2026-09-08T01:00:00Z'))
    )
    [pscustomobject]@{
        BoundaryValid = $true
        EstimateSource = 'snapshot_delta_usd_estimate'
        PricingComplete = $true
        ServiceTierComplete = $QuotaEvidenceComplete
        ModeEvidenceComplete = -not $ModeAssumptionApplied
        ModeAssumptionApplied = $ModeAssumptionApplied
        ManualServiceTierApplied = $ModeAssumptionApplied
        QuotaEvidenceComplete = $QuotaEvidenceComplete
        TotalCost = $TotalCost
        EstimatedTotalUsd = $TotalCost / ($EffectiveDeltaPercent / 100.0)
        EstimatedUsedUsd = 10.0
        EstimatedRemainingUsd = 490.0
        EffectiveDeltaPercent = $EffectiveDeltaPercent
        PercentResolution = 0.1
        StartObservedAt = $ObservedAt.AddMinutes(-1)
        EndObservedAt = $ObservedAt
        CurrentObservedAt = $ObservedAt
        StartUsedPercent = 10.0
        CalibrationEndUsedPercent = 10.0 + $EffectiveDeltaPercent
        FirstCountedAt = $ObservedAt.AddSeconds(-30)
        LastCountedAt = $ObservedAt.AddSeconds(-1)
        WindowMinutes = 300
        ResetsAt = $ObservedAt.AddHours(4)
        ResetIdentity = (& $coreModule { param($m, $r) Get-TokenRaderResetIdentity -WindowMinutes $m -ResetsAt $r } 300 $ObservedAt.AddHours(4))
        CapacitySource = 'percent_delta_tokens'
        TotalTokens = [Int64]0
        UsedTokens = [Int64]0
        RemainingTokens = [Int64]0
        ObservedTokens = [Int64]1000
        IdentityComplete = $true
        IdentitySources = @('request_id')
        UnidentifiedEvents = [Int64]0
        AverageUsdPerToken = 0.001
    }
}

$module = Get-Module TokenRader.Core
$plainPricing = New-QuotaFixPricing
$manualPricing = New-QuotaFixPricing -ManualServiceTiers @{
    'synthetic-astra' = 'priority'
    'synthetic-luna' = 'default'
}

# Manual AstraFast + LunaStandard fills missing mode evidence and is visible
# on every affected item, while preserving the standard cost-completeness API.
$manualAggregate = New-QuotaFixAggregate @(
    (New-QuotaFixBucket -Model 'synthetic-astra')
    (New-QuotaFixBucket -Model 'synthetic-luna')
)
$manualPriced = & $module { param($aggregate, $pricing) ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $pricing } $manualAggregate $manualPricing
Assert-QuotaFixEqual $true $manualPriced.PricingComplete 'manual mode keeps legacy pricing complete'
Assert-QuotaFixEqual $true $manualPriced.ServiceTierComplete 'manual mode completes priced service tiers'
Assert-QuotaFixEqual $false $manualPriced.ModeEvidenceComplete 'manual mode remains an evidence assumption'
Assert-QuotaFixEqual $true $manualPriced.ManualServiceTierApplied 'manual mode assumption is surfaced'
Assert-QuotaFixEqual $true $manualPriced.QuotaEvidenceComplete 'all manually confirmed buckets can produce quota evidence'
Assert-QuotaFixEqual 'priority' $manualPriced.Items[0].ServiceTier 'Astra manual priority tier'
Assert-QuotaFixEqual 'manual_confirmation' $manualPriced.Items[0].ServiceTierSource 'Astra manual source is visible'
Assert-QuotaFixEqual 'default' $manualPriced.Items[1].ServiceTier 'Luna manual standard tier'
Assert-QuotaFixEqual 'manual_confirmation' $manualPriced.Items[1].ServiceTierSource 'Luna manual source is visible'

# Explicit response/service_tier evidence always wins over a conflicting
# manual choice.
$precedencePricing = New-QuotaFixPricing -ManualServiceTiers @{
    'synthetic-astra' = 'priority'
    'synthetic-luna' = 'default'
}
$precedenceAggregate = New-QuotaFixAggregate @(
    (New-QuotaFixBucket -Model 'synthetic-astra' -ServiceTier 'default' -ServiceTierSource 'response')
    (New-QuotaFixBucket -Model 'synthetic-luna' -ServiceTier 'priority' -ServiceTierSource 'service_tier')
)
$precedencePriced = & $module { param($aggregate, $pricing) ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $pricing } $precedenceAggregate $precedencePricing
Assert-QuotaFixEqual 'default' $precedencePriced.Items[0].ServiceTier 'explicit Astra response tier wins'
Assert-QuotaFixEqual 'response' $precedencePriced.Items[0].ServiceTierSource 'explicit Astra source wins'
Assert-QuotaFixEqual 'priority' $precedencePriced.Items[1].ServiceTier 'explicit Luna service tier wins'
Assert-QuotaFixEqual 'service_tier' $precedencePriced.Items[1].ServiceTierSource 'explicit Luna source wins'
Assert-QuotaFixEqual $true $precedencePriced.ModeEvidenceComplete 'explicit tiers complete mode evidence'
Assert-QuotaFixEqual $false $precedencePriced.ManualServiceTierApplied 'explicit tiers do not report manual application'

# An old indexed row whose source was not retained is treated as untrusted;
# manual confirmation may replace it, but an explicit response tier above was
# never replaced.
$indexedAggregate = New-QuotaFixAggregate @(
    (New-QuotaFixBucket -Model 'synthetic-astra' -ServiceTier 'default' -ServiceTierSource 'indexed')
)
$indexedPriced = & $module { param($aggregate, $pricing) ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $pricing } $indexedAggregate $precedencePricing
Assert-QuotaFixEqual 'priority' $indexedPriced.Items[0].ServiceTier 'manual confirmation replaces untrusted indexed tier'
Assert-QuotaFixEqual 'manual_confirmation' $indexedPriced.Items[0].ServiceTierSource 'untrusted indexed tier reports manual source'
Assert-QuotaFixEqual $true $indexedPriced.QuotaEvidenceComplete 'manual confirmation completes untrusted indexed tier'

# Missing mode remains a Standard reference for UI cost display, but it is
# incomplete for strict quota calibration.
$unknownAggregate = New-QuotaFixAggregate @(
    (New-QuotaFixBucket -Model 'synthetic-astra' -ServiceTier '' -ServiceTierSource 'response_null')
)
$unknownPriced = & $module { param($aggregate, $pricing) ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $pricing } $unknownAggregate $plainPricing
Assert-QuotaFixEqual $true $unknownPriced.PricingComplete 'unknown mode retains Standard reference pricing'
Assert-QuotaFixEqual $false $unknownPriced.ServiceTierComplete 'unknown mode is not service-tier complete'
Assert-QuotaFixEqual $false $unknownPriced.ModeEvidenceComplete 'unknown mode lacks evidence'
Assert-QuotaFixEqual $false $unknownPriced.QuotaEvidenceComplete 'unknown mode blocks strict quota evidence'
Assert-QuotaFixEqual 'standard_fallback' $unknownPriced.Items[0].ServiceTierSource 'unknown mode source is Standard fallback'
Assert-QuotaFixEqual $true $unknownPriced.Items[0].Cost.Known 'unknown mode cost remains known as reference'

# A strict evidence object carrying an incomplete mode must not qualify quota,
# while a manual assumption may qualify it and is returned on the card.
$startAt = [DateTimeOffset]::Parse('2026-09-08T00:59:00Z')
$endAt = [DateTimeOffset]::Parse('2026-09-08T01:00:00Z')
$startLimits = [pscustomobject]@{ PlanType = 'synthetic'; FiveHour = New-QuotaFixWindow -UsedPercent 10.0 -ObservedAt $startAt -ResetsAt $endAt.AddHours(4); Weekly = $null }
$endLimits = [pscustomobject]@{ PlanType = 'synthetic'; FiveHour = New-QuotaFixWindow -UsedPercent 10.2 -ObservedAt $endAt -ResetsAt $endAt.AddHours(4); Weekly = $null }
$blockedEvidence = [pscustomobject]@{ FiveHour = New-QuotaFixEvidence -QuotaEvidenceComplete $false -TotalCost 1.0 -EffectiveDeltaPercent 0.2; Weekly = $null }
$blockedEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $startLimits -EndRateLimits $endLimits -IntervalCost 1.0 -CostComplete $true -QuotaEvidence $blockedEvidence
Assert-QuotaFixEqual $null $blockedEstimate.FiveHour 'unknown mode strict evidence is rejected by quota estimate'
$manualEvidence = [pscustomobject]@{ FiveHour = New-QuotaFixEvidence -QuotaEvidenceComplete $true -ModeAssumptionApplied $true -TotalCost 1.0 -EffectiveDeltaPercent 0.2; Weekly = $null }
$manualEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $startLimits -EndRateLimits $endLimits -IntervalCost 1.0 -CostComplete $true -QuotaEvidence $manualEvidence
Assert-QuotaFixNear 500.0 $manualEstimate.FiveHour.TotalUsd 0.0000001 'manual quota estimate uses actual fractional delta'
Assert-QuotaFixEqual $true $manualEstimate.FiveHour.ManualServiceTierApplied 'manual quota assumption flag reaches estimate card'

# Legacy callers without QuotaEvidence (and old evidence objects without the
# new fields) retain the previous estimate behavior.
$legacyEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $startLimits -EndRateLimits $endLimits -IntervalCost 1.0 -CostComplete $true
Assert-QuotaFixNear 500.0 $legacyEstimate.FiveHour.TotalUsd 0.0000001 'legacy no-evidence estimate remains compatible'
$legacyEvidence = [pscustomobject]@{
    BoundaryValid = $true; PricingComplete = $true; EstimateSource = 'snapshot_delta_usd_estimate';
    TotalCost = 1.0; EstimatedTotalUsd = 500.0; EffectiveDeltaPercent = 0.2;
    EndObservedAt = $endAt; CurrentObservedAt = $endAt; WindowMinutes = 300;
    PlanType = 'synthetic'; ResetIdentity = $endLimits.FiveHour.ResetIdentity;
    CapacitySource = 'percent_delta_tokens'; FirstCountedAt = $startAt; LastCountedAt = $endAt.AddSeconds(-1)
}
$legacyEvidenceEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $startLimits -EndRateLimits $endLimits -IntervalCost 1.0 -CostComplete $true `
    -QuotaEvidence ([pscustomobject]@{ FiveHour = $legacyEvidence; Weekly = $null })
Assert-QuotaFixNear 500.0 $legacyEvidenceEstimate.FiveHour.TotalUsd 0.0000001 'old evidence object remains compatible'

# Repeated-late observation is allowed to disclose incomplete coverage, but a
# reset or a negative window delta remains invalid for the affected card only.
$lateEvidence = New-QuotaFixEvidence -QuotaEvidenceComplete $true -TotalCost 1.0 -EffectiveDeltaPercent 0.2
$lateEvidence.CurrentObservedAt = $endAt
$lateEvidence.EndObservedAt = $endAt
$lateEvidence.LastCountedAt = $endAt.AddMinutes(-2)
$lateEvidence | Add-Member -NotePropertyName CoverageComplete -NotePropertyValue $false
$lateEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $startLimits -EndRateLimits $endLimits -IntervalCost 1.0 -CostComplete $true `
    -QuotaEvidence ([pscustomobject]@{ FiveHour = $lateEvidence; Weekly = $null })
Assert-QuotaFixNear 500.0 $lateEstimate.FiveHour.TotalUsd 0.0000001 'repeated-late evidence retains aligned estimate'
$resetEndLimits = [pscustomobject]@{ PlanType = 'synthetic'; FiveHour = New-QuotaFixWindow -UsedPercent 10.2 -ObservedAt $endAt -ResetsAt $endAt.AddHours(5); Weekly = $null }
$resetEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $startLimits -EndRateLimits $resetEndLimits -IntervalCost 1.0 -CostComplete $true
Assert-QuotaFixEqual $null $resetEstimate.FiveHour 'reset identity change rejects the affected quota window'

Write-Output 'QUOTA_EVIDENCE_FIX_TESTS_PASSED'
