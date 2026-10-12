$ErrorActionPreference = 'Stop'

# Synthetic-only launcher target. It does not load the application, logs,
# credentials, or UI; it reports only whether a console is attached/visible
# and which apartment state the launcher supplied. A pseudoconsole can have
# an invisible nonzero window handle, so visibility alone is insufficient.
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
$consoleAttached = $consoleWindow -ne [IntPtr]::Zero
$consoleVisible = $consoleWindow -ne [IntPtr]::Zero -and [LauncherWindowSyntheticNative]::IsWindowVisible($consoleWindow)
$report = 'consoleAttached=' + $consoleAttached.ToString().ToLowerInvariant() + ';consoleVisible=' + $consoleVisible.ToString().ToLowerInvariant() + ';apartment=' + [Threading.Thread]::CurrentThread.GetApartmentState().ToString()
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'launcher-smoke-result.txt'), $report)
