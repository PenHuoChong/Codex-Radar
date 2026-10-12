$ErrorActionPreference = 'Stop'

# Synthetic-only launcher target. It does not load the application, logs,
# credentials, or UI; it reports only whether its console window is visible
# and which apartment state the launcher supplied.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LauncherWindowSyntheticNative
{
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);
}
'@

$consoleWindow = [LauncherWindowSyntheticNative]::GetConsoleWindow()
$consoleVisible = $consoleWindow -ne [IntPtr]::Zero -and [LauncherWindowSyntheticNative]::IsWindowVisible($consoleWindow)
$report = 'consoleVisible=' + $consoleVisible.ToString().ToLowerInvariant() + ';apartment=' + [Threading.Thread]::CurrentThread.GetApartmentState().ToString()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launcher-smoke-result.txt'), $report)
