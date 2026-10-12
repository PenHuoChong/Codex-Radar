$ErrorActionPreference = 'Stop'

# Synthetic-only launcher target. It does not load the application, logs,
# credentials, or UI; it reports only whether its process has a console window
# and which apartment state the launcher supplied.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LauncherWindowSyntheticNative
{
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
'@

$hasConsole = [LauncherWindowSyntheticNative]::GetConsoleWindow() -ne [IntPtr]::Zero
$report = 'console=' + $hasConsole.ToString().ToLowerInvariant() + ';apartment=' + [Threading.Thread]::CurrentThread.GetApartmentState().ToString()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launcher-smoke-result.txt'), $report)
