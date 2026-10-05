$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-FailureInfoUi {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('FAILURE INFO UI TEST FAILED: ' + $Message) }
}

function New-FailureInfoFakeControl {
    return [pscustomobject]@{
        IsEnabled = $false
        Content = ''
        Text = ''
        Foreground = $null
        ContextMenu = $null
        ToolTip = $null
    }
}

$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'TokenRader.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
Assert-FailureInfoUi (@($parseErrors).Count -eq 0) 'production UI script must parse'

Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$neededFunctions = @(
    'ConvertTo-TokenRaderCopyableStatusText',
    'Set-TokenRaderLastFailureInfo',
    'Get-TokenRaderCopyableStatusInfo',
    'Copy-TokenRaderStatusAndFailureInfo',
    'Initialize-TokenRaderStatusCopyMenus',
    'Set-TokenRaderUiState',
    'Update-ProjectView'
)
foreach ($functionName in $neededFunctions) {
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $false)
    Assert-FailureInfoUi ($null -ne $functionAst) ('missing production function ' + $functionName)
    Invoke-Expression $functionAst.Extent.Text
}

$script:State = @{
    LastFailureInfo = ''
    UiState = 'Measuring'
    IsMeasuring = $true
    IndexReady = $true
    IndexSyncing = $false
    HistoryBackfillRunning = $false
    BackgroundJobs = @{}
    ToolBackfillRunning = $false
    ToolBackfillCompleted = $false
    UsageHistoryRefreshing = $false
    IntervalBaseline = $null
    ProjectCache = @{}
}
$script:StatusText = New-FailureInfoFakeControl
$script:HistoryBackfillStatusText = New-FailureInfoFakeControl
$script:UsageHistoryStatusText = New-FailureInfoFakeControl
$script:ToolUsageStatusText = New-FailureInfoFakeControl
$script:StartMeasureButton = New-FailureInfoFakeControl
$script:StopMeasureButton = New-FailureInfoFakeControl
$script:ViewIntervalButton = New-FailureInfoFakeControl
$script:MeasurementPricingButton = New-FailureInfoFakeControl
$script:RefreshButton = New-FailureInfoFakeControl
$script:RebuildIndexButton = New-FailureInfoFakeControl
$script:PurgeOldIndexButton = New-FailureInfoFakeControl
$script:BackfillToolUsageButton = New-FailureInfoFakeControl
$script:HistoryRangeComboBox = New-FailureInfoFakeControl
$script:UsageHistoryRangeComboBox = New-FailureInfoFakeControl
$script:SessionListBox = New-FailureInfoFakeControl
$script:ProjectComboBox = New-FailureInfoFakeControl
$script:ScopeComboBox = New-FailureInfoFakeControl
$script:IntervalStatusText = New-FailureInfoFakeControl
function Update-TokenRaderHistoryBackfillButton { }

# A recent-24-hour preparation failure is captured from the exact status text
# shown to the user. A later progress message must not overwrite that memory.
$baselineFailure = "Baseline preparation failed: synthetic oversized-record cause`r`nsynthetic inner exception detail"
Set-TokenRaderUiState -NewState 'Error' -StatusMessage $baselineFailure
Assert-FailureInfoUi ($script:State.LastFailureInfo -eq $baselineFailure) 'error state did not retain the shown failure message'
$script:StatusText.Text = 'preparing: processed 1.2 MB; 4 files remain'
$copiedInfo = Get-TokenRaderCopyableStatusInfo -CurrentStatus $script:StatusText.Text
Assert-FailureInfoUi ($copiedInfo.Contains('synthetic oversized-record cause') -and $copiedInfo.Contains('synthetic inner exception detail')) 'multiline failure cause was not retained for copying'
Assert-FailureInfoUi ($copiedInfo.Contains('preparing:')) 'current progress status was not included'

# Structured JSON session rows and body fields are omitted without discarding
# a preceding root-cause line.
Set-TokenRaderLastFailureInfo -Message ('synthetic row-too-large cause' + "`r`n" + '{"type":"response_item","payload":{"text":"synthetic private body"}}')
$redactedInfo = Get-TokenRaderCopyableStatusInfo -CurrentStatus 'synthetic current status'
Assert-FailureInfoUi ($redactedInfo.Contains('synthetic row-too-large cause')) 'safe error prefix was lost during body filtering'
Assert-FailureInfoUi (-not $redactedInfo.Contains('synthetic private body')) 'structured log body was copied'
Assert-FailureInfoUi ($redactedInfo -match '\[[^\]]+\]') 'structured record omission was not disclosed'

Set-TokenRaderLastFailureInfo -Message ('root cause: row rejected; "text":"synthetic inline private body"')
$inlineRedacted = Get-TokenRaderCopyableStatusInfo -CurrentStatus 'ready'
Assert-FailureInfoUi ($inlineRedacted.Contains('root cause: row rejected')) 'inline redaction removed the preceding cause'
Assert-FailureInfoUi (-not $inlineRedacted.Contains('synthetic inline private body')) 'inline body field was copied'
Assert-FailureInfoUi ($inlineRedacted -match '\[[^\]]+\]') 'inline body omission was not disclosed'

$longDiagnostic = 'Root cause: synthetic detail ' + ('x' * 8300)
Set-TokenRaderLastFailureInfo -Message $longDiagnostic
$truncatedInfo = Get-TokenRaderCopyableStatusInfo -CurrentStatus ''
Assert-FailureInfoUi ($truncatedInfo.Contains('Root cause: synthetic detail')) 'long exception lost its leading cause'
Assert-FailureInfoUi ($truncatedInfo.Length -gt 8192 -and $truncatedInfo.Length -lt 8400) 'long exception truncation was not disclosed'

# Project aggregation keeps the detailed cause in the visible CaveatText while
# retaining the same user-facing reason for a later manual copy.
$script:ProjectComboBox = New-FailureInfoFakeControl
$script:ProjectComboBox | Add-Member -NotePropertyName SelectedItem -NotePropertyValue ([pscustomobject]@{
    ProjectPath = 'synthetic-only'
    ProjectName = 'synthetic project'
    Signature = 'synthetic-signature'
}) -Force
$script:SelectedSessionText = New-FailureInfoFakeControl
$script:UpdatedText = New-FailureInfoFakeControl
$script:ScopeBadgeText = New-FailureInfoFakeControl
$script:FormulaText = New-FailureInfoFakeControl
$script:CaveatText = New-FailureInfoFakeControl
$script:Paths = [pscustomobject]@{ SessionsRoot = 'synthetic-only' }
$script:Prices = $null
function Set-EmptyMetrics { param([string]$Message) }
function Get-TokenRaderProjectResult { throw 'synthetic project aggregation failure' }
$script:State.ProjectCache = @{}
Update-ProjectView
Assert-FailureInfoUi ($script:CaveatText.Text -eq 'synthetic project aggregation failure') 'project renderer did not leave the detailed cause visible'
Assert-FailureInfoUi ($script:State.LastFailureInfo.Contains($script:CaveatText.Text) -and
    $script:State.LastFailureInfo.Contains($script:StatusText.Text)) 'project failure copy text omitted its visible status or cause'

# Re-establish an ordinary recent failure and prove menu setup is passive.
Set-TokenRaderLastFailureInfo -Message 'Baseline preparation failed: synthetic failure remains available'
$script:StatusText.Text = 'preparing: normal progress overwrote visible footer text'
$script:CopyActionCalls = 0
$script:CopiedCurrentStatus = ''
function Copy-TokenRaderStatusAndFailureInfo {
    param([AllowNull()][string]$CurrentStatus)
    $script:CopyActionCalls++
    $script:CopiedCurrentStatus = $CurrentStatus
}
Initialize-TokenRaderStatusCopyMenus
Assert-FailureInfoUi ($script:CopyActionCalls -eq 0) 'menu initialization copied to the clipboard automatically'
$headerPrefix = '$copyItem.Header = ' + [char]39
$headerStart = $source.IndexOf($headerPrefix, [StringComparison]::Ordinal)
Assert-FailureInfoUi ($headerStart -ge 0) 'production menu header was not found'
$headerStart += $headerPrefix.Length
$headerEnd = $source.IndexOf([char]39, $headerStart)
Assert-FailureInfoUi ($headerEnd -gt $headerStart) 'production menu header value was not found'
$expectedMenuHeader = $source.Substring($headerStart, $headerEnd - $headerStart)
foreach ($target in @($script:StatusText, $script:HistoryBackfillStatusText, $script:UsageHistoryStatusText, $script:ToolUsageStatusText)) {
    Assert-FailureInfoUi ($null -ne $target.ContextMenu -and $target.ContextMenu.Items.Count -eq 1) 'a visible status surface has no copy context menu'
    Assert-FailureInfoUi ([string]$target.ContextMenu.Items[0].Header -eq $expectedMenuHeader) 'copy menu label is not discoverable'
}
$script:StatusText.ContextMenu.Items[0].RaiseEvent([System.Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
Assert-FailureInfoUi ($script:CopyActionCalls -eq 1) 'manual context-menu click did not invoke copy'
Assert-FailureInfoUi ($script:CopiedCurrentStatus -eq 'preparing: normal progress overwrote visible footer text') 'manual copy did not use the clicked status surface'
$copiedInfo = Get-TokenRaderCopyableStatusInfo -CurrentStatus $script:CopiedCurrentStatus
Assert-FailureInfoUi ($copiedInfo.Contains('synthetic failure remains available')) 'normal progress overwrote the retained failure'

Write-Output 'Failure information UI synthetic tests passed.'
