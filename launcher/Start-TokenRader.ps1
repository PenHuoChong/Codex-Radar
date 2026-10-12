[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This short-lived bootstrap does not load the dashboard or any account data.
# Hidden is not equivalent to console-free when Windows Terminal is the host.
# CreateNoWindow detaches the long-lived WPF process from that console without
# hiding or closing any existing user terminal. All system policies still apply.
$projectRoot = Split-Path -Parent $PSScriptRoot
$dashboardPath = Join-Path $projectRoot 'TokenRader.ps1'
$hostPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $dashboardPath -PathType Leaf)) {
    throw 'TokenRader.ps1 was not found next to the bootstrap.'
}
if (-not (Test-Path -LiteralPath $hostPath -PathType Leaf)) {
    throw 'Windows PowerShell was not found. No alternate host was attempted.'
}

$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $hostPath
$startInfo.Arguments = '-NoProfile -STA -File "' + $dashboardPath + '"'
$startInfo.WorkingDirectory = $projectRoot
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
$child = [System.Diagnostics.Process]::Start($startInfo)
if ($null -eq $child) { throw 'The dashboard process could not be started.' }
# Dispose only the managed handle; never terminate the dashboard or wait for it.
$child.Dispose()
