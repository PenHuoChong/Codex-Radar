[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PlanEvidence {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('PLAN QUOTA EVIDENCE TEST FAILED: ' + $Message) }
}

function Assert-PlanEvidenceNear {
    param([double]$Expected, [double]$Actual, [string]$Message)
    if ([Math]::Abs($Expected - $Actual) -gt 0.0000001) {
        throw ('PLAN QUOTA EVIDENCE TEST FAILED: {0}; expected={1} actual={2}' -f $Message, $Expected, $Actual)
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $projectRoot 'TokenRader.Core.psm1'
Import-Module $corePath -Force
$coreModule = Get-Module TokenRader.Core
$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
$indexerDll = Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll'
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path $indexerDll }

# Reuse the existing synthetic in-memory schema and row builders without
# running that suite or copying a large private-data-independent fixture.
$cyclePath = Join-Path $PSScriptRoot 'Run-QuotaCycleTests.ps1'
$tokens = $null
$parseErrors = $null
$cycleAst = [Management.Automation.Language.Parser]::ParseFile($cyclePath, [ref]$tokens, [ref]$parseErrors)
Assert-PlanEvidence ($parseErrors.Count -eq 0) 'quota-cycle helper source did not parse'
$helperNames = @('Add-QuotaCycleParameter','Add-QuotaCycleRow','New-QuotaCycleDb','New-QuotaCycleWindow')
$helpers = @($cycleAst.FindAll({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $helperNames -contains $node.Name
}, $true))
Assert-PlanEvidence ($helpers.Count -eq $helperNames.Count) 'quota-cycle helper definitions changed'
foreach ($helper in $helpers) { . ([scriptblock]::Create($helper.Extent.Text)) }

$apiPrices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
$planPrices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
$planPrices | Add-Member -NotePropertyName QuotaPricingBasis -NotePropertyValue 'plan_standard_api_reference' -Force
$thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
$thresholds['gpt-6-sol'] = 272000L
$reset = 1900000000L
$startAt = [DateTimeOffset]::Parse('2030-03-01T00:10:00Z')
$endAt = [DateTimeOffset]::Parse('2030-03-01T00:10:20Z')
$callAt = [DateTimeOffset]::Parse('2030-03-01T00:10:10Z')
$start = New-QuotaCycleWindow 26 $startAt.ToString('o') $reset 'team'
$end = New-QuotaCycleWindow 27 $endAt.ToString('o') $reset 'team'
$path = 'synthetic://plan-quota-evidence'
$ends = @{ $path = 20L }
$db = New-QuotaCycleDb
try {
    Add-QuotaCycleRow $db 'synthetic-session' $startAt.ToString('o') $path 10 'snapshot-26' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 26 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    # Five real short-context calls total 1M tokens; cumulative input must not
    # accidentally trigger the per-request 272K premium.
    foreach ($i in 1..5) {
        Add-QuotaCycleRow $db 'synthetic-session' $startAt.AddSeconds($i).ToString('o') $path (10 + $i) ('fast-call-' + $i) -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 26 -FiveHourWindow 300 -FiveHourReset $reset -Model 'gpt-6-sol' -ServiceTier 'priority' -TotalInput (200000 * $i) -CallInput 200000 -TotalOutput 0 -CallOutput 0
    }
    Add-QuotaCycleRow $db 'synthetic-session' $endAt.ToString('o') $path 20 'snapshot-27' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 27 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0

    $apiDiagnostic = @{}
    $planDiagnostic = @{}
    $getEvidence = {
        param($startWindow, $endWindow, $connection, $offsets, $thresholdMap, $prices, $diagnostic)
        Get-TokenRaderQuotaWindowEvidence -StartWindow $startWindow -EndWindow $endWindow -MainLastCountedAt $null `
            -WindowKind FiveHour -RateLimitId 'quota-synthetic' -Connection $connection -EndOffsets $offsets `
            -Thresholds $thresholdMap -PricingDocument $prices -CancellationToken ([Threading.CancellationToken]::None) `
            -ProgressState @{} -Cache @{} -DiagnosticState $diagnostic -AccountIdentity 'synthetic-account'
    }
    $api = & $coreModule $getEvidence $start $end $db $ends $thresholds $apiPrices $apiDiagnostic
    $plan = & $coreModule $getEvidence $start $end $db $ends $thresholds $planPrices $planDiagnostic
    Assert-PlanEvidence ($null -ne $api -and $null -ne $plan) 'both quota calibrations must be available'
    Assert-PlanEvidenceNear 4.0 $api.TotalCost 'legacy API Fast cost'
    Assert-PlanEvidenceNear 5.0 $plan.TotalCost 'plan Fast normalized cost'
    Assert-PlanEvidenceNear 4.0 $plan.ApiTotalCost 'plan evidence must preserve API cost'
    Assert-PlanEvidence ([string]$api.QuotaPricingBasis -eq 'api_equivalent') 'legacy quota basis changed'
    Assert-PlanEvidence ([string]$plan.QuotaPricingBasis -eq 'plan_standard_api_reference') 'plan quota basis missing'
    Assert-PlanEvidenceNear $api.EffectiveDeltaPercent $plan.EffectiveDeltaPercent 'pricing changed percentage boundary'
    Assert-PlanEvidence ($api.StartObservedAt -eq $plan.StartObservedAt -and $api.EndObservedAt -eq $plan.EndObservedAt) 'pricing changed frozen calibration endpoints'
    Assert-PlanEvidence ([bool]$plan.PricingComplete -and [bool]$plan.QuotaEvidenceComplete) 'plan evidence became incomplete'
    Assert-PlanEvidenceNear 0.0 $plan.CacheCreationCost 'plan evidence should not have API cache-write premium'
    Assert-PlanEvidence ([string]$planDiagnostic.QuotaPricingBasis -eq 'plan_standard_api_reference') 'plan diagnostic omitted basis'
    Assert-PlanEvidenceNear 4.0 $planDiagnostic.ApiTotalCost 'plan diagnostic omitted API cost'

    $startLimits = [pscustomobject]@{ FiveHour=$start; Weekly=$null; PlanType='team' }
    $endLimits = [pscustomobject]@{ FiveHour=$end; Weekly=$null; PlanType='team' }
    $apiEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $startLimits -EndRateLimits $endLimits -IntervalCost 0 -QuotaEvidence ([pscustomobject]@{FiveHour=$api;Weekly=$null})
    $planEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $startLimits -EndRateLimits $endLimits -IntervalCost 0 -QuotaEvidence ([pscustomobject]@{FiveHour=$plan;Weekly=$null})
    Assert-PlanEvidence ($null -ne $apiEstimate.FiveHour -and $null -ne $planEstimate.FiveHour) 'strict estimates missing'
    Assert-PlanEvidenceNear 400.0 $apiEstimate.FiveHour.TotalUsd 'legacy 1% calibration'
    Assert-PlanEvidenceNear 500.0 $planEstimate.FiveHour.TotalUsd 'plan 1% calibration'
    Assert-PlanEvidenceNear 4.0 $planEstimate.FiveHour.ApiEvidenceCost 'estimate did not carry API evidence cost'

    # Append a row whose timestamp falls inside the interval, but whose offset
    # is beyond the captured endpoint. Frozen offsets must exclude it.
    Add-QuotaCycleRow $db 'synthetic-session' $callAt.ToString('o') $path 30 'late-fast-call' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 26 -FiveHourWindow 300 -FiveHourReset $reset -Model 'gpt-6-sol' -ServiceTier 'priority' -TotalInput 1200000 -CallInput 200000 -TotalOutput 0 -CallOutput 0
    $frozen = & $coreModule $getEvidence $start $end $db $ends $thresholds $planPrices @{}
    Assert-PlanEvidence ($null -ne $frozen) 'frozen evidence disappeared after append'
    Assert-PlanEvidenceNear $plan.TotalCost $frozen.TotalCost 'late row crossed frozen offset'
    Assert-PlanEvidence ($plan.StartObservedAt -eq $frozen.StartObservedAt -and $plan.EndObservedAt -eq $frozen.EndObservedAt) 'late row changed frozen boundaries'

    # A complete five-point step uses 5%, never the UI's separate 1% yardstick.
    # Change only synthetic in-memory quota metadata; frozen call costs remain $5.
    $command = $db.CreateCommand()
    try {
        $command.CommandText = 'UPDATE token_records SET five_hour_used=31 WHERE source_offset_end=20'
        [void]$command.ExecuteNonQuery()
    } finally { $command.Dispose() }
    $fivePointEnd = New-QuotaCycleWindow 31 $endAt.ToString('o') $reset 'team'
    $fivePoint = & $coreModule $getEvidence $start $fivePointEnd $db $ends $thresholds $planPrices @{}
    Assert-PlanEvidence ($null -ne $fivePoint) 'five-point strict plan evidence missing'
    Assert-PlanEvidenceNear 5.0 $fivePoint.EffectiveDeltaPercent 'five-point denominator changed'
    Assert-PlanEvidenceNear 5.0 $fivePoint.TotalCost 'five-point frozen costs changed'
    Assert-PlanEvidenceNear 100.0 $fivePoint.EstimatedTotalUsd 'five-point strict cost was folded as 1%'
} finally {
    $db.Dispose()
}

'PLAN_QUOTA_EVIDENCE_TESTS_PASSED'
