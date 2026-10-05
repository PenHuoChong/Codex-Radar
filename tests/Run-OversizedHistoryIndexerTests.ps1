[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll=Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-OversizedSynthetic-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$utf8=[Text.UTF8Encoding]::new($false)
$none=[Threading.CancellationToken]::None
$progress=[hashtable]::Synchronized(@{})
$end=[DateTimeOffset]::Parse('2026-10-05T12:00:00Z'); $cutoff=$end.AddHours(-24)
$db=$null
function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('OVERSIZED HISTORY FAILED: '+$message) } }
function Scalar([string]$sql) { $cmd=$db.CreateCommand(); try { $cmd.CommandText=$sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() } }
function Sql([string]$sql) { $cmd=$db.CreateCommand(); try { $cmd.CommandText=$sql; [void]$cmd.ExecuteNonQuery() } finally { $cmd.Dispose() } }
function New-Database {
    if($null-ne$script:db){$script:db.Close();$script:db.Dispose()}
    $script:db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $script:db.Open(); [TokenRaderIndexer]::CreateSchema($script:db)
}
function New-Fixture([string]$name,[string]$body,[string]$newline="`n") {
    New-Database
    $script:fixtureRoot=Join-Path $temp $name; [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $script:path=Join-Path $fixtureRoot 'synthetic.jsonl'
    [IO.File]::WriteAllText($path,$body+$newline+$script:context+$newline+$script:token+$newline,$utf8)
    $script:frozen=([IO.FileInfo]$path).Length
}
function Prepare([bool]$recent) {
    if($recent){[void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff,$end,$progress,$none)}
    else{[void][TokenRaderIndexer]::InitializeFromNow($db,$fixtureRoot,$progress,$none)}
}
function Complete([bool]$recent,[long]$budget) {
    $table=if($recent){'recent_history_work'}else{'history_gaps'}
    for($i=0;$i-lt100;$i++) {
        $script:batch=if($recent){[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,$budget,5000,$progress,$none)}else{[TokenRaderIndexer]::BackfillHistoryBatch($db,$budget,5000,$progress,$none)}
        Assert ($batch.ProcessedBytes-ge0 -and $batch.ProcessedBytes-le$budget) 'each call respects byte budget'
        $state=[string](Scalar ('SELECT body_scan_state FROM '+$table+' LIMIT 1'))
        Assert ($state.Length-lt600) 'continuation metadata stays constant size'
        Assert ($state-eq'' -or $state-match'^[0-9,|]+$') 'continuation stores no body, key or type text'
        if($batch.Completed -or $batch.EligibleFiles-eq0){return}
        Assert ($batch.ProcessedBytes-gt0) 'bounded continuation makes progress'
    }
    throw 'oversized fixture did not finish bounded work'
}
try {
    $context='{"timestamp":"2026-10-05T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $token='{"timestamp":"2026-10-05T02:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}'
    $text=('x'*(2*1024*1024))+'\"type\":\"event_msg\" 雪😀 \\ \n \u1234'
    $safe='{"timestamp":"2026-10-05T01:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","id":null,"phase":"final_answer","end_turn":true,"recipient":null,"content":[{"type":"output_text","text":"'+$text+'"},{"text":"hello","type":"input_text"},{"type":"text","text":"done"}]}}'
    $lateType='{"payload":{"content":[{"text":"'+$text+'","type":"output_text"}],"role":"user","type":"message"},"type":"response_item","timestamp":"2026-10-05T01:00:00Z"}'
    foreach($recent in @($true,$false)) {
        foreach($budget in @((256*1024),(1024*1024+65536),(3*1024*1024))) {
            New-Fixture ('safe-'+$recent+'-'+$budget) $safe
            Prepare $recent
            Complete $recent $budget
            Assert $batch.Completed 'validated pure-text giant does not block coverage'
            Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) 'following usage retains numeric accounting'
            Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE model='gpt-5.4' AND service_tier='priority'")-eq1) 'following context is not lost'
            Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'pure text generates no synthetic tool metadata'
            $table=if($recent){'recent_history_work'}else{'history_gaps'}
            Assert ((Scalar ('SELECT cursor_offset FROM '+$table+' LIMIT 1'))-eq$frozen) 'ends at frozen byte boundary'
        }
    }
    New-Fixture 'late-type' $lateType
    Prepare $true; Complete $true (256*1024)
    Assert $batch.Completed 'safe whole-line proof does not depend on early top-level type'
    foreach($role in @('user','assistant','system','developer')) {
        New-Fixture ('safe-role-'+$role) ($safe.Replace('"role":"assistant"',('"role":"'+$role+'"')))
        Prepare $true; Complete $true (256*1024)
        Assert $batch.Completed ('explicit safe role '+$role+' permits text-only coverage')
    }

    # Resuming a legitimate unfinished classifier is safe even when cutoff moves.
    New-Fixture 'resume' $safe
    Prepare $true
    $first=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,256*1024,5000,$progress,$none)
    $cursor=Scalar 'SELECT cursor_offset FROM recent_history_work'
    $state=Scalar 'SELECT body_scan_state FROM recent_history_work'
    Assert ($cursor-gt0 -and (Scalar 'SELECT discard_line FROM recent_history_work')-eq1) 'giant line has persisted bounded continuation'
    Assert ((Scalar 'SELECT blocked_reason FROM recent_history_work')-eq'') 'pending proof is incomplete, not an error or completion'
    [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff.AddMinutes(1),$end.AddMinutes(1),$progress,$none)
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$cursor) 'versioned classifier cursor resumes'
    Assert ((Scalar 'SELECT body_scan_state FROM recent_history_work')-eq$state) 'versioned classifier state resumes unchanged'
    [IO.File]::AppendAllText($path,$token+"`n",$utf8)
    Complete $true (256*1024)
    Assert ($batch.Completed -and (Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$frozen) 'classification does not chase appended EOF'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1) 'append is not imported as frozen history'

    # A version-1 DFA did not validate role or routing. Its suffix must never be
    # accepted under the stricter version-2 grammar; retry must rescan the gap.
    New-Fixture 'old-dfa' $safe
    Prepare $true
    [void][TokenRaderIndexer]::BackfillRecentHistoryBatch($db,256*1024,5000,$progress,$none)
    $oldState=([string](Scalar 'SELECT body_scan_state FROM recent_history_work')) -replace '^(2\|[0-9]+\|)2,','${1}1,'
    Assert ($oldState-match'^2\|[0-9]+\|1,') 'fixture contains retired grammar version'
    $cmd=$db.CreateCommand()
    try { $cmd.CommandText='UPDATE recent_history_work SET body_scan_state=@state'; [void]$cmd.Parameters.AddWithValue('@state',$oldState); [void]$cmd.ExecuteNonQuery() }
    finally { $cmd.Dispose() }
    Complete $true (256*1024)
    Assert (-not $batch.Completed -and $batch.BlockedReasons.Contains('oversized_line')) 'old DFA version cannot bypass stricter role proof'
    [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff.AddMinutes(1),$end.AddMinutes(1),$progress,$none)
    Assert ((Scalar 'SELECT blocked_reason FROM recent_history_work')-eq'oversized_line') 'unchanged rejected proof stays blocked without automatic repeated scan'
    [void][TokenRaderIndexer]::ResetRecentHistoryBackfillRetries($db)
    [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff.AddMinutes(1),$end.AddMinutes(1),$progress,$none)
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq0) 'old DFA rejection retries from original gap boundary'
    Complete $true (256*1024)
    Assert $batch.Completed 'old safe body recovers after version-2 whole-line rescan'

    # Old blocked cursors were not whole-line proof: both retry APIs must re-read.
    foreach($recent in @($true,$false)) {
        New-Fixture ('old-block-'+$recent) $safe
        Prepare $recent
        Sql "UPDATE history_gaps SET cursor_offset=end_offset,discard_line=0,blocked_reason='oversized_line',body_scan_state=''"
        if($recent) {
            Sql "UPDATE recent_history_work SET cursor_offset=end_offset,discard_line=0,blocked_reason='oversized_line',body_scan_state=''"
            Sql 'DELETE FROM recent_history_attempt_stamps' # Legacy rows predate attempt stamps.
            [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff.AddMinutes(1),$end.AddMinutes(1),$progress,$none)
            Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq0) 'old recent blocked state is restarted from gap boundary'
        } else {
            Assert ([TokenRaderIndexer]::ResetHistoryBackfillRetries($db)-eq1) 'manual old oversized retry is available'
            Assert ((Scalar 'SELECT cursor_offset FROM history_gaps')-eq0) 'manual retry rereads original gap'
        }
        Complete $recent (256*1024)
        Assert $batch.Completed 'old pure-text misclassification recovers only after rescan'
    }

    $huge='x'*(1024*1024+65536)
    $reject=@{
        toolRole=$safe.Replace('"role":"assistant"','"role":"tool"')
        unknownRole=$safe.Replace('"role":"assistant"','"role":"unknown"')
        routedRecipient=$safe.Replace('"recipient":null','"recipient":"functions.synthetic_tool"')
        allRecipient=$safe.Replace('"recipient":null','"recipient":"all"')
        missingRole=$safe.Replace('"role":"assistant",','')
        usage='{"type":"event_msg","payload":{"type":"token_count","padding":"'+$huge+'"}}'
        context='{"type":"turn_context","payload":{"model":"gpt-5.4","padding":"'+$huge+'"}}'
        tool='{"type":"response_item","payload":{"type":"function_call","name":"synthetic_tool","arguments":"'+$huge+'"}}'
        image='{"type":"response_item","payload":{"type":"message","content":[{"type":"input_image","image_url":"'+$huge+'"}]}}'
        unknown='{"type":"response_item","payload":{"body":"'+$huge+'"}}'
        duplicateRoot='{"type":"response_item","payload":{"type":"message","content":[{"type":"text","text":"'+$huge+'"}]},"type":"event_msg"}'
        duplicatePayload='{"type":"response_item","payload":{"type":"message","content":[{"type":"text","text":"'+$huge+'"}],"type":"token_count"}}'
        duplicateText='{"type":"response_item","payload":{"type":"message","content":[{"type":"text","text":"'+$huge+'","text":"duplicate"}]}}'
        missingText='{"type":"response_item","payload":{"type":"message","content":[{"type":"text","id":"'+$huge+'"}]}}'
        trailingComma='{"type":"response_item","payload":{"type":"message","content":[{"type":"text","text":"'+$huge+'",}]}}'
        trailingJson='{"type":"response_item","payload":{"type":"message","content":[{"type":"text","text":"'+$huge+'"}]}}{}'
        invalidEscape='{"type":"response_item","payload":{"type":"message","content":[{"type":"text","text":"'+$huge+'\q"}]}}'
        escapedType='{"type":"response_item","payload":{"type":"message","content":[{"type":"t\u0065xt","text":"'+$huge+'"}]}}'
    }
    foreach($name in $reject.Keys) {
        $body=$reject[$name].Replace('"type":"message","content"','"type":"message","role":"assistant","content"')
        New-Fixture ('reject-'+$name) $body
        Prepare $true; Complete $true (256*1024)
        Assert (-not $batch.Completed -and $batch.BlockedFiles-eq1) ($name+' never claims coverage')
        Assert ($batch.BlockedReasons.Contains('oversized_line')) ($name+' retains explicit safety rejection')
        Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) ($name+' does not prevent later valid rows importing')
        [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff.AddMinutes(1),$end.AddMinutes(1),$progress,$none)
        Complete $true (1024*1024+65536)
        Assert (-not $batch.Completed) ($name+' retry does not clear unknown usage by trusting a suffix')
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1) ($name+' replay is idempotent')
    }

    # CR at the byte-budget boundary must not truncate an event's CRLF offset.
    New-Fixture 'crlf' $safe "`r`n"
    Prepare $true
    $budget=$utf8.GetByteCount($safe)+1L
    $first=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,$budget,5000,$progress,$none)
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq($budget-1)) 'CR at batch end is retained for continuation'
    Complete $true (256*1024)
    Assert $batch.Completed 'split CRLF pure-text line completes'
    Assert ((Scalar 'SELECT source_offset_end FROM token_records')-eq$frozen) 'event source offset includes complete CRLF'

    # Persisted proof is tied to source creation metadata; replacement cannot be
    # spliced into the middle of an already validated string.
    New-Fixture 'replace' $safe
    Prepare $true
    [void][TokenRaderIndexer]::BackfillRecentHistoryBatch($db,256*1024,5000,$progress,$none)
    $before=Scalar 'SELECT cursor_offset FROM recent_history_work'
    $created=[IO.File]::GetCreationTimeUtc($path)
    [IO.File]::SetCreationTimeUtc($path,$created.AddMinutes(1))
    $batch=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,256*1024,5000,$progress,$none)
    Assert (-not $batch.Completed -and $batch.BlockedReasons.Contains('source_replaced')) 'source identity change rejects saved proof'
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$before) 'replacement does not advance old cursor'
    [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff.AddMinutes(1),$end.AddMinutes(1),$progress,$none)
    Assert (-not [TokenRaderIndexer]::GetRecentHistoryBackfillStatus($db).Completed) 'reprepare cannot erase source replacement guard'
    Assert ((Scalar "SELECT blocked_reason FROM history_gaps")-eq'source_replaced') 'replacement protection survives in original gap ledger'

    # Cancellation from genuine in-file progress rolls back both cursor and DFA.
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Threading;
public sealed class OversizedSyntheticCancelProgress : Hashtable {
    public CancellationTokenSource Source;
    public long Threshold;
    public OversizedSyntheticCancelProgress(CancellationTokenSource source, long threshold) { Source=source; Threshold=threshold; }
    public override object this[object key] {
        get { return base[key]; }
        set { base[key]=value; if (Convert.ToString(key)=="CurrentOffset" && Convert.ToInt64(value)>=Threshold) Source.Cancel(); }
    }
}
'@
    New-Fixture 'cancel' $safe
    Prepare $true
    [void][TokenRaderIndexer]::BackfillRecentHistoryBatch($db,256*1024,5000,$progress,$none)
    $before=Scalar 'SELECT cursor_offset FROM recent_history_work'; $state=Scalar 'SELECT body_scan_state FROM recent_history_work'
    $cts=[Threading.CancellationTokenSource]::new()
    $cancelProgress=[OversizedSyntheticCancelProgress]::new($cts,($before+65536))
    try { [void][TokenRaderIndexer]::BackfillRecentHistoryBatch($db,256*1024,5000,$cancelProgress,$cts.Token); throw 'missing cancellation' }
    catch { Assert ($_.Exception.ToString().Contains('OperationCanceledException')) ('in-file cancellation propagates: '+$_.Exception.ToString()) }
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$before) 'cancelled batch retains committed cursor'
    Assert ((Scalar 'SELECT body_scan_state FROM recent_history_work')-eq$state) 'cancelled batch retains committed classification state'
    $cts.Dispose(); Complete $true (256*1024)
    Assert $batch.Completed 'safe continuation can retry after worker cancellation'
    Write-Output 'Oversized history indexer synthetic tests passed.'
}
finally {
    if($null-ne$db){$db.Close();$db.Dispose()}
    $resolved=[IO.Path]::GetFullPath($temp)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\TokenRader-OversizedSynthetic-'
    if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
