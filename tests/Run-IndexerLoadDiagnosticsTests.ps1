[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-LoaderDiagnostic {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('INDEXER LOAD DIAGNOSTIC TEST FAILED: ' + $Message) }
}

$root = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $root 'TokenRader.Core.psm1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($corePath, [ref]$tokens, [ref]$parseErrors)
Assert-LoaderDiagnostic (@($parseErrors).Count -eq 0) 'core module parses before isolated AST extraction'

$wantedFunctions = @(
    'New-TokenRaderIndexerLoadDiagnostic',
    'New-TokenRaderIndexerExceptionDiagnostic',
    'Get-TokenRaderIndexerLoadDiagnostic',
    'Initialize-TokenRaderIndexer',
    'Open-TokenRaderIndex'
)
$functionTexts = @{}
foreach ($functionAst in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $wantedFunctions -contains $node.Name
}, $true)) {
    $functionTexts[$functionAst.Name] = $functionAst.Extent.Text
}
foreach ($name in $wantedFunctions) {
    Assert-LoaderDiagnostic ($functionTexts.ContainsKey($name)) ("AST extraction found {0}" -f $name)
}

# A broader test runner may already have loaded these types. Make the isolated
# copy deterministically exercise its mocked load paths without consulting or
# unloading AppDomain types, and never pass a real DLL to Add-Type.
$initializeText = [string]$functionTexts['Initialize-TokenRaderIndexer']
Assert-LoaderDiagnostic (([regex]::Matches($initializeText, "'TokenRaderIndexer' -as \[type\]")).Count -eq 2) 'indexer loaded checks are present in the extracted function'
Assert-LoaderDiagnostic (([regex]::Matches($initializeText, "'System\.Data\.SQLite\.SQLiteConnection' -as \[type\]")).Count -eq 2) 'SQLite loaded checks are present in the extracted function'
$initializeText = $initializeText.Replace("('TokenRaderIndexer' -as [type])", '($null)')
$initializeText = $initializeText.Replace("('System.Data.SQLite.SQLiteConnection' -as [type])", '($null)')
$functionTexts['Initialize-TokenRaderIndexer'] = $initializeText

$harness = {
    param([hashtable]$Functions)

    $script:TokenRaderIndexerLoadDiagnostic = $null
    $script:TestAvailablePaths = @()
    $script:TestAddTypeCalls = @()
    $script:TestAddTypeException = $null
    $script:TestThrowOnIndexer = $false

    function Get-TokenRaderIndexerPath { return 'synthetic\TokenRader.Indexer.dll' }
    function Join-Path {
        param([string]$Path, [string]$ChildPath)
        return ('synthetic\' + $ChildPath)
    }
    function Test-Path {
        [CmdletBinding()]
        param([string]$LiteralPath)
        return ($script:TestAvailablePaths -contains $LiteralPath)
    }
    function Add-Type {
        [CmdletBinding()]
        param([string]$Path)
        $script:TestAddTypeCalls += $Path
        if ($script:TestThrowOnIndexer -and $Path -like '*TokenRader.Indexer.dll') {
            throw $script:TestAddTypeException
        }
    }

    foreach ($name in @(
        'New-TokenRaderIndexerLoadDiagnostic',
        'New-TokenRaderIndexerExceptionDiagnostic',
        'Get-TokenRaderIndexerLoadDiagnostic',
        'Initialize-TokenRaderIndexer',
        'Open-TokenRaderIndex'
    )) {
        Invoke-Expression ([string]$Functions[$name])
    }

    $indexerPath = 'synthetic\TokenRader.Indexer.dll'
    $sqlitePath = 'synthetic\indexer\System.Data.SQLite.dll'

    # Missing indexer remains a build diagnosis and does not call Add-Type.
    $script:TestAvailablePaths = @($sqlitePath)
    $script:TestAddTypeCalls = @()
    $result = Initialize-TokenRaderIndexer
    $diagnostic = Get-TokenRaderIndexerLoadDiagnostic
    Assert-LoaderDiagnostic ($result -is [bool] -and -not $result) 'Initialize keeps its Boolean failure contract for a missing DLL'
    Assert-LoaderDiagnostic ($diagnostic.Code -eq 'missing-indexer' -and $diagnostic.Message.Contains('Build.ps1')) 'missing indexer gives explicit build guidance'
    Assert-LoaderDiagnostic (@($script:TestAddTypeCalls).Count -eq 0) 'missing-file path never attempts a load'

    # Missing SQLite is separately identified as a dependency issue.
    $script:TestAvailablePaths = @($indexerPath)
    $script:TestAddTypeCalls = @()
    $result = Initialize-TokenRaderIndexer
    $diagnostic = Get-TokenRaderIndexerLoadDiagnostic
    Assert-LoaderDiagnostic (-not $result -and $diagnostic.Code -eq 'missing-dependency') 'missing SQLite dependency is distinguished from a missing indexer'
    $dependencyLabel = -join [char[]]@(0x4F9D, 0x8D56)
    Assert-LoaderDiagnostic ($diagnostic.Message.Contains($dependencyLabel) -and -not $diagnostic.Message.Contains('Build.ps1')) 'dependency diagnosis gives dependency recovery guidance'
    Assert-LoaderDiagnostic (@($script:TestAddTypeCalls).Count -eq 0) 'missing dependency path never attempts a load'

    # Synthetic COMException exercises the known policy HRESULT. Add-Type is a
    # function in this harness and cannot load, inspect, or execute any DLL.
    $script:TestAvailablePaths = @($indexerPath, $sqlitePath)
    $policyHResult = [int]-2147020345
    $script:TestAddTypeException = [System.Runtime.InteropServices.COMException]::new(
        'synthetic-private-path {"text":"private source body"}', $policyHResult)
    $script:TestThrowOnIndexer = $true
    $script:TestAddTypeCalls = @()
    $result = Initialize-TokenRaderIndexer
    $diagnostic = Get-TokenRaderIndexerLoadDiagnostic
    Assert-LoaderDiagnostic (-not $result -and $diagnostic.Code -eq 'windows-app-control-blocked') 'known HRESULT is classified as Windows app-control block'
    Assert-LoaderDiagnostic ($diagnostic.HResult -eq '0x800711C7' -and $diagnostic.ExceptionType -eq 'System.Runtime.InteropServices.COMException') 'policy diagnostic retains HRESULT and exception type'
    $appControlLabel = -join [char[]]@(0x5E94, 0x7528, 0x63A7, 0x5236)
    $notUnblockLabel = -join [char[]]@(0x4E0D, 0x4F1A, 0x89E3, 0x9664)
    Assert-LoaderDiagnostic ($diagnostic.Message.Contains($appControlLabel) -and $diagnostic.Message.Contains($notUnblockLabel)) 'policy message accurately avoids rebuild-as-unblock guidance'
    Assert-LoaderDiagnostic (-not $diagnostic.Message.Contains('synthetic-private') -and -not $diagnostic.Message.Contains('source body')) 'policy message never copies arbitrary exception details'
    Assert-LoaderDiagnostic (@($script:TestAddTypeCalls).Count -eq 2) 'only mocked SQLite and indexer load attempts occurred'

    $openMessage = ''
    try { Open-TokenRaderIndex -SessionsRoot 'synthetic-session-root' | Out-Null }
    catch { $openMessage = [string]$_.Exception.Message }
    Assert-LoaderDiagnostic ($openMessage.Contains($appControlLabel) -and $openMessage.Contains('0x800711C7')) 'Open reports the stored policy diagnosis'
    Assert-LoaderDiagnostic (-not $openMessage.Contains('Build.ps1') -and -not $openMessage.Contains('synthetic-private')) 'Open does not mislabel policy block as a rebuildable missing DLL'

    # Generic failures retain only safe type/code, never the synthetic details.
    $genericException = [InvalidOperationException]::new('synthetic-private-path {"text":"private source body"}')
    $script:TestAddTypeException = $genericException
    $script:TestAddTypeCalls = @()
    $result = Initialize-TokenRaderIndexer
    $diagnostic = Get-TokenRaderIndexerLoadDiagnostic
    $expectedHResult = '0x{0:X8}' -f [int]$genericException.HResult
    Assert-LoaderDiagnostic (-not $result -and $diagnostic.Code -eq 'load-error') 'unknown loader exceptions stay a load error'
    Assert-LoaderDiagnostic ($diagnostic.HResult -eq $expectedHResult -and $diagnostic.ExceptionType -eq 'System.InvalidOperationException') 'generic diagnosis retains safe HRESULT and type'
    Assert-LoaderDiagnostic (-not $diagnostic.Message.Contains('synthetic-private') -and -not $diagnostic.Message.Contains('source body')) 'generic message excludes arbitrary exception details'

    $openMessage = ''
    try { Open-TokenRaderIndex -SessionsRoot 'synthetic-session-root' | Out-Null }
    catch { $openMessage = [string]$_.Exception.Message }
    Assert-LoaderDiagnostic ($openMessage.Contains('System.InvalidOperationException') -and $openMessage.Contains($expectedHResult)) 'Open exposes safe type and code for generic failures'
    Assert-LoaderDiagnostic (-not $openMessage.Contains('synthetic-private')) 'Open never exposes arbitrary error messages or paths'
}

& $harness $functionTexts
Write-Host 'Indexer load diagnostics tests passed.'
