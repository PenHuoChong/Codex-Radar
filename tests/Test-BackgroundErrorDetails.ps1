[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $projectRoot 'TokenRader.ps1'
$tokens = $null
$parseErrors = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ('BACKGROUND ERROR TEST FAILED: production source did not parse: ' + $parseErrors[0].Message)
}
$functionAst = $sourceAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-TokenRaderBackgroundErrorMessage'
}, $true) | Select-Object -First 1
if ($null -eq $functionAst) {
    throw 'BACKGROUND ERROR TEST FAILED: production helper was not found'
}
Invoke-Expression $functionAst.Extent.Text

function Assert-BackgroundError {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('BACKGROUND ERROR TEST FAILED: ' + $Message) }
}

function New-SyntheticErrorRecord {
    param([System.Exception]$ErrorException)
    return [System.Management.Automation.ErrorRecord]::new(
        $ErrorException,
        'Synthetic.BackgroundError',
        [System.Management.Automation.ErrorCategory]::NotSpecified,
        $null)
}

# A stream record's exception may itself wrap the useful root cause.
$nestedCause = [System.InvalidOperationException]::new('synthetic nested root cause')
$nestedWrapper = [System.Exception]::new('synthetic outer wrapper', $nestedCause)
$streamRecord = New-SyntheticErrorRecord -ErrorException $nestedWrapper
$worker = [pscustomobject]@{
    Streams = [pscustomobject]@{ Error = @($streamRecord) }
}
$streamMessage = Get-TokenRaderBackgroundErrorMessage -Worker $worker -Exception $null
Assert-BackgroundError ($streamMessage -match 'synthetic nested root cause') 'nested Stream.Error.Exception cause was omitted'

# RuntimeException exposes its originating ErrorRecord separately; follow it
# even when the RuntimeException has no InnerException.
$embeddedCause = [System.InvalidOperationException]::new('synthetic embedded ErrorRecord cause')
$embeddedRecord = New-SyntheticErrorRecord -ErrorException $embeddedCause
$runtimeWrapper = [System.Management.Automation.RuntimeException]::new(
    'synthetic runtime wrapper', $null, $embeddedRecord)
$embeddedMessage = Get-TokenRaderBackgroundErrorMessage -Worker $null -Exception $runtimeWrapper
Assert-BackgroundError ($embeddedMessage -match 'synthetic embedded ErrorRecord cause') 'ErrorRecord embedded in RuntimeException was omitted'

# The lock timeout's wrapper/path is less useful than the actionable cause.
$lockInner = [System.IO.IOException]::new('The process cannot access the file because it is being used by another process.')
$lockTimeout = [System.TimeoutException]::new(
    'Timed out waiting for the Token Radar index lock: C:\synthetic\index.db.lock', $lockInner)
$timeoutMessage = Get-TokenRaderBackgroundErrorMessage -Worker $null -Exception $lockTimeout
$lockTimeoutPhrase = -join ([char[]]@(0x7D22, 0x5F15, 0x9501, 0x8D85, 0x65F6))
$backgroundTaskPhrase = -join ([char[]]@(0x540E, 0x53F0, 0x4EFB, 0x52A1, 0x6216, 0x7A0B, 0x5E8F, 0x5B9E, 0x4F8B))
Assert-BackgroundError ($timeoutMessage.Contains($lockTimeoutPhrase) -and $timeoutMessage.Contains($backgroundTaskPhrase)) 'lock timeout did not produce a concise actionable cause'
Assert-BackgroundError ($timeoutMessage -notmatch 'C:\\synthetic') 'lock timeout exposed an unnecessary path'

$accessError = [System.UnauthorizedAccessException]::new(
    "Access to the path 'C:\synthetic\index.db.lock' is denied.")
$accessMessage = Get-TokenRaderBackgroundErrorMessage -Worker $null -Exception $accessError
$permissionPhrase = -join ([char[]]@(0x6743, 0x9650, 0x4E0D, 0x8DB3))
Assert-BackgroundError ($accessMessage.Contains($permissionPhrase)) 'lock access error did not identify a permissions problem'
$directoryAccessError = [System.UnauthorizedAccessException]::new(
    "Access to the path 'C:\synthetic\index' is denied.")
$directoryAccessMessage = Get-TokenRaderBackgroundErrorMessage -Worker $null -Exception $directoryAccessError
Assert-BackgroundError ($directoryAccessMessage.Contains($permissionPhrase)) 'directory access error did not identify a permissions problem'

# A message-less exception must never turn into an empty UI status.
$emptyException = [System.Exception]::new('')
$fallbackMessage = Get-TokenRaderBackgroundErrorMessage -Worker $null -Exception $emptyException
Assert-BackgroundError (-not [string]::IsNullOrWhiteSpace($fallbackMessage)) 'empty exception did not use a nonempty fallback'

Write-Output 'BACKGROUND_ERROR_DETAILS_TESTS_PASSED'
