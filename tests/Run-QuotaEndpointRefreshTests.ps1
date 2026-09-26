[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'TokenRader.Core.psm1') -Force
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'TokenRader.ps1')
foreach ($name in @('Get-TokenRaderQuotaDiagnostic','Get-TokenRaderQuotaDiagnosticValue',
    'Get-TokenRaderQuotaDiagnosticAccountIdentity','Test-TokenRaderQuotaDiagnosticRetained',
    'Test-TokenRaderSameQuotaEvidence','Test-TokenRaderQuotaEstimateMatchesWindow',
    'Update-QuotaEstimatesFromInterval')) {
    $match = [regex]::Match($source, '(?s)function ' + $name + '\b.*?(?=\r?\nfunction |\z)')
    if (-not $match.Success) { throw "Missing production function: $name" }
    Invoke-Expression $match.Value
}
function Assert-Endpoint([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('QUOTA ENDPOINT REFRESH TEST FAILED: ' + $Message) }
}
function Update-QuotaCards { }
function New-EndpointWindow([double]$Percent,[DateTimeOffset]$ObservedAt,[DateTimeOffset]$Reset,
        [string]$Plan='team',[string]$Pool='codex') {
    [pscustomobject]@{
        UsedPercent=$Percent; ObservedAt=$ObservedAt; ResetsAt=$Reset
        PlanType=$Plan; LimitId=$Pool; WindowMinutes=10080; ScopeConflict=$false
    }
}
function New-EndpointLimits($Window) {
    [pscustomobject]@{FiveHour=$null;Weekly=$Window;PlanType=$Window.PlanType;ObservedAt=$Window.ObservedAt}
}
function New-EndpointResult($Window,[DateTimeOffset]$StartAt,[DateTimeOffset]$CalibrationEnd) {
    $evidence=[pscustomobject]@{
        BoundaryValid=$true; AttributionComplete=$true; PricingComplete=$true; QuotaEvidenceComplete=$true
        EstimateSource='snapshot_delta_usd_estimate'; CapacitySource='percent_delta_tokens'
        EstimatedTotalUsd=500.0; TotalCost=25.0
        EndObservedAt=$CalibrationEnd; CurrentObservedAt=$Window.ObservedAt; EffectiveDeltaPercent=5.0
        StartObservedAt=$StartAt; StartUsedPercent=26.0; CalibrationEndUsedPercent=31.0
        WindowMinutes=$Window.WindowMinutes; LimitId=$Window.LimitId; PlanType=$Window.PlanType
        ResetIdentity=(Get-TokenRaderResetIdentity -WindowMinutes $Window.WindowMinutes -ResetsAt $Window.ResetsAt)
        QuotaPricingBasis='plan_standard_api_reference'; AccountIdentity='synthetic-account'
    }
    [pscustomobject]@{
        AccountIdentity='synthetic-account'; StartRateLimits=$null; EndRateLimits=(New-EndpointLimits $Window)
        PricingComplete=$true; TotalCost=20.0; QuotaPricingBasis='plan_standard_api_reference'
        EndedAt=$Window.ObservedAt; QuotaEvidence=[pscustomobject]@{FiveHour=$null;Weekly=$evidence}
        QuotaDiagnostics=[pscustomobject]@{
            FiveHour=[pscustomobject]@{ReasonCode='missing_window';Status='unavailable';Message='没有当前额度窗口';AccountIdentity='synthetic-account'}
            Weekly=[pscustomobject]@{ReasonCode='ok';Status='updated';Message='本次更新';AccountIdentity='synthetic-account'}
        }
    }
}
function Invoke-EndpointCase($Frozen,$Accepted,$Previous=$null) {
    $script:State=@{
        AccountIdentity='synthetic-account'
        IntervalBaseline=[pscustomobject]@{StartedAt=$Frozen.ObservedAt.AddMinutes(-10);AccountIdentity='synthetic-account';RateLimits=$null}
        RateLimits=(New-EndpointLimits $Accepted)
        QuotaEstimates=[pscustomobject]@{FiveHour=$null;Weekly=$Previous}
        QuotaDiagnostics=$null;QuotaEstimateAccountIdentity='synthetic-account';QuotaCalibrationMessage=''
    }
    $result=New-EndpointResult $Frozen $Frozen.ObservedAt.AddMinutes(-2) $Frozen.ObservedAt.AddMinutes(-1)
    Update-QuotaEstimatesFromInterval -Result $result
    return $result
}
$at=[DateTimeOffset]::Now
$reset=$at.AddDays(5)
$frozen=New-EndpointWindow 31 $at $reset
$later=New-EndpointWindow 35 $at.AddSeconds(10) $reset
$result=Invoke-EndpointCase $frozen $later
$estimate=$script:State.QuotaEstimates.Weekly
Assert-Endpoint ($null -ne $estimate -and [double]$estimate.TotalUsd -eq 500) 'first strict estimate lost to later same-cycle UI snapshot'
Assert-Endpoint ($estimate.CurrentObservedAt -eq $frozen.ObservedAt -and $estimate.CalibrationEndObservedAt -eq $result.QuotaEvidence.Weekly.EndObservedAt) 'frozen endpoints were rebound'
Assert-Endpoint ($script:State.QuotaDiagnostics.Weekly.ReasonCode -eq 'frozen_endpoint_waiting_refresh' -and
    $script:State.QuotaDiagnostics.Weekly.Message.Contains('等待新边界')) 'later snapshot not diagnosed'

foreach ($case in @(
    [pscustomobject]@{Name='rollback';Window=(New-EndpointWindow 30 $at.AddSeconds(10) $reset)}
    [pscustomobject]@{Name='older observation';Window=(New-EndpointWindow 35 $at.AddSeconds(-1) $reset)}
    [pscustomobject]@{Name='other plan';Window=(New-EndpointWindow 35 $at.AddSeconds(10) $reset 'pro')}
    [pscustomobject]@{Name='other pool';Window=(New-EndpointWindow 35 $at.AddSeconds(10) $reset 'team' 'other')}
    [pscustomobject]@{Name='other reset';Window=(New-EndpointWindow 35 $at.AddSeconds(10) $reset.AddDays(7))}
)) {
    [void](Invoke-EndpointCase $frozen $case.Window)
    Assert-Endpoint ($null -eq $script:State.QuotaEstimates.Weekly) ($case.Name + ' accepted stale calibration')
}
$conflict=New-EndpointWindow 35 $at.AddSeconds(10) $reset
$conflict.ScopeConflict=$true
[void](Invoke-EndpointCase $frozen $conflict)
Assert-Endpoint ($null -eq $script:State.QuotaEstimates.Weekly) 'source conflict accepted stale calibration'
$sameTimeConflict=New-EndpointWindow 31 $at $reset
$sameTimeConflict.ScopeConflict=$true
[void](Invoke-EndpointCase $frozen $sameTimeConflict)
Assert-Endpoint ($null -eq $script:State.QuotaEstimates.Weekly) 'matching fields bypassed source conflict'
$missing=New-EndpointWindow 35 $at.AddSeconds(10) $reset
$missing.PSObject.Properties.Remove('LimitId')
[void](Invoke-EndpointCase $frozen $missing)
Assert-Endpoint ($null -eq $script:State.QuotaEstimates.Weekly) 'missing pool identity accepted stale calibration'

$previous=[pscustomobject]@{
    TotalUsd=600.0; PlanType='team';WindowMinutes=10080;ResetsAt=$reset;LimitId='codex'
    CalibrationEndObservedAt=$at.AddSeconds(5);CurrentObservedAt=$at.AddSeconds(5)
    QuotaPricingBasis='plan_standard_api_reference';AccountIdentity='synthetic-account'
}
[void](Invoke-EndpointCase $frozen $later $previous)
Assert-Endpoint ([object]::ReferenceEquals($previous,$script:State.QuotaEstimates.Weekly)) 'older calibration replaced newer stored calibration'
'QUOTA_ENDPOINT_REFRESH_TESTS_PASSED'
