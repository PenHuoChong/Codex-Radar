[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll=Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-RecentFailureRepeat-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$utf8=[Text.UTF8Encoding]::new($false); $none=[Threading.CancellationToken]::None
$progress=[hashtable]::Synchronized(@{}); $db=$null
$end=[DateTimeOffset]::Parse('2026-10-05T12:00:00Z'); $cutoff=$end.AddHours(-24)
function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('RECENT FAILURE REPEAT FAILED: '+$message) } }
function Scalar([string]$sql) { $cmd=$db.CreateCommand(); try { $cmd.CommandText=$sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() } }
function Sql([string]$sql) { $cmd=$db.CreateCommand(); try { $cmd.CommandText=$sql; [void]$cmd.ExecuteNonQuery() } finally { $cmd.Dispose() } }
function Reopen {
    if($null-ne$script:db){$script:db.Close();$script:db.Dispose()}
    $script:db=[System.Data.SQLite.SQLiteConnection]::new($script:connection)
    $script:db.Open(); [TokenRaderIndexer]::CreateSchema($script:db)
}
function Fixture([string]$name) {
    $script:fixtureRoot=Join-Path $temp $name; [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $script:path=Join-Path $fixtureRoot 'synthetic.jsonl'
    $script:connection='Data Source='+(Join-Path $temp ($name+'.db'))+';Version=3;Pooling=False;'
    Reopen
    $script:step=0
    [IO.File]::WriteAllText($path,$script:before+"`n"+$script:unsafe+"`n"+$script:after+"`n"+$script:token+"`n",$utf8)
    $script:frozen=([IO.FileInfo]$path).Length
}
function Prepare([int]$minutes=[int]::MinValue) {
    if($minutes-eq[int]::MinValue){$script:step++;$minutes=$script:step}
    $script:prepared=[TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff.AddMinutes($minutes),$end.AddMinutes($minutes),$progress,$none)
}
function Complete {
    $script:bytes=0L
    for($i=0;$i-lt100;$i++) {
        $script:batch=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,256*1024,5000,$progress,$none)
        $script:bytes += [long]$batch.ProcessedBytes
        Assert ($batch.ProcessedBytes-ge0 -and $batch.ProcessedBytes-le256*1024) 'byte budget remains bounded'
        if($batch.Completed -or $batch.EligibleFiles-eq0){return}
    }
    throw 'synthetic failed pass did not reach its frozen endpoint'
}
function Failed {
    Assert (-not $batch.Completed -and $batch.BlockedReasons.Contains('oversized_line')) 'rejected record remains a coverage failure'
    Assert ($batch.BlockedFiles-eq1 -and $batch.EligibleFiles-eq0) 'failed pass ends blocked and ineligible'
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq(Scalar 'SELECT end_offset FROM recent_history_work')) 'retained failed cursor is at EOF only for reporting'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq1 -and (Scalar 'SELECT SUM(call_input) FROM token_records')-eq7) 'later valid rows remain intact without duplicates'
    Assert ([TokenRaderIndexer]::HasHistoryGapInRange($db,$cutoff.AddHours(1),$end)) 'failure never becomes strict coverage'
    Assert (([string][TokenRaderIndexer]::GetSetting($db,'recent_history_coverage_start'))-eq'') 'failure stores no completed coverage boundary'
}
function FreshReplay {
    Assert (-not $prepared.Completed -and $prepared.EligibleFiles-eq1) ('fresh retry has work, not a success (step '+$script:step+', eligible '+$prepared.EligibleFiles+', reason '+($prepared.BlockedReasons-join',')+')')
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq0) 'fresh retry starts at original gap'
    Assert ((Scalar 'SELECT model FROM recent_history_work')-eq'' -and (Scalar 'SELECT has_total FROM recent_history_work')-eq0) 'fresh retry never restores post-failure model or cumulative state'
    Complete; Assert ($bytes-gt1024*1024) 'fresh retry revalidates the rejected record'
    Failed
}
try {
    $before='{"timestamp":"2026-10-05T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4"}}'
    $after='{"timestamp":"2026-10-05T02:00:00Z","type":"turn_context","payload":{"model":"gpt-5.5","service_tier":"priority"}}'
    $token='{"timestamp":"2026-10-05T03:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"output_tokens":0},"total_token_usage":{"input_tokens":7,"output_tokens":0}}}}'
    $unsafe='{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"text","text":"'+('x'*(2*1024*1024))+'"}],"unknown":true}}'
    Fixture 'repeat'; Prepare; Complete
    Assert ($bytes-eq$frozen) 'first failed pass scans its frozen bytes once'
    Failed
    Assert ((Scalar 'SELECT parser_version FROM recent_history_attempt_stamps')-eq[TokenRaderIndexer]::RecentHistoryParserVersion) 'attempt has intentional parser version'
    foreach($restart in @($false,$true,$true)) {
        if($restart){Reopen}
        Prepare; Assert (-not $prepared.Completed -and $prepared.BlockedFiles-eq1 -and $prepared.EligibleFiles-eq0) 'ordinary restart preserves failed status'
        Complete; Assert ($bytes-eq0) 'unchanged failure does not rescan body bytes'
        Failed
    }

    Assert ([TokenRaderIndexer]::ResetRecentHistoryBackfillRetries($db)-eq1) 'explicit recent retry invalidates suppression'
    Prepare; FreshReplay
    Prepare; Complete; Assert ($bytes-eq0) 'explicit retry is one replay, not permanent replay mode'; Failed
    [void][TokenRaderIndexer]::ResetHistoryBackfillRetries($db)
    Prepare; FreshReplay
    Prepare; Complete; Assert ($bytes-eq0) 'existing manual-history retry also performs only one replay'; Failed

    Sql 'UPDATE recent_history_attempt_stamps SET parser_version=0'
    Prepare; FreshReplay
    Prepare; Complete; Assert ($bytes-eq0) 'parser change permits one replay then suppresses unchanged failure'; Failed

    # A changed source cannot reuse its failed post-line cursor as a baseline.
    [IO.File]::AppendAllText($path,$after+"`n",$utf8)
    Prepare; FreshReplay
    Assert ((Scalar 'SELECT end_offset FROM recent_history_work')-eq([IO.FileInfo]$path).Length) 'append creates new frozen endpoint'
    Prepare; Complete; Assert ($bytes-eq0) 'appended source failure is then suppressed safely'; Failed
    Sql 'UPDATE recent_history_attempt_stamps SET last_write_ticks=last_write_ticks-1'
    Prepare; FreshReplay

    # Asking for an earlier cutoff requires a replay even if source is unchanged.
    Prepare -10; FreshReplay
    Prepare -9; Complete; Assert ($bytes-eq0) 'forward-compatible cutoff keeps blocked result reusable'; Failed

    # Old failures without a source/version stamp receive one conservative replay.
    Sql 'DELETE FROM recent_history_attempt_stamps'
    Prepare; FreshReplay
    Prepare; Complete; Assert ($bytes-eq0) 'legacy replay records a repeat-suppression stamp'; Failed

    # Source replacement is a separate, permanent guard—not a retry-cache entry.
    Sql "UPDATE history_gaps SET blocked_reason='source_replaced'"
    [void][TokenRaderIndexer]::ResetHistoryBackfillRetries($db)
    Sql 'UPDATE recent_history_attempt_stamps SET parser_version=0'
    Prepare; Complete
    Assert (-not $batch.Completed -and $batch.BlockedReasons.Contains('history_safety_block')) 'source replacement remains blocked after version/retry changes'
    Assert ($bytes-eq0 -and (Scalar 'SELECT blocked_reason FROM history_gaps')-eq'source_replaced') 'source replacement is never cleared or silently scanned'

    Fixture 'partial'
    Prepare
    [void][TokenRaderIndexer]::BackfillRecentHistoryBatch($db,256*1024,5000,$progress,$none)
    $cursor=Scalar 'SELECT cursor_offset FROM recent_history_work'; $state=Scalar 'SELECT body_scan_state FROM recent_history_work'
    Assert ($cursor-gt0 -and $cursor-lt$frozen) 'partial attempt has bounded progress'
    Reopen; Prepare
    Assert ((Scalar 'SELECT cursor_offset FROM recent_history_work')-eq$cursor) 'old partial success still resumes its cursor'
    Assert ((Scalar 'SELECT body_scan_state FROM recent_history_work')-eq$state) 'partial DFA continuation remains unchanged'
    Complete; Failed
    Write-Output 'Recent failed-pass repeat suppression synthetic tests passed.'
}
finally {
    if($null-ne$db){$db.Close();$db.Dispose()}
    $resolved=[IO.Path]::GetFullPath($temp)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\TokenRader-RecentFailureRepeat-'
    if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
