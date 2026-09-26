[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HistoryCallbackRecovery {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('HISTORY CALLBACK RECOVERY TEST FAILED: ' + $Message) }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $projectRoot 'TokenRader.ps1'))

# Load only the production callback helpers under test. This is deliberately a
# source-extraction harness: it does not launch the application, inspect logs,
# or load account/auth/private-index data.
foreach ($helperName in @(
        'Get-TokenRaderCallbackContextValue',
        'Reset-TokenRaderBackgroundFailureState',
        'Resolve-TokenRaderBackgroundCallbackFailure',
        'Start-TokenRaderPendingUsageHistory',
        'Complete-TokenRaderUsageHistoryJob',
        'Fail-TokenRaderUsageHistoryJob',
        'Complete-TokenRaderUsageHistoryStopJob')) {
    $match = [regex]::Match($source, ('(?s)function ' + [regex]::Escape($helperName) + '\b.*?(?=\r?\nfunction |\z)'))
    Assert-HistoryCallbackRecovery $match.Success ('production helper not found: ' + $helperName)
    Invoke-Expression $match.Value
}

# Verify that every dispatcher/worker exception path routes through the scoped
# resolver. Non-history jobs still take the global failure path inside it.
$resolverCalls = [regex]::Matches($source, 'Resolve-TokenRaderBackgroundCallbackFailure\s+-Job')
Assert-HistoryCallbackRecovery ($resolverCalls.Count -ge 7) 'background completion, failure, stop, timeout, or startup catch bypasses the scoped resolver'
$globalResetCalls = [regex]::Matches($source, 'Reset-TokenRaderBackgroundFailureState\s+-Message')
Assert-HistoryCallbackRecovery ($globalResetCalls.Count -eq 1) 'global failure reset is called outside the scoped resolver'

$script:WindowClosing = $false
$script:UsageHistoryStatusText = [pscustomobject]@{ Text = '' }
$script:BackfillUpdateCalls = 0
$script:ThrowOnBackfillUpdate = $false
$script:ThrowHistoryRenderer = $false
$script:ThrowHistoryRefreshLaunch = $false
$script:HistoryRendererCalls = 0
$script:LastRenderedHistory = $null
$script:HistoryRefreshLaunches = 0
$script:BackgroundJobStartCalls = 0
$script:ThrowHistoryOffsetSelection = $false

function Show-TokenRaderUsageHistoryResult {
    param($Result)
    $script:HistoryRendererCalls++
    $script:LastRenderedHistory = $Result
    $script:UsageHistoryStatusText.Text = 'synthetic history rendered'
    if ($script:ThrowHistoryRenderer) { throw 'synthetic history renderer failure' }
}

function Update-TokenRaderToolBackfillButton {
    $script:BackfillUpdateCalls++
    if ($script:ThrowOnBackfillUpdate) { throw 'synthetic backfill button update failure' }
}

function Start-TokenRaderUsageHistoryRefresh {
    param([int]$DayOffset = -1, [bool]$ForceRefresh = $false, [bool]$PurgeExpired = $false)
    $script:HistoryRefreshLaunches++
    if ($script:ThrowHistoryRefreshLaunch) { throw 'synthetic queued history launch failure' }
    $script:State.UsageHistoryRequestId = [Int64]880L
    $script:State.UsageHistoryRefreshing = $true
}

$refreshMatch = [regex]::Match($source, '(?s)function Start-TokenRaderUsageHistoryRefresh\b.*?(?=\r?\nfunction |\z)')
Assert-HistoryCallbackRecovery $refreshMatch.Success 'production usage-history refresh helper not found'
$refreshUnderTest = $refreshMatch.Value -replace 'function Start-TokenRaderUsageHistoryRefresh\b', 'function Start-TokenRaderUsageHistoryRefreshUnderTest'
Invoke-Expression $refreshUnderTest

function Get-SelectedUsageHistoryDayOffset {
    if ($script:ThrowHistoryOffsetSelection) { throw 'synthetic history range selection failure' }
    return 0
}

function Start-TokenRaderBackgroundJob {
    param($ScriptBlock, $Parameters, [string]$Kind, [Int64]$RequestId, [string]$CompletionHandler, [string]$FailureHandler)
    $script:BackgroundJobStartCalls++
    return $true
}

function Retain-TokenRaderQuotaEstimatesForCurrentWindow { param($RateLimits, [string]$AccountIdentity) }
function Mark-TokenRaderQuotaEstimatesRetainedAfterFailure { }
function Update-QuotaCards { }
function Set-TokenRaderUiState {
    param([string]$NewState, [string]$StatusMessage = '')
    $script:State.UiState = $NewState
    $script:State.IsMeasuring = ($NewState -eq 'Measuring')
    if (-not [string]::IsNullOrWhiteSpace($StatusMessage)) { $script:StatusText.Text = $StatusMessage }
}

function New-HistoryRecoveryScenario {
    param(
        [Parameter(Mandatory = $true)][string]$UiState,
        [Parameter(Mandatory = $true)][bool]$IsMeasuring,
        [Parameter(Mandatory = $true)][Int64]$RequestId
    )
    $baseline = [pscustomobject]@{
        StartedAt = [DateTimeOffset]::Parse('2030-01-02T03:04:05Z')
        StartOffsets = @{ synthetic = 10L }
    }
    $frozenEnd = if ($UiState -eq 'ComputingFinal') {
        [pscustomobject]@{
            EndOffsets = @{ synthetic = 77L }
            EndRevision = 41L
            EndedAt = [DateTimeOffset]::Parse('2030-01-02T03:14:05Z')
        }
    } else { $null }
    $finalRetry = if ($UiState -eq 'ComputingFinal') {
        [pscustomobject]@{ EndOffsets = $frozenEnd.EndOffsets; EndRevision = $frozenEnd.EndRevision; EndedAt = $frozenEnd.EndedAt }
    } else { $null }
    $quotaEstimates = [pscustomobject]@{
        FiveHour = [pscustomobject]@{ TotalUsd = 250.0 }
        Weekly = [pscustomobject]@{ TotalUsd = 500.0 }
    }
    $weeklyReference = [pscustomobject]@{ TotalUsd = 700.0; Label = 'synthetic reference' }
    $lastHistoryResult = [pscustomobject]@{ Marker = 'previous valid history' }
    $state = @{
        BackgroundJobs = @{}
        UiState = $UiState
        IsMeasuring = $IsMeasuring
        MeasurementGeneration = 63L
        IntervalBaseline = $baseline
        IntervalEnd = $frozenEnd
        IntervalFinalRetry = $finalRetry
        IntervalResult = [pscustomobject]@{ Marker = 'previous measurement result' }
        QuotaEstimates = $quotaEstimates
        WeeklyReferenceEstimate = $weeklyReference
        AccountIdentity = 'synthetic-account'
        RateLimits = $null
        QuotaDiagnostics = [pscustomobject]@{ Marker = 'synthetic diagnostic' }
        UsageHistoryRequestId = $RequestId
        UsageHistoryRefreshing = $true
        UsageHistoryStopping = $false
        UsageHistoryPending = $true
        UsageHistoryPendingRequest = [pscustomobject]@{ DayOffset = 2; ForceRefresh = $true; PurgeExpired = $false }
        UsageHistoryResult = $lastHistoryResult
        ToolBackfillRunning = $false
        ToolBackfillRequestId = 0L
        PendingMeasurementStart = $false
    }
    $expectedMeasurement = [pscustomobject]@{
        UiState = $UiState
        IsMeasuring = $IsMeasuring
        MeasurementGeneration = 63L
        IntervalBaseline = $baseline
        IntervalEnd = $frozenEnd
        IntervalFinalRetry = $finalRetry
        IntervalResult = $state.IntervalResult
        QuotaEstimates = $quotaEstimates
        WeeklyReferenceEstimate = $weeklyReference
        QuotaDiagnostics = $state.QuotaDiagnostics
    }
    return [pscustomobject]@{
        State = $state
        ExpectedMeasurement = $expectedMeasurement
        PreviousHistoryResult = $lastHistoryResult
    }
}

function Assert-HistoryMeasurementPreserved {
    param($Expected, [string]$CaseName)
    Assert-HistoryCallbackRecovery ([string]$script:State.UiState -eq [string]$Expected.UiState) ($CaseName + ': UI state changed')
    Assert-HistoryCallbackRecovery ([bool]$script:State.IsMeasuring -eq [bool]$Expected.IsMeasuring) ($CaseName + ': IsMeasuring changed')
    Assert-HistoryCallbackRecovery ([Int64]$script:State.MeasurementGeneration -eq [Int64]$Expected.MeasurementGeneration) ($CaseName + ': measurement generation changed')
    Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.IntervalBaseline, $Expected.IntervalBaseline)) ($CaseName + ': baseline changed')
    Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.IntervalEnd, $Expected.IntervalEnd)) ($CaseName + ': frozen end changed')
    Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.IntervalFinalRetry, $Expected.IntervalFinalRetry)) ($CaseName + ': final retry state changed')
    Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.IntervalResult, $Expected.IntervalResult)) ($CaseName + ': last measurement result changed')
    Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.QuotaEstimates, $Expected.QuotaEstimates)) ($CaseName + ': quota estimates changed')
    Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.WeeklyReferenceEstimate, $Expected.WeeklyReferenceEstimate)) ($CaseName + ': weekly reference changed')
    Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.QuotaDiagnostics, $Expected.QuotaDiagnostics)) ($CaseName + ': quota diagnostics changed')
}

function Invoke-SyntheticPollerCallback {
    param([scriptblock]$Callback, $Job)
    try {
        & $Callback
    } catch {
        Resolve-TokenRaderBackgroundCallbackFailure -Job $Job -Message ('synthetic dispatcher callback failure: ' + $_.Exception.Message)
    }
}

# A renderer exception after the worker has succeeded must be caught as a
# callback failure, retaining the prior history payload and all measurement
# state in both live and frozen-final measurement modes.
foreach ($uiState in @('Measuring', 'ComputingFinal')) {
    $isMeasuring = ($uiState -eq 'Measuring')
    $scenario = New-HistoryRecoveryScenario -UiState $uiState -IsMeasuring $isMeasuring -RequestId 401L
    $script:State = $scenario.State
    $script:UsageHistoryStatusText.Text = 'before render'
    $script:ThrowHistoryRenderer = $true
    $script:ThrowOnBackfillUpdate = $false
    $script:ThrowHistoryRefreshLaunch = $false
    $payload = [pscustomobject]@{ Marker = 'new history payload' }
    $job = [pscustomobject]@{ Kind = 'UsageHistory'; RequestId = 401L; CallbackContext = @{} }
    Invoke-SyntheticPollerCallback {
        Complete-TokenRaderUsageHistoryJob $payload 0L 401L 'UsageHistory' @{}
    } $job
    Assert-HistoryCallbackRecovery ($script:HistoryRendererCalls -gt 0) ($uiState + ': completion did not reach renderer')
    Assert-HistoryCallbackRecovery ([Int64]$script:State.UsageHistoryRequestId -eq 0L) ($uiState + ': renderer failure did not release its request')
    Assert-HistoryCallbackRecovery (-not [bool]$script:State.UsageHistoryRefreshing -and -not [bool]$script:State.UsageHistoryStopping) ($uiState + ': renderer failure left history busy')
    Assert-HistoryCallbackRecovery (-not [bool]$script:State.UsageHistoryPending -and $null -eq $script:State.UsageHistoryPendingRequest) ($uiState + ': renderer failure kept a queued request')
    Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.UsageHistoryResult, $scenario.PreviousHistoryResult)) ($uiState + ': failed render replaced the last valid history result')
    Assert-HistoryCallbackRecovery ($script:UsageHistoryStatusText.Text -match 'synthetic dispatcher callback failure.*synthetic history renderer failure') ($uiState + ': history callback error was not reported')
    Assert-HistoryMeasurementPreserved $scenario.ExpectedMeasurement ($uiState + ' renderer failure')
}

# An exception inside the worker-failure handler's UI update is scoped to the
# history request rather than flowing into the application's global reset.
$scenario = New-HistoryRecoveryScenario -UiState 'Measuring' -IsMeasuring $true -RequestId 501L
$script:State = $scenario.State
$script:ThrowHistoryRenderer = $false
$script:ThrowOnBackfillUpdate = $true
$failureJob = [pscustomobject]@{ Kind = 'UsageHistory'; RequestId = 501L; CallbackContext = @{} }
Invoke-SyntheticPollerCallback {
    Fail-TokenRaderUsageHistoryJob 'synthetic worker failure' 0L 501L 'UsageHistory' @{}
} $failureJob
Assert-HistoryCallbackRecovery ([Int64]$script:State.UsageHistoryRequestId -eq 0L) 'failure-handler exception did not release the history request'
Assert-HistoryCallbackRecovery (-not [bool]$script:State.UsageHistoryRefreshing) 'failure-handler exception left history refreshing'
Assert-HistoryCallbackRecovery ($script:UsageHistoryStatusText.Text -match 'synthetic dispatcher callback failure.*synthetic backfill button update failure') 'failure-handler callback error was not reported'
Assert-HistoryMeasurementPreserved $scenario.ExpectedMeasurement 'failure handler exception'

# A stop-completion UI exception is scoped too. StopPending is cleared by the
# poller only once the asynchronous stop has actually completed.
$scenario = New-HistoryRecoveryScenario -UiState 'ComputingFinal' -IsMeasuring $false -RequestId 601L
$script:State = $scenario.State
$script:State.UsageHistoryStopping = $true
$stopContext = @{ StopPending = $false }
$stopJob = [pscustomobject]@{ Kind = 'UsageHistory'; RequestId = 601L; CallbackContext = $stopContext }
$script:ThrowOnBackfillUpdate = $true
Invoke-SyntheticPollerCallback {
    Complete-TokenRaderUsageHistoryStopJob $null 0L 601L 'UsageHistory' $stopContext
} $stopJob
Assert-HistoryCallbackRecovery ([Int64]$script:State.UsageHistoryRequestId -eq 0L) 'stop callback exception did not release its completed request'
Assert-HistoryCallbackRecovery (-not [bool]$script:State.UsageHistoryRefreshing -and -not [bool]$script:State.UsageHistoryStopping) 'stop callback exception left history busy after stop completion'
Assert-HistoryCallbackRecovery ($script:UsageHistoryStatusText.Text -match 'synthetic dispatcher callback failure.*synthetic backfill button update failure') 'stop callback error was not reported'
Assert-HistoryMeasurementPreserved $scenario.ExpectedMeasurement 'stop callback exception'

# Timeout handling has a distinct StopPending state: do not unlock or launch a
# second history worker until the original asynchronous stop has completed.
$scenario = New-HistoryRecoveryScenario -UiState 'Measuring' -IsMeasuring $true -RequestId 701L
$script:State = $scenario.State
$script:ThrowOnBackfillUpdate = $false
$script:BackfillUpdateCalls = 0
$script:HistoryRefreshLaunches = 0
$timeoutJob = [pscustomobject]@{ Kind = 'UsageHistory'; RequestId = 701L; CallbackContext = @{ StopPending = $true } }
Resolve-TokenRaderBackgroundCallbackFailure -Job $timeoutJob -Message 'synthetic timeout callback failure'
Assert-HistoryCallbackRecovery ([Int64]$script:State.UsageHistoryRequestId -eq 701L) 'StopPending failure cleared the owner request too early'
Assert-HistoryCallbackRecovery ([bool]$script:State.UsageHistoryRefreshing -and [bool]$script:State.UsageHistoryStopping) 'StopPending failure unlocked history before the worker stopped'
Assert-HistoryCallbackRecovery (-not [bool]$script:State.UsageHistoryPending -and $null -eq $script:State.UsageHistoryPendingRequest) 'StopPending failure did not clear queued work'
Assert-HistoryCallbackRecovery (-not (Start-TokenRaderPendingUsageHistory)) 'a new history request started before the timed-out worker stopped'
Assert-HistoryCallbackRecovery ($script:HistoryRefreshLaunches -eq 0) 'StopPending failure launched a second worker'
Assert-HistoryMeasurementPreserved $scenario.ExpectedMeasurement 'StopPending history failure'
$timeoutJob.CallbackContext.StopPending = $false
Complete-TokenRaderUsageHistoryStopJob $null 0L 701L 'UsageHistory' $timeoutJob.CallbackContext
Assert-HistoryCallbackRecovery ([Int64]$script:State.UsageHistoryRequestId -eq 0L) 'completed asynchronous stop did not release history ownership'
Assert-HistoryCallbackRecovery (-not [bool]$script:State.UsageHistoryRefreshing -and -not [bool]$script:State.UsageHistoryStopping) 'completed asynchronous stop left history locked'
Assert-HistoryMeasurementPreserved $scenario.ExpectedMeasurement 'completed asynchronous stop'

# A selector/preparation exception while another history job is still active
# has no request ownership. It may report a history error, but must not release
# the live request or overwrite an already queued request.
$scenario = New-HistoryRecoveryScenario -UiState 'Measuring' -IsMeasuring $true -RequestId 751L
$script:State = $scenario.State
$script:State.IndexCatalogAvailable = $true
$activePendingRequest = $script:State.UsageHistoryPendingRequest
$script:ThrowHistoryOffsetSelection = $true
$jobsBeforeSelectionFailure = $script:BackgroundJobStartCalls
Start-TokenRaderUsageHistoryRefreshUnderTest
Assert-HistoryCallbackRecovery ([Int64]$script:State.UsageHistoryRequestId -eq 751L) 'selector failure cleared another request owner'
Assert-HistoryCallbackRecovery ([bool]$script:State.UsageHistoryRefreshing) 'selector failure unlocked an active history request'
Assert-HistoryCallbackRecovery ([bool]$script:State.UsageHistoryPending -and [object]::ReferenceEquals($script:State.UsageHistoryPendingRequest, $activePendingRequest)) 'selector failure overwrote pending request state'
Assert-HistoryCallbackRecovery ($script:BackgroundJobStartCalls -eq $jobsBeforeSelectionFailure) 'selector failure started a background worker'
Assert-HistoryCallbackRecovery ($script:UsageHistoryStatusText.Text -match 'synthetic history range selection failure') 'selector failure was not reported'
Assert-HistoryMeasurementPreserved $scenario.ExpectedMeasurement 'history selector failure with active request'
$script:ThrowHistoryOffsetSelection = $false

# A queued refresh that fails to launch is handled locally after the completed
# callback releases its request; it reports the error without touching the
# prior measurement or invalidating the newly rendered result.
$scenario = New-HistoryRecoveryScenario -UiState 'ComputingFinal' -IsMeasuring $false -RequestId 801L
$script:State = $scenario.State
$script:State.UsageHistoryPending = $true
$script:State.UsageHistoryPendingRequest = [pscustomobject]@{ DayOffset = 3; ForceRefresh = $true; PurgeExpired = $false }
$script:ThrowHistoryRenderer = $false
$script:ThrowOnBackfillUpdate = $false
$script:ThrowHistoryRefreshLaunch = $true
$script:HistoryRefreshLaunches = 0
$retryPayload = [pscustomobject]@{ Marker = 'rendered before queued launch failure' }
Complete-TokenRaderUsageHistoryJob $retryPayload 0L 801L 'UsageHistory' @{}
Assert-HistoryCallbackRecovery ($script:HistoryRefreshLaunches -eq 1) 'queued refresh launch failure was not exercised'
Assert-HistoryCallbackRecovery ([Int64]$script:State.UsageHistoryRequestId -eq 0L) 'queued launch failure left an owner request'
Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.UsageHistoryResult, $retryPayload)) 'successful render before queued launch failure was not retained'
Assert-HistoryCallbackRecovery ($script:UsageHistoryStatusText.Text -match 'synthetic queued history launch failure') 'queued launch failure was not reported'
Assert-HistoryMeasurementPreserved $scenario.ExpectedMeasurement 'queued history launch failure'

# A late callback for an older request must not alter the active retry, its
# queued request, status text, result, or any measurement state.
$script:State.UsageHistoryRequestId = 902L
$script:State.UsageHistoryRefreshing = $true
$script:State.UsageHistoryPending = $true
$script:State.UsageHistoryPendingRequest = [pscustomobject]@{ DayOffset = 4; ForceRefresh = $false; PurgeExpired = $true }
$script:UsageHistoryStatusText.Text = 'active retry status'
$pendingBeforeStale = $script:State.UsageHistoryPendingRequest
$historyBeforeStale = $script:State.UsageHistoryResult
$backfillCallsBeforeStale = $script:BackfillUpdateCalls
Resolve-TokenRaderBackgroundCallbackFailure -Job ([pscustomobject]@{
    Kind = 'UsageHistory'; RequestId = 901L; CallbackContext = @{}
}) -Message 'stale history failure'
Assert-HistoryCallbackRecovery ([Int64]$script:State.UsageHistoryRequestId -eq 902L) 'stale callback replaced the active request id'
Assert-HistoryCallbackRecovery ([bool]$script:State.UsageHistoryRefreshing) 'stale callback unlocked the active retry'
Assert-HistoryCallbackRecovery ([bool]$script:State.UsageHistoryPending -and [object]::ReferenceEquals($script:State.UsageHistoryPendingRequest, $pendingBeforeStale)) 'stale callback changed queued request state'
Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.UsageHistoryResult, $historyBeforeStale)) 'stale callback changed the last history result'
Assert-HistoryCallbackRecovery ($script:UsageHistoryStatusText.Text -eq 'active retry status') 'stale callback replaced visible status'
Assert-HistoryCallbackRecovery ($script:BackfillUpdateCalls -eq $backfillCallsBeforeStale) 'stale callback updated controls'
Assert-HistoryMeasurementPreserved $scenario.ExpectedMeasurement 'stale history callback'
$script:State.UsageHistoryPending = $false
$script:State.UsageHistoryPendingRequest = $null

# A fresh request succeeds after prior callback failures: the displayed result
# and stored history result advance, while measurement state remains identical.
$script:ThrowHistoryRefreshLaunch = $false
$script:ThrowOnBackfillUpdate = $false
$successPayload = [pscustomobject]@{ Marker = 'successful retry' }
Complete-TokenRaderUsageHistoryJob $successPayload 0L 902L 'UsageHistory' @{}
Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:State.UsageHistoryResult, $successPayload)) 'successful retry did not replace the stored history result'
Assert-HistoryCallbackRecovery ([object]::ReferenceEquals($script:LastRenderedHistory, $successPayload)) 'successful retry did not render its payload'
Assert-HistoryCallbackRecovery ([string]$script:UsageHistoryStatusText.Text -eq 'synthetic history rendered') 'successful retry did not restore a success status'
Assert-HistoryCallbackRecovery ([Int64]$script:State.UsageHistoryRequestId -eq 0L) 'successful retry did not release its request'
Assert-HistoryCallbackRecovery (-not [bool]$script:State.UsageHistoryRefreshing) 'successful retry left history refreshing'
Assert-HistoryMeasurementPreserved $scenario.ExpectedMeasurement 'successful history retry'

# A non-history callback still performs the original global failure reset.
$scenario = New-HistoryRecoveryScenario -UiState 'Measuring' -IsMeasuring $true -RequestId 1001L
$script:State = $scenario.State
$script:StatusText = [pscustomobject]@{ Text = '' }
Resolve-TokenRaderBackgroundCallbackFailure -Job ([pscustomobject]@{
    Kind = 'IntervalCompute'; RequestId = 1002L; CallbackContext = @{}
}) -Message 'synthetic non-history callback failure'
Assert-HistoryCallbackRecovery ([Int64]$script:State.MeasurementGeneration -eq 64L) 'non-history failure did not increment generation through global reset'
Assert-HistoryCallbackRecovery ([string]$script:State.UiState -eq 'Error') 'non-history failure did not retain global reset behavior'
Assert-HistoryCallbackRecovery ([string]$script:StatusText.Text -eq 'synthetic non-history callback failure') 'non-history global failure was not reported'

Write-Output 'HISTORY_CALLBACK_RECOVERY_TESTS_PASSED'
