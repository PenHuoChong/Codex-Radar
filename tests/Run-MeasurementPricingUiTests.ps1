[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'TokenRader.ps1')
foreach ($name in @('Reset-MeasurementPricingConfirmation','Set-MeasurementPricingConfirmation',
    'Test-TokenRaderQuotaEstimateMatchesWindow','Set-QuotaWindowCard','Merge-LatestRateLimits',
    'Get-ServiceTierLabel','Get-ResultServiceTierSummary','Get-TokenRaderQuotaDiagnostic',
    'Get-TokenRaderQuotaDiagnosticValue','Get-TokenRaderQuotaDiagnosticMessage','Test-TokenRaderQuotaDiagnosticRetained',
    'Get-TokenRaderQuotaDiagnosticAccountIdentity','Test-TokenRaderSameQuotaEvidence','Update-QuotaEstimatesFromInterval','Retain-TokenRaderQuotaEstimatesForCurrentWindow')) {
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
$script:State.QuotaEstimates=[pscustomobject]@{Weekly='retained-standard'}
Reset-MeasurementPricingConfirmation
Assert-UiPricing ($script:State.QuotaEstimates.Weekly -eq 'retained-standard') 'unchanged Standard policy erased immediately available dollars'
$script:State.ManualServiceTiers['gpt-6-astra']='priority'
Reset-MeasurementPricingConfirmation
Assert-UiPricing ($null -eq $script:State.QuotaEstimates) 'changed pricing policy retained incompatible dollars'
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
$estimate | Add-Member -NotePropertyName EndUsedPercent -NotePropertyValue 30.0
Set-QuotaWindowCard -Window $null -Estimate $estimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($dollar.Text.Contains((Format-TokenRaderUsd 100.0)) -and $dollar.Text.Contains('沿用最近有效快照')) 'transient missing snapshot hid available dollars'
$estimate.ResetsAt=$now.AddSeconds(-1)
Set-QuotaWindowCard -Window $null -Estimate $estimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($dollar.Text.Contains('不可估') -and -not $dollar.Text.Contains((Format-TokenRaderUsd 100.0))) 'expired estimate was presented as current dollars'
$estimate.ResetsAt=$reset
$diagnostic=[pscustomobject]@{Status='retained';ReasonCode='unknown_attribution';Message='校准区间存在归属不明调用';Retained=$true}
Set-QuotaWindowCard -Window $window -Estimate $estimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText -Diagnostic $diagnostic
Assert-UiPricing ($dollar.Text.Contains('沿用上次结果') -and $dollar.Text.Contains('归属不明') -and $dollar.Text.Contains((Format-TokenRaderUsd 100.0))) 'retained quota lost dollars or diagnostic'
Set-QuotaWindowCard -Window $window -Estimate $null -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText -Diagnostic $diagnostic
Assert-UiPricing ($dollar.Text.Contains('不可估') -and $dollar.Text.Contains('归属不明')) 'missing estimate did not explain why'
$otherPool=$window.PSObject.Copy();$otherPool|Add-Member -NotePropertyName LimitId -NotePropertyValue 'other'
$estimate|Add-Member -NotePropertyName LimitId -NotePropertyValue 'codex'
Assert-UiPricing (-not (Test-TokenRaderQuotaEstimateMatchesWindow -Estimate $estimate -Window $otherPool)) 'different quota pools shared an estimate'
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
# Exercise the real callback with diagnostics present: these are descriptions,
# not a replacement for converting QuotaEvidence into a dollar estimate.
$script:State.AccountIdentity='current-tag'
$script:State.IntervalBaseline=[pscustomobject]@{StartedAt=$now.AddMinutes(-5);AccountIdentity='previous-tag';RateLimits=$null}
$script:State.QuotaDiagnostics=$null
$script:State.QuotaEstimates=$null
$script:State.QuotaEstimateAccountIdentity=''
$script:State.RateLimits=[pscustomobject]@{FiveHour=$null;Weekly=$window}
$script:EstimateConversions=0
function Get-TokenRaderQuotaEstimate {
    param($StartRateLimits,$EndRateLimits,$IntervalCost,$CostComplete,$StartReferenceAt,$EndReferenceAt,$QuotaEvidence)
    $script:EstimateConversions++
    [pscustomobject]@{FiveHour=$null;Weekly=$(if ($null -ne $QuotaEvidence) {$estimate} else {$null})}
}
$callbackResult=[pscustomobject]@{AccountIdentity='current-tag';StartRateLimits=$null;EndRateLimits=$script:State.RateLimits;PricingComplete=$true;TotalCost=1.0;EndedAt=$now;QuotaEvidence=[pscustomobject]@{FiveHour=$null;Weekly=[pscustomobject]@{}};QuotaDiagnostics=[pscustomobject]@{FiveHour=[pscustomobject]@{Status='unavailable';ReasonCode='missing_window';Message='没有当前额度窗口';Retained=$false};Weekly=[pscustomobject]@{Status='updated';ReasonCode='ok';Message='本次更新';Retained=$false;AccountIdentity='current-tag'}}}
Update-QuotaEstimatesFromInterval -Result $callbackResult
Assert-UiPricing ($script:EstimateConversions -eq 1 -and $null -ne $script:State.QuotaEstimates.Weekly) 'diagnostics-present callback failed to convert quota evidence'
Assert-UiPricing ($script:State.QuotaEstimateAccountIdentity -eq 'current-tag') 'old measurement account was assigned to new-cycle estimate'
$callbackResult.QuotaEvidence=$null
$callbackResult.PricingComplete=$false
$callbackResult.QuotaDiagnostics.Weekly.Status='unavailable'
$callbackResult.QuotaDiagnostics.Weekly.ReasonCode='pricing_incomplete'
$callbackResult.QuotaDiagnostics.Weekly.Message='校准区间价格不完整'
Update-QuotaEstimatesFromInterval -Result $callbackResult
Assert-UiPricing ($null -ne $script:State.QuotaEstimates.Weekly -and $script:State.QuotaDiagnostics.Weekly.Retained) 'transient incomplete pricing discarded a same-cycle estimate'
$callbackResult.AccountIdentity='previous-tag'
$callbackResult.QuotaDiagnostics.Weekly.AccountIdentity='previous-tag'
Update-QuotaEstimatesFromInterval -Result $callbackResult
Assert-UiPricing ($script:EstimateConversions -eq 2) 'late previous-account result was recalibrated into current account'
$script:State.QuotaEstimates=[pscustomobject]@{FiveHour=$null;Weekly=$estimate}
$script:State.QuotaEstimateAccountIdentity=''
Retain-TokenRaderQuotaEstimatesForCurrentWindow -RateLimits $script:State.RateLimits -AccountIdentity 'newly-known-account'
Assert-UiPricing ($null -eq $script:State.QuotaEstimates) 'unknown-account dollars migrated into a newly identified account'
$conflictWindow=[pscustomobject]@{UsedPercent=11;WindowMinutes=10080;PlanType='prolite';ResetsAt=$reset;ObservedAt=$now;ScopeConflict=$true;ConflictDescription='pro：已用3%；prolite：已用11%'}
Set-QuotaWindowCard -Window $conflictWindow -Estimate $estimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($usage.Text -eq '来源冲突' -and $dollar.Text.Contains('pro：已用3%') -and $dollar.Text.Contains('不可估')) 'conflicting plan snapshot was presented as current account quota'
Assert-UiPricing (-not (Test-TokenRaderQuotaEstimateMatchesWindow $estimate $conflictWindow)) 'ambiguous scope retained an unbound dollar estimate'
$sameEvidence=[pscustomobject]@{CalibrationStartObservedAt=$now.AddMinutes(-2);CalibrationEndObservedAt=$now.AddMinutes(-1);StartUsedPercent=10;CalibrationEndUsedPercent=11;EvidenceCost=6.530489;TotalUsd=653.0489;PlanType='pro';WindowMinutes=10080;ResetsAt=$reset;LimitId='codex';AccountIdentity='synthetic'}
$newEvidence=$sameEvidence.PSObject.Copy()
Assert-UiPricing (Test-TokenRaderSameQuotaEvidence $sameEvidence $newEvidence) 'unchanged evidence did not compare equal'
$newEvidence.EvidenceCost=7.0
Assert-UiPricing (-not (Test-TokenRaderSameQuotaEvidence $sameEvidence $newEvidence)) 'changed cost evidence was marked stale'
$newEvidence=$sameEvidence.PSObject.Copy();$newEvidence.CalibrationEndObservedAt=$now
Assert-UiPricing (-not (Test-TokenRaderSameQuotaEvidence $sameEvidence $newEvidence)) 'new calibration boundary was marked stale'
Set-QuotaWindowCard -Window $window -Estimate $estimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($dollar.Text.Contains('比例外推已用') -and $dollar.Text.Contains('比例外推剩余')) 'extrapolated dollars still masquerade as actual spend'
foreach ($p in $sameEvidence.PSObject.Properties) { $estimate | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
$script:State.AccountIdentity='current-tag';$script:State.QuotaEstimateAccountIdentity='current-tag'
$script:State.QuotaEstimates=[pscustomobject]@{FiveHour=$null;Weekly=$estimate.PSObject.Copy()}
$callbackResult.AccountIdentity='current-tag';$callbackResult.QuotaEvidence=[pscustomobject]@{FiveHour=$null;Weekly=[pscustomobject]@{}}
$callbackResult.QuotaDiagnostics.Weekly=[pscustomobject]@{ReasonCode='ok';Status='updated';Message='本次更新';Retained=$false;AccountIdentity='current-tag'}
Update-QuotaEstimatesFromInterval -Result $callbackResult
Assert-UiPricing ($script:State.QuotaDiagnostics.Weekly.Retained -and $script:State.QuotaDiagnostics.Weekly.ReasonCode -eq 'unchanged_evidence') 'refresh callback falsely marked identical calibration as updated'
$estimate=$estimate.PSObject.Copy();$estimate.EvidenceCost=8.0
$callbackResult.QuotaDiagnostics.Weekly=[pscustomobject]@{ReasonCode='ok';Status='updated';Message='本次更新';Retained=$false;AccountIdentity='current-tag'}
Update-QuotaEstimatesFromInterval -Result $callbackResult
Assert-UiPricing (-not $script:State.QuotaDiagnostics.Weekly.Retained) 'new calibration cost did not immediately mark result updated'
Write-Output 'MEASUREMENT_PRICING_UI_TESTS_PASSED'
