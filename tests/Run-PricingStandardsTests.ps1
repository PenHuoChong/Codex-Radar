[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PricingStandards {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('PRICING STANDARDS TEST FAILED: ' + $Message) }
}

function Assert-PricingStandardsNear {
    param(
        [double]$Expected,
        [double]$Actual,
        [double]$Tolerance = 0.000001,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw ('PRICING STANDARDS TEST FAILED: {0}; expected=[{1}] actual=[{2}]' -f $Message, $Expected, $Actual)
    }
}

function ConvertFrom-PricingDisplayRate {
    param([Parameter(Mandatory = $true)][string]$Value, [Parameter(Mandatory = $true)][string]$Label)
    $text = $Value.Trim()
    if (-not $text.StartsWith('$', [StringComparison]::Ordinal)) {
        throw ('PRICING STANDARDS TEST FAILED: {0} is not a displayed dollar rate: [{1}]' -f $Label, $Value)
    }
    [double]$rate = 0
    $parsed = [double]::TryParse(
        $text.Substring(1),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$rate
    )
    if (-not $parsed -or [double]::IsNaN($rate) -or [double]::IsInfinity($rate)) {
        throw ('PRICING STANDARDS TEST FAILED: {0} is not a finite dollar rate: [{1}]' -f $Label, $Value)
    }
    return $rate
}

function New-PricingStandardsUsage {
    param(
        [long]$InputTokens = 0,
        [long]$CachedTokens = 0,
        [long]$OutputTokens = 0
    )
    [long]$inputValue = [Math]::Max(0L, $InputTokens)
    [long]$cachedValue = [Math]::Min([Math]::Max(0L, $CachedTokens), $inputValue)
    [long]$outputValue = [Math]::Max(0L, $OutputTokens)
    [pscustomobject]@{
        Input = $inputValue
        Cached = $cachedValue
        Uncached = $inputValue - $cachedValue
        Output = $outputValue
        Total = $inputValue + $outputValue
        ReasoningOutput = 0L
    }
}

function Get-PricingStandardsRow {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$ModeLabel,
        [Parameter(Mandatory = $true)][string]$ContextLabel
    )
    $separator = ' ' + [string][char]0x00B7 + ' '
    $modelLabel = $DisplayName + $separator + $ModeLabel
    $matches = @($Rows | Where-Object {
        [string]$_.Model -eq $modelLabel -and [string]$_.Context -eq $ContextLabel
    })
    Assert-PricingStandards ($matches.Count -eq 1) ('expected one display row for ' + $modelLabel + ' / ' + $ContextLabel)
    return $matches[0]
}

function Get-PricingStandardsRateFromCost {
    param(
        [Parameter(Mandatory = $true)]$PriceModel,
        [Parameter(Mandatory = $true)][string]$ServiceTier,
        [Parameter(Mandatory = $true)][ValidateSet('Input', 'Cached', 'Output', 'CacheWrite')][string]$Category,
        [Parameter(Mandatory = $true)][bool]$LongContext,
        [Parameter(Mandatory = $true)]$PricingDocument
    )
    [long]$tokens = if ($LongContext) { 272001L } else { 272000L }
    $usage = switch ($Category) {
        'Input' { New-PricingStandardsUsage -InputTokens $tokens }
        'Cached' { New-PricingStandardsUsage -InputTokens $tokens -CachedTokens $tokens }
        'Output' { New-PricingStandardsUsage -OutputTokens $tokens }
        'CacheWrite' { New-PricingStandardsUsage -InputTokens $tokens }
    }
    $costArgs = @{
        Usage = $usage
        Model = [string]$PriceModel.id
        PricingDocument = $PricingDocument
        Scope = 'call'
        ServiceTier = $ServiceTier
        LongContextApplied = $LongContext
    }
    if ($Category -eq 'CacheWrite') {
        $costArgs.CacheCreationTokens = $tokens
        $costArgs.CacheWriteObservable = $true
    }
    $cost = Get-TokenRaderCost @costArgs
    Assert-PricingStandards ([bool]$cost.Known) ('core price must be known for ' + $PriceModel.id + '/' + $ServiceTier + '/' + $Category)
    $costProperty = switch ($Category) {
        'Input' { 'InputCost' }
        'Cached' { 'CachedCost' }
        'Output' { 'OutputCost' }
        'CacheWrite' { 'InputCost' }
    }
    return ([double]$cost.$costProperty * 1000000.0 / [double]$tokens)
}

function Assert-PricingStandardsRowMatchesCore {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)]$PriceModel,
        [Parameter(Mandatory = $true)][string]$ServiceTier,
        [Parameter(Mandatory = $true)][bool]$LongContext,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [Parameter(Mandatory = $true)][string]$Label
    )
    foreach ($category in @('Input', 'Cached', 'Output', 'CacheWrite')) {
        $displayProperty = if ($category -eq 'CacheWrite') { 'CacheWrite' } else { $category }
        $displayRate = ConvertFrom-PricingDisplayRate -Value ([string]$Row.$displayProperty) -Label ($Label + '/' + $category)
        $costRate = Get-PricingStandardsRateFromCost -PriceModel $PriceModel -ServiceTier $ServiceTier `
            -Category $category -LongContext $LongContext -PricingDocument $PricingDocument
        Assert-PricingStandardsNear $costRate $displayRate 0.000501 ($Label + '/' + $category + ' displayed rate matches Get-TokenRaderCost')
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$coreModulePath = Join-Path $projectRoot 'TokenRader.Core.psm1'
Import-Module $coreModulePath -Force
$script:Prices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json') -SubscriptionReference
$script:PricingDocument = $script:Prices

# Import only the two production functions under test. Parsing the file avoids
# running the dashboard launcher or reading any local logs or private data.
$mainWindowPath = Join-Path $projectRoot 'TokenRader.ps1'
$tokens = $null
$parseErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile($mainWindowPath, [ref]$tokens, [ref]$parseErrors)
Assert-PricingStandards (@($parseErrors).Count -eq 0) 'TokenRader.ps1 parses successfully'
foreach ($functionName in @('Get-ServiceTierLabel', 'Set-PricingTable')) {
    $functionAst = $mainAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Assert-PricingStandards ($null -ne $functionAst) ('production function exists: ' + $functionName)
    Invoke-Expression $functionAst.Extent.Text
}

$script:PricingDataGrid = [pscustomobject]@{ ItemsSource = $null }
$script:PricingVerifiedText = [pscustomobject]@{ Text = '' }
Set-PricingTable
$rows = @($script:PricingDataGrid.ItemsSource)
Assert-PricingStandards ($rows.Count -gt 0) 'subscription price table has display rows'

$contextNormal = ([string][char]0x2264) + '272,000 ' + ([string][char]0x8F93) + ([string][char]0x5165)
$contextLong = '>272,000 ' + ([string][char]0x8F93) + ([string][char]0x5165) +
    ([string][char]0xFF08) + ([string][char]0x957F) + ([string][char]0x4E0A) +
    ([string][char]0x4E0B) + ([string][char]0x6587) + ([string][char]0xFF09)
$separator = ' ' + [string][char]0x00B7 + ' '
$expectedModesById = @{}

foreach ($priceModel in @($script:PricingDocument.models)) {
    $tiers = @()
    if ($null -ne $priceModel.PSObject.Properties['serviceTiers'] -and $null -ne $priceModel.serviceTiers) {
        $tiers = @($priceModel.serviceTiers.PSObject.Properties | ForEach-Object { [string]$_.Name })
    }
    $expectedModeLabels = @((Get-ServiceTierLabel 'default'))
    foreach ($tier in $tiers) { $expectedModeLabels += (Get-ServiceTierLabel $tier) }
    $expectedModesById[[string]$priceModel.id] = @($expectedModeLabels)

    $prefix = [string]$priceModel.displayName + $separator
    $modelRows = @($rows | Where-Object { ([string]$_.Model).StartsWith($prefix, [StringComparison]::Ordinal) })
    Assert-PricingStandards ($modelRows.Count -eq ($expectedModeLabels.Count * 2)) `
        ('each supported mode has both context rows: ' + $priceModel.id)

    $actualModes = @($modelRows | ForEach-Object {
        $label = ([string]$_.Model).Substring($prefix.Length)
        if ($expectedModeLabels -contains $label) { $label } else { '__unsupported__:' + $label }
    } | Sort-Object -Unique)
    $expectedSorted = @($expectedModeLabels | Sort-Object -Unique)
    Assert-PricingStandards (($actualModes -join '|') -eq ($expectedSorted -join '|')) `
        ('only modes present in the subscription serviceTiers are displayed: ' + $priceModel.id)

    foreach ($modeLabel in $expectedModeLabels) {
        $serviceTier = if ($modeLabel -eq (Get-ServiceTierLabel 'default')) { 'default' }
            elseif ($modeLabel -eq (Get-ServiceTierLabel 'priority')) { 'priority' }
            elseif ($modeLabel -eq (Get-ServiceTierLabel 'ultrafast')) { 'ultrafast' }
            else { throw ('Unrecognized displayed mode label: ' + $modeLabel) }
        foreach ($contextLabel in @($contextNormal, $contextLong)) {
            $row = Get-PricingStandardsRow -Rows $rows -DisplayName ([string]$priceModel.displayName) `
                -ModeLabel $modeLabel -ContextLabel $contextLabel
            $longContext = $contextLabel -eq $contextLong
            Assert-PricingStandardsRowMatchesCore -Row $row -PriceModel $priceModel -ServiceTier $serviceTier `
                -LongContext $longContext -PricingDocument $script:PricingDocument `
                -Label ($priceModel.id + '/' + $serviceTier + '/' + $contextLabel)
            $inputRate = ConvertFrom-PricingDisplayRate ([string]$row.Input) ($priceModel.id + '/Input')
            $cacheWriteRate = ConvertFrom-PricingDisplayRate ([string]$row.CacheWrite) ($priceModel.id + '/CacheWrite')
            Assert-PricingStandardsNear $inputRate $cacheWriteRate 0.000001 `
                ('subscription cache-write reference equals input without a premium: ' + $priceModel.id + '/' + $serviceTier)
        }
    }
}

$sol61 = Resolve-TokenRaderPrice -Model 'gpt-6.1-sol' -PricingDocument $script:PricingDocument
Assert-PricingStandards ($null -ne $sol61) 'GPT-6.1 Sol resolves in subscription reference pricing'
$standardLabel = Get-ServiceTierLabel 'default'
$fastLabel = Get-ServiceTierLabel 'priority'
$ultrafastLabel = Get-ServiceTierLabel 'ultrafast'
foreach ($category in @('Input', 'Cached', 'Output', 'CacheWrite')) {
    $standardShort = Get-PricingStandardsRow -Rows $rows -DisplayName ([string]$sol61.displayName) `
        -ModeLabel $standardLabel -ContextLabel $contextNormal
    $standardLong = Get-PricingStandardsRow -Rows $rows -DisplayName ([string]$sol61.displayName) `
        -ModeLabel $standardLabel -ContextLabel $contextLong
    $fastShort = Get-PricingStandardsRow -Rows $rows -DisplayName ([string]$sol61.displayName) `
        -ModeLabel $fastLabel -ContextLabel $contextNormal
    $ultrafastShort = Get-PricingStandardsRow -Rows $rows -DisplayName ([string]$sol61.displayName) `
        -ModeLabel $ultrafastLabel -ContextLabel $contextNormal
    $standardRate = ConvertFrom-PricingDisplayRate ([string]$standardShort.$category) ('gpt-6.1-sol/standard/' + $category)
    $standardLongRate = ConvertFrom-PricingDisplayRate ([string]$standardLong.$category) ('gpt-6.1-sol/long/' + $category)
    $fastRate = ConvertFrom-PricingDisplayRate ([string]$fastShort.$category) ('gpt-6.1-sol/fast/' + $category)
    $ultrafastRate = ConvertFrom-PricingDisplayRate ([string]$ultrafastShort.$category) ('gpt-6.1-sol/ultrafast/' + $category)
    Assert-PricingStandardsNear $standardRate $standardLongRate 0.000001 ('GPT-6.1 Sol Standard is flat across context rows: ' + $category)
    Assert-PricingStandardsNear 2.5 ($fastRate / $standardRate) 0.000001 ('GPT-6.1 Sol Fast factor is applied exactly once: ' + $category)
    Assert-PricingStandardsNear 8.0 ($ultrafastRate / $standardRate) 0.000001 ('GPT-6.1 Sol Ultrafast factor is applied exactly once: ' + $category)
}

# A deliberately odd in-memory tier proves the table reads the projected
# serviceTiers rates instead of rebuilding known factors in UI code.
$syntheticTierModel = Resolve-TokenRaderPrice -Model 'gpt-6.1-sol' -PricingDocument $script:PricingDocument
$syntheticTierModel.serviceTiers.priority.input = 7.125
$syntheticTierModel.serviceTiers.priority.cachedInput = 0.375
$syntheticTierModel.serviceTiers.priority.output = 52.875
$syntheticTierModel.serviceTiers.priority.cacheWrite = 7.125
Set-PricingTable
$mutatedRows = @($script:PricingDataGrid.ItemsSource)
$mutatedFast = Get-PricingStandardsRow -Rows $mutatedRows -DisplayName ([string]$syntheticTierModel.displayName) `
    -ModeLabel $fastLabel -ContextLabel $contextNormal
Assert-PricingStandardsRowMatchesCore -Row $mutatedFast -PriceModel $syntheticTierModel -ServiceTier 'priority' `
    -LongContext $false -PricingDocument $script:PricingDocument -Label 'synthetic projected Fast tier'
Assert-PricingStandardsNear 7.125 (ConvertFrom-PricingDisplayRate ([string]$mutatedFast.Input) 'synthetic Fast input') `
    -Message 'Fast table row follows the projected serviceTiers rate rather than a hardcoded factor'

# Validate the real WPF markup without creating a window. The pricing grid and
# its named verification label must remain together in one pricing card.
[xml]$xaml = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'MainWindow.xaml')
$namespaces = New-Object System.Xml.XmlNamespaceManager($xaml.NameTable)
$namespaces.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
$gridNode = $xaml.SelectSingleNode('//*[@x:Name="PricingDataGrid"]', $namespaces)
Assert-PricingStandards ($null -ne $gridNode) 'named pricing table control exists'
$cardNode = $gridNode.ParentNode
while ($null -ne $cardNode -and $cardNode.LocalName -ne 'Border') { $cardNode = $cardNode.ParentNode }
Assert-PricingStandards ($null -ne $cardNode) 'pricing table is inside a card border'
Assert-PricingStandards ([string]$cardNode.GetAttribute('Style') -eq '{StaticResource CardStyle}') 'pricing table card uses CardStyle'
$cardXml = [string]$cardNode.OuterXml
Assert-PricingStandards ($cardXml.Contains('x:Name="PricingDataGrid"')) 'pricing card contains its named data grid'
Assert-PricingStandards ($cardXml.Contains('x:Name="PricingVerifiedText"')) 'pricing card contains the named verification label'
Assert-PricingStandards ($cardXml.Contains('Binding="{Binding Context}"')) 'pricing card binds the context column'
Assert-PricingStandards ($cardXml.Contains('Binding="{Binding CacheWrite}"')) 'pricing card binds the cache-write column'

Write-Output 'PRICING_STANDARDS_TESTS_PASSED'
