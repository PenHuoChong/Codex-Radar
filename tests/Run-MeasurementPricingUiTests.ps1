[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'TokenRader.ps1')
foreach ($name in @('Reset-MeasurementPricingConfirmation','Set-MeasurementPricingConfirmation',
    'Test-TokenRaderQuotaEstimateMatchesWindow','Set-QuotaWindowCard','Merge-LatestRateLimits',
    'Get-ServiceTierLabel','Get-ResultServiceTierSummary')) {
    $match = [regex]::Match($source, '(?s)function ' + $name + '\b.*?(?=\r?\nfunction |\z)')
    if (-not $match.Success) { throw "Missing production function: $name" }
    Invoke-Expression $match.Value
}
function Assert-UiPricing([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "UI PRICING TEST FAILED: $Message" }
}
function Update-QuotaCards { $script:CardsUpdated = $true }
function Update-IntervalView { param([switch]$Manual) $script:ManualRefresh = [bool]$Manual }
$script:Prices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
$script:MeasurementPricingButton = [pscustomobject]@{Content=''}
$script:State = @{
    UiState='Measuring'; IntervalBaseline=[pscustomobject]@{StartedAt=[DateTimeOffset]::Now}; IntervalComputing=$false
    ManualServiceTiers=@{}; QuotaEstimates=[pscustomobject]@{Weekly='old'}; QuotaEstimateAccountIdentity='synthetic'
    IntervalCache=[pscustomobject]@{Result='old'}
}
$script:ManualRefresh=$false; $script:CardsUpdated=$false
$ok=Set-MeasurementPricingConfirmation -Selections @{'gpt-6-astra'='fast';'gpt-5.6-luna'='standard'}
Assert-UiPricing $ok 'confirmation was not applied'
Assert-UiPricing ($script:State.ManualServiceTiers['gpt-6-astra'] -eq 'priority') 'Astra confirmation lost'
Assert-UiPricing ($script:State.ManualServiceTiers['gpt-5.6-luna'] -eq 'default') 'Luna must remain independently standard'
Assert-UiPricing ($null -eq $script:State.QuotaEstimates -and $null -eq $script:State.IntervalCache) 'old assumption caches survived'
Assert-UiPricing ($script:ManualRefresh -and $script:CardsUpdated) 'confirmation must refresh immediately'
Assert-UiPricing (-not (Set-MeasurementPricingConfirmation -Selections @{'gpt-5.6-cyber'='priority'})) 'unpublished Fast price accepted'
Assert-UiPricing ($script:State.QuotaCalibrationMessage -eq '正在按本次计价模式重新计算额度…') 'old quota hint survived policy change'
$script:State.IntervalComputing=$true
Assert-UiPricing (-not (Set-MeasurementPricingConfirmation -Selections @{})) 'an active query allowed policy mutation'
$script:State.IntervalComputing=$false
Reset-MeasurementPricingConfirmation
Assert-UiPricing ($script:State.ManualServiceTiers.Count -eq @($script:Prices.models).Count) 'new measurement did not initialize all priced models'
Assert-UiPricing (@($script:State.ManualServiceTiers.Values | Where-Object { $_ -ne 'default' }).Count -eq 0) 'new measurement retained Fast instead of confirmed Standard'
$defaultPrices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
$defaultPrices | Add-Member -NotePropertyName ManualServiceTiers -NotePropertyValue $script:State.ManualServiceTiers
$usage = [pscustomobject]@{Input=100;Cached=0;Output=10;Total=110;Uncached=100;ReasoningOutput=0}
$defaultCost = Get-TokenRaderCost -Model 'gpt-6-astra' -Usage $usage -PricingDocument $defaultPrices
Assert-UiPricing ($defaultCost.ManualServiceTierApplied -and $defaultCost.ServiceTier -eq 'default') 'default selection was not applied as confirmation'
$explicitCost = Get-TokenRaderCost -Model 'gpt-6-astra' -Usage $usage -PricingDocument $defaultPrices -ServiceTier 'priority'
Assert-UiPricing ($explicitCost.ServiceTier -eq 'priority' -and -not $explicitCost.ManualServiceTierApplied) 'default Standard overwrote explicit Fast'

$now=[DateTimeOffset]::Now
$reset=$now.AddDays(5)
$window=[pscustomobject]@{UsedPercent=30.0;WindowMinutes=10080;PlanType='synthetic';ResetsAt=$reset;ObservedAt=$now}
$estimate=[pscustomobject]@{TotalUsd=100.0;UsedUsd=99.0;RemainingUsd=1.0;WindowMinutes=10080;PlanType='synthetic';ResetsAt=$reset;CurrentObservedAt=$now.AddSeconds(-1);EstimateSource='snapshot_delta_usd_estimate';IdentityComplete=$true;StartUsedPercent=10.0;EffectiveDeltaPercent=2.0;ManualServiceTierApplied=$true}
Assert-UiPricing (Test-TokenRaderQuotaEstimateMatchesWindow -Estimate $estimate -Window $window) 'new timestamp discarded same-cycle calibration'
$usage=[pscustomobject]@{Text=''};$progress=[pscustomobject]@{Value=0};$dollar=[pscustomobject]@{Text=''};$resetText=[pscustomobject]@{Text=''}
Set-QuotaWindowCard -Window $window -Estimate $estimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($dollar.Text.Contains((Format-TokenRaderUsd 30.0)) -and $dollar.Text.Contains((Format-TokenRaderUsd 70.0))) 'retained calibration displays stale used/remaining dollars'
Assert-UiPricing ($dollar.Text.Contains('人工确认')) 'manual evidence not labeled on quota'
$estimate | Add-Member -NotePropertyName ReferencePricingApplied -NotePropertyValue $true
$estimate.ManualServiceTierApplied=$false
Set-QuotaWindowCard -Window $window -Estimate $estimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($dollar.Text.Contains('未知模式按普通价参考') -and $dollar.Text.Contains((Format-TokenRaderUsd 100.0))) 'unknown mode reference must display dollars with its pricing basis'
$script:State.RateLimits=[pscustomobject]@{FiveHour=$null;Weekly=$window;ObservedAt=$now;PlanType='synthetic'}
$late=[pscustomobject]@{UsedPercent=29.0;WindowMinutes=10080;PlanType='synthetic';ResetsAt=$reset;ObservedAt=$now.AddSeconds(1)}
Merge-LatestRateLimits -Candidate ([pscustomobject]@{FiveHour=$null;Weekly=$late;ObservedAt=$late.ObservedAt;PlanType='synthetic'})
Assert-UiPricing ($script:State.RateLimits.Weekly.UsedPercent -eq 30.0 -and $script:State.RateLimits.Weekly.ObservedAt -eq $now) 'late regression changed the percent or boundary'
$late.PlanType=''
Merge-LatestRateLimits -Candidate ([pscustomobject]@{FiveHour=$null;Weekly=$late;ObservedAt=$late.ObservedAt;PlanType=''})
Assert-UiPricing ($script:State.RateLimits.Weekly.UsedPercent -eq 30.0) 'missing plan bypassed regression guard'
$late.ResetsAt=$reset.AddDays(7);$late.UsedPercent=1.0
Merge-LatestRateLimits -Candidate ([pscustomobject]@{FiveHour=$null;Weekly=$late;ObservedAt=$late.ObservedAt;PlanType='synthetic'})
Assert-UiPricing ($script:State.RateLimits.Weekly.UsedPercent -eq 1.0) 'actual reset blocked'
[xml]$xaml=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'MainWindow.xaml')
Assert-UiPricing ($xaml.OuterXml.Contains('MeasurementPricingButton')) 'manual confirmation control missing'
Write-Output 'MEASUREMENT_PRICING_UI_TESTS_PASSED'
