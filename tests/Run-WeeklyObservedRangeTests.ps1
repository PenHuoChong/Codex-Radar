[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'TokenRader.ps1')
foreach ($name in @('Get-TokenRaderQuotaDiagnosticValue','Get-TokenRaderQuotaDiagnosticMessage',
        'Test-TokenRaderQuotaDiagnosticRetained','Set-QuotaWindowCard','Update-TokenRaderWeeklyReferenceFromResult')) {
    $match = [regex]::Match($source, '(?s)function ' + $name + '\b.*?(?=\r?\nfunction |\z)')
    if (-not $match.Success) { throw "Missing production function: $name" }
    Invoke-Expression $match.Value
}

# Build expected Chinese UI text from code points to keep this source ASCII-only
# and compatible with Windows PowerShell 5.1's script-file encoding behavior.
function ConvertFrom-CodePointList {
    param([int[]]$CodePoints)
    $characters = New-Object 'System.Collections.Generic.List[char]'
    foreach ($codePoint in $CodePoints) { $characters.Add([char]$codePoint) }
    return -join $characters.ToArray()
}
function Assert-WeeklyObservedRange([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "WEEKLY OBSERVED RANGE TEST FAILED: $Message" }
}
function New-WeeklySnapshot {
    param(
        [double]$UsedPercent,
        [DateTimeOffset]$ResetsAt,
        [string]$PlanType = 'synthetic-plan',
        [string]$LimitId = 'codex',
        [bool]$ScopeConflict = $false
    )
    return [pscustomobject]@{
        UsedPercent = $UsedPercent
        WindowMinutes = 10080
        PlanType = $PlanType
        ResetsAt = $ResetsAt
        LimitId = $LimitId
        ScopeConflict = $ScopeConflict
    }
}
function Set-SyntheticState {
    param($BaselineStartRateLimits, $BaselineRateLimits, [string]$BaselineAccount = 'synthetic-account')
    $script:State = @{
        AccountIdentity = 'synthetic-account'
        IntervalBaseline = [pscustomobject]@{
            StartedAt = [DateTimeOffset]::Now.AddHours(-2)
            AccountIdentity = $BaselineAccount
            StartRateLimits = $BaselineStartRateLimits
            RateLimits = $BaselineRateLimits
        }
    }
}
function New-WeeklyResult {
    param($StartRateLimits, $EndRateLimits, [string]$Account = 'synthetic-account', [double]$Cost = 37.382522)
    return [pscustomobject]@{
        AccountIdentity = $Account
        TotalCost = $Cost
        PricingComplete = $true
        StartRateLimits = $StartRateLimits
        EndRateLimits = $EndRateLimits
    }
}

$rangePrefix = ConvertFrom-CodePointList @(0x672C,0x6B21,0x7528,0x91CF,0x533A,0x95F4)
$deltaLabel = ConvertFrom-CodePointList @(0x533A,0x95F4)
$unknownRange = ConvertFrom-CodePointList @(0x672C,0x6B21,0x7528,0x91CF,0x533A,0x95F4,0xFF1A,0x672A,0x63D0,0x4F9B,0x6709,0x6548,0x8D77,0x6B62,0x5FEB,0x7167)
$arrow = ConvertFrom-CodePointList @(0x2192)
$separator = ConvertFrom-CodePointList @(0x00B7)
$now = [DateTimeOffset]::Now
$resetUtc = $now.AddDays(7).ToUniversalTime()
$resetOffset = $resetUtc.ToOffset([TimeSpan]::FromHours(8))
$start = New-WeeklySnapshot -UsedPercent 16.0 -ResetsAt $resetUtc
$end = New-WeeklySnapshot -UsedPercent 18.0 -ResetsAt $resetOffset
$baselineStart = [pscustomobject]@{ Weekly = $start }
$endRateLimits = [pscustomobject]@{ Weekly = $end }
$usage = [pscustomobject]@{ Text = '' }
$progress = [pscustomobject]@{ Value = 0 }
$dollar = [pscustomobject]@{ Text = '' }
$resetText = [pscustomobject]@{ Text = '' }
$unknownAttribution = [pscustomobject]@{
    Status = 'unavailable'
    ReasonCode = 'unknown_attribution'
    Message = 'unknown_attribution: strict cost attribution is incomplete'
    Retained = $false
}

# The same reset instant expressed in UTC and +08:00 is one cycle, not an
# unknown delta. A 16% -> 18% observed delta must not display cost x 100.
Set-SyntheticState -BaselineStartRateLimits $baselineStart -BaselineRateLimits $null
$result = New-WeeklyResult -StartRateLimits $null -EndRateLimits $endRateLimits
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$reference = $script:State.WeeklyReferenceEstimate
Assert-WeeklyObservedRange ($null -eq $reference.TotalUsd -and
    [Math]::Abs([double]$reference.ActualDeltaPercent - 2.0) -lt 0.000001 -and
    [double]$reference.MeasurementStartUsedPercent -eq 16.0 -and
    [double]$reference.MeasurementEndUsedPercent -eq 18.0) 'timezone-equivalent resets or baseline start fallback did not yield a known +2-point range'
Set-QuotaWindowCard -Window $end -Estimate $null -WeeklyReference $reference -Diagnostic $unknownAttribution -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
$expectedTwoPointRange = "$rangePrefix 16% $arrow 18% $separator $deltaLabel 2%"
Assert-WeeklyObservedRange ($dollar.Text.Contains($expectedTwoPointRange) -and
    $dollar.Text.Contains('unknown_attribution') -and
    -not $dollar.Text.Contains((Format-TokenRaderUsd 3738.2522))) 'full-step observation lost its own range/reason or displayed 1% reference dollars'

# A legacy baseline may have only RateLimits; a missing StartRateLimits
# property on the result must still recover that compatible starting window.
$baselineOnlyRateLimits = [pscustomobject]@{ Weekly = $start }
Set-SyntheticState -BaselineStartRateLimits $null -BaselineRateLimits $baselineOnlyRateLimits
$result = [pscustomobject]@{
    AccountIdentity = 'synthetic-account'
    TotalCost = 37.382522
    PricingComplete = $true
    EndRateLimits = $endRateLimits
}
Update-TokenRaderWeeklyReferenceFromResult -Result $result
Assert-WeeklyObservedRange ([Math]::Abs([double]$script:State.WeeklyReferenceEstimate.ActualDeltaPercent - 2.0) -lt 0.000001 -and
    $null -eq $script:State.WeeklyReferenceEstimate.TotalUsd) 'legacy RateLimits baseline was not used when StartRateLimits is absent'

# With no valid start endpoint, the delta is unknown, not zero or an implied
# 1%; retain the explicit strict diagnostic and show no dollar amount.
Set-SyntheticState -BaselineStartRateLimits $null -BaselineRateLimits $null
$result = New-WeeklyResult -StartRateLimits $null -EndRateLimits $endRateLimits
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$reference = $script:State.WeeklyReferenceEstimate
Assert-WeeklyObservedRange ($null -eq $reference.ActualDeltaPercent -and $null -eq $reference.TotalUsd) 'unknown initial delta generated a 1% reference amount'
Set-QuotaWindowCard -Window $end -Estimate $null -WeeklyReference $reference -Diagnostic $unknownAttribution -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyObservedRange ($dollar.Text.Contains($unknownRange) -and
    $dollar.Text.Contains('unknown_attribution') -and
    -not $dollar.Text.Contains((Format-TokenRaderUsd 3738.2522))) 'unknown delta did not show an explicit reason or fabricated 1% dollars'

# A known same-cycle sub-1-point change keeps the user's 1% reference rule.
$halfPointEnd = New-WeeklySnapshot -UsedPercent 16.5 -ResetsAt $resetOffset
$halfPointEndLimits = [pscustomobject]@{ Weekly = $halfPointEnd }
Set-SyntheticState -BaselineStartRateLimits $baselineStart -BaselineRateLimits $null
$result = New-WeeklyResult -StartRateLimits $null -EndRateLimits $halfPointEndLimits
Update-TokenRaderWeeklyReferenceFromResult -Result $result
$reference = $script:State.WeeklyReferenceEstimate
Assert-WeeklyObservedRange ([Math]::Abs([double]$reference.ActualDeltaPercent - 0.5) -lt 0.000001 -and
    [Math]::Abs([double]$reference.TotalUsd - 3738.2522) -lt 0.000001) 'known +0.5-point delta did not retain the 1% reference'
Set-QuotaWindowCard -Window $halfPointEnd -Estimate $null -WeeklyReference $reference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-WeeklyObservedRange ($dollar.Text.Contains((Format-TokenRaderUsd 3738.2522)) -and
    $dollar.Text.Contains("$rangePrefix 16% $arrow 16.5% $separator $deltaLabel 0.5%")) 'known sub-1-point reference lost its amount or observed interval'

# A foreign result cannot replace the current account's accepted reference.
$priorReference = [pscustomobject]@{ TotalUsd = 250.0; AccountIdentity = 'synthetic-account'; ActualDeltaPercent = 0.5 }
Set-SyntheticState -BaselineStartRateLimits $baselineStart -BaselineRateLimits $null
$script:State.WeeklyReferenceEstimate = $priorReference
$foreign = New-WeeklyResult -StartRateLimits ([pscustomobject]@{ Weekly = $start }) -EndRateLimits $endRateLimits -Account 'foreign-account'
Update-TokenRaderWeeklyReferenceFromResult -Result $foreign
Assert-WeeklyObservedRange ([object]::ReferenceEquals($priorReference,$script:State.WeeklyReferenceEstimate)) 'foreign account result replaced the current reference'

# Different plan, reset cycle, or a conflicted window cannot be combined into
# a measured delta or a reference amount.
$badStartPlan = New-WeeklySnapshot -UsedPercent 16.0 -ResetsAt $resetUtc -PlanType 'plan-a'
$badEndPlan = New-WeeklySnapshot -UsedPercent 18.0 -ResetsAt $resetOffset -PlanType 'plan-b'
$badPlanResult = New-WeeklyResult -StartRateLimits ([pscustomobject]@{ Weekly = $badStartPlan }) -EndRateLimits ([pscustomobject]@{ Weekly = $badEndPlan })
Set-SyntheticState -BaselineStartRateLimits $null -BaselineRateLimits $null
Update-TokenRaderWeeklyReferenceFromResult -Result $badPlanResult
Assert-WeeklyObservedRange ($null -eq $script:State.WeeklyReferenceEstimate.ActualDeltaPercent -and
    $null -eq $script:State.WeeklyReferenceEstimate.TotalUsd) 'cross-plan snapshots were combined'

$differentResetStart = New-WeeklySnapshot -UsedPercent 16.0 -ResetsAt $resetUtc.AddDays(-1)
$badResetResult = New-WeeklyResult -StartRateLimits ([pscustomobject]@{ Weekly = $differentResetStart }) -EndRateLimits $endRateLimits
Set-SyntheticState -BaselineStartRateLimits $null -BaselineRateLimits $null
Update-TokenRaderWeeklyReferenceFromResult -Result $badResetResult
Assert-WeeklyObservedRange ($null -eq $script:State.WeeklyReferenceEstimate.ActualDeltaPercent -and
    $null -eq $script:State.WeeklyReferenceEstimate.TotalUsd) 'different reset cycles were combined'

$conflictedStart = New-WeeklySnapshot -UsedPercent 16.0 -ResetsAt $resetUtc -ScopeConflict $true
$badConflictResult = New-WeeklyResult -StartRateLimits ([pscustomobject]@{ Weekly = $conflictedStart }) -EndRateLimits $endRateLimits
Set-SyntheticState -BaselineStartRateLimits $null -BaselineRateLimits $null
Update-TokenRaderWeeklyReferenceFromResult -Result $badConflictResult
Assert-WeeklyObservedRange ($null -eq $script:State.WeeklyReferenceEstimate.ActualDeltaPercent -and
    $null -eq $script:State.WeeklyReferenceEstimate.TotalUsd) 'scope-conflicted snapshots were combined'

# A foreign baseline cannot be used as fallback even if the result itself is
# tagged to the current account and contains a valid end snapshot.
Set-SyntheticState -BaselineStartRateLimits $baselineStart -BaselineRateLimits $null -BaselineAccount 'foreign-account'
$result = New-WeeklyResult -StartRateLimits $null -EndRateLimits $endRateLimits
Update-TokenRaderWeeklyReferenceFromResult -Result $result
Assert-WeeklyObservedRange ($null -eq $script:State.WeeklyReferenceEstimate.ActualDeltaPercent -and
    $null -eq $script:State.WeeklyReferenceEstimate.TotalUsd) 'foreign measurement baseline was used for a current-account delta'

Write-Output 'Weekly observed range tests passed.'
