[CmdletBinding()]
param([string]$IndexerDll)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'TokenRader.Core.psm1') -Force
$module=Get-Module TokenRader.Core
$prices=Get-TokenRaderPrices -PricingPath (Join-Path $project 'pricing.json')
function Assert([bool]$condition,[string]$why){if(-not$condition){throw ('GPT61 SOL PRICING FAILED: '+$why)}}
function Near([double]$expected,[double]$actual,[string]$why){Assert ([Math]::Abs($expected-$actual)-lt0.000000001) ($why+' expected='+$expected+' actual='+$actual)}
function Usage([long]$InputTokens,[long]$CachedTokens,[long]$OutputTokens){[pscustomobject]@{Input=$InputTokens;Cached=$CachedTokens;Uncached=$InputTokens-$CachedTokens;Output=$OutputTokens;Total=$InputTokens+$OutputTokens;ReasoningOutput=0L}}
$price=Resolve-TokenRaderPrice -Model 'gpt-6.1-sol' -PricingDocument $prices
Assert ($null-ne$price) 'exact new model resolved'
Near 2 $price.input 'standard input';Near 0.10 $price.cachedInput 'standard cache';Near 2.5 $price.cacheWrite 'standard cache write';Near 10 $price.output 'standard output'
Near 0.05 ($price.cachedInput/$price.input) 'cached rate is exactly five percent'
Assert ($price.verifiedAt-eq'2026-10-06') 'new model has its own verification date'
Assert ($prices.verifiedAt-eq'2026-09-24'-and$prices.subscriptionPricing.verifiedAt-eq'2026-09-26') 'new model verification does not claim full-table revalidation'
Assert ($prices.subscriptionPricing.modelVerification.'gpt-6.1-sol'.verifiedAt-eq'2026-10-06') 'new subscription multiplier source dated independently'
Near 2.5 $prices.subscriptionPricing.fastMultipliers.'gpt-6.1-sol' 'included subscription Fast factor'
$usage=Usage 200000 100000 10000
$standard=Get-TokenRaderCost -Usage $usage -Model 'gpt-6.1-sol' -PricingDocument $prices -Scope call -ServiceTier default -CacheCreationTokens 25000 -CacheWriteObservable $true
$fast=Get-TokenRaderCost -Usage $usage -Model 'gpt-6.1-sol' -PricingDocument $prices -Scope call -ServiceTier fast -CacheCreationTokens 25000 -CacheWriteObservable $true
Near 0.3225 $standard.TotalCost 'standard full price with cache write subset'
Near 0.0625 $standard.CacheCreationCost 'standard cache write charged once at 1.25 input'
Near 0.645 $fast.TotalCost 'API Fast uses exact two-times Standard'
Near 0.125 $fast.CacheCreationCost 'API Fast cache write'
$plan=& $module {param($u,$p) Get-TokenRaderPlanNormalizedCost -Usage $u -Model 'gpt-6.1-sol' -PricingDocument $p -ServiceTier priority -LongContextApplied $false} $usage $prices
Assert $plan.Known 'plan reference priced'
Near 0.775 $plan.TotalCost 'subscription reference is ordinary Standard API estimate times 2.5 without write premium'
Near 2.5 $plan.Multiplier 'plan reference multiplier independent of API Fast'
foreach($input in @(271999L,272000L,272001L)){
 $u=Usage $input 20000 1000
 $long=$input-gt272000
 $im=if($long){2.0}else{1.0};$om=if($long){1.5}else{1.0}
 $expected=(($input-30000)*2+10000*2.5+20000*0.1)*$im/1000000+1000*10*$om/1000000
 foreach($tier in @('default','priority')){
  $cost=Get-TokenRaderCost -Usage $u -Model 'gpt-6.1-sol' -PricingDocument $prices -Scope call -ServiceTier $tier -CacheCreationTokens 10000 -CacheWriteObservable $true
  Assert ($cost.Known-and$cost.LongContextApplied-eq$long) ('strict 272K boundary '+$input+'/'+$tier)
  Near ($expected*$(if($tier-eq'priority'){2.0}else{1.0})) $cost.TotalCost ('long context applies to full input/cache/write and output '+$input+'/'+$tier)
 }
}
# Dated log model normalization follows the existing matcher. This synthetic
# suffix does not assert that OpenAI publishes an API snapshot with this ID.
$snapshot='gpt-6.1-sol-2026-10-06'
Assert ((Resolve-TokenRaderPrice -Model $snapshot -PricingDocument $prices).id-eq'gpt-6.1-sol') 'dated log ID resolves to exact base model'
foreach($unknown in @('gpt-6.2-sol','gpt-6.1-solver','gpt-6.1-sol-preview')){
 Assert ($null-eq(Resolve-TokenRaderPrice -Model $unknown -PricingDocument $prices)) ('neighbor model not guessed: '+$unknown)
}
if([string]::IsNullOrWhiteSpace($IndexerDll)){$IndexerDll=Join-Path $project 'indexer\TokenRader.Indexer.dll'}
Add-Type -Path (Join-Path $project 'indexer\System.Data.SQLite.dll')
Add-Type -Path $IndexerDll
$temp=Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-Gpt61Pricing-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;');$db.Open()
$utf8=[Text.UTF8Encoding]::new($false)
try{
 [TokenRaderIndexer]::CreateSchema($db)
 $i=0
 foreach($model in @('gpt-6.1-sol',$snapshot,'gpt-6.2-sol','gpt-6.1-solver','gpt-6.1-sol-preview')){
  foreach($input in @(272000L,272001L)){
   $i++;$id='synthetic-'+$i;$path=Join-Path $temp ($id+'.jsonl')
   $records=@(@{timestamp='2026-10-06T00:00:00Z';type='session_meta';payload=@{id=$id}},@{timestamp='2026-10-06T00:00:00Z';type='turn_context';payload=@{model=$model;service_tier='priority'}},@{timestamp='2026-10-06T00:00:01Z';type='event_msg';payload=@{type='token_count';info=@{total_token_usage=@{input_tokens=$input;cached_input_tokens=20000;output_tokens=1000};last_token_usage=@{input_tokens=$input;cached_input_tokens=20000;output_tokens=1000;cache_creation_input_tokens=10000};model_context_window=1050000}}})
   $lines=@($records|ForEach-Object{$_|ConvertTo-Json -Depth 10 -Compress})
   [IO.File]::WriteAllText($path,($lines-join"`n")+"`n",$utf8)
   [void][TokenRaderIndexer]::ImportFile($db,$path,0)
   $cmd=$db.CreateCommand()
   try{
    $cmd.CommandText='SELECT long_context_threshold,long_context_applied,cache_creation_tokens FROM token_records WHERE source_path=@path';[void]$cmd.Parameters.AddWithValue('@path',$path)
    $reader=$cmd.ExecuteReader();try{
     Assert $reader.Read() 'synthetic token indexed'
     $known=$model-in@('gpt-6.1-sol',$snapshot)
     $threshold=if($reader.IsDBNull(0)){0L}else{[Convert]::ToInt64($reader.GetValue(0))}
     Assert ($threshold-eq$(if($known){272000}else{0})) ('compiled whitelist '+$model)
     Assert ([Convert]::ToInt64($reader.GetValue(1))-eq$(if($known-and$input-gt272000){1}else{0})) ('compiled strict boundary '+$model+'/'+$input)
     Assert ([Convert]::ToInt64($reader.GetValue(2))-eq10000) 'cache write metadata preserved'
    }finally{$reader.Dispose()}
   }finally{$cmd.Dispose()}
  }
 }
 Write-Output 'GPT61_SOL_PRICING_TESTS_PASSED'
}finally{
 $db.Dispose()
 $resolved=[IO.Path]::GetFullPath($temp);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\TokenRader-Gpt61Pricing-'
 if(-not$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe synthetic cleanup target'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
