[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll=Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-RecentSynthetic-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;'); $db.Open()
$utf8=[Text.UTF8Encoding]::new($false); $none=[Threading.CancellationToken]::None; $progress=[hashtable]::Synchronized(@{})
$end=[DateTimeOffset]::Parse('2026-10-05T12:00:00Z'); $cutoff=$end.AddHours(-24)
function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('RECENT HISTORY FAILED: '+$message) } }
function Scalar([string]$sql) { $cmd=$db.CreateCommand(); try { $cmd.CommandText=$sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() } }
function Token([string]$at,[int]$total,[int]$last=-1) {
    $info=@{total_token_usage=@{input_tokens=$total;cached_input_tokens=0;output_tokens=0;reasoning_output_tokens=0}}
    if($last-ge0){$info.last_token_usage=@{input_tokens=$last;cached_input_tokens=0;output_tokens=0;reasoning_output_tokens=0}}
    return (@{timestamp=$at;type='event_msg';payload=@{type='token_count';info=$info}}|ConvertTo-Json -Depth 8 -Compress)
}
function Complete {
    $i=0
    do {
        $script:batch=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,900,500,$progress,$none)
        Assert ($batch.ProcessedBytes-le900) 'bytes bounded'
        $i++; Assert ($i-lt2000) 'bounded work progresses'
    } while(-not $batch.Completed -and $batch.EligibleFiles-gt0)
}
try {
    [TokenRaderIndexer]::CreateSchema($db)
    Assert (-not [TokenRaderIndexer]::GetRecentHistoryBackfillStatus($db).Completed) 'absent task not complete'
    $path=Join-Path $temp 'old-reopened.jsonl'
    $meta='{"timestamp":"2026-09-01T00:00:00Z","type":"session_meta","payload":{"id":"synthetic","cwd":"synthetic-only"}}'
    $context='{"timestamp":"2026-09-01T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    # Nonmonotonic records and an old path/mtime must not hide recent events.
    $lines=@($meta,$context,(Token '2026-09-01T00:00:00Z' 100 100),(Token '2026-10-05T01:00:00Z' 125),(Token '2026-09-02T00:00:00Z' 140 15),(Token '2026-10-05T02:00:00Z' 160))
    [IO.File]::WriteAllText($path,($lines-join"`n")+"`n",$utf8)
    [IO.File]::SetLastWriteTimeUtc($path,[datetime]'2026-09-01T00:00:00Z')
    $frozen=([IO.FileInfo]$path).Length
    $completePath=Join-Path $temp 'already-indexed.jsonl'
    [IO.File]::WriteAllText($completePath,($meta+"`n"+$context+"`n"+(Token '2026-09-03T00:00:00Z' 90 90)+"`n"),$utf8)
    [void][TokenRaderIndexer]::ImportFile($db,$completePath,0)
    [TokenRaderIndexer]::UpdateFileMetadata($db,$completePath,([IO.FileInfo]$completePath).Length,[IO.File]::GetLastWriteTimeUtc($completePath).Ticks,([IO.FileInfo]$completePath).Length)
    $prepared=[TokenRaderIndexer]::PrepareRecentHistory($db,$temp,$cutoff,$end,$progress,$none)
    Assert ((Scalar 'SELECT COUNT(*) FROM recent_history_work')-eq1) 'fully indexed files require no recent discovery scan'
    Assert ($prepared.EndOffsets[$path.ToLowerInvariant()]-eq$frozen) 'freeze old reopened file independent of mtime'
    $first=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,500,500,$progress,$none)
    $cursor=Scalar 'SELECT cursor_offset FROM recent_history_work'
    $cancel=[Threading.CancellationTokenSource]::new(); $cancel.Cancel()
    try { [void][TokenRaderIndexer]::BackfillRecentHistoryBatch($db,500,500,$progress,$cancel.Token); throw 'missing cancellation' }
    catch { Assert ($_.Exception.ToString().Contains('OperationCanceledException')) 'cancel propagates' }
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$cursor) 'cancel preserves committed cursor'
    # Starting again resumes metadata/numeric state rather than rescanning.
    $prepared=[TokenRaderIndexer]::PrepareRecentHistory($db,$temp,$cutoff.AddMinutes(1),$end.AddMinutes(1),$progress,$none)
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-ge$cursor) 'retry resumes cursor'
    [IO.File]::AppendAllText($path,(Token '2026-10-05T12:01:30Z' 170 10)+"`n",$utf8)
    Complete
    Assert $batch.Completed 'frozen recent scan completes while live source grows'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE source_path LIKE '%old-reopened.jsonl'")-eq2) 'only recent frozen token rows retained; earlier indexed rows preserved'
    Assert ((Scalar "SELECT SUM(call_input) FROM token_records WHERE source_path LIKE '%old-reopened.jsonl'")-eq45) 'old cumulative state carries across bounded batches'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE source_path LIKE '%old-reopened.jsonl' AND model='gpt-5.4' AND service_tier='priority'")-eq2) 'historical mode retained'
    Assert (-not [TokenRaderIndexer]::GetHistoryBackfillStatus($db).Completed) 'older global history remains incomplete'
    Assert (-not [TokenRaderIndexer]::HasHistoryGapInRange($db,$cutoff.AddHours(1),$end.AddHours(1))) 'recent and later live evidence has scoped coverage'
    Assert ([TokenRaderIndexer]::HasHistoryGapInRange($db,$cutoff.AddDays(-1),$end)) 'older evidence still rejected'
    Assert ((Scalar 'SELECT MAX(end_offset) FROM recent_history_work')-eq$frozen) 'batch never chases growing EOF'
    [void][TokenRaderIndexer]::ImportFile($db,$path,$frozen,([IO.FileInfo]$path).Length,'synthetic','',100,$progress,$none)
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE source_path LIKE '%old-reopened.jsonl'")-eq3) 'ordinary live import includes appended event once'
    [TokenRaderIndexer]::UpdateFileMetadata($db,$path,([IO.FileInfo]$path).Length,[IO.File]::GetLastWriteTimeUtc($path).Ticks,([IO.FileInfo]$path).Length)
    $repeat=[TokenRaderIndexer]::PrepareRecentHistory($db,$temp,$cutoff.AddMinutes(2),$end.AddMinutes(2),$progress,$none)
    Assert ($repeat.ProcessedBytes-eq0 -and $repeat.Completed -and $repeat.RemainingBytes-eq0) 'unchanged complete-prefix proof avoids resampling/rebackfill'
    $before=Scalar 'SELECT cursor_offset FROM recent_history_work'
    [void][TokenRaderIndexer]::GetRecentHistoryBackfillStatus($db)
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$before) 'status does not scan or advance work'
    $schema=Scalar "SELECT sql FROM sqlite_master WHERE name='recent_history_work'"
    Assert (-not $schema.Contains('pending_line')) 'ledger contains no raw conversation body'
    [IO.File]::AppendAllText($path,(Token '2026-10-05T12:03:00Z' 180 10)+"`n",$utf8)
    [void][TokenRaderIndexer]::InitializeFromNow($db,$temp,$progress,$none)
    $newCoverage=$end.AddHours(2)
    [TokenRaderIndexer]::SetSetting($db,'history_coverage_start',$newCoverage.ToString('o'))
    Assert (-not [TokenRaderIndexer]::HasHistoryGapInRange($db,$newCoverage,$newCoverage.AddMinutes(1))) 'new from-now evidence remains valid despite stale recent marker'
    Assert ([TokenRaderIndexer]::HasHistoryGapInRange($db,$cutoff.AddHours(1),$newCoverage)) 'new uncaptured gap invalidates older scoped evidence'
    $db.Close(); $db.Dispose()

    # A live incomplete tail stays outside the frozen complete prefix.
    $partialRoot=Join-Path $temp 'partial'; [void][IO.Directory]::CreateDirectory($partialRoot)
    $partialPath=Join-Path $partialRoot 'partial.jsonl'
    $full=($meta+"`n"+$context+"`n"+(Token '2026-10-05T02:00:00Z' 100 100)+"`n")
    $tail=Token '2026-10-05T12:01:00Z' 150 50; $half=[int]($tail.Length/2)
    [IO.File]::WriteAllText($partialPath,$full+$tail.Substring(0,$half),$utf8)
    $db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;'); $db.Open(); [TokenRaderIndexer]::CreateSchema($db)
    [void][TokenRaderIndexer]::InitializeFromNow($db,$partialRoot,$progress,$none)
    Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-gt$utf8.GetByteCount($full)) 'ordinary startup initially freezes raw partial EOF'
    $prepared=[TokenRaderIndexer]::PrepareRecentHistory($db,$partialRoot,$cutoff,$end,$progress,$none)
    $completeOffset=$utf8.GetByteCount($full)
    Assert ($prepared.EndOffsets[$partialPath.ToLowerInvariant()]-eq$completeOffset) 'partial live tail is not frozen history'
    Complete; Assert $batch.Completed 'partial EOF does not permanently block complete prefix'
    [IO.File]::AppendAllText($partialPath,$tail.Substring($half)+"`n",$utf8)
    [void][TokenRaderIndexer]::ImportFile($db,$partialPath,$completeOffset,([IO.FileInfo]$partialPath).Length,'synthetic','',200,$progress,$none)
    Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq150) 'partial tail completion live call counted exactly once'
    $db.Close(); $db.Dispose()

    # Invalid timestamps and oversized unknown usage cannot claim completion.
    $badRoot=Join-Path $temp 'bad'; [void][IO.Directory]::CreateDirectory($badRoot)
    $badPath=Join-Path $badRoot 'bad.jsonl'
    [IO.File]::WriteAllText($badPath,$meta+"`n"+$context+"`n"+(Token 'not-a-timestamp' 100 100)+"`n",$utf8)
    $db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;'); $db.Open(); [TokenRaderIndexer]::CreateSchema($db)
    [void][TokenRaderIndexer]::PrepareRecentHistory($db,$badRoot,$cutoff,$end,$progress,$none)
    Complete
    Assert (-not $batch.Completed) 'unknown timestamp retains explicit coverage failure'
    Assert ($batch.BlockedFiles-eq1) 'blocked source reported'
    Assert ($batch.BlockedReasons.Contains('usage_timestamp_unknown')) 'specific blocked reason retained'
    Assert ([TokenRaderIndexer]::HasHistoryGapInRange($db,$cutoff.AddHours(1),$end)) 'failed work does not clear old gap protection'
    $db.Close(); $db.Dispose()
    $hugeRoot=Join-Path $temp 'oversized'; [void][IO.Directory]::CreateDirectory($hugeRoot)
    $hugePath=Join-Path $hugeRoot 'oversized.jsonl'
    [IO.File]::WriteAllText($hugePath,$meta+"`n"+$context+"`n"+'{"timestamp":"2026-10-05T02:00:00Z","type":"event_msg","payload":{"type":"token_count","unknown":"'+('x'*(2*1024*1024))+'"}}'+"`n",$utf8)
    $db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;'); $db.Open(); [TokenRaderIndexer]::CreateSchema($db)
    [void][TokenRaderIndexer]::PrepareRecentHistory($db,$hugeRoot,$cutoff,$end,$progress,$none)
    # Small synthetic byte batches still retain a permanent unknown-line block.
    for($i=0;$i-lt20;$i++) {
        $batch=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,256*1024,500,$progress,$none)
        Assert ($batch.ProcessedBytes-le256*1024) 'oversized discard obeys byte bound'
        if($batch.EligibleFiles-eq0){break}
    }
    Assert (-not $batch.Completed -and $batch.BlockedFiles-eq1) 'oversized unknown usage never reports completion'
    $retry=[TokenRaderIndexer]::PrepareRecentHistory($db,$hugeRoot,$cutoff.AddMinutes(1),$end.AddMinutes(1),$progress,$none)
    Assert (-not $retry.Completed) 'retry preserves unknown oversized-line rejection'
    $db.Close(); $db.Dispose()

    # Old parent numeric proof must survive the timestamp-only import filter.
    $lineageRoot=Join-Path $temp 'lineage'; [void][IO.Directory]::CreateDirectory($lineageRoot)
    $parentPath=Join-Path $lineageRoot 'parent.jsonl'; $childPath=Join-Path $lineageRoot 'child.jsonl'
    $parentMeta='{"timestamp":"2026-09-01T00:00:00Z","type":"session_meta","payload":{"id":"parent"}}'
    $childMeta='{"timestamp":"2026-10-05T00:00:00Z","type":"session_meta","payload":{"id":"child","parent_thread_id":"parent"}}'
    $parentContext='{"timestamp":"2026-09-01T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4","turn_id":"old-turn","service_tier":"priority"}}'
    $childContext='{"timestamp":"2026-10-05T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6","turn_id":"new-child-turn","service_tier":"default"}}'
    $old=(Token '2026-10-04T11:00:00Z' 100 100)|ConvertFrom-Json; $old.payload|Add-Member request_id 'old-request'
    $copy=(Token '2026-10-05T01:00:00Z' 100 100)|ConvertFrom-Json; $copy.payload|Add-Member request_id 'rewritten-child-request'
    [IO.File]::WriteAllText($parentPath,$parentMeta+"`n"+$parentContext+"`n"+($old|ConvertTo-Json -Depth 8 -Compress)+"`n",$utf8)
    [IO.File]::WriteAllText($childPath,$childMeta+"`n"+$childContext+"`n"+($copy|ConvertTo-Json -Depth 8 -Compress)+"`n",$utf8)
    $grandchildPath=Join-Path $lineageRoot 'aaa-grandchild.jsonl'
    $grandchildMeta='{"timestamp":"2026-10-05T00:00:00Z","type":"session_meta","payload":{"id":"grandchild","parent_thread_id":"child"}}'
    [IO.File]::WriteAllText($grandchildPath,$grandchildMeta+"`n"+$childContext+"`n"+($copy|ConvertTo-Json -Depth 8 -Compress)+"`n",$utf8)
    $db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;'); $db.Open(); [TokenRaderIndexer]::CreateSchema($db)
    $prepared=[TokenRaderIndexer]::PrepareRecentHistory($db,$lineageRoot,$cutoff,$end,$progress,$none); Complete
    Assert $batch.Completed 'cross-cutoff lineage discovery completes'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE session_id='parent'")-eq0) 'older ancestor remains proof only, not imported usage'
    Assert ((Scalar 'SELECT COUNT(*) FROM recent_lineage_evidence')-eq1) 'compact old canonical numeric identity retained'
    Assert ((Scalar "SELECT root_session_id FROM file_metadata WHERE session_id='grandchild'")-eq'parent') 'complete catalog resolves multi-level root before child-first import'
    $range=[TokenRaderIndexer]::AggregateTimeRangeRecords($db,$cutoff,$end,@{},$none,$null)
    Assert ($range.TotalInput-eq0) '24-hour history does not charge recent copy of older parent'
    $starts=@{}; foreach($key in $prepared.EndOffsets.Keys){$starts[$key]=0L}
    $interval=[TokenRaderIndexer]::AggregateIntervalRecords($db,$starts,$prepared.EndOffsets,$cutoff,@{},$none,$null)
    Assert ($interval.TotalInput-eq0) 'measurement aggregation uses canonical old proof'
    $scoped=[TokenRaderIndexer]::AggregateScopedTimeRangeRecordsAtOffsets($db,$prepared.EndOffsets,$cutoff,$end,@{},$none,$null,@('child'))
    Assert ($scoped.TotalInput-eq0) 'project/session ownership filters follow old canonical proof'
    $quota=[TokenRaderIndexer]::AggregateQuotaTimeRangeRecordsAtOffsets($db,$prepared.EndOffsets,$cutoff,$end,@{},$none,$null,'Weekly',10080,$end.AddDays(2).ToUnixTimeSeconds(),'pro','codex')
    Assert ($quota.TotalInput-eq0 -and $quota.UnattributedEvents-eq0) 'quota cycle attribution follows canonical proof suppression'
    $shortEnds=@{}; foreach($key in $prepared.EndOffsets.Keys){$shortEnds[$key]=$prepared.EndOffsets[$key]}; $shortEnds[$parentPath.ToLowerInvariant()]=0L
    $withoutProof=[TokenRaderIndexer]::AggregateTimeRangeRecordsAtOffsets($db,$shortEnds,$cutoff,$end,@{},$none,$null)
    Assert ($withoutProof.TotalInput-eq100) 'proof beyond caller frozen source EOF is not used'
    $allTime=[TokenRaderIndexer]::AggregateTimeRangeRecords($db,[DateTimeOffset]::MinValue.AddDays(2),$end,@{},$none,$null)
    Assert ($allTime.TotalInput-eq100) 'proof does not become billable history or override rows inside query range'
    Assert (-not [TokenRaderIndexer]::GetHistoryBackfillStatus($db).Completed) 'proof never marks global old history complete'

    # Same-session distinct request/turn remains a real call, siblings do not merge.
    $newParent=(Token '2026-10-05T02:00:00Z' 100 100)|ConvertFrom-Json; $newParent.payload|Add-Member request_id 'distinct-parent-request'
    $parentFrozen=$prepared.EndOffsets[$parentPath.ToLowerInvariant()]
    [IO.File]::AppendAllText($parentPath,($newParent|ConvertTo-Json -Depth 8 -Compress)+"`n",$utf8)
    $parentEnd=([IO.FileInfo]$parentPath).Length
    [void][TokenRaderIndexer]::ImportFile($db,$parentPath,$parentFrozen,$parentEnd,'parent','',300,$progress,$none)
    $cmd=$db.CreateCommand(); $cmd.CommandText="INSERT INTO file_metadata(path,length,last_write_ticks,parsed_offset,session_id,root_session_id,parent_thread_id) VALUES('sibling-old',100,0,100,'sibling-old','parent','parent'),('sibling-new',100,0,100,'sibling-new','parent','parent'); INSERT INTO recent_lineage_evidence(event_key,session_id,timestamp_ticks,source_path,source_offset_end) VALUES('parent|200:0:0:0:50:0:0:0','sibling-old',@ticks,'sibling-old',100); INSERT INTO token_records(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,call_input,call_cached,call_output,call_reasoning,source_path,source_offset_end,root_session_id) VALUES('sibling-new','2026-10-05T03:00:00Z','gpt-5.4',200,0,0,0,50,0,0,0,'sibling-new',100,'parent')"; [void]$cmd.Parameters.AddWithValue('@ticks',$cutoff.AddHours(-1).UtcDateTime.Ticks); [void]$cmd.ExecuteNonQuery(); $cmd.Dispose()
    $range=[TokenRaderIndexer]::AggregateTimeRangeRecords($db,$cutoff,$end,@{},$none,$null)
    Assert ($range.TotalInput-eq150) 'different same-session request and genuine sibling call survive old proof'
    # A same-session rewritten turn is also protected, independent of request ids.
    $cmd=$db.CreateCommand(); $cmd.CommandText="UPDATE recent_lineage_evidence SET request_id='',turn_id='old-turn' WHERE session_id='parent'; UPDATE token_records SET request_id='',turn_id='new-turn' WHERE session_id='parent'"; [void]$cmd.ExecuteNonQuery(); $cmd.Dispose()
    $range=[TokenRaderIndexer]::AggregateTimeRangeRecords($db,$cutoff,$end,@{},$none,$null)
    Assert ($range.TotalInput-eq150) 'different same-session turn survives proof'
    $iterations=0
    do { $history=[TokenRaderIndexer]::BackfillHistoryBatch($db,900,500,$progress,$none); $iterations++; Assert ($iterations-lt100) 'manual history backfill progresses' } while(-not $history.Completed -and $history.EligibleFiles-gt0)
    Assert $history.Completed 'explicit manual backfill imports older normal rows'
    $olderQuery=[TokenRaderIndexer]::AggregateTimeRangeRecords($db,$cutoff.AddHours(-2),$end,@{},$none,$null)
    Assert ($olderQuery.TotalInput-eq250) 'proof never suppresses later-imported normal canonical parent inside query range'
    $recentQuery=[TokenRaderIndexer]::AggregateTimeRangeRecords($db,$cutoff,$end,@{},$none,$null)
    Assert ($recentQuery.TotalInput-eq150) 'normal old parent and proof coexist without double suppression'
    $removed=[TokenRaderIndexer]::DeleteTokenRecordsBySessionId($db,'parent')
    Assert ($removed-eq2 -and (Scalar "SELECT COUNT(*) FROM recent_lineage_evidence WHERE session_id='parent'")-eq0) 'session delete clears applicable proof and preserves deleted token count API'
    $range=[TokenRaderIndexer]::AggregateTimeRangeRecords($db,$cutoff,$end,@{},$none,$null)
    Assert ($range.TotalInput-eq150) 'deleted parent proof cannot suppress later child'
    Write-Output 'Recent history indexer synthetic tests passed.'
}
finally {
    if($null-ne$db){$db.Close();$db.Dispose()}
    $resolved=[IO.Path]::GetFullPath($temp)
    Assert ($resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)) 'cleanup confined to synthetic temp root'
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
