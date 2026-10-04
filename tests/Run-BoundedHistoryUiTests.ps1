[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

function Assert-BoundedUi([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('BOUNDED HISTORY UI TEST FAILED: ' + $Message) }
}
$root = Split-Path -Parent $PSScriptRoot
$script:SyntheticProjectRoot = $root
$source = [IO.File]::ReadAllText((Join-Path $root 'TokenRader.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-BoundedUi (@($errors).Count -eq 0) 'production UI must parse'
$coreSource = [IO.File]::ReadAllText((Join-Path $root 'TokenRader.Core.psm1'))
Assert-BoundedUi ($coreSource -match '(?s)if \(\$requiresReplacement\) \{[^}]*source_replaced[^}]*throw.*?DeleteTokenRecordsBySessionId') 'blocked source replacement must be rejected before deleting preserved indexed rows'
foreach ($name in @('Get-TokenRaderCallbackContextValue', 'Set-TokenRaderHistoryCoverage',
        'Update-TokenRaderHistoryBackfillButton', 'Fail-TokenRaderHistoryBackfillJob',
        'Complete-TokenRaderHistoryBackfillStopJob', 'Fail-TokenRaderIndexSyncJob',
        'Complete-TokenRaderIndexSyncStopJob', 'Resolve-TokenRaderBackgroundCallbackFailure',
        'Invoke-TokenRaderBackgroundHandler', 'Request-TokenRaderBackgroundStop',
        'Start-TokenRaderBackgroundPoller', 'Start-TokenRaderHistoryBackfill',
        'Try-TokenRaderFinishWindowClose', 'Request-TokenRaderWindowClose')) {
    $match = [regex]::Match($source, ('(?s)function ' + [regex]::Escape($name) + '\b.*?(?=\r?\nfunction |\z)'))
    Assert-BoundedUi $match.Success ('missing helper ' + $name)
    $helperSource = $match.Value
    if ($name -eq 'Start-TokenRaderHistoryBackfill') {
        $helperSource = $helperSource.Replace('$PSScriptRoot', '$script:SyntheticProjectRoot')
    }
    Invoke-Expression $helperSource
}
$startJobMatch = [regex]::Match($source, '(?s)function Start-TokenRaderBackgroundJob\b.*?(?=\r?\nfunction |\z)')
Invoke-Expression ($startJobMatch.Value -replace 'function Start-TokenRaderBackgroundJob\b', 'function Start-TokenRaderBackgroundJobUnderTest')

# No application launch, module import, account lookup or real session/index read.
$script:WindowClosing = $false
$script:BackgroundPollTimer = $null
$script:HistoryBackfillButton = [pscustomobject]@{ Content = ''; IsEnabled = $false }
$script:HistoryCoverageText = [pscustomobject]@{ Text = '' }
$script:UsageHistoryCoverageText = [pscustomobject]@{ Text = '' }
$script:HistoryBackfillStatusText = [pscustomobject]@{ Text = '' }
$script:StatusText = [pscustomobject]@{ Text = '' }
$script:LaunchCalls = 0; $script:ResetCalls = 0; $script:ThrowRender = $false
function Set-TokenRaderUiState {
    param([string]$NewState, [string]$StatusMessage = '')
    $script:State.UiState = $NewState
    $script:StatusText.Text = $StatusMessage
    if ($script:ThrowRender) { throw 'synthetic rendering failure' }
}
function Retain-TokenRaderQuotaEstimatesForCurrentWindow { }
function Mark-TokenRaderQuotaEstimatesRetainedAfterFailure { }
function Update-QuotaCards { }
function Reset-TokenRaderBackgroundFailureState { param([string]$Message); $script:ResetCalls++ }
function Start-TokenRaderBackgroundJob {
    param($ScriptBlock, $Parameters, $Kind, $RequestId, $CompletionHandler, $FailureHandler,
        $CallbackContext, $StallTimeoutSeconds, $ProgressState, $CancellationSource, $StopCompletionHandler)
    $script:LaunchCalls++
    if ($null -ne $CancellationSource) { $CancellationSource.Dispose() }
    return $true
}
function New-TokenRaderRequestId { return [Int64]43 }
$script:Paths = [pscustomobject]@{ SessionsRoot = 'synthetic-only' }
$script:HistoryBackfillScript = { }
function New-BoundedUiState {
    $script:State = @{
        UiState = 'Measuring'; IsMeasuring = $true; MeasurementGeneration = [Int64]17
        IntervalBaseline = [pscustomobject]@{ StartedAt = [DateTimeOffset]'2026-10-01T00:00:00Z' }
        IntervalEnd = [pscustomobject]@{ EndedAt = [DateTimeOffset]'2026-10-01T01:00:00Z' }
        IntervalResult = [pscustomobject]@{ TotalCost = 12.34 }
        QuotaEstimates = [pscustomobject]@{ Weekly = 123.45 }
        IndexSyncing = $true; IndexSyncStopping = $false; IndexSyncRequestId = [Int64]41
        IndexReady = $true; PendingMeasurementStart = $false; BaselineRequestId = [Int64]0
        HistoryBackfillRunning = $true; HistoryBackfillStopping = $false; HistoryBackfillRequestId = [Int64]42
        HistoryCoverage = $null; ToolBackfillRunning = $false; UsageHistoryRefreshing = $false
        BackgroundJobs = @{}; ProjectCache = @{}; QuotaCalibrationMessage = ''
    }
}

New-BoundedUiState
$baseline = $script:State.IntervalBaseline; $end = $script:State.IntervalEnd
$result = $script:State.IntervalResult; $quota = $script:State.QuotaEstimates
Fail-TokenRaderIndexSyncJob 'synthetic timeout' 0 41 'IndexSync' @{ StopPending = $true; ColdStart = $false }
Assert-BoundedUi ($script:State.IndexSyncing -and $script:State.IndexSyncStopping -and $script:State.IndexSyncRequestId -eq 41) 'index timeout released gate before EndStop'
Assert-BoundedUi ($script:State.MeasurementGeneration -eq 17 -and $script:State.UiState -eq 'Measuring') 'index timeout changed measurement state'
Complete-TokenRaderIndexSyncStopJob $null 0 41 'IndexSync' @{}
Assert-BoundedUi (-not $script:State.IndexSyncing -and $script:State.IndexSyncRequestId -eq 0) 'index stop completion failed to release its gate'

Fail-TokenRaderHistoryBackfillJob 'synthetic timeout' 0 42 'HistoryBackfill' @{ StopPending = $true }
Assert-BoundedUi ($script:State.HistoryBackfillRunning -and $script:State.HistoryBackfillStopping) 'history timeout released gate before old worker exit'
Complete-TokenRaderHistoryBackfillStopJob $null 0 42 'HistoryBackfill' @{}
Assert-BoundedUi (-not $script:State.HistoryBackfillRunning -and $script:State.HistoryBackfillRequestId -eq 0) 'history stop completion did not allow resume'
Assert-BoundedUi ([object]::ReferenceEquals($baseline, $script:State.IntervalBaseline) -and
    [object]::ReferenceEquals($end, $script:State.IntervalEnd) -and [object]::ReferenceEquals($result, $script:State.IntervalResult) -and
    [object]::ReferenceEquals($quota, $script:State.QuotaEstimates)) 'auxiliary failures replaced measurement/results/quota objects'
Set-TokenRaderHistoryCoverage ([pscustomobject]@{ HistoryComplete = $false; CoverageStart = [DateTimeOffset]'2026-10-01T00:00:00Z' })
$partialLabel = -join @([char]0x5386, [char]0x53F2, [char]0x672A, [char]0x8865, [char]0x9F50)
Assert-BoundedUi ($script:HistoryCoverageText.Text -match $partialLabel -and $script:UsageHistoryCoverageText.Text -match $partialLabel) 'partial coverage absent from session or history overview'
Start-TokenRaderHistoryBackfill
Assert-BoundedUi ($script:LaunchCalls -eq 0) 'history backfill started during live measurement'
$script:State.UiState = 'Idle'
$script:State.HistoryBackfillRunning = $true
$script:State.HistoryBackfillStopping = $true
Start-TokenRaderHistoryBackfill
Assert-BoundedUi ($script:LaunchCalls -eq 0) 'history backfill relaunched before its old worker exited'
$script:State.HistoryBackfillRunning = $false
$script:State.HistoryBackfillStopping = $false
Start-TokenRaderHistoryBackfill
Assert-BoundedUi ($script:LaunchCalls -eq 1 -and $script:State.HistoryBackfillRequestId -eq 43) 'paused history backfill did not resume on a later idle click'

# Callback renderer failure must still be scoped and preserve the stop gate.
New-BoundedUiState
$script:ThrowRender = $true
Resolve-TokenRaderBackgroundCallbackFailure ([pscustomobject]@{
    Kind = 'IndexSync'; Generation = [Int64]0; RequestId = [Int64]41
    CallbackContext = @{ StopPending = $true; ColdStart = $false }
}) 'synthetic callback failure'
Assert-BoundedUi ($script:State.IndexSyncing -and $script:State.IndexSyncRequestId -eq 41 -and $script:ResetCalls -eq 0) 'index callback error invoked global reset or released gate'
$script:ThrowRender = $false

# BeginStop can fail; use a synthetic worker whose original invocation remains
# pending. The real dispatcher poller must not release it before IsCompleted.
$script:State.HistoryBackfillRunning = $false
$invocation = [pscustomobject]@{ IsCompleted = $false }
$worker = [pscustomobject]@{ EndCalls = 0; DisposeCalls = 0 }
$worker | Add-Member ScriptMethod BeginStop { param($callback, $state); throw 'synthetic BeginStop failure' }
$worker | Add-Member ScriptMethod EndInvoke { param($async); $this.EndCalls++ }
$worker | Add-Member ScriptMethod Dispose { $this.DisposeCalls++ }
$job = [pscustomobject]@{
    Kind = 'IndexSync'; Generation = [Int64]0; RequestId = [Int64]41; PowerShell = $worker
    AsyncResult = $invocation; StopAsyncResult = $null; StopViaInvoke = $false; CompletionDelivered = $false
    CancellationSource = $null; CallbackContext = @{}; StopCompletionHandler = 'Complete-TokenRaderIndexSyncStopJob'
}
$script:State.BackgroundJobs[[Int64]41] = $job
try {
    Request-TokenRaderBackgroundStop $job
    Assert-BoundedUi ($job.StopViaInvoke -and [object]::ReferenceEquals($invocation, $job.StopAsyncResult)) 'BeginStop failure discarded the pending invocation'
    Assert-BoundedUi ($script:State.BackgroundJobs.Count -eq 1 -and $worker.DisposeCalls -eq 0) 'BeginStop failure disposed/unregistered live worker'
    Start-TokenRaderBackgroundPoller
    $frame = New-Object Windows.Threading.DispatcherFrame
    $pump = New-Object Windows.Threading.DispatcherTimer
    $pump.Interval = [TimeSpan]::FromMilliseconds(150)
    $pump.Add_Tick({ $frame.Continue = $false; $pump.Stop() })
    $pump.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
    Assert-BoundedUi ($script:State.IndexSyncing -and $script:State.BackgroundJobs.Count -eq 1) 'poller released still-pending worker'
    $invocation.IsCompleted = $true
    $frame = New-Object Windows.Threading.DispatcherFrame
    $pump.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
    Assert-BoundedUi (-not $script:State.IndexSyncing -and $script:State.BackgroundJobs.Count -eq 0 -and $worker.EndCalls -eq 1 -and $worker.DisposeCalls -eq 1) 'poller did not await actual invocation exit before cleanup'
} finally {
    if ($null -ne $script:BackgroundPollTimer) { $script:BackgroundPollTimer.Stop() }
}

# Closing must cancel and drain asynchronously while the dispatcher stays
# alive. No synchronous Stop/Dispose is allowed before the invocation exits.
New-BoundedUiState
$script:Explorer = $null
$script:State.CloseRequested = $false; $script:State.CloseDispatchPending = $false
$script:Timer = [pscustomobject]@{ StopCalls = 0 }
$script:Timer | Add-Member ScriptMethod Stop { $this.StopCalls++ }
$script:Window = [pscustomobject]@{
    Dispatcher = [Windows.Threading.Dispatcher]::CurrentDispatcher
    Content = [pscustomobject]@{ IsEnabled = $true }; CloseCalls = 0
}
$script:Window | Add-Member ScriptMethod Close { $this.CloseCalls++ }
$script:HostResetCalls = 0; $script:IndexCloseCalls = 0
function Reset-TokenRaderComputeHost { $script:HostResetCalls++ }
function Close-TokenRaderIndex { param([switch]$KeepWatcher); $script:IndexCloseCalls++ }
$invocation = [pscustomobject]@{ IsCompleted = $false }
$worker = [pscustomobject]@{ EndCalls = 0; DisposeCalls = 0; StopCalls = 0 }
$worker | Add-Member ScriptMethod BeginStop { param($callback, $state); throw 'synthetic BeginStop fallback' }
$worker | Add-Member ScriptMethod EndInvoke { param($async); $this.EndCalls++ }
$worker | Add-Member ScriptMethod Dispose { $this.DisposeCalls++ }
$worker | Add-Member ScriptMethod Stop { $this.StopCalls++; throw 'synchronous stop must not be called' }
$cts = [Threading.CancellationTokenSource]::new()
$job = [pscustomobject]@{
    Kind = 'HistoryBackfill'; Generation = [Int64]0; RequestId = [Int64]42; PowerShell = $worker
    AsyncResult = $invocation; StopAsyncResult = $null; StopViaInvoke = $false; CompletionDelivered = $false
    CancellationSource = $cts; CallbackContext = @{}; StopCompletionHandler = 'Complete-TokenRaderHistoryBackfillStopJob'
}
$script:State.BackgroundJobs[[Int64]42] = $job
try {
    $eventArgs = [pscustomobject]@{ Cancel = $false }
    Request-TokenRaderWindowClose -EventArgs $eventArgs
    Assert-BoundedUi ($eventArgs.Cancel -and $script:State.CloseRequested -and -not $script:WindowClosing) 'active workers must defer actual window closing'
    Assert-BoundedUi ($cts.IsCancellationRequested -and $worker.StopCalls -eq 0 -and $worker.DisposeCalls -eq 0 -and $script:HostResetCalls -eq 0) 'close did not cooperatively cancel or performed synchronous stop/disposal'
    Assert-BoundedUi (-not $script:Window.Content.IsEnabled -and $script:BackgroundPollTimer.IsEnabled) 'close did not disable new UI actions or preserve poller'
    $startedDuringClose = Start-TokenRaderBackgroundJobUnderTest -ScriptBlock { throw 'must not run' } `
        -Kind 'Synthetic' -RequestId 99 -CompletionHandler 'none' -FailureHandler 'none'
    Assert-BoundedUi (-not $startedDuringClose -and $script:State.BackgroundJobs.Count -eq 1) 'a new worker started after close was requested'
    $frame = New-Object Windows.Threading.DispatcherFrame
    $pump = New-Object Windows.Threading.DispatcherTimer
    $pump.Interval = [TimeSpan]::FromMilliseconds(150)
    $pump.Add_Tick({ $frame.Continue = $false; $pump.Stop() })
    $pump.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
    Assert-BoundedUi ($script:Window.CloseCalls -eq 0 -and $script:State.BackgroundJobs.Count -eq 1) 'window closed while invocation still pending'
    $invocation.IsCompleted = $true
    $frame = New-Object Windows.Threading.DispatcherFrame
    $pump.Start(); [Windows.Threading.Dispatcher]::PushFrame($frame)
    Assert-BoundedUi ($script:Window.CloseCalls -eq 1 -and $script:State.BackgroundJobs.Count -eq 0 -and $worker.EndCalls -eq 1 -and $worker.DisposeCalls -eq 1) 'drained worker did not dispatch the final close'
    $eventArgs = [pscustomobject]@{ Cancel = $false }
    Request-TokenRaderWindowClose -EventArgs $eventArgs
    Assert-BoundedUi (-not $eventArgs.Cancel -and $script:WindowClosing -and $script:HostResetCalls -eq 1 -and $script:IndexCloseCalls -eq 1) 'final close did not defer host/index cleanup until all workers exited'
} finally {
    if ($null -ne $script:BackgroundPollTimer) { $script:BackgroundPollTimer.Stop() }
    $script:WindowClosing = $false
    $script:State.CloseRequested = $false
}

$script:Explorer = @{ Job = [pscustomobject]@{ Synthetic = $true }; CloseOwner = $false }
$script:ExplorerStopCalls = 0
function Stop-ExplorerWork { $script:ExplorerStopCalls++ }
$eventArgs = [pscustomobject]@{ Cancel = $false }
Request-TokenRaderWindowClose -EventArgs $eventArgs
Assert-BoundedUi ($eventArgs.Cancel -and $script:Explorer.CloseOwner -and $script:ExplorerStopCalls -eq 1 -and -not $script:WindowClosing) 'existing Explorer asynchronous-close path was not preserved'
$script:Explorer = $null; $script:State.CloseRequested = $false

# Execute the production background batch loop entirely against mock helpers.
$assignment = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$script:HistoryBackfillScript'
}, $true)
Invoke-Expression $assignment.Extent.Text
function Import-Module { param($Name, [switch]$Force) }
function Close-TokenRaderIndex { param([switch]$KeepWatcher) }
function Get-TokenRaderIndex { return [pscustomobject]@{ Connection = 'synthetic' } }
function Get-TokenRaderHistoryCoverage { param($Connection); return [pscustomobject]@{ HistoryComplete = $false; CoverageStart = $null } }
$script:BatchCalls = 0
$script:BatchRetryFlags = New-Object System.Collections.ArrayList
$script:AttemptedMode = $false
function Invoke-TokenRaderHistoryBackfillBatch {
    param($SessionsRoot, $ProgressState, $CancellationToken, $MaxBytes, $MaxMilliseconds, [switch]$RetryBlocked)
    $script:BatchCalls++
    [void]$script:BatchRetryFlags.Add([bool]$RetryBlocked)
    Assert-BoundedUi ($MaxBytes -eq 8388608 -and $MaxMilliseconds -eq 2000) 'worker ignored bounded batch limits'
    return [pscustomobject]@{ Completed = $false; ProcessedBytes = 0; RemainingFiles = 2; RemainingBytes = 100; ImportedRecords = 0; IndexRevision = 1; BlockedFiles = 2; AttemptedFiles = $(if ($script:AttemptedMode -and $script:BatchCalls -eq 1) { 1 } else { 0 }); EligibleFiles = $(if ($script:AttemptedMode -and $script:BatchCalls -eq 1) { 1 } else { 0 }) }
}
$payload = & $script:HistoryBackfillScript 'synthetic-only' 'synthetic-only' ([Threading.CancellationToken]::None) ([hashtable]::Synchronized(@{}))
Assert-BoundedUi ($script:BatchCalls -eq 1 -and -not $payload.Completed -and $payload.BlockedFiles -eq 2) 'zero-progress batch did not pause for resumable retry'
$script:BatchCalls = 0; $script:BatchRetryFlags.Clear(); $script:AttemptedMode = $true
$payload = & $script:HistoryBackfillScript 'synthetic-only' 'synthetic-only' ([Threading.CancellationToken]::None) ([hashtable]::Synchronized(@{}))
Assert-BoundedUi ($script:BatchCalls -eq 2 -and [bool]$script:BatchRetryFlags[0] -and -not [bool]$script:BatchRetryFlags[1]) 'transient blocked files must retry once per manual click, then permit other pending batches without spinning'
Write-Host ('BOUNDED_HISTORY_UI_TESTS_PASSED edition={0} version={1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
