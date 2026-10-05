[CmdletBinding()]
param([string]$ProjectRoot = '', [switch]$RunStartWorkerAuthorized)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This invokes the production start worker once. It may update the normal
# metadata index, but never opens the dashboard, reads account/auth files,
# rebuilds the index, or persists diagnostic output. Close the dashboard first.
function Read-SourceAst([string]$Path) {
    $source = [IO.File]::ReadAllText($Path)
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw [InvalidOperationException]::new('Source parse failed.') }
    return $ast
}
function Get-SafeNumber($Value) {
    $number = 0L
    if ($null -ne $Value -and [long]::TryParse([string]$Value, [ref]$number) -and $number -ge 0) { return $number }
    return 0L
}
function Assert-StartupDashboardClosed {
    $windows = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('TokenRader','powershell','pwsh') -and $_.MainWindowTitle -match '^Token Rader'
    })
    if ($windows.Count -gt 0) { throw [InvalidOperationException]::new('Dashboard must be closed.') }
}

$worker = $null; $async = $null; $cts = $null; $cancelBridge = $null
$stopAsync = $null; $ended = $false
$completedSuccessfully = $false
try {
    if (-not $RunStartWorkerAuthorized) { throw [InvalidOperationException]::new('Explicit authorization to run the production start worker is required.') }
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
    $ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
    Assert-StartupDashboardClosed
    $uiAst = Read-SourceAst (Join-Path $ProjectRoot 'TokenRader.ps1')
    $coreAst = Read-SourceAst (Join-Path $ProjectRoot 'TokenRader.Core.psm1')
    $assignment = $uiAst.Find({ param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$script:MeasurementBaselineScript'
    }, $true)
    if ($null -eq $assignment) { throw [InvalidOperationException]::new('Production worker was not found.') }
    $expression = $assignment.Right.Find({ param($n)
        $n -is [Management.Automation.Language.ScriptBlockExpressionAst]
    }, $true)
    if ($null -eq $expression) { throw [InvalidOperationException]::new('Production worker is not a script block.') }
    $workerText = $expression.Extent.Text
    if (-not $workerText.StartsWith('{') -or -not $workerText.EndsWith('}')) {
        throw [InvalidOperationException]::new('Unexpected production worker syntax.')
    }
    $workerText = $workerText.Substring(1, $workerText.Length - 2)
    $safeFailure = $coreAst.Find({ param($n)
        $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Get-TokenRaderSafeIndexFailure'
    }, $true)
    if ($null -eq $safeFailure) { throw [InvalidOperationException]::new('Safe diagnostic classifier was not found.') }

    # Accept only literal stage labels defined by local production source.
    # CurrentPath, paths, IDs and arbitrary source-provided strings are ignored.
    $stageWhitelist = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($stage in @('FastStart','HistoryBackfill','RecentHistoryBackfill')) { [void]$stageWhitelist.Add($stage) }
    foreach ($tree in @($uiAst,$coreAst)) {
        $stageAssignments = $tree.FindAll({ param($n)
            $n -is [Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -match '\.Stage$'
        }, $true)
        foreach ($item in $stageAssignments) {
            foreach ($literal in $item.Right.FindAll({ param($n)
                $n -is [Management.Automation.Language.StringConstantExpressionAst]
            }, $true)) { [void]$stageWhitelist.Add($literal.Value) }
        }
    }

    if ($null -eq ('TokenRaderStartupDiagnostics.CancelBridge' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Threading;
namespace TokenRaderStartupDiagnostics {
    public sealed class CancelBridge : IDisposable {
        private readonly CancellationTokenSource source;
        public CancelBridge(CancellationTokenSource value) {
            source = value;
            Console.CancelKeyPress += OnCancel;
        }
        private void OnCancel(object sender, ConsoleCancelEventArgs args) {
            args.Cancel = true;
            try { source.Cancel(); } catch (ObjectDisposedException) { }
        }
        public void Dispose() { Console.CancelKeyPress -= OnCancel; }
    }
}
'@
    }
    $codexRoot = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $progress = [hashtable]::Synchronized(@{})
    $cts = [Threading.CancellationTokenSource]::new()
    $cancelBridge = [TokenRaderStartupDiagnostics.CancelBridge]::new($cts)
    $workerParameters = @{
        SessionsRoot = Join-Path $codexRoot 'sessions'
        PricingPath = Join-Path $ProjectRoot 'pricing.json'
        ModulePath = Join-Path $ProjectRoot 'TokenRader.Core.psm1'
        AccountIdentity = ''
        CancellationToken = $cts.Token
        ProgressState = $progress
    }
    $wrapper = {
        param([string]$ProductionWorkerSource, [string]$SafeFailureSource, [hashtable]$WorkerParameters,
            [string]$AuthorizedIndexDbPath)
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'
        Invoke-Expression $SafeFailureSource
        $previousIndexDbOverride = [Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB', 'Process')
        try {
            # The worker uses the project's index even if the caller has a test
            # override. Pass the path as data, never interpolate it into code.
            [Environment]::SetEnvironmentVariable('TOKEN_RADER_INDEX_DB', $AuthorizedIndexDbPath, 'Process')
            $baseline = & ([scriptblock]::Create($ProductionWorkerSource)) @WorkerParameters
            if ($null -eq $baseline -or $null -eq $baseline.PSObject.Properties['StartOffsets']) {
                throw [InvalidOperationException]::new('Production worker returned no baseline.')
            }
            [pscustomobject]@{
                Completed = $true
                StartedAt = ([DateTimeOffset]$baseline.StartedAt).ToString('o')
                OffsetFiles = @($baseline.StartOffsets.Keys).Count
            }
        } catch {
            $record = $_
            $safe = Get-TokenRaderSafeIndexFailure -Exception $record.Exception
            $types = New-Object 'System.Collections.Generic.List[string]'
            $cause = $record.Exception
            for ($depth=0; $null -ne $cause -and $depth -lt 16; $depth++) {
                [void]$types.Add($cause.GetType().FullName); $cause = $cause.InnerException
            }
            # Extract only static function labels and line numbers. Do not
            # print raw ErrorRecord, invocation text, exception message or paths.
            $frames = New-Object 'System.Collections.Generic.List[string]'
            foreach ($line in ([string]$record.ScriptStackTrace -split '\r?\n')) {
                if ($line -match '^at (?<function>[A-Za-z0-9_-]+|<ScriptBlock>), .+: line (?<line>[0-9]+)$') {
                    [void]$frames.Add(($matches.function + ': line ' + $matches.line))
                }
            }
            [pscustomobject]@{
                Completed = $false
                ExceptionTypes = ($types -join ' -> ')
                ScriptStack = ($frames -join ' | ')
                SafeSummary = [string]$safe.Message
            }
        } finally {
            [Environment]::SetEnvironmentVariable('TOKEN_RADER_INDEX_DB', $previousIndexDbOverride, 'Process')
        }
    }
    $worker = [PowerShell]::Create()
    [void]$worker.AddScript($wrapper.ToString()).AddParameter('ProductionWorkerSource',$workerText).
        AddParameter('SafeFailureSource',$safeFailure.Extent.Text).AddParameter('WorkerParameters',$workerParameters).
        AddParameter('AuthorizedIndexDbPath',(Join-Path $ProjectRoot 'data/private/index/index.db'))
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-Host 'Starting one production metadata/index preparation. Ctrl+C cancels and waits for worker exit.'
    $async = $worker.BeginInvoke()
    while (-not $async.IsCompleted) {
        if ($cts.IsCancellationRequested -and $null -eq $stopAsync) {
            Write-Host 'Cancellation requested; waiting for actual worker exit.'
            try { $stopAsync = $worker.BeginStop([AsyncCallback]$null,$null) } catch { }
        }
        $stage = [string]$progress['Stage']
        if (-not $stageWhitelist.Contains($stage)) { $stage = 'Preparing (stage unavailable)' }
        $bytes = Get-SafeNumber $progress['HistoryProcessedBytes']
        $remaining = Get-SafeNumber $progress['RemainingFiles']
        $queryMs = Get-SafeNumber $progress['QuotaQueryMilliseconds']
        Write-Host ('Stage={0}; ProcessedBytes={1}; RemainingFiles={2}; ElapsedSeconds={3:F1}; QuotaQueryMilliseconds={4}' -f $stage,$bytes,$remaining,$clock.Elapsed.TotalSeconds,$queryMs)
        [void]$async.AsyncWaitHandle.WaitOne(1000)
    }
    try {
        $output = $worker.EndInvoke($async); $ended = $true
    } catch {
        $ended = $true
        # A host/pipeline stop may prevent the wrapper from returning. Print no
        # raw exception details; classification remains safe and bounded.
        Write-Host ('Completed=False; ExceptionType={0}; SafeSummary=Worker stopped before returning a baseline.' -f $_.Exception.GetType().FullName)
        $output = @()
    }
    foreach ($result in @($output)) {
        if ($null -eq $result -or $null -eq $result.PSObject.Properties['Completed']) { continue }
        if ($result.Completed) {
            $completedSuccessfully = $true
            Write-Host ('Completed=True; StartedAt={0}; OffsetFiles={1}' -f $result.StartedAt,$result.OffsetFiles)
        } else {
            Write-Host ('Completed=False; ExceptionTypes={0}; ScriptStack={1}; SafeSummary={2}' -f $result.ExceptionTypes,$result.ScriptStack,$result.SafeSummary)
        }
    }
} catch {
    # Setup failures must also avoid default error formatting with source text.
    Write-Host ('Completed=False; ExceptionType={0}; SafeSummary=Diagnostic setup or host invocation failed.' -f $_.Exception.GetType().FullName)
} finally {
    if ($null -ne $cts) { try { $cts.Cancel() } catch { } }
    if ($null -ne $worker -and $null -ne $async) {
        if (-not $async.IsCompleted -and $null -eq $stopAsync) {
            try { $stopAsync = $worker.BeginStop([AsyncCallback]$null,$null) } catch { }
        }
        # No timeout is proof of thread exit. Even Ctrl+C cleanup waits until
        # the native query/import really leaves the invocation before disposal.
        while (-not $async.IsCompleted) { [void]$async.AsyncWaitHandle.WaitOne(1000) }
        if ($null -ne $stopAsync) {
            while (-not $stopAsync.IsCompleted) { [void]$stopAsync.AsyncWaitHandle.WaitOne(1000) }
            try { $worker.EndStop($stopAsync) } catch { }
        }
        if (-not $ended) { try { [void]$worker.EndInvoke($async) } catch { } }
    }
    if ($null -ne $worker) { try { $worker.Dispose() } catch { } }
    if ($null -ne $cancelBridge) { try { $cancelBridge.Dispose() } catch { } }
    if ($null -ne $cts) { try { $cts.Dispose() } catch { } }
}
if (-not $completedSuccessfully) { exit 1 }
