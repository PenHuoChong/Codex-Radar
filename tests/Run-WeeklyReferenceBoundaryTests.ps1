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

# An explicitly missing start snapshot may support only a clearly labelled
# hypothetical 1% reference when the end window itself is valid. It is never
# a strict calibrated estimate and must not be treated as a measured delta.
$script:State.WeeklyReferenceEstimate = $null
$script:State.IntervalBaseline.RateLimits = $null
$missingStartEndWeek = [pscustomobject]@{
    UsedPercent = 23.0
    WindowMinutes = 10080
    PlanType = 'synthetic-plan'
    LimitId = 'codex'
    ResetsAt = $reset
    ObservedAt = $now
}
$result.AccountIdentity = 'synthetic-account'
$result.StartRateLimits = $null
$result.EndRateLimits = [pscustomobject]@{ Weekly = $missingStartEndWeek }
$result.TotalCost = 47.2
$result.PlanNormalizedTotalCost = 59.0
$result.PlanPricingComplete = $true
$result.QuotaPricingBasis = 'plan_standard_api_reference'
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$missingStartReference = $script:State.WeeklyReferenceEstimate
$assumptionProperty = if ($null -ne $missingStartReference) { $missingStartReference.PSObject.Properties['ReferenceAssumptionApplied'] } else { $null }
Assert-WeeklyReferenceBoundary ($null -ne $missingStartReference -and $missingStartReference.TotalUsd -eq 5900.0 -and
    $null -eq $missingStartReference.ActualDeltaPercent -and $null -ne $assumptionProperty -and
    [bool]$assumptionProperty.Value -and -not [bool]$missingStartReference.FullStepObserved) 'valid end-only evidence did not create a non-strict hypothetical 1% reference'
$onePercentAssumptionLabel = -join @([char]0x5047, [char]0x8BBE, '1%')
$notCalibratedLabel = -join @([char]0x5C1A, [char]0x672A, [char]0x6821, [char]0x51C6)
Set-QuotaWindowCard -Window $missingStartEndWeek -Estimate $null -WeeklyReference $missingStartReference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyReferenceBoundary ($dollar.Text.Contains($onePercentAssumptionLabel) -and $dollar.Text.Contains($notCalibratedLabel) -and
    $dollar.Text.Contains((Format-TokenRaderUsd 5900.0))) 'hypothetical 1% display was not labelled as assumed and not yet calibrated'

# A real strict estimate continues to win over the hypothetical display value.
$missingStartStrictEstimate = [pscustomobject]@{
    TotalUsd = 1234.5
    UsedUsd = 283.935
    RemainingUsd = 950.565
    WindowMinutes = 10080
    PlanType = 'synthetic-plan'
    ResetsAt = $reset
    CurrentObservedAt = $now
    EstimateSource = 'snapshot_delta_usd_estimate'
    IdentityComplete = $true
    StartUsedPercent = 21.0
    EffectiveDeltaPercent = 2.0
    QuotaPricingBasis = 'plan_standard_api_reference'
}
Set-QuotaWindowCard -Window $missingStartEndWeek -Estimate $missingStartStrictEstimate -WeeklyReference $missingStartReference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyReferenceBoundary ($dollar.Text.Contains((Format-TokenRaderUsd 1234.5)) -and
    -not $dollar.Text.Contains((Format-TokenRaderUsd 5900.0))) 'hypothetical 1% reference overrode a valid strict estimate'

# Once valid frozen endpoints establish a full step, retain that latch and do
# not fall back to 1%, including after a later result omits its start snapshot.
$missingStartStartWeek = $missingStartEndWeek.PSObject.Copy()
$missingStartStartWeek.UsedPercent = 21.0
$missingStartStartWeek.ObservedAt = $now.AddMinutes(-1)
$result.StartRateLimits = [pscustomobject]@{ Weekly = $missingStartStartWeek }
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$fullStepReference = $script:State.WeeklyReferenceEstimate
$assumptionProperty = $fullStepReference.PSObject.Properties['ReferenceAssumptionApplied']
Assert-WeeklyReferenceBoundary ([bool]$fullStepReference.FullStepObserved -and
    [Math]::Abs([double]$fullStepReference.ActualDeltaPercent - 2.0) -lt 0.000001 -and
    $null -eq $fullStepReference.TotalUsd -and ($null -eq $assumptionProperty -or -not [bool]$assumptionProperty.Value)) 'valid +2% endpoints did not disable the hypothetical 1% reference'
$result.StartRateLimits = $null
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$missingStartAfterFullStep = $script:State.WeeklyReferenceEstimate
$assumptionProperty = $missingStartAfterFullStep.PSObject.Properties['ReferenceAssumptionApplied']
Assert-WeeklyReferenceBoundary ([bool]$missingStartAfterFullStep.FullStepObserved -and
    $null -eq $missingStartAfterFullStep.TotalUsd -and ($null -eq $assumptionProperty -or -not [bool]$assumptionProperty.Value)) 'missing start reopened the hypothetical 1% reference after a full step'

# Reject malformed end-window identity, foreign-account results, and
# conflicting reset identities rather than turning any of them into 1% dollars.
$script:State.WeeklyReferenceEstimate = $null
$invalidEndWeek = $missingStartEndWeek.PSObject.Copy()
$invalidEndWeek.LimitId = 'model-specific'
$result.StartRateLimits = $null
$result.EndRateLimits = [pscustomobject]@{ Weekly = $invalidEndWeek }
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$invalidEndReference = $script:State.WeeklyReferenceEstimate
Assert-WeeklyReferenceBoundary ($null -eq $invalidEndReference -or
    ($null -eq $invalidEndReference.TotalUsd -and -not [bool]$invalidEndReference.PSObject.Properties['ReferenceAssumptionApplied'].Value)) 'invalid end-window identity received a hypothetical 1% reference'

$script:State.WeeklyReferenceEstimate = $null
$result.EndRateLimits = [pscustomobject]@{ Weekly = $missingStartEndWeek }
$result.AccountIdentity = 'foreign-synthetic-account'
Update-TokenRaderWeeklyReferenceFromResult -Result $result
Assert-WeeklyReferenceBoundary ($null -eq $script:State.WeeklyReferenceEstimate) 'foreign-account result wrote a hypothetical weekly reference'

$script:State.WeeklyReferenceEstimate = $null
$result.AccountIdentity = 'synthetic-account'
$conflictingStartWeek = $missingStartStartWeek.PSObject.Copy()
$conflictingStartWeek.ResetsAt = $reset.AddDays(1)
$result.StartRateLimits = [pscustomobject]@{ Weekly = $conflictingStartWeek }
$result.EndRateLimits = [pscustomobject]@{ Weekly = $missingStartEndWeek }
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$resetConflictReference = $script:State.WeeklyReferenceEstimate
Assert-WeeklyReferenceBoundary ($null -eq $resetConflictReference -or
    ($null -eq $resetConflictReference.TotalUsd -and -not [bool]$resetConflictReference.PSObject.Properties['ReferenceAssumptionApplied'].Value)) 'reset-conflicting endpoints received a hypothetical 1% reference'

# The missing-start exception still requires a valid, current regular window.
foreach ($guardCase in @('expired-reset','scope-conflict','nan-percent','missing-observed-at')) {
    $script:State.WeeklyReferenceEstimate = $null
    $result.AccountIdentity = 'synthetic-account'
    $result.StartRateLimits = $null
    $candidateEndWeek = $missingStartEndWeek.PSObject.Copy()
    switch ($guardCase) {
        'expired-reset' { $candidateEndWeek.ResetsAt = $now.AddMinutes(-1) }
        'scope-conflict' { $candidateEndWeek | Add-Member -NotePropertyName ScopeConflict -NotePropertyValue $true -Force }
        'nan-percent' { $candidateEndWeek.UsedPercent = [double]::NaN }
        'missing-observed-at' { [void]$candidateEndWeek.PSObject.Properties.Remove('ObservedAt') }
    }
    $result.EndRateLimits = [pscustomobject]@{ Weekly = $candidateEndWeek }
    Update-TokenRaderWeeklyReferenceFromResult -Result $result
    $guardReference = $script:State.WeeklyReferenceEstimate
    $guardAssumptionProperty = if ($null -ne $guardReference) { $guardReference.PSObject.Properties['ReferenceAssumptionApplied'] } else { $null }
    Assert-WeeklyReferenceBoundary ($null -eq $guardReference -or
        ($null -eq $guardReference.TotalUsd -and ($null -eq $guardAssumptionProperty -or -not [bool]$guardAssumptionProperty.Value))) "missing-start guard '$guardCase' produced a hypothetical 1% reference"
}

# A previously valid provisional reference must not leak onto a different reset
# cycle or into a UI now bound to another account.
$script:State.AccountIdentity = 'synthetic-account'
$changedResetWindow = $missingStartEndWeek.PSObject.Copy()
$changedResetWindow.ResetsAt = $reset.AddDays(1)
Set-QuotaWindowCard -Window $changedResetWindow -Estimate $null -WeeklyReference $missingStartReference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyReferenceBoundary (-not $dollar.Text.Contains($onePercentAssumptionLabel) -and
    -not $dollar.Text.Contains((Format-TokenRaderUsd 5900.0))) 'prior hypothetical 1% reference appeared against a changed reset cycle'
$script:State.AccountIdentity = 'foreign-synthetic-account'
Set-QuotaWindowCard -Window $missingStartEndWeek -Estimate $null -WeeklyReference $missingStartReference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyReferenceBoundary (-not $dollar.Text.Contains($onePercentAssumptionLabel) -and
    -not $dollar.Text.Contains((Format-TokenRaderUsd 5900.0))) 'prior hypothetical 1% reference appeared for a foreign current account'
$script:State.AccountIdentity = 'synthetic-account'

Write-Output 'Weekly reference boundary tests passed.'
