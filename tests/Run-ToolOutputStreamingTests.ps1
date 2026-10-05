[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll = Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp = Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-ToolOutputSynthetic-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$utf8 = [Text.UTF8Encoding]::new($false)
$none = [Threading.CancellationToken]::None
$progress = [hashtable]::Synchronized(@{})
$end = [DateTimeOffset]::Parse('2026-10-05T12:00:00Z'); $cutoff = $end.AddHours(-24)
$db = $null
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw ('TOOL OUTPUT STREAMING FAILED: ' + $Message) } }
# Reflection is bound once into a typed delegate, not invoked per byte.
Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Text;
public static class ToolOutputSyntheticProbe {
    public static string Validate(Type indexer, string json, int budget, bool everyByte) {
        Type scanType = indexer.GetNestedType("SafeOversizedBodyScan", BindingFlags.NonPublic);
        object scan = Activator.CreateInstance(scanType, true);
        Action<int> feed = (Action<int>)Delegate.CreateDelegate(typeof(Action<int>), scan, scanType.GetMethod("Feed"));
        MethodInfo save = scanType.GetMethod("Save");
        PropertyInfo protocol = scanType.GetProperty("Protocol"), complete = scanType.GetProperty("Complete"), continuing = scanType.GetProperty("CanContinue");
        byte[] bytes = Encoding.UTF8.GetBytes(json);
        for (int i = 0; i < bytes.Length; i++) {
            feed(bytes[i]);
            if (everyByte || (i+1)%budget == 0 || i == bytes.Length-1) {
                string saved = (string)save.Invoke(scan, null), version = (string)protocol.GetValue(scan, null);
                if ((version + "|638000000000000000|" + saved).Length > 600) throw new Exception("State exceeded 600 characters.");
                if (saved.Contains("BODY_SENTINEL") || saved.Contains("METADATA_SENTINEL") || saved.Contains("OUTPUT_ID_SENTINEL")) throw new Exception("State contains private value.");
                if (!(bool)continuing.GetValue(scan, null)) return "rejected";
                scan = Activator.CreateInstance(scanType, new object[] { saved, version });
                feed = (Action<int>)Delegate.CreateDelegate(typeof(Action<int>), scan, scanType.GetMethod("Feed"));
                if (!(bool)continuing.GetValue(scan, null)) throw new Exception("Saved candidate could not resume.");
            }
        }
        return (bool)complete.GetValue(scan, null) ? "complete" : "incomplete";
    }
    public static bool UnknownStateRejects(Type indexer, string saved, string version, string suffix) {
        Type t = indexer.GetNestedType("SafeOversizedBodyScan", BindingFlags.NonPublic);
        object scan = Activator.CreateInstance(t, new object[] { saved, version });
        Action<int> feed = (Action<int>)Delegate.CreateDelegate(typeof(Action<int>), scan, t.GetMethod("Feed"));
        foreach (byte b in Encoding.UTF8.GetBytes(suffix)) feed(b);
        return !(bool)t.GetProperty("Complete").GetValue(scan, null);
    }
    public static int Images(Type indexer, string json) {
        Type t = indexer.GetNestedType("ToolOutputBodyScan", BindingFlags.NonPublic);
        object scan = Activator.CreateInstance(t, true);
        Action<int> feed = (Action<int>)Delegate.CreateDelegate(typeof(Action<int>), scan, t.GetMethod("Feed"));
        foreach (byte b in Encoding.UTF8.GetBytes(json)) feed(b);
        object projection = t.GetProperty("Projection").GetValue(scan, null);
        return projection == null ? 0 : (int)projection.GetType().GetField("InputImages").GetValue(projection);
    }
}
'@
function Scalar([string]$Sql) {
    $cmd = $db.CreateCommand()
    try { $cmd.CommandText = $Sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() }
}
function New-Fixture([string]$Name, [string]$Body) {
    if ($null -ne $script:db) { $script:db.Dispose() }
    $script:db = [System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $script:db.Open(); [TokenRaderIndexer]::CreateSchema($script:db)
    $script:fixtureRoot = Join-Path $temp $Name; [void][IO.Directory]::CreateDirectory($fixtureRoot)
    $script:path = Join-Path $fixtureRoot 'synthetic.jsonl'
    [IO.File]::WriteAllText($path, $Body, $utf8); $script:frozen = ([IO.FileInfo]$path).Length
}
function Import([long]$Until = -1, $State = $null, [Threading.CancellationToken]$Cancel = $none) {
    if ($Until -lt 0) { $Until = $frozen }
    return [TokenRaderIndexer]::ImportFile($db, $path, 0L, $Until, 'synthetic-root', '', 1L, $State, $Cancel)
}
function Assert-Accounting([int]$Images = 0) {
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq 2) 'only real before/after token events retained'
    Assert ((Scalar 'SELECT SUM(call_input) FROM token_records') -eq 14) 'tool reply never changes token baseline'
    Assert ((Scalar "SELECT call_input FROM token_records WHERE timestamp='2026-10-05T03:00:00Z'") -eq 7) 'total-only after event remains delta 7'
    Assert ((Scalar "SELECT COALESCE(SUM(image_count),0) FROM tool_records WHERE event_kind='image_input'") -eq $Images) 'only validated output array images are counted'
    Assert ((Scalar "SELECT COUNT(*) FROM tool_records WHERE event_kind<>'image_input'") -eq 0) 'tool reply never adds tool calls or other image kinds'
    Assert ((Scalar 'SELECT COUNT(*) FROM tool_records') -eq $(if ($Images -gt 0) { 1 } else { 0 })) 'image reply uses one source-offset event'
}
function New-Output([string]$Output, [string]$Type = 'custom_tool_call_output', [string]$Order = 'normal') {
    $payload = '"type":"' + $Type + '","id":"OUTPUT_ID_SENTINEL","call_id":"OUTPUT_ID_SENTINEL","output":"' + $Output + '","internal_chat_message_metadata_passthrough":' + $script:opaque
    if ($Order -eq 'payload-first') {
        $payload = '"output":"' + $Output + '","internal_chat_message_metadata_passthrough":' + $script:opaque + ',"call_id":null,"id":null,"type":"' + $Type + '"'
        return '{"payload":{' + $payload + '},"metadata":' + $script:opaque + ',"ordinal":1,"timestamp":"2026-10-05T02:00:00Z","type":"response_item"}'
    }
    if ($Order -eq 'metadata-first') { return '{"metadata":' + $script:opaque + ',"payload":{' + $payload + '},"timestamp":"2026-10-05T02:00:00Z","ordinal":1,"type":"response_item"}' }
    if ($Order -eq 'timestamp-type-last') { return '{"timestamp":"' + ('t' * 48) + '","ordinal":1,"payload":{' + $payload + '},"metadata":' + $script:opaque + ',"type":"response_item"}' }
    return '{"timestamp":"2026-10-05T02:00:00Z","type":"response_item","ordinal":1,"payload":{' + $payload + '},"metadata":' + $script:opaque + '}'
}
function Prepare([bool]$Recent) {
    if ($Recent) { [void][TokenRaderIndexer]::PrepareRecentHistory($db,$fixtureRoot,$cutoff,$end,$progress,$none) }
    else { [void][TokenRaderIndexer]::InitializeFromNow($db,$fixtureRoot,$progress,$none) }
}
function New-ImageOutput([string]$Text, [string]$Image, [string]$Order = 'normal') {
    $array = '[{"type":"input_text","text":"' + $Text + '"},{"image_url":"' + $Image + '","detail":"auto","type":"input_image"},{"type":"input_image","image_url":"SECOND_IMAGE_SENTINEL"}]'
    $reply = New-Output 'OUTPUT_PLACEHOLDER' 'custom_tool_call_output' $Order
    return $reply.Replace('"output":"OUTPUT_PLACEHOLDER"','"output":' + $array)
}
function Batch([bool]$Recent, [long]$Budget) {
    if ($Recent) { return [TokenRaderIndexer]::BackfillRecentHistoryBatch($db,$Budget,5000,$progress,$none) }
    return [TokenRaderIndexer]::BackfillHistoryBatch($db,$Budget,5000,$progress,$none)
}
function Assert-State {
    foreach ($table in @('history_gaps','recent_history_work')) {
        $state = [string](Scalar ('SELECT COALESCE(MAX(body_scan_state),'''') FROM ' + $table))
        Assert ($state.Length -le 600) 'persistent continuation <=600'
        Assert (-not $state.Contains('SENTINEL') -and -not $state.Contains('response_item') -and
            -not $state.Contains('input_image')) 'persistent continuation contains only bounded parser state'
    }
}
function Reject-Live {
    $failure = ''
    try { [void](Import) } catch { $failure = $_.Exception.Message }
    Assert (-not [string]::IsNullOrWhiteSpace($failure)) ('unsafe giant reply rejects: ' + $script:CaseLabel)
    Assert (-not $failure.Contains('SENTINEL')) 'failure never exposes output values'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq 0 -and
        (Scalar 'SELECT COUNT(*) FROM tool_records') -eq 0) 'unsafe live import rolls back all numeric/tool rows'
}
try {
    $context = '{"timestamp":"2026-10-05T00:30:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $first = '{"timestamp":"2026-10-05T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},"total_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}'
    $after = $first.Replace('01:00:00Z','03:00:00Z').Replace('"total_token_usage":{"input_tokens":7','"total_token_usage":{"input_tokens":14')
    $after = $after.Replace('"last_token_usage":{"input_tokens":7,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0},','')
    $opaque = '{"METADATA_SENTINEL":{"type":"input_image","image_url":"synthetic","tool":{"type":"function_call","name":"synthetic","call_id":"synthetic"},"token_count":{"input_tokens":999999},"nested":[null,true,false,-1.25e+3,{"type":"computer_screenshot"}]}}'
    $small = 'BODY_SENTINEL token_count input_image function_call'
    $huge = $small + ('x' * (2*1024*1024))
    foreach ($type in @('custom_tool_call_output','function_call_output')) {
        foreach ($order in @('normal','payload-first','metadata-first')) {
            $shortReply = New-Output $small $type $order
            Assert ([ToolOutputSyntheticProbe]::Validate([TokenRaderIndexer],$shortReply,1,$true) -eq 'complete') 'every-byte candidate save/restore across arbitrary field order'
            foreach ($size in @('small','giant')) {
                $reply = New-Output $(if ($size -eq 'small') { $small } else { $huge }) $type $order
                New-Fixture ($type + '-' + $order + '-' + $size) ($context + "`n" + $first + "`n" + $reply + "`n" + $after + "`n")
                Assert ((Import) -eq 2) 'live import continues after validated reply'
                Assert-Accounting
            }
        }
    }
    $minimal = '{"type":"response_item","payload":{"type":"custom_tool_call_output","output":""}}'
    Assert ([ToolOutputSyntheticProbe]::Validate([TokenRaderIndexer],$minimal,1,$true) -eq 'complete') 'optional timestamp and ids are not invented requirements'
    Assert ([ToolOutputSyntheticProbe]::Validate([TokenRaderIndexer],(New-Output $small 'custom_tool_call_output' 'timestamp-type-last'),1,$true) -eq 'complete') 'long timestamp first and root type last remains <=600 at every byte'
    $utf = [string][char]0x4E2D + [char]0xD83D + [char]0xDE00
    $escaped = '\u4E2D\uD83D\uDE00\\\"\n' + $utf
    $reply = New-Output ($huge + $escaped) 'custom_tool_call_output' 'payload-first'
    Assert ([ToolOutputSyntheticProbe]::Validate([TokenRaderIndexer],$reply,262144,$false) -eq 'complete') 'large byte-budget restore retains no body'
    Assert ([ToolOutputSyntheticProbe]::Validate([TokenRaderIndexer],(New-Output $escaped),1,$true) -eq 'complete') 'every-byte raw UTF8 and escape continuation'
    foreach ($order in @('normal','payload-first','metadata-first')) {
        $imageReply = New-ImageOutput $small 'IMAGE_URL_SENTINEL' $order
        Assert ([ToolOutputSyntheticProbe]::Validate([TokenRaderIndexer],$imageReply,1,$true) -eq 'complete') 'array item type-last and timestamp-late every-byte state restore'
        Assert ([ToolOutputSyntheticProbe]::Images([TokenRaderIndexer],$imageReply) -eq 2) 'opaque nested image names are excluded from projection'
        foreach ($size in @('small','giant-text','giant-image')) {
            $imageReply = New-ImageOutput $(if ($size -eq 'giant-text') { $huge + $escaped } else { $small }) $(if ($size -eq 'giant-image') { 'IMAGE_URL_SENTINEL' + ('a' * (2*1024*1024)) } else { 'IMAGE_URL_SENTINEL' }) $order
            New-Fixture ('array-' + $order + '-' + $size) ($context + "`n" + $first + "`n" + $imageReply + "`n" + $after + "`n")
            Assert ((Import) -eq 2) 'array import retains subsequent tokens'
            Assert-Accounting 2
            [void](Import)
            Assert-Accounting 2
        }
    }
    $imageReply = New-ImageOutput ($huge + $escaped) 'IMAGE_URL_SENTINEL' 'payload-first'
    Assert ([ToolOutputSyntheticProbe]::Validate([TokenRaderIndexer],$imageReply,262144,$false) -eq 'complete') 'giant array resumes across body/item fields without URL retention'
    foreach ($recent in @($false,$true)) {
        New-Fixture ('image-history-' + $recent) ($imageReply + "`n" + $context + "`n" + $first + "`n" + $after + "`n")
        Prepare $recent; [void](Batch $recent 1L); Assert-State
        $done=$false
        for ($i=0; $i -lt 40; $i++) {
            $batch = Batch $recent 262144L; Assert-State
            if ($batch.Completed) { $done=$true; break }
            Assert ($batch.ProcessedBytes -gt 0) 'image history progresses'
        }
        Assert $done 'image history only completes after full validated EOL'
        Assert-Accounting 2
    }
    $imageGood = New-ImageOutput $huge 'IMAGE_URL_SENTINEL'
    $imageInvalid = @(
        $imageGood.Replace('"type":"input_image"','"type":"unknown_image"'),
        $imageGood.Replace('"image_url":"SECOND_IMAGE_SENTINEL"','"image_url":"SECOND_IMAGE_SENTINEL","text":"wrong-shape"'),
        $imageGood.Replace('"image_url":"SECOND_IMAGE_SENTINEL"','"unknown":"SECOND_IMAGE_SENTINEL"'),
        $imageGood.Replace('"detail":"auto"','"detail":"auto","detail":"auto"'),
        $imageGood.Replace('"type":"input_text","text":','"type":"input_text","image_url":'),
        $imageGood.Replace('"type":"input_text","text":','"type":"input_text","detail":"auto","text":'),
        $imageGood.Replace('"image_url":"SECOND_IMAGE_SENTINEL"','"image_url":null'),
        $imageGood.Replace('"image_url":"SECOND_IMAGE_SENTINEL"','"image_url":{}'),
        $imageGood.Replace('"timestamp":"2026-10-05T02:00:00Z",',''),
        $imageGood.Replace('2026-10-05T02:00:00Z','not-a-date'),
        $imageGood.Replace('"output":[','"output":[null,'),
        $imageGood.Replace('"output":[','"output":[[],')
    )
    foreach ($bad in $imageInvalid) {
        Assert ([ToolOutputSyntheticProbe]::Validate([TokenRaderIndexer],$bad,262144,$false) -ne 'complete') 'unsafe/unknown image array never reaches projection'
        Assert ([ToolOutputSyntheticProbe]::Images([TokenRaderIndexer],$bad) -eq 0) 'invalid image array cannot emit partial image metadata'
        New-Fixture ('reject-image-' + [guid]::NewGuid().ToString('N')) ($context + "`n" + $first + "`n" + $bad + "`n" + $after + "`n")
        $script:CaseLabel='invalid-image-array'; Reject-Live
    }
    foreach ($recent in @($false,$true)) {
        foreach ($budget in @(262144L,1114112L)) {
            New-Fixture ('history-' + $recent + '-' + $budget) ($reply + "`n" + $context + "`n" + $first + "`n" + $after + "`n")
            Prepare $recent
            $initial = Batch $recent 1L
            Assert ($initial.ProcessedBytes -eq 1) 'tiny initial batch persists four candidates'
            Assert-State
            $done = $false
            for ($i=0; $i -lt 40; $i++) {
                $batch = Batch $recent $budget
                Assert ($batch.ProcessedBytes -ge 0 -and $batch.ProcessedBytes -le $budget) 'history respects byte budget'
                Assert-State
                if ($batch.Completed) { $done=$true; break }
                Assert ($batch.ProcessedBytes -gt 0) ('bounded history progresses recent=' + $recent + ' budget=' + $budget + ' blocked=' + $batch.BlockedFiles + ' reasons=' + ($batch.BlockedReasons -join ','))
            }
            Assert $done 'validated reply clears history block at complete line only'
            Assert-Accounting
        }
    }
    $good = New-Output $huge
    $invalid = @(
        $good.Replace('"metadata":','"unknown_root":'),
        $good.Replace('"internal_chat_message_metadata_passthrough":','"unknown_payload":'),
        $good.Replace('"ordinal":1','"ordinal":1,"ordinal":2'),
        $good.Replace('"output":"','"output":"duplicate","output":"'),
        $good.Replace('"type":"response_item"','"type":"response_item","type":"response_item"'),
        $good.Replace('"type":"custom_tool_call_output"','"type":"custom_tool_call_output","type":"custom_tool_call_output"'),
        $good.Replace('"output":"' + $huge + '"','"output":["' + $huge + '"]'),
        $good.Replace('"output":"' + $huge + '"','"output":null'),
        $good.Replace('"output":"' + $huge + '"','"output":123'),
        $good.Replace('"call_id":"OUTPUT_ID_SENTINEL"','"call_id":false'),
        $good.Replace('"timestamp":"2026-10-05T02:00:00Z"','"timestamp":{}'),
        $good.Replace(',"metadata":' + $opaque,',"metadata":null'),
        $good.Replace('"internal_chat_message_metadata_passthrough":' + $opaque,'"internal_chat_message_metadata_passthrough":[]'),
        $good.Replace('"type":"response_item",',''),
        $good.Replace('"type":"custom_tool_call_output",',''),
        $good.Replace('"type":"computer_screenshot"','"type":"computer_screenshot",'),
        $good.Replace('-1.25e+3','01'),
        $good.Replace('"nested":[','"nested":[,'),
        $good.Replace('"METADATA_SENTINEL"','"BAD\q"'),
        $good.Substring(0,$good.Length-1)
    )
    $deep = ('{"nested":' * 30) + 'null' + ('}' * 30)
    $invalid += $good.Replace(',"metadata":' + $opaque,',"metadata":' + $deep)
    $caseIndex = 0
    foreach ($bad in $invalid) {
        $script:CaseLabel = 'invalid-' + $caseIndex; $caseIndex++
        if ($utf8.GetByteCount($bad) -le 1048576) {
            $bad = $bad.Replace('"METADATA_SENTINEL":','"ballast":"' + $huge + '","METADATA_SENTINEL":')
        }
        New-Fixture ('reject-' + [guid]::NewGuid().ToString('N')) ($context + "`n" + $first + "`n" + $bad + "`n" + $after + "`n")
        Reject-Live
    }
    New-Fixture 'invalid-utf8' ($context + "`n" + $first + "`n" + $good + "`n" + $after + "`n")
    $raw = [IO.File]::ReadAllBytes($path)
    $rawOffset = $utf8.GetByteCount($context + "`n" + $first + "`n") + $good.IndexOf('BODY_SENTINEL')
    $raw[$rawOffset] = 0xC0; $raw[$rawOffset+1] = 0x80
    [IO.File]::WriteAllBytes($path,$raw); $script:CaseLabel = 'invalid-utf8'; Reject-Live
    New-Fixture 'complete-json-no-eol' ($context + "`n" + $first + "`n" + $good)
    $script:CaseLabel = 'complete-json-no-eol'
    Reject-Live
    New-Fixture 'frozen-half-line' ($context + "`n" + $first + "`n" + $good + "`n")
    Prepare $true
    # Frozen work targets may not admit a syntactically complete partial record.
    [IO.File]::WriteAllText($path,($context + "`n" + $first + "`n" + $good.Substring(0,1500000)),$utf8)
    $batch = Batch $true 4000000L
    Assert (-not $batch.Completed) 'source shrink or incomplete line cannot claim coverage'
    foreach ($unknown in @(@('O1,0','5'),@('unknown','5'),@('','5'),@('O1,0','999'))) {
        Assert ([ToolOutputSyntheticProbe]::UnknownStateRejects([TokenRaderIndexer],$unknown[0],$unknown[1],$minimal)) 'unknown restored state cannot fake complete'
    }
    New-Fixture 'cancel' ($context + "`n" + $first + "`n" + $good + "`n" + $after + "`n")
    $cts = [Threading.CancellationTokenSource]::new(); $cts.Cancel()
    $cancelled = $false
    try { [void](Import -Cancel $cts.Token) } catch { $cancelled=$true } finally { $cts.Dispose() }
    Assert ($cancelled -and (Scalar 'SELECT COUNT(*) FROM token_records') -eq 0) 'cancel preserves transaction rollback'
    Write-Host ('TOOL_OUTPUT_STREAMING_TESTS_PASSED edition={0} version={1}' -f $PSVersionTable.PSEdition,$PSVersionTable.PSVersion)
} finally {
    if ($null -ne $db) { $db.Dispose() }
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
