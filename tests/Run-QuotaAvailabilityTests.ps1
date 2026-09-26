[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'TokenRader.Core.psm1') -Force
$source=Get-Content -Raw -Encoding UTF8 (Join-Path $root 'TokenRader.ps1')
foreach($name in @('Fail-TokenRaderIndexSyncJob','Retain-TokenRaderQuotaEstimatesForCurrentWindow',
    'Test-TokenRaderQuotaEstimateMatchesWindow','Mark-TokenRaderQuotaEstimatesRetainedAfterFailure',
    'Get-TokenRaderQuotaDiagnostic','Get-TokenRaderQuotaDiagnosticValue','Set-MeasurementPricingConfirmation',
    'Get-TokenRaderCallbackContextValue')) {
    $match=[regex]::Match($source,'(?s)function '+$name+'\b.*?(?=\r?\nfunction |\z)')
    if(!$match.Success){throw "Missing production function $name"}
    Invoke-Expression $match.Value
}
function Assert-Available($ok,$message){if(!$ok){throw "QUOTA AVAILABILITY TEST FAILED: $message"}}
function Set-TokenRaderUiState {param($NewState,$StatusMessage) $script:State.UiState=$NewState}
function Update-QuotaCards {$script:Redraws++}
function Update-IntervalView {param([switch]$Manual) $script:Recomputes++}
$script:WindowClosing=$false
$script:Prices=Get-TokenRaderPrices (Join-Path $root 'pricing.json')
$script:MeasurementPricingButton=[pscustomobject]@{Content='synthetic'}
$now=[DateTimeOffset]::Now
$reset=$now.AddDays(4)
$window=[pscustomobject]@{WindowMinutes=10080;ResetsAt=$reset;PlanType='pro';LimitId='codex';UsedPercent=39}
$estimate=[pscustomobject]@{TotalUsd=500.0;WindowMinutes=10080;ResetsAt=$reset;PlanType='pro';LimitId='codex'}
function New-AvailabilityState {
    $script:State=@{
        UiState='Measuring';AccountIdentity='synthetic';IndexSyncRequestId=8L;IndexSyncing=$true;IndexReady=$true
        PendingMeasurementStart=$false;BaselineRequestId=0L;MeasurementGeneration=4L
        IntervalBaseline=[pscustomobject]@{StartedAt=$now.AddMinutes(-10)}
        IntervalEnd=[pscustomobject]@{EndedAt=$now}
        IntervalResult=[pscustomobject]@{TotalCost=20};IntervalComputing=$false
        RateLimits=[pscustomobject]@{FiveHour=$null;Weekly=$window}
        QuotaEstimates=[pscustomobject]@{FiveHour=$null;Weekly=$estimate}
        QuotaEstimateAccountIdentity='synthetic';QuotaDiagnostics=$null;QuotaCalibrationMessage=''
        ManualServiceTiers=@{'gpt-6-astra'='priority'}
        WeeklyReferenceEstimate=[pscustomobject]@{FullStepObserved=$true;TotalUsd=$null}
        IntervalCache=[pscustomobject]@{Synthetic='cache'}
    }
    $script:Redraws=0;$script:Recomputes=0
}
foreach($phase in @('Measuring','Ready','Stopping','ComputingFinal')){
    New-AvailabilityState
    $script:State.UiState=$phase
    $baseline=$script:State.IntervalBaseline;$ending=$script:State.IntervalEnd
    Fail-TokenRaderIndexSyncJob -ErrorMessage 'synthetic transient failure' -Generation 4 -RequestId 8 -Kind 'Index' -Context @{}
    Assert-Available ([object]::ReferenceEquals($estimate,$script:State.QuotaEstimates.Weekly)) "index failure erased dollars in $phase"
    Assert-Available ($script:State.UiState-eq$phase -and $script:State.MeasurementGeneration-eq4) "index failure changed measurement state in $phase"
    Assert-Available ([object]::ReferenceEquals($baseline,$script:State.IntervalBaseline) -and [object]::ReferenceEquals($ending,$script:State.IntervalEnd)) 'index failure changed measurement boundaries'
    Assert-Available ($script:State.QuotaDiagnostics.Weekly.Retained -and !$script:State.IndexSyncing) 'failure did not label retained dollars or unlock index'
}
New-AvailabilityState
$script:State.UiState='Starting'
Fail-TokenRaderIndexSyncJob -ErrorMessage 'synthetic cold failure' -Generation 4 -RequestId 8 -Kind 'Index' -Context @{ColdStart=$true}
Assert-Available ($script:State.UiState-eq'Error' -and !$script:State.IndexReady) 'cold-start failure did not unlock preparation'
New-AvailabilityState
$script:State.AccountIdentity='new-account'
Fail-TokenRaderIndexSyncJob -ErrorMessage 'synthetic failure' -Generation 4 -RequestId 8 -Kind 'Index' -Context @{}
Assert-Available ($null-eq$script:State.QuotaEstimates) 'foreign-account dollars survived failure'
New-AvailabilityState
$script:State.RateLimits.Weekly=$window.PSObject.Copy()
$script:State.RateLimits.Weekly.ResetsAt=$reset.AddDays(7)
Fail-TokenRaderIndexSyncJob -ErrorMessage 'synthetic failure' -Generation 4 -RequestId 8 -Kind 'Index' -Context @{}
Assert-Available ($null-eq$script:State.QuotaEstimates) 'other-cycle dollars survived failure'

New-AvailabilityState
$cache=$script:State.IntervalCache;$reference=$script:State.WeeklyReferenceEstimate
Assert-Available (Set-MeasurementPricingConfirmation -Selections @{'gpt-6-astra'='fast'}) 'identical normalized tier was rejected'
Assert-Available ([object]::ReferenceEquals($estimate,$script:State.QuotaEstimates.Weekly) -and
    [object]::ReferenceEquals($cache,$script:State.IntervalCache) -and
    [object]::ReferenceEquals($reference,$script:State.WeeklyReferenceEstimate)) 'same pricing confirmation erased valid state'
Assert-Available ($script:Recomputes-eq0 -and $script:Redraws-eq1) 'same pricing confirmation launched redundant calculation'
Assert-Available (Set-MeasurementPricingConfirmation -Selections @{'gpt-6-astra'='standard'}) 'changed pricing was rejected'
Assert-Available ($null-eq$script:State.QuotaEstimates -and $null-eq$script:State.IntervalCache -and $script:Recomputes-eq1) 'real pricing change reused incompatible dollars'

# First-ever calibration failure has no estimate owner. Do not erase its
# independent, current-result reason during the card's retention pass.
New-AvailabilityState
$script:State.QuotaEstimates=[pscustomobject]@{FiveHour=$null;Weekly=$null}
$script:State.QuotaEstimateAccountIdentity=''
$reason=[pscustomobject]@{ReasonCode='unknown_attribution';Message='synthetic specific reason';AccountIdentity='synthetic'}
$script:State.QuotaDiagnostics=[pscustomobject]@{FiveHour=$null;Weekly=$reason}
Retain-TokenRaderQuotaEstimatesForCurrentWindow
Assert-Available ($null-eq$script:State.QuotaEstimates -and
    [object]::ReferenceEquals($reason,$script:State.QuotaDiagnostics.Weekly)) 'first unavailable result lost its concrete diagnostic'
Retain-TokenRaderQuotaEstimatesForCurrentWindow
Assert-Available ([object]::ReferenceEquals($reason,$script:State.QuotaDiagnostics.Weekly)) 'repeated redraw erased diagnostic'
$script:State.QuotaEstimates=[pscustomobject]@{FiveHour=$null;Weekly=$null}
$reason.AccountIdentity='foreign'
Retain-TokenRaderQuotaEstimatesForCurrentWindow
Assert-Available ($null-eq$script:State.QuotaDiagnostics.Weekly) 'foreign diagnostic passed empty-estimate retention'

# Exercise the actual redraw path responsible for the screenshot's generic
# message: no estimates, current window at 15%, completed measurement step 3%.
foreach($name in @('Update-QuotaCards','Set-QuotaWindowCard','Get-TokenRaderQuotaDiagnosticMessage',
    'Test-TokenRaderQuotaDiagnosticRetained')) {
    $match=[regex]::Match($source,'(?s)function '+$name+'\b.*?(?=\r?\nfunction |\z)')
    Invoke-Expression $match.Value
}
function Update-TokenRaderQuotaPlanLabel { }
foreach($name in @('FiveHourUsageText','FiveHourDollarText','FiveHourResetText',
    'WeeklyUsageText','WeeklyDollarText','WeeklyResetText','QuotaEstimateHintText')) {
    Set-Variable -Scope Script -Name $name -Value ([pscustomobject]@{Text=''})
}
$script:FiveHourProgress=[pscustomobject]@{Value=0}
$script:WeeklyProgress=[pscustomobject]@{Value=0}
New-AvailabilityState
$script:State.RateLimits.Weekly=$window.PSObject.Copy()
$script:State.RateLimits.Weekly.UsedPercent=15
$script:State.QuotaEstimates=[pscustomobject]@{FiveHour=$null;Weekly=$null}
$script:State.QuotaEstimateAccountIdentity=''
$reason.AccountIdentity='synthetic'
$script:State.QuotaDiagnostics=[pscustomobject]@{FiveHour=$null;Weekly=$reason}
$script:State.WeeklyReferenceEstimate=[pscustomobject]@{TotalUsd=$null;ActualDeltaPercent=3;FullStepObserved=$true}
Update-QuotaCards
Assert-Available ($script:WeeklyDollarText.Text.Contains('synthetic specific reason') -and
    $script:WeeklyUsageText.Text-eq'15%') 'real card redraw hid the concrete first-calibration rejection'
'QUOTA_AVAILABILITY_TESTS_PASSED'
