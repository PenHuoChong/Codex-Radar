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
$end=[DateTimeOffset]::Parse('2026-10-05T12:00:00Z')
$cutoff=$end.AddHours(-24)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-CommandVariantsSynthetic-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$temp=[IO.Path]::GetFullPath($temp)
$db=$null

function Assert([bool]$value,[string]$message) { if (-not $value) { throw ('COMMAND VARIANT STREAMING FAILED: '+$message) } }
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
    $script:fixtureRoot=Join-Path $temp $name
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $script:path=Join-Path $fixtureRoot 'synthetic.jsonl'
    $script:dbPath=Join-Path $temp ($name+'.sqlite')
    [IO.File]::WriteAllText($path,$body,$utf8)
    $script:frozen=([IO.FileInfo]$path).Length
    Open-Db
}
function Command([string]$parsed,[string]$output='OUTPUT_BODY_SENTINEL',[string]$id='synthetic-call') {
    return '{"timestamp":"2026-10-05T02:00:00Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"'+$id+'","command":"COMMAND_BODY_SENTINEL","cwd":"PATH_BODY_SENTINEL","status":"completed","stdout":"'+$output+'","parsed_cmd":'+$parsed+'}}}'
}
function Assert-Usage {
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records')-eq2) 'exactly two surrounding usage events'
    Assert ((Scalar 'SELECT SUM(call_input) FROM token_records')-eq14) 'surrounding input is charged once each'
    Assert ((Scalar "SELECT COUNT(*) FROM token_records WHERE model='gpt-5.4' AND service_tier='priority'")-eq2) 'model/tier context survives command'
    $tools=[TokenRaderIndexer]::AggregateToolUsage($db,$cutoff,$end)
    Assert ($tools.TotalToolCalls-eq1 -and $tools.CompletedToolCalls-eq1) 'same invocation counts once'
}
function Prepare-Again($progress) {
    # Prepare accounts for catalogue elapsed time. Reuse its committed window,
    # not the older pre-catalogue request (which deliberately cannot resume).
    $savedCutoff=[DateTimeOffset]::Parse([string](Scalar "SELECT value FROM index_settings WHERE key='recent_history_cutoff'"))
    $savedEnd=[DateTimeOffset]::Parse([string](Scalar "SELECT value FROM index_settings WHERE key='recent_history_frozen_at'"))
    [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$savedCutoff,$savedEnd,$progress,$none)
}

# Delegate-based feeding avoids millions of PowerShell/reflection calls. Only
# synthetic bytes are used; continuation snapshots contain scanner metadata.
Add-Type -TypeDefinition @'
using System;
using System.Reflection;
public sealed class CommandVariantScanResult {
    public bool Accepted, Complete;
    public int MaximumStateLength, LegacyMigrations, FailureOffset, FailureMode, FailureDepth;
}
public static class CommandVariantScannerTest {
    static readonly BindingFlags Flags = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    public static CommandVariantScanResult Scan(Type indexer, byte[] bytes, int chunk, int legacyAt) {
        Type type=indexer.GetNestedType("CommandExecutionBodyScan",BindingFlags.NonPublic);
        object scanner=Activator.CreateInstance(type,true);
        Action<int> feed=(Action<int>)Delegate.CreateDelegate(typeof(Action<int>),scanner,type.GetMethod("Feed",Flags));
        Func<bool> live=(Func<bool>)Delegate.CreateDelegate(typeof(Func<bool>),scanner,type.GetProperty("CanContinue",Flags).GetGetMethod(true));
        var result=new CommandVariantScanResult();
        for(int i=0;i<bytes.Length;i++) {
            feed(bytes[i]);
            if(!live()) {
                int[] state=(int[])type.GetField("s",Flags).GetValue(scanner);
                result.FailureOffset=i; result.FailureMode=state[3]; result.FailureDepth=state[1]; break;
            }
            if((i+1)%chunk==0 || i+1==legacyAt) {
                string saved=(string)type.GetMethod("Save",Flags).Invoke(scanner,null);
                result.MaximumStateLength=Math.Max(result.MaximumStateLength,saved.Length);
                if(saved.Contains("BODY_SENTINEL")) throw new Exception("Opaque body leaked into state.");
                if(i+1==legacyAt) {
                    string[] parts=saved.Split('~'), values=parts[0].Split(',');
                    // Recreate an authentic v1 layout. Its only accepted
                    // parsed type was unknown; mode3 had no candidate mask.
                    if(values[4]=="7") { values[4]="3"; values[5]="0"; }
                    values[0]="1";
                    var old=new string[33]; Array.Copy(values,old,33);
                    parts[0]=string.Join(",",old); saved=string.Join("~",parts);
                    result.LegacyMigrations++;
                }
                scanner=Activator.CreateInstance(type,Flags,null,new object[]{saved},null);
                feed=(Action<int>)Delegate.CreateDelegate(typeof(Action<int>),scanner,type.GetMethod("Feed",Flags));
                live=(Func<bool>)Delegate.CreateDelegate(typeof(Func<bool>),scanner,type.GetProperty("CanContinue",Flags).GetGetMethod(true));
            }
        }
        result.Accepted=live();
        result.Complete=(bool)type.GetProperty("Complete",Flags).GetValue(scanner,null);
        return result;
    }
}
'@
function Scan([string]$record,[int]$chunk=65536,[int]$legacyAt=-1) {
    return [CommandVariantScannerTest]::Scan([TokenRaderIndexer],$utf8.GetBytes($record),$chunk,$legacyAt)
}

try {
    $context='{"timestamp":"2026-10-05T00:30:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $first='{"timestamp":"2026-10-05T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}'
    $next=$first.Replace('01:00:00Z','03:00:00Z').Replace('"total_token_usage":{"input_tokens":7','"total_token_usage":{"input_tokens":14')
    $opaque='BODY_SENTINEL \\ \" \n \u96ea \ud83d\ude00 '+[char]0x96ea+[char]::ConvertFromUtf32(0x1f600)
    $variants=@(
        ('[{"type":"unknown","cmd":"'+$opaque+'"}]'),
        ('[{"type":"read","cmd":"'+$opaque+'","name":"'+$opaque+'","path":"'+$opaque+'"}]'),
        ('[{"path":"'+$opaque+'","name":"'+$opaque+'","cmd":"'+$opaque+'","type":"read"}]'),
        ('[{"type":"list_files","cmd":"'+$opaque+'","path":null}]'),
        ('[{"type":"list_files","cmd":"'+$opaque+'","path":"'+$opaque+'"}]'),
        ('[{"type":"list_files","cmd":"'+$opaque+'"}]'),
        ('[{"type":"search","cmd":"'+$opaque+'","query":null,"path":null}]'),
        ('[{"path":"'+$opaque+'","query":"'+$opaque+'","cmd":"'+$opaque+'","type":"search"}]'),
        ('[{"type":"search","cmd":"'+$opaque+'"}]'),
        '[{"type":"read","cmd":"x","name":"n","path":"p"},{"type":"unknown","cmd":"x"},{"type":"search","cmd":"x","query":null},{"type":"list_files","cmd":"x"}]'
    )
    $variantIndex=0
    foreach ($parsed in $variants) {
        $variantIndex++
        $record=Command $parsed
        $scan=Scan $record 1
        Assert ($scan.Accepted -and $scan.Complete) ('known variant '+$variantIndex+' accepts every-byte continuation (offset='+$scan.FailureOffset+', mode='+$scan.FailureMode+', depth='+$scan.FailureDepth+')')
        Assert ($scan.MaximumStateLength-le575) 'bounded scanner state'
        New-Fixture ([guid]::NewGuid().ToString('N')) ($context+"`n"+$first+"`n"+$record+"`n"+$next+"`n")
        Assert ([TokenRaderIndexer]::ImportFile($db,$path,0,$frozen,'synthetic-root','',1L,$null,$none)-eq2) 'small record keeps surrounding tokens'
        Assert-Usage
        [void][TokenRaderIndexer]::ImportFile($db,$path,0,$frozen,'synthetic-root','',1L,$null,$none)
        Assert-Usage
    }
    $bad=@(
        '[{"type":"unknown","cmd":"x","path":"p"}]',
        '[{"type":"read","cmd":"x","name":"n"}]',
        '[{"type":"read","cmd":"x","name":"n","path":null}]',
        '[{"type":"read","cmd":"x","name":"n","path":"p","query":null}]',
        '[{"type":"list_files","cmd":"x","name":"n"}]',
        '[{"type":"search","cmd":"x","query":1}]',
        '[{"type":"search","cmd":"x","path":{}}]',
        '[{"type":"search","cmd":"x","mystery":"x"}]',
        '[{"type":"unknown","cmd":"x","cmd":"y"}]',
        '[{"type":"read","type":"unknown","cmd":"x","name":"n","path":"p"}]',
        '[{"type":"other","cmd":"x"}]',
        '[{"type":"unknown"}]',
        '[{"type":"read","cmd":"x","name":null,"path":"p"}]',
        '[{"type":"unknown","cmd":"bad\q"}]',
        '[{"type":"unknown","cmd":"x",}]'
    )
    foreach ($parsed in $bad) {
        $scan=Scan (Command $parsed) 7
        Assert (-not $scan.Accepted -and -not $scan.Complete) 'unknown/duplicate/type/missing/invalid fields reject'
    }
    $incomplete=Command '[{"type":"read","cmd":"x","name":"n","path":"p"}]'
    $scan=Scan $incomplete.Substring(0,$incomplete.Length-1) 11
    Assert ($scan.Accepted -and -not $scan.Complete) 'half line never proves completion'
    $invalidUtf8=$utf8.GetBytes((Command '[{"type":"unknown","cmd":"UTF8_MARKER"}]'))
    $at=$utf8.GetByteCount((Command '[{"type":"unknown","cmd":"UTF8_MARKER"}]').Substring(0,(Command '[{"type":"unknown","cmd":"UTF8_MARKER"}]').IndexOf('UTF8_MARKER')))
    $invalidUtf8[$at]=0xc0
    $scan=[CommandVariantScannerTest]::Scan([TokenRaderIndexer],$invalidUtf8,5,-1)
    Assert (-not $scan.Accepted) 'invalid UTF8 cannot pass opaque strings'

    # These three snapshots exercise genuine v1-compatible positions.
    $legacy=Command '[{"type":"unknown","cmd":"CMD_BODY_SENTINEL"}]' 'OUTPUT_BODY_SENTINEL'
    foreach ($marker in @('OUTPUT_BODY_','"type":"unk','CMD_BODY_')) {
        $position=$legacy.LastIndexOf($marker)+$marker.Length
        Assert ($position-gt$marker.Length) 'legacy fixture split exists'
        $scan=Scan $legacy 1000000 ($utf8.GetByteCount($legacy.Substring(0,$position)))
        Assert ($scan.Accepted -and $scan.Complete -and $scan.LegacyMigrations-eq1) 'v1 output/type/cmd state migrates safely'
    }

    # The read command itself exceeds 8 MiB, so batches stop inside cmd rather
    # than only inside stdout. Duplicate completions share a synthetic call id.
    $large='BODY_SENTINEL'+('x'*(8*1024*1024+257))+$opaque
    $giant=Command ('[{"type":"read","cmd":"'+$large+'","name":"'+$opaque+'","path":"'+$opaque+'"}]')
    foreach ($budget in @((8*1024*1024),65536)) {
        New-Fixture ('history-'+$budget) ($context+"`n"+$first+"`n"+$giant+"`n"+(Command '[{"type":"unknown","cmd":"x"}]')+"`n"+$next+"`n")
        $progress=[hashtable]::Synchronized(@{})
        [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff,$end,$progress,$none)
        [long]$processed=0
        for ($i=0;$i-lt300;$i++) {
            $batch=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,$budget,5000,$progress,$none)
            Assert ($batch.ProcessedBytes-ge0 -and $batch.ProcessedBytes-le$budget) 'byte budget is respected'
            $processed+=$batch.ProcessedBytes
            $state=[string](Scalar "SELECT COALESCE(MAX(body_scan_state),'') FROM recent_history_work")
            Assert ($state.Length-le600 -and -not $state.Contains('BODY_SENTINEL')) 'persisted continuation is bounded and body-free'
            if ($i-eq0) {
                Assert (-not $batch.Completed) 'giant command needs another batch'
                Assert ((Scalar 'SELECT COUNT(*) FROM tool_records')-eq0) 'unfinished command does not submit tool metadata'
                $db.Close(); $db.Dispose(); $db=$null; Open-Db
                Prepare-Again $progress
            }
            if ($batch.Completed) { break }
            Assert ($batch.EligibleFiles-gt0 -and $batch.ProcessedBytes-gt0) 'continued work remains safely eligible'
        }
        Assert ($batch.Completed) 'bounded/reopened history completes'
        Assert ($processed-eq$frozen) ('resume processes each frozen byte once (processed='+$processed+', frozen='+$frozen+', budget='+$budget+')')
        Assert-Usage
        Prepare-Again $progress
        $retry=[TokenRaderIndexer]::BackfillRecentHistoryBatch($db,$budget,5000,$progress,$none)
        Assert ($retry.Completed -and $retry.ProcessedBytes-eq0) 'repeat preparation reuses completed history'
        Assert-Usage
    }
    Write-Host 'PASS Command variant streaming: strict variants, v1 migration, UTF8, exact tokens/tools, 8MiB/64KiB batches and reopen.'
} finally {
    if ($null-ne$db) { $db.Close(); $db.Dispose() }
    [System.Data.SQLite.SQLiteConnection]::ClearAllPools()
    $resolved=[IO.Path]::GetFullPath($temp)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('TokenRader-CommandVariantsSynthetic-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
