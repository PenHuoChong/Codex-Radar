[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-IntervalRecovery {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw ('INTERVAL RECOVERY TEST FAILED: ' + $Message) }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $projectRoot 'TokenRader.ps1'))

# Load the production callback path into this test script's scope.  The test
# supplies only small UI/lifecycle seams below; it never reads auth data or
# real session logs.
foreach ($helperName in @(
        'Get-TokenRaderCallbackContextValue',
        'Complete-TokenRaderIntervalComputeJob',
        'Complete-TokenRaderIntervalCompute',
        'Update-TokenRaderWeeklyReferenceFromResult',
        'ConvertTo-TokenRaderOffsetHashtable',
        'Update-IntervalView')) {
    $match = [regex]::Match($source, ('(?s)function ' + [regex]::Escape($helperName) + '\b.*?(?=\r?\nfunction |\z)'))
    Assert-IntervalRecovery $match.Success ('production helper not found: ' + $helperName)
    Invoke-Expression $match.Value
}

$script:WindowClosing = $false
$script:StatusText = [pscustomobject]@{ Text = '' }
$script:ShowCalls = 0
$script:QuotaCardCalls = 0
$script:MergeCalls = 0
$script:HistoryRefreshCalls = 0

function Set-TokenRaderUiState {
    param([string]$NewState, [string]$StatusMessage = '')
    $script:State.UiState = $NewState
    $script:State.IsMeasuring = ($NewState -eq 'Measuring')
    if (-not [string]::IsNullOrWhiteSpace($StatusMessage)) { $script:StatusText.Text = $StatusMessage }
}

function Show-IntervalResult {
    param($Result, [bool]$Running)
    $script:ShowCalls++
    throw 'synthetic interval result rendering failure'
}

function Update-QuotaCards { $script:QuotaCardCalls++ }
function Merge-LatestRateLimits { param($Candidate) $script:MergeCalls++ }
function Start-TokenRaderUsageHistoryRefresh { param([switch]$PurgeExpired, [switch]$ForceRefresh); $script:HistoryRefreshCalls++ }
function Start-TokenRaderIntervalComputeAsync {
    param(
        $Baseline, $EndOffsets, $EndRevision, $EndedAt,
        [bool]$Final, [bool]$ScanRateLimits, [Int64]$Generation
    )
    $script:RetryStart = [pscustomobject]@{
        Baseline = $Baseline
        EndOffsets = $EndOffsets
        EndRevision = $EndRevision
        EndedAt = $EndedAt
        Final = $Final
        ScanRateLimits = $ScanRateLimits
        Generation = $Generation
    }
}

$generation = 17L
$baselineStartedAt = [DateTimeOffset]::Parse('2030-01-02T03:04:05Z')
$baseline = [pscustomobject]@{
    StartedAt = $baselineStartedAt
    StartOffsets = @{ synthetic = 10L }
    StartRateLimits = $null
}
$payload = [pscustomobject]@{
    Result = [pscustomobject]@{
        Signature = 'synthetic-render-failure'
        ChangeRevision = 4L
        TotalCost = 1.0
        EndRateLimits = $null
        AccountIdentity = 'synthetic-account'
        BaselineSnapshots = @{}
    }
    LatestRateLimits = $null
}

# A failed live render is advisory.  The real callback must leave the frozen
# baseline and Measuring state intact, while still releasing the in-flight
# request so the user can try a later preview.
$script:State = @{
    MeasurementGeneration = $generation
    IntervalComputeRequestId = 301L
    IntervalComputing = $true
    IntervalComputeStopping = $false
    IntervalActiveScanRateLimits = $false
    IntervalComputePending = $false
    IntervalComputePendingRequest = $null
    IntervalBaseline = $baseline
    IntervalResult = $null
    IntervalCache = $null
    IntervalFinalRetry = $null
    IntervalLastError = ''
    AccountIdentity = 'synthetic-account'
    UiState = 'Measuring'
    IsMeasuring = $true
}
$script:ShowCalls = 0
$script:QuotaCardCalls = 0
$script:HistoryRefreshCalls = 0

Complete-TokenRaderIntervalComputeJob $payload $generation 301L 'IntervalCompute' @{
    BaselineStartedAt = $baselineStartedAt
    Final = $false
    ScanRateLimits = $false
}

Assert-IntervalRecovery ($script:ShowCalls -eq 1) 'live callback did not invoke the production result renderer'
Assert-IntervalRecovery ([string]$script:State.UiState -eq 'Measuring') 'live rendering failure left Measuring'
Assert-IntervalRecovery ([bool]$script:State.IsMeasuring) 'live rendering failure stopped measurement'
Assert-IntervalRecovery ($script:State.IntervalBaseline -eq $baseline) 'live rendering failure replaced the frozen baseline'
Assert-IntervalRecovery ([Int64]$script:State.IntervalComputeRequestId -eq 0L) 'live rendering failure did not release the request id'
Assert-IntervalRecovery (-not [bool]$script:State.IntervalComputing) 'live rendering failure left computation locked'
Assert-IntervalRecovery ($script:State.IntervalLastError -match 'synthetic interval result rendering failure') 'live rendering error was not retained'
Assert-IntervalRecovery ($script:QuotaCardCalls -eq 1) 'live rendering failure did not refresh quota cards safely'
Assert-IntervalRecovery ($script:HistoryRefreshCalls -eq 0) 'failed live rendering refreshed usage history as if successful'

# A failed final render must retain the already-captured end and the existing
# frozen retry context.  The retry is cleared only after a successful render;
# later appends therefore cannot move this final retry boundary.
$intervalEnd = [pscustomobject]@{
    EndOffsets = @{ synthetic = 77L }
    EndRevision = 41L
    EndedAt = [DateTimeOffset]::Parse('2030-01-02T03:14:05Z')
}
$finalRetry = [pscustomobject]@{
    Generation = $generation
    BaselineStartedAt = $baselineStartedAt
    EndOffsets = @{ synthetic = 77L }
    EndRevision = 41L
    EndedAt = $intervalEnd.EndedAt
    ScanRateLimits = $true
}
$script:State = @{
    MeasurementGeneration = $generation
    IntervalComputeRequestId = 302L
    IntervalComputing = $true
    IntervalComputeStopping = $false
    IntervalActiveScanRateLimits = $true
    IntervalComputePending = $false
    IntervalComputePendingRequest = $null
    IntervalBaseline = $baseline
    IntervalResult = [pscustomobject]@{ Marker = 'previously-rendered-result' }
    IntervalCache = [pscustomobject]@{ Marker = 'previous-cache' }
    IntervalEnd = $intervalEnd
    IntervalFinalRetry = $finalRetry
    IntervalLastError = ''
    AccountIdentity = 'synthetic-account'
    UiState = 'ComputingFinal'
    IsMeasuring = $false
}
$script:ShowCalls = 0
$script:QuotaCardCalls = 0
$script:HistoryRefreshCalls = 0

Complete-TokenRaderIntervalComputeJob $payload $generation 302L 'IntervalCompute' @{
    BaselineStartedAt = $baselineStartedAt
    Final = $true
    EndOffsets = @{ synthetic = 77L }
    EndRevision = 41L
    EndedAt = $intervalEnd.EndedAt
    ScanRateLimits = $false
}

Assert-IntervalRecovery ($script:ShowCalls -eq 1) 'final callback did not invoke the production result renderer'
Assert-IntervalRecovery ([string]$script:State.UiState -eq 'Ready') 'final rendering failure did not enter Ready'
Assert-IntervalRecovery (-not [bool]$script:State.IsMeasuring) 'final rendering failure left measurement active'
Assert-IntervalRecovery ($script:State.IntervalEnd -eq $intervalEnd) 'final rendering failure replaced the captured IntervalEnd'
Assert-IntervalRecovery ([Int64]$script:State.IntervalEnd.EndRevision -eq 41L -and
    [Int64]$script:State.IntervalEnd.EndOffsets['synthetic'] -eq 77L) 'final IntervalEnd boundary changed'
Assert-IntervalRecovery ($script:State.IntervalFinalRetry -eq $finalRetry) 'final rendering failure discarded the existing retry context'
Assert-IntervalRecovery ([Int64]$script:State.IntervalFinalRetry.EndRevision -eq 41L -and
    [Int64]$script:State.IntervalFinalRetry.EndOffsets['synthetic'] -eq 77L) 'final retry boundary changed'
Assert-IntervalRecovery ([Int64]$script:State.IntervalComputeRequestId -eq 0L) 'final rendering failure did not release the request id'
Assert-IntervalRecovery (-not [bool]$script:State.IntervalComputing) 'final rendering failure left computation locked'
Assert-IntervalRecovery ($script:State.IntervalLastError -match 'synthetic interval result rendering failure') 'final rendering error was not retained'
Assert-IntervalRecovery ($script:QuotaCardCalls -eq 1) 'final rendering failure did not refresh quota cards safely'
Assert-IntervalRecovery ($script:HistoryRefreshCalls -eq 0) 'failed final rendering refreshed usage history as if successful'

# View Result first paints the cached result.  A broken cached renderer must
# not abort the click before the production code schedules the retry at the
# immutable final boundary.
$script:State = @{
    MeasurementGeneration = $generation
    IntervalComputing = $false
    IntervalBaseline = $baseline
    IntervalResult = [pscustomobject]@{ Marker = 'cached-result' }
    IntervalEnd = $intervalEnd
    IntervalFinalRetry = $finalRetry
    IntervalLastError = ''
    UiState = 'Ready'
    IsMeasuring = $false
}
$script:StatusText.Text = ''
$script:ShowCalls = 0
$script:RetryStart = $null

Update-IntervalView -Manual

Assert-IntervalRecovery ($script:ShowCalls -eq 1) 'View Result did not attempt to paint its cached result'
Assert-IntervalRecovery ($null -ne $script:RetryStart) 'cached render failure aborted the final retry'
Assert-IntervalRecovery ([bool]$script:RetryStart.Final) 'cached render failure scheduled a non-final retry'
Assert-IntervalRecovery ([bool]$script:RetryStart.ScanRateLimits) 'cached render failure skipped quota evidence on retry'
Assert-IntervalRecovery ([Int64]$script:RetryStart.Generation -eq $generation) 'cached render failure changed retry generation'
Assert-IntervalRecovery ($script:RetryStart.Baseline -eq $baseline) 'cached render failure changed retry baseline'
Assert-IntervalRecovery ([Int64]$script:RetryStart.EndRevision -eq 41L -and
    [Int64]$script:RetryStart.EndOffsets['synthetic'] -eq 77L) 'cached render failure moved the frozen retry boundary'
Assert-IntervalRecovery ($script:State.IntervalEnd -eq $intervalEnd -and
    $script:State.IntervalFinalRetry -eq $finalRetry) 'cached render failure discarded frozen final state'

Write-Output 'INTERVAL_RECOVERY_TESTS_PASSED'
