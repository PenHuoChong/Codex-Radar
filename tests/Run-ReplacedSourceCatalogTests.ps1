[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($IndexerDll)) { $IndexerDll = Join-Path $root 'indexer/TokenRader.Indexer.dll' }
Add-Type -Path (Join-Path $root 'indexer/System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp = Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-ReplacedCatalogSynthetic-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$temp = [IO.Path]::GetFullPath((Get-Item -LiteralPath $temp).FullName)
$utf8 = [Text.UTF8Encoding]::new($false)
$none = [Threading.CancellationToken]::None
$db = $null
function Assert([bool]$Value,[string]$Message) { if (-not $Value) { throw ('REPLACED CATALOG FAILED: ' + $Message) } }
function Sql([string]$Text,[string]$Path = '') {
    $cmd = $db.CreateCommand()
    try { $cmd.CommandText=$Text; [void]$cmd.Parameters.AddWithValue('@path',$Path); [void]$cmd.ExecuteNonQuery() }
    finally { $cmd.Dispose() }
}
function Scalar([string]$Text,[string]$Path = '') {
    $cmd = $db.CreateCommand()
    try { $cmd.CommandText=$Text; [void]$cmd.Parameters.AddWithValue('@path',$Path); return $cmd.ExecuteScalar() }
    finally { $cmd.Dispose() }
}
function Snapshot([string]$Table,[string]$Path) {
    $column = if ($Table -in @('token_records','tool_records','recent_lineage_evidence')) { 'source_path' } else { 'path' }
    $cmd = $db.CreateCommand(); $rows = [Collections.Generic.List[string]]::new()
    try {
        $cmd.CommandText = 'SELECT * FROM ' + $Table + ' WHERE ' + $column + '=@path'
        [void]$cmd.Parameters.AddWithValue('@path',$Path)
        $reader = $cmd.ExecuteReader()
        try {
            while ($reader.Read()) {
                $row = [ordered]@{}
                for ($i=0;$i -lt $reader.FieldCount;$i++) {
                    $value=$reader.GetValue($i)
                    $row[$reader.GetName($i)] = if ($value -is [DBNull]) { $null } else { $value }
                }
                $rows.Add(($row | ConvertTo-Json -Depth 5 -Compress))
            }
        } finally { $reader.Dispose() }
        return (@($rows | Sort-Object) -join "`n")
    } finally { $cmd.Dispose() }
}
function Header([string]$Session,[string]$Parent = '') {
    return (@{type='session_meta';payload=@{id=$Session;cwd='synthetic-only';parent_thread_id=$Parent}} | ConvertTo-Json -Depth 5 -Compress) + "`n"
}
function New-Fixture([string]$Name) {
    if ($null -ne $script:db) { $script:db.Dispose() }
    $script:db = [System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $db.Open(); [TokenRaderIndexer]::CreateSchema($db)
    $script:folder = Join-Path $temp $Name
    [void][IO.Directory]::CreateDirectory($folder)
    $script:progress = [hashtable]::Synchronized(@{})
}
function Seed([string]$Name,[string]$Session,[string]$Parent,[string]$CanonicalRoot,[string]$Body = '') {
    $path = Join-Path $folder ($Name + '.jsonl')
    if ([string]::IsNullOrEmpty($Body)) { $Body = Header $Session $Parent }
    [IO.File]::WriteAllText($path,$Body,$utf8)
    $length=([IO.FileInfo]$path).Length; $write=[IO.File]::GetLastWriteTimeUtc($path).Ticks
    [TokenRaderIndexer]::UpdateFileMetadata($db,$path,$length,$write,$length,$Session,'old-cwd',$Parent,'',$CanonicalRoot)
    $cmd = $db.CreateCommand()
    try {
        $cmd.CommandText = "UPDATE file_metadata SET turn_context_model='gpt-5.4',turn_context_model_source='turn_context',turn_context_model_timestamp='2026-01-01T00:00:00Z',turn_context_model_timestamp_ticks=123,turn_context_service_tier='priority',turn_context_service_tier_source='turn_context',fast_baseline_offset=@end,fast_baseline_input=10,fast_baseline_cached=2,fast_baseline_output=3,fast_baseline_reasoning=1 WHERE path=@path;
            INSERT INTO token_records(session_id,timestamp,total_input,total_cached,total_output,call_input,call_cached,call_output,source_path,source_offset_end,root_session_id) VALUES(@session,'2026-01-01T00:00:00Z',10,2,3,10,2,3,@path,@end,@root);
            INSERT INTO tool_records(event_key,session_id,source_path,source_offset_end,root_session_id) VALUES(@tool,@session,@path,@end,@root);
            INSERT INTO recent_lineage_evidence(event_key,session_id,timestamp_ticks,source_path,source_offset_end) VALUES(@proof,@session,123,@path,@end)"
        [void]$cmd.Parameters.AddWithValue('@path',$path); [void]$cmd.Parameters.AddWithValue('@end',$length)
        [void]$cmd.Parameters.AddWithValue('@session',$Session); [void]$cmd.Parameters.AddWithValue('@root',$CanonicalRoot)
        [void]$cmd.Parameters.AddWithValue('@tool',('tool|' + $Session)); [void]$cmd.Parameters.AddWithValue('@proof',($CanonicalRoot + '|fingerprint'))
        [void]$cmd.ExecuteNonQuery()
    } finally { $cmd.Dispose() }
    return $path
}
function Freeze([string]$Path) {
    $result=@{}
    foreach ($table in @('file_metadata','token_records','tool_records','recent_lineage_evidence')) { $result[$table]=Snapshot $table $Path }
    return $result
}
function Preserved([string]$Path,$Before) {
    foreach ($table in @('file_metadata','token_records','tool_records','recent_lineage_evidence')) {
        Assert ((Snapshot $table $Path) -ceq $Before[$table]) ('retained ' + $table)
    }
}
try {
    foreach ($kind in @('shrink','same-length','empty','already-blocked-append')) {
        New-Fixture $kind
        $oldBody=(Header 'known-old' 'old-parent') + (' ' * 2048) + "`n"
        $path=Seed 'target' 'known-old' 'old-parent' 'retained-root' $oldBody
        $before=Freeze $path
        $oldWrite=[IO.File]::GetLastWriteTimeUtc($path)
        if ($kind -eq 'already-blocked-append') {
            Sql "INSERT INTO history_gaps(path,start_offset,end_offset,cursor_offset,blocked_reason) SELECT path,0,length,0,'source_replaced' FROM file_metadata WHERE path=@path" $path
            [IO.File]::AppendAllText($path,(Header 'known-new' 'new-parent'),$utf8)
        } elseif ($kind -eq 'empty') {
            [IO.File]::WriteAllText($path,'',$utf8)
        } elseif ($kind -eq 'same-length') {
            $newBody=$oldBody.Replace('known-old','known-new').Replace('old-parent','new-parent')
            [IO.File]::WriteAllText($path,$newBody,$utf8)
            [IO.File]::SetLastWriteTimeUtc($path,$oldWrite.AddMinutes(1))
        } else {
            [IO.File]::WriteAllText($path,(Header 'known-new' 'new-parent'),$utf8)
        }
        $result=[TokenRaderIndexer]::InitializeFromNow($db,$folder,$progress,$none)
        Preserved $path $before
        Assert ((Scalar "SELECT COUNT(*) FROM history_gaps WHERE path=@path AND blocked_reason='source_replaced'" $path) -gt 0) 'replacement guard retained'
        Assert (-not $result.Completed -and $result.ProcessedBytes -eq 0) 'blocked source not sampled or called complete'
        [void][TokenRaderIndexer]::PrepareRecentHistory($db,$folder,[DateTimeOffset]::Parse('2026-01-01T00:00:00Z'),[DateTimeOffset]::Parse('2026-01-02T00:00:00Z'),$progress,$none)
        Preserved $path $before
        Assert ((Scalar "SELECT COUNT(*) FROM history_gaps WHERE path=@path AND blocked_reason='source_replaced'" $path) -gt 0) 'recent Start cannot clear replacement guard'
    }

    New-Fixture 'blocked-ancestry'
    $ancestor=Seed 'ancestor' 'ancestor' 'upstream' 'retained-root'
    $child=Seed 'child' 'child' 'ancestor' 'retained-root'
    $leaf=Seed 'leaf' 'leaf' 'child' 'retained-root'
    Sql "INSERT INTO history_gaps(path,start_offset,end_offset,cursor_offset,blocked_reason) SELECT path,0,length,0,'source_replaced' FROM file_metadata WHERE path=@path" $ancestor
    $frozen=@{}
    foreach ($path in @($ancestor,$child,$leaf)) { $frozen[$path]=Freeze $path }
    $normalRoot=Seed 'normal-root' 'normal-root' '' 'normal-root'
    $normalChild=Seed 'normal-child' 'normal-child' 'normal-root' 'old-normal-root'
    [void][TokenRaderIndexer]::InitializeFromNow($db,$folder,$progress,$none)
    foreach ($path in @($ancestor,$child,$leaf)) { Preserved $path $frozen[$path] }
    Assert ((Scalar 'SELECT root_session_id FROM file_metadata WHERE path=@path' $normalChild) -eq 'normal-root') 'unblocked chain still resolves'
    Assert ((Scalar 'SELECT event_key FROM recent_lineage_evidence WHERE source_path=@path' $normalChild) -eq 'normal-root|fingerprint') 'unblocked lineage proof still resolves'

    New-Fixture 'ordinary-first-and-append'
    $path=Join-Path $folder 'ordinary.jsonl'
    [IO.File]::WriteAllText($path,(Header 'ordinary' 'ordinary-parent'),$utf8)
    $first=[TokenRaderIndexer]::InitializeFromNow($db,$folder,$progress,$none)
    Assert ((Scalar 'SELECT parent_thread_id FROM file_metadata WHERE path=@path' $path) -eq 'ordinary-parent') 'ordinary bounded header parent retained'
    Assert ($first.ProcessedBytes -le 256*1024) 'ordinary sample bound unchanged'
    $end=([IO.FileInfo]$path).Length
    [IO.File]::AppendAllText($path," `n",$utf8)
    [void][TokenRaderIndexer]::InitializeFromNow($db,$folder,$progress,$none)
    Assert ((Scalar 'SELECT parsed_offset FROM file_metadata WHERE path=@path' $path) -gt $end) 'ordinary append still freezes new bytes'
    Assert ((Scalar "SELECT COUNT(*) FROM history_gaps WHERE blocked_reason='source_replaced'") -eq 0) 'ordinary append not classified as replacement'
    Write-Host ('REPLACED_SOURCE_CATALOG_TESTS_PASSED edition={0} version={1}' -f $PSVersionTable.PSEdition,$PSVersionTable.PSVersion)
} finally {
    if ($null -ne $db) { $db.Dispose() }
    $resolved=[IO.Path]::GetFullPath($temp)
    $allowed=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved).StartsWith('TokenRader-ReplacedCatalogSynthetic-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
