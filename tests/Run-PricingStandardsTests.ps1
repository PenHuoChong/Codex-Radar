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
$script:PricingPath = Join-Path $projectRoot 'pricing.json'
$script:Prices = Get-TokenRaderPrices -PricingPath $script:PricingPath -SubscriptionReference
$script:PricingDocument = $script:Prices

# Import only the production functions under test. Parsing the file avoids
# running the dashboard launcher or reading any local logs or private data.
$mainWindowPath = Join-Path $projectRoot 'TokenRader.ps1'
$tokens = $null
$parseErrors = $null
$mainAst = [System.Management.Automation.Language.Parser]::ParseFile($mainWindowPath, [ref]$tokens, [ref]$parseErrors)
Assert-PricingStandards (@($parseErrors).Count -eq 0) 'TokenRader.ps1 parses successfully'
foreach ($functionName in @('Get-ServiceTierLabel', 'Set-PricingTable', 'Set-ResultPricing', 'Show-MeasurementPricingDialog')) {
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
$currentModels = @(Get-TokenRaderCurrentPricingModels -PricingDocument $script:PricingDocument -ReferenceDate ([datetime]::Today))
$currentModelIds = @($currentModels | ForEach-Object { [string]$_.id })
$historicalModels = @($script:PricingDocument.models | Where-Object {
    $null -ne $_.PSObject.Properties['referenceRateBasis'] -and
    [string]$_.referenceRateBasis -eq 'historical_application_reference_unit'
})
foreach ($historicalModel in $historicalModels) {
    Assert-PricingStandards ($currentModelIds -notcontains [string]$historicalModel.id) `
        ('historical subscription reference is not a current display option: ' + [string]$historicalModel.id)
    Assert-PricingStandards (@($rows | Where-Object { ([string]$_.Model).StartsWith(([string]$historicalModel.displayName + ' ' + [string][char]0x00B7 + ' '), [StringComparison]::Ordinal) }).Count -eq 0) `
        ('historical subscription reference is omitted from the displayed standards: ' + [string]$historicalModel.id)
}

# Availability is a presentation filter, not a destructive edit to historical
# reference prices or the raw API pricing document.
$rawPricing = Get-TokenRaderPrices -PricingPath $script:PricingPath
$rawCurrentModels = @(Get-TokenRaderCurrentPricingModels -PricingDocument $rawPricing -ReferenceDate ([datetime]'2026-10-14'))
Assert-PricingStandards (@($rawPricing.models).Count -eq $rawCurrentModels.Count) 'raw API pricing keeps all model options regardless of subscription availability'
$subscriptionOct13 = @(Get-TokenRaderCurrentPricingModels -PricingDocument $script:PricingDocument -ReferenceDate ([datetime]'2026-10-13'))
$subscriptionOct14 = @(Get-TokenRaderCurrentPricingModels -PricingDocument $script:PricingDocument -ReferenceDate ([datetime]'2026-10-14'))
Assert-PricingStandards (@($subscriptionOct13 | Where-Object { [string]$_.id -eq 'gpt-5.5' }).Count -eq 1) 'GPT-5.5 remains a current option through 2026-10-13'
Assert-PricingStandards (@($subscriptionOct14 | Where-Object { [string]$_.id -eq 'gpt-5.5' }).Count -eq 0) 'GPT-5.5 is removed from current options on its 2026-10-14 retirement date'
$withoutAvailability = ConvertFrom-Json (ConvertTo-Json -InputObject $script:PricingDocument -Depth 12 -Compress)
$withoutAvailability.subscriptionPricing.PSObject.Properties.Remove('modelAvailability')
$gracefulModels = @(Get-TokenRaderCurrentPricingModels -PricingDocument $withoutAvailability -ReferenceDate ([datetime]'2026-10-14'))
Assert-PricingStandards (@($gracefulModels | Where-Object { [string]$_.id -eq 'gpt-6.1-sol' }).Count -eq 1) `
    'a missing availability map leaves known current models usable without throwing'
Assert-PricingStandards (@($gracefulModels | Where-Object { [string]$_.id -eq 'gpt-5.4' }).Count -eq 0) `
    'historical reference basis remains excluded when availability metadata is absent'
foreach ($historicalId in @('gpt-5.4', 'gpt-5.3-codex')) {
    $historicalPrice = Resolve-TokenRaderPrice -Model $historicalId -PricingDocument $script:PricingDocument
    $historicalCost = Get-TokenRaderCost -Usage ([pscustomobject]@{Input=100000L;Cached=25000L;Output=10000L;Total=110000L;Uncached=75000L;ReasoningOutput=0L}) `
        -Model $historicalId -PricingDocument $script:PricingDocument -Scope call -ServiceTier default -LongContextApplied $false
    Assert-PricingStandards ($null -ne $historicalPrice -and [string]$historicalPrice.referenceRateBasis -eq 'historical_application_reference_unit') `
        ('historical price remains available for resolution: ' + $historicalId)
    Assert-PricingStandards ([bool]$historicalCost.Known -and [double]$historicalCost.TotalCost -gt 0) `
        ('historical call still computes using retained pricing: ' + $historicalId)
    Assert-PricingStandards ([Int64]$historicalPrice.longContextThreshold -eq 0L -and
        [double]$historicalPrice.longContextInputMultiplier -eq 1.0 -and [double]$historicalPrice.longContextOutputMultiplier -eq 1.0) `
        ('historical pricing stays flat rather than acquiring a new model-availability/context policy: ' + $historicalId)
}

$manualPickerAst = $mainAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-MeasurementPricingDialog'
}, $true)
$manualPickerText = [string]$manualPickerAst.Extent.Text
Assert-PricingStandards ($manualPickerText.Contains('Get-TokenRaderCurrentPricingModels')) `
    'manual pricing picker uses the same current-model presentation filter'
$manualModelLoop = $manualPickerAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        [string]$node.Condition.Extent.Text -match 'Get-TokenRaderCurrentPricingModels'
}, $true)
Assert-PricingStandards ($null -ne $manualModelLoop) 'manual pricing selector iterates only the helper-filtered model set'

$contextNormal = ([string][char]0x2264) + '272,000 ' + ([string][char]0x8F93) + ([string][char]0x5165)
$contextLong = '>272,000 ' + ([string][char]0x8F93) + ([string][char]0x5165) +
    ([string][char]0xFF08) + ([string][char]0x957F) + ([string][char]0x4E0A) +
    ([string][char]0x4E0B) + ([string][char]0x6587) + ([string][char]0xFF09)
$separator = ' ' + [string][char]0x00B7 + ' '
$expectedModesById = @{}

foreach ($priceModel in $currentModels) {
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

# Check the declared model policy separately from table/core equality: a shared
# bug in both display and calculation must not make all models appear flat.
foreach ($modelId in @('gpt-6-astra','gpt-6-sol','gpt-6-luna','gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna','gpt-5.6-cyber','gpt-5.5')) {
    $priceModel = Resolve-TokenRaderPrice -Model $modelId -PricingDocument $script:PricingDocument
    $isFlat = $modelId -eq 'gpt-5.6-sol'
    foreach ($tier in @('default') + @($priceModel.serviceTiers.PSObject.Properties | ForEach-Object { [string]$_.Name })) {
        $modeLabel = Get-ServiceTierLabel $tier
        $shortRow = Get-PricingStandardsRow -Rows $rows -DisplayName ([string]$priceModel.displayName) -ModeLabel $modeLabel -ContextLabel $contextNormal
        $longRow = Get-PricingStandardsRow -Rows $rows -DisplayName ([string]$priceModel.displayName) -ModeLabel $modeLabel -ContextLabel $contextLong
        $standardShortRow = Get-PricingStandardsRow -Rows $rows -DisplayName ([string]$priceModel.displayName) -ModeLabel $standardLabel -ContextLabel $contextNormal
        $standardLongRow = Get-PricingStandardsRow -Rows $rows -DisplayName ([string]$priceModel.displayName) -ModeLabel $standardLabel -ContextLabel $contextLong
        $modeFactor = if ($tier -eq 'default') { 1.0 } else { [double]$priceModel.serviceTiers.$tier.referenceModeMultiplier }
        foreach ($category in @('Input','Cached','Output','CacheWrite')) {
            $contextFactor = if ($isFlat) { 1.0 } elseif ($category -eq 'Output') { 1.5 } else { 2.0 }
            $shortRate = ConvertFrom-PricingDisplayRate ([string]$shortRow.$category) ($modelId + '/' + $tier + '/short/' + $category)
            $longRate = ConvertFrom-PricingDisplayRate ([string]$longRow.$category) ($modelId + '/' + $tier + '/long/' + $category)
            $standardShortRate = ConvertFrom-PricingDisplayRate ([string]$standardShortRow.$category) ($modelId + '/standard/short/' + $category)
            $standardLongRate = ConvertFrom-PricingDisplayRate ([string]$standardLongRow.$category) ($modelId + '/standard/long/' + $category)
            Assert-PricingStandardsNear ($shortRate * $contextFactor) $longRate 0.000501 ($modelId + '/' + $tier + '/' + $category + ' context rule is visible')
            Assert-PricingStandardsNear ($standardShortRate * $modeFactor) $shortRate 0.000501 ($modelId + '/' + $tier + '/' + $category + ' short mode factor appears once')
            Assert-PricingStandardsNear ($standardLongRate * $modeFactor) $longRate 0.000501 ($modelId + '/' + $tier + '/' + $category + ' long mode factor appears once')
        }
    }
}

# Result rate labels must describe the same effective projected context tier
# as the amount, and must not display one misleading price for mixed contexts.
$script:InputPriceText = [pscustomobject]@{ Text='' }
$script:CachedPriceText = [pscustomobject]@{ Text='' }
$script:OutputPriceText = [pscustomobject]@{ Text='' }
$script:OpenPricingButton = [pscustomobject]@{ IsEnabled=$false }
$script:State = [pscustomobject]@{ CurrentPriceUrl='' }
foreach ($modelId in @('gpt-6-astra','gpt-6.1-sol','gpt-5.6-sol')) {
    $priceModel = Resolve-TokenRaderPrice -Model $modelId -PricingDocument $script:PricingDocument
    foreach ($tier in @('default') + @($priceModel.serviceTiers.PSObject.Properties | ForEach-Object { [string]$_.Name })) {
        foreach ($longContext in @($false,$true)) {
            $usage = New-PricingStandardsUsage -InputTokens $(if ($longContext) { 272001L } else { 272000L }) -CachedTokens 100000 -OutputTokens 20000
            $cost = Get-TokenRaderCost -Usage $usage -Model $modelId -PricingDocument $script:PricingDocument -Scope call -ServiceTier $tier -LongContextApplied $longContext
            $result = [pscustomobject]@{
                Models=@($modelId)
                Items=@([pscustomobject]@{ ServiceTier=$tier; LongContext=[bool]$cost.LongContextApplied; Cost=$cost })
            }
            Set-ResultPricing -Result $result
            foreach ($category in @('Input','Cached','Output')) {
                $controlName = $category + 'PriceText'
                $displayControl = Get-Variable -Name $controlName -Scope Script -ValueOnly
                $displayRate = ConvertFrom-PricingDisplayRate ([string]$displayControl.Text) ($modelId + '/result/' + $tier + '/' + $category)
                $expectedRate = Get-PricingStandardsRateFromCost -PriceModel $priceModel -ServiceTier $tier -Category $category `
                    -LongContext $longContext -PricingDocument $script:PricingDocument
                Assert-PricingStandardsNear $expectedRate $displayRate 0.000501 ($modelId + '/result/' + $tier + '/' + $category + ' effective rate matches cost')
            }
            Assert-PricingStandards ([bool]$script:OpenPricingButton.IsEnabled) ($modelId + '/result/' + $tier + ' known single-context rates keep source link enabled')
        }
    }
}
$mixedResult = [pscustomobject]@{
    Models=@('gpt-6-astra')
    Items=@(
        [pscustomobject]@{ ServiceTier='priority'; LongContext=$false; Cost=[pscustomobject]@{ Known=$true } },
        [pscustomobject]@{ ServiceTier='priority'; LongContext=$true; Cost=[pscustomobject]@{ Known=$true } }
    )
}
Set-ResultPricing -Result $mixedResult
$mixedContextLabel = -join (@(0x6DF7,0x5408,0x4E0A,0x4E0B,0x6587) | ForEach-Object { [char]$_ })
Assert-PricingStandards ([string]$script:InputPriceText.Text -eq $mixedContextLabel -and
    [string]$script:CachedPriceText.Text -eq $mixedContextLabel -and [string]$script:OutputPriceText.Text -eq $mixedContextLabel) `
    'mixed contexts show a clear mixed label rather than a misleading single dollar rate'
Assert-PricingStandards (-not [bool]$script:OpenPricingButton.IsEnabled -and [string]$script:State.CurrentPriceUrl -eq '') `
    'mixed-context result does not expose a single-context price source as its rate'

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

# Use nonstandard context factors in memory to ensure long rows use the same
# tier projection as costing, rather than a second hardcoded 2x/1.5x table.
$syntheticContextModel = Resolve-TokenRaderPrice -Model 'gpt-6-astra' -PricingDocument $script:PricingDocument
$syntheticContextModel.serviceTiers.priority.longContextInputMultiplier = 2.125
$syntheticContextModel.serviceTiers.priority.longContextOutputMultiplier = 1.625
Set-PricingTable
$mutatedContextRows = @($script:PricingDataGrid.ItemsSource)
$mutatedLongFast = Get-PricingStandardsRow -Rows $mutatedContextRows -DisplayName ([string]$syntheticContextModel.displayName) `
    -ModeLabel $fastLabel -ContextLabel $contextLong
Assert-PricingStandardsRowMatchesCore -Row $mutatedLongFast -PriceModel $syntheticContextModel -ServiceTier 'priority' `
    -LongContext $true -PricingDocument $script:PricingDocument -Label 'synthetic projected long-context Fast tier'

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
$longContextMultiplierCaveat = -join (@(0x957F,0x4E0A,0x4E0B,0x6587,0xFF1A,0x47,0x50,0x54,0x2D,0x36,0x2E,0x31,0x20,0x53,0x6F,0x6C,0x3001,0x47,0x50,0x54,0x2D,0x35,0x2E,0x36,0x20,0x53,0x6F,0x6C,0x20,0x8BA2,0x9605,0x4E0D,0x9644,0x52A0,0x500D,0x7387,0xFF1B,0x5176,0x4ED6,0x5DF2,0x914D,0x7F6E,0x6A21,0x578B,0x6309,0x7528,0x6237,0x786E,0x8BA4,0x7684,0x20,0x41,0x50,0x49,0x20,0x957F,0x4E0A,0x4E0B,0x6587,0x500D,0x7387,0x4F30,0x7B97,0xFF08,0x975E,0x5B98,0x65B9,0x8BA2,0x9605,0x500D,0x7387,0xFF09) | ForEach-Object { [char]$_ })
Assert-PricingStandards ($cardXml.Contains($longContextMultiplierCaveat)) `
    'pricing caveat names both flat exemptions and identifies the other model context multipliers as user-confirmed estimates, not official subscription multipliers'

Write-Output 'PRICING_STANDARDS_TESTS_PASSED'
