[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Assert-StartupDiagnostic([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('STARTUP DIAGNOSTICS TEST FAILED: ' + $Message) }
}
# Extract production classification only. Do not import Core, load its DLL,
# execute the diagnostic worker, read sessions, or open any private index.
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'TokenRader.Core.psm1'))
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-StartupDiagnostic (@($errors).Count -eq 0) 'Core parse'
$classifier = $ast.Find({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Get-TokenRaderSafeIndexFailure'
}, $true)
Assert-StartupDiagnostic ($null -ne $classifier) 'production classifier exists'
Invoke-Expression $classifier.Extent.Text
$literals = @($classifier.FindAll({ param($n)
    $n -is [Management.Automation.Language.StringConstantExpressionAst]
}, $true))
$historyProducer = $ast.Find({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -eq 'Complete-TokenRaderRecentHistory'
}, $true)
$messageFormat = @($historyProducer.FindAll({ param($n)
    $n -is [Management.Automation.Language.StringConstantExpressionAst] -and
    $n.Value.Contains('{0}') -and $n.Value.Contains('{1}') -and $n.Value.Contains('{2}')
}, $true))[0].Value
$historyFormat = @($literals | Where-Object { $_.Value.Contains('{2}') })[0].Value
$knownAssignment = $classifier.Find({ param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$known'
}, $true)
$known = @($knownAssignment.Right.FindAll({ param($n)
    $n -is [Management.Automation.Language.StringConstantExpressionAst]
}, $true) | ForEach-Object { $_.Value })
Assert-StartupDiagnostic ($known.Count -eq 7) 'closed history reason whitelist'
$separator = [string][char]0xFF1B
$privatePath = 'Z:\synthetic-private\secret-session.jsonl'
$privateBody = '{"text":"synthetic-private-body","command":"synthetic-private-command"}'
function New-HistoryMessage([string]$Remaining, [string]$Blocked, [string]$Reasons) {
    return $messageFormat -f $Remaining,$Blocked,$Reasons
}
function Assert-NoPrivateOutput($Result) {
    Assert-StartupDiagnostic (-not $Result.Message.Contains($privatePath) -and
        -not $Result.Message.Contains('synthetic-private-body') -and
        -not $Result.Message.Contains('synthetic-private-command') -and
        -not $Result.Message.Contains('unknown-source-reason')) 'private input omitted'
}
foreach ($counts in @(@('0','0'), @('9','3'), @('2147483647','2147483647'))) {
    foreach ($reason in $known) {
        $message = New-HistoryMessage $counts[0] $counts[1] ($reason + $separator + $privatePath + $privateBody)
        $safe = Get-TokenRaderSafeIndexFailure -Exception ([InvalidOperationException]::new($message))
        Assert-StartupDiagnostic ($safe.Kind -eq 'history') 'recent24 incomplete is history'
        Assert-StartupDiagnostic ($safe.Message -eq ($historyFormat -f $counts[0],$counts[1],$reason)) 'counts and whitelisted reason preserved exactly'
        Assert-NoPrivateOutput $safe
    }
}
$message = New-HistoryMessage '8' '2' (($known + $known + @('unknown-source-reason', $privatePath, $privateBody)) -join $separator)
$safe = Get-TokenRaderSafeIndexFailure -Exception ([Exception]::new('synthetic outer path ' + $privatePath, [InvalidOperationException]::new($message)))
Assert-StartupDiagnostic ($safe.Kind -eq 'history' -and $safe.Message -eq
    ($historyFormat -f '8','2',($known -join $separator))) 'inner exception, deduplicated closed reasons'
Assert-NoPrivateOutput $safe
$safe = Get-TokenRaderSafeIndexFailure -Exception ([Exception]::new((New-HistoryMessage '1' '1' ('unknown-source-reason ' + $privatePath + $privateBody))))
Assert-StartupDiagnostic ($safe.Message -eq ($historyFormat -f '1','1','')) 'unknown reasons never printed'
Assert-NoPrivateOutput $safe
foreach ($invalidCount in @('-1', '1.5', 'NaN', '12345678901', $privatePath, $privateBody)) {
    $safe = Get-TokenRaderSafeIndexFailure -Exception ([Exception]::new((New-HistoryMessage $invalidCount '1' $known[0])))
    Assert-StartupDiagnostic ($safe.Kind -eq 'unknown') 'malformed count cannot inject history output'
    Assert-NoPrivateOutput $safe
}
$message = (New-HistoryMessage '4' '1' $known[0]) + $privatePath + $privateBody + $separator + $known[1]
$safe = Get-TokenRaderSafeIndexFailure -Exception ([Exception]::new($message))
Assert-StartupDiagnostic ($safe.Message -eq ($historyFormat -f '4','1',$known[0])) 'appended body whitelist word cannot become a reason'
Assert-NoPrivateOutput $safe
$message = New-HistoryMessage '4' '1' ('unknown-source-reason ' + $known[0] + ' appended')
$safe = Get-TokenRaderSafeIndexFailure -Exception ([Exception]::new($message))
Assert-StartupDiagnostic ($safe.Message -eq ($historyFormat -f '4','1','')) 'whitelist substring is not a complete reason'
Assert-NoPrivateOutput $safe
$message = New-HistoryMessage '1234567890' '0987654321' $known[0]
$safe = Get-TokenRaderSafeIndexFailure -Exception ([Exception]::new($message))
Assert-StartupDiagnostic ($safe.Kind -eq 'history' -and $safe.Message -eq
    ($historyFormat -f '1234567890','0987654321',$known[0])) 'ten digit count bound supported'
$cases = @(
    @('Oversized usage/context line cannot be safely indexed', 'safety'),
    @('Compacted archival record cannot be safely indexed', 'safety'),
    @('Source was replaced/truncated', 'safety'),
    @('Replacement source has no complete JSONL boundary', 'pending'),
    @('Replacement source has no complete JSONL line', 'pending'),
    @('Replacement boundary is not a complete JSONL line', 'pending'),
    @('Replacement source shrank before its frozen boundary', 'pending'),
    @('Replacement source changed before its frozen boundary', 'pending'),
    @('Malformed replacement usage record', 'safety'),
    @('Malformed replacement context record', 'safety'),
    @('Malformed replacement tool metadata record', 'safety'),
    @('Malformed replacement metadata record', 'safety')
)
foreach ($case in $cases) {
    $safe = Get-TokenRaderSafeIndexFailure -Exception ([IO.IOException]::new(($case[0] + ' ' + $privatePath + $privateBody)))
    Assert-StartupDiagnostic ($safe.Kind -eq $case[1]) ('existing classification: ' + $case[0])
    Assert-NoPrivateOutput $safe
}
foreach ($exception in @([UnauthorizedAccessException]::new($privatePath + $privateBody),
    [Security.SecurityException]::new($privatePath + $privateBody), [IO.IOException]::new($privatePath + $privateBody),
    [InvalidOperationException]::new($privatePath + $privateBody))) {
    $expected = if ($exception -is [UnauthorizedAccessException] -or $exception -is [Security.SecurityException]) { 'access' }
        elseif ($exception -is [IO.IOException]) { 'io' } else { 'unknown' }
    $safe = Get-TokenRaderSafeIndexFailure -Exception $exception
    Assert-StartupDiagnostic ($safe.Kind -eq $expected) ('existing type classification: ' + $expected)
    Assert-NoPrivateOutput $safe
}
$scriptSource = [IO.File]::ReadAllText((Join-Path $root 'scripts/Measure-StartupDiagnostics.ps1'))
$scriptTokens = $null; $scriptErrors = $null
$diagnosticAst = [Management.Automation.Language.Parser]::ParseInput($scriptSource, [ref]$scriptTokens, [ref]$scriptErrors)
Assert-StartupDiagnostic (@($scriptErrors).Count -eq 0) 'diagnostic script parses without executing it'
$dashboardGuard = $diagnosticAst.Find({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-StartupDashboardClosed'
}, $true)
Assert-StartupDiagnostic ($null -ne $dashboardGuard) 'dashboard guard exists'
& {
    function Get-Process { [CmdletBinding()]param(); return $script:syntheticWindows }
    Invoke-Expression $dashboardGuard.Extent.Text
    foreach ($processName in @('TokenRader','powershell','pwsh')) {
        $script:syntheticWindows = @([pscustomobject]@{ ProcessName=$processName; MainWindowTitle='Token Rader synthetic' })
        $rejected = $false
        try { Assert-StartupDashboardClosed } catch { $rejected = $true }
        Assert-StartupDiagnostic $rejected ('visible dashboard rejected: ' + $processName)
    }
    $script:syntheticWindows = @([pscustomobject]@{ ProcessName='pwsh'; MainWindowTitle='unrelated synthetic terminal' })
    Assert-StartupDashboardClosed
    $script:syntheticWindows = @()
    Assert-StartupDashboardClosed
}
$wrapperAssignment = $diagnosticAst.Find({ param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$wrapper'
}, $true)
$wrapperExpression = $wrapperAssignment.Right.Find({ param($n)
    $n -is [Management.Automation.Language.ScriptBlockExpressionAst]
}, $true)
Assert-StartupDiagnostic ($null -ne $wrapperExpression) 'worker wrapper exists'
$wrapperText = $wrapperExpression.Extent.Text.Substring(1,$wrapperExpression.Extent.Text.Length-2)
$originalOverride = [Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB','Process')
$authorizedPath = 'Z:\synthetic project;literal"$value\data\private\index\index.db'
$fakeWorker = @'
param([string]$ExpectedIndexDb,[string]$Mode)
if ([Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB','Process') -cne $ExpectedIndexDb) {
    throw [InvalidOperationException]::new('Synthetic worker received an incorrect index scope.')
}
if ($Mode -eq 'failure') { throw [InvalidOperationException]::new('synthetic-private-body') }
if ($Mode -eq 'cancellation') { throw [OperationCanceledException]::new('synthetic-private-body') }
[pscustomobject]@{ StartedAt=[DateTimeOffset]::Parse('2026-01-01T00:00:00Z'); StartOffsets=@{ synthetic=0L } }
'@
try {
    foreach ($previous in @($null,'Z:\other-synthetic-project\data\private\index\index.db')) {
        foreach ($mode in @('success','failure','cancellation')) {
            [Environment]::SetEnvironmentVariable('TOKEN_RADER_INDEX_DB',$previous,'Process')
            $expectedRestoredOverride = [Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB','Process')
            $pipeline = [PowerShell]::Create()
            try {
                [void]$pipeline.AddScript($wrapperText).AddParameter('ProductionWorkerSource',$fakeWorker).
                    AddParameter('SafeFailureSource',$classifier.Extent.Text).
                    AddParameter('WorkerParameters',@{ ExpectedIndexDb=$authorizedPath; Mode=$mode }).
                    AddParameter('AuthorizedIndexDbPath',$authorizedPath)
                $results = @($pipeline.Invoke())
                Assert-StartupDiagnostic ($pipeline.Streams.Error.Count -eq 0 -and $results.Count -eq 1) 'synthetic wrapper returns one safe result'
                Assert-StartupDiagnostic ($results[0].Completed -eq ($mode -eq 'success')) ('synthetic completion: ' + $mode)
                if ($mode -ne 'success') { Assert-NoPrivateOutput ([pscustomobject]@{ Message=[string]$results[0].SafeSummary }) }
                Assert-StartupDiagnostic ([Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB','Process') -ceq $expectedRestoredOverride) ('original override restored: ' + $mode)
            } finally { $pipeline.Dispose() }
        }
    }
} finally {
    [Environment]::SetEnvironmentVariable('TOKEN_RADER_INDEX_DB',$originalOverride,'Process')
    Remove-Variable -Name syntheticWindows -Scope Script -ErrorAction SilentlyContinue
}
Write-Host ('STARTUP_DIAGNOSTICS_TESTS_PASSED edition={0} version={1}' -f $PSVersionTable.PSEdition,$PSVersionTable.PSVersion)
