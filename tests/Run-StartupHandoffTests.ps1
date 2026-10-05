[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-Handoff([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('STARTUP HANDOFF TEST FAILED: ' + $Message) }
}
$source = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'TokenRader.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-Handoff (@($errors).Count -eq 0) 'production parse'
foreach ($name in @('Get-TokenRaderCallbackContextValue', 'Complete-TokenRaderIndexSyncJob',
    'Fail-TokenRaderIndexSyncJob', 'Resolve-TokenRaderBackgroundCallbackFailure',
    'ConvertTo-TokenRaderCopyableStatusText', 'Set-TokenRaderLastFailureInfo')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Assert-Handoff ($null -ne $node) ('missing production function ' + $name)
    Invoke-Expression $node.Extent.Text
}
# Only extracted callbacks run. Every database, worker and UI seam is synthetic.
# No app launch, DLL build, private index, authentication or session-log reads.
$script:Paths = [pscustomobject]@{ SessionsRoot = 'synthetic-only' }
function Reset-Handoff {
    $script:WindowClosing = $false
    $script:State = @{
        UiState = 'Starting'; IsMeasuring = $false; MeasurementGeneration = 7L
        IndexSyncRequestId = 11L; IndexSyncing = $true; IndexSyncStopping = $false
        PendingMeasurementStart = $true; BaselineRequestId = 12L
        IndexReady = $false; IndexCatalogAvailable = $false
        ProjectCache = @{}; RateLimitSnapshotCache = @{}
        QuotaCalibrationMessage = ''; LastFailureInfo = ''
        IntervalBaseline = [pscustomobject]@{ Frozen = 'baseline' }
        IntervalResult = [pscustomobject]@{ Frozen = 'result' }
    }
    $script:StatusText = [pscustomobject]@{ Text = '' }
    $script:Faults = @(); $script:LaunchCalls = 0; $script:UsageCalls = 0
    $script:Reenter = ''; $script:LaunchOwned = $false; $script:HandledLaunchFailure = $false
}
function Invoke-SyntheticFault([string]$Name) {
    if ($script:Faults -contains $Name) { throw ('synthetic-' + $Name) }
}
function Set-TokenRaderHistoryCoverage { param($Coverage); Invoke-SyntheticFault 'Coverage' }
function Open-TokenRaderIndex { param($SessionsRoot, [switch]$SchemaReady); Invoke-SyntheticFault 'Open' }
function Update-TokenRaderToolBackfillButton { Invoke-SyntheticFault 'ToolButton' }
function Merge-LatestRateLimits { param($Candidate); Invoke-SyntheticFault 'Merge' }
function Refresh-Application {
    if ($script:Reenter -eq 'Refresh') { $script:State.IndexSyncRequestId = 99L }
    Invoke-SyntheticFault 'Refresh'
}
function Set-TokenRaderUiState {
    param($NewState, $StatusMessage)
    if ($script:Reenter -eq 'State') {
        $script:State.IndexSyncRequestId = 99L
        $script:State.BaselineRequestId = 100L
        $script:State.MeasurementGeneration = 8L
        $script:State.PendingMeasurementStart = $true
        return
    }
    Invoke-SyntheticFault 'State'
    $script:State.UiState = $NewState
    $script:StatusText.Text = $StatusMessage
}
function Start-TokenRaderMeasurementBaselineAsync {
    param($Generation, $RequestId)
    $script:LaunchCalls++
    $script:LaunchOwned = $script:State.IndexSyncRequestId -eq 11L -and
        $script:State.PendingMeasurementStart -and $RequestId -eq 12L -and $Generation -eq 7L
    if ($script:Reenter -eq 'Launch') {
        $script:State.IndexSyncRequestId = 99L; $script:State.BaselineRequestId = 100L
        $script:State.PendingMeasurementStart = $true; return
    }
    Invoke-SyntheticFault 'Launch'
    if ($script:HandledLaunchFailure) {
        $script:State.UiState = 'Error'; $script:State.BaselineRequestId = 0L
        $script:State.PendingMeasurementStart = $false
        Set-TokenRaderLastFailureInfo 'synthetic-BeginInvoke'
        $script:StatusText.Text = 'synthetic-BeginInvoke'
    }
}
function Start-TokenRaderUsageHistoryRefresh { $script:UsageCalls++; Invoke-SyntheticFault 'UsageLaunch' }
function Retain-TokenRaderQuotaEstimatesForCurrentWindow {
    if ($script:Reenter -eq 'Retain') {
        $script:State.MeasurementGeneration = 8L; $script:State.UiState = 'Starting'
        $script:State.BaselineRequestId = 100L; $script:State.PendingMeasurementStart = $true
        $script:State.LastFailureInfo = 'newer-failure'; return
    }
    Invoke-SyntheticFault 'Retain'
}
function Mark-TokenRaderQuotaEstimatesRetainedAfterFailure { Invoke-SyntheticFault 'Mark' }
function Update-QuotaCards { Invoke-SyntheticFault 'Cards' }
$payload = [pscustomobject]@{ SchemaInitialized = $true; HistoryCoverage = @{}; LatestRateLimits = @{} }
$job = [pscustomobject]@{ Kind = 'IndexSync'; Generation = 0L; RequestId = 11L; CallbackContext = @{ ColdStart = $true } }
function Invoke-CompleteHandoff {
    try { Complete-TokenRaderIndexSyncJob $payload 0L 11L 'IndexSync' @{ Startup = $true } }
    catch { Resolve-TokenRaderBackgroundCallbackFailure -Job $job -Message $_.Exception.Message }
}
foreach ($fault in @('', 'Coverage', 'ToolButton', 'Merge', 'State', 'All')) {
    Reset-Handoff
    $script:Faults = if ($fault -eq 'All') { @('Coverage','ToolButton','Merge','State') } elseif ($fault) { @($fault) } else { @() }
    Invoke-CompleteHandoff
    Assert-Handoff ($script:LaunchCalls -eq 1 -and $script:LaunchOwned) ('launch retains ownership: ' + $fault)
    Assert-Handoff ($script:State.UiState -eq 'Starting' -and $script:State.IndexReady -and
        $script:State.IndexSyncRequestId -eq 0 -and -not $script:State.PendingMeasurementStart) ('handoff: ' + $fault)
    if ($fault) {
        foreach ($name in $script:Faults) { Assert-Handoff ($script:State.LastFailureInfo.Contains('synthetic-' + $name)) ('original display cause: ' + $name) }
    }
}
foreach ($fault in @('Open', 'Launch')) {
    Reset-Handoff; $script:Faults = @($fault, 'Retain', 'Mark', 'State', 'Cards')
    Invoke-CompleteHandoff
    Assert-Handoff ($script:State.UiState -eq 'Error' -and -not $script:State.IsMeasuring -and
        $script:State.IndexSyncRequestId -eq 0 -and $script:State.BaselineRequestId -eq 0 -and
        -not $script:State.PendingMeasurementStart) ('retryable true failure: ' + $fault)
    Assert-Handoff ($script:State.LastFailureInfo.Contains('synthetic-' + $fault)) ('original true failure retained: ' + $fault)
    foreach ($name in @('Retain','Mark','State','Cards')) {
        Assert-Handoff ($script:State.LastFailureInfo.Contains('synthetic-' + $name)) ('secondary failure retained: ' + $name)
    }
}
Reset-Handoff; $script:Faults = @('Coverage'); $script:HandledLaunchFailure = $true
Invoke-CompleteHandoff
Assert-Handoff ($script:State.UiState -eq 'Error' -and $script:State.IndexSyncRequestId -eq 0 -and
    $script:State.LastFailureInfo -eq 'synthetic-BeginInvoke' -and $script:StatusText.Text -eq 'synthetic-BeginInvoke') 'handled launch failure is not replaced by display summary'
foreach ($where in @('State', 'Launch')) {
    Reset-Handoff; $script:Reenter = $where; Invoke-CompleteHandoff
    Assert-Handoff ($script:State.IndexSyncRequestId -eq 99 -and $script:State.BaselineRequestId -eq 100 -and
        $script:State.PendingMeasurementStart) ('new request preserved: ' + $where)
    if ($where -eq 'State') { Assert-Handoff ($script:LaunchCalls -eq 0) 'old completion cannot launch after reentry' }
}
Reset-Handoff; $script:State.UiState = 'Ready'; $script:State.PendingMeasurementStart = $false
$script:Reenter = 'Refresh'; Invoke-CompleteHandoff
Assert-Handoff ($script:State.IndexSyncRequestId -eq 99 -and $script:UsageCalls -eq 0) 'refresh reentry cannot launch old usage task'
foreach ($fault in @('Refresh', 'State')) {
    Reset-Handoff; $script:State.UiState = 'Ready'; $script:State.PendingMeasurementStart = $false
    $script:Faults = @($fault); Invoke-CompleteHandoff
    Assert-Handoff ($script:UsageCalls -eq 1 -and $script:State.IndexSyncRequestId -eq 0 -and
        $script:State.UiState -eq 'Ready' -and $script:State.LastFailureInfo.Contains('synthetic-' + $fault)) 'ready display failure does not block auxiliary launch'
}
foreach ($stopPending in @($false, $true)) {
    Reset-Handoff; $script:Faults = @('Retain','Mark','State','Cards')
    Fail-TokenRaderIndexSyncJob 'synthetic-worker' 0L 11L 'IndexSync' @{ StopPending = $stopPending }
    Assert-Handoff ($script:State.UiState -eq 'Error' -and $script:State.BaselineRequestId -eq 0 -and
        -not $script:State.PendingMeasurementStart) 'failure rendering cannot leave Starting'
    Assert-Handoff ($script:State.LastFailureInfo.Contains('synthetic-worker')) 'worker failure remains copyable'
    Assert-Handoff ($script:State.IndexSyncRequestId -eq $(if ($stopPending) { 11 } else { 0 }) -and
        $script:State.IndexSyncing -eq $stopPending -and $script:State.IndexSyncStopping -eq $stopPending) 'stop retains real worker gate'
}
Reset-Handoff; $script:State.UiState = 'Measuring'; $script:State.IsMeasuring = $true
$script:State.PendingMeasurementStart = $false; $script:Faults = @('Retain','Mark','State','Cards')
$baseline = $script:State.IntervalBaseline; $result = $script:State.IntervalResult
Fail-TokenRaderIndexSyncJob 'synthetic-worker' 0L 11L 'IndexSync' @{}
Assert-Handoff ($script:State.UiState -eq 'Measuring' -and $script:State.IsMeasuring -and
    $script:State.MeasurementGeneration -eq 7 -and [object]::ReferenceEquals($baseline, $script:State.IntervalBaseline) -and
    [object]::ReferenceEquals($result, $script:State.IntervalResult)) 'active measurement and frozen evidence survive auxiliary failure'
Reset-Handoff; $script:Reenter = 'Retain'
Fail-TokenRaderIndexSyncJob 'old-worker' 0L 11L 'IndexSync' @{}
Assert-Handoff ($script:State.MeasurementGeneration -eq 8 -and $script:State.UiState -eq 'Starting' -and
    $script:State.BaselineRequestId -eq 100 -and $script:State.PendingMeasurementStart -and
    $script:State.LastFailureInfo -eq 'newer-failure') 'failure display reentry cannot overwrite new measurement without new index job'
Reset-Handoff; $script:State.IndexSyncRequestId = 99L; $script:State.LastFailureInfo = 'newer-failure'
Complete-TokenRaderIndexSyncJob $payload 0L 11L 'IndexSync' @{}
Fail-TokenRaderIndexSyncJob 'stale-failure' 0L 11L 'IndexSync' @{}
Assert-Handoff ($script:LaunchCalls -eq 0 -and $script:State.IndexSyncRequestId -eq 99 -and
    $script:State.PendingMeasurementStart -and $script:State.LastFailureInfo -eq 'newer-failure') 'stale callbacks ignored'
Write-Host 'Startup handoff synthetic tests passed.'
