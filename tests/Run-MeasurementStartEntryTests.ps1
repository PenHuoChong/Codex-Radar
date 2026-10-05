[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('MEASUREMENT START ENTRY FAILED: '+$message) } }
$tokens=$null; $errors=$null
$script:SyntheticProjectRoot=Split-Path -Parent $PSScriptRoot
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'TokenRader.ps1'),[ref]$tokens,[ref]$errors)
Assert (@($errors).Count-eq0) 'production parses'
foreach ($name in @('Start-IntervalMeasurement','Start-TokenRaderIndexSyncAsync')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-eq$name},$true)
    Assert ($null-ne$node) ('production function exists: '+$name)
    # Invoke-Expression does not retain the production script's automatic
    # PSScriptRoot. Substitute that path seam only; no module is imported.
    Invoke-Expression $node.Extent.Text.Replace('$PSScriptRoot','$script:SyntheticProjectRoot')
}
# These extracted entry points use synthetic UI and worker seams only. No
# application, source logs, index, authentication or DLL build is performed.
$script:Paths=[pscustomobject]@{ SessionsRoot='synthetic-only' }
$script:IndexSyncScript={}
function Reset-Fixture([bool]$ready=$true,[bool]$catalog=$true) {
    $script:WindowClosing=$false
    $script:Baseline=[pscustomobject]@{ Frozen='synthetic-start' }
    $script:Ending=[pscustomobject]@{ Frozen='synthetic-end' }
    $script:Result=[pscustomobject]@{ Valid='synthetic-result' }
    $script:Estimate=[pscustomobject]@{ Valid='synthetic-estimate' }
    $script:State=@{
        UiState='Ready'; IsMeasuring=$false; MeasurementGeneration=7L
        BaselineRequestId=0L; EndCaptureRequestId=0L; IntervalComputeRequestId=0L
        IntervalComputing=$false; IntervalComputeStopping=$false; IntervalActiveScanRateLimits=$false
        IntervalComputePending=$false; IntervalComputePendingRequest=$null; IntervalLastError=''
        IndexReady=$ready; IndexCatalogAvailable=$catalog; IndexSyncing=$false; IndexSyncStopping=$false; IndexSyncRequestId=0L
        HistoryBackfillRunning=$false; ToolBackfillRunning=$false; UsageHistoryRefreshing=$false
        PendingMeasurementStart=$false; BackgroundJobs=@{}; ViewMode='interval'; LastFailureInfo=''
        IntervalBaseline=$Baseline; IntervalEnd=$Ending; IntervalResult=$Result; QuotaEstimates=$Estimate; QuotaCalibrationMessage=''
    }
    $script:StatusText=[pscustomobject]@{ Text='' }
    $script:NextId=10L; $script:Faults=@(); $script:Reenter=''; $script:SameGeneration=$false
    $script:SensitiveFailures=@(); $script:BaselineLaunches=0; $script:IndexLaunches=0; $script:LaunchFailure=''; $script:LastJob=$null
}
function New-TokenRaderRequestId { $script:NextId++; return $script:NextId }
function Reset-MeasurementPricingConfirmation { }
function Seam([string]$name) {
    if ($script:Reenter-eq$name) {
        if (-not $script:SameGeneration) { $script:State.MeasurementGeneration=99L }
        $script:State.BaselineRequestId=100L; $script:State.IndexSyncRequestId=101L
        $script:State.PendingMeasurementStart=$true; $script:State.UiState='Starting'
        $script:State.LastFailureInfo='newer-failure'; $script:StatusText.Text='newer-status'
        return $false
    }
    if ($script:Faults-contains$name -or ($script:Faults-contains'All' -and $name-in@('Retain','Cards','StartingState','IndexState','LastFailure'))) {
        if ($script:SensitiveFailures-contains$name) { throw [InvalidOperationException]::new('synthetic-private-body') }
        throw ('synthetic-'+$name)
    }
    return $true
}
function Retain-TokenRaderQuotaEstimatesForCurrentWindow { [void](Seam 'Retain') }
function Update-QuotaCards { [void](Seam 'Cards') }
function Set-TokenRaderUiState {
    param($NewState,$StatusMessage)
    $seam=if($NewState-eq'Starting'){'StartingState'}else{'IndexState'}
    if (-not (Seam $seam)) { return }
    $script:State.UiState=$NewState; $script:State.IsMeasuring=($NewState-eq'Measuring')
}
function Set-TokenRaderLastFailureInfo {
    param($Message)
    if (-not (Seam 'LastFailure')) { return }
    $script:State.LastFailureInfo=$Message
}
function Start-TokenRaderBackgroundJob {
    param($ScriptBlock,$Parameters,$Kind,$Generation,$RequestId,$CompletionHandler,$FailureHandler,
        $CallbackContext,$TimeoutSeconds,$StallTimeoutSeconds,$ProgressState,$CancellationSource,$StopCompletionHandler)
    if (-not (Seam 'IndexLaunch')) { $CancellationSource.Dispose(); return $false }
    $script:IndexLaunches++
    if ($script:LaunchFailure-eq'Index') {
        # The real background helper invokes its owned failure callback when
        # BeginInvoke fails; represent that contract without creating threads.
        $script:State.IndexSyncing=$false; $script:State.IndexSyncStopping=$false; $script:State.IndexSyncRequestId=0L
        $script:State.PendingMeasurementStart=$false; $script:State.BaselineRequestId=0L; $script:State.UiState='Error'
        $script:State.LastFailureInfo='synthetic-index-launch-failure'
        $CancellationSource.Dispose(); return $false
    }
    $script:LastJob=[pscustomobject]@{ Kind=$Kind; Generation=$Generation; RequestId=$RequestId; TimeoutSeconds=$TimeoutSeconds; StallTimeoutSeconds=$StallTimeoutSeconds }
    $script:State.BackgroundJobs[$RequestId]=$script:LastJob
    $CancellationSource.Dispose(); return $true
}
function Start-TokenRaderMeasurementBaselineAsync {
    param($Generation,$RequestId)
    if (-not (Seam 'BaselineLaunch')) { return }
    $script:BaselineLaunches++
    if ($script:LaunchFailure-eq'Baseline') {
        $script:State.UiState='Error'; $script:State.BaselineRequestId=0L; $script:State.PendingMeasurementStart=$false
        $script:State.LastFailureInfo='synthetic-baseline-launch-failure'; return
    }
    $script:State.BackgroundJobs[$RequestId]=[pscustomobject]@{ Kind='MeasurementBaseline'; Generation=$Generation; RequestId=$RequestId }
}
function Fail-TokenRaderMeasurementRequest {
    param($Generation,$RequestId,$Final,$Message)
    if($State.MeasurementGeneration-ne$Generation -or $State.BaselineRequestId-ne$RequestId){return}
    $script:State.UiState='Error'; $script:State.BaselineRequestId=0L; $script:State.PendingMeasurementStart=$false
    $script:State.LastFailureInfo=$Message
}
function Fail-TokenRaderIndexSyncJob {
    param($ErrorMessage,$Generation,$RequestId,$Kind,$Context)
    if($State.IndexSyncRequestId-ne$RequestId){return}
    $script:State.IndexSyncing=$false; $script:State.IndexSyncStopping=$false; $script:State.IndexSyncRequestId=0L
    $script:State.UiState='Error'; $script:State.BaselineRequestId=0L; $script:State.PendingMeasurementStart=$false
    $script:State.LastFailureInfo=$ErrorMessage
}
function Assert-Frozen {
    Assert ([object]::ReferenceEquals($State.IntervalBaseline,$Baseline)) 'start boundary retained'
    Assert ([object]::ReferenceEquals($State.IntervalEnd,$Ending)) 'end boundary retained'
    Assert ([object]::ReferenceEquals($State.IntervalResult,$Result)) 'valid result retained'
    Assert ([object]::ReferenceEquals($State.QuotaEstimates,$Estimate)) 'valid quota estimate retained'
}
foreach ($ready in @($true,$false)) {
    foreach ($catalog in @($true,$false)) {
        foreach ($fault in @('', 'Retain','Cards','StartingState','IndexState','All')) {
            Reset-Fixture $ready $catalog
            if($fault){$script:Faults=@($fault)}
            Start-IntervalMeasurement
            Assert ($State.UiState-eq'Starting' -and $State.BaselineRequestId-gt0 -and -not $State.IsMeasuring) ('committed Starting survives render failure: '+$fault+'; ready='+$ready+'; catalog='+$catalog+'; state='+$State.UiState+'; failure='+$State.LastFailureInfo)
            Assert ($script:BaselineLaunches-eq$(if($ready){1}else{0}) -and $script:IndexLaunches-eq$(if($ready){0}else{1})) 'exactly the correct owned worker is launched'
            Assert ($State.BackgroundJobs.Count-eq1) 'Starting has a real synthetic worker'
            Assert ($State.PendingMeasurementStart-eq(-not $ready)) 'pending index handoff is retained only when needed'
            if(-not $ready){
                Assert ($LastJob.TimeoutSeconds-eq$(if($catalog){60}else{0}) -and $LastJob.StallTimeoutSeconds-eq$(if($catalog){60}else{300})) 'cold/warm timeout policy unchanged'
            }
            Assert-Frozen
        }
    }
}
Reset-Fixture $false $true; $State.IndexSyncing=$true; $State.IndexSyncRequestId=42L
$State.BackgroundJobs[42L]=[pscustomobject]@{ Kind='IndexSync' }
$script:Faults=@('StartingState')
Start-IntervalMeasurement
Assert ($script:IndexLaunches-eq0 -and $script:BaselineLaunches-eq0 -and $State.IndexSyncRequestId-eq42 -and $State.PendingMeasurementStart -and $State.UiState-eq'Starting') 'existing sync worker is reused despite render failure'
Assert-Frozen
foreach ($failure in @('Baseline','Index')) {
    Reset-Fixture ($failure-eq'Baseline') $true; $script:LaunchFailure=$failure; $script:Faults=@('StartingState','IndexState')
    Start-IntervalMeasurement
    Assert ($State.UiState-eq'Error' -and $State.BaselineRequestId-eq0 -and $State.BackgroundJobs.Count-eq0) 'true launch failure is retryable, not orphaned Starting'
    Assert ($State.LastFailureInfo-eq('synthetic-'+$failure.ToLowerInvariant()+'-launch-failure')) 'display summary cannot replace real launch failure'
    Assert-Frozen
}
foreach($launch in @('BaselineLaunch','IndexLaunch')) {
    Reset-Fixture ($launch-eq'BaselineLaunch') $true; $script:Faults=@($launch,'StartingState','IndexState'); $script:SensitiveFailures=@($launch)
    Start-IntervalMeasurement
    Assert ($State.UiState-eq'Error' -and $State.BaselineRequestId-eq0 -and $State.BackgroundJobs.Count-eq0 -and -not $State.PendingMeasurementStart) 'thrown launch error reaches owned failure recovery'
    if($launch-eq'IndexLaunch'){Assert (-not $State.IndexSyncing -and $State.IndexSyncRequestId-eq0) 'thrown index launch releases own request'}
    $expectedPrefix = -join ([char[]]@(0x540E,0x53F0,0x7D22,0x5F15,0x542F,0x52A8,0x5931,0x8D25,0xFF1A))
    if ($launch -eq 'BaselineLaunch') { $expectedPrefix = -join ([char[]]@(0x5F00,0x59CB,0x8BA1,0x7B97,0x51C6,0x5907,0x542F,0x52A8,0x5931,0x8D25,0xFF1A)) }
    $expectedError = [string]::Concat($expectedPrefix, 'InvalidOperationException')
    $hasLaunchBody = $State.LastFailureInfo.Contains('synthetic-private-body')
    Assert (($State.LastFailureInfo -eq $expectedError) -and (-not $hasLaunchBody)) 'launch error keeps safe type summary and omits exception body'
    Assert-Frozen
}
Reset-Fixture $false $true; $script:Faults=@('IndexState'); $script:SensitiveFailures=@('IndexState')
Start-IntervalMeasurement
Assert ($State.UiState -eq 'Starting' -and $State.BaselineRequestId -gt 0 -and $State.BackgroundJobs.Count -eq 1) 'index display failure preserves the owned startup task'
$indexDisplayLeakedBody=$State.LastFailureInfo.Contains('synthetic-private-body') -or $StatusText.Text.Contains('synthetic-private-body')
$indexDisplayPrefix = -join ([char[]]@(0x7D22,0x5F15,0x51C6,0x5907,0x72B6,0x6001,0x663E,0x793A,0x5931,0x8D25,0xFF1A))
Assert ($State.LastFailureInfo.StartsWith($indexDisplayPrefix) -and $State.LastFailureInfo.Contains('InvalidOperationException') -and ($StatusText.Text -eq $State.LastFailureInfo) -and (-not $indexDisplayLeakedBody)) 'index display diagnostic uses fixed stage and exception type only'
Assert-Frozen
Reset-Fixture $true $true; $script:Faults=@('StartingState'); $script:SensitiveFailures=@('StartingState')
Start-IntervalMeasurement
Assert ($State.UiState -eq 'Starting' -and $State.BaselineRequestId -gt 0 -and $State.BackgroundJobs.Count -eq 1) 'starting display failure preserves the baseline worker'
$startDisplayLeakedBody=$State.LastFailureInfo.Contains('synthetic-private-body') -or $StatusText.Text.Contains('synthetic-private-body')
$startDisplayPrefix = -join ([char[]]@(0x51C6,0x5907,0x72B6,0x6001,0x663E,0x793A,0x5931,0x8D25,0xFF1A))
Assert ($State.LastFailureInfo.StartsWith($startDisplayPrefix) -and $State.LastFailureInfo.Contains('InvalidOperationException') -and ($StatusText.Text -eq $State.LastFailureInfo) -and (-not $startDisplayLeakedBody)) 'start display diagnostic uses fixed stage and exception type only'
Assert-Frozen
foreach ($seam in @('Retain','Cards','StartingState','IndexState','BaselineLaunch','IndexLaunch','LastFailure')) {
    foreach ($same in @($false,$true)) {
        $ready=$seam-notin@('IndexState','IndexLaunch')
        Reset-Fixture $ready $true; $script:Reenter=$seam; $script:SameGeneration=$same
        if($seam-eq'LastFailure'){$script:Faults=@('StartingState')}
        Start-IntervalMeasurement
        Assert ($State.BaselineRequestId-eq100 -and $State.IndexSyncRequestId-eq101 -and $State.PendingMeasurementStart) ('new owner preserved: '+$seam)
        Assert ($State.LastFailureInfo-eq'newer-failure' -and $StatusText.Text-eq'newer-status') ('new status preserved: '+$seam)
        Assert-Frozen
    }
}
Write-Host 'PASS Measurement start entry: cold/warm render failures launch the correct worker, real failures recover, frozen boundaries and reentrant owners survive.'
