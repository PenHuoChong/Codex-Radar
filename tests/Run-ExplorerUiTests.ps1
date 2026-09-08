[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $root 'TokenRader.Core.psm1') -Force
. (Join-Path $root 'TokenRader.Explorer.UI.ps1')
function Assert-ExplorerUi([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
Assert-ExplorerUi ($null -eq $script:Explorer) 'loading definitions started explorer activity'
$now=[DateTimeOffset]::Parse('2026-01-02T15:45:00+08:00')
$range=Get-ExplorerTimeRange '1' '' '' $now
Assert-ExplorerUi (($range.EndAt-$range.StartAt).TotalHours -eq 24) 'recent day is not rolling 24h'
$all=Get-ExplorerTimeRange 'all' '' '' $now
Assert-ExplorerUi ($null -eq $all.StartAt -and $all.EndAt -eq $now) 'all-time has a hidden lookback cap'
$custom=Get-ExplorerTimeRange 'custom' '2026-01-01 10:00:00' '2026-01-02 11:00:00' $now
Assert-ExplorerUi (($custom.EndAt-$custom.StartAt).TotalHours -eq 25) 'custom timestamps lost precision'
$rejected=$false
try { Get-ExplorerTimeRange 'custom' '2026-01-02 10:00:00' '2026-01-01 11:00:00' $now | Out-Null } catch { $rejected=$true }
Assert-ExplorerUi $rejected 'reversed range was accepted'
[xml]$xml=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'ExplorerWindow.xaml')
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xml))
$controls=@{}
foreach ($name in @('Reload','Backfill','Titles','Cancel','Query','Tree','Range','From','To','Selection','Summary','Coverage','Models','Status')) {
    $controls[$name]=$window.FindName($name)
    Assert-ExplorerUi ($null -ne $controls[$name]) ('Missing explorer control '+$name)
}
$script:Explorer=@{Controls=$controls;Catalog=$null;TitleMap=@{'synthetic-session'='Synthetic title'}}
$catalog=[pscustomobject]@{Projects=@([pscustomobject]@{ProjectPath='synthetic://project';ProjectName='Example';Sessions=@([pscustomobject]@{SessionId='synthetic-session';DisplayName='Unnamed'})})}
Set-ExplorerCatalog $catalog
Assert-ExplorerUi ($controls.Tree.Items.Count -eq 1) 'project catalog not rendered'
$project=$controls.Tree.Items[0]
Assert-ExplorerUi (-not $project.Tag.Loaded) 'conversation controls eagerly loaded'
$project.IsExpanded=$true
Assert-ExplorerUi ($project.Tag.Loaded -and $project.Items[0].Header -eq 'Synthetic title') 'lazy expansion or title metadata failed'
$usage=[pscustomobject]@{Input=300;Cached=200;Uncached=100;Output=20;Total=320}
$result=[pscustomobject]@{Usage=$usage;TotalCost=0.125;PricingComplete=$true;CoverageMessage='Synthetic coverage';Items=@([pscustomobject]@{Model='synthetic-model';ServiceTier='default';Usage=$usage;Cost=[pscustomobject]@{TotalCost=0.125}})}
Complete-ExplorerWork $result 'Query'
Assert-ExplorerUi ($controls.Summary.Text.Contains('320') -and $controls.Summary.Text.Contains('0.125')) 'total token/USD not rendered'
Assert-ExplorerUi ($controls.Models.Items.Count -eq 1 -and $controls.Coverage.Text -eq 'Synthetic coverage') 'model detail or coverage lost'
Set-ExplorerBusy $true
Assert-ExplorerUi (-not $controls.Query.IsEnabled -and $controls.Cancel.IsEnabled) 'duplicate query not disabled'
Set-ExplorerBusy $false
Assert-ExplorerUi ($controls.Query.IsEnabled -and -not $controls.Cancel.IsEnabled) 'query controls not restored'
$script:Explorer=$null
$source=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $root 'TokenRader.ps1')
Assert-ExplorerUi ($source.Contains('$script:ExplorerButton.Add_Click({ Show-TokenRaderExplorer })')) 'manual entry missing'
Write-Output 'EXPLORER_UI_TESTS_PASSED'
