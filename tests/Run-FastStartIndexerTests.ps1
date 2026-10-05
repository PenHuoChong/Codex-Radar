[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll = Join-Path $root 'indexer\TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp = Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-FastStartSynthetic-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$db = [System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
$db.Open()
$none = [Threading.CancellationToken]::None
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert([bool]$ok, [string]$why) { if (-not $ok) { throw ('FAST START TEST FAILED: ' + $why) } }
function Scalar([string]$sql) { $cmd=$db.CreateCommand(); try { $cmd.CommandText=$sql; return $cmd.ExecuteScalar() } finally { $cmd.Dispose() } }
function SyntheticMetadataSnapshot {
    $cmd=$db.CreateCommand()
    try {
        $cmd.CommandText="SELECT * FROM file_metadata WHERE session_id='synthetic'"
        $reader=$cmd.ExecuteReader()
        try {
            Assert ($reader.Read()) 'synthetic catalog row exists'
            $row=[ordered]@{}
            for ($i=0; $i -lt $reader.FieldCount; $i++) {
                $row[$reader.GetName($i)] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
            }
            return ($row | ConvertTo-Json -Depth 8 -Compress)
        } finally { $reader.Dispose() }
    } finally { $cmd.Dispose() }
}
function Token([int]$total, [int]$last = -1) {
    $info = @{ total_token_usage=@{ input_tokens=$total; cached_input_tokens=0; output_tokens=0; reasoning_output_tokens=0 } }
    if ($last -ge 0) { $info.last_token_usage=@{ input_tokens=$last; cached_input_tokens=0; output_tokens=0; reasoning_output_tokens=0 } }
    return (@{ timestamp='2026-10-05T00:00:00Z'; type='event_msg'; payload=@{ type='token_count'; info=$info } } | ConvertTo-Json -Depth 8 -Compress)
}
try {
    [TokenRaderIndexer]::CreateSchema($db)
    $path = Join-Path $temp 'synthetic.jsonl'
    $meta = '{"timestamp":"2026-10-05T00:00:00Z","type":"session_meta","payload":{"id":"synthetic","cwd":"synthetic-only"}}'
    $context = '{"timestamp":"2026-10-05T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4","service_tier":"priority"}}'
    $lines = @($meta,$context,(Token 100 100),(Token 200 100))
    [IO.File]::WriteAllText($path, ($lines -join "`n") + "`n", $utf8)
    $frozen = ([IO.FileInfo]$path).Length
    $progress = [hashtable]::Synchronized(@{})
    $fast = [TokenRaderIndexer]::InitializeFromNow($db,$temp,$progress,$none)
    Assert ($fast.RemainingFiles -eq 1) 'skipped history has a resumable gap'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq 0) 'startup imports no historical token rows'
    Assert ((Scalar 'SELECT parsed_offset FROM file_metadata') -eq $frozen) 'startup freezes complete EOF'
    Assert ($progress.ContainsKey('LastProgressAt')) 'genuine progress updates liveness'
    Assert ([TokenRaderIndexer]::GetSetting($db,'fast_start_mode') -eq '1') 'fast mode recorded'
    $again = [TokenRaderIndexer]::InitializeFromNow($db,$temp,$progress,$none)
    Assert ($again.ProcessedBytes -eq 0) 'unchanged files avoid sampling reads'
    $append = (Token 225) + "`n"
    [IO.File]::AppendAllText($path,$append,$utf8)
    $end = ([IO.FileInfo]$path).Length
    $added = [TokenRaderIndexer]::ImportFile($db,$path,$frozen,$end,'synthetic','',100,$progress,$none)
    Assert ($added -eq 1) 'new append imports immediately'
    Assert ((Scalar 'SELECT call_input FROM token_records') -eq 25) 'tail cumulative baseline does not include skipped history'
    $replay = [TokenRaderIndexer]::ImportFile($db,$path,$frozen,$end,'synthetic','',100,$progress,$none)
    Assert ($replay -eq 0) 'committed range replay is idempotent'
    [TokenRaderIndexer]::UpdateFileMetadata($db,$path,$end,[IO.File]::GetLastWriteTimeUtc($path).Ticks,$end)
    $liveModel = Scalar 'SELECT turn_context_model FROM file_metadata'
    $cancel = [Threading.CancellationTokenSource]::new(); $cancel.Cancel()
    $before = Scalar 'SELECT cursor_offset FROM history_gaps'
    try { [void][TokenRaderIndexer]::BackfillHistoryBatch($db,1024,500,$progress,$cancel.Token); throw 'expected cancellation' }
    catch { Assert ($_.Exception.ToString().Contains('OperationCanceledException')) 'cancellation propagated' }
    Assert ((Scalar 'SELECT cursor_offset FROM history_gaps') -eq $before) 'cancelled batch does not advance persisted cursor'
    $iterations = 0
    do {
        $batch = [TokenRaderIndexer]::BackfillHistoryBatch($db,500,500,$progress,$none)
        Assert ($batch.ProcessedBytes -le 500) 'batch obeys byte bound'
        $iterations++
        Assert ($iterations -lt 20) 'bounded batches make progress'
    } while (-not $batch.Completed -and $batch.RemainingBytes -gt 0)
    Assert $batch.Completed 'history completes'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq 3) 'history imports once without duplicating live append'
    Assert ((Scalar 'SELECT parsed_offset FROM file_metadata') -eq $end) 'history does not regress live cursor'
    Assert ((Scalar 'SELECT turn_context_model FROM file_metadata') -eq $liveModel) 'history does not regress live model context'
    $schema=Scalar "SELECT sql FROM sqlite_master WHERE name='history_gaps'"
    Assert (-not $schema.Contains('pending_line')) 'no raw conversation fragments persisted'

    $huge = Join-Path $temp 'rollout-huge.jsonl'
    [IO.File]::WriteAllText($huge,('{"type":"response_item","payload":{"body":"' + ('x' * (2*1024*1024)) + '"}}' + "`n" + $context + "`n" + (Token 10 10) + "`n"),$utf8)
    $hugeFast = [TokenRaderIndexer]::InitializeFromNow($db,$temp,$progress,$none)
    Assert ($hugeFast.ProcessedBytes -le 256*1024) 'new giant file startup reads only bounded samples'
    $iterations = 0
    do {
        $batch=[TokenRaderIndexer]::BackfillHistoryBatch($db,65536,500,$progress,$none)
        Assert ($batch.ProcessedBytes -le 65536) 'giant lines obey batch bound'
        $iterations++; Assert ($iterations -lt 50) 'giant lines do not loop forever'
    } while ($batch.RemainingBytes -gt 0)
    Assert (-not $batch.Completed -and $batch.BlockedFiles -gt 0) 'unparsed giant line remains explicitly incomplete'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq 4) 'records following giant body still imported'
    $oldCursor = [long](Scalar "SELECT parsed_offset FROM file_metadata WHERE session_id='synthetic'")
    $oldMetadata = SyntheticMetadataSnapshot
    [IO.File]::WriteAllText($path, $meta + "`n", $utf8)
    $replaced = [TokenRaderIndexer]::InitializeFromNow($db,$temp,$progress,$none)
    Assert ($replaced.BlockedFiles -ge 1) 'truncated source is explicitly blocked'
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq 4) 'truncation preserves retained rows'
    Assert ($oldCursor -gt ([IO.FileInfo]$path).Length) 'fixture truncates below the retained cursor'
    Assert ((Scalar "SELECT parsed_offset FROM file_metadata WHERE session_id='synthetic'") -eq $oldCursor) 'truncation preserves the old-incarnation cursor'
    Assert ((SyntheticMetadataSnapshot) -eq $oldMetadata) 'truncation preserves old identity, relationships and context'
    Assert ((Scalar "SELECT COUNT(*) FROM history_gaps WHERE path=(SELECT path FROM file_metadata WHERE session_id='synthetic') AND blocked_reason='source_replaced'") -gt 0) 'replacement guard makes the retained cursor unusable for the new incarnation'
    Assert (-not $replaced.Completed -and -not ([TokenRaderIndexer]::GetHistoryBackfillStatus($db)).Completed) 'truncation cannot claim complete history'

    # Independent edge-case database: only generated fixtures, no real index.
    $db.Dispose()
    $db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;'); $db.Open()
    [TokenRaderIndexer]::CreateSchema($db)
    $edge=Join-Path $temp 'edge'; [void][IO.Directory]::CreateDirectory($edge)
    foreach ($item in @(@('root',''),@('middle','root'),@('leaf','middle'))) {
        $header=@{ timestamp='2026-10-05T00:00:00Z'; type='session_meta'; payload=@{ id=$item[0]; parent_thread_id=$item[1] } } | ConvertTo-Json -Depth 6 -Compress
        [IO.File]::WriteAllText((Join-Path $edge ($item[0]+'.jsonl')),$header+"`n"+$context+"`n"+(Token 100)+"`n",$utf8)
    }
    [void][TokenRaderIndexer]::InitializeFromNow($db,$edge,$progress,$none)
    Assert ((Scalar "SELECT root_session_id FROM file_metadata WHERE session_id='leaf'") -eq 'root') 'three-generation root resolved from metadata graph'
    $removeMiddle=$db.CreateCommand()
    try { $removeMiddle.CommandText="DELETE FROM file_metadata WHERE session_id='middle'"; [void]$removeMiddle.ExecuteNonQuery() } finally { $removeMiddle.Dispose() }
    [IO.File]::Move((Join-Path $edge 'middle.jsonl'),(Join-Path $edge 'middle.temporary'))
    [void][TokenRaderIndexer]::InitializeFromNow($db,$edge,$progress,$none)
    Assert ((Scalar "SELECT root_session_id FROM file_metadata WHERE session_id='leaf'") -eq 'root') 'missing intermediate ancestor does not downgrade a reliable root'
    [IO.File]::Move((Join-Path $edge 'middle.temporary'),(Join-Path $edge 'middle.jsonl'))
    [void][TokenRaderIndexer]::InitializeFromNow($db,$edge,$progress,$none)
    do { $batch=[TokenRaderIndexer]::BackfillHistoryBatch($db,2048,500,$progress,$none) } while ($batch.RemainingBytes -gt 0)
    Assert $batch.Completed 'three-generation history completes'
    $leaf=Join-Path $edge 'leaf.jsonl'; $before=([IO.FileInfo]$leaf).Length
    [IO.File]::AppendAllText($leaf,(Token 150)+"`n",$utf8)
    [void][TokenRaderIndexer]::InitializeFromNow($db,$edge,$progress,$none)
    do { $batch=[TokenRaderIndexer]::BackfillHistoryBatch($db,2048,500,$progress,$none) } while ($batch.RemainingBytes -gt 0)
    Assert ((Scalar "SELECT call_input FROM token_records WHERE source_path LIKE '%leaf.jsonl' ORDER BY source_offset_end DESC LIMIT 1") -eq 50) 'completed adjacent gap permits trusted prior cumulative baseline'

    $missing=Join-Path $edge 'aaa-missing.jsonl'
    $available=Join-Path $edge 'zzz-available.jsonl'
    [IO.File]::WriteAllText($missing,$context+"`n"+(Token 10 10)+"`n",$utf8)
    [IO.File]::WriteAllText($available,$context+"`n"+(Token 20 20)+"`n",$utf8)
    [void][TokenRaderIndexer]::InitializeFromNow($db,$edge,$progress,$none)
    [IO.File]::Delete($missing)
    $batch=[TokenRaderIndexer]::BackfillHistoryBatch($db,2048,500,$progress,$none)
    Assert ($batch.AttemptedFiles -eq 2 -and $batch.ImportedRecords -eq 1) 'unavailable early path does not starve another gap'
    Assert ($batch.BlockedFiles -eq 1 -and $batch.EligibleFiles -eq 0) 'all remaining inaccessible work pauses explicitly'
    [IO.File]::WriteAllText($missing,$context+"`n"+(Token 10 10)+"`n",$utf8)
    Assert ([TokenRaderIndexer]::ResetHistoryBackfillRetries($db) -eq 1) 'explicit transient retry is available'
    $batch=[TokenRaderIndexer]::BackfillHistoryBatch($db,2048,500,$progress,$none)
    Assert $batch.Completed 'restored missing source resumes without duplicates'

    $unsafe=Join-Path $edge 'unsafe-token.jsonl'
    $largeToken=(Token 200 200).TrimEnd('}') + ',"padding":"' + ('x' * (1024*1024+1)) + '"}' + "`n"
    [IO.File]::WriteAllText($unsafe,$largeToken,$utf8)
    $count=Scalar 'SELECT COUNT(*) FROM token_records'
    try { [void][TokenRaderIndexer]::ImportFile($db,$unsafe,0,([IO.FileInfo]$unsafe).Length,'unsafe-token','',100,$progress,$none); throw 'expected oversized rejection' }
    catch { Assert ($_.Exception.ToString().Contains('Oversized usage/context')) 'normal oversized usage fails closed' }
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq $count) 'oversized normal import rolls back'

    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Threading;
public sealed class TokenRaderSyntheticCancelProgress : Hashtable {
    public CancellationTokenSource CancelSource;
    public TokenRaderSyntheticCancelProgress(CancellationTokenSource source) { CancelSource=source; }
    public override object this[object key] {
        get { return base[key]; }
        set { base[key]=value; if (Convert.ToString(key)=="ImportedRecords" && Convert.ToInt64(value)>0) CancelSource.Cancel(); }
    }
}
'@
    $cancelPath=Join-Path $edge 'cancel.jsonl'
    [IO.File]::WriteAllText($cancelPath,$context+"`n"+(Token 1 1)+"`n"+(Token 2 1)+"`n",$utf8)
    $cts=[Threading.CancellationTokenSource]::new()
    $cancelProgress=[TokenRaderSyntheticCancelProgress]::new($cts)
    try { [void][TokenRaderIndexer]::ImportFile($db,$cancelPath,0,([IO.FileInfo]$cancelPath).Length,'cancel','',100,$cancelProgress,$cts.Token); throw 'expected in-file cancellation' }
    catch { Assert ($_.Exception.ToString().Contains('OperationCanceledException')) ('cancellation checked within active file: ' + $_.Exception.ToString()) }
    Assert ((Scalar 'SELECT COUNT(*) FROM token_records') -eq $count) 'in-file cancellation rolls back already inserted rows'

    $partialDir=Join-Path $temp 'partial'; [void][IO.Directory]::CreateDirectory($partialDir)
    $partialPath=Join-Path $partialDir 'partial.jsonl'
    $oldToken=Token 300 300; $split=[int]($oldToken.Length/2)
    [IO.File]::WriteAllText($partialPath,$context+"`n"+$oldToken.Substring(0,$split),$utf8)
    $partialEof=([IO.FileInfo]$partialPath).Length
    [void][TokenRaderIndexer]::InitializeFromNow($db,$partialDir,$progress,$none)
    Assert ((Scalar "SELECT parsed_offset FROM file_metadata WHERE session_id='partial'") -eq $partialEof) 'startup freezes unfinished byte EOF'
    Assert ((Scalar "SELECT turn_context_model FROM file_metadata WHERE session_id='partial'") -eq '') 'unfinished skipped record cannot establish current pricing context'
    [IO.File]::AppendAllText($partialPath,$oldToken.Substring($split)+"`n"+(Token 350 50)+"`n",$utf8)
    $added=[TokenRaderIndexer]::ImportFile($db,$partialPath,$partialEof,([IO.FileInfo]$partialPath).Length,'partial','',100,$progress,$none)
    Assert ($added -eq 1) 'live append skips completed pre-start fragment and counts following call'
    Assert ((Scalar "SELECT call_input FROM token_records WHERE session_id='partial'") -eq 50) 'unfinished historical call is not billed as new work'
    do { $batch=[TokenRaderIndexer]::BackfillHistoryBatch($db,2048,500,$progress,$none) } while ($batch.EligibleFiles -gt 0 -and $batch.ProcessedBytes -gt 0)
    Assert ((Scalar "SELECT blocked_reason FROM history_gaps WHERE path LIKE '%partial.jsonl'") -eq 'incomplete_frozen_line') 'frozen incomplete historical endpoint remains explicitly incomplete'

    $empty=Join-Path $temp 'not-created'
    [void][TokenRaderIndexer]::InitializeFromNow($db,$empty,$progress,$none)
    Assert ([TokenRaderIndexer]::GetSetting($db,'sessions_root') -eq $empty) 'missing first-install sessions root is an empty catalog'
    Write-Output 'Fast-start indexer synthetic tests passed.'
} finally {
    $db.Dispose()
    # The only removed directory is the freshly created synthetic fixture root.
    $resolved=[IO.Path]::GetFullPath($temp)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\TokenRader-FastStartSynthetic-'
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
