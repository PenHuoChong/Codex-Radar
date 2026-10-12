[CmdletBinding()]
param()

# Synthetic capability probe only. Load code dependencies and an in-memory
# database, never the dashboard, account data, real index, or Codex logs.
# Respect the current policy.
$ErrorActionPreference = 'Stop'
Write-Output ('LanguageMode=' + $ExecutionContext.SessionState.LanguageMode)
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Output 'STARTUP_PROBE_BLOCKED: WPF dashboard requires FullLanguage; no alternative host or bypass will be tried.'
    exit 2
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $projectRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
    if (-not (Initialize-TokenRaderIndexer)) { throw 'Indexer dependencies could not be loaded under the current policy.' }
    $connection = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;'
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = 'SELECT 1'
            if ([int]$command.ExecuteScalar() -ne 1) { throw 'Synthetic SQLite query failed.' }
        } finally { $command.Dispose() }
    } finally { $connection.Dispose() }
    Write-Output 'INDEXER_AND_IN_MEMORY_SQLITE_PASSED'
    $window = New-Object System.Windows.Window
    $window.Title = 'Token Rader - synthetic startup check'
    $window.Width = 360
    $window.Height = 100
    $window.Content = 'Synthetic check only; no account or log data is read.'
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(700)
    $timer.Add_Tick({ $timer.Stop(); $window.Close() })
    $timer.Start()
    [void]$window.ShowDialog()
    Write-Output 'SYNTHETIC_WPF_STARTUP_PASSED'
} catch {
    Write-Output ('STARTUP_PROBE_FAILED: ' + $_.Exception.Message)
    exit 1
}
