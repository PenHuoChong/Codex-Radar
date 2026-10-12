[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll=Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
Import-Module (Join-Path $root 'TokenRader.Core.psm1') -Force
$prices=Get-TokenRaderPrices -PricingPath (Join-Path $root 'pricing.json')
$utf8=[Text.UTF8Encoding]::new($false)
$none=[Threading.CancellationToken]::None
$end=[DateTimeOffset]::Parse('2026-10-05T12:00:00Z'); $cutoff=$end.AddHours(-24)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-MessageFileChangeSynthetic-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$temp=[IO.Path]::GetFullPath($temp)
$db=$null
function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('MESSAGE/FILECHANGE STREAMING FAILED: '+$message) } }
function Scalar([string]$sql) {
    $cmd=$db.CreateCommand()
    try { $cmd.CommandText=$sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
}
function Sql([string]$sql) {
    $cmd=$db.CreateCommand()
    try { $cmd.CommandText=$sql; [void]$cmd.ExecuteNonQuery() } finally { $cmd.Dispose() }
}
function Open-Db {
    $script:db=[System.Data.SQLite.SQLiteConnection]::new(('Data Source="'+$dbPath+'";Version=3;'))
    $db.Open(); [TokenRaderIndexer]::CreateSchema($db)
}
function New-Fixture([string]$name,[string]$body) {
    if ($null-ne$db) { $db.Close(); $db.Dispose(); $script:db=$null }
    $script:fixtureRoot=Join-Path $temp $name; [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $script:path=Join-Path $fixtureRoot 'synthetic.jsonl'
    $script:dbPath=Join-Path $temp ($name+'.sqlite')
    [IO.File]::WriteAllText($path,$body,$utf8); $script:frozen=([IO.FileInfo]$path).Length
    Open-Db
}
function Import([long]$start=0,$progress=$null,[Threading.CancellationToken]$cancel=$none) {
    return [TokenRaderIndexer]::ImportFile($db,$path,$start,([IO.FileInfo]$path).Length,'synthetic-root','',1L,$progress,$cancel)
}
function Message([string]$text,[bool]$late=$false) {
    $content='[{"type":"input_text","text":"'+$text+'"},{"type":"input_image","image_url":"IMAGE_URL_BODY_SENTINEL","detail":"auto"}]'
    if ($late) {
        return '{"metadata":'+$opaque+',"ordinal":1,"payload":{"internal_chat_message_metadata_passthrough":'+$opaque+',"content":'+$content+',"role":"user","id":"synthetic-message","type":"message"},"type":"response_item","timestamp":"2026-10-05T02:00:00Z"}'
    }
    return '{"timestamp":"2026-10-05T02:00:00Z","type":"response_item","ordinal":1,"payload":{"type":"message","id":"synthetic-message","role":"user","content":'+$content+',"internal_chat_message_metadata_passthrough":'+$opaque+'},"metadata":'+$opaque+'}'
}
function FileChange([string]$content,[bool]$late=$false) {
    $changes='{"E:\\synthetic\\PATH_BODY_SENTINEL.txt":{"type":"add","content":"'+$content+'"},"OTHER_PATH_BODY_SENTINEL":{"content":"small","type":"add"}}'
    if ($late) {
        return '{"payload":{"item":{"changes":'+$changes+',"stderr":"STDERR_BODY_SENTINEL","stdout":"STDOUT_BODY_SENTINEL","status":"completed","id":"synthetic-patch","type":"FileChange"},"completed_at_ms":1234567,"started_at_ms":1234566,"turn_id":"synthetic-turn","thread_id":"synthetic-thread","type":"item_completed"},"type":"event_msg","timestamp":"2026-10-05T02:00:00Z"}'
    }
    return '{"timestamp":"2026-10-05T02:00:00Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"synthetic-thread","turn_id":"synthetic-turn","started_at_ms":1234566,"completed_at_ms":1234567,"item":{"type":"FileChange","id":"synthetic-patch","status":"completed","stdout":"STDOUT_BODY_SENTINEL","stderr":"STDERR_BODY_SENTINEL","changes":'+$changes+'}}}'
}
function Assert-Accounting([bool]$isMessage) {
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq2 -and (Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'surrounding usage is charged exactly once'
    Assert ((Scalar "SELECT call_input FROM token_records WHERE timestamp='2026-10-05T03:00:00Z'")-eq7) 'opaque text does not overwrite cumulative baseline'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE model='gpt-5.4' AND service_tier='priority'")-eq2) 'model/tier context survives body discard'
    $usage=[TokenRaderIndexer]::AggregateToolUsage($db,$cutoff,$end)
    if ($isMessage) {
        Assert ($usage.InputImages-eq1 -and $usage.TotalToolCalls-eq0 -and $usage.CompletedToolCalls-eq0) 'message counts only its one real image'
        Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE event_kind='image_input' AND image_count=1")-eq1) 'message image projects once by source position'
    } else {
        Assert ($usage.InputImages-eq0 -and $usage.TotalToolCalls-eq1 -and $usage.CompletedToolCalls-eq1) 'FileChange completion counts once by invocation identity'
        Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE event_kind='tool_call' AND tool_name='apply_patch' AND call_key='synthetic-patch'")-ge1) 'FileChange retains only safe apply_patch metadata'
    }
    Assert ($usage.GeneratedImages-eq0 -and $usage.ComputerScreenshots-eq0) 'body/metadata examples do not manufacture images'
    $pricedUsage=[pscustomobject]@{Input=[long](Scalar 'SELECT SUM(call_input) FROM token_records');Cached=0L;Uncached=14L;Output=0L;ReasoningOutput=0L;Total=14L;CacheHitRate=0.0}
    $cost=Get-TokenRaderCost -Usage $pricedUsage -Model 'gpt-5.4' -PricingDocument $prices -ServiceTier 'priority'
    Assert ($cost.Known -and $cost.TotalCost-gt0) 'first query after import computes positive API dollars'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE model LIKE '%BODY_SENTINEL%' OR service_tier LIKE '%BODY_SENTINEL%'")-eq0) 'body does not leak into token metadata'
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE tool_name LIKE '%BODY_SENTINEL%' OR call_key LIKE '%BODY_SENTINEL%' OR model LIKE '%BODY_SENTINEL%' OR event_key LIKE '%BODY_SENTINEL%'")-eq0) 'body/path/URL does not leak into tool metadata'
}
function Assert-State {
    foreach ($table in @('history_gaps','recent_history_work')) {
        $state=[string](Scalar ('SELECT COALESCE(MAX(body_scan_state),'''') FROM '+$table))
        Assert ($state.Length-le600 -and -not $state.Contains('BODY_SENTINEL') -and -not $state.Contains('synthetic\\')) 'persisted state is bounded and contains no text/path/URL'
    }
}
function Prepare-Again($progress) {
    $savedCutoff=[DateTimeOffset]::Parse([string](Scalar "SELECT value FROM index_settings WHERE key='recent_history_cutoff'"))
    $savedEnd=[DateTimeOffset]::Parse([string](Scalar "SELECT value FROM index_settings WHERE key='recent_history_frozen_at'"))
    [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$savedCutoff,$savedEnd,$progress,$none)
}
function Complete-History([bool]$recent,[bool]$isMessage) {
    $progress=[hashtable]::Synchronized(@{})
    if ($recent) { [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff,$end,$progress,$none) }
    else { [void][TokenRaderIndexer]::InitializeFromNow($db,$fixtureRoot,$progress,$none) }
    [long]$processed=0
    for ($i=0;$i-lt150;$i++) {
        if ($recent) { $batch=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,65536L,5000,$progress,$none) }
        else { $batch=[TokenRaderIndexer]::BackfillHistoryBatch($db,65536L,5000,$progress,$none) }
        Assert ($batch.ProcessedBytes-ge0 -and $batch.ProcessedBytes-le65536) '64 KiB byte budget respected'
        $processed+=$batch.ProcessedBytes; Assert-State
        if ($i-eq0) {
            Assert (-not $batch.Completed -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'partial record submits no tool/image metadata'
            $db.Close(); $db.Dispose(); $script:db=$null; Open-Db
            if ($recent) { Prepare-Again $progress }
        }
        if ($batch.Completed) { break }
        Assert ($batch.ProcessedBytes-gt0 -and $batch.EligibleFiles-gt0) 'continuation remains eligible'
    }
    Assert ($batch.Completed -and $processed-eq$frozen) 'reopened batches process each frozen byte exactly once'
    Assert-Accounting $isMessage
    if ($recent) {
        Prepare-Again $progress
        $retry=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,65536L,5000,$progress,$none)
        Assert ($retry.Completed -and $retry.ProcessedBytes-eq0) 'committed recent cursor reused on repeated preparation'
    }
    Assert-Accounting $isMessage
}

# Direct scanner probes make strict shape validation independent of the
# ordinary deserializer's small-record fallback. All strings are synthetic.
Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Reflection;
using System.Threading;
public sealed class MessageFileChangeScanResult { public bool Accepted, Complete; public int MaximumStateLength; }
public static class MessageFileChangeScannerTest {
    static readonly BindingFlags Flags=BindingFlags.Instance|BindingFlags.Public|BindingFlags.NonPublic;
    public static MessageFileChangeScanResult Scan(Type indexer,string scannerName,byte[] bytes,int chunk) {
        Type type=indexer.GetNestedType(scannerName,BindingFlags.NonPublic);
        if(type==null) throw new Exception("Missing scanner: "+scannerName);
        object scan=Activator.CreateInstance(type,true);
        Action<int> feed=(Action<int>)Delegate.CreateDelegate(typeof(Action<int>),scan,type.GetMethod("Feed",Flags));
        Func<bool> live=(Func<bool>)Delegate.CreateDelegate(typeof(Func<bool>),scan,type.GetProperty("CanContinue",Flags).GetGetMethod(true));
        var result=new MessageFileChangeScanResult();
        for(int i=0;i<bytes.Length;i++) {
            feed(bytes[i]); if(!live()) break;
            if((i+1)%chunk==0) {
                string state=(string)type.GetMethod("Save",Flags).Invoke(scan,null);
                result.MaximumStateLength=Math.Max(result.MaximumStateLength,state.Length);
                if(state.Contains("BODY_SENTINEL")) throw new Exception("Body/path/URL leaked into scanner state.");
                scan=Activator.CreateInstance(type,Flags,null,new object[]{state},null);
                feed=(Action<int>)Delegate.CreateDelegate(typeof(Action<int>),scan,type.GetMethod("Feed",Flags));
                live=(Func<bool>)Delegate.CreateDelegate(typeof(Func<bool>),scan,type.GetProperty("CanContinue",Flags).GetGetMethod(true));
            }
        }
        result.Accepted=live(); result.Complete=(bool)type.GetProperty("Complete",Flags).GetValue(scan,null);
        return result;
    }
}
public sealed class MessageFileChangeCancelProgress:Hashtable {
    readonly CancellationTokenSource source; readonly long threshold;
    public MessageFileChangeCancelProgress(CancellationTokenSource source,long threshold) { this.source=source;this.threshold=threshold; }
    public override object this[object key] {
        get {return base[key];}
        set {base[key]=value;if(Convert.ToString(key)=="CurrentOffset" && Convert.ToInt64(value)>=threshold)source.Cancel();}
    }
}
'@
function Scan([string]$record,[bool]$isMessage,[int]$chunk=65536) {
    $scanner=if ($isMessage) {'ToolOutputBodyScan'} else {'CommandExecutionBodyScan'}
    return [MessageFileChangeScannerTest]::Scan([TokenRaderIndexer],$scanner,$utf8.GetBytes($record),$chunk)
}
try {
    $context='{"timestamp":"2026-10-05T00:30:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $first='{"timestamp":"2026-10-05T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}'
    $after=$first.Replace('01:00:00Z','03:00:00Z').Replace('"total_token_usage":{"input_tokens":7','"total_token_usage":{"input_tokens":14').Replace('"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},','')
    $opaque='{"METADATA_BODY_SENTINEL":{"type":"input_image","image_url":"FAKE_URL_BODY_SENTINEL","examples":[{"type":"function_call","call_id":"fake"},{"type":"computer_screenshot"},{"type":"token_count","info":{"total_token_usage":{"input_tokens":999999}}}]}}'
    $text='TEXT_BODY_SENTINEL \\ \"type\":\"input_image\" \"type\":\"token_count\" \n \u96ea \ud83d\ude00 '+[char]0x96ea+[char]::ConvertFromUtf32(0x1f600)
    $huge=$text+('x'*(2*1024*1024+257))
    foreach ($isMessage in @($true,$false)) {
        foreach ($body in @($text,$huge)) {
            foreach ($late in @($false,$true)) {
                $record=if ($isMessage) {Message $body $late} else {FileChange $body $late}
                $scan=Scan $record $isMessage $(if ($body-eq$text) {1} else {65536})
                Assert ($scan.Accepted -and $scan.Complete -and $scan.MaximumStateLength-le600) 'closed shape accepts reordered fields and resumable body-free scanning'
                New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n"+$record+"`n"+$after+"`n")
                Assert ((Import)-eq2) 'small/oversized import preserves surrounding tokens'
                Assert-Accounting $isMessage
                Assert ((Import)-eq0) 'source-offset replay is idempotent'; Assert-Accounting $isMessage
                if (-not $isMessage) {
                    $start=([IO.FileInfo]$path).Length
                    [IO.File]::AppendAllText($path,$record+"`n",$utf8)
                    Assert ((Import $start)-eq0) 'duplicate completion adds no tokens'; Assert-Accounting $false
                }
            }
        }
        $large=if ($isMessage) {Message $huge} else {FileChange $huge}
        foreach ($recent in @($false,$true)) {
            New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n"+$large+"`n"+$after+"`n")
            Complete-History $recent $isMessage
        }
        $small=if ($isMessage) {Message $text} else {FileChange $text}
        $bad=@(
            $small.Replace('"timestamp":','"unknown_outer":'),
            $small.Replace('"type":"'+$(if ($isMessage) {'response_item'} else {'event_msg'})+'",','"type":"'+$(if ($isMessage) {'response_item'} else {'event_msg'})+'","type":"'+$(if ($isMessage) {'response_item'} else {'event_msg'})+'",'),
            $small.Replace('"payload":{','"payload":{"unknown_payload":0,'),
            $small.Replace('"payload":{','"payload":{"type":"'+$(if ($isMessage) {'message'} else {'item_completed'})+'",'),
            $small.Replace('"timestamp":"2026-10-05T02:00:00Z"','"timestamp":"bad"'),
            $small.Replace('TEXT_BODY_SENTINEL','BAD\q'),
            $small.Substring(0,$small.Length-1)
        )
        if ($isMessage) {
            $bad+=@(
                $small.Replace('"input_image","image_url":','"input_image","unknown_item":0,"image_url":'),
                $small.Replace('"image_url":"IMAGE_URL_BODY_SENTINEL"','"image_url":"IMAGE_URL_BODY_SENTINEL","image_url":"duplicate"'),
                $small.Replace('"metadata":'+$opaque,'"metadata":null'),
                $small.Replace('"internal_chat_message_metadata_passthrough":'+$opaque,'"internal_chat_message_metadata_passthrough":[]')
            )
        } else {
            $bad+=@(
                $small.Replace('"item":{','"item":{"unknown_item":0,'),
                $small.Replace('"item":{','"item":{"id":"duplicate",'),
                $small.Replace('"type":"add"','"type":"update"'),
                $small.Replace('"type":"add","content":','"type":"add","unknown_change":0,"content":'),
                $small.Replace('"content":"'+$text+'"','"content":"'+$text+'","content":"duplicate"'),
                $small.Replace('"completed_at_ms":1234567','"completed_at_ms":{}')
            )
        }
        foreach ($invalid in $bad) {
            $scan=Scan $invalid $isMessage 7
            Assert (-not $scan.Complete) 'unknown/duplicate/unsupported/malformed shapes cannot validate'
            # Pad the discarded text, preserving the exact invalid structure.
            $giantInvalid=$invalid.Replace($text,$huge)
            if ($utf8.GetByteCount($giantInvalid)-le1048576) {
                $giantInvalid=$invalid.Replace('BODY_SENTINEL','BODY_SENTINEL'+('z'*(2*1024*1024)))
            }
            New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n")
            Assert ((Import)-eq1) 'seed committed source baseline before failure'
            $start=$frozen
            [IO.File]::AppendAllText($path,$after+"`n"+$giantInvalid+"`n",$utf8)
            $rejected=$false
            try { [void](Import $start) } catch { $rejected=$true }
            Assert ($rejected -and (Scalar 'SELECT COUNT(*) FROM token_records')-eq1 -and (Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) 'invalid giant rolls back preceding new usage but retains committed source'
            Assert ((Scalar 'SELECT parsed_offset FROM file_metadata')-eq$start -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'failure leaves original source cursor and no fabricated metadata'
        }
        New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n"+$large)
        $rejected=$false
        try { [void](Import) } catch { $rejected=$true }
        Assert ($rejected -and (Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'complete JSON without full line ending rolls back source transaction'
        New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n"+$large+"`n"+$after+"`n")
        $cts=[Threading.CancellationTokenSource]::new()
        $progress=[MessageFileChangeCancelProgress]::new($cts,1114112L)
        $cancelled=$false
        try { [void](Import 0 $progress $cts.Token) } catch { $cancelled=$_.Exception.ToString().Contains('OperationCanceledException') } finally { $cts.Dispose() }
        Assert ($cancelled -and (Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM file_metadata')-eq0 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'in-record cancellation rolls back every source write'
        Assert ((Import)-eq2) 'cancelled source safely retries'; Assert-Accounting $isMessage
        New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n"+$large+"`n"+$after+"`n")
        $progress=[hashtable]::Synchronized(@{})
        [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff,$end,$progress,$none)
        $partial=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,65536L,5000,$progress,$none)
        Assert (-not $partial.Completed) 'source shrink fixture has a committed pending continuation'
        [IO.File]::WriteAllText($path,$context+"`n"+$first+"`n",$utf8)
        $batch=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,65536L,5000,$progress,$none)
        Assert (-not $batch.Completed -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'changed/shrunk source never claims complete or emits partial metadata'
        Assert-State
    }
    # A failure stamp from the preceding parser version may suppress repeated
    # failures, but never prove coverage. Upgrade must revisit the original
    # missing interval rather than resume the reporting-only post-failure EOF.
    foreach ($supported in @($true,$false)) {
        $record=Message $huge
        if (-not $supported) { $record=$record.Replace('"ordinal":1','"ordinal":1,"unsupported_outer":0') }
        New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n"+$record+"`n"+$after+"`n")
        $progress=[hashtable]::Synchronized(@{})
        [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff,$end,$progress,$none)
        $priorVersion=[TokenRaderIndexer]::RecentHistoryParserVersion-1
        Sql ("UPDATE recent_history_work SET cursor_offset=end_offset,discard_line=0,body_scan_state='',blocked_reason='oversized_line'; UPDATE recent_history_attempt_stamps SET parser_version="+$priorVersion)
        Assert ([TokenRaderIndexer]::HasHistoryGapInRange($db,$cutoff,$end)) 'old rejected stamp is a gap, never valid coverage'
        $db.Close(); $db.Dispose(); $script:db=$null; Open-Db
        Prepare-Again $progress
        Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq0) 'parser upgrade rewinds original rejected gap'
        [long]$processed=0
        for ($i=0;$i-lt100;$i++) {
            $batch=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,65536L,5000,$progress,$none)
            $processed+=$batch.ProcessedBytes; Assert-State
            if ($batch.Completed -or $batch.EligibleFiles-eq0) { break }
        }
        Assert ($processed-eq$frozen) 'version replay validates every original frozen byte'
        if ($supported) { Assert $batch.Completed 'supported former rejection completes after upgrade'; Assert-Accounting $true }
        else {
            Assert (-not $batch.Completed -and $batch.BlockedFiles-eq1 -and $batch.BlockedReasons.Contains('oversized_line')) 'truly unknown structure stays blocked after upgrade'
            Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'rejected metadata does not become a real image'
            Assert ([TokenRaderIndexer]::HasHistoryGapInRange($db,$cutoff,$end)) 'rejected replay cannot claim historical coverage'
        }
    }
    Write-Host 'PASS Message/FileChange streaming: strict small/giant parity, opaque isolation, real image/tool counts, positive dollars, 64KiB reopen, rollback and cancellation.'
} finally {
    if ($null-ne$db) { $db.Close(); $db.Dispose() }
    [System.Data.SQLite.SQLiteConnection]::ClearAllPools()
    $resolved=[IO.Path]::GetFullPath($temp)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('TokenRader-MessageFileChangeSynthetic-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
