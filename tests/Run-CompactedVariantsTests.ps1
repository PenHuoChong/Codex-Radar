[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll = Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp = Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-CompactedVariantsSynthetic-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$utf8 = [Text.UTF8Encoding]::new($false)
$none = [Threading.CancellationToken]::None
$progress = [hashtable]::Synchronized(@{})
$end = [DateTimeOffset]::Parse('2026-10-05T12:00:00Z'); $cutoff = $end.AddHours(-24)
$db = $null
function Assert([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('COMPACTED VARIANTS FAILED: ' + $Message) } }
Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Text;
public static class CompactedVariantsProbe {
    public static bool Validate(Type indexer, string json, int budget) {
        Type t = indexer.GetNestedType("SafeOversizedBodyScan", BindingFlags.NonPublic);
        object scan = Activator.CreateInstance(t, true);
        Action<int> feed = (Action<int>)Delegate.CreateDelegate(typeof(Action<int>), scan, t.GetMethod("Feed"));
        byte[] bytes = Encoding.UTF8.GetBytes(json);
        for (int i=0; i<bytes.Length; i++) {
            feed(bytes[i]);
            if ((i+1)%budget == 0 || i == bytes.Length-1) {
                string saved = (string)t.GetMethod("Save").Invoke(scan, null), version = (string)t.GetProperty("Protocol").GetValue(scan,null);
                if ((version+"|638000000000000000|"+saved).Length > 600 || saved.Contains("SENTINEL")) throw new Exception("Unsafe continuation state.");
                if (!(bool)t.GetProperty("CanContinue").GetValue(scan,null)) return false;
                scan = Activator.CreateInstance(t, new object[] { saved, version });
                feed = (Action<int>)Delegate.CreateDelegate(typeof(Action<int>), scan, t.GetMethod("Feed"));
                if (!(bool)t.GetProperty("CanContinue").GetValue(scan,null)) throw new Exception("Continuation could not resume.");
            }
        }
        return (bool)t.GetProperty("Complete").GetValue(scan,null);
    }
    public static bool Legacy(Type indexer, bool invalid, bool unknown) {
        Type t = indexer.GetNestedType("CompactedBodyScan", BindingFlags.NonPublic);
        object scan = Activator.CreateInstance(t, true);
        Action<int> feed = (Action<int>)Delegate.CreateDelegate(typeof(Action<int>),scan,t.GetMethod("Feed"));
        foreach (byte b in Encoding.UTF8.GetBytes("{\"type\":\"compacted\",\"payload\":{\"")) feed(b);
        string[] state = ((string)t.GetMethod("Save").Invoke(scan,null)).Split(',');
        state[0] = unknown ? "99" : "1"; state[5] = "2047";
        if (invalid) state[1] = "1";
        scan = Activator.CreateInstance(t,new object[] { string.Join(",",state) });
        feed = (Action<int>)Delegate.CreateDelegate(typeof(Action<int>),scan,t.GetMethod("Feed"));
        foreach (byte b in Encoding.UTF8.GetBytes("guardian_history\":[],\"compaction_response_id\":null}}")) feed(b);
        return (bool)t.GetProperty("Complete").GetValue(scan,null);
    }
}
'@
function Scalar([string]$Sql) {
    $cmd=$db.CreateCommand()
    try { $cmd.CommandText=$Sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
}
function New-Fixture([string]$Name,[string]$Body) {
    if ($null -ne $script:db) { $script:db.Dispose() }
    $script:db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $script:db.Open(); [TokenRaderIndexer]::CreateSchema($script:db)
    $script:fixtureRoot=Join-Path $temp $Name; [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $script:path=Join-Path $fixtureRoot 'synthetic.jsonl'
    [IO.File]::WriteAllText($path,$Body,$utf8); $script:frozen=([IO.FileInfo]$path).Length
}
function Import([long]$Until=-1,[Threading.CancellationToken]$Cancel=$none) {
    if ($Until -lt 0) { $Until=$frozen }
    return [TokenRaderIndexer]::ImportFile($db,$path,0L,$Until,'synthetic-root','',1L,$null,$Cancel)
}
function New-Variant([bool]$Guardian,[string]$Text,[bool]$Late=$false) {
    $archive='[{"type":"function_call","name":"archive","call_id":"archive-call"},{"type":"input_image","image_url":"URL_SENTINEL"},{"type":"token_count","info":{"last_token_usage":{"input_tokens":999999}}},{"arbitrary":{"text":"'+$Text+'","nested":[null,true,false,-1.25e+3]}}]'
    $payload='"compaction_response_id":null,"latest_token_usage_record":'+$(if($Guardian){$script:latest}else{'null'})+',"message":"MESSAGE_SENTINEL","replacement_history":[],"replacement_history_metadata":[],"resume_metadata":{},"retained_context":{}'
    if ($Guardian) { $payload='"guardian_history":'+$archive+','+$payload }
    else { $payload+=',"first_window_id":"'+$Text+'"' }
    if ($Late) { return '{"payload":{'+$payload+'},"ordinal":1,"timestamp":"2026-10-05T02:00:00Z","type":"compacted"}' }
    return '{"timestamp":"2026-10-05T02:00:00Z","type":"compacted","ordinal":1,"payload":{'+$payload+'}}'
}
function Assert-Accounting {
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq 2 -and (Scalar 'SELECT SUM(call_input) FROM token_records') -eq 14) 'only real numeric events counted'
    Assert ((Scalar "SELECT call_input FROM token_records WHERE timestamp='2026-10-05T03:00:00Z'") -eq 7) 'checkpoint never advances total-only baseline'
    Assert ((Scalar 'SELECT COUNT(*) FROM tool_records') -eq 0) 'guardian archive tools/images not replayed'
}
function Batch([bool]$Recent,[long]$Budget) {
    if ($Recent) { return [TokenRaderIndexer]::BackfillRecentHistoryBatch($db,$Budget,5000,$progress,$none) }
    return [TokenRaderIndexer]::BackfillHistoryBatch($db,$Budget,5000,$progress,$none)
}
function Prepare([bool]$Recent) {
    if ($Recent) { [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff,$end,$progress,$none) }
    else { [void][TokenRaderIndexer]::InitializeFromNow($db,$fixtureRoot,$progress,$none) }
}
function Complete([bool]$Recent) {
    for ($i=0;$i -lt 40;$i++) {
        $script:batch=Batch $Recent 262144L
        Assert ($batch.ProcessedBytes -ge 0 -and $batch.ProcessedBytes -le 262144) 'bounded batch bytes'
        foreach ($table in @('history_gaps','recent_history_work')) {
            $saved=[string](Scalar ('SELECT COALESCE(MAX(body_scan_state),'''') FROM '+$table))
            Assert ($saved.Length -le 600 -and -not $saved.Contains('SENTINEL') -and -not $saved.Contains('guardian_history')) 'persisted state bounded with no body/key values'
        }
        if ($batch.Completed -or $batch.EligibleFiles -eq 0) { return }
        Assert ($batch.ProcessedBytes -gt 0) 'viable continuation progresses'
    }
    throw 'Synthetic compacted variants did not finish bounded work'
}
function Reject([long]$Until=-1) {
    $failed=$false
    try { [void](Import $Until) } catch {
        $failed=$true
        Assert (-not $_.Exception.Message.Contains('SENTINEL')) 'failure hides private archive content'
    }
    Assert $failed 'invalid archival variant rejected'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq 0 -and (Scalar 'SELECT COUNT(*) FROM tool_records') -eq 0) 'invalid import atomically rolls back numeric/tool metadata'
}
try {
    $context='{"timestamp":"2026-10-05T00:30:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $first='{"timestamp":"2026-10-05T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}'
    $after=$first.Replace('01:00:00Z','03:00:00Z').Replace('"total_token_usage":{"input_tokens":7','"total_token_usage":{"input_tokens":14').Replace('"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},','')
    $usage='{"input_tokens":999999,"cached_input_tokens":17,"output_tokens":4,"reasoning_output_tokens":2,"total_tokens":1000003,"cache_write_input_tokens":0}'
    $latest='{"response_id":"snapshot","root_turn_id":null,"session_id":"snapshot","thread_id":"snapshot","turn_id":"snapshot","usage":'+$usage+',"thread_token_usage":'+$usage+',"turn_token_usage":'+$usage+'}'
    $utf=[string][char]0x4E2D+[char]0xD83D+[char]0xDE00
    $text='GUARDIAN_BODY_SENTINEL\u4E2D\uD83D\uDE00'+$utf
    $large=$text+('x'*(3*1024*1024))
    foreach ($guardian in @($false,$true)) {
        foreach ($late in @($false,$true)) {
            $small=New-Variant $guardian $text $late
            Assert ([CompactedVariantsProbe]::Validate([TokenRaderIndexer],$small,1)) 'every byte restore including key12, UTF8/escapes and late type'
            foreach ($size in @('small','giant')) {
                $record=New-Variant $guardian $(if($size -eq 'giant'){$large}else{$text}) $late
                Assert ([CompactedVariantsProbe]::Validate([TokenRaderIndexer],$record,262144)) 'giant archive continuation validates'
                New-Fixture ('live-'+$guardian+'-'+$late+'-'+$size) ($context+"`n"+$first+"`n"+$record+"`n"+$after+"`n")
                Assert ((Import) -eq 2) 'new variants retain subsequent real token events'; Assert-Accounting
                [void][TokenRaderIndexer]::BackfillRecentToolRecords($db,$cutoff.UtcDateTime.Ticks,2L,$none,$progress)
                Assert-Accounting
            }
        }
    }
    Assert ([CompactedVariantsProbe]::Legacy([TokenRaderIndexer],$false,$false)) 'valid old key-opening state can resume appended schema'
    Assert (-not [CompactedVariantsProbe]::Legacy([TokenRaderIndexer],$true,$false)) 'invalid legacy state is not revived'
    Assert (-not [CompactedVariantsProbe]::Legacy([TokenRaderIndexer],$false,$true)) 'unknown state version cannot fake complete'
    $giant=New-Variant $true $large $true
    foreach ($recent in @($false,$true)) {
        New-Fixture ('history-'+$recent) ($giant+"`n"+$context+"`n"+$first+"`n"+$after+"`n")
        Prepare $recent; [void](Batch $recent 1L); Complete $recent
        Assert $batch.Completed 'new guardian archival history reaches complete EOL'; Assert-Accounting
    }
    $small=New-Variant $true $text
    $invalid=@(
        $small.Replace('"compaction_response_id":null','"compaction_response_id":false'),
        $small.Replace('"compaction_response_id":null','"compaction_response_id":{}'),
        $small.Replace('"compaction_response_id":null','"compaction_response_id":null,"compaction_response_id":null'),
        $small.Replace('"guardian_history":','"unknown_guardian_history":'),
        $small.Replace('"guardian_history":','"guardian_history":[],"guardian_history":'),
        $small.Replace('"guardian_history":[','"guardian_history":['+'],"bad":['),
        $small.Replace('"cached_input_tokens":17','"cached_input_tokens":-1'),
        $small.Replace('"arbitrary":','"arbitrary" '),
        $small.Replace('"nested":[null','"nested":[,null'),
        $small.Replace('"arbitrary":{"text":','"arbitrary":{"text":true,"text":'),
        $small.Replace('GUARDIAN_BODY_SENTINEL\u4E2D','GUARDIAN_BODY_SENTINEL\uXXXX')
    )
    # Opaque archive duplicate names are syntactically legal JSON and never
    # interpreted as semantic fields. Do not confuse them with outer duplicates.
    $opaqueDuplicate=$invalid[9]; $invalid=@($invalid[0..8]) + @($invalid[10])
    Assert ([CompactedVariantsProbe]::Validate([TokenRaderIndexer],$opaqueDuplicate,1)) 'opaque duplicate names retain no statistical meaning'
    foreach ($value in @('null','{}','"text"','123')) {
        $invalid+='{"type":"compacted","payload":{"compaction_response_id":null,"guardian_history":'+$value+'}}'
    }
    foreach ($bad in $invalid) {
        Assert (-not [CompactedVariantsProbe]::Validate([TokenRaderIndexer],$bad,1)) 'closed envelope and usage validation remain strict'
        New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n"+$bad+"`n"+$after+"`n"); Reject
    }
    $deep=('['*30)+'null'+(']'*30)
    $bad='{"type":"compacted","payload":{"guardian_history":'+$deep+'}}'
    Assert (-not [CompactedVariantsProbe]::Validate([TokenRaderIndexer],$bad,1)) 'opaque guardian nesting remains bounded'
    New-Fixture 'frozen-half-line' ($context+"`n"+$first+"`n"+$giant+"`n"+$after+"`n")
    Reject ($utf8.GetByteCount($context+"`n"+$first+"`n")+1500000L)
    New-Fixture 'no-eol' ($context+"`n"+$first+"`n"+$giant); Reject
    New-Fixture 'cancel' ($context+"`n"+$first+"`n"+$giant+"`n")
    $cts=[Threading.CancellationTokenSource]::new(); $cts.Cancel()
    $cancelled=$false
    try { [void](Import -Cancel $cts.Token) } catch { $cancelled=$true } finally { $cts.Dispose() }
    Assert ($cancelled -and (Scalar 'SELECT COUNT(*) FROM token_records') -eq 0) 'cancelled variant import rolls back'
    Write-Host ('COMPACTED_VARIANTS_TESTS_PASSED edition={0} version={1}' -f $PSVersionTable.PSEdition,$PSVersionTable.PSVersion)
} finally {
    if ($null -ne $db) { $db.Dispose() }
    $resolved=[IO.Path]::GetFullPath($temp)
    $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\TokenRader-CompactedVariantsSynthetic-'
    if ($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
