[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll=Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-CompactedSynthetic-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$temp=[IO.Path]::GetFullPath((Get-Item -LiteralPath $temp).FullName)
$utf8=[Text.UTF8Encoding]::new($false)
$none=[Threading.CancellationToken]::None
$progress=[hashtable]::Synchronized(@{})
$end=[DateTimeOffset]::Parse('2026-10-05T12:00:00Z'); $cutoff=$end.AddHours(-24)
$db=$null
function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('COMPACTED STREAMING FAILED: '+$message) } }
function Scalar([string]$sql) {
    $cmd=$db.CreateCommand()
    try { $cmd.CommandText=$sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
}
function New-Fixture([string]$name,[string]$body) {
    if ($null-ne$script:db) { $script:db.Close(); $script:db.Dispose() }
    $script:db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $script:db.Open(); [TokenRaderIndexer]::CreateSchema($script:db)
    $script:fixtureRoot=Join-Path $temp $name; [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $script:path=Join-Path $fixtureRoot 'synthetic.jsonl'
    [IO.File]::WriteAllText($path,$body,$utf8); $script:frozen=([IO.FileInfo]$path).Length
}
function Import([long]$start=0,[long]$until=-1,$state=$null,[Threading.CancellationToken]$cancel=$none) {
    if ($until-lt0) { $until=([IO.FileInfo]$path).Length }
    return [TokenRaderIndexer]::ImportFile($db,$path,$start,$until,'synthetic-root','',1L,$state,$cancel)
}
function New-Compacted([string]$text,[string]$archiveText,[bool]$late=$false,[string]$latestMode='object',[string]$nullArchiveField='') {
    $latestField=if($latestMode-eq'null'){',"latest_token_usage_record":null'}elseif($latestMode-eq'omitted'){''}else{',"latest_token_usage_record":'+$script:latest}
    $archive='['+$script:archivedTool+','+$script:archivedImage+','+$script:archivedToken+',{"type":"message","text":"'+$archiveText+'"}]'
    $historyMetadata='[{"arbitrary_archive_field":"ARCHIVE_METADATA_SENTINEL","usage":{"anything":"opaque"}}]'
    $resume='{"arbitrary_resume_field":{"type":"input_image","image_url":"synthetic"}}'
    $retained='{"arbitrary_retained_field":{"type":"function_call","name":"archived-retained","call_id":"archived-retained-id"}}'
    if ($nullArchiveField-eq'all' -or $nullArchiveField-eq'replacement_history') { $archive='null' }
    if ($nullArchiveField-eq'all' -or $nullArchiveField-eq'replacement_history_metadata') { $historyMetadata='null' }
    if ($nullArchiveField-eq'all' -or $nullArchiveField-eq'resume_metadata') { $resume='null' }
    if ($nullArchiveField-eq'all' -or $nullArchiveField-eq'retained_context') { $retained='null' }
    $payload='"compaction_response_id":"synthetic-compaction","first_window_id":"synthetic-first","message":"'+$text+'","previous_window_id":"synthetic-previous","replacement_history":'+$archive+',"replacement_history_metadata":'+$historyMetadata+',"resume_metadata":'+$resume+',"retained_context":'+$retained+',"window_id":"synthetic-window","window_number":2'+$latestField
    if ($late) { return '{"payload":{'+$payload+'},"ordinal":1,"timestamp":"2026-10-05T02:00:00Z","type":"compacted"}' }
    return '{"timestamp":"2026-10-05T02:00:00Z","type":"compacted","ordinal":1,"payload":{'+$payload+'}}'
}
function Assert-Accounting {
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq2) 'only actual before/after token events are retained'
    Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'checkpoint/archive does not add billable tokens'
    Assert ((Scalar "SELECT call_input FROM token_records WHERE timestamp='2026-10-05T03:00:00Z'")-eq7) 'checkpoint never advances cumulative usage baseline'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE model='gpt-5.4' AND service_tier='priority'")-eq2) 'compaction cannot mutate model/tier context'
    Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'archived tools and images are not retained as new tool evidence'
    $tools=[TokenRaderIndexer]::AggregateToolUsage($db,$cutoff,$end)
    Assert ($tools.TotalToolCalls-eq0 -and $tools.InputImages-eq0 -and $tools.GeneratedImages-eq0 -and $tools.ComputerScreenshots-eq0) 'archived tool/image/screenshot metadata is not counted'
}
function Assert-State {
    foreach ($table in @('history_gaps','recent_history_work')) {
        $state=[string](Scalar ('SELECT COALESCE(MAX(body_scan_state),'''') FROM '+$table))
        Assert ($state.Length-le600) 'continuation metadata remains bounded'
        foreach ($sentinel in @('COMPACTION_BODY_SENTINEL','ARCHIVE_BODY_SENTINEL','ARCHIVE_METADATA_SENTINEL','ARCHIVED_COMMAND_SENTINEL','ARCHIVED_CWD_SENTINEL')) {
            Assert (-not $state.Contains($sentinel)) 'continuation never stores archived private values'
        }
    }
}
function Prepare([bool]$recent) {
    if ($recent) { [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff,$end,$progress,$none) }
    else { [void][TokenRaderIndexer]::InitializeFromNow($db,$fixtureRoot,$progress,$none) }
}
function Batch([bool]$recent,[long]$budget,$state=$progress,[Threading.CancellationToken]$cancel=$none) {
    if ($recent) { return [TokenRaderIndexer]::BackfillRecentHistoryBatch($db,$budget,5000,$state,$cancel) }
    return [TokenRaderIndexer]::BackfillHistoryBatch($db,$budget,5000,$state,$cancel)
}
function Complete([bool]$recent,[long]$budget) {
    for ($i=0;$i-lt100;$i++) {
        $script:batch=Batch $recent $budget
        Assert ($batch.ProcessedBytes-ge0 -and $batch.ProcessedBytes-le$budget) 'each batch obeys byte budget'
        Assert-State
        if ($batch.Completed -or $batch.EligibleFiles-eq0) { return }
        Assert ($batch.ProcessedBytes-gt0) 'unfinished historical scan progresses'
    }
    throw 'Compacted synthetic history did not finish bounded work'
}
function Reject([long]$start=0,[long]$until=-1) {
    $failure=$null
    try { [void](Import $start $until) } catch { $failure=$_.Exception.ToString() }
    Assert (-not [string]::IsNullOrWhiteSpace($failure)) 'unsafe/incomplete compacted record is rejected'
    foreach ($sentinel in @('COMPACTION_BODY_SENTINEL','ARCHIVE_BODY_SENTINEL','ARCHIVED_COMMAND_SENTINEL','ARCHIVED_CWD_SENTINEL')) {
        Assert (-not $failure.Contains($sentinel)) 'diagnostic does not expose synthetic private values'
    }
}
function Replace($state=$null,[Threading.CancellationToken]$cancel=$none) {
    $length=([IO.FileInfo]$path).Length
    return [TokenRaderIndexer]::ReplaceFile($db,$path,$length,$oldSession,$length,456L,$oldSession,'new-cwd','','','synthetic-root',2L,$state,$cancel)
}
function Seed-Replacement([string]$name) {
    $tool='{"timestamp":"2026-10-05T01:30:00Z","type":"response_item","payload":{"type":"function_call","name":"synthetic-live-tool","call_id":"synthetic-live-call"}}'
    New-Fixture $name ($script:context+"`n"+$script:firstToken+"`n"+$tool+"`n")
    Assert ((Import)-eq1) 'seed prior replacement usage'
    $script:oldSession=[string](Scalar 'SELECT session_id FROM token_records')
    [TokenRaderIndexer]::UpdateFileMetadata($db,$path,$frozen,123L,$frozen,$oldSession,'old-cwd','','','synthetic-root')
    $script:oldCatalog=[string](Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||cwd||'|'||turn_context_model||'|'||turn_context_service_tier FROM file_metadata")
}
function Assert-ReplacementPreserved {
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1 -and (Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) 'failed replacement retains prior numeric rows'
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE call_key='synthetic-live-call'")-eq1) 'failed replacement retains prior live tool evidence'
    Assert ((Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||cwd||'|'||turn_context_model||'|'||turn_context_service_tier FROM file_metadata")-eq$oldCatalog) 'failed replacement retains catalog/cursor/context'
}
try {
    $context='{"timestamp":"2026-10-05T00:30:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $firstToken='{"timestamp":"2026-10-05T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}'
    $nextToken=$firstToken.Replace('01:00:00Z','03:00:00Z').Replace('"total_token_usage":{"input_tokens":7','"total_token_usage":{"input_tokens":14')
    # A total-only after event is essential: a last=7 value could conceal an
    # incorrectly advanced checkpoint baseline by falling back after a reset.
    $nextToken=$nextToken.Replace('"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},','')
    $usage='{"input_tokens":999999,"cached_input_tokens":17,"output_tokens":23,"reasoning_output_tokens":3,"total_tokens":1000022,"cache_write_input_tokens":19}'
    $latest='{"response_id":"synthetic-response","root_turn_id":"synthetic-root-turn","session_id":"synthetic-session","thread_id":"synthetic-thread","turn_id":"synthetic-turn","thread_token_usage":'+$usage+',"turn_token_usage":'+$usage+',"usage":'+$usage+'}'
    $checkpoint='{"timestamp":"2026-10-05T01:45:00Z","type":"token_usage_record","payload":'+$latest+'}'
    $archivedToken=$firstToken.Replace('"input_tokens":7','"input_tokens":999999')
    $archivedTool='{"type":"response_item","payload":{"type":"function_call","name":"archived-tool","call_id":"archived-call","arguments":"ARCHIVED_COMMAND_SENTINEL","cwd":"ARCHIVED_CWD_SENTINEL"}}'
    $archivedImage='{"type":"input_image","image_url":"synthetic","other":{"type":"computer_screenshot"}}'
    # Keep the source ASCII for Windows PowerShell 5.1; runtime characters also
    # exercise raw UTF-8 continuation alongside JSON escapes and fake markers.
    $unicode=([string][char]0x96ea)+[char]::ConvertFromUtf32(0x1F600)
    $escaped='COMPACTION_BODY_SENTINEL \\ \n \t \"type\":\"token_count\" \u96ea \ud83d\ude00 '+$unicode
    $huge=('x'*(2*1024*1024))+$escaped
    $small=New-Compacted $escaped 'ARCHIVE_BODY_SENTINEL'
    $giant=New-Compacted $huge 'ARCHIVE_BODY_SENTINEL'
    $archiveGiant=New-Compacted $escaped ('ARCHIVE_BODY_SENTINEL'+$huge) $true
    $late=New-Compacted $huge 'ARCHIVE_BODY_SENTINEL' $true
    foreach ($record in @($small,$giant,$archiveGiant,$late,(New-Compacted $huge '' $false 'null'),(New-Compacted $huge '' $true 'omitted'))) {
        foreach ($newline in @("`n","`r`n")) {
            New-Fixture ([guid]::NewGuid().ToString('N')) ($context+$newline+$firstToken+$newline+$checkpoint+$newline+$record+$newline+$nextToken+$newline)
            Assert ((Import)-eq2) 'small/giant checkpoint/archive preserves exact token semantics'
            Assert-Accounting
            Assert ((Scalar 'SELECT MAX(source_offset_end) FROM token_records')-eq$frozen) 'precise UTF-8 endpoint includes LF/CRLF'
            Assert ((Import)-eq0) 'same frozen checkpoint/archive retry is idempotent'
            Assert-Accounting
        }
    }
    # Explicit null means no archive; unknown or invalid non-null data remains
    # rejected. Cover each archive independently, plus all four together.
    foreach ($field in @('replacement_history','replacement_history_metadata','resume_metadata','retained_context','all')) {
        foreach ($text in @($escaped,$huge)) {
            $record=New-Compacted $text 'ARCHIVE_BODY_SENTINEL' $true 'object' $field
            New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$firstToken+"`n"+$checkpoint+"`n"+$record+"`n"+$nextToken+"`n")
            Assert ((Import)-eq2) 'explicit null archive means no archive, not new accounting evidence'
            Assert-Accounting
            New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$firstToken+"`n"+$record+"`n"+$nextToken+"`n")
            Prepare $true; Complete $true (256*1024)
            Assert $batch.Completed 'explicit-null archive remains safely classifiable across bounded history'
            Assert-Accounting
        }
    }
    $keywordTool='{"timestamp":"2026-10-05T02:00:00Z","type":"response_item","payload":{"type":"function_call","name":"synthetic-keyword-tool","call_id":"synthetic-keyword-call","arguments":"compacted replacement_history latest_token_usage_record \"type\":\"compacted\""}}'
    $keywordToken=$nextToken.Replace('"info":{','"note":"compacted replacement_history latest_token_usage_record","info":{')
    New-Fixture 'ordinary-events-with-compacted-keywords' ($context+"`n"+$firstToken+"`n"+$keywordTool+"`n"+$keywordToken+"`n")
    Assert ((Import)-eq2) 'ordinary token_count mentioning compacted is not swallowed'
    Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'ordinary total-only token_count retains its original baseline'
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE call_key='synthetic-keyword-call' AND tool_name='synthetic-keyword-tool'")-eq1) 'ordinary function arguments mentioning compacted remain normal tool evidence'
    foreach ($record in @($small,$giant,$archiveGiant)) {
        New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$firstToken+"`n"+$record+"`n"+$nextToken+"`n")
        Assert ((Import)-eq2) 'seed numeric metadata for tool-only rescan'
        $cmd=$db.CreateCommand()
        try {
            $cmd.CommandText='UPDATE file_metadata SET content_retained=1,last_write_ticks=@ticks'
            [void]$cmd.Parameters.AddWithValue('@ticks',$end.UtcDateTime.Ticks)
            [void]$cmd.ExecuteNonQuery()
        } finally { $cmd.Dispose() }
        $toolBackfill=[TokenRaderIndexer]::BackfillRecentToolRecords($db,$cutoff.UtcDateTime.Ticks,2L,$none,$progress)
        Assert ($toolBackfill.CandidateFiles-eq1 -and $toolBackfill.ProcessedFiles-eq1) 'tool-only backfill actually scans the synthetic source'
        Assert ($toolBackfill.DetectedRecords-eq0) 'tool-only backfill does not discover archived tool/image events'
        Assert-Accounting
    }
    foreach ($recent in @($true,$false)) {
        foreach ($record in @($giant,$archiveGiant,$late)) {
            foreach ($budget in @((256*1024),(1024*1024+65536),(3*1024*1024))) {
                New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$firstToken+"`n"+$checkpoint+"`n"+$record+"`n"+$nextToken+"`n")
                Prepare $recent; Complete $recent $budget
                Assert $batch.Completed 'known compacted archive completes bounded history'
                Assert-Accounting
                $table=if($recent){'recent_history_work'}else{'history_gaps'}
                Assert ((Scalar ('SELECT cursor_offset FROM '+$table+' LIMIT 1'))-eq$frozen) 'history retains frozen endpoint'
            }
        }
    }
    # Before the root type is known, all classifiers can still be viable. Their
    # combined continuation must be resumable and bounded even at one byte.
    foreach ($budget in @(1L,8L,25L)) {
        New-Fixture ([guid]::NewGuid().ToString('N')) ($giant+"`n"+$context+"`n"+$firstToken+"`n"+$nextToken+"`n")
        Prepare $true; $first=Batch $true $budget
        Assert ($first.ProcessedBytes-eq$budget -and -not $first.Completed) 'tiny unresolved-envelope batch obeys exact budget'
        Assert (-not [string]::IsNullOrWhiteSpace([string](Scalar 'SELECT body_scan_state FROM recent_history_work'))) 'tiny batch saves viable classifier continuation'
        Assert-State
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'unresolved root cannot emit numeric or tool evidence'
        Complete $true (256*1024)
        Assert $batch.Completed 'combined classifier continuation resumes from tiny batch'
        Assert-Accounting
    }
    $boundaryRecord=New-Compacted $escaped ('ARCHIVE_BODY_SENTINEL'+$huge)
    $escapeBoundary=$utf8.GetByteCount($boundaryRecord.Substring(0,$boundaryRecord.IndexOf('\u96ea',[StringComparison]::Ordinal)))+3L
    $utf8Boundary=$utf8.GetByteCount($boundaryRecord.Substring(0,$boundaryRecord.IndexOf($unicode,[StringComparison]::Ordinal)))+1L
    foreach ($boundary in @($escapeBoundary,$utf8Boundary)) {
        New-Fixture ([guid]::NewGuid().ToString('N')) ($boundaryRecord+"`n"+$context+"`n"+$firstToken+"`n"+$nextToken+"`n")
        Prepare $true; $first=Batch $true $boundary
        Assert ($first.ProcessedBytes-eq$boundary -and -not $first.Completed) 'escape/UTF-8 split commits only bounded parsing state'
        Assert-State
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'partial archive proof emits no accounting metadata'
        [IO.File]::AppendAllText($path,$archivedTool+"`n",$utf8)
        Complete $true (256*1024); Assert $batch.Completed 'escape/UTF-8 continuation resumes'
        Assert-Accounting
        Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$frozen) 'resumed proof does not chase appended live events'
    }
    $reject=@{
        rootUnknown=$giant.Replace('"ordinal":1,','"ordinal":1,"unknown":0,')
        rootDuplicate=$giant.Replace('"ordinal":1,','"ordinal":1,"type":"compacted",')
        payloadUnknown=$giant.Replace('"window_number":2','"window_number":2,"unknown":0')
        payloadDuplicate=$giant.Replace('"window_number":2','"window_number":2,"message":"duplicate"')
        latestUnknown=$giant.Replace('"response_id":"synthetic-response"','"response_id":"synthetic-response","unknown":0')
        latestDuplicate=$giant.Replace('"response_id":"synthetic-response"','"response_id":"synthetic-response","response_id":"duplicate"')
        usageUnknown=$giant.Replace('"cached_input_tokens":17','"cached_input_tokens":17,"unknown":0')
        usageDuplicate=$giant.Replace('"cached_input_tokens":17','"cached_input_tokens":17,"input_tokens":0')
        usageNegative=$giant.Replace('"cached_input_tokens":17','"cached_input_tokens":-1')
        usageFraction=$giant.Replace('"cached_input_tokens":17','"cached_input_tokens":1.5')
        usageOverflow=$giant.Replace('"cached_input_tokens":17','"cached_input_tokens":999999999999999999999999999999')
        usageNull=$giant.Replace('"cached_input_tokens":17','"cached_input_tokens":null')
        invalidEscape=$giant.Replace($escaped,($escaped+'\q'))
        malformedArchive=$giant.Replace('"replacement_history":[','"replacement_history":[,')
        trailingJson=$giant+'{}'
    }
    foreach ($name in $reject.Keys) {
        New-Fixture ('reject-'+$name) ($context+"`n"+$firstToken+"`n")
        Assert ((Import)-eq1) 'seed committed usage before unsafe compacted event'
        $start=$frozen
        [IO.File]::AppendAllText($path,$nextToken+"`n"+$reject[$name]+"`n",$utf8)
        Reject $start
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7 -and (Scalar 'SELECT COUNT(*) FROM token_records')-eq1) ($name+' atomically rolls back new numeric rows')
        Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-eq$start -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) ($name+' preserves committed cursor and emits no archived metadata')
        New-Fixture ('history-reject-'+$name) ($reject[$name]+"`n"+$context+"`n"+$firstToken+"`n")
        Prepare $true; Complete $true (256*1024)
        Assert (-not $batch.Completed -and $batch.BlockedFiles-eq1) ($name+' keeps explicit historical coverage block')
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) ($name+' does not erase following valid usage or fabricate archive tool rows')
    }
    $smallReject=@{
        duplicate=$small.Replace('"ordinal":1,','"ordinal":1,"type":"compacted",')
        unknown=$small.Replace('"window_number":2','"window_number":2,"unknown":0')
        invalidUsage=$small.Replace('"cached_input_tokens":17','"cached_input_tokens":-1')
    }
    foreach ($name in $smallReject.Keys) {
        New-Fixture ('small-reject-'+$name) ($context+"`n"+$firstToken+"`n")
        Assert ((Import)-eq1) 'seed prior numeric rows before small malformed compacted'
        $start=$frozen
        [IO.File]::AppendAllText($path,$nextToken+"`n"+$smallReject[$name]+"`n",$utf8)
        Reject $start
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7 -and (Scalar 'SELECT parsed_offset FROM file_metadata')-eq$start) ($name+' small malformed compacted uses the same safe rollback semantics')
        Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) ($name+' small malformed archive cannot leak tool/image rows')
        New-Fixture ('small-history-reject-'+$name) ($smallReject[$name]+"`n"+$context+"`n"+$firstToken+"`n")
        Prepare $true; Complete $true (256*1024)
        Assert (-not $batch.Completed -and $batch.BlockedFiles-eq1) ($name+' small malformed historical archive cannot claim coverage')
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) ($name+' small rejected history retains only actual following numeric rows')
    }
    New-Fixture 'frozen-half-line' ($context+"`n"+$firstToken+"`n"+$giant+"`n")
    Reject 0 ($utf8.GetByteCount($context+"`n"+$firstToken+"`n")+1024*1024+65536)
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM file_metadata')-eq0) 'frozen half-line rolls back all new rows/cursor'
    Assert ((Import)-eq1) 'complete-line retry recovers frozen half-line'
    foreach ($recent in @($true,$false)) {
        New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$firstToken+"`n"+$archiveGiant)
        Prepare $recent; Complete $recent (256*1024)
        Assert (-not $batch.Completed -and $batch.BlockedFiles-eq1) 'complete compacted JSON without EOL cannot claim coverage'
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'unfinished archive retains preceding real usage only'
    }
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Threading;
public sealed class CompactedSyntheticCancelProgress : Hashtable {
    public CancellationTokenSource Source; public long Threshold;
    public CompactedSyntheticCancelProgress(CancellationTokenSource source, long threshold) { Source=source; Threshold=threshold; }
    public override object this[object key] {
        get { return base[key]; }
        set { base[key]=value; if (Convert.ToString(key)=="CurrentOffset" && Convert.ToInt64(value)>=Threshold) Source.Cancel(); }
    }
}
'@
    New-Fixture 'cancel-live' ($context+"`n"+$firstToken+"`n"+$archiveGiant+"`n")
    $cts=[Threading.CancellationTokenSource]::new(); $cancelProgress=[CompactedSyntheticCancelProgress]::new($cts,(1024*1024+65536))
    try {
        $failure=$null; try { [void](Import 0 -1 $cancelProgress $cts.Token) } catch { $failure=$_.Exception.ToString() }
        Assert ($null-ne$failure -and $failure.Contains('OperationCanceledException')) 'live archive cancellation propagates'
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM file_metadata')-eq0 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'live cancellation atomically restores all metadata/cursor'
    } finally { $cts.Dispose() }
    Assert ((Import)-eq1) 'cancelled archive retries safely'
    New-Fixture 'cancel-history' ($archiveGiant+"`n"+$context+"`n"+$firstToken+"`n")
    Prepare $true; [void](Batch $true (256*1024))
    $cursor=[long](Scalar 'SELECT cursor_offset FROM recent_history_work'); $saved=[string](Scalar 'SELECT body_scan_state FROM recent_history_work')
    $cts=[Threading.CancellationTokenSource]::new(); $cancelProgress=[CompactedSyntheticCancelProgress]::new($cts,($cursor+65536))
    try {
        $failure=$null; try { [void](Batch $true (256*1024) $cancelProgress $cts.Token) } catch { $failure=$_.Exception.ToString() }
        Assert ($null-ne$failure -and $failure.Contains('OperationCanceledException')) 'history archive cancellation propagates'
        Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$cursor -and (Scalar 'SELECT body_scan_state FROM recent_history_work')-eq$saved) 'cancelled history restores cursor and scanner state'
    } finally { $cts.Dispose() }
    Complete $true (256*1024); Assert $batch.Completed 'cancelled archive history resumes'
    Seed-Replacement 'replacement-reject'
    [IO.File]::WriteAllText($path,$nextToken+"`n"+$reject['usageUnknown']+"`n",$utf8)
    $failure=$null; try { [void](Replace) } catch { $failure=$_.Exception.ToString() }
    Assert (-not [string]::IsNullOrWhiteSpace($failure)) 'unsafe replacement rejects'; Assert-ReplacementPreserved
    Seed-Replacement 'replacement-cancel'
    [IO.File]::WriteAllText($path,$nextToken+"`n"+$archiveGiant+"`n",$utf8)
    $cts=[Threading.CancellationTokenSource]::new(); $cancelProgress=[CompactedSyntheticCancelProgress]::new($cts,(1024*1024+65536))
    try {
        $failure=$null; try { [void](Replace $cancelProgress $cts.Token) } catch { $failure=$_.Exception.ToString() }
        Assert ($null-ne$failure -and $failure.Contains('OperationCanceledException')) 'replacement cancellation propagates'; Assert-ReplacementPreserved
    } finally { $cts.Dispose() }
    Assert ((Replace)-eq1) 'cancelled replacement retries atomically'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'successful replacement has only actual new usage'
    Write-Output 'Compacted streaming synthetic tests passed.'
}
finally {
    if ($null-ne$db) { $db.Close(); $db.Dispose() }
    $resolved=[IO.Path]::GetFullPath($temp)
    $prefix=[IO.Path]::GetFullPath((Get-Item -LiteralPath ([IO.Path]::GetTempPath())).FullName).TrimEnd('\')+'\TokenRader-CompactedSynthetic-'
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
