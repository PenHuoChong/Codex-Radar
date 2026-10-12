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
                if ($report -match '^console=(?:true|false);apartment=(?:STA|MTA|Unknown)$') { return $report }
            } catch { }
        }
        [Threading.Thread]::Sleep(50)
    }
    throw 'LAUNCHER WINDOW TEST FAILED: synthetic script did not report before timeout'
}

function Assert-SyntheticHiddenStaReport {
    param([string]$ReportPath, [string]$PathDescription)
    $report = Get-LauncherWindowSmokeReport -ReportPath $ReportPath
    Assert-LauncherWindow ($report -eq 'console=false;apartment=STA') ($PathDescription + ' must run without a console window in STA; report=[' + $report + ']')
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
$syntheticScriptPath = Join-Path $PSScriptRoot 'fixtures\launcher\TokenRader.ps1'

$cmdSource = [IO.File]::ReadAllText($cmdPath)
Assert-LauncherWindow ($cmdSource -match '(?im)^\s*start\s+""\s+"%~dp0TokenRader\.exe"\s*$') '.cmd must asynchronously dispatch the adjacent GUI launcher through START'
Assert-LauncherWindow ($cmdSource -notmatch '(?i)\s/wait(?:\s|$)') '.cmd must not wait for the dashboard process'
Assert-LauncherWindow ($cmdSource -notmatch '(?i)\b(?:powershell|pwsh)(?:\.exe)?\b') '.cmd must not run PowerShell directly in the foreground or as a fallback'
Assert-LauncherWindow ($cmdSource -notmatch '(?im)^\s*(?:call\s+)?"?%~dp0TokenRader\.exe"?(?:\s|$)') '.cmd must not invoke the GUI launcher as a foreground command'

$launcherSource = [IO.File]::ReadAllText($launcherSourcePath)
$processStartInfo = [regex]::Match($launcherSource, '(?s)new\s+ProcessStartInfo\s*\{(?<body>.*?)\}\s*;')
Assert-LauncherWindow $processStartInfo.Success 'launcher source must configure a ProcessStartInfo'
$startInfoBody = $processStartInfo.Groups['body'].Value
Assert-LauncherWindow ($startInfoBody -match '(?m)\bUseShellExecute\s*=\s*false\s*,') 'launcher must disable shell execution for the hidden child'
Assert-LauncherWindow ($startInfoBody -match '(?m)\bCreateNoWindow\s*=\s*true\s*,') 'launcher must prevent creation of a console window'
Assert-LauncherWindow ($startInfoBody -match '(?m)\bWindowStyle\s*=\s*ProcessWindowStyle\.Hidden\s*(?:,|$)') 'launcher must request a hidden child window'
Assert-LauncherWindow ($startInfoBody -match '(?i)\-WindowStyle\s+Hidden') 'PowerShell child arguments must request a hidden window'
Assert-LauncherWindow ($launcherSource -match '\[assembly:\s*AssemblyTitle\("Token Rader"\)\]') 'launcher source must remain the Token Rader GUI host'
$uiSource = [IO.File]::ReadAllText((Join-Path $projectRoot 'TokenRader.ps1'))
Assert-LauncherWindow ($uiSource -match '(?s)GetApartmentState\(\)\s*-ne\s*\[Threading\.ApartmentState\]::STA\).*?Start-Process\s+-FilePath\s+\$hostExecutable\s+-ArgumentList\s+\$arguments\s+-WindowStyle\s+Hidden') 'MTA-to-STA relaunch must also hide the PowerShell host window'

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

# Exercise a copied launcher only from a disposable fixture directory whose
# adjacent script is synthetic. The real application script is never run.
$powerShellFound = $false
foreach ($executable in @('powershell.exe', 'pwsh.exe')) {
    foreach ($rawDirectory in @(([string]$env:PATH).Split([IO.Path]::PathSeparator))) {
        $directory = $rawDirectory.Trim().Trim('"')
        if ($directory.Length -eq 0) { continue }
        if (Test-Path -LiteralPath (Join-Path $directory $executable) -PathType Leaf) {
            $powerShellFound = $true
            break
        }
    }
    if ($powerShellFound) { break }
}
Assert-LauncherWindow $powerShellFound 'synthetic smoke requires PowerShell on PATH, as the launcher contract does'

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$fixtureRoot = Join-Path $tempParent ('Token Rader Launcher Window Tests ' + [Guid]::NewGuid().ToString('N'))
$fixtureFullPath = [IO.Path]::GetFullPath($fixtureRoot)
Assert-LauncherWindow ($fixtureFullPath.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'fixture path must be a child of the system temporary directory'
[void][IO.Directory]::CreateDirectory($fixtureFullPath)

try {
    Copy-Item -LiteralPath $launcherPath -Destination (Join-Path $fixtureFullPath 'TokenRader.exe')
    Copy-Item -LiteralPath $cmdPath -Destination (Join-Path $fixtureFullPath 'Start-TokenRader.cmd')
    Copy-Item -LiteralPath $syntheticScriptPath -Destination (Join-Path $fixtureFullPath 'TokenRader.ps1')

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
            throw ('LAUNCHER WINDOW TEST BLOCKED: local Application Control blocked the synthetic launcher process (native error code ' + $nativeErrorText + '). Static checks passed; runtime smoke was not attempted.')
        }
        throw
    }
    Assert-LauncherWindow ($null -ne $launcherProcess) 'synthetic direct launcher process must start'
    try {
        Assert-LauncherWindow ($launcherProcess.WaitForExit(5000)) 'launcher must return promptly after detaching its synthetic PowerShell child'
    } finally {
        $launcherProcess.Dispose()
    }
    Assert-SyntheticHiddenStaReport (Join-Path $fixtureFullPath 'launcher-smoke-result.txt') 'direct launcher'

    $reportPath = Join-Path $fixtureFullPath 'launcher-smoke-result.txt'
    Remove-Item -LiteralPath $reportPath -Force
    $cmdStart = New-Object System.Diagnostics.ProcessStartInfo
    $cmdStart.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
    $cmdStart.Arguments = '/d /c ""' + (Join-Path $fixtureFullPath 'Start-TokenRader.cmd') + '""'
    $cmdStart.WorkingDirectory = $fixtureFullPath
    $cmdStart.UseShellExecute = $false
    $cmdStart.CreateNoWindow = $true
    $cmdStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    try {
        $cmdProcess = [Diagnostics.Process]::Start($cmdStart)
    } catch {
        $policyBlock = Get-LauncherWindowPolicyBlockInfo $_
        if ($null -ne $policyBlock) {
            $nativeErrorText = if ($null -eq $policyBlock.NativeErrorCode) { 'unavailable' } else { [string]$policyBlock.NativeErrorCode }
            throw ('LAUNCHER WINDOW TEST BLOCKED: local Application Control blocked the synthetic .cmd smoke process (native error code ' + $nativeErrorText + ').')
        }
        throw
    }
    Assert-LauncherWindow ($null -ne $cmdProcess) '.cmd smoke process must start'
    try {
        Assert-LauncherWindow ($cmdProcess.WaitForExit(5000)) '.cmd must exit promptly without waiting for its dashboard child'
    } finally {
        $cmdProcess.Dispose()
    }
    Assert-SyntheticHiddenStaReport $reportPath '.cmd-to-launcher path'
} finally {
    # Verify the resolved deletion target is still exactly our dedicated temp
    # fixture before cleaning it up.
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureFullPath)
    if ($resolvedFixture -eq $fixtureFullPath -and $resolvedFixture.StartsWith($tempParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host 'PASS Launcher window: detached .cmd dispatch, GUI PE subsystem, and hidden STA synthetic child smoke.'
