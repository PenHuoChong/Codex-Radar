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
    if (-not $match.Success) { throw ('Missing production function: ' + $name) }
    Invoke-Expression $match.Value
}
function Assert-Isolation([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('QUOTA WINDOW ISOLATION TEST FAILED: ' + $Message) }
}
function Update-QuotaCards { }
$script:MockEstimate=$null
$script:ConversionCalls=0
function Get-TokenRaderQuotaEstimate {
    param($StartRateLimits,$EndRateLimits,$IntervalCost,$CostComplete,$StartReferenceAt,$EndReferenceAt,$QuotaEvidence)
    $script:ConversionCalls++
    return $script:MockEstimate
}
function New-TestDiagnostic([string]$Account) {
    [pscustomobject]@{AccountIdentity=$Account;Status='unavailable';ReasonCode='pricing_incomplete';Message='synthetic retry';Retained=$false}
}
function New-TestEstimate([double]$Usd,$Window,[DateTimeOffset]$CalibrationEnd) {
    [pscustomobject]@{
        TotalUsd=$Usd;PlanType=$Window.PlanType;WindowMinutes=$Window.WindowMinutes
        ResetsAt=$Window.ResetsAt;LimitId=$Window.LimitId;AccountIdentity='current'
        QuotaPricingBasis='api_equivalent';CalibrationEndObservedAt=$CalibrationEnd
    }
}
function Invoke-IsolationCase($PreviousFive,$PreviousWeekly,$NewFive,$NewWeekly,
        [string]$FiveDiagnosticAccount,[string]$WeeklyDiagnosticAccount,[string]$ResultAccount='current') {
    $script:MockEstimate=[pscustomobject]@{FiveHour=$NewFive;Weekly=$NewWeekly}
    $script:State=@{
        AccountIdentity='current';IntervalBaseline=[pscustomobject]@{StartedAt=$at.AddMinutes(-10);AccountIdentity='current';RateLimits=$null}
        RateLimits=[pscustomobject]@{FiveHour=$fiveWindow;Weekly=$weekWindow;PlanType='team'}
        QuotaEstimates=[pscustomobject]@{FiveHour=$PreviousFive;Weekly=$PreviousWeekly}
        QuotaEstimateAccountIdentity='current';QuotaDiagnostics=$null;QuotaCalibrationMessage=''
    }
    $result=[pscustomobject]@{
        AccountIdentity=$ResultAccount;StartRateLimits=$null;EndRateLimits=$script:State.RateLimits
        TotalCost=1.0;PricingComplete=$false;QuotaPricingBasis='api_equivalent';EndedAt=$at
        QuotaEvidence=[pscustomobject]@{FiveHour=$null;Weekly=$null}
        QuotaDiagnostics=[pscustomobject]@{
            FiveHour=(New-TestDiagnostic $FiveDiagnosticAccount)
            Weekly=(New-TestDiagnostic $WeeklyDiagnosticAccount)
        }
    }
    Update-QuotaEstimatesFromInterval -Result $result
}
$at=[DateTimeOffset]::Now
$fiveWindow=[pscustomobject]@{UsedPercent=20;ObservedAt=$at;PlanType='team';WindowMinutes=300;ResetsAt=$at.AddHours(4);LimitId='codex'}
$weekWindow=[pscustomobject]@{UsedPercent=30;ObservedAt=$at;PlanType='team';WindowMinutes=10080;ResetsAt=$at.AddDays(5);LimitId='codex'}
$oldFive=New-TestEstimate 100 $fiveWindow $at.AddMinutes(-3)
$oldWeekly=New-TestEstimate 500 $weekWindow $at.AddMinutes(-3)
Invoke-IsolationCase $oldFive $oldWeekly $null $null 'foreign' 'current'
Assert-Isolation ($null -eq $script:State.QuotaEstimates.FiveHour -and
    [object]::ReferenceEquals($oldWeekly,$script:State.QuotaEstimates.Weekly)) 'foreign five-hour diagnostic erased valid weekly dollars'
Assert-Isolation ($script:State.QuotaDiagnostics.FiveHour.ReasonCode -eq 'account_boundary' -and
    $script:State.QuotaDiagnostics.Weekly.Retained) 'foreign diagnostic leaked or weekly reuse was unlabeled'

Invoke-IsolationCase $oldFive $oldWeekly $null $null 'current' 'foreign'
Assert-Isolation ([object]::ReferenceEquals($oldFive,$script:State.QuotaEstimates.FiveHour) -and
    $null -eq $script:State.QuotaEstimates.Weekly) 'foreign weekly diagnostic erased valid five-hour dollars'

$newFive=New-TestEstimate 120 $fiveWindow $at.AddMinutes(-1)
$newWeekly=New-TestEstimate 520 $weekWindow $at.AddMinutes(-1)
Invoke-IsolationCase $null $null $newFive $newWeekly 'foreign' 'current'
Assert-Isolation ($null -eq $script:State.QuotaEstimates.FiveHour -and
    [object]::ReferenceEquals($newWeekly,$script:State.QuotaEstimates.Weekly)) 'foreign five-hour diagnostic admitted new dollars or blocked weekly dollars'
Invoke-IsolationCase $null $null $newFive $newWeekly 'current' 'foreign'
Assert-Isolation ([object]::ReferenceEquals($newFive,$script:State.QuotaEstimates.FiveHour) -and
    $null -eq $script:State.QuotaEstimates.Weekly) 'foreign weekly diagnostic admitted new dollars or blocked five-hour dollars'

$callsBefore=$script:ConversionCalls
Invoke-IsolationCase $oldFive $oldWeekly $newFive $newWeekly 'current' 'current' 'foreign'
Assert-Isolation ($script:ConversionCalls -eq $callsBefore -and
    $null -eq $script:State.QuotaEstimates.FiveHour -and $null -eq $script:State.QuotaEstimates.Weekly) 'foreign result bypassed global account gate'

$newOlder=New-TestEstimate 450 $weekWindow $at.AddMinutes(-4)
Invoke-IsolationCase $oldFive $oldWeekly $newFive $newOlder 'foreign' 'current'
Assert-Isolation ($null -eq $script:State.QuotaEstimates.FiveHour -and
    [object]::ReferenceEquals($oldWeekly,$script:State.QuotaEstimates.Weekly)) 'foreign five-hour diagnostic disabled newer weekly calibration guard'
'QUOTA_WINDOW_ISOLATION_TESTS_PASSED'
