[CmdletBinding()]
param(
    [switch]$IncludeExe
)

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
                if ($report -match '^consoleVisible=(?:true|false);apartment=(?:STA|MTA|Unknown)$') { return $report }
            } catch { }
        }
        [Threading.Thread]::Sleep(50)
    }
    throw 'LAUNCHER WINDOW TEST FAILED: synthetic script did not report before timeout'
}

function Assert-SyntheticHiddenStaReport {
    param([string]$ReportPath, [string]$PathDescription)
    $report = Get-LauncherWindowSmokeReport -ReportPath $ReportPath
    Assert-LauncherWindow ($report -eq 'consoleVisible=false;apartment=STA') ($PathDescription + ' must have no visible console window in STA; report=[' + $report + ']')
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
$launcherPath = Join-Path $projectRoot 'TokenRader.exe'
$launcherSourcePath = Join-Path $projectRoot 'launcher\TokenRader.Launcher.cs'
$uiSourcePath = Join-Path $projectRoot 'TokenRader.ps1'
$syntheticScriptPath = Join-Path $PSScriptRoot 'fixtures\launcher\TokenRader.ps1'

$cmdSource = [IO.File]::ReadAllText($cmdPath)
$expectedCmdStart = '(?im)^\s*start\s+""\s+"%SystemRoot%\\System32\\WindowsPowerShell\\v1\.0\\powershell\.exe"\s+-NoProfile\s+-STA\s+-WindowStyle\s+Hidden\s+-File\s+"%~dp0TokenRader\.ps1"\s*$'
Assert-LauncherWindow ($cmdSource -match $expectedCmdStart) '.cmd must start the adjacent source script in hidden STA Windows PowerShell'
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

$launcherSource = [IO.File]::ReadAllText($launcherSourcePath)
$processStartInfo = [regex]::Match($launcherSource, '(?s)new\s+ProcessStartInfo\s*\{(?<body>.*?)\}\s*;')
Assert-LauncherWindow $processStartInfo.Success 'launcher source must configure a ProcessStartInfo'
$startInfoBody = $processStartInfo.Groups['body'].Value
Assert-LauncherWindow ($startInfoBody -match '(?m)\bUseShellExecute\s*=\s*false\s*,') 'launcher must disable shell execution for the hidden child'
Assert-LauncherWindow ($startInfoBody -match '(?m)\bCreateNoWindow\s*=\s*true\s*,') 'launcher must prevent creation of a console window'
Assert-LauncherWindow ($startInfoBody -match '(?m)\bWindowStyle\s*=\s*ProcessWindowStyle\.Hidden\s*(?:,|$)') 'launcher must request a hidden child window'
Assert-LauncherWindow ($startInfoBody -match '(?i)\-WindowStyle\s+Hidden') 'PowerShell child arguments must request a hidden window'
Assert-LauncherWindow ($launcherSource -match '\[assembly:\s*AssemblyTitle\("Token Rader"\)\]') 'launcher source must remain the Token Rader GUI host'
$uiSource = [IO.File]::ReadAllText($uiSourcePath)
Assert-LauncherWindow ($uiSource -match '(?s)GetApartmentState\(\)\s*-ne\s*\[Threading\.ApartmentState\]::STA\).*?Start-Process\s+-FilePath\s+\$hostExecutable\s+-ArgumentList\s+\$arguments\s+-WindowStyle\s+Hidden') 'MTA-to-STA relaunch must also hide the PowerShell host window'

# Keep validating the existing launcher as a GUI PE, but never execute it by
# default. Runtime execution is opt-in because local Application Control may
# block this unsigned launcher.
$launcherBytes = [IO.File]::ReadAllBytes($launcherPath)
Assert-LauncherWindow ($launcherBytes.Length -ge 128) 'built launcher must be a complete PE image'
Assert-LauncherWindow ([BitConverter]::ToUInt16($launcherBytes, 0) -eq 0x5A4D) 'built launcher must have an MZ header'
$peOffset = [BitConverter]::ToInt32($launcherBytes, 0x3c)
Assert-LauncherWindow ($peOffset -ge 64 -and ($peOffset + 24 + 70) -le $launcherBytes.Length) 'built launcher PE header must be within the file bounds'
Assert-LauncherWindow ([BitConverter]::ToUInt32($launcherBytes, $peOffset) -eq 0x00004550) 'built launcher must have a PE signature'
$optionalHeaderOffset = $peOffset + 24
$optionalHeaderMagic = [BitConverter]::ToUInt16($launcherBytes, $optionalHeaderOffset)
Assert-LauncherWindow ($optionalHeaderMagic -eq 0x10b -or $optionalHeaderMagic -eq 0x20b) 'built launcher must have a supported PE optional header'
$subsystem = [BitConverter]::ToUInt16($launcherBytes, $optionalHeaderOffset + 68)
Assert-LauncherWindow ($subsystem -eq 2) ('built launcher PE subsystem must be Windows GUI (2), not console (' + $subsystem + ')')

$standardPowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cmdHostPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
Assert-LauncherWindow (Test-Path -LiteralPath $standardPowerShellPath -PathType Leaf) 'synthetic CMD smoke requires the standard Windows PowerShell host'
Assert-LauncherWindow (Test-Path -LiteralPath $cmdHostPath -PathType Leaf) 'synthetic CMD smoke requires cmd.exe'

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$fixtureRoot = Join-Path $tempParent ('Token Rader Launcher Window Tests ' + [Guid]::NewGuid().ToString('N'))
$fixtureFullPath = [IO.Path]::GetFullPath($fixtureRoot)
Assert-LauncherWindow ($fixtureFullPath.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'fixture path must be a child of the system temporary directory'
[void][IO.Directory]::CreateDirectory($fixtureFullPath)

try {
    Copy-Item -LiteralPath $cmdPath -Destination (Join-Path $fixtureFullPath 'Start-TokenRader.cmd')
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
    Assert-SyntheticHiddenStaReport $reportPath '.cmd-to-PowerShell path'

    if ($IncludeExe) {
        # This branch is the only place where the real launcher executable is
        # started. It still runs only against the synthetic fixture script.
        Copy-Item -LiteralPath $launcherPath -Destination (Join-Path $fixtureFullPath 'TokenRader.exe')
        Remove-Item -LiteralPath $reportPath -Force
        $launcherStart = New-Object System.Diagnostics.ProcessStartInfo
        $launcherStart.FileName = Join-Path $fixtureFullPath 'TokenRader.exe'
        $launcherStart.WorkingDirectory = $fixtureFullPath
        $launcherStart.UseShellExecute = $false
        $launcherStart.CreateNoWindow = $true
        $launcherStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        try {
            $launcherProcess = [Diagnostics.Process]::Start($launcherStart)
        } catch {
            $policyBlock = Get-LauncherWindowPolicyBlockInfo $_
            if ($null -ne $policyBlock) {
                $nativeErrorText = if ($null -eq $policyBlock.NativeErrorCode) { 'unavailable' } else { [string]$policyBlock.NativeErrorCode }
                throw ('LAUNCHER WINDOW TEST BLOCKED: local Application Control blocked the synthetic launcher process (native error code ' + $nativeErrorText + '). Static checks passed; the opt-in runtime smoke did not complete.')
            }
            throw
        }
        Assert-LauncherWindow ($null -ne $launcherProcess) 'synthetic direct launcher process must start'
        try {
            Assert-LauncherWindow ($launcherProcess.WaitForExit(5000)) 'launcher must return promptly after detaching its synthetic PowerShell child'
        } finally {
            $launcherProcess.Dispose()
        }
        Assert-SyntheticHiddenStaReport $reportPath 'opt-in direct launcher path'
    }
} finally {
    # Verify the resolved deletion target is still exactly our dedicated temp
    # fixture before cleaning it up.
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureFullPath)
    if ($resolvedFixture -eq $fixtureFullPath -and $resolvedFixture.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($IncludeExe) {
    Write-Host 'PASS Launcher window: direct PowerShell CMD path, GUI PE metadata, hidden STA synthetic child, and opt-in EXE runtime smoke.'
} else {
    Write-Host 'PASS Launcher window: direct PowerShell CMD path, GUI PE metadata, and hidden STA synthetic child. EXE runtime NOT TESTED (opt in with -IncludeExe).'
}
