[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-LauncherWindow {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('LAUNCHER WINDOW TEST FAILED: ' + $Message) }
}

function Get-LauncherWindowSmokeReport {
    param([string]$ReportPath, [int]$TimeoutSeconds = 10)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
            try {
                $report = [IO.File]::ReadAllText($ReportPath)
                if ($report -match '^consoleAttached=(?:true|false);consoleVisible=(?:true|false);apartment=(?:STA|MTA|Unknown)$') { return $report }
            } catch { }
        }
        [Threading.Thread]::Sleep(50)
    }
    throw 'LAUNCHER WINDOW TEST FAILED: synthetic script did not report before timeout'
}

function Assert-SyntheticHiddenStaReport {
    param([string]$ReportPath, [string]$PathDescription)
    $report = Get-LauncherWindowSmokeReport -ReportPath $ReportPath
    Assert-LauncherWindow ($report -eq 'consoleAttached=false;consoleVisible=false;apartment=STA') ($PathDescription + ' must have no attached console (including pseudoconsoles), no visible console window, and STA; report=[' + $report + ']')
}

function Get-LauncherWindowPolicyBlockInfo {
    param($ErrorRecord)

    $exception = $ErrorRecord.Exception
    $blocked = $false
    $nativeErrorCode = $null
    while ($null -ne $exception) {
        if ([string]$exception.Message -match 'Application Control policy has blocked this file') { $blocked = $true }
        try {
            $candidateCode = [int]$exception.NativeErrorCode
            if ($candidateCode -ne 0) { $nativeErrorCode = $candidateCode }
        } catch { }
        $exception = $exception.InnerException
    }
    if (-not $blocked -and $nativeErrorCode -ne 1260) { return $null }
    return [pscustomobject]@{ NativeErrorCode = $nativeErrorCode }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$cmdPath = Join-Path $projectRoot 'Start-TokenRader.cmd'
$bootstrapPath = Join-Path $projectRoot 'launcher\Start-TokenRader.ps1'
$uiSourcePath = Join-Path $projectRoot 'TokenRader.ps1'
$syntheticScriptPath = Join-Path $PSScriptRoot 'fixtures\launcher\TokenRader.ps1'

$cmdSource = [IO.File]::ReadAllText($cmdPath)
$expectedCmdStart = '(?im)^\s*start\s+""\s+"%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe"\s+-NoProfile\s+-STA\s+-WindowStyle\s+Hidden\s+-File\s+"%~dp0launcher\\Start-TokenRader\.ps1"\s*$'
Assert-LauncherWindow ($cmdSource -match $expectedCmdStart) '.cmd must start the internal bootstrap in hidden STA standard Windows PowerShell'
Assert-LauncherWindow ([regex]::Matches($cmdSource, '(?im)^\s*start\s+').Count -eq 1) '.cmd must have exactly one asynchronous start command'
Assert-LauncherWindow ($cmdSource -notmatch '(?i)\s/wait(?:\s|$)') '.cmd must not wait for the dashboard process'
Assert-LauncherWindow ($cmdSource -notmatch '(?i)(?:-ExecutionPolicy|-ep\b|\bBypass\b|\bUnblock(?:-File)?\b|\bEncodedCommand\b|-enc\b|Set-ExecutionPolicy)') '.cmd must not change execution policy, unblock files, or use encoded commands'
$cmdCommandLines = @($cmdSource -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object {
    $_.Length -gt 0 -and $_ -notmatch '^(?:@?echo\b|rem\b|::)'
})
$cmdStartLines = @($cmdCommandLines | Where-Object { $_ -match '(?i)(?:^|\s)start\s+' })
Assert-LauncherWindow ($cmdStartLines.Count -eq 1) '.cmd must contain exactly one process-start command; preflight and error text are not counted as launches'
$otherHostLaunchLines = @($cmdCommandLines | Where-Object {
    $_ -match '(?i)(?:^|[&|]\s*|\s)\s*(?:call\s+)?(?:"?%~dp0TokenRader\.exe"?|powershell(?:\.exe)?|pwsh(?:\.exe)?|cmd(?:\.exe)?)(?:\s|$)'
})
Assert-LauncherWindow ($otherHostLaunchLines.Count -eq 0) '.cmd must not launch another host or executable outside the expected START command'

$bootstrapSource = [IO.File]::ReadAllText($bootstrapPath)
Assert-LauncherWindow ($bootstrapSource -match '(?i)System32\\WindowsPowerShell\\v1\.0\\powershell\.exe') 'bootstrap must select the standard Windows PowerShell host'
Assert-LauncherWindow ($bootstrapSource -match '(?i)TokenRader\.ps1') 'bootstrap must target the root dashboard script'
Assert-LauncherWindow ($bootstrapSource -match '(?im)Split-Path\s+-Parent\s+\$PSScriptRoot') 'internal bootstrap must resolve the dashboard root from its parent directory'
Assert-LauncherWindow ($bootstrapSource -match '(?i)ProcessStartInfo') 'bootstrap must use ProcessStartInfo rather than shell execution'
Assert-LauncherWindow ($bootstrapSource -match '(?im)\.UseShellExecute\s*=\s*\$false\b') 'bootstrap must disable shell execution'
Assert-LauncherWindow ($bootstrapSource -match '(?im)\.CreateNoWindow\s*=\s*\$true\b') 'bootstrap must create a console-free child'
Assert-LauncherWindow ($bootstrapSource -match '(?im)\.WindowStyle\s*=\s*\[(?:System\.)?Diagnostics\.ProcessWindowStyle\]::Hidden') 'bootstrap must request a hidden child window'
Assert-LauncherWindow ($bootstrapSource -match '(?i)-NoProfile\s+-STA\s+-File\s+"') 'bootstrap must explicitly launch the dashboard in STA with a quoted file path'
Assert-LauncherWindow ($bootstrapSource -notmatch '(?i)(?:-ExecutionPolicy|-ep\b|\bBypass\b|\bUnblock(?:-File)?\b|\bEncodedCommand\b|-enc\b|Set-ExecutionPolicy|pwsh(?:\.exe)?|TokenRader\.exe|WaitForExit|Wait-Process|Start-Process)') 'bootstrap must neither change policy, fall back to another host/EXE, nor wait for the dashboard'
Assert-LauncherWindow ([regex]::Matches($bootstrapSource, '\[(?:System\.)?Diagnostics\.Process\]::Start\s*\(').Count -eq 1) 'bootstrap must start exactly one child'

$uiSource = [IO.File]::ReadAllText($uiSourcePath)
Assert-LauncherWindow ($uiSource -match '(?s)GetApartmentState\(\)\s*-ne\s*\[Threading\.ApartmentState\]::STA\).*?Start-Process\s+-FilePath\s+\$hostExecutable\s+-ArgumentList\s+\$arguments\s+-WindowStyle\s+Hidden') 'MTA-to-STA relaunch must also hide the PowerShell host window'

$standardPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cmdHostPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
Assert-LauncherWindow (Test-Path -LiteralPath $standardPowerShellPath -PathType Leaf) 'synthetic CMD smoke requires the standard Windows PowerShell host'
Assert-LauncherWindow (Test-Path -LiteralPath $cmdHostPath -PathType Leaf) 'synthetic CMD smoke requires cmd.exe'

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
# Exercise spaces, an apostrophe, and Unicode without depending on the source
# file's encoding under Windows PowerShell 5.1.
$fixtureRoot = Join-Path $tempParent ("Token Rader's Launcher " + [char]0x6D4B + [char]0x8BD5 + ' ' + [Guid]::NewGuid().ToString('N'))
$fixtureFullPath = [IO.Path]::GetFullPath($fixtureRoot)
Assert-LauncherWindow ($fixtureFullPath.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'fixture path must be a child of the system temporary directory'
[void][IO.Directory]::CreateDirectory($fixtureFullPath)

try {
    Copy-Item -LiteralPath $cmdPath -Destination (Join-Path $fixtureFullPath 'Start-TokenRader.cmd')
    $fixtureLauncherPath = Join-Path $fixtureFullPath 'launcher'
    [void][IO.Directory]::CreateDirectory($fixtureLauncherPath)
    $fixtureBootstrapPath = Join-Path $fixtureLauncherPath 'Start-TokenRader.ps1'
    Copy-Item -LiteralPath $bootstrapPath -Destination $fixtureBootstrapPath
    Copy-Item -LiteralPath $syntheticScriptPath -Destination (Join-Path $fixtureFullPath 'TokenRader.ps1')

    $reportPath = Join-Path $fixtureFullPath 'launcher-smoke-result.txt'
    $cmdStart = New-Object System.Diagnostics.ProcessStartInfo
    $cmdStart.FileName = $cmdHostPath
    $cmdStart.Arguments = '/d /c ""' + (Join-Path $fixtureFullPath 'Start-TokenRader.cmd') + '""'
    $cmdStart.WorkingDirectory = $fixtureFullPath
    $cmdStart.UseShellExecute = $false
    # Keep cmd.exe's own console behavior normal so its CreateNoWindow setting
    # cannot mask whether the child PowerShell host hides its console itself.
    $cmdStart.CreateNoWindow = $false
    $cmdStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    $cmdStart.RedirectStandardOutput = $true
    $cmdStart.RedirectStandardError = $true
    try {
        $cmdProcess = [Diagnostics.Process]::Start($cmdStart)
    } catch {
        $policyBlock = Get-LauncherWindowPolicyBlockInfo $_
        if ($null -ne $policyBlock) {
            $nativeErrorText = if ($null -eq $policyBlock.NativeErrorCode) { 'unavailable' } else { [string]$policyBlock.NativeErrorCode }
            throw ('LAUNCHER WINDOW TEST BLOCKED: local Application Control blocked the synthetic CMD process (native error code ' + $nativeErrorText + ').')
        }
        throw
    }
    Assert-LauncherWindow ($null -ne $cmdProcess) 'synthetic .cmd process must start'
    $stdoutTask = $cmdProcess.StandardOutput.ReadToEndAsync()
    $stderrTask = $cmdProcess.StandardError.ReadToEndAsync()
    try {
        Assert-LauncherWindow ($cmdProcess.WaitForExit(5000)) '.cmd must exit promptly without waiting for its dashboard child'
        $cmdProcess.WaitForExit()
        $cmdOutput = $stdoutTask.GetAwaiter().GetResult() + "`n" + $stderrTask.GetAwaiter().GetResult()
        if ($cmdOutput -match '(?i)Application Control policy has blocked this file|blocked by your system administrator' -or $cmdProcess.ExitCode -eq 1260) {
            throw 'LAUNCHER WINDOW TEST BLOCKED: local Application Control blocked the synthetic PowerShell host or script; security policy was not changed.'
        }
        Assert-LauncherWindow ($cmdProcess.ExitCode -eq 0) ('.cmd must report a successful asynchronous launch; exit code=' + $cmdProcess.ExitCode)
    } finally {
        $cmdProcess.Dispose()
    }
    Assert-SyntheticHiddenStaReport $reportPath '.cmd-to-bootstrap-to-PowerShell path'

    # A nonzero but invisible console handle must fail, unlike the old test.
    [IO.File]::WriteAllText($reportPath, 'consoleAttached=true;consoleVisible=false;apartment=STA')
    $invisibleAttachedConsoleRejected = $false
    try { Assert-SyntheticHiddenStaReport $reportPath 'synthetic pseudoconsole negative case' } catch {
        $invisibleAttachedConsoleRejected = $_.Exception.Message -match 'must have no attached console'
    }
    Assert-LauncherWindow $invisibleAttachedConsoleRejected 'an invisible attached console must not pass the smoke assertion'
    Remove-Item -LiteralPath $reportPath -Force

    # Test the bootstrap directly as well: CMD's prompt exit does not prove
    # that its own PowerShell bootstrap releases the terminal promptly.
    $bootstrapStart = New-Object System.Diagnostics.ProcessStartInfo
    $bootstrapStart.FileName = $standardPowerShellPath
    $bootstrapStart.Arguments = '-NoProfile -STA -WindowStyle Hidden -File "' + $fixtureBootstrapPath + '"'
    $bootstrapStart.WorkingDirectory = $fixtureFullPath
    $bootstrapStart.UseShellExecute = $false
    $bootstrapStart.CreateNoWindow = $false
    $bootstrapStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $bootstrapStart.RedirectStandardOutput = $true
    $bootstrapStart.RedirectStandardError = $true
    try {
        $bootstrapProcess = [Diagnostics.Process]::Start($bootstrapStart)
    } catch {
        $policyBlock = Get-LauncherWindowPolicyBlockInfo $_
        if ($null -ne $policyBlock) { throw 'LAUNCHER WINDOW TEST BLOCKED: local Application Control blocked the synthetic bootstrap; security policy was not changed.' }
        throw
    }
    Assert-LauncherWindow ($null -ne $bootstrapProcess) 'synthetic bootstrap process must start'
    $bootstrapStdoutTask = $bootstrapProcess.StandardOutput.ReadToEndAsync()
    $bootstrapStderrTask = $bootstrapProcess.StandardError.ReadToEndAsync()
    try {
        Assert-LauncherWindow ($bootstrapProcess.WaitForExit(5000)) 'PowerShell bootstrap must exit within five seconds without waiting for its dashboard child'
        $bootstrapProcess.WaitForExit()
        $bootstrapOutput = $bootstrapStdoutTask.GetAwaiter().GetResult() + "`n" + $bootstrapStderrTask.GetAwaiter().GetResult()
        if ($bootstrapOutput -match '(?i)Application Control policy has blocked this file|blocked by your system administrator' -or $bootstrapProcess.ExitCode -eq 1260) {
            throw 'LAUNCHER WINDOW TEST BLOCKED: local Application Control blocked the synthetic bootstrap or child; security policy was not changed.'
        }
        Assert-LauncherWindow ($bootstrapProcess.ExitCode -eq 0) ('bootstrap must report successful launch; exit code=' + $bootstrapProcess.ExitCode + '; output=' + $bootstrapOutput)
    } finally {
        $bootstrapProcess.Dispose()
    }
    Assert-SyntheticHiddenStaReport $reportPath 'direct bootstrap-to-PowerShell path'

} finally {
    # Verify the resolved deletion target is still exactly our dedicated temp
    # fixture before cleaning it up.
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureFullPath)
    if ($resolvedFixture -eq $fixtureFullPath -and $resolvedFixture.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PASS Launcher window: single public CMD entry, internal bootstrap, prompt bootstrap exit, and console-free STA synthetic children (including rejection of invisible attached consoles).'
