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
    'Get-TokenRaderQuotaDiagnosticAccountIdentity','Test-TokenRaderSameQuotaEvidence','Update-QuotaEstimatesFromInterval','Update-TokenRaderWeeklyReferenceFromResult','Retain-TokenRaderQuotaEstimatesForCurrentWindow')) {
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
$missingWindow=$conflictWindow.PSObject.Copy()
$missingWindow | Add-Member -NotePropertyName ScopeConflictReason -NotePropertyValue 'selected_plan_missing'
Set-QuotaWindowCard -Window $missingWindow -Estimate $estimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($usage.Text -eq '暂无' -and $resetText.Text -eq '未提供所选套餐窗口') 'missing selected plan is not a source conflict'
Assert-UiPricing (-not (Test-TokenRaderQuotaEstimateMatchesWindow $estimate $missingWindow)) 'missing selection must still reject stale estimates'
Set-QuotaWindowCard -Window $conflictWindow -Estimate $estimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText -NotApplicable
Assert-UiPricing ($usage.Text -eq '不适用' -and $dollar.Text -match '人工确认' -and $resetText.Text -eq '') 'explicit no-five-hour setting overrides display without inventing a limit'
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
foreach ($messages in @(@('', ''), @('only diagnostic', ''), @('same diagnostic','same diagnostic'), @('first diagnostic','second diagnostic'))) {
    $script:State.QuotaEstimates=$null
    $callbackResult.QuotaEvidence=$null
    $callbackResult.PricingComplete=$true
    $callbackResult.QuotaDiagnostics=[pscustomobject]@{
        FiveHour=[pscustomobject]@{Status='unavailable';ReasonCode='missing_window';Message=$messages[0];Retained=$false;AccountIdentity='current-tag'}
        Weekly=[pscustomobject]@{Status='unavailable';ReasonCode='missing_window';Message=$messages[1];Retained=$false;AccountIdentity='current-tag'}
    }
    Update-QuotaEstimatesFromInterval -Result $callbackResult
    Assert-UiPricing ($null -ne $script:State.QuotaCalibrationMessage) 'empty/single diagnostic pipeline failed'
}
$regularWindow=$window.PSObject.Copy()
$regularWindow | Add-Member -NotePropertyName LimitId -NotePropertyValue 'codex' -Force
$regularWindow.UsedPercent=74
$regularLimits=[pscustomobject]@{FiveHour=$null;Weekly=$regularWindow;ObservedAt=$now;PlanType='synthetic'}
$script:State.RateLimits=$regularLimits;$script:State.QuotaPlanSelection=''
$foreignWindow=$regularWindow.PSObject.Copy();$foreignWindow.LimitId='codex_bengalfox';$foreignWindow.UsedPercent=0;$foreignWindow.ObservedAt=$now.AddMinutes(1)
$foreignLimits=[pscustomobject]@{FiveHour=$foreignWindow;Weekly=$foreignWindow;ObservedAt=$now.AddMinutes(1);PlanType='synthetic'}
Merge-LatestRateLimits $foreignLimits
Assert-UiPricing ($script:State.RateLimits.Weekly.UsedPercent -eq 74 -and $null -eq $script:State.RateLimits.FiveHour) 'newer specialized pool replaced the regular cards'
$foreignEstimate=$estimate.PSObject.Copy();$foreignEstimate.LimitId='codex_bengalfox'
Assert-UiPricing (-not (Test-TokenRaderQuotaEstimateMatchesWindow $foreignEstimate $regularWindow)) 'specialized-pool estimate survived regular-card retention'

# The one-percent reference is scoped to the current measurement and stays
# separate from frozen quota calibration, including sub-percent observations.
$script:State.AccountIdentity='current-tag'
$script:State.IntervalBaseline=[pscustomobject]@{StartedAt=$now.AddMinutes(-5);AccountIdentity='current-tag';RateLimits=$null}
$startWeek=[pscustomobject]@{UsedPercent=30.0;WindowMinutes=10080;PlanType='synthetic';ResetsAt=$reset;LimitId='codex'}
$endWeek=$startWeek.PSObject.Copy()
$referenceResult=[pscustomobject]@{
    AccountIdentity='current-tag';StartRateLimits=[pscustomobject]@{Weekly=$startWeek}
    EndRateLimits=[pscustomobject]@{Weekly=$endWeek};TotalCost=12.5;PricingComplete=$true
}
foreach ($delta in @(0.0,0.1,0.99,1.0,2.0)) {
    $endWeek.UsedPercent=30.0+$delta
    Update-TokenRaderWeeklyReferenceFromResult -Result $referenceResult
    $reference=$script:State.WeeklyReferenceEstimate
    Assert-UiPricing ([Math]::Abs([double]$reference.ActualDeltaPercent-$delta) -lt 0.000001) "wrong measured delta at $delta percentage points"
    if ($delta -lt 1.0) {
        Assert-UiPricing ([Math]::Abs([double]$reference.TotalUsd-1250.0) -lt 0.000001) "wrong 1% reference at $delta percentage points"
    } else {
        Assert-UiPricing ($null -eq $reference.TotalUsd) "full step still manufactured 1% dollars at $delta"
    }
    Set-QuotaWindowCard -Window $endWeek -Estimate $estimate -WeeklyReference $reference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
    if ($delta -lt 1.0) {
        Assert-UiPricing ($dollar.Text.StartsWith('周总额度参考≈$1,250') -and $dollar.Text.Contains('本次API消耗×100') -and
            -not $dollar.Text.Contains('反推总额度≈')) "sub-percent measurement used frozen calibration at $delta"
    } else {
        Assert-UiPricing ($dollar.Text.Contains('反推总额度≈') -and -not $dollar.Text.Contains('周总额度参考')) "complete step failed to use frozen calibration at $delta"
    }
}
$endWeek.UsedPercent=32.0
Update-TokenRaderWeeklyReferenceFromResult -Result $referenceResult
Set-QuotaWindowCard -Window $endWeek -Estimate $null -WeeklyReference $script:State.WeeklyReferenceEstimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing (-not $dollar.Text.Contains('$1,250') -and $dollar.Text.Contains('本次周增量已达 2%') -and $dollar.Text.Contains('等待同边界校准')) 'unavailable strict calibration reused 1% reference after a full step'
# The following sub-percent cases are a separate measurement, not a rollback
# that could reopen a reference after a complete step in the same cycle.
$script:State.WeeklyReferenceEstimate=$null
$endWeek.UsedPercent=30.0
Update-TokenRaderWeeklyReferenceFromResult -Result $referenceResult
$reference=$script:State.WeeklyReferenceEstimate
Set-QuotaWindowCard -Window $endWeek -Estimate $null -WeeklyReference $reference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($usage.Text -eq '30%' -and $dollar.Text.StartsWith('周总额度参考≈$1,250') -and
    -not $dollar.Text.Contains('比例外推已用')) 'current percent or reference-only label was fabricated'
Set-QuotaWindowCard -Window $null -Estimate $null -WeeklyReference $reference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($usage.Text -eq '暂无' -and $dollar.Text.StartsWith('周总额度参考≈$1,250') -and
    -not $dollar.Text.Contains('美金额度：不可估')) 'missing window hid reference or invented percent'
Set-QuotaWindowCard -Window $conflictWindow -Estimate $null -WeeklyReference $reference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($usage.Text -eq '来源冲突' -and $dollar.Text.StartsWith('周总额度参考≈$1,250') -and
    -not $dollar.Text.Contains('美金额度：不可估')) 'conflicting source hid reference or invented percent'
$referenceResult.PricingComplete=$false
Update-TokenRaderWeeklyReferenceFromResult -Result $referenceResult
Set-QuotaWindowCard -Window $null -Estimate $null -WeeklyReference $script:State.WeeklyReferenceEstimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($dollar.Text.Contains('计价不完整（部分参考）')) 'partial pricing reference was unmarked'
$referenceResult.TotalCost=[double]::NaN
Update-TokenRaderWeeklyReferenceFromResult -Result $referenceResult
Assert-UiPricing ($null -eq $script:State.WeeklyReferenceEstimate) 'nonfinite cost produced a reference'
$referenceResult.TotalCost=12.5;$referenceResult.PricingComplete=$true
Update-TokenRaderWeeklyReferenceFromResult -Result $referenceResult
$currentReference=$script:State.WeeklyReferenceEstimate
$referenceResult.AccountIdentity='old-account'
Update-TokenRaderWeeklyReferenceFromResult -Result $referenceResult
Assert-UiPricing ([object]::ReferenceEquals($currentReference,$script:State.WeeklyReferenceEstimate)) 'late old-account result replaced the current reference'
foreach ($invalidCost in @($null, 0, -1, [double]::NaN, [double]::PositiveInfinity, 'invalid')) {
    $referenceResult.TotalCost = $invalidCost
    Update-TokenRaderWeeklyReferenceFromResult -Result $referenceResult
    Assert-UiPricing ([object]::ReferenceEquals($currentReference,$script:State.WeeklyReferenceEstimate)) 'late foreign invalid/zero cost erased the current reference'
}
$missingCostResult = [pscustomobject]@{ AccountIdentity = 'old-account' }
Update-TokenRaderWeeklyReferenceFromResult -Result $missingCostResult
Assert-UiPricing ([object]::ReferenceEquals($currentReference,$script:State.WeeklyReferenceEstimate)) 'late foreign missing cost erased the current reference'
$script:State.IntervalBaseline.AccountIdentity = 'old-account'
Update-TokenRaderWeeklyReferenceFromResult -Result ([pscustomobject]@{TotalCost=0})
Assert-UiPricing ([object]::ReferenceEquals($currentReference,$script:State.WeeklyReferenceEstimate)) 'untagged old-baseline result erased current reference'
$referenceResult.AccountIdentity = 'current-tag'; $referenceResult.TotalCost = 15
Update-TokenRaderWeeklyReferenceFromResult -Result $referenceResult
Assert-UiPricing ($script:State.WeeklyReferenceEstimate.TotalUsd -eq 1500) 'valid current result failed to update after rejecting late results'
# Plan-normalized quota dollars are separate from the unchanged API card.
$planResult = [pscustomobject]@{
    AccountIdentity='current-tag'; TotalCost=20.0; PricingComplete=$true
    PlanNormalizedTotalCost=25.0; PlanPricingComplete=$true
    QuotaPricingBasis='plan_standard_api_reference'
}
Update-TokenRaderWeeklyReferenceFromResult -Result $planResult
Assert-UiPricing ($script:State.WeeklyReferenceEstimate.TotalUsd -eq 2500) 'plan reference reused API tier cost instead of plan valuation'
Assert-UiPricing ($planResult.TotalCost -eq 20.0) 'plan reference mutated main API dollars'
Set-QuotaWindowCard -Window $window -Estimate $null -WeeklyReference $script:State.WeeklyReferenceEstimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($dollar.Text.Contains('套餐折算') -and $dollar.Text.Contains('非账单') -and -not $dollar.Text.Contains('本次API消耗')) 'plan reference presented as API billing'
$planEstimate = $estimate.PSObject.Copy()
$planEstimate | Add-Member -NotePropertyName QuotaPricingBasis -NotePropertyValue 'plan_standard_api_reference'
Set-QuotaWindowCard -Window $window -Estimate $planEstimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-UiPricing ($dollar.Text.Contains('套餐折算总额度参考') -and $dollar.Text.Contains('非账单')) 'strict plan quota did not disclose its basis'
$currentReference = $script:State.WeeklyReferenceEstimate
$untaggedPlanResult = [pscustomobject]@{ TotalCost=0; PlanNormalizedTotalCost=0; QuotaPricingBasis='plan_standard_api_reference' }
$script:State.IntervalBaseline.AccountIdentity = ''
Update-TokenRaderWeeklyReferenceFromResult -Result $untaggedPlanResult
Assert-UiPricing ([object]::ReferenceEquals($currentReference,$script:State.WeeklyReferenceEstimate)) 'untagged plan result erased a newly identified account reference'
$planResult.AccountIdentity = 'old-account'; $planResult.PlanNormalizedTotalCost = [double]::NaN
Update-TokenRaderWeeklyReferenceFromResult -Result $planResult
Assert-UiPricing ([object]::ReferenceEquals($currentReference,$script:State.WeeklyReferenceEstimate)) 'foreign invalid plan cost erased current reference'
$planResult.AccountIdentity = 'current-tag'
Update-TokenRaderWeeklyReferenceFromResult -Result $planResult
Assert-UiPricing ($null -eq $script:State.WeeklyReferenceEstimate) 'nonfinite plan cost produced dollars'
$script:State.IntervalBaseline=[pscustomobject]@{StartedAt=$now.AddMinutes(-5);AccountIdentity='current-tag';RateLimits=$null}
$script:State.RateLimits=[pscustomobject]@{FiveHour=$null;Weekly=$window}
$script:State.QuotaEstimates=[pscustomobject]@{FiveHour=$null;Weekly=$estimate}
$script:State.QuotaEstimateAccountIdentity='current-tag'
$basisSwitchResult=[pscustomobject]@{
    AccountIdentity='current-tag'; TotalCost=20.0; PricingComplete=$true
    EndRateLimits=$script:State.RateLimits; QuotaEvidence=$null
    QuotaPricingBasis='plan_standard_api_reference'
}
Update-QuotaEstimatesFromInterval -Result $basisSwitchResult
Assert-UiPricing ($null -eq $script:State.QuotaEstimates.Weekly) 'API estimate survived a switch to plan-reference basis'
Write-Output 'MEASUREMENT_PRICING_UI_TESTS_PASSED'
