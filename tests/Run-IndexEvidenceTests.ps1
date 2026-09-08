[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-IndexEvidence {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('INDEX EVIDENCE TEST FAILED: ' + $Message) }
}

function Write-IndexEvidenceJsonl {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object[]]$Records)
    $encoding = [Text.UTF8Encoding]::new($false)
    $lines = @($Records | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress })
    [IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), $encoding)
}

function Append-IndexEvidenceJsonl {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object[]]$Records)
    $encoding = [Text.UTF8Encoding]::new($false)
    $lines = @($Records | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress })
    [IO.File]::AppendAllText($Path, (($lines -join "`n") + "`n"), $encoding)
}

function New-IndexEvidenceTurn {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [AllowEmptyString()][string]$Model = '',
        [AllowNull()][string]$ServiceTier = $null,
        [AllowNull()][string]$ReasoningEffort = $null,
        [AllowEmptyString()][string]$TurnId = ''
    )
    $payload = [ordered]@{}
    if ($PSBoundParameters.ContainsKey('Model')) { $payload['model'] = $Model }
    if ($PSBoundParameters.ContainsKey('ServiceTier')) { $payload['service_tier'] = $ServiceTier }
    if ($PSBoundParameters.ContainsKey('ReasoningEffort')) { $payload['reasoning_effort'] = $ReasoningEffort }
    if (-not [string]::IsNullOrWhiteSpace($TurnId)) { $payload['turn_id'] = $TurnId }
    [ordered]@{ timestamp = $Timestamp; type = 'turn_context'; payload = $payload }
}

function New-IndexEvidenceToken {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][Int64]$TotalInput,
        [Parameter(Mandatory = $true)][Int64]$CallInput,
        [string]$RequestId = '',
        [string]$ResponseId = '',
        [string]$TurnId = '',
        [string]$Body = ''
    )
    $total = [ordered]@{ input_tokens = $TotalInput; cached_input_tokens = 0; output_tokens = 10; reasoning_output_tokens = 0; total_tokens = $TotalInput + 10 }
    $last = [ordered]@{ input_tokens = $CallInput; cached_input_tokens = 0; output_tokens = 10; reasoning_output_tokens = 0; total_tokens = $CallInput + 10 }
    $info = [ordered]@{ total_token_usage = $total; last_token_usage = $last; model_context_window = 1050000 }
    $payload = [ordered]@{ type = 'token_count'; info = $info }
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) { $payload['request_id'] = $RequestId }
    if (-not [string]::IsNullOrWhiteSpace($ResponseId)) { $payload['response_id'] = $ResponseId }
    if (-not [string]::IsNullOrWhiteSpace($TurnId)) { $payload['turn_id'] = $TurnId }
    if (-not [string]::IsNullOrWhiteSpace($Body)) { $payload['body'] = $Body }
    [ordered]@{ timestamp = $Timestamp; type = 'event_msg'; payload = $payload }
}

function New-IndexEvidenceRateToken {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][double]$UsedPercent,
        [Parameter(Mandatory = $true)][Int64]$ResetUnixSeconds,
        [Int64]$OffsetInput = 100
    )
    $total = [ordered]@{ input_tokens = $OffsetInput; cached_input_tokens = 0; output_tokens = 1; reasoning_output_tokens = 0; total_tokens = $OffsetInput + 1 }
    $last = [ordered]@{ input_tokens = $OffsetInput; cached_input_tokens = 0; output_tokens = 1; reasoning_output_tokens = 0; total_tokens = $OffsetInput + 1 }
    $primary = [ordered]@{ used_percent = $UsedPercent; window_minutes = 300; resets_at = $ResetUnixSeconds }
    $limits = [ordered]@{ plan_type = 'pro'; limit_id = 'synthetic'; primary = $primary }
    [ordered]@{
        timestamp = $Timestamp
        type = 'event_msg'
        payload = [ordered]@{
            type = 'token_count'
            info = [ordered]@{ total_token_usage = $total; last_token_usage = $last }
            rate_limits = $limits
        }
    }
}

function Get-IndexEvidenceRows {
    param([Parameter(Mandatory = $true)]$Connection, [Parameter(Mandatory = $true)][string]$Sql, [hashtable]$Parameters = @{})
    $table = [Data.DataTable]::new()
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Sql
        foreach ($key in $Parameters.Keys) { [void]$command.Parameters.AddWithValue($key, $Parameters[$key]) }
        $adapter = [System.Data.SQLite.SQLiteDataAdapter]::new($command)
        try { [void]$adapter.Fill($table) } finally { $adapter.Dispose() }
    } finally { $command.Dispose() }
    return ,$table
}

function Add-IndexEvidenceAggregateRow {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][Int64]$Offset,
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Int64]$TotalInput = 100,
        [Int64]$CallInput = 100,
        [double]$FiveHourUsed = 0,
        [Int64]$FiveHourReset = 1890000000,
        [string]$PlanType = 'pro',
        [string]$RateLimitId = 'synthetic',
        [string]$ServiceTier = '',
        [string]$ServiceTierSource = ''
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
INSERT INTO token_records
(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,
 call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,
 source_offset_end,root_session_id,index_revision,request_id,identity_source,
 service_tier,service_tier_source,
 five_hour_used,five_hour_window,five_hour_resets,plan_type,rate_limit_id)
VALUES (@session,@timestamp,'gpt-5.6-sol',@total,0,10,0,@call,0,10,0,
 @fingerprint,@path,@offset,@session,1,@request,'request_id',@tier,@tier_source,
 @used,300,@reset,@plan,@limit)
'@
        [void]$command.Parameters.AddWithValue('@session', $SessionId)
        [void]$command.Parameters.AddWithValue('@timestamp', $Timestamp)
        [void]$command.Parameters.AddWithValue('@total', $TotalInput)
        [void]$command.Parameters.AddWithValue('@call', $CallInput)
        [void]$command.Parameters.AddWithValue('@fingerprint', ($TotalInput.ToString() + ':0:10:0:' + $CallInput.ToString() + ':0:10:0'))
        [void]$command.Parameters.AddWithValue('@path', $SourcePath)
        [void]$command.Parameters.AddWithValue('@offset', $Offset)
        [void]$command.Parameters.AddWithValue('@request', $RequestId)
        [void]$command.Parameters.AddWithValue('@tier', $ServiceTier)
        [void]$command.Parameters.AddWithValue('@tier_source', $ServiceTierSource)
        [void]$command.Parameters.AddWithValue('@used', $FiveHourUsed)
        [void]$command.Parameters.AddWithValue('@reset', $FiveHourReset)
        [void]$command.Parameters.AddWithValue('@plan', $PlanType)
        [void]$command.Parameters.AddWithValue('@limit', $RateLimitId)
        [void]$command.ExecuteNonQuery()
    } finally { $command.Dispose() }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }

$tempRoot = Join-Path $env:TEMP ('token-rader-index-evidence-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    if ($null -eq ('TokenRaderIndexer' -as [type])) {
        Add-Type -Path (Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll')
    }

    $db = [System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $db.Open()
    try {
        [TokenRaderIndexer]::CreateSchema($db)

        # Body text may contain metadata-looking words, but only a real
        # top-level turn_context event may mutate model/tier/effort/turn state.
        $bodyId = '20000000-0000-0000-0000-000000000001'
        $bodyPath = Join-Path $tempRoot ('rollout-' + $bodyId + '.jsonl')
        $bodyRecords = @(
            (New-IndexEvidenceTurn '2026-09-08T00:00:00Z' 'gpt-5.6-sol' 'priority' 'ultra' 'turn-one'),
            (New-IndexEvidenceToken '2026-09-08T00:00:01Z' 100 100 'body-r1' '' '' 'turn_context reasoning_effort service_tier turn_id model'),
            (New-IndexEvidenceTurn '2026-09-08T00:00:02Z' 'gpt-5.6-luna'),
            (New-IndexEvidenceToken '2026-09-08T00:00:03Z' 200 100 'body-r2' '' '' '')
        )
        Write-IndexEvidenceJsonl $bodyPath $bodyRecords
        [void][TokenRaderIndexer]::ImportFile($db, $bodyPath, 0L, [IO.FileInfo]::new($bodyPath).Length, $bodyId, '', 1L)
        $bodyRows = Get-IndexEvidenceRows $db 'SELECT model,service_tier,service_tier_source,reasoning_effort,turn_id FROM token_records WHERE session_id=@session ORDER BY source_offset_end' @{ '@session' = $bodyId }
        Assert-IndexEvidence ($bodyRows.Rows.Count -eq 2) 'body marker fixture did not produce two tokens'
        Assert-IndexEvidence ([string]$bodyRows.Rows[0]['model'] -eq 'gpt-5.6-sol' -and [string]$bodyRows.Rows[0]['service_tier'] -eq 'priority' -and [string]$bodyRows.Rows[0]['reasoning_effort'] -eq 'ultra' -and [string]$bodyRows.Rows[0]['turn_id'] -eq 'turn-one') 'body text polluted the first context'
        Assert-IndexEvidence ([string]$bodyRows.Rows[1]['model'] -eq 'gpt-5.6-luna' -and [string]$bodyRows.Rows[1]['service_tier'] -eq '' -and [string]$bodyRows.Rows[1]['service_tier_source'] -eq 'turn_context_missing' -and [string]$bodyRows.Rows[1]['reasoning_effort'] -eq '') 'missing turn context did not clear metadata'

        # A context-only append must survive restart and bind the next token;
        # explicit missing and later new tiers are both exercised here.
        $restartId = '20000000-0000-0000-0000-000000000002'
        $restartPath = Join-Path $tempRoot ('rollout-' + $restartId + '.jsonl')
        $initial = @(
            (New-IndexEvidenceTurn '2026-09-08T01:00:00Z' 'gpt-5.6-sol' 'priority' 'ultra' 'restart-one'),
            (New-IndexEvidenceToken '2026-09-08T01:00:01Z' 100 100 'restart-r1')
        )
        Write-IndexEvidenceJsonl $restartPath $initial
        [void][TokenRaderIndexer]::ImportFile($db, $restartPath, 0L, [IO.FileInfo]::new($restartPath).Length, $restartId, '', 1L)
        $firstLength = [IO.FileInfo]::new($restartPath).Length
        Append-IndexEvidenceJsonl $restartPath @(
            (New-IndexEvidenceTurn '2026-09-08T01:00:02Z' 'gpt-5.6-luna' $null 'low' 'restart-two')
        )
        $contextEnd = [IO.FileInfo]::new($restartPath).Length
        [void][TokenRaderIndexer]::ImportFile($db, $restartPath, $firstLength, $contextEnd, $restartId, '', 2L)
        $contextMetadata = Get-IndexEvidenceRows $db 'SELECT turn_context_model,turn_context_model_source,turn_context_service_tier FROM file_metadata WHERE path=@path' @{ '@path' = $restartPath }
        Assert-IndexEvidence ($contextMetadata.Rows.Count -eq 1 -and [string]$contextMetadata.Rows[0]['turn_context_model'] -eq 'gpt-5.6-luna' -and [string]$contextMetadata.Rows[0]['turn_context_service_tier'] -eq '') 'context-only append did not persist model or clear tier'
        Append-IndexEvidenceJsonl $restartPath @(
            (New-IndexEvidenceTurn '2026-09-08T01:00:03Z' 'gpt-5.6-luna' 'priority' 'ultra' 'restart-three'),
            (New-IndexEvidenceToken '2026-09-08T01:00:04Z' 200 100 'restart-r2')
        )
        [void][TokenRaderIndexer]::ImportFile($db, $restartPath, $contextEnd, [IO.FileInfo]::new($restartPath).Length, $restartId, '', 3L)
        $restartRows = Get-IndexEvidenceRows $db 'SELECT model,service_tier FROM token_records WHERE session_id=@session ORDER BY source_offset_end' @{ '@session' = $restartId }
        Assert-IndexEvidence ($restartRows.Rows.Count -eq 2 -and [string]$restartRows.Rows[1]['model'] -eq 'gpt-5.6-luna' -and [string]$restartRows.Rows[1]['service_tier'] -eq 'priority') 'restart did not restore trailing model context'

        # Parent model resolution is bounded by the child event timestamp.
        $parentId = '20000000-0000-0000-0000-000000000010'
        $childId = '20000000-0000-0000-0000-000000000011'
        $parentPath = Join-Path $tempRoot ('rollout-' + $parentId + '.jsonl')
        $childPath = Join-Path $tempRoot ('rollout-' + $childId + '.jsonl')
        Write-IndexEvidenceJsonl $parentPath @(
            (New-IndexEvidenceTurn '2026-09-08T02:00:00Z' 'gpt-5.6-sol'),
            (New-IndexEvidenceToken '2026-09-08T02:00:01Z' 100 100 'parent-r1')
        )
        [void][TokenRaderIndexer]::ImportFile($db, $parentPath, 0L, [IO.FileInfo]::new($parentPath).Length, $parentId, '', 4L)
        $parentLength = [IO.FileInfo]::new($parentPath).Length
        Append-IndexEvidenceJsonl $parentPath @(
            (New-IndexEvidenceTurn '2026-09-08T02:00:20Z' 'gpt-5.6-luna'),
            (New-IndexEvidenceToken '2026-09-08T02:00:21Z' 200 100 'parent-r2')
        )
        [void][TokenRaderIndexer]::ImportFile($db, $parentPath, $parentLength, [IO.FileInfo]::new($parentPath).Length, $parentId, '', 5L)
        Write-IndexEvidenceJsonl $childPath @(
            (New-IndexEvidenceToken '2026-09-08T02:00:10Z' 50 50 'child-r1')
        )
        [void][TokenRaderIndexer]::ImportFile($db, $childPath, 0L, [IO.FileInfo]::new($childPath).Length, $parentId, $parentId, 6L)
        $childRows = Get-IndexEvidenceRows $db 'SELECT model,model_source FROM token_records WHERE session_id=@session' @{ '@session' = $childId }
        Assert-IndexEvidence ($childRows.Rows.Count -eq 1 -and [string]$childRows.Rows[0]['model'] -eq 'gpt-5.6-sol' -and [string]$childRows.Rows[0]['model_source'] -eq 'parent') 'child inherited a future parent model'

        # A parent context without a token is still valid evidence. Compare
        # actual instants, including offsets and sub-millisecond boundaries.
        $parentLength = [IO.FileInfo]::new($parentPath).Length
        Append-IndexEvidenceJsonl $parentPath @(
            (New-IndexEvidenceTurn '2026-09-08T10:00:30.1234567+08:00' 'gpt-6-astra')
        )
        [void][TokenRaderIndexer]::ImportFile($db, $parentPath, $parentLength, [IO.FileInfo]::new($parentPath).Length, $parentId, '', 7L)
        $modelLookup = @([TokenRaderIndexer].GetMethods([Reflection.BindingFlags]'NonPublic,Static') | Where-Object { $_.Name -eq 'GetLatestSessionModel' -and $_.GetParameters().Count -eq 3 })[0]
        $beforeContext = $modelLookup.Invoke($null, [object[]]@($db, $parentId, [DateTimeOffset]::Parse('2026-09-08T02:00:30.1234566Z')))
        $atContext = $modelLookup.Invoke($null, [object[]]@($db, $parentId, [DateTimeOffset]::Parse('2026-09-08T02:00:30.1234567Z')))
        Assert-IndexEvidence ($beforeContext -eq 'gpt-5.6-luna' -and $atContext -eq 'gpt-6-astra') 'parent context-only evidence crossed its exact time boundary'
        $mixedTimeId = '20000000-0000-0000-0000-000000000012'
        Add-IndexEvidenceAggregateRow $db $mixedTimeId '2026-09-08T10:00:01+08:00' 'synthetic://mixed-time' 1 'mixed-one'
        $mixedModel = $modelLookup.Invoke($null, [object[]]@($db, $mixedTimeId, [DateTimeOffset]::Parse('2026-09-08T02:00:02Z')))
        Assert-IndexEvidence ($mixedModel -eq 'gpt-5.6-sol') 'explicit-offset token timestamp was compared lexically'

        # Early cumulative-snapshot gates must retain distinct strong ids while
        # still collapsing an ordinary repeated status with the same id.
        $aggregatePath = 'synthetic://index-evidence-aggregate'
        $aggregateSession = '20000000-0000-0000-0000-000000000020'
        Add-IndexEvidenceAggregateRow $db $aggregateSession '2026-09-08T03:00:01Z' $aggregatePath 10 'request-one' 100 100
        Add-IndexEvidenceAggregateRow $db $aggregateSession '2026-09-08T03:00:02Z' $aggregatePath 20 'request-one' 100 100
        Add-IndexEvidenceAggregateRow $db $aggregateSession '2026-09-08T03:00:03Z' $aggregatePath 30 'request-two' 100 100
        $startOffsets = @{ $aggregatePath = 0L }
        $endOffsets = @{ $aggregatePath = 1000L }
        $thresholds = @{ 'gpt-5.6-sol' = 272000L }
        $interval = [TokenRaderIndexer]::AggregateIntervalRecords($db, $startOffsets, $endOffsets, [DateTimeOffset]::Parse('2026-09-08T02:59:00Z'), $thresholds, [Threading.CancellationToken]::None)
        Assert-IndexEvidence ($interval.CountedEvents -eq 2 -and $interval.TotalInput -eq 200 -and $interval.DuplicateEventsDropped -ge 1) 'interval strong-id dedup lost a distinct request or retained ordinary status'
        $range = [TokenRaderIndexer]::AggregateTimeRangeRecords($db, [DateTimeOffset]::Parse('2026-09-08T03:00:00Z'), [DateTimeOffset]::Parse('2026-09-08T03:01:00Z'), $thresholds, [Threading.CancellationToken]::None)
        Assert-IndexEvidence ($range.CountedEvents -eq 2 -and $range.TotalInput -eq 200) 'time-range strong-id dedup lost a distinct request'
        $rangeAtOffset = [TokenRaderIndexer]::AggregateTimeRangeRecordsAtOffsets($db, $endOffsets, [DateTimeOffset]::Parse('2026-09-08T03:00:00Z'), [DateTimeOffset]::Parse('2026-09-08T03:01:00Z'), $thresholds, [Threading.CancellationToken]::None)
        Assert-IndexEvidence ($rangeAtOffset.CountedEvents -eq 2 -and $rangeAtOffset.TotalInput -eq 200) 'offset time-range strong-id dedup lost a distinct request'

        $tierPath = 'synthetic://index-evidence-tier'
        Add-IndexEvidenceAggregateRow $db $aggregateSession '2026-09-08T03:02:01Z' $tierPath 10 'tier-indexed' 100 100 0 1890000000 'pro' 'synthetic' 'priority' 'indexed'
        Add-IndexEvidenceAggregateRow $db $aggregateSession '2026-09-08T03:02:02Z' $tierPath 20 'tier-response' 100 100 0 1890000000 'pro' 'synthetic' 'priority' 'response'
        $tierResult = [TokenRaderIndexer]::AggregateIntervalRecords($db, @{ $tierPath = 0L }, @{ $tierPath = 1000L }, [DateTimeOffset]::Parse('2026-09-08T03:02:00Z'), $thresholds, [Threading.CancellationToken]::None)
        $trustedBuckets = @($tierResult.Buckets | Where-Object { $_.ServiceTierEvidenceComplete })
        $untrustedBuckets = @($tierResult.Buckets | Where-Object { -not $_.ServiceTierEvidenceComplete })
        Assert-IndexEvidence ($tierResult.CountedEvents -eq 2 -and $trustedBuckets.Count -eq 1 -and $untrustedBuckets.Count -eq 1) 'trusted and legacy tier evidence was merged into one pricing bucket'

        # Streaming endpoint validation accepts a real 0% start and rejects a
        # higher snapshot at or before either frozen boundary.
        $quotaPath = 'synthetic://index-evidence-quota'
        $quotaSession = '20000000-0000-0000-0000-000000000021'
        $reset = 1890000000L
        Add-IndexEvidenceAggregateRow $db $quotaSession '2026-09-08T04:00:00Z' $quotaPath 10 'quota-zero' 100 100 0 $reset
        Add-IndexEvidenceAggregateRow $db $quotaSession '2026-09-08T04:00:10Z' $quotaPath 20 'quota-mid' 100 100 1 $reset
        Add-IndexEvidenceAggregateRow $db $quotaSession '2026-09-08T04:00:20Z' $quotaPath 30 'quota-end' 100 100 2 $reset
        $quotaEnds = @{ $quotaPath = 1000L }
        $validQuota = [TokenRaderIndexer]::ValidateQuotaSnapshotPairByOffsets($db, $quotaEnds, 'FiveHour', 300, $reset, 'pro', 'synthetic', 0, [DateTimeOffset]::Parse('2026-09-08T04:00:00Z'), 2, [DateTimeOffset]::Parse('2026-09-08T04:00:20Z'), [Threading.CancellationToken]::None)
        Assert-IndexEvidence $validQuota 'valid zero-percent quota endpoint pair was rejected'
        # Exercise the actual Core evidence path, not just its validator. A
        # newer observation on the same plateau must keep exact endpoints.
        $coreModule = Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -PassThru
        $quotaPrices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
        $quotaPrices | Add-Member -NotePropertyName ManualServiceTiers -NotePropertyValue @{'gpt-5.6-sol'='default'} -Force
        $startWindow = [pscustomobject]@{ObservedAt=[DateTimeOffset]::Parse('2026-09-08T04:00:00Z');UsedPercent=0.0;WindowMinutes=300;ResetsAt=[DateTimeOffset]::FromUnixTimeSeconds($reset);PlanType='pro';LimitId='synthetic'}
        $endWindow = [pscustomobject]@{ObservedAt=[DateTimeOffset]::Parse('2026-09-08T04:00:20Z');UsedPercent=2.0;WindowMinutes=300;ResetsAt=[DateTimeOffset]::FromUnixTimeSeconds($reset);PlanType='pro';LimitId='synthetic'}
        $getEvidence = {
            param($connection,$ends,$start,$end,$prices)
            Get-TokenRaderQuotaWindowEvidence -StartWindow $start -EndWindow $end -WindowKind FiveHour -Connection $connection -EndOffsets $ends -Thresholds @{} -PricingDocument $prices -CancellationToken ([Threading.CancellationToken]::None) -Cache @{}
        }
        $evidence = & $coreModule $getEvidence $db $quotaEnds $startWindow $endWindow $quotaPrices
        Assert-IndexEvidence ($null -ne $evidence -and $evidence.QuotaEvidenceComplete -and $evidence.CountedEvents -eq 2) 'production evidence rejected complete manually confirmed endpoints'
        Add-IndexEvidenceAggregateRow $db $quotaSession '2026-09-08T04:00:30Z' $quotaPath 35 'quota-plateau' 100 100 2 $reset
        $endWindow.ObservedAt=[DateTimeOffset]::Parse('2026-09-08T04:00:30Z')
        $plateauEvidence = & $coreModule $getEvidence $db $quotaEnds $startWindow $endWindow $quotaPrices
        Assert-IndexEvidence ($null -ne $plateauEvidence -and $plateauEvidence.CountedEvents -eq 3 -and $plateauEvidence.EndObservedAt -eq $endWindow.ObservedAt) 'production evidence replaced a later plateau endpoint with the first step'
        Add-IndexEvidenceAggregateRow $db $quotaSession '2026-09-08T04:00:05Z' $quotaPath 40 'quota-high' 100 100 3 $reset
        $invalidQuota = [TokenRaderIndexer]::ValidateQuotaSnapshotPairByOffsets($db, $quotaEnds, 'FiveHour', 300, $reset, 'pro', 'synthetic', 0, [DateTimeOffset]::Parse('2026-09-08T04:00:00Z'), 2, [DateTimeOffset]::Parse('2026-09-08T04:00:20Z'), [Threading.CancellationToken]::None)
        Assert-IndexEvidence (-not $invalidQuota) 'quota validator accepted a higher pre-end snapshot'
        $staleEvidence = & $coreModule $getEvidence $db $quotaEnds $startWindow $endWindow $quotaPrices
        Assert-IndexEvidence ($null -eq $staleEvidence) 'production evidence accepted a late lower endpoint'

        Write-Output 'INDEX_EVIDENCE_TESTS_PASSED'
    } finally {
        $db.Dispose()
    }
} finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolved = [IO.Path]::GetFullPath($tempRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup target' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
