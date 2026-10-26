[CmdletBinding()]
param([switch]$SkipIndexer)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $projectRoot 'TokenRader.Core.psm1'
$pricingPath = Join-Path $projectRoot 'pricing.json'
$module = Import-Module $corePath -Force -PassThru
$raw = Get-TokenRaderPrices -PricingPath $pricingPath
$subscription = Get-TokenRaderPrices -PricingPath $pricingPath -SubscriptionReference
$modelId = 'gpt-6.1-terra'

function Assert-Terra([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('GPT61 TERRA PRICING FAILED: ' + $Message) }
}
function Assert-TerraNear([double]$Expected, [double]$Actual, [string]$Message) {
    Assert-Terra ([Math]::Abs($Expected - $Actual) -lt 0.000000001) ($Message + '; expected=' + $Expected + ' actual=' + $Actual)
}
function New-TerraUsage([long]$InputTokens, [long]$CachedTokens, [long]$OutputTokens) {
    [pscustomobject]@{
        Input=$InputTokens; Cached=$CachedTokens; Uncached=$InputTokens-$CachedTokens
        Output=$OutputTokens; Total=$InputTokens+$OutputTokens; ReasoningOutput=0L
    }
}
function New-TerraTokenRecord([string]$Timestamp, [long]$TotalInput, [long]$TotalCached, [long]$TotalOutput,
    [long]$CallInput, [long]$CallCached, [long]$CallOutput) {
    [ordered]@{
        timestamp=$Timestamp; type='event_msg'; payload=[ordered]@{
            type='token_count'; info=[ordered]@{
                total_token_usage=[ordered]@{ input_tokens=$TotalInput; cached_input_tokens=$TotalCached; output_tokens=$TotalOutput; reasoning_output_tokens=0; total_tokens=$TotalInput+$TotalOutput }
                last_token_usage=[ordered]@{ input_tokens=$CallInput; cached_input_tokens=$CallCached; output_tokens=$CallOutput; reasoning_output_tokens=0; total_tokens=$CallInput+$CallOutput; cache_creation_input_tokens=10000 }
                model_context_window=1050000
            }
        }
    }
}
function Write-TerraSession([string]$Path, [string]$SessionId, [string]$ProjectPath, [object[]]$TokenRecords,
    [string]$Model='gpt-6.1-terra', [string]$ParentId='') {
    $meta=[ordered]@{ timestamp='2026-10-26T11:59:59Z'; type='session_meta'; payload=[ordered]@{id=$SessionId; cwd=$ProjectPath; model_provider='openai'} }
    if (-not [string]::IsNullOrWhiteSpace($ParentId)) {
        $meta.payload['parent_thread_id']=$ParentId
        $meta.payload['forked_from_id']=$ParentId
    }
    $records=@($meta, [ordered]@{ timestamp='2026-10-26T12:00:00Z'; type='turn_context'; payload=[ordered]@{model=$Model; service_tier='priority'} }) + @($TokenRecords)
    $lines=@($records | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 14 -Compress })
    [IO.File]::WriteAllLines($Path, [string[]]$lines, [Text.UTF8Encoding]::new($false))
}
function Get-TerraCacheKey($Document) {
    & $module { param($p) Get-TokenRaderPricingCacheKey -PricingDocument $p } $Document
}

$apiPrice=Resolve-TokenRaderPrice -Model $modelId -PricingDocument $raw
$refPrice=Resolve-TokenRaderPrice -Model $modelId -PricingDocument $subscription
Assert-Terra ($null -ne $apiPrice -and $null -ne $refPrice) 'exact model is known in both pricing bases'
Assert-Terra (@($apiPrice.aliases).Count -eq 0) 'no fictional aliases were added'
Assert-Terra ($apiPrice.source -eq 'https://developers.openai.com/api/docs/models/gpt-6.1-terra') 'exact official model source is retained'
Assert-Terra ($apiPrice.verifiedAt -eq '2026-10-27') 'model verification is separately dated'
Assert-Terra ($raw.verifiedAt -eq '2026-09-24') 'new model does not claim a full historical API-table revalidation'
Assert-Terra ($subscription.subscriptionPricing.modelVerification.'gpt-6.1-terra'.verifiedAt -eq '2026-10-27') 'subscription rule verification is dated'
Assert-Terra ([long]$apiPrice.contextWindow -eq 1050000 -and [long]$refPrice.longContextThreshold -eq 272000) 'context metadata is explicit'
Assert-Terra ($refPrice.longContextPolicy -eq 'user_confirmed_api_style_reference') 'long-context reference is a user assumption, not an official subscription rule'
foreach ($price in @($apiPrice,$refPrice)) {
    Assert-TerraNear 1 $price.input 'ordinary input per million'
    Assert-TerraNear 0.05 $price.cachedInput 'ordinary cached input per million'
    Assert-TerraNear 5 $price.output 'ordinary output per million'
}
Assert-TerraNear 1.25 $apiPrice.cacheWrite 'legacy API cache-write compatibility premium'
Assert-TerraNear 1 $refPrice.cacheWrite 'subscription cache-write subset uses ordinary input'
Assert-TerraNear 2 $apiPrice.serviceTiers.priority.input 'API Fast remains two times ordinary'
Assert-TerraNear 2.5 $refPrice.serviceTiers.priority.referenceModeMultiplier 'subscription Fast is independently 2.5x'
Assert-Terra ($null -eq $refPrice.serviceTiers.PSObject.Properties['ultrafast']) 'no unconfirmed Ultrafast tier is offered'
Assert-Terra ($null -eq $subscription.subscriptionPricing.ultrafastMultipliers.PSObject.Properties[$modelId]) 'no inherited Ultrafast multiplier'
$current=@(Get-TokenRaderCurrentPricingModels -PricingDocument $subscription -ReferenceDate ([datetime]'2026-10-27'))
Assert-Terra (@($current | Where-Object { $_.id -eq $modelId }).Count -eq 1) 'current model selector includes Terra exactly once'

# A dated synthetic log ID exercises normalization without asserting publication
# of a corresponding official API snapshot.
$datedModel='gpt-6.1-terra-2026-10-27'
foreach ($document in @($raw,$subscription)) {
    Assert-Terra ((Resolve-TokenRaderPrice -Model $datedModel -PricingDocument $document).id -eq $modelId) 'dated suffix resolves only to the exact base model'
    foreach ($unknown in @('gpt-6.1','gpt-6.2-terra','gpt-6.1-terrain','gpt-6.1-terra-preview','gpt-daybreak-terra-latest')) {
        Assert-Terra ($null -eq (Resolve-TokenRaderPrice -Model $unknown -PricingDocument $document)) ('unknown neighboring ID is not guessed: ' + $unknown)
    }
}

$expectedIndexed=0.0
foreach ($inputTokens in @(271999L,272000L,272001L)) {
    $usage=New-TerraUsage $inputTokens 20000 1000
    $isLong=$inputTokens -gt 272000
    $im=if($isLong){2.0}else{1.0}; $om=if($isLong){1.5}else{1.0}
    $ordinary=(($inputTokens-20000)*$im + 20000*0.05*$im + 1000*5*$om)/1000000.0
    $apiOrdinary=(($inputTokens-30000)*$im + 10000*1.25*$im + 20000*0.05*$im + 1000*5*$om)/1000000.0
    foreach ($tier in @('default','priority','fast')) {
        $factor=if($tier -eq 'default'){1.0}else{2.5}
        $apiFactor=if($tier -eq 'default'){1.0}else{2.0}
        $cost=Get-TokenRaderCost -Usage $usage -Model $modelId -PricingDocument $subscription -Scope call -ServiceTier $tier -CacheCreationTokens 10000 -CacheWriteObservable $true
        Assert-Terra ($cost.Known -and $cost.LongContextApplied -eq $isLong) ('strict threshold: '+$inputTokens+'/'+$tier)
        Assert-TerraNear ($ordinary*$factor) $cost.TotalCost ('subscription factors apply once: '+$inputTokens+'/'+$tier)
        Assert-TerraNear (10000*$im*$factor/1000000.0) $cost.CacheCreationCost 'cache-write metadata is an ordinary-input subset'
        $apiCost=Get-TokenRaderCost -Usage $usage -Model $modelId -PricingDocument $raw -Scope call -ServiceTier $tier -CacheCreationTokens 10000 -CacheWriteObservable $true
        Assert-TerraNear ($apiOrdinary*$apiFactor) $apiCost.TotalCost ('legacy API factors remain independent: '+$inputTokens+'/'+$tier)
        $plan=Get-TokenRaderPlanNormalizedCost -Usage $usage -Model $modelId -PricingDocument $subscription -ServiceTier $tier -LongContextApplied $isLong
        Assert-TerraNear $cost.TotalCost $plan.TotalCost 'plan reference does not repeat mode or context factors'
    }
    $expectedIndexed += $ordinary*2.5
}
$unsupported=Get-TokenRaderCost -Usage (New-TerraUsage 10000 0 100) -Model $modelId -PricingDocument $subscription -Scope call -ServiceTier ultrafast
Assert-Terra (-not $unsupported.Known) 'unsupported Ultrafast is unknown, not free or silently downgraded'
$reasoningOnly=Get-TokenRaderCost -Usage (New-TerraUsage 10000 0 100) -Model $modelId -PricingDocument $subscription -Scope call -ServiceTier ultra
Assert-Terra (-not $reasoningOnly.Known) 'reasoning ultra is not a supported speed tier'

# Cache identities must change even when a copied old document retains the
# current rule-version string. Adding this known model alone invalidates money.
foreach ($document in @($raw,$subscription)) {
    $withoutTerra=ConvertFrom-Json (ConvertTo-Json $document -Depth 40 -Compress)
    $withoutTerra.models=@($withoutTerra.models | Where-Object { $_.id -ne $modelId })
    Assert-Terra ((Get-TerraCacheKey $document) -ne (Get-TerraCacheKey $withoutTerra)) 'new model invalidates prior amount caches'
}
Assert-Terra ((Get-TerraCacheKey $raw) -ne (Get-TerraCacheKey $subscription)) 'API and subscription caches stay isolated'

# Exercise production table generation with inert controls, not a live GUI.
$tokens=$null; $parseErrors=$null
$mainAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'TokenRader.ps1'),[ref]$tokens,[ref]$parseErrors)
Assert-Terra (@($parseErrors).Count -eq 0) 'dashboard source parses'
foreach($name in @('Get-ServiceTierLabel','Set-PricingTable')) {
    $function=$mainAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    Assert-Terra ($null -ne $function) ('production function exists: '+$name)
    Invoke-Expression $function.Extent.Text
}
$script:PricingDocument=$subscription; $script:Prices=$subscription; $script:PricingPath=$pricingPath
$script:PricingDataGrid=[pscustomobject]@{ItemsSource=$null}; $script:PricingVerifiedText=[pscustomobject]@{Text=''}
Set-PricingTable
$displayRows=@($script:PricingDataGrid.ItemsSource | Where-Object { ([string]$_.Model).StartsWith('GPT-6.1 Terra ',[StringComparison]::Ordinal) })
Assert-Terra ($displayRows.Count -eq 4) 'table offers only Standard/Fast times two context rows'
foreach ($row in $displayRows) {
    $long=([string]$row.Context).StartsWith('>')
    $fast=([string]$row.Model).EndsWith((Get-ServiceTierLabel 'priority'),[StringComparison]::Ordinal)
    $mode=if($fast){2.5}else{1.0}; $im=if($long){2.0}else{1.0}; $om=if($long){1.5}else{1.0}
    foreach ($field in @('Input','Cached','CacheWrite','Output')) {
        $expected=switch($field){'Input'{$mode*$im};'Cached'{0.05*$mode*$im};'CacheWrite'{$mode*$im};'Output'{5*$mode*$om}}
        $display=[double]::Parse(([string]$row.$field).Substring(1),[Globalization.CultureInfo]::InvariantCulture)
        Assert-TerraNear $expected $display ('display matches actual reference calculation: '+$field+'/'+$row.Model+'/'+$row.Context)
    }
}
if ($SkipIndexer) { Write-Output 'GPT61_TERRA_PRICING_DIRECT_TESTS_PASSED'; return }

# All sources, indexes, project paths and Explorer caches below are synthetic.
if (-not (Initialize-TokenRaderIndexer)) { throw 'Build the updated indexer before running the indexed Terra tests.' }
$previousDb=$env:TOKEN_RADER_INDEX_DB
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-Gpt61Terra-'+[Guid]::NewGuid().ToString('N'))
$sessionsRoot=Join-Path $tempRoot 'sessions'; $projectPath=Join-Path $tempRoot 'Synthetic Terra Project'
$dbPath=Join-Path $tempRoot 'data\private\index.db'
$parentId='61000000-0000-0000-0000-000000000001'; $childId='61000000-0000-0000-0000-000000000002'
$parentPath=Join-Path $sessionsRoot ('rollout-'+$parentId+'.jsonl'); $childPath=Join-Path $sessionsRoot ('rollout-'+$childId+'.jsonl')
$anchor=[DateTimeOffset]::Parse('2026-10-27T00:00:00Z')
try {
    [void][IO.Directory]::CreateDirectory($sessionsRoot); [void][IO.Directory]::CreateDirectory($projectPath)
    $normalizationDb=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $normalizationDb.Open()
    try {
        [TokenRaderIndexer]::CreateSchema($normalizationDb)
        $fixtureNumber=0
        foreach ($logModel in @($modelId,$datedModel,'gpt-6.2-terra','gpt-6.1-terrain','gpt-6.1-terra-preview')) {
            foreach ($input in @(272000L,272001L)) {
                $fixtureNumber++
                $normalizationPath=Join-Path $tempRoot ('normalization-'+$fixtureNumber+'.jsonl')
                $record=New-TerraTokenRecord '2026-10-26T12:00:01Z' $input 20000 1000 $input 20000 1000
                Write-TerraSession $normalizationPath ('normalization-'+$fixtureNumber) $projectPath @($record) -Model $logModel
                [void][TokenRaderIndexer]::ImportFile($normalizationDb,$normalizationPath,0)
                $check=$normalizationDb.CreateCommand()
                try {
                    $check.CommandText='SELECT long_context_threshold,long_context_applied FROM token_records WHERE source_path=@path'
                    [void]$check.Parameters.AddWithValue('@path',$normalizationPath)
                    $rows=$check.ExecuteReader()
                    try {
                        Assert-Terra $rows.Read() 'normalization fixture indexed'
                        $known=$logModel -in @($modelId,$datedModel)
                        $threshold=if($rows.IsDBNull(0)){0L}else{[long]$rows.GetValue(0)}
                        Assert-Terra ($threshold -eq $(if($known){272000L}else{0L})) ('compiled exact/datable model recognition: '+$logModel)
                        Assert-Terra ([long]$rows.GetValue(1) -eq $(if($known -and $input -gt 272000){1L}else{0L})) ('compiled normalized threshold: '+$logModel+'/'+$input)
                    } finally {$rows.Dispose()}
                } finally {$check.Dispose()}
            }
        }
    } finally {$normalizationDb.Dispose()}
    $first=New-TerraTokenRecord '2026-10-26T12:00:01Z' 271999 20000 1000 271999 20000 1000
    $copy=New-TerraTokenRecord '2026-10-26T12:00:10Z' 271999 20000 1000 271999 20000 1000
    $second=New-TerraTokenRecord '2026-10-26T12:00:20Z' 543999 40000 2000 272000 20000 1000
    $third=New-TerraTokenRecord '2026-10-26T12:00:30Z' 816000 60000 3000 272001 20000 1000
    Write-TerraSession $parentPath $parentId $projectPath @($first)
    Write-TerraSession $childPath $childId $projectPath @($copy,$second,$third) -ParentId $parentId
    Close-TokenRaderIndex
    $env:TOKEN_RADER_INDEX_DB=$dbPath
    New-TokenRaderIndex -SessionsRoot $sessionsRoot -Force | Out-Null
    $connection=(Get-TokenRaderIndex).Connection; $command=$connection.CreateCommand()
    try {
        $command.CommandText='SELECT call_input,long_context_threshold,long_context_applied,cache_creation_tokens FROM token_records WHERE source_path=@path ORDER BY source_offset_end'
        [void]$command.Parameters.AddWithValue('@path',$childPath)
        $reader=$command.ExecuteReader(); $rowIndex=0
        try {
            while($reader.Read()) {
                $input=@(271999L,272000L,272001L)[$rowIndex]
                Assert-Terra ([long]$reader.GetValue(0) -eq $input) 'index preserves per-call request input, not cumulative input'
                Assert-Terra ([long]$reader.GetValue(1) -eq 272000) 'compiled model whitelist recognizes Terra'
                Assert-Terra ([long]$reader.GetValue(2) -eq $(if($input -gt 272000){1}else{0})) 'compiled strict 272K threshold'
                Assert-Terra ([long]$reader.GetValue(3) -eq 10000) 'index preserves cache-write metadata'
                $rowIndex++
            }
        } finally {$reader.Dispose()}
        Assert-Terra ($rowIndex -eq 3) 'all synthetic child records indexed'
    } finally {$command.Dispose()}
    $endOffsets=@{}; $endOffsets[$parentPath]=[long](Get-Item -LiteralPath $parentPath).Length; $endOffsets[$childPath]=[long](Get-Item -LiteralPath $childPath).Length
    $baseline=[pscustomobject]@{StartedAt=[DateTimeOffset]::MinValue; SessionsRoot=$sessionsRoot; StartOffsets=@{}; Files=@(); RateLimits=$null; StartRateLimits=$null}
    $interval=Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $subscription -EndOffsets $endOffsets -EndedAt $anchor -ScanRateLimits:$false
    Assert-Terra ($interval.PricingComplete -and $interval.CountedEvents -eq 3 -and $interval.DuplicateEventsDropped -ge 1) 'interval counts unique parent/child calls'
    Assert-Terra ($interval.Usage.Input -eq 816000 -and $interval.StandardContextEvents -eq 2 -and $interval.LongContextEvents -eq 1) 'aggregate retains original under/at/above threshold classification'
    Assert-TerraNear $expectedIndexed $interval.TotalCost 'interval prices each original call once'
    Assert-TerraNear $expectedIndexed $interval.PlanNormalizedTotalCost 'quota reference matches main amount'
    $project=[pscustomobject]@{FilePaths=@($parentPath,$childPath); ProjectPath=$projectPath; ProjectName='Synthetic Terra Project'}
    $projectResult=Get-TokenRaderProjectResult -Project $project -SessionsRoot $sessionsRoot -PricingDocument $subscription
    Assert-Terra ($projectResult.CountedEvents -eq 3 -and $projectResult.DuplicateEventsDropped -ge 1) 'project retains parent/child deduplication'
    Assert-TerraNear $expectedIndexed $projectResult.TotalCost 'project uses identical per-call reference prices'
    $history=Get-TokenRaderUsageHistoryWindow -SessionsRoot $sessionsRoot -PricingDocument $subscription -AnchorAt $anchor -ForceRefresh
    Assert-Terra ($history.PricingComplete -and $history.CountedEvents -eq 3 -and $history.LongContextEvents -eq 1 -and $history.StandardContextEvents -eq 2) 'history retains deduplicated context counts'
    Assert-TerraNear $expectedIndexed $history.TotalCost 'history amount matches interval'
    Close-TokenRaderIndex
    Get-TokenRaderIndex -SessionsRoot $sessionsRoot | Out-Null
    $reopened=Get-TokenRaderUsageHistoryWindow -SessionsRoot $sessionsRoot -PricingDocument $subscription -AnchorAt $anchor
    Assert-TerraNear $expectedIndexed $reopened.TotalCost 'reopened history cache retains correct model pricing'
    Assert-Terra ($reopened.LongContextEvents -eq 1 -and $reopened.StandardContextEvents -eq 2) 'reopened cache retains original context counts'
    Close-TokenRaderIndex

    Import-Module (Join-Path $projectRoot 'TokenRader.Explorer.psm1') -Force
    $pricingCopy=Join-Path $tempRoot 'pricing.json'; Copy-Item -LiteralPath $pricingPath -Destination $pricingCopy
    $paths=[pscustomobject]@{MainIndexPath=$dbPath; ExplorerIndexPath=(Join-Path $tempRoot 'explorer\index.db'); SessionsRoot=$sessionsRoot; PricingPath=$pricingCopy}
    $backfill=Update-TokenRaderExplorerIndex -ProjectRoot $tempRoot -Paths $paths
    Assert-Terra $backfill.SyncComplete 'Explorer imports isolated synthetic fixture'
    $explorer=Get-TokenRaderExplorerResult -ProjectRoot $tempRoot -Paths $paths -ProjectPath $projectPath -StartAt ([DateTimeOffset]::Parse('2026-10-26T00:00:00Z')) -EndAt $anchor
    Assert-Terra ($explorer.Count -eq 3 -and $explorer.DuplicateEventsDropped -ge 1) 'Explorer deduplicates parent/child calls'
    Assert-TerraNear $expectedIndexed $explorer.TotalCost 'Explorer uses same subscription per-call calculation'
    Write-Output 'GPT61_TERRA_PRICING_TESTS_PASSED'
} finally {
    try { & $module { Close-TokenRaderIndex } } catch {}
    if ($null -eq $previousDb) { Remove-Item Env:\TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue } else {$env:TOKEN_RADER_INDEX_DB=$previousDb}
    $resolved=[IO.Path]::GetFullPath($tempRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]'\',[char]'/')+[IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or -not (Split-Path -Leaf $resolved).StartsWith('TokenRader-Gpt61Terra-',[StringComparison]::Ordinal)) {throw 'Unsafe synthetic cleanup target'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
