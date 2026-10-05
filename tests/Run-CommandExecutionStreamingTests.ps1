[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll=Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-CommandExecutionSynthetic-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$temp=[IO.Path]::GetFullPath((Get-Item -LiteralPath $temp).FullName)
$utf8=[Text.UTF8Encoding]::new($false)
$none=[Threading.CancellationToken]::None
$progress=[hashtable]::Synchronized(@{})
$end=[DateTimeOffset]::Parse('2026-10-05T12:00:00Z')
$cutoff=$end.AddHours(-24)
$db=$null

function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('COMMAND EXECUTION STREAMING FAILED: '+$message) } }
function Scalar([string]$sql) {
    $cmd=$db.CreateCommand()
    try { $cmd.CommandText=$sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
}
function Sql([string]$sql) {
    $cmd=$db.CreateCommand()
    try { $cmd.CommandText=$sql; [void]$cmd.ExecuteNonQuery() } finally { $cmd.Dispose() }
}
function New-Fixture([string]$name,[string]$body) {
    if ($null-ne$script:db) { $script:db.Close(); $script:db.Dispose() }
    $script:db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $script:db.Open(); [TokenRaderIndexer]::CreateSchema($script:db)
    $script:fixtureRoot=Join-Path $temp $name
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $script:path=Join-Path $fixtureRoot 'synthetic.jsonl'
    [IO.File]::WriteAllText($path,$body,$utf8)
    $script:frozen=([IO.FileInfo]$path).Length
}
function Import([long]$start=0,[long]$until=-1,$state=$null,[Threading.CancellationToken]$cancel=$none) {
    if ($until-lt0) { $until=([IO.FileInfo]$path).Length }
    return [TokenRaderIndexer]::ImportFile($db,$path,$start,$until,'synthetic-root','',1L,$state,$cancel)
}
function New-CommandRecord([string]$text,[bool]$late=$false,[string]$commandJson='"COMMAND_SENTINEL"',[bool]$commandLate=$false) {
    # All retained identifiers are synthetic. Output/command/cwd sentinels must
    # never appear in persisted scanner state or retained numeric/tool metadata.
    $commandField='"command":'+$commandJson
    $itemFields='"id":"synthetic-call","cwd":"C:\\SYNTHETIC_CWD_SENTINEL","process_id":null,"source":"exec","status":"completed","exit_code":0,"duration":{"secs":1,"nanos":2},"stdout":"'+$text+'","stderr":"","aggregated_output":"","formatted_output":"","parsed_cmd":[{"type":"unknown","cmd":"PARSED_COMMAND_SENTINEL"}]'
    if ($commandLate) { $itemFields+=','+$commandField }
    else { $itemFields=$itemFields.Replace('"cwd":',($commandField+',"cwd":')) }
    if ($late) {
        $item='{'+$itemFields+',"type":"CommandExecution"}'
        return '{"payload":{"item":'+$item+',"completed_at_ms":1791165601000,"started_at_ms":1791165600000,"turn_id":"synthetic-turn","thread_id":"synthetic-thread","type":"item_completed"},"ordinal":1,"timestamp":"2026-10-05T02:00:00Z","type":"event_msg"}'
    }
    $item='{"type":"CommandExecution",'+$itemFields+'}'
    return '{"timestamp":"2026-10-05T02:00:00Z","type":"event_msg","ordinal":1,"payload":{"type":"item_completed","thread_id":"synthetic-thread","turn_id":"synthetic-turn","started_at_ms":1791165600000,"completed_at_ms":1791165601000,"item":'+$item+'}}'
}
function Assert-Tools([long]$calls=1) {
    $usage=[TokenRaderIndexer]::AggregateToolUsage($db,$cutoff,$end)
    Assert ($usage.TotalToolCalls-eq$calls) 'canonical tool-call count is exact'
    if ($calls-gt0) {
        Assert ($usage.CompletedToolCalls-eq$calls) 'completion status is retained'
        Assert (@($usage.Items | Where-Object { $_.EventKind-eq'tool_call' -and $_.ToolName-eq'shell' }).Count-eq1) 'CommandExecution maps to shell tool metadata'
        Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE call_key='synthetic-call' AND event_kind='tool_call' AND tool_name='shell' AND status='completed'")-ge1) 'synthetic call id and completion metadata are retained'
    }
    Assert ($usage.InputImages-eq0 -and $usage.GeneratedImages-eq0) 'output text cannot manufacture image metadata'
}
function Assert-SafeStorage {
    foreach ($table in @('history_gaps','recent_history_work')) {
        $state=[string](Scalar ('SELECT COALESCE(MAX(body_scan_state),'''') FROM '+$table))
        Assert ($state.Length-le600) 'scanner continuation stays bounded'
        foreach ($sentinel in @('OUTPUT_BODY_SENTINEL','COMMAND_SENTINEL','COMMAND_ARRAY_BODY_SENTINEL','SYNTHETIC_CWD_SENTINEL','PARSED_COMMAND_SENTINEL')) {
            Assert (-not $state.Contains($sentinel)) 'scanner continuation never retains output/command/cwd'
        }
    }
    $cmd=$db.CreateCommand()
    try {
        $cmd.CommandText='SELECT event_key,call_key,session_id,timestamp,model,event_kind,tool_name,status,source_path,root_session_id FROM tool_records'
        $reader=$cmd.ExecuteReader()
        try {
            while ($reader.Read()) {
                for ($i=0;$i-lt$reader.FieldCount;$i++) {
                    $value=[string]$reader.GetValue($i)
                    foreach ($sentinel in @('OUTPUT_BODY_SENTINEL','COMMAND_SENTINEL','COMMAND_ARRAY_BODY_SENTINEL','SYNTHETIC_CWD_SENTINEL','PARSED_COMMAND_SENTINEL')) {
                        Assert (-not $value.Contains($sentinel)) 'tool metadata never retains output/command/cwd'
                    }
                }
            }
        } finally { $reader.Dispose() }
    } finally { $cmd.Dispose() }
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
        Assert ($batch.ProcessedBytes-ge0 -and $batch.ProcessedBytes-le$budget) 'history obeys its byte budget'
        Assert-SafeStorage
        if ($batch.Completed -or $batch.EligibleFiles-eq0) { return }
        Assert ($batch.ProcessedBytes-gt0) 'unfinished bounded history makes progress'
    }
    throw 'CommandExecution history fixture did not finish bounded work'
}
function Reject-Import([long]$start=0,[long]$until=-1) {
    $failure=$null
    try { [void](Import $start $until) } catch { $failure=$_.Exception.ToString() }
    Assert (-not [string]::IsNullOrWhiteSpace($failure)) 'unsafe or incomplete command record is rejected'
    foreach ($sentinel in @('OUTPUT_BODY_SENTINEL','COMMAND_SENTINEL','COMMAND_ARRAY_BODY_SENTINEL','SYNTHETIC_CWD_SENTINEL')) {
        Assert (-not $failure.Contains($sentinel)) 'failure classification contains no synthetic private text'
    }
}
function New-ReplacementFixture([string]$name) {
    New-Fixture $name ($script:context+"`n"+$script:firstToken+"`n"+$script:small+"`n")
    Assert ((Import)-eq1) 'seed valid usage before replacement'
    Assert-Tools
    $script:oldSession=[string](Scalar 'SELECT session_id FROM token_records')
    [TokenRaderIndexer]::UpdateFileMetadata($db,$path,$frozen,123L,$frozen,$oldSession,'old-cwd','','','synthetic-root')
    $script:oldMetadata=[string](Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||cwd||'|'||turn_context_model||'|'||turn_context_service_tier FROM file_metadata")
}
function Replace($state=$null,[Threading.CancellationToken]$cancel=$none) {
    $length=([IO.FileInfo]$path).Length
    return [TokenRaderIndexer]::ReplaceFile($db,$path,$length,$oldSession,$length,456L,$oldSession,'new-cwd','','','synthetic-root',2L,$state,$cancel)
}
function Assert-ReplacementPreserved {
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1 -and (Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) 'failed replacement retains preceding valid token metadata'
    Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq1) 'failed replacement retains prior command tool metadata'
    Assert-Tools
    Assert ((Scalar "SELECT length||'|'||last_write_ticks||'|'||parsed_offset||'|'||cwd||'|'||turn_context_model||'|'||turn_context_service_tier FROM file_metadata")-eq$oldMetadata) 'failed replacement retains committed catalog/cursor/context'
}

try {
    $context='{"timestamp":"2026-10-05T00:30:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $firstToken='{"timestamp":"2026-10-05T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}'
    $nextToken=$firstToken.Replace('01:00:00Z','03:00:00Z').Replace('"total_token_usage":{"input_tokens":7','"total_token_usage":{"input_tokens":14')
    # ASCII source is deliberately safe to parse as Windows PowerShell 5.1.
    # JSON escapes exercise escaped quotes, slash, control escapes and Unicode.
    $escaped='OUTPUT_BODY_SENTINEL \\ \n \r \t \u96ea \ud83d\ude00 \"type\":\"input_image\" \"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":999999}} \"type\":\"function_call\" \"type\":\"computer_screenshot\"'
    $huge=('x'*(2*1024*1024))+$escaped
    $giant=New-CommandRecord $huge
    $late=New-CommandRecord $huge $true
    $small=New-CommandRecord $escaped
    Assert ($utf8.GetByteCount($giant)-gt(1024*1024)) 'fixture is genuinely oversized'

    foreach ($record in @($giant,$late,$small)) {
        foreach ($newline in @("`n","`r`n")) {
            New-Fixture ([guid]::NewGuid().ToString('N')) ($context+$newline+$firstToken+$newline+$record+$newline+$nextToken+$newline)
            Assert ((Import)-eq2) 'tokens before and after command import together'
            Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'command output does not alter token totals'
            Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE model='gpt-5.4' AND service_tier='priority'")-eq2) 'command preserves model/tier context'
            Assert ((Scalar 'SELECT MAX(source_offset_end) FROM token_records')-eq$frozen) 'exact UTF-8 LF/CRLF endpoint is retained'
            Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq1) 'one completion yields one metadata record'
            Assert-Tools; Assert-SafeStorage
            Assert ((Import)-eq0) 'same frozen import retry is idempotent'
            Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq1) 'same source event is not duplicated'
            [IO.File]::AppendAllText($path,$record+$newline,$utf8)
            Assert ((Import 0 $frozen)-eq0) 'frozen import ignores appended command'
            Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq1) 'frozen endpoint does not chase append'
            Assert ((Import $frozen)-eq0) 'later command completion adds no token row'
            Assert-Tools
        }
    }

    # Every output string can be oversized; no particular early stdout prefix
    # should be required to prove the completed item is the supported schema.
    foreach ($field in @('stderr','aggregated_output','formatted_output')) {
        $moved=$giant.Replace(('"stdout":"'+$huge+'"'),'"stdout":""').Replace(('"'+$field+'":""'),('"'+$field+'":"'+$huge+'"'))
        New-Fixture ('output-field-'+$field) ($context+"`n"+$firstToken+"`n"+$moved+"`n"+$nextToken+"`n")
        Assert ((Import)-eq2) ($field+' oversized output preserves surrounding tokens')
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) ($field+' output keywords cannot create fake usage')
        Assert-Tools; Assert-SafeStorage
    }
    foreach ($process in @('123','"synthetic-process"','null')) {
        $nullable=$giant.Replace('"process_id":null',('"process_id":'+$process)).Replace('"duration":{"secs":1,"nanos":2}','"duration":null').Replace('"parsed_cmd":[{"type":"unknown","cmd":"PARSED_COMMAND_SENTINEL"}]','"parsed_cmd":null').Replace('"stderr":""','"stderr":null')
        New-Fixture ([guid]::NewGuid().ToString('N')) ($nullable+"`n")
        Assert ((Import)-eq0) 'known nullable fields and supported process-id scalars retain tool-only semantics'
        Assert-Tools; Assert-SafeStorage
    }
    New-Fixture 'failed-completion' ($giant.Replace('"status":"completed"','"status":"failed"').Replace('"exit_code":0','"exit_code":1')+"`n")
    Assert ((Import)-eq0) 'failed execution is tool metadata, not token usage'
    $failed=[TokenRaderIndexer]::AggregateToolUsage($db,$cutoff,$end)
    Assert ($failed.TotalToolCalls-eq1 -and $failed.FailedToolCalls-eq1 -and $failed.CompletedToolCalls-eq0) 'failed completion status is normalized without changing call count'
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE call_key='synthetic-call' AND tool_name='shell' AND status='failed'")-eq1) 'failed completion retains its safe metadata'

    # Same-call evidence from an existing shell call and its completion dedups.
    $shell='{"timestamp":"2026-10-05T01:30:00Z","type":"response_item","payload":{"type":"shell_call","call_id":"synthetic-call","status":"in_progress"}}'
    New-Fixture 'same-call-replay' ($context+"`n"+$shell+"`n"+$giant+"`n"+$giant+"`n")
    Assert ((Import)-eq0) 'tool-only replay has zero tokens'
    Assert-Tools

    # A normal function call may mention the completion protocol in arguments.
    # Keywords in its text must not reroute it to CommandExecution validation.
    $keywordTool='{"timestamp":"2026-10-05T02:00:00Z","type":"response_item","payload":{"type":"function_call","name":"synthetic_protocol_tool","call_id":"synthetic-keyword-call","arguments":"CommandExecution item_completed"}}'
    New-Fixture 'function-call-protocol-keywords' ($context+"`n"+$firstToken+"`n"+$keywordTool+"`n"+$nextToken+"`n")
    Assert ((Import)-eq2) 'protocol words in function arguments preserve surrounding tokens'
    $keywordUsage=[TokenRaderIndexer]::AggregateToolUsage($db,$cutoff,$end)
    Assert ($keywordUsage.TotalToolCalls-eq1) 'normal function call with protocol words is not swallowed'
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE call_key='synthetic-keyword-call' AND tool_name='synthetic_protocol_tool' AND event_kind='tool_call'")-eq1) 'normal function metadata retains its own identity'

    # Observed command values are string arrays. This is separate from the
    # legacy string shape above, and no array element may be retained as data.
    $rawUnicode=([string][char]0x96ea)+[char]::ConvertFromUtf32(0x1F600)
    $arrayEscaped='COMMAND_SENTINEL \\ \n \t \"quoted\" \u96ea \ud83d\ude00 '+$rawUnicode
    $commands='["'+$arrayEscaped+'","synthetic-tail"]'
    $hugeCommand='COMMAND_ARRAY_BODY_SENTINEL'+('c'*(2*1024*1024))+$arrayEscaped
    $largeCommands='["synthetic-head","'+$hugeCommand+'","synthetic-tail"]'
    foreach ($commandLate in @($false,$true)) {
        foreach ($record in @((New-CommandRecord $escaped $commandLate $commands $commandLate),(New-CommandRecord $escaped $commandLate '[]' $commandLate),(New-CommandRecord $huge $commandLate $commands $commandLate),(New-CommandRecord $escaped $commandLate $largeCommands $commandLate))) {
            New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$firstToken+"`n"+$record+"`n"+$nextToken+"`n")
            Assert ((Import)-eq2) 'early/late command array preserves token rows'
            Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'command array elements do not manufacture usage'
            Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq1) 'command array completion yields one tool record'
            Assert-Tools; Assert-SafeStorage
            Assert ((Import)-eq0) 'command array frozen replay is idempotent'
        }
        foreach ($recent in @($true,$false)) {
            foreach ($record in @((New-CommandRecord $huge $commandLate $commands $commandLate),(New-CommandRecord $escaped $commandLate $largeCommands $commandLate))) {
                foreach ($budget in @((256*1024),(1024*1024+65536))) {
                    New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$firstToken+"`n"+$record+"`n"+$nextToken+"`n")
                    Prepare $recent; Complete $recent $budget
                    Assert $batch.Completed 'command arrays resume across bounded string/array scans'
                    Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'resumed command arrays retain numeric accounting'
                    Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq1) 'resumed command arrays emit only fully validated completion metadata'
                    Assert-Tools; Assert-SafeStorage
                }
            }
        }
    }
    # Force a persisted batch boundary inside a command-array Unicode escape,
    # and separately inside a raw UTF-8 scalar, rather than relying on chance.
    $boundaryRecord=New-CommandRecord $huge $false $commands
    $escapeBoundary=$utf8.GetByteCount($boundaryRecord.Substring(0,$boundaryRecord.IndexOf('\u96ea',[StringComparison]::Ordinal)))+3L
    $utf8Boundary=$utf8.GetByteCount($boundaryRecord.Substring(0,$boundaryRecord.IndexOf($rawUnicode,[StringComparison]::Ordinal)))+1L
    foreach ($boundary in @($escapeBoundary,$utf8Boundary)) {
        New-Fixture ([guid]::NewGuid().ToString('N')) ($boundaryRecord+"`n"+$context+"`n"+$firstToken+"`n")
        Prepare $true; $first=Batch $true $boundary
        Assert ($first.ProcessedBytes-eq$boundary -and -not $first.Completed) 'command-array escape/UTF-8 boundary commits only bounded parser state'
        Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'partial command-array string cannot emit tool metadata'
        Assert-SafeStorage
        Complete $true (256*1024)
        Assert $batch.Completed 'command-array escaped/UTF-8 string resumes safely'
        Assert-Tools
    }
    $badCommands=@{
        object='{"cmd":"synthetic"}'
        null='null'
        number='7'
        boolean='true'
        nested='[["synthetic"]]'
        trailing='["synthetic",]'
        nullElement='["synthetic",null]'
        numberElement='["synthetic",7]'
        booleanElement='["synthetic",false]'
        objectElement='["synthetic",{"cmd":"synthetic"}]'
        usageElement='["synthetic",{"usage":{"input_tokens":7}}]'
        imageElement='["synthetic",{"type":"input_image","image_url":"synthetic"}]'
    }
    foreach ($name in @($badCommands.Keys)+@('duplicate')) {
        if ($name-eq'duplicate') { $record=(New-CommandRecord $huge $false $commands).Replace('"process_id":','"command":["duplicate"],"process_id":') }
        else { $record=New-CommandRecord $huge $true $badCommands[$name] $true }
        New-Fixture ('reject-command-array-'+$name) ($context+"`n"+$firstToken+"`n")
        Assert ((Import)-eq1) 'seed committed usage before invalid command array'
        $start=$frozen
        [IO.File]::AppendAllText($path,$nextToken+"`n"+$record+"`n",$utf8)
        Reject-Import $start
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7 -and (Scalar 'SELECT COUNT(*) FROM token_records')-eq1) ($name+' invalid command rolls back preceding new token row')
        Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-eq$start -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) ($name+' invalid command retains cursor and emits no tool metadata')
        New-Fixture ('history-reject-command-array-'+$name) ($record+"`n"+$context+"`n"+$firstToken+"`n")
        Prepare $true; Complete $true (256*1024)
        Assert (-not $batch.Completed -and $batch.BlockedFiles-eq1) ($name+' invalid command array preserves historical coverage block')
        Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0 -and (Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) ($name+' invalid array cannot fabricate tools or erase following numeric usage')
    }

    foreach ($recent in @($true,$false)) {
        foreach ($record in @($giant,$late)) {
            foreach ($budget in @((256*1024),(1024*1024+65536),(3*1024*1024))) {
                New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$firstToken+"`n"+$record+"`n"+$nextToken+"`n")
                Prepare $recent; Complete $recent $budget
                Assert $batch.Completed 'complete known command allows bounded history coverage'
                Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'history retains tokens before and after output'
                Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq1) 'history stores completion metadata exactly once'
                Assert-Tools
                $table=if($recent){'recent_history_work'}else{'history_gaps'}
                Assert ((Scalar ('SELECT cursor_offset FROM '+$table+' LIMIT 1'))-eq$frozen) 'history stops at frozen endpoint'
            }
        }
    }

    # Persisted scans are metadata only and cannot produce a completion early.
    New-Fixture 'bounded-proof' ($giant+"`n"+$context+"`n"+$firstToken+"`n")
    Prepare $true
    $first=Batch $true (256*1024)
    Assert (-not $first.Completed -and $first.ProcessedBytes-le(256*1024)) 'first bounded batch cannot finish giant output'
    Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'no tool record before whole-line validation'
    Assert ((Scalar 'SELECT discard_line FROM recent_history_work')-eq1) 'scanner continuation is committed'
    Assert-SafeStorage
    [IO.File]::AppendAllText($path,$small+"`n",$utf8)
    Complete $true (256*1024)
    Assert $batch.Completed 'saved scan resumes to complete known command'
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$frozen) 'saved scan does not chase append'
    Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq1) 'saved scan stores only frozen completion'

    $reject=@{
        rootUnknown=$giant.Replace('"ordinal":1,','"ordinal":1,"unknown_root":true,')
        payloadUnknown=$giant.Replace('"thread_id":','"unknown_payload":null,"thread_id":')
        itemUnknown=$giant.Replace('"process_id":','"unknown_item":0,"process_id":')
        duplicateRoot=$giant.Replace('"ordinal":1,','"ordinal":1,"type":"event_msg",')
        duplicatePayload=$giant.Replace('"thread_id":','"type":"item_completed","thread_id":')
        duplicateItem=$giant.Replace('"process_id":','"id":"other-call","process_id":')
        duplicateOutput=$giant.Replace('"stderr":""','"stdout":"late duplicate","stderr":""')
        duplicateDuration=$giant.Replace('"nanos":2','"secs":1,"nanos":2')
        duplicateParsed=$giant.Replace('"cmd":"PARSED_COMMAND_SENTINEL"','"cmd":"PARSED_COMMAND_SENTINEL","cmd":"duplicate"')
        usageRoot=$giant.Replace('"ordinal":1,','"ordinal":1,"usage":{"input_tokens":7},')
        usageItem=$giant.Replace('"process_id":','"usage":{"input_tokens":7},"process_id":')
        imageItem=$giant.Replace('"process_id":','"image":{"type":"input_image","image_url":"synthetic"},"process_id":')
        unknownDuration=$giant.Replace('"nanos":2','"nanos":2,"unknown":0')
        unknownParsed=$giant.Replace('"cmd":"PARSED_COMMAND_SENTINEL"','"cmd":"PARSED_COMMAND_SENTINEL","unknown":true')
        invalidEscape=$giant.Replace($escaped,($escaped+'\q'))
        malformed=$giant+'{}'
        wrongItemType=$giant.Replace('"type":"CommandExecution"','"type":"UnknownExecution"')
        missingItemType=$giant.Replace('"type":"CommandExecution",','')
        missingId=$giant.Replace('"id":"synthetic-call",','')
        missingTimestamp=$giant.Replace('"timestamp":"2026-10-05T02:00:00Z",','')
    }
    foreach ($name in $reject.Keys) {
        New-Fixture ('reject-'+$name) ($context+"`n"+$firstToken+"`n")
        Assert ((Import)-eq1) 'seed index before unsafe completion'
        $start=$frozen
        [IO.File]::AppendAllText($path,$nextToken+"`n"+$reject[$name]+"`n",$utf8)
        Reject-Import $start
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1 -and (Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) ($name+' rolls back preceding token insertion')
        Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-eq$start) ($name+' retains committed cursor')
        Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) ($name+' cannot leak partial command metadata')
        Reject-Import $start
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1) ($name+' rejected retry is idempotent')

        New-Fixture ('history-reject-'+$name) ($reject[$name]+"`n"+$context+"`n"+$firstToken+"`n")
        Prepare $true; Complete $true (256*1024)
        Assert (-not $batch.Completed -and $batch.BlockedFiles-eq1) ($name+' historical rejection retains coverage block')
        Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) ($name+' rejected history has no command metadata')
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) ($name+' history can retain following numeric rows without claiming full coverage')
    }

    New-Fixture 'incomplete-frozen' ($context+"`n"+$firstToken+"`n"+$giant+"`n")
    $partial=$utf8.GetByteCount($context+"`n"+$firstToken+"`n")+1024*1024+65536
    Reject-Import 0 $partial
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'frozen half-line rolls back usage and tool metadata'
    Assert ((Scalar 'SELECT COUNT(*) FROM file_metadata')-eq0) 'frozen half-line cannot advance a catalog cursor'
    Assert ((Import)-eq1) 'retry with complete frozen line recovers'
    Assert-Tools

    foreach ($recent in @($true,$false)) {
        foreach ($body in @($giant.Substring(0,(1024*1024+65536)),$giant)) {
            New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$firstToken+"`n"+$body)
            Prepare $recent; Complete $recent (256*1024)
            Assert (-not $batch.Completed -and $batch.BlockedFiles-eq1) 'frozen unfinished command line cannot claim historical coverage'
            Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'half-line or complete JSON without EOL cannot emit tool metadata'
            Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) 'unfinished historical command preserves earlier valid numeric rows'
        }
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Threading;
public sealed class CommandExecutionSyntheticCancelProgress : Hashtable {
    public CancellationTokenSource Source;
    public long Threshold;
    public CommandExecutionSyntheticCancelProgress(CancellationTokenSource source, long threshold) { Source=source; Threshold=threshold; }
    public override object this[object key] {
        get { return base[key]; }
        set { base[key]=value; if (Convert.ToString(key)=="CurrentOffset" && Convert.ToInt64(value)>=Threshold) Source.Cancel(); }
    }
}
'@
    New-Fixture 'cancel-live' ($context+"`n"+$firstToken+"`n"+$giant+"`n")
    $cts=[Threading.CancellationTokenSource]::new()
    $cancelProgress=[CommandExecutionSyntheticCancelProgress]::new($cts,(1024*1024+65536))
    try {
        $failure=$null
        try { [void](Import 0 -1 $cancelProgress $cts.Token) } catch { $failure=$_.Exception.ToString() }
        Assert ($null-ne$failure -and $failure.Contains('OperationCanceledException')) 'live cancellation propagates'
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'live cancellation atomically rolls back metadata'
        Assert ((Scalar 'SELECT COUNT(*) FROM file_metadata')-eq0) 'live cancellation preserves original cursor'
    } finally { $cts.Dispose() }
    Assert ((Import)-eq1) 'cancelled live command can retry'; Assert-Tools

    New-Fixture 'cancel-history' ($giant+"`n"+$context+"`n"+$firstToken+"`n")
    Prepare $true; [void](Batch $true (256*1024))
    $cursor=[long](Scalar 'SELECT cursor_offset FROM recent_history_work')
    $savedState=[string](Scalar 'SELECT body_scan_state FROM recent_history_work')
    $cts=[Threading.CancellationTokenSource]::new()
    $cancelProgress=[CommandExecutionSyntheticCancelProgress]::new($cts,($cursor+65536))
    try {
        $failure=$null
        try { [void](Batch $true (256*1024) $cancelProgress $cts.Token) } catch { $failure=$_.Exception.ToString() }
        Assert ($null-ne$failure -and $failure.Contains('OperationCanceledException')) 'history cancellation propagates'
        Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$cursor) 'history cancellation rolls back continuation cursor'
        Assert ((Scalar 'SELECT body_scan_state FROM recent_history_work')-eq$savedState) 'history cancellation rolls back parser state'
        Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'cancelled partial proof creates no tool metadata'
    } finally { $cts.Dispose() }
    Complete $true (256*1024); Assert $batch.Completed 'cancelled history resumes'; Assert-Tools

    New-ReplacementFixture 'replacement-reject'
    [IO.File]::WriteAllText($path,$nextToken+"`n"+$reject['usageItem']+"`n",$utf8)
    for ($i=0;$i-lt2;$i++) {
        $failure=$null
        try { [void](Replace) } catch { $failure=$_.Exception.ToString() }
        Assert (-not [string]::IsNullOrWhiteSpace($failure)) 'unsafe replacement rejects'
        Assert-ReplacementPreserved
    }

    New-ReplacementFixture 'replacement-cancel'
    [IO.File]::WriteAllText($path,$nextToken+"`n"+$giant+"`n",$utf8)
    $cts=[Threading.CancellationTokenSource]::new()
    $cancelProgress=[CommandExecutionSyntheticCancelProgress]::new($cts,(1024*1024+65536))
    try {
        $failure=$null
        try { [void](Replace $cancelProgress $cts.Token) } catch { $failure=$_.Exception.ToString() }
        Assert ($null-ne$failure -and $failure.Contains('OperationCanceledException')) 'replacement cancellation propagates'
        Assert-ReplacementPreserved
    } finally { $cts.Dispose() }
    Assert ((Replace)-eq1) 'complete replacement retries after cancellation'; Assert-Tools

    New-ReplacementFixture 'replacement-insert-failure'
    Sql "CREATE TRIGGER fail_command_insert BEFORE INSERT ON tool_records BEGIN SELECT RAISE(ABORT,'synthetic command metadata failure'); END"
    [IO.File]::WriteAllText($path,$nextToken+"`n"+$giant+"`n",$utf8)
    $failure=$null
    try { [void](Replace) } catch { $failure=$_.Exception.ToString() }
    Assert ($null-ne$failure -and $failure.Contains('synthetic command metadata failure')) 'tool metadata insertion failure propagates'
    Assert-ReplacementPreserved
    Sql 'DROP TRIGGER fail_command_insert'
    Assert ((Replace)-eq1) 'metadata insertion failure retries atomically'; Assert-Tools; Assert-SafeStorage

    Write-Output 'CommandExecution streaming synthetic tests passed.'
}
finally {
    if ($null-ne$db) { $db.Close(); $db.Dispose() }
    $resolved=[IO.Path]::GetFullPath($temp)
    $prefix=[IO.Path]::GetFullPath((Get-Item -LiteralPath ([IO.Path]::GetTempPath())).FullName).TrimEnd('\')+'\TokenRader-CommandExecutionSynthetic-'
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
