[CmdletBinding()]
param([string]$ProjectRoot = '', [switch]$RepairSingleSourceAuthorized,
    [switch]$ReadOnlyRelationsAuthorized,
    [ValidateRange(1,3600)][int]$TimeoutSeconds = 120)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$db = $null; $lease = $null; $stage = $null; $cts = $null; $cancelBridge = $null
$completed = $false; $phase = 'authorization'; $backupPath = $null
function Assert-UnlinkedPath([string]$LiteralPath) {
    $current = [IO.Path]::GetFullPath($LiteralPath)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) {
            if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw [InvalidOperationException]::new('Linked path requires separate authorization.')
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
try {
    if (-not $RepairSingleSourceAuthorized) { throw [InvalidOperationException]::new('Explicit single-source repair authorization is required.') }
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    $phase = 'application_check'
    $windows = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('TokenRader','powershell','pwsh') -and $_.MainWindowTitle -match '^Token Rader'
    })
    if ($windows.Count -gt 0) { throw [InvalidOperationException]::new('Dashboard must be closed.') }
    Add-Type -Path (Join-Path $ProjectRoot 'indexer/System.Data.SQLite.dll')
    Add-Type -Path (Join-Path $ProjectRoot 'indexer/TokenRader.Indexer.dll')
    $dbPath = Join-Path $ProjectRoot 'data/private/index/index.db'
    Assert-UnlinkedPath -LiteralPath $dbPath
    Assert-UnlinkedPath -LiteralPath ($dbPath + '.lock')
    if (-not [IO.File]::Exists($dbPath)) { throw [InvalidOperationException]::new('Existing index required.') }
    $phase = 'index_lock'
    $lease = [TokenRaderIndexer]::AcquireFileLock(($dbPath + '.lock'), 1000)
    $builder = [System.Data.SQLite.SQLiteConnectionStringBuilder]::new()
    $builder['Data Source'] = [string]$dbPath; $builder.FailIfMissing = $true; $builder.Pooling = $false
    $db = [System.Data.SQLite.SQLiteConnection]::new($builder.ConnectionString)
    $db.Open()
    $phase = 'select_single_source'
    $command = $db.CreateCommand()
    try {
        $command.CommandText = "SELECT path FROM history_gaps WHERE blocked_reason='source_replaced' GROUP BY path LIMIT 2"
        $reader = $command.ExecuteReader(); $paths = [Collections.Generic.List[string]]::new()
        try { while ($reader.Read()) { $paths.Add([string]$reader.GetValue(0)) } } finally { $reader.Dispose() }
    } finally { $command.Dispose() }
    if ($paths.Count -ne 1) { throw [InvalidOperationException]::new('Exactly one blocked source is required.') }
    $sourcePath = [IO.Path]::GetFullPath($paths[0])
    $codexRoot = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { Join-Path $HOME '.codex' } else { $env:CODEX_HOME }
    $sessionsRoot = [IO.Path]::GetFullPath((Join-Path $codexRoot 'sessions')).TrimEnd('\','/')
    if (-not $sourcePath.StartsWith(($sessionsRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetExtension($sourcePath) -ne '.jsonl') { throw [InvalidOperationException]::new('Source is outside authorized sessions.') }
    # Do not follow a substituted file/directory link into a different private location.
    $node = $sourcePath
    while ($node.Length -ge $sessionsRoot.Length) {
        if (([IO.File]::GetAttributes($node) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw [InvalidOperationException]::new('Linked source requires separate authorization.')
        }
        if ($node -eq $sessionsRoot) { break }
        $node = [IO.Path]::GetDirectoryName($node)
    }
    $cts = [Threading.CancellationTokenSource]::new()
    $cts.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
    if ($null -eq ('TokenRaderManualRepair.CancelBridge' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Threading;
namespace TokenRaderManualRepair {
    public sealed class CancelBridge : IDisposable {
        private readonly CancellationTokenSource source;
        public CancelBridge(CancellationTokenSource value) { source = value; Console.CancelKeyPress += Cancel; }
        private void Cancel(object sender, ConsoleCancelEventArgs args) { args.Cancel = true; source.Cancel(); }
        public void Dispose() { Console.CancelKeyPress -= Cancel; }
    }
}
'@
    }
    $cancelBridge = [TokenRaderManualRepair.CancelBridge]::new($cts)
    $phase = 'validate_frozen_source'
    Write-Host 'Phase=validate_frozen_source; Sources=1; OriginalLogsModified=False'
    if ($ReadOnlyRelationsAuthorized) {
        $stage = [TokenRaderIndexer]::StageSingleSourceRepair($db, $sourcePath, -1L, $cts.Token)
    } else {
        $stage = [TokenRaderIndexer]::StageSingleSourceRepair($sourcePath, -1L, $cts.Token)
    }
    Write-Host ('Phase=source_validated; VerifiedBytes={0}; TokenRows={1}; ToolRows={2}; UnresolvedTokenRows={3}' -f $stage.VerifiedBytes,$stage.TokenRows,$stage.ToolRows,$stage.UnresolvedTokenRows)
    $backupDirectory = Join-Path $ProjectRoot 'data/private/repairs'
    $backupPath = Join-Path $backupDirectory ('source-repair-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N') + '.db')
    $phase = 'backup_and_commit'
    $result = [TokenRaderIndexer]::CommitSingleSourceRepair($db, $stage, $backupPath, $cts.Token)
    $completed = [bool]$result.Applied
    Write-Host ('Completed={0}; Sources=1; TokenRows={1}; ToolRows={2}; VerifiedMetadataBackup={3}; UnresolvedTokenRows={4}; OriginalLogsModified=False' -f $completed,$result.TokenRows,$result.ToolRows,$completed,$result.UnresolvedTokenRows)
} catch {
    $cause = $_.Exception
    while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
    $safeCode = 'validation_or_execution_failed'
    if ($cause.GetType().FullName -eq 'TokenRaderRepairException' -and [string]$cause.Code -cmatch '^[a-z_]+$') {
        $safeCode = [string]$cause.Code
    }
    Write-Host ('Completed=False; Phase={0}; Reason={1}; ExceptionType={2}; BackupFilePresent={3}; BackupValidityNotAsserted=True; OriginalLogsModified=False' -f $phase,$safeCode,$cause.GetType().FullName,($null -ne $backupPath -and [IO.File]::Exists($backupPath)))
} finally {
    if ($null -ne $stage) { $stage.Dispose() }
    if ($null -ne $db) { $db.Dispose() }
    if ($null -ne $lease) { $lease.Dispose() }
    if ($null -ne $cancelBridge) { $cancelBridge.Dispose() }
    if ($null -ne $cts) { $cts.Dispose() }
}
if (-not $completed) { exit 1 }
