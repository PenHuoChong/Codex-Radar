[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-QuotaScope {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('QUOTA SCOPE TEST FAILED: ' + $Message) }
}

function Add-QuotaScopeParameter {
    param([Parameter(Mandatory = $true)]$Command, [Parameter(Mandatory = $true)][string]$Name, $Value)
    [void]$Command.Parameters.AddWithValue($Name, $(if ($null -eq $Value) { [DBNull]::Value } else { $Value }))
}

function Add-QuotaScopeRow {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][Int64]$SourceOffset,
        [Parameter(Mandatory = $true)][string]$PlanType,
        [Parameter(Mandatory = $true)][Int64]$ResetUnixSeconds,
        [Parameter(Mandatory = $true)][double]$UsedPercent,
        [string]$Path = 'synthetic://quota-scope-conflict'
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
INSERT INTO token_records
(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,
 call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,
 source_offset_end,root_session_id,index_revision,model_source,turn_id,request_id,
 response_id,identity_source,service_tier,service_tier_source,
 five_hour_used,five_hour_window,five_hour_resets,plan_type,rate_limit_id,cache_write_observable)
VALUES
('scope-session',@timestamp,'gpt-5.6-sol',0,0,0,0,0,0,0,0,@fingerprint,@path,
 @offset,'scope-session',1,'response','','scope-request','scope-response','request_id',
 'default','response',@used,300,@reset,@plan,'scope-limit',1)
'@
        Add-QuotaScopeParameter $command '@timestamp' $Timestamp
        Add-QuotaScopeParameter $command '@fingerprint' ('scope-' + $SourceOffset.ToString([Globalization.CultureInfo]::InvariantCulture))
        Add-QuotaScopeParameter $command '@path' $Path
        Add-QuotaScopeParameter $command '@offset' $SourceOffset
        Add-QuotaScopeParameter $command '@used' $UsedPercent
        Add-QuotaScopeParameter $command '@reset' $ResetUnixSeconds
        Add-QuotaScopeParameter $command '@plan' $PlanType
        [void]$command.ExecuteNonQuery()
    } finally { $command.Dispose() }
}

function New-QuotaScopeWindow {
    param([double]$UsedPercent, [DateTimeOffset]$ObservedAt, [DateTimeOffset]$ResetsAt, [string]$PlanType, [bool]$Conflict = $false)
    [pscustomobject]@{
        UsedPercent = $UsedPercent
        RemainingPercent = 100.0 - $UsedPercent
        WindowMinutes = 300
        ResetsAt = $ResetsAt
        ResetIdentity = (& $coreModule { param($m, $r) Get-TokenRaderResetIdentity -WindowMinutes $m -ResetsAt $r } 300 $ResetsAt)
        ObservedAt = $ObservedAt
        PlanType = $PlanType
        LimitId = 'scope-limit'
        ScopeConflict = $Conflict
        ConflictDescription = if ($Conflict) { '额度周期存在冲突计划：pro=20%; pro-lite=40%' } else { '' }
        ConflictPlans = if ($Conflict) { @('pro', 'pro-lite') } else { @() }
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $projectRoot 'TokenRader.Core.psm1'
Import-Module $corePath -Force
$coreModule = Get-Module TokenRader.Core
$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
$indexerDll = Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll'
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path $indexerDll }

$db = [System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
$db.Open()
try {
    [TokenRaderIndexer]::CreateSchema($db)
    $path = 'synthetic://quota-scope-conflict'
    $currentReset = [DateTimeOffset]::Parse('2030-04-01T05:00:00Z')
    $oldReset = $currentReset.AddDays(-7)
    Add-QuotaScopeRow $db '2030-04-01T00:00:10Z' 10 'pro-lite' $oldReset.ToUnixTimeSeconds() 80 -Path $path
    Add-QuotaScopeRow $db '2030-04-01T00:01:00Z' 20 'pro' $currentReset.ToUnixTimeSeconds() 20 -Path $path
    Add-QuotaScopeRow $db '2030-04-01T00:02:00Z' 30 'pro-lite' $currentReset.ToUnixTimeSeconds() 40 -Path $path
    Add-QuotaScopeRow $db '2030-04-01T00:03:00Z' 40 'pro' $currentReset.ToUnixTimeSeconds() 21 -Path $path

    $rows = [TokenRaderIndexer]::QueryLatestRateLimitsByOffsets($db, @{ $path = 0L }, @{ $path = 100L })
    Assert-QuotaScope ($rows.Rows.Count -ge 3) 'latest query discarded a same-file plan/reset candidate'
    $converted = & $coreModule { param($table) ConvertFrom-TokenRaderRateLimitRows -Table $table } $rows
    Assert-QuotaScope ($null -ne $converted -and $converted.FiveHour.UsedPercent -eq 21) 'current reset scope did not win over old reset scope'
    Assert-QuotaScope ([bool]$converted.FiveHour.ScopeConflict) 'same-reset competing plans were not marked as a conflict'
    Assert-QuotaScope ([string]$converted.FiveHour.ConflictDescription -match 'pro' -and [string]$converted.FiveHour.ConflictDescription -match 'pro-lite' -and [string]$converted.FiveHour.ConflictDescription -match '%') 'conflict description omitted plan percentages'
    Assert-QuotaScope (@($converted.FiveHour.ScopeCandidates | ForEach-Object { $_.PlanType }) -contains 'pro' -and
        @($converted.FiveHour.ScopeCandidates | ForEach-Object { $_.PlanType }) -contains 'pro-lite') 'conflicting scope candidates were not preserved'
    $oldCycleRows = [TokenRaderIndexer]::QueryLatestRateLimitsByOffsets($db, @{ $path = 0L }, @{ $path = 25L })
    $oldCycleConverted = & $coreModule { param($table) ConvertFrom-TokenRaderRateLimitRows -Table $table } $oldCycleRows
    Assert-QuotaScope ($null -ne $oldCycleConverted -and $oldCycleConverted.FiveHour.UsedPercent -eq 20 -and
        -not [bool]$oldCycleConverted.FiveHour.ScopeConflict) 'different reset cycles were incorrectly treated as a conflict'

    $diagnostic = @{}
    $evidence = & $coreModule {
        param($connection, $endOffsets, $window, $diagnostic)
        Get-TokenRaderQuotaWindowEvidence -StartWindow $null -EndWindow $window -MainLastCountedAt $null `
            -WindowKind FiveHour -RateLimitId 'scope-limit' -Connection $connection -EndOffsets $endOffsets `
            -Thresholds @{} -PricingDocument ([pscustomobject]@{ models = @(); unitTokens = 1000000 }) `
            -CancellationToken ([Threading.CancellationToken]::None) -ProgressState @{} -Cache @{} `
            -DiagnosticState $diagnostic -AccountIdentity 'synthetic'
    } $db @{ $path = 100L } $converted.FiveHour $diagnostic
    Assert-QuotaScope ($null -eq $evidence -and [string]$diagnostic.ReasonCode -eq 'scope_conflict') 'quota evidence did not reject a scope conflict'

    $estimate = Get-TokenRaderQuotaEstimate -StartRateLimits ([pscustomobject]@{ FiveHour = $converted.FiveHour; Weekly = $null; PlanType = 'pro' }) `
        -EndRateLimits ([pscustomobject]@{ FiveHour = $converted.FiveHour; Weekly = $null; PlanType = 'pro' }) `
        -IntervalCost 1 -CostComplete $true
    Assert-QuotaScope ($null -eq $estimate.FiveHour) 'quota estimate accepted a conflict window'
    $weeklyCommand=$db.CreateCommand()
    $weeklyCommand.CommandText='UPDATE token_records SET weekly_used=five_hour_used,weekly_window=10080,weekly_resets=five_hour_resets,five_hour_used=NULL,five_hour_window=NULL,five_hour_resets=NULL'
    [void]$weeklyCommand.ExecuteNonQuery();$weeklyCommand.Dispose()
    $weeklyRows=[TokenRaderIndexer]::QueryLatestRateLimitsByOffsets($db,@{$path=0L},@{$path=100L})
    $weeklyConverted=& $coreModule { param($table) ConvertFrom-TokenRaderRateLimitRows -Table $table } $weeklyRows
    Assert-QuotaScope ($weeklyConverted.Weekly.ScopeConflict -and $null -eq $weeklyConverted.FiveHour) 'weekly-only conflicting plans were not preserved independently'
} finally { $db.Dispose() }

$startAt = [DateTimeOffset]::Parse('2030-04-02T00:00:00Z')
$endAt = $startAt.AddMinutes(1)
$resetAt = $startAt.AddHours(5)
$cleanStart = New-QuotaScopeWindow 10 $startAt $resetAt 'pro'
$cleanEnd = New-QuotaScopeWindow 12 $endAt $resetAt 'pro'
$cleanStartRate = [pscustomobject]@{ FiveHour = $cleanStart; Weekly = $null; PlanType = 'pro' }
$cleanEndRate = [pscustomobject]@{ FiveHour = $cleanEnd; Weekly = $null; PlanType = 'pro' }
$cleanEvidence = [pscustomobject]@{
    BoundaryValid = $true; AttributionComplete = $true; PricingComplete = $true
    QuotaEvidenceComplete = $true; EstimateSource = 'snapshot_delta_usd_estimate'
    CapacitySource = 'synthetic'
    EstimatedTotalUsd = 50.0; EstimatedUsedUsd = 6.0; EstimatedRemainingUsd = 44.0
    TotalCost = 1.0; EffectiveDeltaPercent = 2.0; EndObservedAt = $endAt
    CurrentObservedAt = $endAt; StartObservedAt = $startAt; WindowMinutes = 300
    ResetIdentity = $cleanEnd.ResetIdentity; PlanType = 'pro'; LimitId = 'scope-limit'
}
$cleanEstimate = Get-TokenRaderQuotaEstimate -StartRateLimits $cleanStartRate -EndRateLimits $cleanEndRate `
    -IntervalCost 1 -CostComplete $true -QuotaEvidence ([pscustomobject]@{ FiveHour = $cleanEvidence; Weekly = $null })
Assert-QuotaScope ($cleanEstimate.FiveHour.CalibrationStartObservedAt -eq $startAt -and
    $cleanEstimate.FiveHour.CalibrationEndObservedAt -eq $endAt) 'calibration endpoint timestamps were not returned'

Write-Output 'QUOTA_SCOPE_CONFLICT_TESTS_PASSED'
