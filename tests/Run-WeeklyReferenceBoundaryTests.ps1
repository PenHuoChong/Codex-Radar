[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'TokenRader.ps1')
foreach ($name in @('Set-QuotaWindowCard', 'Update-TokenRaderWeeklyReferenceFromResult')) {
    $match = [regex]::Match($source, '(?s)function ' + $name + '\b.*?(?=\r?\nfunction |\z)')
    if (-not $match.Success) { throw "Missing production function: $name" }
    Invoke-Expression $match.Value
}

# Keep this focused test independent of diagnostic formatting while still
# exercising the extracted production card and updater functions.
function Get-TokenRaderQuotaDiagnosticMessage {
    param($Diagnostic, [string]$Fallback)
    if ($null -ne $Diagnostic -and $null -ne $Diagnostic.PSObject.Properties['Message'] -and
        -not [string]::IsNullOrWhiteSpace([string]$Diagnostic.Message)) {
        return [string]$Diagnostic.Message
    }
    return $Fallback
}
function Get-TokenRaderQuotaDiagnosticValue {
    param($Diagnostic, [string]$Name, $Default)
    if ($null -eq $Diagnostic -or $null -eq $Diagnostic.PSObject.Properties[$Name] -or
        $null -eq $Diagnostic.PSObject.Properties[$Name].Value) { return $Default }
    return $Diagnostic.PSObject.Properties[$Name].Value
}
function Test-TokenRaderQuotaDiagnosticRetained { param($Diagnostic) return $false }
function Assert-WeeklyReferenceBoundary([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "WEEKLY REFERENCE BOUNDARY TEST FAILED: $Message" }
}

$now = [DateTimeOffset]::Now
$reset = $now.AddDays(5)
$script:State = @{
    AccountIdentity = 'synthetic-account'
    IntervalBaseline = [pscustomobject]@{
        StartedAt = $now.AddMinutes(-5)
        AccountIdentity = 'synthetic-account'
        RateLimits = $null
    }
}
$startWeek = [pscustomobject]@{
    UsedPercent = 30.0
    WindowMinutes = 10080
    PlanType = 'synthetic-plan'
    ResetsAt = $reset
    LimitId = 'codex'
}
$endWeek = $startWeek.PSObject.Copy()
$result = [pscustomobject]@{
    AccountIdentity = 'synthetic-account'
    TotalCost = 47.2
    PlanNormalizedTotalCost = 59.0
    PlanPricingComplete = $true
    QuotaPricingBasis = 'plan_standard_api_reference'
    PricingComplete = $true
    StartRateLimits = [pscustomobject]@{ Weekly = $startWeek }
    EndRateLimits = [pscustomobject]@{ Weekly = $endWeek }
}
$usage = [pscustomobject]@{ Text = '' }
$progress = [pscustomobject]@{ Value = 0 }
$dollar = [pscustomobject]@{ Text = '' }
$resetText = [pscustomobject]@{ Text = '' }

# A reliable +5-point current-cycle delta is enough to disqualify the 1%
# reference, even when no strict frozen-boundary estimate is available. Do not
# substitute either $5,900 or an unaligned $1,180 estimate in that case.
$endWeek.UsedPercent = 35.0
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$reference = $script:State.WeeklyReferenceEstimate
Assert-WeeklyReferenceBoundary ($null -eq $reference.TotalUsd -and [bool]$reference.FullStepObserved -and
    [Math]::Abs([double]$reference.ActualDeltaPercent - 5.0) -lt 0.000001) 'updater did not latch the synthetic +5% full step'
Set-QuotaWindowCard -Window $endWeek -Estimate $null -WeeklyReference $reference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyReferenceBoundary (-not $dollar.Text.Contains((Format-TokenRaderUsd 5900.0)) -and
    -not $dollar.Text.Contains((Format-TokenRaderUsd 1180.0)) -and
    -not $dollar.Text.Contains('USD 1180')) 'reliable full-step delta displayed a 1% reference or invented strict calibration'

# A later missing endpoint must not erase the completed-step latch and
# accidentally restore the 1% reference for this measurement.
$result.EndRateLimits = $null
Update-TokenRaderWeeklyReferenceFromResult -Result $result
Set-QuotaWindowCard -Window $endWeek -Estimate $null -WeeklyReference $script:State.WeeklyReferenceEstimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyReferenceBoundary (-not $dollar.Text.Contains((Format-TokenRaderUsd 5900.0)) -and
    -not $dollar.Text.Contains((Format-TokenRaderUsd 1180.0))) 'missing endpoint restored the 1% reference after a completed step'
$result.PlanNormalizedTotalCost = 0.0
Update-TokenRaderWeeklyReferenceFromResult -Result $result
Assert-WeeklyReferenceBoundary ([bool]$script:State.WeeklyReferenceEstimate.FullStepObserved -and
    $null -eq $script:State.WeeklyReferenceEstimate.TotalUsd) 'zero cost erased the full-step marker'
$result.PlanNormalizedTotalCost = 59.0
Update-TokenRaderWeeklyReferenceFromResult -Result $result
Assert-WeeklyReferenceBoundary ($null -eq $script:State.WeeklyReferenceEstimate.TotalUsd) 'zero cost followed by a missing snapshot reopened 1%'
$result.EndRateLimits = [pscustomobject]@{ Weekly = $endWeek }

# Keep the requested 1% yardstick for a reliable sub-1-point delta.
$script:State.WeeklyReferenceEstimate = $null
$endWeek.UsedPercent = 30.99
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$reference = $script:State.WeeklyReferenceEstimate
Set-QuotaWindowCard -Window $endWeek -Estimate $null -WeeklyReference $reference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyReferenceBoundary ($dollar.Text.Contains((Format-TokenRaderUsd 5900.0)) -and
    [double]$reference.ActualDeltaPercent -lt 1.0) 'sub-1-point delta lost the 1% reference'

# With a valid strict estimate, the actual frozen calibration remains the
# displayed dollar source once the current-cycle delta reaches one point.
$endWeek.UsedPercent = 35.0
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$reference = $script:State.WeeklyReferenceEstimate
$strictEstimate = [pscustomobject]@{
    TotalUsd = 1180.0
    UsedUsd = 413.0
    RemainingUsd = 767.0
    WindowMinutes = 10080
    PlanType = 'synthetic-plan'
    ResetsAt = $reset
    CurrentObservedAt = $now
    EstimateSource = 'snapshot_delta_usd_estimate'
    IdentityComplete = $true
    StartUsedPercent = 30.0
    EffectiveDeltaPercent = 5.0
    QuotaPricingBasis = 'plan_standard_api_reference'
}
Set-QuotaWindowCard -Window $endWeek -Estimate $strictEstimate -WeeklyReference $reference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyReferenceBoundary ($dollar.Text.Contains((Format-TokenRaderUsd 1180.0)) -and
    -not $dollar.Text.Contains((Format-TokenRaderUsd 5900.0))) 'valid strict calibration did not take precedence over the 1% reference'

# Explicitly entering a new reset cycle can establish a fresh sub-percent reference.
$endWeek = $endWeek.PSObject.Copy()
$startWeek = $startWeek.PSObject.Copy()
$endWeek.ResetsAt = $reset.AddDays(7)
$startWeek.ResetsAt = $endWeek.ResetsAt
$startWeek.UsedPercent = 0.0
$endWeek.UsedPercent = 0.5
$result.StartRateLimits = [pscustomobject]@{ Weekly = $startWeek }
$result.EndRateLimits = [pscustomobject]@{ Weekly = $endWeek }
Update-TokenRaderWeeklyReferenceFromResult -Result $result
Assert-WeeklyReferenceBoundary (-not [bool]$script:State.WeeklyReferenceEstimate.FullStepObserved -and
    $script:State.WeeklyReferenceEstimate.TotalUsd -eq 5900.0) 'new reset cycle inherited the old full-step marker'

# Unknown deltas must not masquerade as a sub-1% observation.
foreach ($invalidPercent in @('malformed', [double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity)) {
    # Reset the measurement so an earlier completed step cannot be inherited.
    $script:State.WeeklyReferenceEstimate = $null
    $endWeek.UsedPercent = $invalidPercent
    Update-TokenRaderWeeklyReferenceFromResult -Result $result
    $reference = $script:State.WeeklyReferenceEstimate
    Assert-WeeklyReferenceBoundary ($null -eq $reference.ActualDeltaPercent) "invalid percent '$invalidPercent' produced a delta"

    # Supply a separately valid display window to isolate the unknown-delta
    # compatibility branch from current-window percent validation.
    $displayWindow = $endWeek.PSObject.Copy()
    $displayWindow.UsedPercent = 35.0
    Set-QuotaWindowCard -Window $displayWindow -Estimate $null -WeeklyReference $reference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
    Assert-WeeklyReferenceBoundary ($null -eq $reference.TotalUsd -and -not $dollar.Text.Contains((Format-TokenRaderUsd 5900.0))) "unknown delta fabricated 1% dollars for invalid percent '$invalidPercent'"
}

Write-Output 'Weekly reference boundary tests passed.'
