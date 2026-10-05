[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll=Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-IncrementalOversizedSynthetic-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$utf8=[Text.UTF8Encoding]::new($false)
$none=[Threading.CancellationToken]::None
$db=$null
function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('INCREMENTAL OVERSIZED FAILED: '+$message) } }
function Scalar([string]$sql) { $cmd=$db.CreateCommand(); try { $cmd.CommandText=$sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() } }
function Sql([string]$sql) { $cmd=$db.CreateCommand(); try { $cmd.CommandText=$sql; [void]$cmd.ExecuteNonQuery() } finally { $cmd.Dispose() } }
function New-Fixture([string]$name,[string]$body) {
    if($null-ne$script:db){$script:db.Close();$script:db.Dispose()}
    $script:db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $script:db.Open(); [TokenRaderIndexer]::CreateSchema($script:db)
    $dir=Join-Path $temp $name; [void][IO.Directory]::CreateDirectory($dir)
    $script:path=Join-Path $dir 'synthetic.jsonl'
    [IO.File]::WriteAllText($path,$body,$utf8)
    $script:frozen=([IO.FileInfo]$path).Length
}
function Import([long]$start=0,[long]$end=-1,$progress=$null,[Threading.CancellationToken]$cancel=$none) {
    if($end-lt0){$end=([IO.FileInfo]$path).Length}
    return [TokenRaderIndexer]::ImportFile($db,$path,$start,$end,'synthetic-root','',1L,$progress,$cancel)
}
function Reject([long]$start=0,[long]$end=-1) {
    try { [void](Import $start $end); throw 'missing rejection' }
    catch { Assert ($_.Exception.ToString().Contains('Oversized usage/context line')) ('unsafe oversized input must reject: '+$_.Exception.ToString()) }
}
function Replace($progress=$null,[Threading.CancellationToken]$cancel=$none) {
    $length=([IO.FileInfo]$path).Length
    return [TokenRaderIndexer]::ReplaceFile($db,$path,$length,$oldSession,$length,456L,$oldSession,'new-cwd','','','synthetic-root',2L,$progress,$cancel)
}
function New-ReplacementFixture([string]$name) {
    New-Fixture $name ($script:context+"`n"+$script:token+"`n")
    Assert ((Import)-eq1) 'seed replacement with prior valid token'
    $script:oldSession=[string](Scalar 'SELECT session_id FROM token_records')
    [TokenRaderIndexer]::UpdateFileMetadata($db,$path,$frozen,123L,$frozen,$oldSession,'old-cwd','','','synthetic-root')
    $cmd=$db.CreateCommand()
    try {
        $cmd.CommandText="INSERT INTO tool_records(event_key,source_path,session_id) VALUES('old-tool',@path,@session); INSERT INTO recent_lineage_evidence(event_key,session_id,timestamp_ticks,source_path,source_offset_end) VALUES('old-lineage',@session,1,@path,1); UPDATE file_metadata SET fast_baseline_offset=1,fast_baseline_input=99 WHERE path=@path"
        [void]$cmd.Parameters.AddWithValue('@path',$path); [void]$cmd.Parameters.AddWithValue('@session',$oldSession)
        [void]$cmd.ExecuteNonQuery()
    } finally { $cmd.Dispose() }
    $script:oldMetadata=[string](Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||cwd||'|'||turn_context_model||'|'||turn_context_service_tier||'|'||fast_baseline_offset||'|'||fast_baseline_input FROM file_metadata")
}
function Assert-ReplacementPreserved([string]$reason) {
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1 -and (Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) ($reason+' preserves prior tokens')
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE event_key='old-tool'")-eq1) ($reason+' preserves prior tool metadata')
    Assert ((Scalar "SELECT COUNT(*) FROM recent_lineage_evidence WHERE event_key='old-lineage'")-eq1) ($reason+' preserves prior lineage')
    Assert ((Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||cwd||'|'||turn_context_model||'|'||turn_context_service_tier||'|'||fast_baseline_offset||'|'||fast_baseline_input FROM file_metadata")-eq$oldMetadata) ($reason+' preserves old catalog, cursor, context and baseline')
}
try {
    $context='{"timestamp":"2026-10-05T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $token='{"timestamp":"2026-10-05T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}'
    $nextToken=$token.Replace('02:00:00Z','03:00:00Z').Replace('"total_token_usage":{"input_tokens":7','"total_token_usage":{"input_tokens":14')
    $huge=('x'*(2*1024*1024))+' 雪😀 \\ \n \u1234 \"type\":\"event_msg\"'
    $safe='{"timestamp":"2026-10-05T01:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"'+$huge+'"}]}}'
    $late='{"payload":{"content":[{"text":"'+$huge+'","type":"output_text"}],"role":"user","type":"message"},"type":"response_item","timestamp":"2026-10-05T01:00:00Z"}'
    foreach($body in @($safe,$late)) {
        foreach($newline in @("`n","`r`n")) {
            New-Fixture ([guid]::NewGuid().ToString('N')) ($body+$newline+$context+$newline+$token+$newline)
            Assert ((Import)-eq1) 'validated huge message allows following usage'
            Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) 'following usage is exact'
            Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE model='gpt-5.4' AND service_tier='priority'")-eq1) 'following model and tier survive'
            Assert ((Scalar 'SELECT source_offset_end FROM token_records')-eq$frozen) 'UTF-8 source offset includes exact LF/CRLF'
            Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-eq$frozen) 'complete safe import retains exact end'
            Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'text does not create tool records'
            Assert ((Import)-eq0) 'same safe import retry is idempotent'
            [IO.File]::AppendAllText($path,$nextToken+$newline,$utf8)
            Assert ((Import 0 $frozen)-eq0) 'frozen endpoint excludes an appended token'
            Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1) 'frozen retry never chases live append'
            Assert ((Import $frozen)-eq1) 'next incremental segment imports appended token'
            Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'append uses original cumulative baseline'
        }
    }

    $reject=@{
        tool='{"type":"response_item","payload":{"type":"function_call","name":"synthetic_tool","arguments":"'+$huge+'"}}'
        image=$safe.Replace('"type":"output_text"','"type":"input_image"')
        lateImage=$safe.Replace('"}]}}','"},{"type":"input_image","image_url":"synthetic"}]}}')
        usage=$safe.Replace('"}]}}','"}]},"usage":{"input_tokens":7}}')
        context='{"type":"turn_context","payload":{"model":"gpt-5.4","padding":"'+$huge+'"}}'
        unknown=$safe.Replace('"}]}}','"}],"unknown":true}}')
        duplicate=$safe.Replace('"}]}}','"}]},"type":"event_msg"}')
        routed=$safe.Replace('"role":"assistant"','"role":"assistant","recipient":"functions.synthetic_tool"')
        malformed=$safe+'{}'
        missingRole=$safe.Replace('"role":"assistant",','')
    }
    foreach($name in $reject.Keys) {
        New-Fixture ('reject-'+$name) ($context+"`n"+$token+"`n")
        Assert ((Import)-eq1) 'seed valid metadata before failing segment'
        $start=$frozen
        # A valid row before the unsafe record must be rolled back with it.
        [IO.File]::AppendAllText($path,$nextToken+"`n"+$reject[$name]+"`n"+$context+"`n",$utf8)
        Reject $start
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1) ($name+' transaction rolls back earlier token insert')
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) ($name+' preserves prior valid totals')
        Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-eq$start) ($name+' does not advance committed cursor')
        Assert ((Scalar "SELECT turn_context_model FROM file_metadata")-eq'gpt-5.4') ($name+' preserves prior context')
        Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) ($name+' does not partially insert tool metadata')
        Reject $start
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1) ($name+' repeated retry is idempotent')
    }

    New-Fixture 'incomplete-frozen' ($context+"`n"+$token+"`n"+$late+"`n")
    $partial=$utf8.GetByteCount($context+"`n"+$token+"`n")+1024*1024+65536
    Reject 0 $partial
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0) 'incomplete oversized proof rolls back preceding valid row'
    Assert ((Scalar 'SELECT COUNT(*) FROM file_metadata')-eq0) 'incomplete oversized proof cannot seed an advanced cursor'
    Assert ((Import)-eq1) 'full-line retry recovers frozen partial proof'

    # Cancellation is triggered by actual reader progress, not a timing race.
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Threading;
public sealed class IncrementalOversizedCancelProgress : Hashtable {
    public CancellationTokenSource Source;
    public long Threshold;
    public IncrementalOversizedCancelProgress(CancellationTokenSource source, long threshold) { Source=source; Threshold=threshold; }
    public override object this[object key] {
        get { return base[key]; }
        set { base[key]=value; if (Convert.ToString(key)=="CurrentOffset" && Convert.ToInt64(value)>=Threshold) Source.Cancel(); }
    }
}
'@
    New-Fixture 'cancel' ($context+"`n"+$token+"`n"+$late+"`n")
    $cts=[Threading.CancellationTokenSource]::new()
    $progress=[IncrementalOversizedCancelProgress]::new($cts,(1024*1024+65536))
    try { [void](Import 0 -1 $progress $cts.Token); throw 'missing cancellation' }
    catch { Assert ($_.Exception.ToString().Contains('OperationCanceledException')) 'in-file cancellation propagates' }
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0) 'cancel rolls back prior token row'
    Assert ((Scalar 'SELECT COUNT(*) FROM file_metadata')-eq0) 'cancel does not advance cursor'
    $cts.Dispose()
    Assert ((Import)-eq1) 'retry after cancellation imports safely'
    Assert ((Import)-eq0) 'retry after cancellation remains idempotent'

    New-ReplacementFixture 'replacement-reject'
    [IO.File]::WriteAllText($path,$nextToken+"`n"+$reject['lateImage']+"`n",$utf8)
    for($i=0;$i-lt2;$i++) {
        try { [void](Replace); throw 'missing replacement rejection' }
        catch { Assert ($_.Exception.ToString().Contains('Oversized usage/context line')) 'replacement rejects unsafe giant' }
        Assert-ReplacementPreserved 'unsafe replacement retry'
    }
    [IO.File]::WriteAllText($path,$nextToken+"`n",$utf8)
    Assert ((Replace)-eq1) 'valid replacement commits one new token'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1) 'valid replacement replaces, not appends'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE timestamp='2026-10-05T03:00:00Z' AND model='' AND service_tier=''")-eq1) 'replacement does not inherit prior model or tier'
    Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM recent_lineage_evidence')-eq0) 'valid replacement deletes obsolete tool and lineage metadata'
    Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-eq([IO.FileInfo]$path).Length -and (Scalar 'SELECT cwd FROM file_metadata')-eq'new-cwd') 'valid replacement atomically updates catalog'
    Assert ((Scalar 'SELECT fast_baseline_input FROM file_metadata')-is[DBNull]) 'valid replacement clears obsolete fast-start baseline'

    New-ReplacementFixture 'replacement-cancel'
    [IO.File]::WriteAllText($path,$nextToken+"`n"+$late+"`n",$utf8)
    $cts=[Threading.CancellationTokenSource]::new()
    $progress=[IncrementalOversizedCancelProgress]::new($cts,(1024*1024+65536))
    try { [void](Replace $progress $cts.Token); throw 'missing replacement cancellation' }
    catch { Assert ($_.Exception.ToString().Contains('OperationCanceledException')) 'replacement in-file cancellation propagates' }
    $cts.Dispose(); Assert-ReplacementPreserved 'cancelled replacement'
    Assert ((Replace)-eq1) 'cancelled replacement can retry safely'

    New-ReplacementFixture 'replacement-catalog-failure'
    Sql "CREATE TRIGGER fail_replacement_catalog BEFORE UPDATE OF cwd ON file_metadata BEGIN SELECT RAISE(ABORT,'synthetic replacement catalog failure'); END"
    [IO.File]::WriteAllText($path,$nextToken+"`n",$utf8)
    try { [void](Replace); throw 'missing catalog failure' }
    catch { Assert ($_.Exception.ToString().Contains('synthetic replacement catalog failure')) 'forced post-import catalog failure propagates' }
    Assert-ReplacementPreserved 'failed catalog update'
    Sql 'DROP TRIGGER fail_replacement_catalog'
    Assert ((Replace)-eq1) 'catalog failure retries after cause removed'

    foreach($table in @('token_records','tool_records')) {
        New-ReplacementFixture ('replacement-insert-failure-'+$table)
        Sql ("CREATE TRIGGER fail_replacement_insert BEFORE INSERT ON "+$table+" BEGIN SELECT RAISE(ABORT,'synthetic replacement insert failure'); END")
        $tool='{"timestamp":"2026-10-05T04:00:00Z","type":"response_item","payload":{"type":"function_call","name":"synthetic_tool","call_id":"new-tool","arguments":"{}"}}'
        [IO.File]::WriteAllText($path,$context+"`n"+$nextToken+"`n"+$tool+"`n",$utf8)
        try { [void](Replace); throw 'missing insert failure' }
        catch { Assert ($_.Exception.ToString().Contains('synthetic replacement insert failure')) ($table+' insertion failure aborts replacement') }
        Assert-ReplacementPreserved ($table+' insertion failure')
        Sql 'DROP TRIGGER fail_replacement_insert'
        Assert ((Replace)-eq1) ($table+' replacement retry commits valid multiline input')
        Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq1) 'successful multiline replacement preserves new tool metadata'
    }

    New-ReplacementFixture 'replacement-empty'
    [IO.File]::WriteAllText($path,'',$utf8)
    Assert ((Replace)-eq0) 'empty replacement commits zero usage rows'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM recent_lineage_evidence')-eq0) 'empty replacement clears obsolete metadata atomically'
    Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-eq0 -and (Scalar 'SELECT length FROM file_metadata')-eq0) 'empty replacement resets catalog cursor'
    Assert ((Scalar 'SELECT turn_context_model FROM file_metadata')-eq'' -and (Scalar 'SELECT turn_context_service_tier FROM file_metadata')-eq'') 'empty replacement clears trailing context'
    Assert ((Scalar 'SELECT fast_baseline_input FROM file_metadata')-is[DBNull]) 'empty replacement clears stale cumulative baseline'

    New-ReplacementFixture 'replacement-no-complete-line'
    [IO.File]::WriteAllText($path,$nextToken,$utf8)
    try { [void][TokenRaderIndexer]::ReplaceFile($db,$path,0L,$oldSession,([IO.FileInfo]$path).Length,456L,$oldSession,'new-cwd','','','synthetic-root',2L,$null,$none); throw 'missing unfinished rejection' }
    catch { Assert ($_.Exception.ToString().Contains('no complete JSONL line')) 'nonempty unfinished replacement cannot erase prior index' }
    Assert-ReplacementPreserved 'unfinished replacement'

    New-ReplacementFixture 'replacement-stale-overlong-boundary'
    [IO.File]::WriteAllText($path,$nextToken+"`n",$utf8)
    $actual=([IO.FileInfo]$path).Length
    try { [void][TokenRaderIndexer]::ReplaceFile($db,$path,($actual+100L),$oldSession,($actual+100L),456L,$oldSession,'new-cwd','','','synthetic-root',2L,$null,$none); throw 'missing stale boundary rejection' }
    catch { Assert ($_.Exception.ToString().Contains('shrank before its frozen boundary')) 'stale boundary past current EOF rejects replacement' }
    Assert-ReplacementPreserved 'stale frozen boundary'

    New-ReplacementFixture 'replacement-source-guard'
    $cmd=$db.CreateCommand()
    try {
        $cmd.CommandText="INSERT INTO history_gaps(path,start_offset,end_offset,cursor_offset,blocked_reason) VALUES(@path,0,@end,0,'source_replaced')"
        [void]$cmd.Parameters.AddWithValue('@path',$path); [void]$cmd.Parameters.AddWithValue('@end',$frozen); [void]$cmd.ExecuteNonQuery()
    } finally { $cmd.Dispose() }
    [IO.File]::WriteAllText($path,$context+"`n"+$nextToken+"`n",$utf8)
    try { [void](Replace); throw 'missing source replacement guard' }
    catch { Assert ($_.Exception.ToString().Contains('retained history cannot be mixed')) 'source replacement guard remains authoritative' }
    Assert-ReplacementPreserved 'source replacement guard'

    foreach($malformed in @('{"type":"event_msg","payload":{"type":"token_count",BROKEN}}','{"type":"turn_context",BROKEN}','{"type":"response_item","payload":{"type":"function_call",BROKEN}}')) {
        New-ReplacementFixture ('replacement-malformed-'+[guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($path,$nextToken+"`n"+$malformed+"`n",$utf8)
        try { [void](Replace); throw 'missing malformed replacement rejection' }
        catch { Assert ($_.Exception.ToString().Contains('Malformed replacement')) 'malformed metadata-bearing replacement aborts atomically' }
        Assert-ReplacementPreserved 'malformed replacement metadata'
    }

    Write-Output 'Incremental oversized indexer synthetic tests passed.'
}
finally {
    if($null-ne$db){$db.Close();$db.Dispose()}
    $resolved=[IO.Path]::GetFullPath($temp)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\TokenRader-IncrementalOversizedSynthetic-'
    if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
