[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $tempRoot ('Token Rader Standard Startup ' + [Guid]::NewGuid().ToString('N'))
$app = Join-Path $fixture 'app'
$codex = Join-Path $fixture 'synthetic-codex'
$process = $null
[void](New-Item -ItemType Directory -Path $app, (Join-Path $app 'indexer'), (Join-Path $codex 'sessions') -Force)
try {
    # Explicit source/runtime whitelist: never copy project data/private,
    # account metadata, the blocked EXE, or any user's session files.
    foreach ($name in @('TokenRader.ps1', 'TokenRader.Core.psm1', 'TokenRader.Explorer.UI.ps1', 'TokenRader.Explorer.psm1', 'MainWindow.xaml', 'ExplorerWindow.xaml', 'pricing.json')) {
        Copy-Item -LiteralPath (Join-Path $root $name) -Destination (Join-Path $app $name)
    }
    foreach ($name in @('TokenRader.Indexer.dll', 'System.Data.SQLite.dll')) {
        Copy-Item -LiteralPath (Join-Path $root ('indexer\' + $name)) -Destination (Join-Path $app ('indexer\' + $name))
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $start.Arguments = '-NoProfile -STA -WindowStyle Hidden -File "' + (Join-Path $app 'TokenRader.ps1') + '"'
    $start.WorkingDirectory = $app
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['CODEX_HOME'] = $codex
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $opened = $false
    while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero -and $process.MainWindowTitle -like 'Token Rader*') { $opened = $true; break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $opened) { throw 'The isolated dashboard did not open; no alternate host or policy bypass was attempted.' }
    Start-Sleep -Seconds 3
    if ($process.HasExited) { throw 'The isolated dashboard exited unexpectedly during startup.' }
    if (-not $process.CloseMainWindow()) { throw 'The isolated dashboard could not be closed gracefully.' }
    if (-not $process.WaitForExit(15000)) { throw 'The isolated dashboard did not finish graceful shutdown; its process was not forcibly stopped.' }
    $errorText = $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($errorText)) {
        throw ('Isolated dashboard startup/shutdown failed: ' + $errorText)
    }
    Write-Output 'STANDARD_STARTUP_INTEGRATION_PASSED: real dashboard in isolated empty synthetic CODEX_HOME; graceful close; no real logs/index accessed.'
} finally {
    $canClean = $true
    if ($null -ne $process) {
        if (-not $process.HasExited) {
            [void]$process.CloseMainWindow()
            $canClean = $process.WaitForExit(5000)
        }
        $process.Dispose()
    }
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($canClean -and $resolved -eq $fixture -and $resolved.StartsWith($tempRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
