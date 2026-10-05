[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
function Assert-RecentUi([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('RECENT HISTORY UI TEST FAILED: ' + $Message) }
}
$root = Split-Path -Parent $PSScriptRoot
$script:SyntheticRoot = $root
$source = [IO.File]::ReadAllText((Join-Path $root 'TokenRader.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-RecentUi (@($errors).Count -eq 0) 'production UI parse'
foreach ($name in @('Get-TokenRaderCallbackContextValue', 'New-TokenRaderRequestId',
    'Start-IntervalMeasurement', 'Start-TokenRaderMeasurementBaselineAsync',
    'Cancel-TokenRaderMeasurementPreparation', 'Complete-TokenRaderMeasurementBaseline',
    'Fail-TokenRaderMeasurementBaselineJob', 'Fail-TokenRaderMeasurementEndJob',
    'Fail-TokenRaderMeasurementRequest', 'Resolve-TokenRaderBackgroundCallbackFailure',
    'Invoke-TokenRaderBackgroundHandler', 'Request-TokenRaderBackgroundStop',
    'Start-TokenRaderBackgroundPoller', 'Complete-TokenRaderBoundaryStopJob',
    'Start-TokenRaderIndexSyncAsync', 'Start-TokenRaderHistoryBackfill', 'Start-TokenRaderUsageHistoryRefresh',
    'Start-TokenRaderToolBackfill', 'Update-TokenRaderToolBackfillButton', 'Set-TokenRaderHistoryCoverage',
    'ConvertTo-TokenRaderCopyableStatusText', 'Set-TokenRaderLastFailureInfo')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Assert-RecentUi ($null -ne $node) ('missing function ' + $name)
    Invoke-Expression $node.Extent.Text.Replace('$PSScriptRoot', '$script:SyntheticRoot')
}
$assignment = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$script:MeasurementBaselineScript' }, $true)
Invoke-Expression $assignment.Extent.Text
$pollerNode = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Start-TokenRaderBackgroundPoller' }, $true)
$mappingNode = $pollerNode.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
    $n.Clauses[0].Item1.Extent.Text.Contains("'HistoryBackfill'") -and
    $n.Clauses[0].Item1.Extent.Text.Contains("'RecentHistoryBackfill'") }, $true)
$localizedNode = $mappingNode.Clauses[0].Item2.Find({ param($n)
    $n -is [Management.Automation.Language.StringConstantExpressionAst] }, $true)
$script:BackfillStageText = $localizedNode.Value

# Only production function/scriptblock extraction; no app launch, account read,
# index open, real log access or DLL build. All core and UI seams are synthetic.
$script:WindowClosing = $false
$script:BackgroundPollTimer = $null
$script:StatusText = [pscustomobject]@{ Text = '' }
$script:Paths = [pscustomobject]@{ SessionsRoot = 'synthetic-only'; PricingPath = 'synthetic-only' }
$script:StartMeasureButton = [pscustomobject]@{ IsEnabled = $true }
$script:BackfillToolUsageButton = [pscustomobject]@{ Content = ''; IsEnabled = $true }
$script:HistoryCoverageText = [pscustomobject]@{ Text = '' }
$script:UsageHistoryCoverageText = [pscustomobject]@{ Text = '' }
function Get-TokenRaderToolBackfillStatus { param($SessionsRoot); return [pscustomobject]@{ Completed = $false } }
function Update-TokenRaderHistoryBackfillButton { }
$script:LaunchCalls = 0; $script:EmptyCalls = 0; $script:ResetCalls = 0
function Reset-MeasurementPricingConfirmation { }
function Retain-TokenRaderQuotaEstimatesForCurrentWindow { param($RateLimits, $AccountIdentity) }
function Mark-TokenRaderQuotaEstimatesRetainedAfterFailure { }
function Update-QuotaCards { }
function Merge-LatestRateLimits { param($Candidate) }
function Show-EmptyIntervalMeasurement { param($Baseline); $script:EmptyCalls++ }
function Reset-TokenRaderBackgroundFailureState { param($Message); $script:ResetCalls++ }
function Set-TokenRaderUiState {
    param($NewState, $StatusMessage = '')
    $script:State.UiState = $NewState
    $script:State.IsMeasuring = $NewState -eq 'Measuring'
    if ($StatusMessage) { $script:StatusText.Text = $StatusMessage }
}
function Start-TokenRaderBackgroundJob {
    param($ScriptBlock, $Parameters, $Kind, $Generation, $RequestId, $CompletionHandler,
        $FailureHandler, $TimeoutSeconds, $StallTimeoutSeconds, $ProgressState,
        $CancellationSource, $StopCompletionHandler, $CallbackContext)
    $script:LaunchCalls++
    $script:CapturedLaunch = $PSBoundParameters
    return $true
}
function New-RecentUiState {
    $script:State = @{
        UiState = 'Ready'; IsMeasuring = $false; MeasurementGeneration = 7L; RequestSequence = 20L
        BaselineRequestId = 0L; EndCaptureRequestId = 0L; IntervalComputeRequestId = 0L
        IntervalComputing = $false; IntervalComputeStopping = $false; IntervalActiveScanRateLimits = $false
        IntervalComputePending = $false; IntervalComputePendingRequest = $null; IntervalLastError = ''
        PendingMeasurementStart = $false; BackgroundJobs = @{}; IndexReady = $true
        IndexCatalogAvailable = $true; IndexSyncing = $false; IndexSyncStopping = $false
        HistoryBackfillRunning = $false; ToolBackfillRunning = $false; ToolBackfillCompleted = $false; UsageHistoryRefreshing = $false
        AccountIdentity = 'synthetic-account'; RateLimits = $null; QuotaCalibrationMessage = ''
        IntervalBaseline = [pscustomobject]@{ StartedAt = [DateTimeOffset]'2026-10-01T00:00:00Z' }
        IntervalResult = [pscustomobject]@{ Marker = 'last-result' }
        IntervalEnd = [pscustomobject]@{ Marker = 'last-end' }; IntervalFinalRetry = 'last-retry'
        IntervalCache = [pscustomobject]@{ Marker = 'last-cache' }
        WeeklyReferenceEstimate = [pscustomobject]@{ Marker = 'last-reference' }
        QuotaEstimates = [pscustomobject]@{ Marker = 'valid-quota' }
    }
}
New-RecentUiState
$oldBaseline = $script:State.IntervalBaseline; $oldResult = $script:State.IntervalResult
$oldEnd = $script:State.IntervalEnd; $oldQuota = $script:State.QuotaEstimates
$oldReference = $script:State.WeeklyReferenceEstimate
Start-IntervalMeasurement
Assert-RecentUi ($script:State.UiState -eq 'Starting' -and -not $script:State.IsMeasuring) 'preparation started timer'
Assert-RecentUi ($script:LaunchCalls -eq 1 -and $script:CapturedLaunch.TimeoutSeconds -eq 0 -and
    $script:CapturedLaunch.StallTimeoutSeconds -eq 60) 'bounded preparation retained fixed total timeout'
Assert-RecentUi ([object]::ReferenceEquals($oldResult, $script:State.IntervalResult) -and
    [object]::ReferenceEquals($oldBaseline, $script:State.IntervalBaseline) -and
    [object]::ReferenceEquals($oldReference, $script:State.WeeklyReferenceEstimate)) 'preparation erased old results/reference'
$launch = $script:CapturedLaunch
$newBaseline = [pscustomobject]@{ StartedAt = [DateTimeOffset]::Now; StartOffsets = @{ synthetic = 99L }; StartRateLimits = $null }
Complete-TokenRaderMeasurementBaseline $newBaseline 7 21
Assert-RecentUi ($script:State.UiState -eq 'Starting' -and $script:EmptyCalls -eq 0) 'stale completion started timer'
Fail-TokenRaderMeasurementBaselineJob 'synthetic incomplete' 8 21 'MeasurementBaseline' @{}
Assert-RecentUi ($script:State.UiState -eq 'Error' -and [object]::ReferenceEquals($oldResult, $script:State.IntervalResult) -and
    [object]::ReferenceEquals($oldEnd, $script:State.IntervalEnd) -and [object]::ReferenceEquals($oldQuota, $script:State.QuotaEstimates)) 'failure erased prior evidence'
$launch.CancellationSource.Dispose()

# The worker orders preparation -> baseline, forwards its frozen object, and
# rejects incomplete/cancelled preparation before capturing a measuring start.
function Import-Module { param($Name, [switch]$Force) }
function Close-TokenRaderIndex { param([switch]$KeepWatcher) }
function Get-TokenRaderPrices { param($PricingPath); return [pscustomobject]@{} }
$script:PrepCompleted = $true; $script:CancelInPrep = $false; $script:CaptureCalls = 0
$script:WorkerEvents = New-Object System.Collections.ArrayList
$script:Prepared = [pscustomobject]@{ Completed = $true; EndOffsets = @{ synthetic = 55L } }
function Complete-TokenRaderRecentHistory {
    param($SessionsRoot, $CancellationToken, $ProgressState)
    [void]$script:WorkerEvents.Add($ProgressState.Stage)
    $script:Prepared.Completed = $script:PrepCompleted
    if ($script:CancelInPrep) { $script:WorkerCts.Cancel() }
    return $script:Prepared
}
function CaptureMeasurementBaseline {
    param($SessionsRoot, $PricingDocument, $AccountIdentity, $CancellationToken, $ProgressState, $PreparedHistory)
    $script:CaptureCalls++
    Assert-RecentUi ([object]::ReferenceEquals($PreparedHistory, $script:Prepared)) 'lost fixed recent EOF object'
    [void]$script:WorkerEvents.Add($ProgressState.Stage)
    return [pscustomobject]@{ StartedAt = [DateTimeOffset]::Now; StartOffsets = $PreparedHistory.EndOffsets; StartRateLimits = $null; IndexRevision = 1L }
}
$progress = [hashtable]::Synchronized(@{})
$result = & $script:MeasurementBaselineScript 'synthetic-only' 'synthetic-only' 'synthetic-only' 'synthetic-account' ([Threading.CancellationToken]::None) $progress
Assert-RecentUi ($script:CaptureCalls -eq 1 -and $script:WorkerEvents.Count -eq 2 -and
    $script:WorkerEvents[0] -ne $script:WorkerEvents[1] -and $result.StartOffsets.synthetic -eq 55) 'worker did not prepare before starting'
$script:PrepCompleted = $false
$threw = $false
try { & $script:MeasurementBaselineScript 'x' 'x' 'x' 'x' ([Threading.CancellationToken]::None) $progress | Out-Null } catch { $threw = $true }
Assert-RecentUi ($threw -and $script:CaptureCalls -eq 1) 'incomplete history reported measuring start'
$script:PrepCompleted = $true; $script:CancelInPrep = $true
$script:WorkerCts = [Threading.CancellationTokenSource]::new()
try {
    $threw = $false
    try { & $script:MeasurementBaselineScript 'x' 'x' 'x' 'x' $script:WorkerCts.Token $progress | Out-Null } catch { $threw = $true }
    Assert-RecentUi ($threw -and $script:CaptureCalls -eq 1) 'cancelled history captured baseline'
} finally { $script:WorkerCts.Dispose() }

function Pump-RecentUi {
    $script:TestFrame = New-Object Windows.Threading.DispatcherFrame
    $script:PumpTimer = New-Object Windows.Threading.DispatcherTimer
    $script:PumpTimer.Interval = [TimeSpan]::FromMilliseconds(170)
    $script:PumpTimer.Add_Tick({ $script:TestFrame.Continue = $false; $script:PumpTimer.Stop() })
    $script:PumpTimer.Start(); [Windows.Threading.Dispatcher]::PushFrame($script:TestFrame)
}
# Synthetic pending invocation lets the real poller prove cancellation gates:
# progress after 35s stays alive; a true stall cancels; gate stays until exit.
New-RecentUiState
$script:State.UiState = 'Starting'; $script:State.BaselineRequestId = 21L
$invocation = [pscustomobject]@{ IsCompleted = $false }
$worker = [pscustomobject]@{ EndCalls = 0; DisposeCalls = 0 }
$worker | Add-Member ScriptMethod BeginStop { param($callback, $state); throw 'synthetic pending stop' }
$worker | Add-Member ScriptMethod EndInvoke { param($async); $this.EndCalls++ }
$worker | Add-Member ScriptMethod Dispose { $this.DisposeCalls++ }
$cts = [Threading.CancellationTokenSource]::new()
$job = [pscustomobject]@{
    Kind = 'MeasurementBaseline'; Generation = 7L; RequestId = 21L; PowerShell = $worker
    AsyncResult = $invocation; StopAsyncResult = $null; StopViaInvoke = $false; CompletionDelivered = $false
    CancellationSource = $cts; CallbackContext = @{}; StopCompletionHandler = 'Complete-TokenRaderBoundaryStopJob'
    CompletionHandler = 'Complete-TokenRaderMeasurementBaselineJob'; FailureHandler = 'Fail-TokenRaderMeasurementBaselineJob'
    StartedAt = [DateTimeOffset]::Now.AddSeconds(-35); LastProgressUiAt = [DateTimeOffset]::Now.AddSeconds(-1)
    TimeoutSeconds = 0; StallTimeoutSeconds = 60; SoftWarningSeconds = 0
    ProgressState = [hashtable]::Synchronized(@{ Stage = 'HistoryBackfill'; HistoryProcessedBytes = 8MB
        RemainingFiles = 3L; RemainingBytes = 4MB; LastProgressAt = [DateTimeOffset]::Now })
}
$script:State.BackgroundJobs[21L] = $job
try {
    Start-TokenRaderBackgroundPoller; Pump-RecentUi
    Assert-RecentUi (-not $cts.IsCancellationRequested -and $null -eq $job.StopAsyncResult -and
        $script:StatusText.Text.Contains('8.0 MB') -and $script:StatusText.Text.Contains('4.0 MB') -and
        $script:StatusText.Text.Contains($script:BackfillStageText)) 'healthy 35s prep timed out or progress/stage hidden'
    $job.ProgressState.Stage = 'RecentHistoryBackfill'; $job.LastProgressUiAt = [DateTimeOffset]::Now.AddSeconds(-1)
    Pump-RecentUi
    Assert-RecentUi ($script:StatusText.Text.Contains($script:BackfillStageText)) 'recent stage code not localized'
    $script:StatusText.Text = 'newer-status'; $job.Generation = 6L
    $job.LastProgressUiAt = [DateTimeOffset]::Now.AddSeconds(-1); Pump-RecentUi
    Assert-RecentUi ($script:StatusText.Text -eq 'newer-status') 'stale job progress rewrote newer UI'
    Resolve-TokenRaderBackgroundCallbackFailure $job 'synthetic stale callback'
    Assert-RecentUi ($script:State.MeasurementGeneration -eq 7 -and $script:ResetCalls -eq 0) 'stale callback globally reset measurement'
    $job.Generation = 7L; $job.ProgressState.LastProgressAt = [DateTimeOffset]::Now.AddSeconds(-61)
    Pump-RecentUi
    Assert-RecentUi ($cts.IsCancellationRequested -and $null -ne $job.StopAsyncResult -and
        $script:State.BackgroundJobs.Count -eq 1 -and $worker.DisposeCalls -eq 0) 'stall did not cancel/drain before releasing gate'
    $before = $script:LaunchCalls
    Start-IntervalMeasurement; Start-TokenRaderIndexSyncAsync; Start-TokenRaderHistoryBackfill; Start-TokenRaderUsageHistoryRefresh; Start-TokenRaderToolBackfill
    Assert-RecentUi ($script:LaunchCalls -eq $before) 'new writer launched while stalled worker draining'
    $invocation.IsCompleted = $true; Pump-RecentUi
    Assert-RecentUi ($script:State.BackgroundJobs.Count -eq 0 -and $worker.EndCalls -eq 1 -and $worker.DisposeCalls -eq 1) 'gate not released after actual exit'
} finally { if ($null -ne $script:BackgroundPollTimer) { $script:BackgroundPollTimer.Stop() } }

New-RecentUiState
Start-IntervalMeasurement
$launch = $script:CapturedLaunch
$script:State.BackgroundJobs[21L] = [pscustomobject]@{
    Kind = 'MeasurementBaseline'; Generation = 8L; RequestId = 21L; CancellationSource = $launch.CancellationSource
    StopAsyncResult = $null; CompletionDelivered = $false; CallbackContext = @{}; PowerShell = $worker
    StopViaInvoke = $false; AsyncResult = [pscustomobject]@{ IsCompleted = $false }
}
Cancel-TokenRaderMeasurementPreparation
Assert-RecentUi ($launch.CancellationSource.IsCancellationRequested -and $script:State.UiState -eq 'Idle' -and
    $script:State.BackgroundJobs.Count -eq 1 -and $script:State.IntervalResult.Marker -eq 'last-result') 'cancel lost results or released live worker'
Complete-TokenRaderMeasurementBaseline $newBaseline 8 21
Assert-RecentUi ($script:State.UiState -eq 'Idle') 'cancelled completion started measurement'
$launch.CancellationSource.Dispose()
$script:State.BackgroundJobs.Clear()
New-RecentUiState
$script:State.UsageHistoryRefreshing = $true
Update-TokenRaderToolBackfillButton
Assert-RecentUi (-not $script:StartMeasureButton.IsEnabled) 'summary writer did not disable preparation launch'
$script:State.UsageHistoryRefreshing = $false
Update-TokenRaderToolBackfillButton
Assert-RecentUi $script:StartMeasureButton.IsEnabled 'summary exit left preparation button disabled'
New-RecentUiState
$script:State.UiState = 'Starting'; $script:State.BaselineRequestId = 21L
$coverage = [pscustomobject]@{ HistoryComplete = $false; RecentHistoryComplete = $true; CoverageStart = $null }
$newBaseline | Add-Member -NotePropertyName HistoryCoverage -NotePropertyValue $coverage
Complete-TokenRaderMeasurementBaseline $newBaseline 6 21
Assert-RecentUi ($script:HistoryCoverageText.Text -eq '') 'stale preparation changed coverage label'
Complete-TokenRaderMeasurementBaseline $newBaseline 7 21
Assert-RecentUi ($script:State.UiState -eq 'Measuring' -and $script:EmptyCalls -eq 1 -and
    [object]::ReferenceEquals($newBaseline, $script:State.IntervalBaseline)) 'successful preparation did not begin measurement'
Assert-RecentUi ([object]::ReferenceEquals($coverage, $script:State.HistoryCoverage) -and
    $script:HistoryCoverageText.Text -eq $script:UsageHistoryCoverageText.Text -and
    $script:HistoryCoverageText.Text.Contains('24')) 'successful preparation omitted scoped coverage label'
Set-TokenRaderHistoryCoverage ([pscustomobject]@{ HistoryComplete = $true; RecentHistoryComplete = $true; CoverageStart = $null })
Assert-RecentUi (-not $script:HistoryCoverageText.Text.Contains('24')) 'complete historical coverage was downgraded to recent-only'

# Fault injection around the production completion callback. A completed
# worker is no longer polled, so neither timeout nor a second failure callback
# can rescue an early-cleared request stranded in Starting.
$script:FaultStage = ''
$script:HandoffRequestSeen = 0L
$script:AuxiliaryCalls = 0
function Set-TokenRaderUiState {
    param($NewState, $StatusMessage = '')
    $script:HandoffRequestSeen = [Int64]$script:State.BaselineRequestId
    if ($script:FaultStage -in @('State','All')) { throw 'synthetic-State-original-cause' }
    if ($script:FaultStage -eq 'Reentrant') {
        $script:State.MeasurementGeneration = 8L
        $script:State.BaselineRequestId = 99L
        $script:State.IntervalBaseline = $script:NewerBaseline
        $script:State.UiState = 'Starting'; $script:State.IsMeasuring = $false
        return
    }
    $script:State.UiState = $NewState
    $script:State.IsMeasuring = $NewState -eq 'Measuring'
    if ($StatusMessage) { $script:StatusText.Text = $StatusMessage }
}
function Set-TokenRaderHistoryCoverage {
    param($Coverage); $script:AuxiliaryCalls++
    if ($script:FaultStage -in @('Coverage','All')) { throw 'synthetic-Coverage-original-cause' }
}
function Merge-LatestRateLimits {
    param($Candidate); $script:AuxiliaryCalls++
    if ($script:FaultStage -in @('Merge','All')) { throw 'synthetic-Merge-original-cause' }
}
function Retain-TokenRaderQuotaEstimatesForCurrentWindow {
    param($RateLimits, $AccountIdentity); $script:AuxiliaryCalls++
    if ($script:FaultStage -in @('Retain','All')) { throw 'synthetic-Retain-original-cause' }
}
function Show-EmptyIntervalMeasurement {
    param($Baseline); $script:AuxiliaryCalls++
    if ($script:FaultStage -in @('Empty','All')) { throw 'synthetic-Empty-original-cause' }
    $script:EmptyCalls++
}
$frozenBaseline = [pscustomobject]@{
    StartedAt = [DateTimeOffset]'2026-10-01T01:02:03Z'
    StartOffsets = @{ synthetic = 123L }; StartRateLimits = $null
    HistoryCoverage = [pscustomobject]@{ RecentHistoryComplete = $true }
}
foreach ($fault in @('State','Coverage','Merge','Retain','Empty','All')) {
    New-RecentUiState
    $script:State.UiState = 'Starting'; $script:State.BaselineRequestId = 21L
    $script:State.LastFailureInfo = ''; $script:FaultStage = $fault
    $script:AuxiliaryCalls = 0
    $retainedQuota = $script:State.QuotaEstimates
    Complete-TokenRaderMeasurementBaseline $frozenBaseline 7L 21L
    Assert-RecentUi ($script:State.UiState -eq 'Measuring' -and $script:State.IsMeasuring -and
        $script:State.BaselineRequestId -eq 0L -and $script:HandoffRequestSeen -eq 21L) ($fault+' display fault stranded Starting or cleared ownership before handoff')
    Assert-RecentUi ([object]::ReferenceEquals($frozenBaseline,$script:State.IntervalBaseline) -and
        $script:State.IntervalBaseline.StartedAt -eq [DateTimeOffset]'2026-10-01T01:02:03Z' -and
        $script:State.IntervalBaseline.StartOffsets.synthetic -eq 123L -and
        [object]::ReferenceEquals($retainedQuota,$script:State.QuotaEstimates)) ($fault+' fault recaptured boundary or cleared valid quota')
    Assert-RecentUi ($script:AuxiliaryCalls -eq 4) ($fault+' fault prevented independent auxiliary steps')
    $expectedFaults = if ($fault -eq 'All') { @('State','Coverage','Merge','Retain','Empty') } else { @($fault) }
    foreach ($expected in $expectedFaults) {
        $cause = 'synthetic-'+$expected+'-original-cause'
        Assert-RecentUi ($script:State.IntervalLastError.Contains($cause) -and
            $script:State.LastFailureInfo.Contains($cause)) ($expected+' original exception was lost from retry/copy diagnostics')
    }
    $failureInfo = $script:State.LastFailureInfo
    $calls = $script:AuxiliaryCalls
    Complete-TokenRaderMeasurementBaseline $newBaseline 6L 21L
    Complete-TokenRaderMeasurementBaseline $newBaseline 7L 22L
    Fail-TokenRaderMeasurementBaselineJob 'synthetic late failure' 7L 21L 'MeasurementBaseline' @{}
    Assert-RecentUi ($script:State.UiState -eq 'Measuring' -and $script:AuxiliaryCalls -eq $calls -and
        [object]::ReferenceEquals($frozenBaseline,$script:State.IntervalBaseline) -and
        $script:State.LastFailureInfo -eq $failureInfo) ($fault+' stale completion/failure affected active measurement')
    $script:FaultStage = ''
    Show-EmptyIntervalMeasurement $script:State.IntervalBaseline
    Set-TokenRaderUiState -NewState 'Measuring' -StatusMessage 'synthetic successful redraw'
    Assert-RecentUi ($script:State.IsMeasuring -and $script:State.LastFailureInfo -eq $failureInfo) ($fault+' redraw retry stopped measurement or erased latest failure')
}
New-RecentUiState
$script:State.UiState = 'Starting'; $script:State.BaselineRequestId = 21L
$script:NewerBaseline = [pscustomobject]@{ Marker = 'newer-request' }
$script:FaultStage = 'Reentrant'; $script:AuxiliaryCalls = 0
Complete-TokenRaderMeasurementBaseline $frozenBaseline 7L 21L
Assert-RecentUi ($script:State.MeasurementGeneration -eq 8L -and $script:State.BaselineRequestId -eq 99L -and
    $script:State.UiState -eq 'Starting' -and $script:AuxiliaryCalls -eq 0 -and
    [object]::ReferenceEquals($script:NewerBaseline,$script:State.IntervalBaseline)) 'old handoff cleared or rendered a newer preparation'
$script:FaultStage = ''
Write-Host ('RECENT_HISTORY_UI_TESTS_PASSED edition={0} version={1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
