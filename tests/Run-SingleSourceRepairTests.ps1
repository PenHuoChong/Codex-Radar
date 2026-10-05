[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if([string]::IsNullOrWhiteSpace($IndexerDll)){$IndexerDll=Join-Path $root 'indexer\TokenRader.Indexer.dll'}
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-SingleSourceRepairSynthetic-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$temp=[IO.Path]::GetFullPath((Get-Item -LiteralPath $temp).FullName)
$utf8=[Text.UTF8Encoding]::new($false)
$none=[Threading.CancellationToken]::None
$db=$null; $stage=$null
$tables=@('token_records','tool_records','recent_lineage_evidence','file_metadata','history_gaps','recent_history_work','recent_history_sources','recent_history_attempt_stamps')
$header='{"type":"session_meta","payload":{"id":"repair-session","cwd":"synthetic-cwd"}}'
$context='{"timestamp":"2026-10-01T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
$usage='{"timestamp":"2026-10-01T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":23,"cached_input_tokens":0,"output_tokens":4},"total_token_usage":{"input_tokens":23,"cached_input_tokens":0,"output_tokens":4}}}}'
$valid=$header+"`n"+$context+"`n"+$usage+"`n"
function Assert([bool]$value,[string]$message){if(-not$value){throw ('SINGLE SOURCE REPAIR FAILED: '+$message)}}
function Sql([string]$sql,$connection=$db){
    $cmd=$connection.CreateCommand()
    try{$cmd.CommandText=$sql; [void]$cmd.Parameters.AddWithValue('@path',$script:path); [void]$cmd.Parameters.AddWithValue('@other',$script:other); [void]$cmd.Parameters.AddWithValue('@parentA',$script:parentA); [void]$cmd.Parameters.AddWithValue('@parentB',$script:parentB); [void]$cmd.Parameters.AddWithValue('@candidate',$script:candidate); [void]$cmd.ExecuteNonQuery()}finally{$cmd.Dispose()}
}
function Scalar([string]$sql,$connection=$db){
    $cmd=$connection.CreateCommand()
    try{$cmd.CommandText=$sql; [void]$cmd.Parameters.AddWithValue('@path',$script:path); [void]$cmd.Parameters.AddWithValue('@other',$script:other); [void]$cmd.Parameters.AddWithValue('@parentA',$script:parentA); [void]$cmd.Parameters.AddWithValue('@parentB',$script:parentB); [void]$cmd.Parameters.AddWithValue('@candidate',$script:candidate); return $cmd.ExecuteScalar()}finally{$cmd.Dispose()}
}
function New-Fixture([string]$name){
    $script:fixture=$name
    if($null-ne$script:stage){$script:stage.Dispose();$script:stage=$null}
    if($null-ne$script:db){$script:db.Dispose();$script:db=$null}
    $dir=Join-Path $temp $name; [void][IO.Directory]::CreateDirectory($dir)
    $script:private=Join-Path $dir 'data\private'; [void][IO.Directory]::CreateDirectory($private)
    $script:path=Join-Path $dir 'source.jsonl'; $script:other=Join-Path $dir 'other.jsonl'
    $script:parentA=Join-Path $dir 'parent-empty.jsonl';$script:parentB=Join-Path $dir 'parent-self.jsonl';$script:candidate=''
    [IO.File]::WriteAllText($path,$valid,$utf8)
    $builder=[System.Data.SQLite.SQLiteConnectionStringBuilder]::new();$builder['Data Source']=[string](Join-Path $private 'index.sqlite');$builder.Version=3
    $script:db=[System.Data.SQLite.SQLiteConnection]::new($builder.ConnectionString);$db.Open();[TokenRaderIndexer]::CreateSchema($db)
    $length=([IO.FileInfo]$path).Length
    [void][TokenRaderIndexer]::ImportFile($db,$path,0L,$length,'old-session','',9L,$null,$none)
    [TokenRaderIndexer]::UpdateFileMetadata($db,$path,$length,123L,$length,'old-session','old-cwd','','','old-session')
    Sql "UPDATE token_records SET session_id='old-session',root_session_id='old-session',call_input=7,index_revision=9 WHERE source_path=@path;
        INSERT INTO tool_records(event_key,session_id,source_path,root_session_id) VALUES('old-tool','old-session',@path,'old-session');
        INSERT INTO recent_lineage_evidence(event_key,session_id,timestamp_ticks,source_path,source_offset_end) VALUES('old-lineage','old-session',1,@path,1);
        INSERT INTO history_gaps(path,start_offset,end_offset,cursor_offset,blocked_reason) VALUES(@path,0,$length,$length,'source_replaced');
        INSERT INTO recent_history_work(path,start_offset,end_offset,cursor_offset,blocked_reason) VALUES(@path,0,$length,$length,'source_replaced');
        INSERT INTO recent_history_sources(path,end_offset) VALUES(@path,$length);
        INSERT INTO recent_history_attempt_stamps VALUES(@path,$length,123,1,'2026-10-01T00:00:00Z');
        INSERT OR REPLACE INTO index_settings VALUES('IndexRevision','9');
        INSERT OR REPLACE INTO index_settings VALUES('recent_history_cutoff','2026-10-01T00:00:00Z');
        INSERT OR REPLACE INTO index_settings VALUES('recent_history_frozen_at','2026-10-02T00:00:00Z');
        INSERT OR REPLACE INTO index_settings VALUES('recent_history_coverage_start','2026-10-01T00:00:00Z');
        INSERT OR REPLACE INTO index_settings VALUES('history_coverage_start','2026-10-01T00:00:00Z');"
    $script:snapshot=[string](Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||session_id||'|'||cwd FROM file_metadata WHERE path=@path")
    $script:backup=Join-Path $private ('repair-'+[guid]::NewGuid().ToString('N')+'.sqlite')
}
function Stage([long]$end=-1L){$script:stage=[TokenRaderIndexer]::StageSingleSourceRepair($path,$end,$none);return $stage}
function Stage-Related {$script:stage=[TokenRaderIndexer]::StageSingleSourceRepair($db,$path,-1L,$none);return $stage}
function New-RelatedFixture([string]$name){
    New-Fixture $name
    $script:relatedHeader=$header.Replace('"cwd":"synthetic-cwd"','"cwd":"synthetic-cwd","parent_thread_id":"parent-session"')
    [IO.File]::WriteAllText($path,$valid.Replace($header,$relatedHeader),$utf8)
    Sql "UPDATE file_metadata SET session_id='repair-session',root_session_id='repair-session' WHERE path=@path;
        UPDATE token_records SET session_id='repair-session',root_session_id='parent-session' WHERE source_path=@path;
        UPDATE tool_records SET session_id='repair-session',root_session_id='parent-session' WHERE source_path=@path;
        UPDATE recent_lineage_evidence SET session_id='repair-session' WHERE source_path=@path;
        INSERT INTO file_metadata(path,length,last_write_ticks,parsed_offset,session_id,root_session_id) VALUES(@parentA,100,1,100,'parent-session','parent-session');
        INSERT INTO file_metadata(path,length,last_write_ticks,parsed_offset,session_id,root_session_id,parent_thread_id,forked_from_id) VALUES(@parentB,100,2,100,'parent-session','parent-session','parent-session','parent-session');
        INSERT INTO history_gaps(path,start_offset,end_offset,cursor_offset) VALUES(@parentA,0,100,0);"
    $script:snapshot=[string](Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||session_id||'|'||cwd FROM file_metadata WHERE path=@path")
}
function Commit([Threading.CancellationToken]$cancel=$none){return [TokenRaderIndexer]::CommitSingleSourceRepair($db,$stage,$backup,$cancel)}
function Refuse($action,[string]$code){
    $caught=$null
    try{&$action|Out-Null}catch{$caught=$_.Exception;while($null-ne$caught.InnerException){$caught=$caught.InnerException}}
    Assert ($null-ne$caught) ('expected conservative refusal: '+$script:fixture)
    if($null-ne$caught){
        Assert ($caught -is [TokenRaderRepairException]) 'fixed coded repair exception'
        Assert ($caught.Code-eq$code) ('safe refusal code '+$code)
        Assert (-not$caught.Message.Contains($path)-and-not$caught.Message.Contains('secret-body')) 'refusal excludes path/body'
    }
}
function Preserved {
    Assert ((Scalar "SELECT SUM(call_input) FROM token_records WHERE source_path=@path")-eq7) 'old numeric rows preserved'
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE event_key='old-tool'")-eq1) 'old tool retained'
    Assert ((Scalar "SELECT COUNT(*) FROM recent_lineage_evidence WHERE event_key='old-lineage'")-eq1) 'old lineage retained'
    Assert ((Scalar "SELECT COUNT(*) FROM history_gaps WHERE path=@path AND blocked_reason='source_replaced'")-eq1) 'old safety guard retained'
    Assert ((Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||session_id||'|'||cwd FROM file_metadata WHERE path=@path")-eq$snapshot) 'old catalog retained'
    Assert ((Scalar "SELECT value FROM index_settings WHERE key='IndexRevision'")-eq'9') 'old revision retained'
}
try{
    New-Fixture 'valid'
    Sql "INSERT INTO token_records(session_id,timestamp,total_input,total_cached,total_output,call_input,call_cached,call_output,source_path,root_session_id) VALUES('unrelated','2026-10-01T00:00:00Z',1,0,0,1,0,0,@other,'unrelated')"
    $otherId=Scalar 'SELECT id FROM token_records WHERE source_path=@other'
    [void](Stage)
    Assert ($stage.TokenRows-eq1-and$stage.VerifiedBytes-eq([IO.FileInfo]$path).Length) 'full frozen prefix staged'
    $result=Commit
    Assert ($stage.MetadataBackupVerified) 'backup confirmed after close/reopen field verification'
    Assert ($result.Applied-and$result.IndexRevision-eq10) 'atomic replacement/revision'
    Assert ((Scalar 'SELECT SUM(call_input) FROM token_records WHERE source_path=@path')-eq23) 'new metadata replaces old'
    Assert ((Scalar 'SELECT id FROM token_records WHERE source_path=@other')-eq$otherId) 'other source/id untouched'
    Assert ((Scalar 'SELECT id FROM token_records WHERE source_path=@path')-ne$otherId) 'stage autoincrement id not copied'
    Assert ((Scalar "SELECT COUNT(*) FROM history_gaps WHERE blocked_reason='source_replaced'")-eq0) 'only validated target guard retired'
    Assert (-not[TokenRaderIndexer]::GetRecentHistoryBackfillStatus($db).Completed) 'global recent coverage not claimed'
    Assert ((Scalar "SELECT value FROM index_settings WHERE key='recent_history_coverage_start'")-eq'') 'coverage invalidated'
    $readBuilder=[System.Data.SQLite.SQLiteConnectionStringBuilder]::new();$readBuilder['Data Source']=[string]$backup;$readBuilder.Version=3;$readBuilder['Read Only']=$true
    $backupDb=[System.Data.SQLite.SQLiteConnection]::new($readBuilder.ConnectionString)
    try{
        $backupDb.Open()
        foreach($table in $tables){$column=if($table-in @('token_records','tool_records','recent_lineage_evidence')){'source_path'}else{'path'};Assert ((Scalar "SELECT COUNT(*) FROM $table WHERE $column=@path" $backupDb)-eq1) 'eight exact-path tables backed up'}
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records WHERE source_path=@other' $backupDb)-eq0) 'backup excludes other source'
        Assert ((Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||session_id||'|'||cwd FROM file_metadata WHERE path=@path" $backupDb)-eq$snapshot) 'backup retains prior catalog'
    }finally{$backupDb.Dispose()}

    foreach($case in @(
        @{Name='malformed';Body=$valid.Replace('"input_tokens":23','"input_tokens":23,');Code='repair_invalid_json'},
        @{Name='duplicate';Body=$valid.Replace('"input_tokens":23','"input_tokens":23,"input_tokens":99');Code='repair_invalid_json'},
        @{Name='escaped-duplicate';Body=$valid.Replace('"input_tokens":23','"input_tokens":23,"input_\u0074okens":99');Code='repair_invalid_json'},
        @{Name='negative';Body=$valid.Replace('"input_tokens":23','"input_tokens":-1');Code='repair_usage_invalid'},
        @{Name='overflow';Body=$valid.Replace('"input_tokens":23','"input_tokens":99999999999999999999999');Code='repair_usage_invalid'},
        @{Name='parent';Body=$valid.Replace('"cwd":"synthetic-cwd"','"cwd":"synthetic-cwd","parent_thread_id":"outside"');Code='repair_relationship_unverified'},
        @{Name='future';Body=$valid.Replace('2026-10-01T02:00:00Z','2099-10-01T02:00:00Z');Code='repair_usage_invalid'}
    )){
        New-Fixture $case.Name;[IO.File]::WriteAllText($path,$case.Body,$utf8)
        Refuse {Stage} $case.Code;Preserved
    }

    New-Fixture 'literal-dotted-alias'
    $aliasHeader=$header.Substring(0,$header.Length-1)+',"payload.id":"wrong","payload.cwd":"wrong","payload.parent_thread_id":"outside"}'
    [IO.File]::WriteAllText($path,$valid.Replace($header,$aliasHeader),$utf8)
    [void](Stage);[void](Commit)
    Assert ((Scalar 'SELECT session_id FROM file_metadata WHERE path=@path')-eq'repair-session') 'literal dotted key cannot override structural header'
    Assert ((Scalar 'SELECT cwd FROM file_metadata WHERE path=@path')-eq'synthetic-cwd') 'literal dotted cwd inert'

    New-Fixture 'large-safe'
    $text='secret-body-not-stored'+('x'*(9*1024*1024))
    $large='{"payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"'+$text+'"}]},"type":"response_item"}'
    [IO.File]::WriteAllText($path,$header+"`n"+$large+"`n"+$context+"`n"+$usage+"`n",$utf8)
    [void](Stage);Assert ($stage.TokenRows-eq1) 'large streaming safe body followed by full numeric metadata'
    [void](Commit)
    Assert (-not[Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($backup)).Contains('secret-body-not-stored')) 'metadata backup contains no body'

    New-Fixture 'large-unsafe'
    $unsafe='{"type":"event_msg","payload":{"type":"token_count","body":"'+('x'*(2*1024*1024))+'"}}'
    [IO.File]::WriteAllText($path,$header+"`n"+$unsafe+"`n"+$usage+"`n",$utf8)
    Refuse {Stage} 'repair_coverage_incomplete';Preserved

    foreach($largeTool in @($false,$true)){
        New-Fixture ('future-tool-'+$largeTool)
        $output=if($largeTool){'x'*(2*1024*1024)}else{'short'}
        $tool='{"timestamp":"2099-10-01T02:00:00Z","type":"response_item","payload":{"type":"function_call_output","call_id":"synthetic-call","output":[{"type":"input_text","text":"'+$output+'"},{"type":"input_image","image_url":"data:image/png;base64,AA=="}]}}'
        [IO.File]::WriteAllText($path,$header+"`n"+$tool+"`n"+$usage+"`n",$utf8)
        $code=if($largeTool){'repair_stage_failed'}else{'repair_tool_timestamp_invalid'}
        Refuse {Stage} $code;Preserved
    }

    New-Fixture 'append'
    [void](Stage);$end=$stage.VerifiedBytes
    [IO.File]::AppendAllText($path,$usage.Replace('02:00:00Z','03:00:00Z')+"`n",$utf8)
    [void](Commit)
    Assert ((Scalar 'SELECT parsed_offset FROM file_metadata WHERE path=@path')-eq$end) 'append does not advance verified cursor'
    Assert ((Scalar 'SELECT length FROM file_metadata WHERE path=@path')-eq$end) 'append EOF not falsely catalogued'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records WHERE source_path=@path')-eq1) 'append not chased'

    New-Fixture 'partial-tail'
    [IO.File]::AppendAllText($path,'{"type":"event_msg"',$utf8)
    [void](Stage);Assert ($stage.VerifiedBytes-lt([IO.FileInfo]$path).Length) 'same handle freezes final complete EOL'
    [void](Commit)

    New-Fixture 'changed-after-consumption'
    [void](Stage);[IO.File]::WriteAllText($path,$valid.Replace('"input_tokens":23','"input_tokens":24'),$utf8)
    Refuse {Commit} 'repair_source_changed';Preserved

    New-Fixture 'replaced-identical-prefix'
    [void](Stage);$replacement=Join-Path (Split-Path -Parent $path) 'replacement.jsonl'
    [IO.File]::WriteAllText($replacement,$valid,$utf8);[IO.File]::Delete($path);[IO.File]::Move($replacement,$path)
    Refuse {Commit} 'repair_source_changed';Preserved

    foreach($kind in @('same-session-other','blank-legacy','unknown-schema','unknown-trigger','unique-conflict')){
        New-Fixture $kind;[void](Stage)
        switch($kind){
            'same-session-other'{Sql "INSERT INTO token_records(session_id,timestamp,total_input,total_cached,total_output,call_input,call_cached,call_output,source_path) VALUES('repair-session','x',1,0,0,1,0,0,@other)";$code='repair_cross_source_association'}
            'blank-legacy'{Sql "INSERT INTO token_records(session_id,timestamp,total_input,total_cached,total_output,call_input,call_cached,call_output,source_path) VALUES('old-session','x',1,0,0,1,0,0,'')";$code='repair_cross_source_association'}
            'unknown-schema'{Sql 'ALTER TABLE file_metadata ADD COLUMN last_record_id INTEGER';$code='repair_schema_mismatch'}
            'unknown-trigger'{Sql "CREATE TRIGGER unsafe_trigger AFTER DELETE ON token_records BEGIN DELETE FROM tool_records; END";$code='repair_schema_mismatch'}
            'unique-conflict'{Sql "INSERT INTO token_records(session_id,timestamp,total_input,total_cached,total_output,call_input,call_cached,call_output,source_path) VALUES('unrelated','x',1,0,0,23,0,0,@other);CREATE UNIQUE INDEX synthetic_call_collision ON token_records(call_input)";$code='repair_commit_failed'}
        }
        Refuse {Commit} $code;Preserved
    }

    New-RelatedFixture 'terminal-parent-duplicates'
    # No parent JSONL exists. Only the explicitly authorized catalog topology is used.
    Sql "INSERT INTO file_metadata(path,length,last_write_ticks,parsed_offset,session_id,root_session_id,parent_thread_id) VALUES('synthetic://sibling',100,3,100,'sibling-session','parent-session','parent-session');
        INSERT INTO token_records(session_id,timestamp,model,total_input,total_cached,total_output,call_input,call_cached,call_output,source_path,source_offset_end,root_session_id) VALUES('sibling-session','2026-10-01T02:00:00Z','gpt-5.4',23,0,4,23,0,4,'synthetic://sibling',100,'parent-session');"
    [void](Stage-Related);[void](Commit)
    Assert ((Scalar 'SELECT root_session_id FROM file_metadata WHERE path=@path')-eq'parent-session') 'verified parent/root replaces incorrect target self-root'
    Assert ((Scalar 'SELECT parent_thread_id FROM file_metadata WHERE path=@path')-eq'parent-session') 'verified direct parent persisted'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE source_path=@path AND session_id='repair-session' AND root_session_id='parent-session'")-eq1) 'staged numeric identity canonical'
    Assert ((Scalar "SELECT COUNT(*) FROM recent_lineage_evidence WHERE source_path=@path AND event_key NOT LIKE 'parent-session|%'")-eq0) 'staged lineage root canonical'
    Assert ((Scalar "SELECT COUNT(*) FROM history_gaps WHERE path=@parentA AND cursor_offset=0 AND end_offset=100")-eq1) 'parent historical gap unchanged'
    Assert ((Scalar "SELECT COUNT(*) FROM file_metadata WHERE session_id='parent-session'")-eq2) 'parent candidate directories unchanged'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE source_path='synthetic://sibling'")-eq1) 'independent sibling rows retained'
    Assert (-not[TokenRaderIndexer]::GetRecentHistoryBackfillStatus($db).Completed) 'parent gap never becomes global coverage'
    $ends=@{};$ends[$path]=([IO.FileInfo]$path).Length;$ends['synthetic://sibling']=100L
    $aggregate=[TokenRaderIndexer]::AggregateIntervalRecords($db,@{},$ends,[DateTimeOffset]::MinValue,@{},$none,$null)
    Assert ($aggregate.CountedEvents-eq2-and$aggregate.TotalInput-eq46) 'same-root independent sibling remains separately counted'

    New-RelatedFixture 'terminal-parent-copy'
    # Seed the parent copy from the synthetic target row without changing body data.
    Sql "UPDATE token_records SET call_input=23 WHERE source_path=@path;
        INSERT INTO token_records(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,source_offset_end,root_session_id,turn_id,request_id,response_id,identity_source)
        SELECT 'parent-session',timestamp,model,total_input,total_cached,total_output,total_reasoning,call_input,call_cached,call_output,call_reasoning,fingerprint,@parentA,100,'parent-session',turn_id,request_id,response_id,identity_source FROM token_records WHERE source_path=@path LIMIT 1;"
    [void](Stage-Related);[void](Commit)
    $ends=@{};$ends[$path]=([IO.FileInfo]$path).Length;$ends[$parentA]=100L
    $aggregate=[TokenRaderIndexer]::AggregateIntervalRecords($db,@{},$ends,[DateTimeOffset]::MinValue,@{},$none,$null)
    Assert ($aggregate.CountedEvents-eq1-and$aggregate.DuplicateEventsDropped-eq1-and$aggregate.TotalInput-eq23) 'parent child copied event counted once'

    New-RelatedFixture 'target-own-model-switch'
    $nextContext=$context.Replace('gpt-5.4','gpt-6').Replace('01:00:00Z','03:00:00Z')
    $nextUsage=$usage.Replace('02:00:00Z','04:00:00Z').Replace('"input_tokens":23','"input_tokens":46').Replace('"output_tokens":4','"output_tokens":8')
    [IO.File]::WriteAllText($path,$relatedHeader+"`n"+$context+"`n"+$usage+"`n"+$nextContext+"`n"+$nextUsage+"`n",$utf8)
    [void](Stage-Related);[void](Commit)
    Assert ((Scalar "SELECT COUNT(DISTINCT model) FROM token_records WHERE source_path=@path")-eq2) 'target own model switch survives relation repair'
    Assert ((Scalar "SELECT turn_context_model FROM file_metadata WHERE path=@parentA")-eq'') 'parent context never backfilled'

    New-RelatedFixture 'target-model-unresolved'
    [IO.File]::WriteAllText($path,$relatedHeader+"`n"+$usage+"`n",$utf8)
    Sql "UPDATE file_metadata SET turn_context_model='parent-model-not-evidence',turn_context_model_source='turn_context' WHERE session_id='parent-session'"
    [void](Stage-Related);Assert ($stage.UnresolvedTokenRows-eq1) 'missing target context explicitly counted';$unresolvedResult=Commit
    Assert ($unresolvedResult.UnresolvedTokenRows-eq1) 'unresolved count survives result handoff'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE source_path=@path AND model='parent-model-not-evidence'")-eq0) 'parent latest model never guessed'
    $ends=@{};$ends[$path]=([IO.FileInfo]$path).Length
    $aggregate=[TokenRaderIndexer]::AggregateIntervalRecords($db,@{},$ends,[DateTimeOffset]::MinValue,@{},$none,$null)
    Assert (@($aggregate.Buckets | Where-Object {[string]::IsNullOrWhiteSpace($_.Model)}).Count-eq1) 'unknown model retained in aggregate bucket for incomplete pricing'

    foreach($case in @('parent-external-edge','parent-unknown-root','parent-blocked','parent-too-many','parent-target-case-alias','parent-target-dot-alias','target-wrong-id','target-mixed-session','target-unknown-root','target-blank-legacy')){
        New-RelatedFixture $case
        $code='repair_relationship_unverified'
        switch($case){
            'parent-external-edge'{Sql "UPDATE file_metadata SET parent_thread_id='outside' WHERE path=@parentB"}
            'parent-unknown-root'{Sql "UPDATE file_metadata SET root_session_id='' WHERE path=@parentB"}
            'parent-blocked'{Sql "INSERT INTO history_gaps(path,start_offset,end_offset,cursor_offset,blocked_reason) VALUES(@parentB,0,100,100,'source_replaced')"}
            'parent-too-many'{for($i=0;$i-lt31;$i++){$script:candidate=Join-Path (Split-Path -Parent $path) "extra-$i.jsonl";Sql "INSERT INTO file_metadata(path,length,last_write_ticks,session_id,root_session_id) VALUES(@candidate,0,1,'parent-session','parent-session')"}}
            'parent-target-case-alias'{$script:candidate=$path.ToUpperInvariant();Sql "INSERT INTO file_metadata(path,length,last_write_ticks,session_id,root_session_id) VALUES(@candidate,0,1,'parent-session','parent-session')"}
            'parent-target-dot-alias'{$script:candidate=Join-Path (Split-Path -Parent $path) 'sub\..\source.jsonl';Sql "INSERT INTO file_metadata(path,length,last_write_ticks,session_id,root_session_id) VALUES(@candidate,0,1,'parent-session','parent-session')"}
            'target-wrong-id'{Sql "UPDATE file_metadata SET session_id='wrong' WHERE path=@path";$script:snapshot=[string](Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||session_id||'|'||cwd FROM file_metadata WHERE path=@path")}
            'target-mixed-session'{Sql "UPDATE tool_records SET session_id='wrong' WHERE source_path=@path"}
            'target-unknown-root'{Sql "UPDATE token_records SET root_session_id='' WHERE source_path=@path"}
            'target-blank-legacy'{Sql "INSERT INTO recent_lineage_evidence(event_key,session_id,timestamp_ticks,source_path,source_offset_end) VALUES('legacy','repair-session',1,'',1)";$code='repair_cross_source_association'}
        }
        Refuse {Stage-Related} $code;Preserved
    }
    foreach($case in @('late-parent-edge','late-parent-new-path','late-parent-guard','late-target-row','late-revision')){
        New-RelatedFixture $case;[void](Stage-Related)
        switch($case){
            'late-parent-edge'{Sql "UPDATE file_metadata SET parent_thread_id='outside' WHERE path=@parentB"}
            'late-parent-new-path'{$script:candidate=Join-Path (Split-Path -Parent $path) 'late-parent.jsonl';Sql "INSERT INTO file_metadata(path,length,last_write_ticks,session_id,root_session_id) VALUES(@candidate,0,1,'parent-session','parent-session')"}
            'late-parent-guard'{Sql "UPDATE history_gaps SET cursor_offset=1 WHERE path=@parentA"}
            'late-target-row'{Sql "UPDATE token_records SET model='changed' WHERE source_path=@path"}
            'late-revision'{Sql "UPDATE index_settings SET value='10' WHERE key='IndexRevision'"}
        }
        Refuse {Commit} 'repair_relation_changed'
        if($case-eq'late-revision'){Sql "UPDATE index_settings SET value='9' WHERE key='IndexRevision'"}
        Preserved
    }

    New-Fixture 'canceled'
    [void](Stage);$cts=[Threading.CancellationTokenSource]::new();$cts.Cancel()
    try{try{Commit $cts.Token|Out-Null;throw 'missing cancellation'}catch{Assert ($_.Exception.ToString().Contains('OperationCanceledException')) 'cancellation surfaced'}}finally{$cts.Dispose()}
    Preserved
    Write-Output 'Single-source repair synthetic tests passed.'
}finally{
    if($null-ne$stage){$stage.Dispose()};if($null-ne$db){$db.Dispose()}
    [System.Data.SQLite.SQLiteConnection]::ClearAllPools()
    $resolved=[IO.Path]::GetFullPath($temp);$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)-and(Split-Path -Leaf $resolved).StartsWith('TokenRader-SingleSourceRepairSynthetic-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
