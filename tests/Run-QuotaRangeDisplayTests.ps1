[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'TokenRader.ps1')
$match = [regex]::Match($source, '(?s)function Set-QuotaWindowCard\b.*?(?=\r?\nfunction |\z)')
if (-not $match.Success) { throw 'Missing production function: Set-QuotaWindowCard' }
Invoke-Expression $match.Value

# Construct Chinese UI labels from code points so this test source remains
# ASCII-only and therefore parses identically in Windows PowerShell 5.1.
function ConvertFrom-CodePointList {
    param([int[]]$CodePoints)
    $characters = New-Object 'System.Collections.Generic.List[char]'
    foreach ($codePoint in $CodePoints) { $characters.Add([char]$codePoint) }
    return -join $characters.ToArray()
}
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
function Assert-QuotaRange([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "QUOTA RANGE DISPLAY TEST FAILED: $Message" }
}

$calibrationLabel = ConvertFrom-CodePointList @(0x6821,0x51C6,0x533A,0x95F4)
$calibrationDeltaLabel = ConvertFrom-CodePointList @(0x6821,0x51C6,0x589E,0x91CF)
$statsLabel = ConvertFrom-CodePointList @(0x7EDF,0x8BA1,0x533A,0x95F4,0xFF08,0x672C,0x5730,0x65F6,0x95F4,0xFF0C,0x8D77,0x70B9,0x4E0D,0x542B,0x2F,0x7EC8,0x70B9,0x5305,0x542B,0xFF09)
$referenceStatsLabel = ConvertFrom-CodePointList @(0x53C2,0x8003,0x6210,0x672C,0x7EDF,0x8BA1,0x533A,0x95F4,0xFF08,0x672C,0x5730,0x65F6,0x95F4,0xFF09)
$notProvided = ConvertFrom-CodePointList @(0x672A,0x63D0,0x4F9B)
$arrow = ConvertFrom-CodePointList @(0x2192)

$currentObserved = [DateTimeOffset]::Now
$startAt = $currentObserved.AddHours(-2)
$endAt = $currentObserved.AddHours(-1)
$measurementStart = $currentObserved.AddHours(-4)
$reset = $currentObserved.AddDays(2)
$startLocal = '{0:MM-dd HH:mm:ss}' -f $startAt.ToLocalTime()
$endLocal = '{0:MM-dd HH:mm:ss}' -f $endAt.ToLocalTime()
$measurementStartLocal = '{0:MM-dd HH:mm:ss}' -f $measurementStart.ToLocalTime()
$currentLocal = '{0:MM-dd HH:mm:ss}' -f $currentObserved.ToLocalTime()
$dollar = [pscustomobject]@{ Text = '' }
$usage = [pscustomobject]@{ Text = '' }
$progress = [pscustomobject]@{ Value = 0 }
$resetText = [pscustomobject]@{ Text = '' }

# The displayed current weekly usage is 40%, while its frozen calibration
# endpoint is 35%; the explanatory range must use the latter, not the former.
$weeklyWindow = [pscustomobject]@{
    UsedPercent = 40.0; WindowMinutes = 10080; PlanType = 'synthetic-weekly'
    ResetsAt = $reset; LimitId = 'codex'
}
$weeklyEstimate = [pscustomobject]@{
    TotalUsd = 500.0; UsedUsd = 200.0; RemainingUsd = 300.0
    WindowMinutes = 10080; PlanType = 'synthetic-weekly'; ResetsAt = $reset
    CurrentObservedAt = $currentObserved; EstimateSource = 'snapshot_delta_usd_estimate'
    IdentityComplete = $true; StartUsedPercent = 30.0; CalibrationEndUsedPercent = 35.0
    EffectiveDeltaPercent = 5.0; CalibrationStartObservedAt = $startAt
    CalibrationEndObservedAt = $endAt; StartedAt = $measurementStart
    MeasurementStartedAt = $measurementStart; MeasurementEndedAt = $currentObserved
}
Set-QuotaWindowCard -Window $weeklyWindow -Estimate $weeklyEstimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
$weeklyCalibrationRange = "$calibrationLabel 30% $arrow 35%"
$weeklyStatsRange = "$statsLabel $startLocal $arrow $endLocal"
Assert-QuotaRange ($dollar.Text.Contains($weeklyCalibrationRange) -and
    $dollar.Text.Contains("$calibrationDeltaLabel +5%") -and $usage.Text -eq '40%' -and
    -not $dollar.Text.Contains("$calibrationLabel 30% $arrow 40%")) 'weekly card used the live window percent instead of its frozen calibration endpoint'
Assert-QuotaRange ($dollar.Text.Contains($weeklyStatsRange)) 'weekly frozen calibration timestamps were not shown as a local half-open interval'

# Verify the 5-hour card renders its own calibration metadata independently
# from the weekly card.
$fiveHourWindow = [pscustomobject]@{
    UsedPercent = 90.0; WindowMinutes = 300; PlanType = 'synthetic-five-hour'
    ResetsAt = $reset; LimitId = 'codex'
}
$fiveHourStart = $startAt.AddHours(-1)
$fiveHourEnd = $startAt.AddMinutes(-30)
$fiveHourEstimate = [pscustomobject]@{
    TotalUsd = 80.0; UsedUsd = 72.0; RemainingUsd = 8.0
    WindowMinutes = 300; PlanType = 'synthetic-five-hour'; ResetsAt = $reset
    CurrentObservedAt = $currentObserved; EstimateSource = 'snapshot_delta_usd_estimate'
    IdentityComplete = $true; StartUsedPercent = 10.0; CalibrationEndUsedPercent = 15.0
    EffectiveDeltaPercent = 5.0; CalibrationStartObservedAt = $fiveHourStart
    CalibrationEndObservedAt = $fiveHourEnd; StartedAt = $measurementStart
}
Set-QuotaWindowCard -Window $fiveHourWindow -Estimate $fiveHourEstimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
$fiveHourStartLocal = '{0:MM-dd HH:mm:ss}' -f $fiveHourStart.ToLocalTime()
$fiveHourEndLocal = '{0:MM-dd HH:mm:ss}' -f $fiveHourEnd.ToLocalTime()
Assert-QuotaRange ($dollar.Text.Contains("$calibrationLabel 10% $arrow 15%") -and
    $dollar.Text.Contains("$statsLabel $fiveHourStartLocal $arrow $fiveHourEndLocal") -and
    -not $dollar.Text.Contains($weeklyStatsRange)) '5-hour card reused weekly calibration metadata'

# Missing strict endpoint timestamps are explicitly reported as missing;
# measurement-start/current-observation fields are not substitutes.
$weeklyEstimate.CalibrationStartObservedAt = $null
$weeklyEstimate.CalibrationEndObservedAt = $null
Set-QuotaWindowCard -Window $weeklyWindow -Estimate $weeklyEstimate -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-QuotaRange ($dollar.Text.Contains("$statsLabel $notProvided $arrow $notProvided") -and
    -not $dollar.Text.Contains($measurementStartLocal) -and -not $dollar.Text.Contains($currentLocal)) 'missing strict timestamp endpoints were inferred from measurement/current timestamps'

# The 1% reference has its own measurement range, unrelated to the strict
# calibration interval and never inferred from current-observation metadata.
$weeklyReference = [pscustomobject]@{
    TotalUsd = 5900.0; ActualDeltaPercent = 0.5; PricingIncomplete = $false
    MeasurementStartedAt = $startAt; MeasurementEndedAt = $endAt
    StartedAt = $measurementStart; CurrentObservedAt = $currentObserved
}
Set-QuotaWindowCard -Window $weeklyWindow -Estimate $null -WeeklyReference $weeklyReference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-QuotaRange ($dollar.Text.Contains($referenceStatsLabel) -and
    $dollar.Text.Contains("$startLocal $arrow $endLocal")) '1% reference did not show its measurement-cost interval'

$weeklyReference.MeasurementStartedAt = $null
$weeklyReference.MeasurementEndedAt = $endAt
Set-QuotaWindowCard -Window $weeklyWindow -Estimate $null -WeeklyReference $weeklyReference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-QuotaRange ($dollar.Text.Contains("$referenceStatsLabel $notProvided $arrow $endLocal") -and
    -not $dollar.Text.Contains($measurementStartLocal) -and -not $dollar.Text.Contains($currentLocal)) 'missing reference start was inferred or not marked missing'

$weeklyReference.MeasurementStartedAt = $startAt
$weeklyReference.MeasurementEndedAt = $null
Set-QuotaWindowCard -Window $weeklyWindow -Estimate $null -WeeklyReference $weeklyReference -UsageText $usage -Progress $progress -DollarText $dollar -ResetText $resetText
Assert-QuotaRange ($dollar.Text.Contains("$referenceStatsLabel $startLocal $arrow $notProvided") -and
    -not $dollar.Text.Contains($currentLocal)) 'missing reference end was inferred or not marked missing'

Write-Output 'Quota range display tests passed.'
