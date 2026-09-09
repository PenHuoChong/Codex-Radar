[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-QuotaCycle {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw ('QUOTA CYCLE TEST FAILED: ' + $Message) }
}

function Assert-QuotaCycleEqual {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([string]$Expected -ne [string]$Actual) {
        throw ('QUOTA CYCLE TEST FAILED: {0}; expected=[{1}] actual=[{2}]' -f $Message, $Expected, $Actual)
    }
}

function Add-QuotaCycleParameter {
    param(
        [Parameter(Mandatory = $true)]$Command,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    $parameterValue = if ($null -eq $Value) { [DBNull]::Value } else { $Value }
    [void]$Command.Parameters.AddWithValue($Name, $parameterValue)
}

function Add-QuotaCycleRow {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][Int64]$SourceOffset,
        [string]$RequestId = '',
        [string]$ResponseId = '',
        [string]$IdentitySource = 'request_id',
        [string]$Model = 'gpt-5.6-sol',
        [Int64]$TotalInput = 100,
        [Int64]$CallInput = 100,
        [Int64]$TotalOutput = 10,
        [Int64]$CallOutput = 10,
        [string]$Fingerprint = '',
        [string]$RootSessionId = '',
        [string]$PlanType = '',
        [string]$RateLimitId = '',
        [object]$FiveHourUsed = $null,
        [object]$FiveHourWindow = $null,
        [object]$FiveHourReset = $null,
        [object]$WeeklyUsed = $null,
        [object]$WeeklyWindow = $null,
        [object]$WeeklyReset = $null,
        [string]$ServiceTier = 'default',
        [string]$ServiceTierSource = 'response',
        [string]$TurnId = '',
        [string]$ModelSource = 'response'
    )
    if ([string]::IsNullOrWhiteSpace($Fingerprint)) {
        $Fingerprint = '{0}:{1}:{2}:{3}:{4}' -f $TotalInput, $CallInput, $TotalOutput, $CallOutput, $RequestId
    }
    if ([string]::IsNullOrWhiteSpace($RootSessionId)) { $RootSessionId = $SessionId }

    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
INSERT INTO token_records
(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,
 call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,
 source_offset_end,root_session_id,index_revision,model_source,turn_id,request_id,
 response_id,identity_source,service_tier,service_tier_source,
 five_hour_used,five_hour_window,five_hour_resets,weekly_used,weekly_window,
 weekly_resets,plan_type,rate_limit_id,cache_write_observable)
VALUES
(@session,@timestamp,@model,@total_input,0,@total_output,0,
 @call_input,0,@call_output,0,@fingerprint,@source_path,
 @source_offset,@root_session,1,@model_source,@turn_id,@request,
 @response,@identity,@tier,@tier_source,
 @fh_used,@fh_window,@fh_reset,@weekly_used,@weekly_window,
 @weekly_reset,@plan,@limit,1)
'@
        Add-QuotaCycleParameter $command '@session' $SessionId
        Add-QuotaCycleParameter $command '@timestamp' $Timestamp
        Add-QuotaCycleParameter $command '@model' $Model
        Add-QuotaCycleParameter $command '@total_input' $TotalInput
        Add-QuotaCycleParameter $command '@total_output' $TotalOutput
        Add-QuotaCycleParameter $command '@call_input' $CallInput
        Add-QuotaCycleParameter $command '@call_output' $CallOutput
        Add-QuotaCycleParameter $command '@fingerprint' $Fingerprint
        Add-QuotaCycleParameter $command '@source_path' $SourcePath
        Add-QuotaCycleParameter $command '@source_offset' $SourceOffset
        Add-QuotaCycleParameter $command '@root_session' $RootSessionId
        Add-QuotaCycleParameter $command '@model_source' $ModelSource
        Add-QuotaCycleParameter $command '@turn_id' $TurnId
        Add-QuotaCycleParameter $command '@request' $RequestId
        Add-QuotaCycleParameter $command '@response' $ResponseId
        Add-QuotaCycleParameter $command '@identity' $IdentitySource
        Add-QuotaCycleParameter $command '@tier' $ServiceTier
        Add-QuotaCycleParameter $command '@tier_source' $ServiceTierSource
        Add-QuotaCycleParameter $command '@fh_used' $FiveHourUsed
        Add-QuotaCycleParameter $command '@fh_window' $FiveHourWindow
        Add-QuotaCycleParameter $command '@fh_reset' $FiveHourReset
        Add-QuotaCycleParameter $command '@weekly_used' $WeeklyUsed
        Add-QuotaCycleParameter $command '@weekly_window' $WeeklyWindow
        Add-QuotaCycleParameter $command '@weekly_reset' $WeeklyReset
        Add-QuotaCycleParameter $command '@plan' $PlanType
        Add-QuotaCycleParameter $command '@limit' $RateLimitId
        [void]$command.ExecuteNonQuery()
    } finally {
        $command.Dispose()
    }
}

function Add-QuotaCycleRelationship {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$ParentSessionId = '',
        [string]$RootSessionId = ''
    )
    if ([string]::IsNullOrWhiteSpace($RootSessionId)) { $RootSessionId = $SessionId }
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
INSERT OR REPLACE INTO file_metadata
(path,length,last_write_ticks,parsed_offset,session_id,cwd,parent_thread_id,
 forked_from_id,content_retained,root_session_id)
VALUES (@path,100,0,100,@session,'',@parent,@parent,1,@root)
'@
        Add-QuotaCycleParameter $command '@path' $Path
        Add-QuotaCycleParameter $command '@session' $SessionId
        Add-QuotaCycleParameter $command '@parent' $ParentSessionId
        Add-QuotaCycleParameter $command '@root' $RootSessionId
        [void]$command.ExecuteNonQuery()
    } finally {
        $command.Dispose()
    }
}

function New-QuotaCycleDb {
    $connection = [System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $connection.Open()
    [TokenRaderIndexer]::CreateSchema($connection)
    return $connection
}

function New-QuotaCycleWindow {
    param(
        [Parameter(Mandatory = $true)][double]$UsedPercent,
        [Parameter(Mandatory = $true)][string]$ObservedAt,
        [Parameter(Mandatory = $true)][Int64]$ResetUnixSeconds,
        [string]$PlanType = 'team',
        [string]$LimitId = 'quota-synthetic',
        [int]$WindowMinutes = 300
    )
    $observed = [DateTimeOffset]::Parse($ObservedAt)
    [pscustomobject]@{
        UsedPercent = $UsedPercent
        RemainingPercent = 100.0 - $UsedPercent
        WindowMinutes = $WindowMinutes
        ResetsAt = [DateTimeOffset]::FromUnixTimeSeconds($ResetUnixSeconds)
        ObservedAt = $observed
        PlanType = $PlanType
        LimitId = $LimitId
        ResetIdentity = (& $coreModule { param($m,$r) Get-TokenRaderResetIdentity -WindowMinutes $m -ResetsAt $r } $WindowMinutes ([DateTimeOffset]::FromUnixTimeSeconds($ResetUnixSeconds)))
    }
}

function New-QuotaCyclePricing {
    $path = Join-Path $projectRoot 'pricing.json'
    return Get-TokenRaderPrices -PricingPath $path
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
$coreModule = Get-Module TokenRader.Core
$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
$indexerDll = Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll'
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path $indexerDll }

$none = [Threading.CancellationToken]::None
$thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
$thresholds['gpt-5.6-sol'] = 272000L
$pricing = New-QuotaCyclePricing
$reset = 1900000000L

# The main measurement may begin in a pro cycle while the latest completed
# calibration step belongs to the current team cycle. The old StartWindow
# plan veto must not hide this independent step.
$db = New-QuotaCycleDb
try {
    $path = 'synthetic://quota-pro-team'
    $startAt = [DateTimeOffset]::Parse('2030-03-01T00:00:00Z')
    $stepStart = [DateTimeOffset]::Parse('2030-03-01T00:10:00Z')
    $stepEnd = [DateTimeOffset]::Parse('2030-03-01T00:10:20Z')
    Add-QuotaCycleRow $db 'team-session' $stepStart.ToString('o') $path 10 'team-snapshot-20' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 20 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    Add-QuotaCycleRow $db 'team-session' $stepEnd.ToString('o') $path 20 'team-snapshot-21' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 21 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    Add-QuotaCycleRow $db 'team-session' ([DateTimeOffset]::Parse('2030-03-01T00:10:10Z')).ToString('o') $path 15 'team-call' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 20 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 1000 -CallInput 1000 -TotalOutput 100 -CallOutput 100
    $ends = @{ $path = 100L }
    $diagnostic = @{}
    $evidence = & $coreModule {
        param($start, $end, $connection, $offsets, $thresholds, $prices, $diag)
        Get-TokenRaderQuotaWindowEvidence -StartWindow $start -EndWindow $end -MainLastCountedAt $null -WindowKind FiveHour -RateLimitId 'quota-synthetic' -Connection $connection -EndOffsets $offsets -Thresholds $thresholds -PricingDocument $prices -CancellationToken ([Threading.CancellationToken]::None) -ProgressState @{} -Cache @{} -DiagnosticState $diag -AccountIdentity 'synthetic-account'
    } (New-QuotaCycleWindow 20 '2030-03-01T00:11:00Z' $reset 'pro') (New-QuotaCycleWindow 21 '2030-03-01T00:10:20Z' $reset 'team') $db $ends $thresholds $pricing $diagnostic
    Assert-QuotaCycle ($null -ne $evidence) 'pro-to-team independent calibration step was rejected'
    Assert-QuotaCycleEqual 20 $evidence.StartUsedPercent 'pro-to-team selected the latest completed start percentage'
    Assert-QuotaCycleEqual 21 $evidence.CalibrationEndUsedPercent 'pro-to-team selected the current completed end percentage'
    Assert-QuotaCycle ([bool]$evidence.HistoryLookbackApplied) 'old measurement boundary was not reported as a lookback'
    Assert-QuotaCycleEqual 'updated' $diagnostic.Status 'successful independent step did not update diagnostics'
    Assert-QuotaCycleEqual 'team' $diagnostic.PlanType 'diagnostics retained the current plan'
} finally {
    $db.Dispose()
}

# A concurrent row from the old plan belongs to a different quota scope even
# when its timestamp and reset overlap the current plan. It is excluded from
# the token interval and reported for diagnostics.
$db = New-QuotaCycleDb
try {
    $path = 'synthetic://quota-plan-scope'
    $stepStart = [DateTimeOffset]::Parse('2030-03-02T00:10:00Z')
    $stepEnd = [DateTimeOffset]::Parse('2030-03-02T00:10:20Z')
    Add-QuotaCycleRow $db 'team-session' $stepStart.ToString('o') $path 10 'team-snapshot-40' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 40 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    Add-QuotaCycleRow $db 'team-session' $stepEnd.ToString('o') $path 20 'team-snapshot-41' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 41 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    Add-QuotaCycleRow $db 'team-session' ([DateTimeOffset]::Parse('2030-03-02T00:10:10Z')).ToString('o') $path 15 'team-call' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 40 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 1000 -CallInput 1000 -TotalOutput 100 -CallOutput 100
    Add-QuotaCycleRow $db 'old-session' ([DateTimeOffset]::Parse('2030-03-02T00:10:15Z')).ToString('o') $path 18 'old-plan-call' -PlanType 'pro' -RateLimitId 'quota-synthetic' -FiveHourUsed 40 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 900 -CallInput 900 -TotalOutput 90 -CallOutput 90
    $aggregate = [TokenRaderIndexer]::AggregateQuotaTimeRangeRecordsAtOffsets(
        $db, @{ $path = 100L }, $stepStart, $stepEnd, $thresholds, $none, @{}, 'FiveHour', 300, $reset, 'team', 'quota-synthetic')
    Assert-QuotaCycle ($aggregate.CountedEvents -eq 1) 'current-plan scope counted a concurrent old-plan call'
    Assert-QuotaCycle ($aggregate.TotalInput -eq 1000) 'old-plan input leaked into current-plan calibration'
    Assert-QuotaCycle ($aggregate.ExcludedCycleEvents -ge 1) 'old-plan exclusion was not diagnosed'
} finally {
    $db.Dispose()
}

# Quota metadata may be inherited from a prior row in the same session, but a
# different session must not donate its plan/reset to the missing row.
$db = New-QuotaCycleDb
try {
    $path = 'synthetic://quota-own-session'
    $stepStart = [DateTimeOffset]::Parse('2030-03-03T00:10:00Z')
    $stepEnd = [DateTimeOffset]::Parse('2030-03-03T00:10:30Z')
    Add-QuotaCycleRow $db 'owner-session' $stepStart.ToString('o') $path 10 'owner-prior' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 50 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    Add-QuotaCycleRow $db 'owner-session' ([DateTimeOffset]::Parse('2030-03-03T00:10:10Z')).ToString('o') $path 20 'owner-inherited' -PlanType '' -RateLimitId '' -FiveHourUsed $null -FiveHourWindow $null -FiveHourReset $null -ServiceTier 'default' -TotalInput 700 -CallInput 700 -TotalOutput 70 -CallOutput 70
    $aggregate = [TokenRaderIndexer]::AggregateQuotaTimeRangeRecordsAtOffsets(
        $db, @{ $path = 100L }, $stepStart, $stepEnd, $thresholds, $none, @{}, 'FiveHour', 300, $reset, 'team', 'quota-synthetic')
    Assert-QuotaCycle ($aggregate.AttributionComplete) 'same-session prior quota metadata was not inherited'
    Assert-QuotaCycle ($aggregate.CountedEvents -eq 1 -and $aggregate.TotalInput -eq 700) 'inherited same-session call was not counted'
    Assert-QuotaCycle ($aggregate.UnattributedEvents -eq 0) 'same-session inheritance was marked as unknown attribution'
} finally {
    $db.Dispose()
}

# A row with no attributable quota metadata must reject the entire calibration
# result. It must never silently become a zero-cost or guessed estimate.
$db = New-QuotaCycleDb
try {
    $snapshotPath = 'synthetic://quota-known-snapshots'
    $unknownPath = 'synthetic://quota-unknown-attribution'
    $stepStart = [DateTimeOffset]::Parse('2030-03-04T00:10:00Z')
    $stepEnd = [DateTimeOffset]::Parse('2030-03-04T00:10:20Z')
    Add-QuotaCycleRow $db 'known-session' $stepStart.ToString('o') $snapshotPath 10 'known-snapshot-60' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 60 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    Add-QuotaCycleRow $db 'known-session' $stepEnd.ToString('o') $snapshotPath 20 'known-snapshot-61' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 61 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    Add-QuotaCycleRow $db 'unknown-session' ([DateTimeOffset]::Parse('2030-03-04T00:10:10Z')).ToString('o') $unknownPath 10 'unknown-call' -PlanType '' -RateLimitId '' -FiveHourUsed $null -FiveHourWindow $null -FiveHourReset $null -TotalInput 800 -CallInput 800 -TotalOutput 80 -CallOutput 80
    $ends = @{ $snapshotPath = 100L; $unknownPath = 100L }
    $diagnostic = @{}
    $evidence = & $coreModule {
        param($end, $connection, $offsets, $thresholds, $prices, $diag)
        Get-TokenRaderQuotaWindowEvidence -StartWindow $null -EndWindow $end -MainLastCountedAt $null -WindowKind FiveHour -RateLimitId 'quota-synthetic' -Connection $connection -EndOffsets $offsets -Thresholds $thresholds -PricingDocument $prices -CancellationToken ([Threading.CancellationToken]::None) -ProgressState @{} -Cache @{} -DiagnosticState $diag -AccountIdentity 'synthetic-account'
    } (New-QuotaCycleWindow 61 '2030-03-04T00:10:20Z' $reset 'team') $db $ends $thresholds $pricing $diagnostic
    Assert-QuotaCycle ($null -eq $evidence) 'unknown attribution produced a quota estimate'
    Assert-QuotaCycleEqual 'unknown_attribution' $diagnostic.ReasonCode 'unknown attribution did not explain rejection'
    Assert-QuotaCycle ([int64]$diagnostic.UnattributedEvents -ge 1) 'unknown attribution count was not retained in diagnostics'
} finally {
    $db.Dispose()
}

# Canonicalize parent/child lineage before applying the quota scope. The child
# has the current plan, but its canonical parent is an old-plan copy; counting
# the child would bill a copied event that is outside the current cycle.
$db = New-QuotaCycleDb
try {
    $parentPath = 'synthetic://quota-parent'
    $childPath = 'synthetic://quota-child'
    Add-QuotaCycleRelationship $db $parentPath 'parent-session' '' 'root-session'
    Add-QuotaCycleRelationship $db $childPath 'child-session' 'parent-session' 'root-session'
    $stepStart = [DateTimeOffset]::Parse('2030-03-05T00:10:00Z')
    $stepEnd = [DateTimeOffset]::Parse('2030-03-05T00:10:20Z')
    Add-QuotaCycleRow $db 'parent-session' ([DateTimeOffset]::Parse('2030-03-05T00:10:10Z')).ToString('o') $parentPath 10 'lineage-copy' -RootSessionId 'root-session' -PlanType 'pro' -RateLimitId 'quota-synthetic' -FiveHourUsed 70 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 500 -CallInput 500 -TotalOutput 50 -CallOutput 50 -Fingerprint 'same-lineage-usage'
    Add-QuotaCycleRow $db 'child-session' ([DateTimeOffset]::Parse('2030-03-05T00:10:11Z')).ToString('o') $childPath 10 'lineage-copy' -RootSessionId 'root-session' -PlanType 'team' -RateLimitId 'quota-synthetic' -FiveHourUsed 70 -FiveHourWindow 300 -FiveHourReset $reset -TotalInput 500 -CallInput 500 -TotalOutput 50 -CallOutput 50 -Fingerprint 'same-lineage-usage'
    $aggregate = [TokenRaderIndexer]::AggregateQuotaTimeRangeRecordsAtOffsets(
        $db, @{ $parentPath = 100L; $childPath = 100L }, $stepStart, $stepEnd, $thresholds, $none, @{}, 'FiveHour', 300, $reset, 'team', 'quota-synthetic')
    Assert-QuotaCycle ($aggregate.CountedEvents -eq 0) 'child current-plan copy escaped parent canonicalization'
    Assert-QuotaCycle ($aggregate.ExcludedCycleEvents -ge 1) 'canonical old-plan event was not reported as excluded'
} finally {
    $db.Dispose()
}

# Same-timestamp rate-limit rows use the stable SQLite record id as the tie
# breaker. The converter must retain the latest row rather than depending on
# incidental DataTable enumeration order.
$db = New-QuotaCycleDb
try {
    $path = 'synthetic://quota-same-timestamp'
    $sameTime = '2030-03-06T00:10:00Z'
    $weeklyReset = $reset + 1000L
    # The latest-five row and latest-weekly row intentionally come from
    # different records at one exact timestamp. This mirrors split API
    # responses and forces the converter to use the stable id tie-breaker.
    Add-QuotaCycleRow $db 'same-time-session' $sameTime $path 10 'same-time-first' -PlanType 'team' -RateLimitId 'old-limit' -FiveHourUsed 80 -FiveHourWindow 300 -FiveHourReset $reset -WeeklyUsed 10 -WeeklyWindow 10080 -WeeklyReset $weeklyReset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    Add-QuotaCycleRow $db 'same-time-session' $sameTime $path 20 'same-time-latest' -PlanType 'team' -RateLimitId 'new-limit' -FiveHourUsed $null -FiveHourWindow $null -FiveHourReset $null -WeeklyUsed 11 -WeeklyWindow 10080 -WeeklyReset $weeklyReset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    $rows = [TokenRaderIndexer]::QueryLatestRateLimitsByOffsets($db, @{ $path = 0L }, @{ $path = 100L })
    $converted = & $coreModule { param($table) ConvertFrom-TokenRaderRateLimitRows -Table $table } $rows
    Assert-QuotaCycle ($null -ne $converted -and $converted.FiveHour.UsedPercent -eq 80 -and $converted.Weekly.UsedPercent -eq 11) 'same-timestamp converter did not choose latest stable ids per window'
    Assert-QuotaCycleEqual 'new-limit' $converted.LimitId 'same-timestamp converter selected stale metadata id'
    $reversed = $rows.Clone()
    for ($rowIndex = $rows.Rows.Count - 1; $rowIndex -ge 0; $rowIndex--) { $reversed.ImportRow($rows.Rows[$rowIndex]) }
    $convertedReversed = & $coreModule { param($table) ConvertFrom-TokenRaderRateLimitRows -Table $table } $reversed
    Assert-QuotaCycle ($convertedReversed.FiveHour.UsedPercent -eq 80 -and $convertedReversed.Weekly.UsedPercent -eq 11 -and $convertedReversed.LimitId -eq 'new-limit') 'same-timestamp converter depended on DataTable enumeration order'
} finally {
    $db.Dispose()
}

# Dense split-window metadata must not cause a prefix replay for every call.
$db = New-QuotaCycleDb
try {
    $path='synthetic://quota-split-performance'
    $start=[DateTimeOffset]::Parse('2030-03-06T00:00:00Z')
    Add-QuotaCycleRow $db 'split-perf' $start.ToString('o') $path 1 'split-start' -PlanType 'team' -RateLimitId 'quota-synthetic' -WeeklyUsed 20 -WeeklyWindow 10080 -WeeklyReset $reset -TotalInput 0 -CallInput 0 -TotalOutput 0 -CallOutput 0
    $cmd=$db.CreateCommand()
    $cmd.CommandText=@'
WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v+1 FROM n WHERE v<25000)
INSERT INTO token_records(session_id,timestamp,model,total_input,total_cached,total_output,call_input,call_cached,call_output,source_path,source_offset_end,root_session_id,request_id,plan_type,rate_limit_id,five_hour_used,five_hour_window,five_hour_resets)
SELECT 'split-perf',strftime('%Y-%m-%dT%H:%M:%fZ','2030-03-06',printf('+%d seconds',v)),'gpt-5.6-sol',v*10,0,v,10,0,1,@path,v+1,'split-perf',printf('split-%d',v),'team','quota-synthetic',10,300,@reset FROM n
'@
    [void]$cmd.Parameters.AddWithValue('@path',$path);[void]$cmd.Parameters.AddWithValue('@reset',$reset)
    [void]$cmd.ExecuteNonQuery();$cmd.Dispose()
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $aggregate=[TokenRaderIndexer]::AggregateQuotaTimeRangeRecordsAtOffsets($db,@{$path=30000L},$start,$start.AddSeconds(25001),$thresholds,$none,@{},'Weekly',10080,$reset,'team','quota-synthetic')
    $watch.Stop()
    Assert-QuotaCycle ($aggregate.AttributionComplete -and $aggregate.CountedEvents -eq 25000) 'split-window inheritance lost calls'
    Assert-QuotaCycle ($watch.Elapsed.TotalSeconds -lt 3) 'split-window attribution became quadratic'
    Write-Output ('QUOTA_SPLIT_PERF rows=25000 elapsedMs={0:0.0}' -f $watch.Elapsed.TotalMilliseconds)
} finally { $db.Dispose() }
Write-Output 'QUOTA_CYCLE_TESTS_PASSED'
