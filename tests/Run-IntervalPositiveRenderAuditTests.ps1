[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-Audit([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('INTERVAL POSITIVE RENDER AUDIT FAILED: ' + $Message) }
}
$source = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'TokenRader.ps1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-Audit (@($errors).Count -eq 0) 'production parse'
foreach ($name in @('Complete-TokenRaderMeasurementBaseline', 'Update-IntervalView',
    'Start-TokenRaderIntervalComputeAsync', 'Complete-TokenRaderIntervalCompute',
    'Show-IntervalResult', 'New-TokenRaderRequestId', 'ConvertTo-TokenRaderOffsetHashtable')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Assert-Audit ($null -ne $node) ('missing function ' + $name)
    Invoke-Expression $node.Extent.Text
}
# All external seams are synthetic. No session/private/auth data, DLL builds,
# application startup, network calls or database reads are involved.
$script:Paths = [pscustomobject]@{ PricingPath = 'synthetic'; SessionsRoot = 'synthetic' }
$script:IntervalComputeScript = { }
$script:WindowClosing = $false
function Join-Path { param($Path, $ChildPath); return 'synthetic-module' }
function Set-TokenRaderUiState {
    param($NewState, $StatusMessage); $script:State.UiState = $NewState
    if ($NewState -eq 'ComputingFinal') { Invoke-AuditSeam 'QueuedState' }
}
function Retain-TokenRaderQuotaEstimatesForCurrentWindow { param($RateLimits, $AccountIdentity); Invoke-AuditSeam 'Retain' }
function Mark-TokenRaderQuotaEstimatesRetainedAfterFailure { $script:State.RetainedAfterFailure = $true; Invoke-AuditSeam 'Mark' }
function Show-EmptyIntervalMeasurement { param($Baseline); $script:UsdCostText.Text = '0' }
function Set-TokenRaderLastFailureInfo { param($Message); $script:State.LastFailureInfo = $Message; Invoke-AuditSeam 'LastFailure' }
function Start-TokenRaderUsageHistoryRefresh { param([switch]$PurgeExpired) }
function Start-TokenRaderBackgroundJob {
    param($ScriptBlock, $Parameters, $Kind, $Generation, $RequestId, $CompletionHandler, $FailureHandler,
        $CallbackContext, $TimeoutSeconds, $SoftWarningSeconds, $ProgressState, $CancellationSource, $StopCompletionHandler)
    $CancellationSource.Dispose()
    if ($RequestId -eq $script:QueuedRequestId -and $script:QueuedLaunchMode -eq 'ThrowBefore') { throw [InvalidOperationException]::new('synthetic-private-launch-body') }
    if ($RequestId -eq $script:QueuedRequestId -and $script:QueuedLaunchMode -eq 'NoWorker') { return $false }
    $script:Launch = [pscustomobject]@{ Parameters = $Parameters; Generation = $Generation; RequestId = $RequestId; Context = $CallbackContext }
    $script:State.BackgroundJobs[$RequestId] = [pscustomobject]@{ Kind = $Kind; RequestId = $RequestId }
    if ($RequestId -eq $script:QueuedRequestId -and $script:QueuedLaunchMode -eq 'ThrowAfter') { throw [InvalidOperationException]::new('synthetic-private-launch-body') }
    return $true
}
function Invoke-AuditSeam([string]$Name) {
    if ($script:Reenter -eq $Name) {
        $script:State.MeasurementGeneration = 8L; $script:State.IntervalComputeRequestId = 999L
        $script:State.UiState = 'Starting'; $script:State.IsMeasuring = $false
        $script:State.IntervalResult = $script:NewerResult; $script:State.IntervalCache = $script:NewerCache
        $script:State.QuotaEstimates = $script:NewerQuota; $script:State.WeeklyReferenceEstimate = $script:NewerWeekly
        $script:State.IntervalComputePending = $true; $script:State.IntervalComputePendingRequest = $script:NewerPending
        $script:State.LastFailureInfo = 'newer-failure'; $script:StatusText.Text = 'newer-status'
    }
    if ($script:AccountSwitch -eq $Name) {
        $script:State.AccountIdentity = 'new-account'; $script:State.QuotaEstimates = $script:NewerQuota
        $script:State.WeeklyReferenceEstimate = $script:NewerWeekly
    }
    if (@($script:Fault) -contains $Name) { throw [InvalidOperationException]::new('synthetic-private-body') }
}
function Merge-LatestRateLimits { param($Candidate); $script:MergeCalls++; Invoke-AuditSeam 'Merge' }
function Update-QuotaEstimatesFromInterval {
    param($Result, $Final); $script:QuotaCalls++
    if ($script:CommitQuota) { $script:State.QuotaEstimates = $script:NewerQuota; $script:State.QuotaEstimateAccountIdentity = ''; Invoke-AuditSeam 'Cards' }
    if (@($script:Fault) -contains 'Quota') { $script:State.QuotaEstimates = $null; $script:State.QuotaEstimateAccountIdentity = ''; $script:State.QuotaDiagnostics = $null }
    Invoke-AuditSeam 'Quota'
}
function Update-TokenRaderWeeklyReferenceFromResult {
    param($Result); $script:WeeklyCalls++
    if (@($script:Fault) -contains 'Weekly') { $script:State.WeeklyReferenceEstimate = $null }
    Invoke-AuditSeam 'Weekly'
}
function Update-QuotaCards { Invoke-AuditSeam 'Cards' }
function Set-UsageMetrics { param($Usage, $Model) }
function Set-ResultPricing { param($Result) }
function Format-IntervalDuration { param($Duration); return '1 min' }
function Format-TokenRaderUsd { param([double]$Value); return ('$' + $Value.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture)) }
function Get-ResultServiceTierSummary { param($Result); return 'synthetic' }
foreach ($name in @('SelectedSessionText','ScopeBadgeText','UpdatedText','IntervalTimeText','UsdCostText',
    'CostBreakdownText','LongContextText','FormulaText','CaveatText','StatusText')) {
    Set-Variable -Scope Script -Name $name -Value ([pscustomobject]@{ Text = '' })
}
$baseline = [pscustomobject]@{ StartedAt = [DateTimeOffset]::Now.AddMinutes(-2); StartOffsets = @{ synthetic = 10L }; StartRateLimits = $null }
$result = [pscustomobject]@{
    StartedAt = $baseline.StartedAt; EndedAt = [DateTimeOffset]::Now
    Usage = @{}; ModelDisplay = 'synthetic'; TotalCost = 0.125; InputCost = 0.1; CachedCost = 0.005; OutputCost = 0.02
    CostComplete = $true; ChangedSessions = 1; RawEvents = 1L; CountedEvents = 1L
    DuplicateEventsDropped = 0L; InheritedEventsDropped = 0L; EndRateLimits = $null
    Signature = 'synthetic'; ChangeRevision = 1L; BaselineSnapshots = @{}
}
function Reset-Audit {
    $script:Fault = ''
    $script:CommitQuota = $false
    $script:QueuedRequestId = 202L; $script:QueuedLaunchMode = ''
    $script:Reenter = ''; $script:AccountSwitch = ''
    $script:MergeCalls = 0; $script:QuotaCalls = 0; $script:WeeklyCalls = 0
    $script:Launch = $null
    $script:PriorQuota = [pscustomobject]@{ FiveHour = [pscustomobject]@{ TotalUsd = 100.0 }; Weekly = [pscustomobject]@{ TotalUsd = 200.0 } }
    $script:PriorWeekly = [pscustomobject]@{ TotalUsd = 300.0 }
    $script:NewerResult = [pscustomobject]@{ Marker = 'newer-result' }; $script:NewerCache = [pscustomobject]@{ Marker = 'newer-cache' }
    $script:NewerQuota = [pscustomobject]@{ Marker = 'newer-quota' }; $script:NewerWeekly = [pscustomobject]@{ Marker = 'newer-weekly' }
    $script:NewerPending = [pscustomobject]@{ Marker = 'newer-pending' }
    $script:State = @{
        MeasurementGeneration = 7L; RequestSequence = 100L; BaselineRequestId = 11L; UiState = 'Starting'
        IntervalComputing = $false; IntervalComputePending = $false; IntervalComputePendingRequest = $null
        IntervalComputeStopping = $false; IntervalActiveScanRateLimits = $false; IntervalComputeRequestId = 0L
        IntervalResult = $null; IntervalCache = $null; ManualServiceTiers = @{}; BackgroundJobs = @{}
        AccountIdentity = ''; IntervalLastError = ''; LastFailureInfo = ''
        QuotaEstimates = $script:PriorQuota; QuotaEstimateAccountIdentity = ''; QuotaDiagnostics = [pscustomobject]@{ Marker = 'prior-diagnostic' }
        QuotaCalibrationMessage = 'prior-calibration'; WeeklyReferenceEstimate = $script:PriorWeekly
        RetainedAfterFailure = $false
    }
    Complete-TokenRaderMeasurementBaseline -Baseline $baseline -Generation 7L -RequestId 11L
    Assert-Audit ($State.UiState -eq 'Measuring' -and $State.IsMeasuring -and $State.BaselineRequestId -eq 0L) 'start handoff'
    Update-IntervalView -Manual
    Assert-Audit ($null -ne $script:Launch -and $State.IntervalComputing -and $State.IntervalComputeRequestId -eq $script:Launch.RequestId) 'manual View schedules request'
    Assert-Audit ($script:Launch.Parameters.ScanRateLimits -and [object]::ReferenceEquals($script:Launch.Parameters.Baseline, $baseline)) 'correct baseline and quota-aware query'
    # Start resets the independent reference; install a previous successful
    # update only after preparation has completed.
    $script:State.WeeklyReferenceEstimate = $script:PriorWeekly
    $script:MergeCalls = 0; $script:QuotaCalls = 0; $script:WeeklyCalls = 0
}
foreach ($final in @($false, $true)) {
foreach ($fault in @('', 'Merge', 'Quota', 'Weekly', 'Cards', 'Retain', 'Mark')) {
    Reset-Audit
    $script:Fault = $fault
    # Trigger Retain/Mark recovery with a primary merge failure as well.
    if ($fault -in @('Retain','Mark')) { $script:Fault = @('Merge', $fault) }
    $frozenEnd = [pscustomobject]@{ EndOffsets = @{ synthetic = 99L }; EndRevision = 4L; EndedAt = $result.EndedAt }
    $State.IntervalEnd = $frozenEnd
    if ($final) { $State.UiState = 'ComputingFinal'; $State.IsMeasuring = $false }
    Complete-TokenRaderIntervalCompute -BaselineStartedAt $baseline.StartedAt -Payload ([pscustomobject]@{ Result = $result }) -Generation 7L -RequestId $script:Launch.RequestId -Final $final
    Assert-Audit ($State.UiState -eq $(if ($final) { 'Ready' } else { 'Measuring' }) -and $State.IsMeasuring -eq (-not $final) -and -not $State.IntervalComputing -and $State.IntervalComputeRequestId -eq 0L) 'callback unlocks and retains measurement state'
    Assert-Audit ([object]::ReferenceEquals($State.IntervalResult, $result)) 'positive result accepted'
    Assert-Audit ($script:UsdCostText.Text -eq '$0.125000') ('first callback displays positive dollars: ' + $fault)
    Assert-Audit ([object]::ReferenceEquals($State.IntervalCache.Result, $result) -and [object]::ReferenceEquals($State.IntervalEnd, $frozenEnd)) 'cache and frozen end retained'
    if ($fault) {
        Assert-Audit ($State.LastFailureInfo.Contains('InvalidOperationException') -and -not $State.LastFailureInfo.Contains('synthetic-private-body')) 'safe copyable failure type'
        Assert-Audit ([object]::ReferenceEquals($State.QuotaEstimates, $script:PriorQuota) -and [object]::ReferenceEquals($State.WeeklyReferenceEstimate, $script:PriorWeekly)) 'auxiliary failures preserve prior amounts'
    }
}
}
foreach ($seam in @('Merge','Quota','Weekly','Retain','Mark','Cards','LastFailure')) {
    Reset-Audit; $script:Reenter = $seam
    if ($seam -in @('Retain','Mark','LastFailure')) { $script:Fault = 'Merge' }
    Complete-TokenRaderIntervalCompute -BaselineStartedAt $baseline.StartedAt -Payload ([pscustomobject]@{ Result = $result }) -Generation 7L -RequestId $script:Launch.RequestId
    Assert-Audit ($State.MeasurementGeneration -eq 8L -and $State.IntervalComputeRequestId -eq 999L -and $State.UiState -eq 'Starting') ('reentrant request retained: ' + $seam)
    Assert-Audit ([object]::ReferenceEquals($State.IntervalResult, $script:NewerResult) -and [object]::ReferenceEquals($State.IntervalCache, $script:NewerCache)) ('newer result retained: ' + $seam)
    Assert-Audit ($State.LastFailureInfo -eq 'newer-failure' -and $script:StatusText.Text -eq 'newer-status') ('newer diagnostics retained: ' + $seam)
}
foreach ($seam in @('Merge','Quota','Weekly')) {
    Reset-Audit; $script:AccountSwitch = $seam; $script:Fault = $seam
    Complete-TokenRaderIntervalCompute -BaselineStartedAt $baseline.StartedAt -Payload ([pscustomobject]@{ Result = $result }) -Generation 7L -RequestId $script:Launch.RequestId
    Assert-Audit ([object]::ReferenceEquals($State.QuotaEstimates, $script:NewerQuota) -and [object]::ReferenceEquals($State.WeeklyReferenceEstimate, $script:NewerWeekly)) ('account switch does not restore old amounts: ' + $seam)
}
foreach ($stale in @('Generation','Request','Baseline')) {
    Reset-Audit
    $g = 7L; $r = $script:Launch.RequestId; $at = $baseline.StartedAt
    if ($stale -eq 'Generation') { $g = 6L }
    if ($stale -eq 'Request') { $r-- }
    if ($stale -eq 'Baseline') { $at = $at.AddSeconds(-1) }
    Complete-TokenRaderIntervalCompute -BaselineStartedAt $at -Payload ([pscustomobject]@{ Result = $result }) -Generation $g -RequestId $r
    Assert-Audit ($null -eq $State.IntervalResult -and $script:UsdCostText.Text -eq '0' -and $State.IntervalComputing) ('stale callback rejected: ' + $stale)
}
Reset-Audit
$foreignResult = $result.PSObject.Copy(); Add-Member -InputObject $foreignResult -NotePropertyName AccountIdentity -NotePropertyValue 'foreign-account'
Complete-TokenRaderIntervalCompute -BaselineStartedAt $baseline.StartedAt -Payload ([pscustomobject]@{ Result = $foreignResult }) -Generation 7L -RequestId $script:Launch.RequestId
Assert-Audit ($script:MergeCalls -eq 0 -and $script:QuotaCalls -eq 0 -and $script:WeeklyCalls -eq 0) 'foreign account cannot mutate quota evidence'
Reset-Audit; $script:CommitQuota = $true; $script:Fault = 'Cards'
Complete-TokenRaderIntervalCompute -BaselineStartedAt $baseline.StartedAt -Payload ([pscustomobject]@{ Result = $result }) -Generation 7L -RequestId $script:Launch.RequestId
Assert-Audit ([object]::ReferenceEquals($State.QuotaEstimates, $script:NewerQuota) -and $script:UsdCostText.Text -eq '$0.125000') 'card-render failure does not roll back an already committed quota or hide main cost'
Reset-Audit; $script:Fault = 'Quota'
$newBasisResult = $result.PSObject.Copy(); Add-Member -InputObject $newBasisResult -NotePropertyName QuotaPricingBasis -NotePropertyValue 'plan_standard_api_reference'
Complete-TokenRaderIntervalCompute -BaselineStartedAt $baseline.StartedAt -Payload ([pscustomobject]@{ Result = $newBasisResult }) -Generation 7L -RequestId $script:Launch.RequestId
Assert-Audit ($null -eq $State.QuotaEstimates.FiveHour -and $null -eq $State.QuotaEstimates.Weekly -and $script:UsdCostText.Text -eq '$0.125000') 'failed update cannot restore dollars from a different pricing basis'
foreach ($mode in @('', 'ThrowBefore', 'NoWorker', 'ThrowAfter')) {
    Reset-Audit; $script:Fault = 'QueuedState'; $script:QueuedLaunchMode = $mode
    $previewId = $script:Launch.RequestId
    [void]$State.BackgroundJobs.Remove($previewId)
    $queued = [pscustomobject]@{
        Generation = 7L; RequestId = $script:QueuedRequestId; BaselineStartedAt = $baseline.StartedAt
        EndOffsets = @{ synthetic = 99L }; EndRevision = 4L; EndedAt = $result.EndedAt
        Final = $true; ScanRateLimits = $true
    }
    $State.IntervalComputePending = $true; $State.IntervalComputePendingRequest = $queued
    $State.UiState = 'ComputingFinal'; $State.IsMeasuring = $false
    $State.IntervalEnd = [pscustomobject]@{ EndOffsets = $queued.EndOffsets; EndRevision = $queued.EndRevision; EndedAt = $queued.EndedAt }
    Complete-TokenRaderIntervalCompute -BaselineStartedAt $baseline.StartedAt -Payload ([pscustomobject]@{ Result = $result }) -Generation 7L -RequestId $previewId
    Assert-Audit (-not $State.IntervalComputePending -and $null -eq $State.IntervalComputePendingRequest) ('queued request consumed only into worker or frozen retry: ' + $mode)
    if ($mode -in @('', 'ThrowAfter')) {
        Assert-Audit ($State.UiState -eq 'ComputingFinal' -and $State.IntervalComputing -and $State.IntervalComputeRequestId -eq $script:QueuedRequestId -and $State.BackgroundJobs.ContainsKey($script:QueuedRequestId)) 'redraw failure still launches queued final worker'
        Assert-Audit ($script:Launch.Parameters.EndOffsets.synthetic -eq 99L -and $script:Launch.Parameters.EndRevision -eq 4L -and $script:Launch.Parameters.EndedAt -eq $queued.EndedAt) 'queued final launches exact frozen boundaries'
    } else {
        Assert-Audit ($State.UiState -eq 'Ready' -and -not $State.IntervalComputing -and $State.IntervalComputeRequestId -eq 0L -and [object]::ReferenceEquals($State.IntervalFinalRetry, $queued)) 'failed queued launch becomes Ready with exact frozen retry'
        $script:Fault = ''; $script:QueuedLaunchMode = ''
        Update-IntervalView -Manual
        Assert-Audit ($State.IntervalComputing -and $script:Launch.Parameters.EndOffsets.synthetic -eq 99L -and $script:Launch.Parameters.EndRevision -eq 4L) 'manual retry after queued launch failure uses frozen boundaries'
    }
    Assert-Audit (-not $State.LastFailureInfo.Contains('synthetic-private-launch-body') -and -not $State.LastFailureInfo.Contains('synthetic-private-body')) 'queued failure diagnostic contains no exception body'
}
Reset-Audit; $script:Reenter = 'QueuedState'
$previewId = $script:Launch.RequestId; [void]$State.BackgroundJobs.Remove($previewId)
$State.IntervalComputePending = $true; $State.IntervalComputePendingRequest = [pscustomobject]@{
    Generation = 7L; RequestId = $script:QueuedRequestId; BaselineStartedAt = $baseline.StartedAt
    EndOffsets = @{ synthetic = 99L }; EndRevision = 4L; EndedAt = $result.EndedAt; Final = $true; ScanRateLimits = $true
}
$State.UiState = 'ComputingFinal'; $State.IsMeasuring = $false
Complete-TokenRaderIntervalCompute -BaselineStartedAt $baseline.StartedAt -Payload ([pscustomobject]@{ Result = $result }) -Generation 7L -RequestId $previewId
Assert-Audit ($State.MeasurementGeneration -eq 8L -and $State.IntervalComputeRequestId -eq 999L -and [object]::ReferenceEquals($State.IntervalComputePendingRequest, $script:NewerPending) -and $State.LastFailureInfo -eq 'newer-failure') 'queued redraw reentry preserves newer task and pending request'
Write-Host 'PASS Interval positive render: normal and auxiliary-failure callbacks display cost immediately; frozen boundaries, retained amounts, safe diagnostics, stale ownership and account reentry are protected.'
