[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll=Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$utf8=[Text.UTF8Encoding]::new($false)
$none=[Threading.CancellationToken]::None
$end=[DateTimeOffset]::Parse('2026-10-05T12:00:00Z'); $cutoff=$end.AddHours(-24)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-ToolProjectionSynthetic-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$temp=[IO.Path]::GetFullPath($temp)
$db=$null
function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('TOOL OUTPUT PROJECTION FAILED: '+$message) } }
function Scalar([string]$sql) {
    $cmd=$db.CreateCommand()
    try { $cmd.CommandText=$sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
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
function Reply([string]$output,[string]$time='2026-10-05T02:00:00Z',[string]$type='custom_tool_call_output',[bool]$late=$false) {
    $fields='"type":"'+$type+'","call_id":"ID_BODY_SENTINEL","output":'+$output+',"internal_chat_message_metadata_passthrough":'+$opaque
    if ($late) {
        $fields='"output":'+$output+',"internal_chat_message_metadata_passthrough":'+$opaque+',"call_id":"ID_BODY_SENTINEL","type":"'+$type+'"'
        return '{"metadata":'+$opaque+',"payload":{'+$fields+'},"timestamp":"'+$time+'","type":"response_item"}'
    }
    return '{"timestamp":"'+$time+'","type":"response_item","payload":{'+$fields+'},"metadata":'+$opaque+'}'
}
function Import {
    return [TokenRaderIndexer]::ImportFile($db,$path,0,$frozen,'synthetic-root','',1L,$null,$none)
}
function Assert-Images([int]$images,[int]$rows=1) {
    $usage=[TokenRaderIndexer]::AggregateToolUsage($db,$cutoff,$end)
    Assert ($usage.InputImages-eq$images) 'only actual output-array input images counted'
    Assert ($usage.TotalToolCalls-eq0 -and $usage.GeneratedImages-eq0 -and $usage.ComputerScreenshots-eq0) 'tool reply/metadata cannot manufacture calls or other images'
    Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq$rows) 'one source-offset image row per validated output'
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE event_kind<>'image_input' OR tool_name<>'image_input' OR call_key<>''")-eq0) 'projection retains only input-image metadata'
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE event_key LIKE '%BODY_SENTINEL%' OR timestamp LIKE '%BODY_SENTINEL%' OR model LIKE '%BODY_SENTINEL%'")-eq0) 'body and identifiers never retained'
}
function Assert-Tokens {
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq2 -and (Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'surrounding tokens are neither lost nor duplicated'
    Assert ((Scalar "SELECT call_input FROM token_records WHERE timestamp='2026-10-05T03:00:00Z'")-eq7) 'reply never overwrites cumulative baseline'
}
function Complete-History([long]$budget,[bool]$recent) {
    $progress=[hashtable]::Synchronized(@{})
    if ($recent) { [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff,$end,$progress,$none) }
    else { [void][TokenRaderIndexer]::InitializeFromNow($db,$fixtureRoot,$progress,$none) }
    [long]$processed=0
    for ($i=0;$i-lt100;$i++) {
        if ($recent) { $batch=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,$budget,5000,$progress,$none) }
        else { $batch=[TokenRaderIndexer]::BackfillHistoryBatch($db,$budget,5000,$progress,$none) }
        Assert ($batch.ProcessedBytes-ge0 -and $batch.ProcessedBytes-le$budget) 'bounded batch'
        $processed+=$batch.ProcessedBytes
        foreach ($table in @('history_gaps','recent_history_work')) {
            $state=[string](Scalar ('SELECT COALESCE(MAX(body_scan_state),'''') FROM '+$table))
            Assert ($state.Length-le600 -and -not $state.Contains('BODY_SENTINEL')) 'bounded body-free persistent continuation'
        }
        if ($i-eq0 -and -not $batch.Completed) {
            Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'partial output array never submits images'
            $db.Close(); $db.Dispose(); $script:db=$null; Open-Db
        }
        if ($batch.Completed) { break }
        Assert ($batch.ProcessedBytes-gt0 -and $batch.EligibleFiles-gt0) 'safe continuation remains eligible'
    }
    Assert ($batch.Completed -and $processed-eq$frozen) 'reopened history completes every frozen byte exactly once'
}
try {
    $context='{"timestamp":"2026-10-05T00:30:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $first='{"timestamp":"2026-10-05T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}'
    $after=$first.Replace('01:00:00Z','03:00:00Z').Replace('"total_token_usage":{"input_tokens":7','"total_token_usage":{"input_tokens":14').Replace('"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},','')
    $opaque='{"METADATA_BODY_SENTINEL":{"type":"input_image","image_url":"URL_BODY_SENTINEL","nested":[{"type":"function_call"},{"type":"computer_screenshot"},{"type":"token_count","input_tokens":999999}]}}'
    $text='TEXT_BODY_SENTINEL \"type\":\"input_image\" \"image_url\":\"LOOKALIKE_BODY_SENTINEL\" \n \u96ea '+[char]0x96ea+[char]::ConvertFromUtf32(0x1f600)
    $giant=$text+('x'*(2*1024*1024))
    foreach ($type in @('custom_tool_call_output','function_call_output')) {
        foreach ($body in @($text,$giant)) {
            $output='[{"type":"input_text","text":"'+$body+'"},{"type":"input_image","image_url":"URL_BODY_SENTINEL","detail":"auto"},{"image_url":"URL_BODY_SENTINEL","type":"input_image"}]'
            foreach ($late in @($false,$true)) {
                $reply=Reply $output '2026-10-05T02:00:00Z' $type $late
                New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n"+$reply+"`n"+$after+"`n")
                Assert ((Import)-eq2) 'small/giant reply keeps surrounding usage'
                Assert-Images 2; Assert-Tokens
                [void](Import); Assert-Images 2; Assert-Tokens
            }
            New-Fixture ([guid]::NewGuid().ToString('N')) ((Reply ('"'+$body+'"') '2026-10-05T02:00:00Z' $type)+"`n")
            [void](Import); Assert-Images 0 0
        }
    }
    $array='[{"type":"input_text","text":"'+$giant+'"},{"type":"input_image","image_url":"URL_BODY_SENTINEL"},{"type":"input_image","image_url":"URL_BODY_SENTINEL","detail":"low"}]'
    $large=Reply $array
    foreach ($recent in @($false,$true)) {
        New-Fixture ('history-'+$recent) ($context+"`n"+$first+"`n"+$large+"`n"+$after+"`n")
        Complete-History 65536 $recent
        Assert-Images 2; Assert-Tokens
    }
    # Event timestamps, not source filenames or opaque archive timestamps,
    # determine recent eligibility. The frozen upper endpoint excludes this
    # deliberately later sample (one hour beyond the prepared endpoint).
    foreach ($body in @($text,$giant)) {
        $output='[{"type":"input_text","text":"'+$body+'"},{"type":"input_image","image_url":"URL_BODY_SENTINEL"}]'
        $old=Reply $output '2026-10-04T11:00:00Z'
        $current=Reply $output '2026-10-05T02:00:00Z'
        $future=Reply $output '2026-10-05T13:00:00Z'
        New-Fixture ([guid]::NewGuid().ToString('N')) ($old+"`n"+$current+"`n"+$future+"`n")
        Complete-History 65536 $true
        Assert-Images 1
        Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE timestamp<>'2026-10-05T02:00:00.0000000+00:00'")-eq0) 'recent cutoff and frozen end both respected'
    }
    # Manual auxiliary tool backfill uses the same projection and lower cutoff.
    foreach ($body in @($text,$giant)) {
        $output='[{"type":"input_text","text":"'+$body+'"},{"type":"input_image","image_url":"URL_BODY_SENTINEL"}]'
        New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+(Reply $output '2026-10-04T11:00:00Z')+"`n"+(Reply $output)+"`n")
        [TokenRaderIndexer]::UpdateFileMetadata($db,$path,$frozen,[IO.File]::GetLastWriteTimeUtc($path).Ticks,$frozen,'synthetic-session','','','','synthetic-root')
        [void][TokenRaderIndexer]::BackfillRecentToolRecords($db,$cutoff.UtcDateTime.Ticks,1L,$none,$null)
        Assert-Images 1
        [void][TokenRaderIndexer]::BackfillRecentToolRecords($db,$cutoff.UtcDateTime.Ticks,2L,$none,$null)
        Assert-Images 1
        Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0) 'auxiliary image projection never adds tokens'
    }
    # Small invalid closed outputs may not fall back to regex interpretation.
    $small=Reply '[{"type":"input_image","image_url":"URL_BODY_SENTINEL"}]'
    foreach ($bad in @(
        $small.Replace('"image_url":"URL_BODY_SENTINEL"','"image_url":"URL_BODY_SENTINEL","unknown":0'),
        $small.Replace('"image_url":"URL_BODY_SENTINEL"','"image_url":"URL_BODY_SENTINEL","image_url":"duplicate"'),
        $small.Replace('"timestamp":"2026-10-05T02:00:00Z"','"timestamp":"bad"'),
        $small.Replace('"output":[','"output":[{"type":"other"},'),
        $small.Replace('"metadata":','"unknown_root":')
    )) {
        New-Fixture ([guid]::NewGuid().ToString('N')) ($bad+"`n")
        [void](Import); Assert-Images 0 0
    }
    New-Fixture 'giant-no-eol' ($context+"`n"+$first+"`n"+$large)
    $failed=$false
    try { [void](Import) } catch { $failed=$true }
    Assert $failed 'giant without complete EOL rejects'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq0 -and (Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'incomplete output rolls back all rows'
    Write-Host 'PASS Tool-output projection: true images only, opaque isolation, small/giant parity, cutoff/frozen end, EOL/reopen and source idempotence.'
} finally {
    if ($null-ne$db) { $db.Close(); $db.Dispose() }
    [System.Data.SQLite.SQLiteConnection]::ClearAllPools()
    $resolved=[IO.Path]::GetFullPath($temp)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('TokenRader-ToolProjectionSynthetic-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
