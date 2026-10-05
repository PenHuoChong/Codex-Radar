[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('MEASUREMENT FAILURE CALLBACK FAILED: '+$message) } }
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'TokenRader.ps1'),[ref]$tokens,[ref]$errors)
Assert (@($errors).Count-eq0) 'production PowerShell parses'
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq'Fail-TokenRaderMeasurementRequest'},$true)
Assert ($null-ne$node) 'production failure callback exists'
Invoke-Expression $node.Extent.Text
# Only the extracted callback runs. All quota, UI and task state is synthetic;
# no application, private database, session logs or authentication is opened.
function Reset-Fixture {
    $script:WindowClosing=$false
    $script:Baseline=[pscustomobject]@{ Frozen='synthetic-start' }
    $script:Ending=[pscustomobject]@{ Frozen='synthetic-end' }
    $script:Result=[pscustomobject]@{ Value='synthetic-valid-result' }
    $script:Retry=[pscustomobject]@{ Frozen='synthetic-final-retry' }
    $script:Estimate=[pscustomobject]@{ Value='synthetic-valid-estimate' }
    $script:State=@{
        MeasurementGeneration=7L; UiState='Starting'; IsMeasuring=$false
        BaselineRequestId=12L; EndCaptureRequestId=21L; IntervalComputeRequestId=22L
        IntervalComputing=$true; IntervalComputeStopping=$true; IntervalActiveScanRateLimits=$true
        IntervalComputePending=$true; IntervalComputePendingRequest=[pscustomobject]@{ Task='unrelated' }
        PendingMeasurementStart=$true; QuotaCalibrationMessage=''
        IntervalBaseline=$Baseline; IntervalEnd=$Ending; IntervalResult=$Result; IntervalFinalRetry=$Retry
        QuotaEstimates=$Estimate; QuotaEstimateAccountIdentity='synthetic-account'; QuotaDiagnostics=@{ Value='valid' }
        LastFailureInfo=''; RateLimits=@{}; AccountIdentity='synthetic-account'
    }
    $script:StatusText=[pscustomobject]@{ Text='' }
    $script:Faults=@(); $script:Reenter=''; $script:SameGeneration=$false; $script:Calls=0
}
function Seam([string]$name) {
    $script:Calls++
    if ($script:Reenter-eq$name) {
        if (-not $script:SameGeneration) { $script:State.MeasurementGeneration=8L }
        $script:State.BaselineRequestId=99L; $script:State.EndCaptureRequestId=100L; $script:State.IntervalComputeRequestId=101L
        $script:State.PendingMeasurementStart=$true; $script:State.UiState='Starting'; $script:State.IsMeasuring=$false
        $script:State.LastFailureInfo='newer-failure'; $script:StatusText.Text='newer-status'
        return $false
    }
    if ($script:Faults-contains$name) { throw ('synthetic-'+$name) }
    return $true
}
function Retain-TokenRaderQuotaEstimatesForCurrentWindow { param($RateLimits,$AccountIdentity); [void](Seam 'Retain') }
function Mark-TokenRaderQuotaEstimatesRetainedAfterFailure { [void](Seam 'Mark') }
function Set-TokenRaderUiState {
    param($NewState,$StatusMessage)
    if (-not (Seam 'State')) { return }
    $script:State.UiState=$NewState; $script:State.IsMeasuring=($NewState-eq'Measuring')
}
function Update-QuotaCards { [void](Seam 'Cards') }
function Set-TokenRaderLastFailureInfo {
    param($Message)
    if (-not (Seam 'LastFailure')) { return }
    $script:State.LastFailureInfo=$Message
}
function Assert-Frozen {
    Assert ([object]::ReferenceEquals($script:State.IntervalBaseline,$Baseline)) 'frozen start retained'
    Assert ([object]::ReferenceEquals($script:State.IntervalEnd,$Ending)) 'frozen end retained'
    Assert ([object]::ReferenceEquals($script:State.IntervalResult,$Result)) 'valid interval result retained'
    Assert ([object]::ReferenceEquals($script:State.IntervalFinalRetry,$Retry)) 'frozen final retry retained'
    Assert ([object]::ReferenceEquals($script:State.QuotaEstimates,$Estimate)) 'valid quota estimate survives display failure'
}
foreach ($fault in @('', 'Retain','Mark','State','Cards','LastFailure','All')) {
    Reset-Fixture
    $script:Faults=if($fault-eq'All'){@('Retain','Mark','State','Cards','LastFailure')}elseif($fault){@($fault)}else{@()}
    Fail-TokenRaderMeasurementRequest -Generation 7L -RequestId 12L -Message 'synthetic-primary-failure'
    Assert ($State.UiState-eq'Error' -and -not $State.IsMeasuring -and $State.BaselineRequestId-eq0 -and -not $State.PendingMeasurementStart) ('no stranded Starting: '+$fault)
    Assert ($State.EndCaptureRequestId-eq21 -and $State.IntervalComputeRequestId-eq22 -and $State.IntervalComputing -and $State.IntervalComputePending) 'unrelated owned tasks retain state'
    Assert ($StatusText.Text.Contains('synthetic-primary-failure')) 'primary cause remains visible despite secondary failures'
    Assert-Frozen
    $originalStatus=$StatusText.Text
    Fail-TokenRaderMeasurementRequest -Generation 7L -RequestId 12L -Message 'duplicate-late-failure'
    Assert ($StatusText.Text-eq$originalStatus) 'duplicate released-owner callback cannot replace failure'
}
Reset-Fixture; $State.UiState='Measuring'; $State.IsMeasuring=$true
Fail-TokenRaderMeasurementRequest -Generation 7L -RequestId 22L -Message 'synthetic-compute-failure'
Assert ($State.UiState-eq'Measuring' -and $State.IsMeasuring) 'active measurement is not terminated by auxiliary failure'
Assert ($State.IntervalComputeRequestId-eq0 -and -not $State.IntervalComputing -and -not $State.IntervalComputePending) 'only owned compute task is released'
Assert ($State.BaselineRequestId-eq12 -and $State.EndCaptureRequestId-eq21 -and $State.PendingMeasurementStart) 'unrelated boundary/pending task survives'
Assert-Frozen
Reset-Fixture; $State.UiState='Stopping'; $script:Faults=@('State','Cards')
Fail-TokenRaderMeasurementRequest -Generation 7L -RequestId 21L -Final $true -Message 'synthetic-final-failure'
Assert ($State.UiState-eq'Error' -and $State.EndCaptureRequestId-eq0) 'end failure restores state before drawing'
Assert-Frozen
Reset-Fixture; $State.UiState='Ready'
Fail-TokenRaderMeasurementRequest -Generation 7L -RequestId 22L -Final $true -Message 'synthetic-ready-failure'
Assert ($State.UiState-eq'Ready') 'completed frozen interval remains viewable'
Assert-Frozen
foreach ($seam in @('Retain','Mark','State','Cards','LastFailure')) {
    foreach ($same in @($false,$true)) {
        Reset-Fixture; $script:Reenter=$seam; $script:SameGeneration=$same
        Fail-TokenRaderMeasurementRequest -Generation 7L -RequestId 12L -Message 'old-failure'
        Assert ($State.BaselineRequestId-eq99 -and $State.EndCaptureRequestId-eq100 -and $State.IntervalComputeRequestId-eq101 -and $State.PendingMeasurementStart) ('reentrant request preserved: '+$seam)
        Assert ($State.UiState-eq'Starting' -and $State.LastFailureInfo-eq'newer-failure' -and $StatusText.Text-eq'newer-status') ('new generation/owner status preserved: '+$seam)
        Assert-Frozen
    }
}
foreach ($stale in @('generation','request','closing')) {
    Reset-Fixture
    if($stale-eq'closing'){$script:WindowClosing=$true}
    Fail-TokenRaderMeasurementRequest -Generation $(if($stale-eq'generation'){6L}else{7L}) -RequestId $(if($stale-eq'request'){98L}else{12L}) -Message 'stale'
    Assert ($script:Calls-eq0 -and $State.BaselineRequestId-eq12 -and $State.UiState-eq'Starting') ('stale callback is inert: '+$stale)
    Assert-Frozen
}
Write-Host 'PASS Measurement failure callback: render faults cannot strand Starting; frozen results, active measuring, unrelated owners and reentry are preserved.'
