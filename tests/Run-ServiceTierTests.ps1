[CmdletBinding()]
param(
    [string]$IndexerDllPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ServiceTier {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw ('SERVICE TIER TEST FAILED: ' + $Message) }
}

function Assert-ServiceTierEqual {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Expected -ne $Actual) {
        throw ('SERVICE TIER TEST FAILED: {0}. Expected=[{1}] Actual=[{2}]' -f $Message, $Expected, $Actual)
    }
}

function Assert-ServiceTierNear {
    param(
        [double]$Expected,
        [double]$Actual,
        [double]$Tolerance,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw ('SERVICE TIER TEST FAILED: {0}. Expected=[{1}] Actual=[{2}]' -f $Message, $Expected, $Actual)
    }
}

function New-ServiceTierUsage {
    param(
        [Int64]$InputTokens = 1000000,
        [Int64]$CachedTokens = 200000,
        [Int64]$OutputTokens = 100000
    )
    [Int64]$inputTokensValue = [Math]::Max([Int64]0, $InputTokens)
    [Int64]$cachedTokensValue = [Math]::Min([Math]::Max([Int64]0, $CachedTokens), $inputTokensValue)
    [Int64]$outputTokensValue = [Math]::Max([Int64]0, $OutputTokens)
    [pscustomobject]@{
        Input = $inputTokensValue
        Cached = $cachedTokensValue
        Uncached = $inputTokensValue - $cachedTokensValue
        Output = $outputTokensValue
        ReasoningOutput = [Int64]0
        Total = $inputTokensValue + $outputTokensValue
        CacheHitRate = if ($inputTokensValue -gt 0) { ($cachedTokensValue * 100.0) / $inputTokensValue } else { 0.0 }
    }
}

function New-ServiceTierTurnContextLine {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Model,
        [switch]$IncludeServiceTier,
        [AllowNull()][AllowEmptyString()][string]$ServiceTier = $null
    )
    $payload = [ordered]@{ model = $Model }
    if ($IncludeServiceTier) { $payload['service_tier'] = $ServiceTier }
    $record = [ordered]@{
        timestamp = $Timestamp
        type = 'turn_context'
        payload = $payload
    }
    return ($record | ConvertTo-Json -Depth 12 -Compress)
}

function New-ServiceTierTokenLine {
    param(
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][Int64]$TotalInput,
        [Parameter(Mandatory = $true)][Int64]$TotalCached,
        [Parameter(Mandatory = $true)][Int64]$TotalOutput,
        [Parameter(Mandatory = $true)][Int64]$CallInput,
        [Parameter(Mandatory = $true)][Int64]$CallCached,
        [Parameter(Mandatory = $true)][Int64]$CallOutput,
        [switch]$IncludePayloadServiceTier,
        [AllowNull()][AllowEmptyString()][string]$PayloadServiceTier = $null,
        [switch]$IncludeResponseServiceTier,
        [AllowNull()][AllowEmptyString()][string]$ResponseServiceTier = $null,
        [string]$RequestId = '',
        [string]$ResponseId = '',
        [string]$TurnId = '',
        [Int64]$ContextWindow = 1050000
    )
    $total = [ordered]@{
        input_tokens = $TotalInput
        cached_input_tokens = $TotalCached
        output_tokens = $TotalOutput
        reasoning_output_tokens = 0
        total_tokens = $TotalInput + $TotalOutput
    }
    $last = [ordered]@{
        input_tokens = $CallInput
        cached_input_tokens = $CallCached
        output_tokens = $CallOutput
        reasoning_output_tokens = 0
        total_tokens = $CallInput + $CallOutput
    }
    $info = [ordered]@{
        total_token_usage = $total
        last_token_usage = $last
        model_context_window = $ContextWindow
    }
    $payload = [ordered]@{
        type = 'token_count'
        info = $info
    }
    if ($IncludePayloadServiceTier) { $payload['service_tier'] = $PayloadServiceTier }
    if ($IncludeResponseServiceTier) {
        $payload['response'] = [ordered]@{ service_tier = $ResponseServiceTier }
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestId)) { $payload['request_id'] = $RequestId }
    if (-not [string]::IsNullOrWhiteSpace($ResponseId)) { $payload['response_id'] = $ResponseId }
    if (-not [string]::IsNullOrWhiteSpace($TurnId)) { $payload['turn_id'] = $TurnId }
    $record = [ordered]@{
        timestamp = $Timestamp
        type = 'event_msg'
        payload = $payload
    }
    return ($record | ConvertTo-Json -Depth 12 -Compress)
}

function Write-ServiceTierJsonl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $encoding)
}

function Add-ServiceTierJsonl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::AppendAllText($Path, (($Lines -join "`n") + "`n"), $encoding)
}

function Invoke-ServiceTierSql {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Sql
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Sql
        [void]$command.ExecuteNonQuery()
    } finally { $command.Dispose() }
}

function Add-ServiceTierAggregateRow {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][Int64]$TotalInput,
        [Parameter(Mandatory = $true)][Int64]$TotalCached,
        [Parameter(Mandatory = $true)][Int64]$TotalOutput,
        [Parameter(Mandatory = $true)][Int64]$CallInput,
        [Parameter(Mandatory = $true)][Int64]$CallCached,
        [Parameter(Mandatory = $true)][Int64]$CallOutput,
        [Parameter(Mandatory = $true)][string]$Fingerprint,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][Int64]$SourceOffset,
        [Parameter(Mandatory = $true)][string]$RootSessionId,
        [string]$ServiceTier = '',
        [string]$ServiceTierSource = '',
        [Int64]$ModelContextWindow = 1050000,
        [Int64]$LongContextThreshold = 0,
        [bool]$LongContextApplied = $false,
        [string]$LongContextSource = 'no_threshold',
        [string]$TurnId = '',
        [string]$RequestId = '',
        [string]$ResponseId = '',
        [string]$IdentitySource = '',
        [Int64]$CacheCreationTokens = 0,
        [bool]$CacheWriteObservable = $false
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
INSERT INTO token_records
(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,
 call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,
 source_offset_end,root_session_id,index_revision,turn_id,request_id,response_id,
 identity_source,service_tier,service_tier_source,model_context_window,
 long_context_threshold,long_context_applied,long_context_source,
 cache_creation_tokens,cache_write_observable)
VALUES
(@session,@timestamp,@model,@total_input,@total_cached,@total_output,0,
 @call_input,@call_cached,@call_output,0,@fingerprint,@source_path,
 @source_offset,@root_session,1,@turn_id,@request_id,@response_id,
 @identity_source,@service_tier,@service_tier_source,@context_window,
 @long_threshold,@long_applied,@long_source,@cache_creation,@cache_write)
'@
        [void]$command.Parameters.AddWithValue('@session', $SessionId)
        [void]$command.Parameters.AddWithValue('@timestamp', $Timestamp)
        [void]$command.Parameters.AddWithValue('@model', $Model)
        [void]$command.Parameters.AddWithValue('@total_input', $TotalInput)
        [void]$command.Parameters.AddWithValue('@total_cached', $TotalCached)
        [void]$command.Parameters.AddWithValue('@total_output', $TotalOutput)
        [void]$command.Parameters.AddWithValue('@call_input', $CallInput)
        [void]$command.Parameters.AddWithValue('@call_cached', $CallCached)
        [void]$command.Parameters.AddWithValue('@call_output', $CallOutput)
        [void]$command.Parameters.AddWithValue('@fingerprint', $Fingerprint)
        [void]$command.Parameters.AddWithValue('@source_path', $SourcePath)
        [void]$command.Parameters.AddWithValue('@source_offset', $SourceOffset)
        [void]$command.Parameters.AddWithValue('@root_session', $RootSessionId)
        [void]$command.Parameters.AddWithValue('@turn_id', $TurnId)
        [void]$command.Parameters.AddWithValue('@request_id', $RequestId)
        [void]$command.Parameters.AddWithValue('@response_id', $ResponseId)
        [void]$command.Parameters.AddWithValue('@identity_source', $IdentitySource)
        [void]$command.Parameters.AddWithValue('@service_tier', $ServiceTier)
        [void]$command.Parameters.AddWithValue('@service_tier_source', $ServiceTierSource)
        [void]$command.Parameters.AddWithValue('@context_window', $ModelContextWindow)
        [void]$command.Parameters.AddWithValue('@long_threshold', $LongContextThreshold)
        [void]$command.Parameters.AddWithValue('@long_applied', $(if ($LongContextApplied) { 1 } else { 0 }))
        [void]$command.Parameters.AddWithValue('@long_source', $LongContextSource)
        [void]$command.Parameters.AddWithValue('@cache_creation', $CacheCreationTokens)
        [void]$command.Parameters.AddWithValue('@cache_write', $(if ($CacheWriteObservable) { 1 } else { 0 }))
        [void]$command.ExecuteNonQuery()
    } finally { $command.Dispose() }
}

function Add-ServiceTierRelationship {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ParentId,
        [Parameter(Mandatory = $true)][string]$RootId,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
INSERT OR REPLACE INTO file_metadata
(path,length,last_write_ticks,parsed_offset,session_id,cwd,parent_thread_id,
 forked_from_id,content_retained,root_session_id)
VALUES (@path,10,0,10,@session,'',@parent,@parent,1,@root)
'@
        [void]$command.Parameters.AddWithValue('@path', $SourcePath)
        [void]$command.Parameters.AddWithValue('@session', $SessionId)
        [void]$command.Parameters.AddWithValue('@parent', $ParentId)
        [void]$command.Parameters.AddWithValue('@root', $RootId)
        [void]$command.ExecuteNonQuery()
    } finally { $command.Dispose() }
}

function Get-ServiceTierIndexedRows {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $table = New-Object System.Data.DataTable
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
SELECT service_tier,service_tier_source,total_input,total_cached,total_output,
       source_offset_end
FROM token_records WHERE source_path=@path ORDER BY source_offset_end
'@
        [void]$command.Parameters.AddWithValue('@path', $Path)
        $adapter = New-Object System.Data.SQLite.SQLiteDataAdapter($command)
        try { [void]$adapter.Fill($table) } finally { $adapter.Dispose() }
    } finally { $command.Dispose() }
    return ,$table
}

function Get-ServiceTierTable {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Sql
    )
    $table = New-Object System.Data.DataTable
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Sql
        $adapter = New-Object System.Data.SQLite.SQLiteDataAdapter($command)
        try { [void]$adapter.Fill($table) } finally { $adapter.Dispose() }
    } finally { $command.Dispose() }
    return ,$table
}

function Get-ServiceTierAggregateBucket {
    param(
        [Parameter(Mandatory = $true)]$Aggregate,
        [Parameter(Mandatory = $true)][string]$Tier,
        [Parameter(Mandatory = $true)][bool]$LongContext
    )
    return @($Aggregate.Buckets | Where-Object {
        [string]$_.ServiceTier -eq $Tier -and [bool]$_.LongContext -eq $LongContext
    })
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'TokenRader.Core.psm1'
if ($null -eq (Get-Module TokenRader.Core)) {
    Import-Module $modulePath -ErrorAction Stop
}
$coreModule = @(Get-Module TokenRader.Core)[-1]

$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
$indexerDll = if ([string]::IsNullOrWhiteSpace($IndexerDllPath)) {
    Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll'
} else {
    (Resolve-Path -LiteralPath $IndexerDllPath).Path
}
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path $indexerDll }

# Keep a caller's live measurement index and environment override intact. The
# history section temporarily opens a private synthetic index and restores the
# prior module state in finally; direct/in-memory checks never touch this state.
$previousIndex = & $coreModule { $script:TokenRaderIndex }
$previousIndexRoot = if ($null -ne $previousIndex -and $null -ne $previousIndex.PSObject.Properties['SessionsRoot']) {
    [string]$previousIndex.SessionsRoot
} else { '' }
$previousDbOverride = [Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB', 'Process')
$historyIndexTouched = $false

$tempRoot = Join-Path $env:TEMP ('token-rader-service-tier-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$tempRoot = (Get-Item -LiteralPath $tempRoot).FullName

try {
    # A deliberately synthetic pricing document makes every expected dollar
    # value stable even when the official catalog changes independently.
    $tieredPrice = [pscustomobject]@{
        id = 'synthetic-tiered'
        displayName = 'Synthetic tiered model'
        aliases = @('synthetic-tiered-alias')
        input = 10.0
        cachedInput = 1.0
        output = 30.0
        contextWindow = 1050000
        longContextThreshold = 272000
        longContextInputMultiplier = 2.0
        longContextOutputMultiplier = 1.5
        serviceTiers = [pscustomobject]@{
            priority = [pscustomobject]@{
                input = 20.0
                cachedInput = 2.0
                output = 60.0
                cacheWrite = 25.0
            }
        }
    }
    $limitedPrice = [pscustomobject]@{
        id = 'synthetic-limited'
        displayName = 'Synthetic limited-priority model'
        aliases = @()
        input = 5.0
        cachedInput = 0.5
        output = 20.0
        contextWindow = 1050000
        longContextThreshold = 272000
        longContextInputMultiplier = 2.0
        longContextOutputMultiplier = 1.5
        serviceTiers = [pscustomobject]@{
            priority = [pscustomobject]@{
                input = 12.5
                cachedInput = 1.25
                output = 75.0
                maximumInputTokens = 272000
            }
        }
    }
    $pricing = [pscustomobject]@{
        currency = 'USD'
        unitTokens = 1000000
        verifiedAt = 'synthetic-service-tier-v1'
        priceType = 'synthetic'
        models = @($tieredPrice, $limitedPrice)
    }

    $normalUsage = New-ServiceTierUsage -InputTokens 100000 -CachedTokens 20000 -OutputTokens 10000
    $standard = Get-TokenRaderCost -Usage $normalUsage -Model 'synthetic-tiered' `
        -PricingDocument $pricing -Scope call
    Assert-ServiceTier ([bool]$standard.Known) 'missing tier remains priced with the Standard reference'
    Assert-ServiceTierEqual '' ([string]$standard.ServiceTier) 'missing tier normalizes to unknown/empty'
    Assert-ServiceTier (-not [bool]$standard.ServiceTierKnown) 'missing tier is not reported as observed'
    Assert-ServiceTierEqual 'standard_fallback' ([string]$standard.ServiceTierSource) 'missing tier source is Standard fallback'
    Assert-ServiceTierNear 1.12 ([double]$standard.TotalCost) 0.0000000001 'default Standard cost'

    $auto = Get-TokenRaderCost -Usage $normalUsage -Model 'synthetic-tiered' `
        -PricingDocument $pricing -Scope call -ServiceTier 'auto'
    Assert-ServiceTierEqual '' ([string]$auto.ServiceTier) 'Auto does not invent a tier'
    Assert-ServiceTierEqual 'standard_fallback' ([string]$auto.ServiceTierSource) 'Auto uses Standard fallback pricing'
    Assert-ServiceTierNear ([double]$standard.TotalCost) ([double]$auto.TotalCost) 0.0000000001 'Auto equals Standard cost'
    $unknownWireTier = Get-TokenRaderCost -Usage $normalUsage -Model 'synthetic-tiered' `
        -PricingDocument $pricing -Scope call -ServiceTier 'unknown'
    Assert-ServiceTierEqual '' ([string]$unknownWireTier.ServiceTier) 'Unknown wire tier normalizes to empty'
    Assert-ServiceTierEqual 'standard_fallback' ([string]$unknownWireTier.ServiceTierSource) 'Unknown wire tier uses Standard fallback'

    foreach ($wireValue in @('standard', 'normal', 'default')) {
        $defaultTier = Get-TokenRaderCost -Usage $normalUsage -Model 'synthetic-tiered' `
            -PricingDocument $pricing -Scope call -ServiceTier $wireValue
        Assert-ServiceTierEqual 'default' ([string]$defaultTier.ServiceTier) ($wireValue + ' normalizes to default')
        Assert-ServiceTier ([bool]$defaultTier.ServiceTierKnown) ($wireValue + ' is an observed tier')
        Assert-ServiceTierEqual 'log' ([string]$defaultTier.ServiceTierSource) ($wireValue + ' tier source is log')
        Assert-ServiceTierNear 1.12 ([double]$defaultTier.TotalCost) 0.0000000001 ($wireValue + ' cost')
    }

    $fast = Get-TokenRaderCost -Usage $normalUsage -Model 'synthetic-tiered' `
        -PricingDocument $pricing -Scope call -ServiceTier 'fast'
    $priority = Get-TokenRaderCost -Usage $normalUsage -Model 'synthetic-tiered' `
        -PricingDocument $pricing -Scope call -ServiceTier 'priority'
    Assert-ServiceTierEqual 'priority' ([string]$fast.ServiceTier) 'Fast normalizes to priority'
    Assert-ServiceTier ([bool]$fast.ServiceTierKnown) 'Fast tier is known when a priority price exists'
    Assert-ServiceTierEqual 'log' ([string]$fast.ServiceTierSource) 'Fast tier source is log'
    Assert-ServiceTierNear 2.24 ([double]$fast.TotalCost) 0.0000000001 'Fast cost'
    Assert-ServiceTierNear ([double]$fast.TotalCost) ([double]$priority.TotalCost) 0.0000000001 'Fast and Priority prices are equal'

    $unsupportedTier = Get-TokenRaderCost -Usage $normalUsage -Model 'synthetic-tiered' `
        -PricingDocument $pricing -Scope call -ServiceTier 'ultrafast'
    Assert-ServiceTier (-not [bool]$unsupportedTier.Known) 'an unsupported explicit tier is not silently Standard-priced'
    Assert-ServiceTierEqual 'ultrafast' ([string]$unsupportedTier.ServiceTier) 'unsupported tier is retained for diagnostics'
    Assert-ServiceTierEqual 'unknown_service_tier_price' ([string]$unsupportedTier.PricingReason) 'unsupported tier reason'
    Assert-ServiceTierEqual 'log' ([string]$unsupportedTier.ServiceTierSource) 'unsupported explicit tier is from log'
    $unknownModelTier = Get-TokenRaderCost -Usage $normalUsage -Model 'synthetic-not-in-catalog' `
        -PricingDocument $pricing -Scope call -ServiceTier 'priority'
    Assert-ServiceTier (-not [bool]$unknownModelTier.Known) 'priority for an unknown model is not silently priced'
    Assert-ServiceTierEqual 'unknown_model' ([string]$unknownModelTier.PricingReason) 'unknown model priority reason'

    $limitedShortUsage = New-ServiceTierUsage -InputTokens 200000 -CachedTokens 20000 -OutputTokens 50000
    $unsupportedModelTier = Get-TokenRaderCost -Usage $limitedShortUsage -Model 'synthetic-limited' `
        -PricingDocument $pricing -Scope call -ServiceTier 'priority'
    Assert-ServiceTier ([bool]$unsupportedModelTier.Known) 'a supported priority tier is priced below its context cap'
    $limitedLongUsage = New-ServiceTierUsage -InputTokens 300000 -CachedTokens 50000 -OutputTokens 100000
    $unsupportedContext = Get-TokenRaderCost -Usage $limitedLongUsage -Model 'synthetic-limited' `
        -PricingDocument $pricing -Scope call -ServiceTier 'priority'
    Assert-ServiceTier (-not [bool]$unsupportedContext.Known) 'priority long context without a published price is partial/unknown'
    Assert-ServiceTierEqual 'unsupported_service_tier_context' ([string]$unsupportedContext.PricingReason) 'unsupported priority long-context reason'
    Assert-ServiceTierEqual 'priority' ([string]$unsupportedContext.ServiceTier) 'unsupported context retains priority mode'

    # A tier-specific cache-write price is required when the log exposes cache
    # creation tokens. A model whose priority table omits cacheWrite remains
    # partially unsupported, while the synthetic Astra-like table is complete.
    $priorityCacheUsage = New-ServiceTierUsage -InputTokens 100000 -CachedTokens 20000 -OutputTokens 10000
    $knownPriorityCache = Get-TokenRaderCost -Usage $priorityCacheUsage -Model 'synthetic-tiered' `
        -PricingDocument $pricing -Scope call -ServiceTier 'priority' -CacheCreationTokens 100 -CacheWriteObservable $true
    Assert-ServiceTier ([bool]$knownPriorityCache.Known) 'priority cache-write price is complete when cacheWrite is explicit'
    Assert-ServiceTier ([double]$knownPriorityCache.CacheCreationCost -gt 0) 'explicit priority cache-write price is charged'
    $unsupportedPriorityCache = Get-TokenRaderCost -Usage $priorityCacheUsage -Model 'synthetic-limited' `
        -PricingDocument $pricing -Scope call -ServiceTier 'priority' -CacheCreationTokens 100 -CacheWriteObservable $true
    Assert-ServiceTier (-not [bool]$unsupportedPriorityCache.Known) 'priority cache creation without a tier cacheWrite price is partial'
    Assert-ServiceTierEqual 'unsupported_service_tier_cache_write' ([string]$unsupportedPriorityCache.PricingReason) 'unsupported priority cache-write reason'

    # Response metadata wins over the requested turn setting. This is called in
    # the module scope because the resolver is intentionally an internal helper.
    $requestedFast = [pscustomobject]@{ service_tier = 'fast' }
    $actualDefault = [pscustomobject]@{ response = [pscustomobject]@{ service_tier = 'standard' } }
    $resolvedResponseTier = & $coreModule {
        param($requested, $response)
        Get-TokenRaderMetadataServiceTier -Containers @($requested, $response) -Fallback 'fast'
    } $requestedFast $actualDefault
    Assert-ServiceTierEqual 'default' ([string]$resolvedResponseTier) 'response tier overrides requested Fast tier'

    $longFast = Get-TokenRaderCost -Usage $limitedLongUsage -Model 'synthetic-tiered' `
        -PricingDocument $pricing -Scope call -ServiceTier 'fast'
    Assert-ServiceTier ([bool]$longFast.Known) 'tiered Fast long-context price is known'
    Assert-ServiceTier ([bool]$longFast.LongContextApplied) 'Fast long-context call crosses the synthetic threshold'
    Assert-ServiceTierNear 2.0 ([double]$longFast.InputMultiplier) 0.0000000001 'Fast long-context input multiplier'
    Assert-ServiceTierNear 1.5 ([double]$longFast.OutputMultiplier) 0.0000000001 'Fast long-context output multiplier'
    Assert-ServiceTierNear 19.2 ([double]$longFast.TotalCost) 0.0000000001 'Fast and long-context multipliers apply once'
    Assert-ServiceTierNear 300000 ([double]$limitedLongUsage.Input) 0.0000001 'long-context pricing does not mutate input tokens'
    Assert-ServiceTierNear 50000 ([double]$limitedLongUsage.Cached) 0.0000001 'long-context pricing does not double cached tokens'
    Assert-ServiceTierNear 100000 ([double]$limitedLongUsage.Output) 0.0000001 'long-context pricing does not mutate output tokens'

    $pricingKey = & $coreModule { param($document) Get-TokenRaderPricingCacheKey -PricingDocument $document } $pricing
    Assert-ServiceTier ($pricingKey.StartsWith('usage-history-v6|', [StringComparison]::Ordinal)) 'service-tier history cache algorithm version'
    $changedPricing = $pricing | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $changedTierPrice = @($changedPricing.models | Where-Object { [string]$_.id -eq 'synthetic-tiered' })[0]
    $changedTierPrice.serviceTiers.priority.input = 21.0
    $changedPricingKey = & $coreModule { param($document) Get-TokenRaderPricingCacheKey -PricingDocument $document } $changedPricing
    Assert-ServiceTier ($pricingKey -ne $changedPricingKey) 'tier price changes invalidate the usage-history cache key'

    # Direct parser fixture: Fast -> Standard -> explicit null clears context,
    # including the empty/unknown ServiceTier state on the final token.
    $transitionPath = Join-Path $tempRoot 'transition.jsonl'
    $transitionLines = @(
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-30T00:00:00Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier 'fast'),
        (New-ServiceTierTokenLine -Timestamp '2026-08-30T00:00:01Z' -TotalInput 1000000 -TotalCached 200000 -TotalOutput 100000 -CallInput 1000000 -CallCached 200000 -CallOutput 100000),
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-30T00:00:02Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier 'standard'),
        (New-ServiceTierTokenLine -Timestamp '2026-08-30T00:00:03Z' -TotalInput 2000000 -TotalCached 400000 -TotalOutput 200000 -CallInput 1000000 -CallCached 200000 -CallOutput 100000),
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-30T00:00:04Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier $null),
        (New-ServiceTierTokenLine -Timestamp '2026-08-30T00:00:05Z' -TotalInput 3000000 -TotalCached 600000 -TotalOutput 300000 -CallInput 1000000 -CallCached 200000 -CallOutput 100000)
    )
    Write-ServiceTierJsonl -Path $transitionPath -Lines $transitionLines
    $transitionScan = & $coreModule {
        param($path)
        Get-TokenRaderUsageEvents -FilePath $path
    } $transitionPath
    $transitionEvents = @($transitionScan.Events)
    Assert-ServiceTierEqual 3 $transitionEvents.Count 'three synthetic mode-transition token events'
    Assert-ServiceTierEqual 'priority' ([string]$transitionEvents[0].ServiceTier) 'Fast event parser tier'
    Assert-ServiceTierEqual 'default' ([string]$transitionEvents[1].ServiceTier) 'Standard event parser tier'
    Assert-ServiceTierEqual '' ([string]$transitionEvents[2].ServiceTier) 'null context resets event parser tier'

    # Snapshot has two intentionally different views: ServiceTier belongs to
    # the latest token, while ContextServiceTier belongs to the newest request
    # context. Appending an unannotated token inherits the trailing Fast context.
    $snapshotPath = Join-Path $tempRoot 'snapshot-mode-switch.jsonl'
    $snapshotLines = @(
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-30T01:00:00Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier 'fast'),
        (New-ServiceTierTokenLine -Timestamp '2026-08-30T01:00:01Z' -TotalInput 1000000 -TotalCached 200000 -TotalOutput 100000 -CallInput 1000000 -CallCached 200000 -CallOutput 100000),
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-30T01:00:02Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier 'standard'),
        (New-ServiceTierTokenLine -Timestamp '2026-08-30T01:00:03Z' -TotalInput 2000000 -TotalCached 400000 -TotalOutput 200000 -CallInput 1000000 -CallCached 200000 -CallOutput 100000),
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-30T01:00:04Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier 'fast')
    )
    Write-ServiceTierJsonl -Path $snapshotPath -Lines $snapshotLines
    $snapshotBeforeAppend = Get-TokenRaderUsageSnapshot -FilePath $snapshotPath
    Assert-ServiceTierEqual 'default' ([string]$snapshotBeforeAppend.ServiceTier) 'snapshot latest token tier remains Standard'
    Assert-ServiceTierEqual 'priority' ([string]$snapshotBeforeAppend.ContextServiceTier) 'snapshot context tier reports trailing Fast request'
    Add-ServiceTierJsonl -Path $snapshotPath -Lines @(
        (New-ServiceTierTokenLine -Timestamp '2026-08-30T01:00:05Z' -TotalInput 3000000 -TotalCached 600000 -TotalOutput 300000 -CallInput 1000000 -CallCached 200000 -CallOutput 100000)
    )
    $snapshotAfterAppend = Get-TokenRaderUsageSnapshot -FilePath $snapshotPath
    Assert-ServiceTierEqual 'priority' ([string]$snapshotAfterAppend.ServiceTier) 'new token without tier inherits trailing Fast context'
    Assert-ServiceTierEqual 'priority' ([string]$snapshotAfterAppend.ContextServiceTier) 'appended snapshot retains latest Fast context'

    $responseOverridePath = Join-Path $tempRoot 'response-override.jsonl'
    Write-ServiceTierJsonl -Path $responseOverridePath -Lines @(
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-30T02:00:00Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier 'fast'),
        (New-ServiceTierTokenLine -Timestamp '2026-08-30T02:00:01Z' -TotalInput 1000000 -TotalCached 200000 -TotalOutput 100000 -CallInput 1000000 -CallCached 200000 -CallOutput 100000 -IncludePayloadServiceTier -PayloadServiceTier 'fast' -IncludeResponseServiceTier -ResponseServiceTier 'standard')
    )
    $responseScan = & $coreModule {
        param($path)
        Get-TokenRaderUsageEvents -FilePath $path
    } $responseOverridePath
    $responseEvents = @($responseScan.Events)
    Assert-ServiceTierEqual 1 $responseEvents.Count 'response override produced one event'
    Assert-ServiceTierEqual 'default' ([string]$responseEvents[0].ServiceTier) 'actual response tier overrides payload/request Fast tier'
    $responseSnapshot = Get-TokenRaderUsageSnapshot -FilePath $responseOverridePath
    Assert-ServiceTierEqual 'default' ([string]$responseSnapshot.ServiceTier) 'snapshot uses actual response tier'
    Assert-ServiceTierEqual 'priority' ([string]$responseSnapshot.ContextServiceTier) 'snapshot keeps requested context tier separately'

    $oldPath = Join-Path $tempRoot 'old-no-tier.jsonl'
    Write-ServiceTierJsonl -Path $oldPath -Lines @(
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-30T03:00:00Z' -Model 'synthetic-tiered'),
        (New-ServiceTierTokenLine -Timestamp '2026-08-30T03:00:01Z' -TotalInput 1000000 -TotalCached 200000 -TotalOutput 100000 -CallInput 1000000 -CallCached 200000 -CallOutput 100000)
    )
    $oldSnapshot = Get-TokenRaderUsageSnapshot -FilePath $oldPath
    Assert-ServiceTierEqual '' ([string]$oldSnapshot.ServiceTier) 'old token logs without tier remain compatible'
    Assert-ServiceTier (-not [bool]$oldSnapshot.ServiceTierKnown) 'old token logs do not claim an observed tier'
    Assert-ServiceTierEqual '' ([string]$oldSnapshot.ContextServiceTier) 'old context without tier remains unknown'

    # The compact aggregate path must canonicalize the parent model/tier when
    # a copied child is enumerated first, retain independent siblings, and keep
    # long-context pricing in a separate model/tier bucket.
    $aggregateDb = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;New=True;'
    $aggregateDb.Open()
    try {
        [TokenRaderIndexer]::CreateSchema($aggregateDb)
        $parentPath = 'synthetic://tier-parent'
        $childPath = 'synthetic://tier-child'
        $siblingFastPath = 'synthetic://tier-sibling-fast'
        $siblingDefaultPath = 'synthetic://tier-sibling-default'
        $longPath = 'synthetic://tier-long-fast'
        Add-ServiceTierRelationship -Connection $aggregateDb -SessionId 'tier-parent' -ParentId 'tier-root' -RootId 'tier-root' -SourcePath $parentPath
        Add-ServiceTierRelationship -Connection $aggregateDb -SessionId 'tier-child' -ParentId 'tier-parent' -RootId 'tier-root' -SourcePath $childPath
        Add-ServiceTierRelationship -Connection $aggregateDb -SessionId 'tier-sibling-fast' -ParentId 'tier-root' -RootId 'tier-root' -SourcePath $siblingFastPath
        Add-ServiceTierRelationship -Connection $aggregateDb -SessionId 'tier-sibling-default' -ParentId 'tier-root' -RootId 'tier-root' -SourcePath $siblingDefaultPath
        Add-ServiceTierRelationship -Connection $aggregateDb -SessionId 'tier-long-fast' -ParentId '' -RootId 'tier-long-fast' -SourcePath $longPath

        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-child' -Timestamp '2026-08-30T04:00:02Z' -Model 'synthetic-tiered' `
            -TotalInput 200000 -TotalCached 40000 -TotalOutput 20000 -CallInput 200000 -CallCached 40000 -CallOutput 20000 `
            -Fingerprint 'tier-copy' -SourcePath $childPath -SourceOffset 10 -RootSessionId 'tier-root' -ServiceTier 'default' -ServiceTierSource 'log'
        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-parent' -Timestamp '2026-08-30T04:00:01Z' -Model 'synthetic-tiered' `
            -TotalInput 200000 -TotalCached 40000 -TotalOutput 20000 -CallInput 200000 -CallCached 40000 -CallOutput 20000 `
            -Fingerprint 'tier-copy' -SourcePath $parentPath -SourceOffset 10 -RootSessionId 'tier-root' -ServiceTier 'fast' -ServiceTierSource 'log'
        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-sibling-fast' -Timestamp '2026-08-30T04:00:03Z' -Model 'synthetic-tiered' `
            -TotalInput 200000 -TotalCached 40000 -TotalOutput 20000 -CallInput 200000 -CallCached 40000 -CallOutput 20000 `
            -Fingerprint 'tier-copy' -SourcePath $siblingFastPath -SourceOffset 10 -RootSessionId 'tier-root' -ServiceTier 'priority' -ServiceTierSource 'log'
        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-sibling-default' -Timestamp '2026-08-30T04:00:04Z' -Model 'synthetic-tiered' `
            -TotalInput 200000 -TotalCached 40000 -TotalOutput 20000 -CallInput 200000 -CallCached 40000 -CallOutput 20000 `
            -Fingerprint 'tier-copy' -SourcePath $siblingDefaultPath -SourceOffset 10 -RootSessionId 'tier-root' -ServiceTier 'standard' -ServiceTierSource 'log'
        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-long-fast' -Timestamp '2026-08-30T04:00:05Z' -Model 'synthetic-tiered' `
            -TotalInput 300000 -TotalCached 50000 -TotalOutput 100000 -CallInput 300000 -CallCached 50000 -CallOutput 100000 `
            -Fingerprint 'tier-long' -SourcePath $longPath -SourceOffset 10 -RootSessionId 'tier-long-fast' -ServiceTier 'fast' -ServiceTierSource 'log' `
            -ModelContextWindow 1050000 -LongContextThreshold 272000 -LongContextApplied $true -LongContextSource 'pricing_threshold'

        $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        $thresholds['synthetic-tiered'] = 272000L
        $starts = [ordered]@{
            $childPath = 0L
            $parentPath = 0L
            $siblingFastPath = 0L
            $siblingDefaultPath = 0L
            $longPath = 0L
        }
        $ends = [ordered]@{
            $childPath = 10L
            $parentPath = 10L
            $siblingFastPath = 10L
            $siblingDefaultPath = 10L
            $longPath = 10L
        }
        $aggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
            $aggregateDb, $starts, $ends, [DateTimeOffset]::Parse('2026-08-30T00:00:00Z'),
            $thresholds, [Threading.CancellationToken]::None, $null)
        Assert-ServiceTierEqual 5 ([Int64]$aggregate.RawEvents) 'aggregate raw event count before lineage deduplication'
        Assert-ServiceTierEqual 4 ([Int64]$aggregate.CountedEvents) 'parent/child duplicate removed while siblings remain'
        Assert-ServiceTier ([Int64]$aggregate.DuplicateEventsDropped -ge 1) 'parent/child duplicate was diagnosed'
        Assert-ServiceTierEqual 900000 ([Int64]$aggregate.TotalInput) 'aggregate input tokens do not double-count child copy'
        Assert-ServiceTierEqual 170000 ([Int64]$aggregate.TotalCached) 'aggregate cached tokens do not double-count child copy'
        Assert-ServiceTierEqual 160000 ([Int64]$aggregate.TotalOutput) 'aggregate output tokens do not double-count child copy'

        $priorityStandardBucket = @(Get-ServiceTierAggregateBucket -Aggregate $aggregate -Tier 'priority' -LongContext $false)
        $defaultStandardBucket = @(Get-ServiceTierAggregateBucket -Aggregate $aggregate -Tier 'default' -LongContext $false)
        $priorityLongBucket = @(Get-ServiceTierAggregateBucket -Aggregate $aggregate -Tier 'priority' -LongContext $true)
        Assert-ServiceTierEqual 1 $priorityStandardBucket.Count 'priority standard bucket exists'
        Assert-ServiceTierEqual 1 $defaultStandardBucket.Count 'default standard bucket exists'
        Assert-ServiceTierEqual 1 $priorityLongBucket.Count 'priority long-context bucket exists'
        Assert-ServiceTierEqual 2 ([Int64]$priorityStandardBucket[0].Events) 'canonical Fast parent and Fast sibling share priority standard bucket'
        Assert-ServiceTierEqual 1 ([Int64]$defaultStandardBucket[0].Events) 'default sibling remains a distinct mode bucket'
        Assert-ServiceTierEqual 1 ([Int64]$priorityLongBucket[0].Events) 'long Fast call is counted once'
        Assert-ServiceTierEqual 'log' ([string]$priorityStandardBucket[0].ServiceTierSource) 'priority bucket preserves tier source'
        Assert-ServiceTier ([bool]$priorityStandardBucket[0].ServiceTierObservable) 'priority bucket marks tier as observable'

        $pricedAggregate = & $coreModule {
            param($value, $document)
            ConvertFrom-TokenRaderPricedAggregate -Aggregate $value -PricingDocument $document
        } $aggregate $pricing
        Assert-ServiceTierNear 30.4 ([double]$pricedAggregate.TotalCost) 0.0000000001 'mixed tier/interval aggregate cost'
        Assert-ServiceTierNear 8.1 ([double]$pricedAggregate.LongContextExtraCost) 0.0000000001 'long-context premium applied once'
        Assert-ServiceTierEqual 900000 ([Int64]$pricedAggregate.Usage.Input) 'priced aggregate preserves one input total'
        Assert-ServiceTierEqual 160000 ([Int64]$pricedAggregate.Usage.Output) 'priced aggregate preserves one output total'
        Assert-ServiceTier (@($pricedAggregate.Items | Where-Object { $_.ServiceTier -eq 'priority' -and -not $_.LongContext }).Count -eq 1) 'priced priority standard item has tier metadata'
        Assert-ServiceTier (@($pricedAggregate.Items | Where-Object { $_.ServiceTier -eq 'default' }).Count -eq 1) 'priced default item has tier metadata'

        # A later status refresh can change its context mode while repeating
        # the same cumulative and last usage. It must not re-price or rewrite
        # the original Fast call.
        $statusPath = 'synthetic://tier-status-refresh'
        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-status' -Timestamp '2026-08-30T04:01:00Z' -Model 'synthetic-tiered' `
            -TotalInput 100000 -TotalCached 10000 -TotalOutput 10000 -CallInput 100000 -CallCached 10000 -CallOutput 10000 `
            -Fingerprint 'status-fast' -SourcePath $statusPath -SourceOffset 10 -RootSessionId 'tier-status' -ServiceTier 'fast' -ServiceTierSource 'log'
        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-status' -Timestamp '2026-08-30T04:01:01Z' -Model 'synthetic-tiered' `
            -TotalInput 100000 -TotalCached 10000 -TotalOutput 10000 -CallInput 100000 -CallCached 10000 -CallOutput 10000 `
            -Fingerprint 'status-default-refresh' -SourcePath $statusPath -SourceOffset 20 -RootSessionId 'tier-status' -ServiceTier 'default' -ServiceTierSource 'log'
        $statusAggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
            $aggregateDb, @{}, @{ $statusPath = 20L }, [DateTimeOffset]::Parse('2026-08-30T00:00:00Z'),
            $thresholds, [Threading.CancellationToken]::None, $null)
        Assert-ServiceTierEqual 2 ([Int64]$statusAggregate.RawEvents) 'status refresh raw rows'
        Assert-ServiceTierEqual 1 ([Int64]$statusAggregate.CountedEvents) 'repeated status usage is not billed twice'
        Assert-ServiceTier ([Int64]$statusAggregate.DuplicateEventsDropped -ge 1) 'repeated status usage is diagnosed as duplicate'
        Assert-ServiceTierEqual 'priority' ([string]$statusAggregate.Buckets[0].ServiceTier) 'later status does not rewrite the original call mode'

        # A later token_count carrying the actual response tier is different
        # from a plain status refresh: it enriches the same call in place. The
        # usage and representative timestamp remain singular while response
        # Standard/Default replaces the requested Fast/priority mode.
        $responseEnrichPath = 'synthetic://tier-response-enrich'
        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-response-enrich' -Timestamp '2026-08-30T04:02:00Z' -Model 'synthetic-tiered' `
            -TotalInput 100000 -TotalCached 10000 -TotalOutput 10000 -CallInput 100000 -CallCached 10000 -CallOutput 10000 `
            -Fingerprint 'response-enrich-request' -SourcePath $responseEnrichPath -SourceOffset 10 -RootSessionId 'tier-response-enrich' -ServiceTier 'priority' -ServiceTierSource 'log'
        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-response-enrich' -Timestamp '2026-08-30T04:02:01Z' -Model 'synthetic-tiered' `
            -TotalInput 100000 -TotalCached 10000 -TotalOutput 10000 -CallInput 100000 -CallCached 10000 -CallOutput 10000 `
            -Fingerprint 'response-enrich-actual' -SourcePath $responseEnrichPath -SourceOffset 20 -RootSessionId 'tier-response-enrich' -ServiceTier 'default' -ServiceTierSource 'response'
        Add-ServiceTierAggregateRow -Connection $aggregateDb -SessionId 'tier-response-enrich' -Timestamp '2026-08-30T04:02:02Z' -Model 'synthetic-tiered' `
            -TotalInput 100000 -TotalCached 10000 -TotalOutput 10000 -CallInput 100000 -CallCached 10000 -CallOutput 10000 `
            -Fingerprint 'response-enrich-conflict' -SourcePath $responseEnrichPath -SourceOffset 30 -RootSessionId 'tier-response-enrich' -ServiceTier 'priority' -ServiceTierSource 'response'
        $responseEnrichAggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
            $aggregateDb, @{}, @{ $responseEnrichPath = 30L }, [DateTimeOffset]::Parse('2026-08-30T00:00:00Z'),
            $thresholds, [Threading.CancellationToken]::None, $null)
        Assert-ServiceTierEqual 1 ([Int64]$responseEnrichAggregate.CountedEvents) 'response tier enrichment does not duplicate call tokens'
        Assert-ServiceTierEqual 100000 ([Int64]$responseEnrichAggregate.TotalInput) 'response tier enrichment keeps one input total'
        Assert-ServiceTierEqual 'default' ([string]$responseEnrichAggregate.Buckets[0].ServiceTier) 'first actual response tier wins over an equal-strength conflict'
        Assert-ServiceTier ([Int64]$responseEnrichAggregate.DuplicateEventsDropped -ge 2) 'response enrichment conflicts remain deduplicated'
        Assert-ServiceTierEqual ([DateTimeOffset]::Parse('2026-08-30T04:02:00Z')) $responseEnrichAggregate.FirstCountedAt 'response tier enrichment keeps first call timestamp'
        Assert-ServiceTierEqual ([DateTimeOffset]::Parse('2026-08-30T04:02:00Z')) $responseEnrichAggregate.LastCountedAt 'response tier enrichment does not time-shift the call'
    } finally {
        $aggregateDb.Close()
        $aggregateDb.Dispose()
    }

    # An unsupported long priority bucket must not hide a separately priced
    # standard bucket for the same model.
    $partialDb = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;New=True;'
    $partialDb.Open()
    try {
        [TokenRaderIndexer]::CreateSchema($partialDb)
        $partialShortPath = 'synthetic://limited-short'
        $partialLongPath = 'synthetic://limited-long'
        Add-ServiceTierAggregateRow -Connection $partialDb -SessionId 'limited-short' -Timestamp '2026-08-30T05:00:01Z' -Model 'synthetic-limited' `
            -TotalInput 200000 -TotalCached 20000 -TotalOutput 50000 -CallInput 200000 -CallCached 20000 -CallOutput 50000 `
            -Fingerprint 'limited-short' -SourcePath $partialShortPath -SourceOffset 10 -RootSessionId 'limited-short' -ServiceTier 'priority' -ServiceTierSource 'log' `
            -ModelContextWindow 1050000 -LongContextThreshold 272000 -LongContextApplied $false -LongContextSource 'pricing_threshold'
        Add-ServiceTierAggregateRow -Connection $partialDb -SessionId 'limited-long' -Timestamp '2026-08-30T05:00:02Z' -Model 'synthetic-limited' `
            -TotalInput 300000 -TotalCached 30000 -TotalOutput 50000 -CallInput 300000 -CallCached 30000 -CallOutput 50000 `
            -Fingerprint 'limited-long' -SourcePath $partialLongPath -SourceOffset 10 -RootSessionId 'limited-long' -ServiceTier 'priority' -ServiceTierSource 'log' `
            -ModelContextWindow 1050000 -LongContextThreshold 272000 -LongContextApplied $true -LongContextSource 'pricing_threshold'
        $limitedThresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        $limitedThresholds['synthetic-limited'] = 272000L
        $partialAggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
            $partialDb, @{}, @{ $partialShortPath = 10L; $partialLongPath = 10L },
            [DateTimeOffset]::Parse('2026-08-30T00:00:00Z'), $limitedThresholds,
            [Threading.CancellationToken]::None, $null)
        $partialPriced = & $coreModule {
            param($value, $document)
            ConvertFrom-TokenRaderPricedAggregate -Aggregate $value -PricingDocument $document
        } $partialAggregate $pricing
        Assert-ServiceTier (-not [bool]$partialPriced.PricingComplete) 'unsupported tier context makes aggregate pricing partial'
        $partialKnown = @($partialPriced.Items | Where-Object { $_.LongContext -eq $false })
        $partialUnknown = @($partialPriced.Items | Where-Object { $_.LongContext -eq $true })
        Assert-ServiceTierEqual 1 $partialKnown.Count 'supported standard bucket survives an unsupported long bucket'
        Assert-ServiceTierEqual 1 $partialUnknown.Count 'unsupported long bucket remains visible'
        Assert-ServiceTier ([bool]$partialKnown[0].Cost.Known) 'short priority bucket remains priced'
        Assert-ServiceTier (-not [bool]$partialUnknown[0].Cost.Known) 'long priority bucket is explicitly unknown'
        Assert-ServiceTierEqual 'unsupported_service_tier_context' ([string]$partialUnknown[0].Cost.PricingReason) 'partial unsupported reason survives aggregate pricing'
        Assert-ServiceTierNear 6.025 ([double]$partialPriced.TotalCost) 0.0000000001 'partial aggregate keeps known bucket cost'
    } finally {
        $partialDb.Close()
        $partialDb.Dispose()
    }

    # Two independently observed standard-context calls may sum beyond the
    # published priority maximum. The sum is a compact bucket, not one request,
    # so it remains priced as standard context.
    $sumDb = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;New=True;'
    $sumDb.Open()
    try {
        [TokenRaderIndexer]::CreateSchema($sumDb)
        $sumOnePath = 'synthetic://limited-sum-one'
        $sumTwoPath = 'synthetic://limited-sum-two'
        Add-ServiceTierAggregateRow -Connection $sumDb -SessionId 'limited-sum-one' -Timestamp '2026-08-30T06:00:01Z' -Model 'synthetic-limited' `
            -TotalInput 200000 -TotalCached 20000 -TotalOutput 50000 -CallInput 200000 -CallCached 20000 -CallOutput 50000 `
            -Fingerprint 'limited-sum-one' -SourcePath $sumOnePath -SourceOffset 10 -RootSessionId 'limited-sum-one' -ServiceTier 'priority' -ServiceTierSource 'log' `
            -ModelContextWindow 1050000 -LongContextThreshold 272000 -LongContextApplied $false -LongContextSource 'pricing_threshold'
        Add-ServiceTierAggregateRow -Connection $sumDb -SessionId 'limited-sum-two' -Timestamp '2026-08-30T06:00:02Z' -Model 'synthetic-limited' `
            -TotalInput 200000 -TotalCached 20000 -TotalOutput 50000 -CallInput 200000 -CallCached 20000 -CallOutput 50000 `
            -Fingerprint 'limited-sum-two' -SourcePath $sumTwoPath -SourceOffset 10 -RootSessionId 'limited-sum-two' -ServiceTier 'priority' -ServiceTierSource 'log' `
            -ModelContextWindow 1050000 -LongContextThreshold 272000 -LongContextApplied $false -LongContextSource 'pricing_threshold'
        $sumAggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
            $sumDb, @{}, @{ $sumOnePath = 10L; $sumTwoPath = 10L },
            [DateTimeOffset]::Parse('2026-08-30T00:00:00Z'), $limitedThresholds,
            [Threading.CancellationToken]::None, $null)
        $sumPriced = & $coreModule {
            param($value, $document)
            ConvertFrom-TokenRaderPricedAggregate -Aggregate $value -PricingDocument $document
        } $sumAggregate $pricing
        Assert-ServiceTierEqual 1 $sumAggregate.Buckets.Count 'same-mode standard calls compact into one bucket'
        Assert-ServiceTierEqual 400000 ([Int64]$sumAggregate.Buckets[0].Input) 'standard compact bucket sums two calls'
        Assert-ServiceTier (-not [bool]$sumAggregate.Buckets[0].LongContext) 'standard compact bucket is not reclassified by its sum'
        Assert-ServiceTier ([bool]$sumPriced.PricingComplete) 'standard compact sum remains priced below tier context cap semantics'
        Assert-ServiceTier ([bool]$sumPriced.Items[0].Cost.Known) 'standard compact sum has a known cost'
        Assert-ServiceTierNear 12.05 ([double]$sumPriced.TotalCost) 0.0000000001 'standard compact sum cost'
    } finally {
        $sumDb.Close()
        $sumDb.Dispose()
    }

    # Older compact objects omit ServiceTier. The conversion path must treat
    # that as an unobserved Standard reference rather than failing or inventing
    # priority pricing.
    $oldAggregateObject = [pscustomobject]@{
        Buckets = @([pscustomobject]@{
            Model = 'synthetic-tiered'
            Input = 1000000L
            Cached = 200000L
            Output = 100000L
            Reasoning = 0L
            Events = 1L
            LongContext = $false
            CacheCreationTokens = 0L
            CacheWriteObservable = $false
            ModelContextWindow = 1050000L
        })
        Models = @('synthetic-tiered')
        TotalInput = 1000000L
        TotalCached = 200000L
        TotalOutput = 100000L
        TotalReasoning = 0L
    }
    $oldPriced = & $coreModule {
        param($value, $document)
        ConvertFrom-TokenRaderPricedAggregate -Aggregate $value -PricingDocument $document
    } $oldAggregateObject $pricing
    Assert-ServiceTier ([bool]$oldPriced.PricingComplete) 'old aggregate without tier remains priced'
    Assert-ServiceTierEqual '' ([string]$oldPriced.Items[0].ServiceTier) 'old aggregate tier defaults to empty'
    Assert-ServiceTier (-not [bool]$oldPriced.Items[0].ServiceTierKnown) 'old aggregate tier is not marked observed'
    Assert-ServiceTierNear 11.2 ([double]$oldPriced.TotalCost) 0.0000000001 'old aggregate Standard reference cost'

    $oldHistoryModel = [pscustomobject]@{
        Model = 'synthetic-tiered'
        TotalInput = 1000000L
        TotalCached = 200000L
        TotalOutput = 100000L
        TotalReasoning = 0L
        InputCost = 8.0
        CachedCost = 0.2
        OutputCost = 3.0
        PricingComplete = $true
        Events = 1L
        CacheCreationTokens = 0L
        CacheWriteObservable = $false
        StandardContextEvents = 1L
        LongContextEvents = 0L
        StandardContextInput = 1000000L
        LongContextInput = 0L
        LongContextOutput = 0L
    }
    $oldHistorySnapshot = [pscustomobject]@{
        WindowStartTicks = [DateTime]::Parse('2026-08-29T00:00:00Z').Ticks
        WindowEndTicks = [DateTime]::Parse('2026-08-30T00:00:00Z').Ticks
        ComputedAtTicks = [DateTime]::Parse('2026-08-30T00:00:01Z').Ticks
        IndexRevision = 1L
        TotalInput = 1000000L
        TotalCached = 200000L
        TotalOutput = 100000L
        TotalReasoning = 0L
        InputCost = 8.0
        CachedCost = 0.2
        OutputCost = 3.0
        PricingComplete = $true
        ModelDisplay = 'synthetic-tiered'
        Models = 'synthetic-tiered'
        RawEvents = 1L
        CountedEvents = 1L
        DuplicateEventsDropped = 0L
        InheritedEventsDropped = 0L
        ProcessedRows = 1L
        CacheCreationTokens = 0L
        CacheWriteObservable = $false
        StandardContextEvents = 1L
        LongContextEvents = 0L
        StandardContextInput = 1000000L
        LongContextInput = 0L
        LongContextOutput = 0L
        LongContextExtraCost = 0.0
        ModelBreakdown = @($oldHistoryModel)
    }
    $oldHistoryResult = & $coreModule {
        param($snapshot)
        ConvertFrom-TokenRaderUsageHistorySnapshot -Snapshot $snapshot -FromCache $true
    } $oldHistorySnapshot
    Assert-ServiceTier ([bool]$oldHistoryResult.FromCache) 'old history object can be re-read from cache'
    Assert-ServiceTierEqual '' ([string]$oldHistoryResult.ModelBreakdown[0].ServiceTier) 'old history model breakdown tier defaults to empty'

    # A real legacy usage_history_models table used a three-column primary key
    # (window_start, window_end, model). Exercise the actual SQLite migration,
    # not just conversion of an in-memory object: the pre-existing row and all
    # long-context/cache diagnostics must survive the table rebuild, while the
    # new composite key permits default and priority rows for one model.
    $legacyDb = New-Object System.Data.SQLite.SQLiteConnection 'Data Source=:memory:;Version=3;New=True;'
    $legacyDb.Open()
    try {
        Invoke-ServiceTierSql -Connection $legacyDb -Sql @'
CREATE TABLE usage_history_models (
    window_start_ticks INTEGER NOT NULL,
    window_end_ticks INTEGER NOT NULL,
    model TEXT NOT NULL DEFAULT '',
    total_input INTEGER NOT NULL DEFAULT 0,
    total_cached INTEGER NOT NULL DEFAULT 0,
    total_output INTEGER NOT NULL DEFAULT 0,
    total_reasoning INTEGER NOT NULL DEFAULT 0,
    input_cost REAL NOT NULL DEFAULT 0,
    cached_cost REAL NOT NULL DEFAULT 0,
    output_cost REAL NOT NULL DEFAULT 0,
    pricing_complete INTEGER NOT NULL DEFAULT 1,
    events INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    cache_write_observable INTEGER NOT NULL DEFAULT 0,
    standard_context_events INTEGER NOT NULL DEFAULT 0,
    long_context_events INTEGER NOT NULL DEFAULT 0,
    standard_context_input INTEGER NOT NULL DEFAULT 0,
    long_context_input INTEGER NOT NULL DEFAULT 0,
    long_context_output INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(window_start_ticks,window_end_ticks,model)
)
'@
        Invoke-ServiceTierSql -Connection $legacyDb -Sql @'
INSERT INTO usage_history_models
(window_start_ticks,window_end_ticks,model,total_input,total_cached,total_output,
 total_reasoning,input_cost,cached_cost,output_cost,pricing_complete,events,
 cache_creation_tokens,cache_write_observable,standard_context_events,
 long_context_events,standard_context_input,long_context_input,long_context_output)
VALUES
(101,202,'synthetic-tiered',700000,70000,7000,70,7.25,0.125,1.75,1,3,
 1234,1,2,1,400000,300000,50000)
'@
        $legacyBefore = Get-ServiceTierTable -Connection $legacyDb -Sql 'PRAGMA table_info(usage_history_models)'
        $legacyBeforePk = @($legacyBefore.Rows | Where-Object { [int]$_['pk'] -gt 0 } | Sort-Object { [int]$_['pk'] })
        Assert-ServiceTierEqual 'window_start_ticks|window_end_ticks|model' (($legacyBeforePk | ForEach-Object { [string]$_['name'] }) -join '|') 'legacy history table has the three-column key before migration'
        Assert-ServiceTier (@($legacyBefore.Rows | Where-Object { [string]$_['name'] -eq 'service_tier' }).Count -eq 0) 'legacy history table starts without service_tier'

        [TokenRaderIndexer]::CreateSchema($legacyDb)
        $legacyAfter = Get-ServiceTierTable -Connection $legacyDb -Sql 'PRAGMA table_info(usage_history_models)'
        $legacyAfterPk = @($legacyAfter.Rows | Where-Object { [int]$_['pk'] -gt 0 } | Sort-Object { [int]$_['pk'] })
        Assert-ServiceTierEqual 'window_start_ticks|window_end_ticks|model|service_tier' (($legacyAfterPk | ForEach-Object { [string]$_['name'] }) -join '|') 'history migration adds service_tier to the primary key'
        $legacyRows = Get-ServiceTierTable -Connection $legacyDb -Sql @'
SELECT model,service_tier,total_input,total_cached,total_output,total_reasoning,
       input_cost,cached_cost,output_cost,pricing_complete,events,
       cache_creation_tokens,cache_write_observable,standard_context_events,
       long_context_events,standard_context_input,long_context_input,long_context_output
FROM usage_history_models WHERE window_start_ticks=101 AND window_end_ticks=202
ORDER BY service_tier
'@
        Assert-ServiceTierEqual 1 $legacyRows.Rows.Count 'legacy history row survives service-tier key migration'
        $legacyDefault = $legacyRows.Rows[0]
        Assert-ServiceTierEqual '' ([string]$legacyDefault['service_tier']) 'legacy row receives empty service tier'
        Assert-ServiceTierEqual 700000 ([Int64]$legacyDefault['total_input']) 'legacy total input survives migration'
        Assert-ServiceTierEqual 70000 ([Int64]$legacyDefault['total_cached']) 'legacy total cached survives migration'
        Assert-ServiceTierEqual 7000 ([Int64]$legacyDefault['total_output']) 'legacy total output survives migration'
        Assert-ServiceTierEqual 70 ([Int64]$legacyDefault['total_reasoning']) 'legacy reasoning total survives migration'
        Assert-ServiceTierNear 7.25 ([double]$legacyDefault['input_cost']) 0.0000000001 'legacy input cost survives migration'
        Assert-ServiceTierNear 0.125 ([double]$legacyDefault['cached_cost']) 0.0000000001 'legacy cached cost survives migration'
        Assert-ServiceTierNear 1.75 ([double]$legacyDefault['output_cost']) 0.0000000001 'legacy output cost survives migration'
        Assert-ServiceTierEqual 3 ([Int64]$legacyDefault['events']) 'legacy event count survives migration'
        Assert-ServiceTierEqual 1234 ([Int64]$legacyDefault['cache_creation_tokens']) 'legacy cache creation diagnostics survive migration'
        Assert-ServiceTierEqual 1 ([Int64]$legacyDefault['cache_write_observable']) 'legacy cache-write observability survives migration'
        Assert-ServiceTierEqual 2 ([Int64]$legacyDefault['standard_context_events']) 'legacy standard-context event diagnostics survive migration'
        Assert-ServiceTierEqual 1 ([Int64]$legacyDefault['long_context_events']) 'legacy long-context event diagnostics survive migration'
        Assert-ServiceTierEqual 400000 ([Int64]$legacyDefault['standard_context_input']) 'legacy standard-context input diagnostics survive migration'
        Assert-ServiceTierEqual 300000 ([Int64]$legacyDefault['long_context_input']) 'legacy long-context input diagnostics survive migration'
        Assert-ServiceTierEqual 50000 ([Int64]$legacyDefault['long_context_output']) 'legacy long-context output diagnostics survive migration'

        Invoke-ServiceTierSql -Connection $legacyDb -Sql @'
INSERT INTO usage_history_models
(window_start_ticks,window_end_ticks,model,service_tier,total_input,total_cached,
 total_output,total_reasoning,input_cost,cached_cost,output_cost,pricing_complete,
 events,cache_creation_tokens,cache_write_observable,standard_context_events,
 long_context_events,standard_context_input,long_context_input,long_context_output)
VALUES
(101,202,'synthetic-tiered','priority',800000,80000,8000,80,8.25,0.225,2.75,1,
 4,2345,1,3,1,500000,300000,60000)
'@
        $twoTierRows = Get-ServiceTierTable -Connection $legacyDb -Sql @'
SELECT model,service_tier,total_input,total_cached,total_output,total_reasoning,
       input_cost,cached_cost,output_cost,pricing_complete,events,
       cache_creation_tokens,cache_write_observable,standard_context_events,
       long_context_events,standard_context_input,long_context_input,long_context_output
FROM usage_history_models WHERE window_start_ticks=101 AND window_end_ticks=202
ORDER BY service_tier
'@
        Assert-ServiceTierEqual 2 $twoTierRows.Rows.Count 'migrated history key permits two tiers for one model'
        Assert-ServiceTierEqual 'default|priority' (($twoTierRows.Rows | ForEach-Object { if ([string]::IsNullOrWhiteSpace([string]$_['service_tier'])) { 'default' } else { [string]$_['service_tier'] } }) -join '|') 'migrated rows retain distinct default and priority modes'
        $legacyPriority = @($twoTierRows.Rows | Where-Object { [string]$_['service_tier'] -eq 'priority' })[0]
        Assert-ServiceTierEqual 2345 ([Int64]$legacyPriority['cache_creation_tokens']) 'new priority row cache diagnostics are stored'
        Assert-ServiceTierEqual 1 ([Int64]$legacyPriority['cache_write_observable']) 'new priority row cache-write diagnostics are stored'
        Assert-ServiceTierEqual 1 ([Int64]$legacyPriority['long_context_events']) 'new priority row long-context diagnostics are stored'

        # A second schema initialization must be a no-op: it must not rebuild
        # the already migrated table again or lose either tier row/diagnostic.
        [TokenRaderIndexer]::CreateSchema($legacyDb)
        $legacyAfterSecond = Get-ServiceTierTable -Connection $legacyDb -Sql 'PRAGMA table_info(usage_history_models)'
        $legacyAfterSecondPk = @($legacyAfterSecond.Rows | Where-Object { [int]$_['pk'] -gt 0 } | Sort-Object { [int]$_['pk'] })
        Assert-ServiceTierEqual 'window_start_ticks|window_end_ticks|model|service_tier' (($legacyAfterSecondPk | ForEach-Object { [string]$_['name'] }) -join '|') 'second history migration is idempotent'
        $twoTierRowsAfterSecond = Get-ServiceTierTable -Connection $legacyDb -Sql @'
SELECT model,service_tier,total_input,total_cached,total_output,total_reasoning,
       cache_creation_tokens,cache_write_observable,standard_context_events,
       long_context_events,standard_context_input,long_context_input,long_context_output
FROM usage_history_models WHERE window_start_ticks=101 AND window_end_ticks=202
ORDER BY service_tier
'@
        Assert-ServiceTierEqual 2 $twoTierRowsAfterSecond.Rows.Count 'second history migration preserves both tier rows'
        $legacyDefaultAfterSecond = @($twoTierRowsAfterSecond.Rows | Where-Object { [string]$_['service_tier'] -eq '' })[0]
        $legacyPriorityAfterSecond = @($twoTierRowsAfterSecond.Rows | Where-Object { [string]$_['service_tier'] -eq 'priority' })[0]
        Assert-ServiceTierEqual 1234 ([Int64]$legacyDefaultAfterSecond['cache_creation_tokens']) 'second migration preserves legacy cache diagnostics'
        Assert-ServiceTierEqual 1 ([Int64]$legacyDefaultAfterSecond['long_context_events']) 'second migration preserves legacy long-context diagnostics'
        Assert-ServiceTierEqual 2345 ([Int64]$legacyPriorityAfterSecond['cache_creation_tokens']) 'second migration leaves priority cache diagnostics intact'
    } finally {
        $legacyDb.Close()
        $legacyDb.Dispose()
    }

    # Persistent synthetic history covers mixed intervals, model|tier rows,
    # response precedence in the indexer, cached mode persistence, and cache
    # invalidation when only a tier price changes.
    $historyRoot = Join-Path $tempRoot 'history-sessions'
    New-Item -ItemType Directory -Path $historyRoot -Force | Out-Null
    $historyTransitionPath = Join-Path $historyRoot 'rollout-70000000-0000-0000-0000-000000000001.jsonl'
    $historyResponsePath = Join-Path $historyRoot 'rollout-70000000-0000-0000-0000-000000000002.jsonl'
    Write-ServiceTierJsonl -Path $historyTransitionPath -Lines @(
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-31T05:59:00Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier 'fast'),
        (New-ServiceTierTokenLine -Timestamp '2026-08-31T06:00:00Z' -TotalInput 200000 -TotalCached 40000 -TotalOutput 20000 -CallInput 200000 -CallCached 40000 -CallOutput 20000),
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-31T11:59:00Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier 'standard'),
        (New-ServiceTierTokenLine -Timestamp '2026-08-31T12:00:00Z' -TotalInput 400000 -TotalCached 80000 -TotalOutput 40000 -CallInput 200000 -CallCached 40000 -CallOutput 20000),
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-31T17:59:00Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier $null),
        (New-ServiceTierTokenLine -Timestamp '2026-08-31T18:00:00Z' -TotalInput 600000 -TotalCached 120000 -TotalOutput 60000 -CallInput 200000 -CallCached 40000 -CallOutput 20000)
    )
    Write-ServiceTierJsonl -Path $historyResponsePath -Lines @(
        (New-ServiceTierTurnContextLine -Timestamp '2026-08-31T19:59:00Z' -Model 'synthetic-tiered' -IncludeServiceTier -ServiceTier 'fast'),
        (New-ServiceTierTokenLine -Timestamp '2026-08-31T20:00:00Z' -TotalInput 200000 -TotalCached 40000 -TotalOutput 20000 -CallInput 200000 -CallCached 40000 -CallOutput 20000 `
            -IncludePayloadServiceTier -PayloadServiceTier 'fast' -IncludeResponseServiceTier -ResponseServiceTier 'standard')
    )

    $historyDbPath = Join-Path $tempRoot 'data\private\history-index\index.db'
    New-Item -ItemType Directory -Path (Split-Path -Parent $historyDbPath) -Force | Out-Null
    $env:TOKEN_RADER_INDEX_DB = $historyDbPath
    $historyIndexTouched = $true
    $historyAnchor = [DateTimeOffset]::Parse('2026-09-01T00:00:00Z')
    $historyFirst = Get-TokenRaderUsageHistoryWindow -SessionsRoot $historyRoot -PricingDocument $pricing `
        -AnchorAt $historyAnchor -ForceRefresh
    Assert-ServiceTier (-not [bool]$historyFirst.FromCache) 'first synthetic history read is fresh'
    Assert-ServiceTierEqual 880000 ([Int64]$historyFirst.Usage.Total) 'history mixed intervals usage total'
    Assert-ServiceTierEqual 3 (@($historyFirst.ModelBreakdown).Count) 'history stores one model row per observed tier'
    $historyPriority = @($historyFirst.ModelBreakdown | Where-Object { [string]$_.ServiceTier -eq 'priority' })
    $historyDefault = @($historyFirst.ModelBreakdown | Where-Object { [string]$_.ServiceTier -eq 'default' })
    $historyUnknown = @($historyFirst.ModelBreakdown | Where-Object { [string]$_.ServiceTier -eq '' })
    Assert-ServiceTierEqual 1 $historyPriority.Count 'history priority breakdown row'
    Assert-ServiceTierEqual 1 $historyDefault.Count 'history default breakdown row'
    Assert-ServiceTierEqual 1 $historyUnknown.Count 'history unknown/Standard-fallback breakdown row'
    Assert-ServiceTierEqual 1 ([Int64]$historyPriority[0].Events) 'history priority event count'
    Assert-ServiceTierEqual 2 ([Int64]$historyDefault[0].Events) 'history default event count includes response override'
    Assert-ServiceTierEqual 1 ([Int64]$historyUnknown[0].Events) 'history unknown event count'
    Assert-ServiceTierNear 11.2 ([double]$historyFirst.TotalCost) 0.0000000001 'history mixed-tier cost'

    $historyIndex = & $coreModule { $script:TokenRaderIndex }
    $indexedTransitionRows = Get-ServiceTierIndexedRows -Connection $historyIndex.Connection -Path ([IO.Path]::GetFullPath($historyTransitionPath))
    Assert-ServiceTierEqual 3 $indexedTransitionRows.Rows.Count 'indexed transition rows'
    $indexedTransitionTiers = @($indexedTransitionRows.Rows | ForEach-Object {
        & $coreModule { param($value) ConvertTo-TokenRaderServiceTier $value } ([string]$_['service_tier'])
    })
    Assert-ServiceTierEqual 'priority|default|' ($indexedTransitionTiers -join '|') 'index stores/reset service tier state across turns'
    $indexedResponseRows = Get-ServiceTierIndexedRows -Connection $historyIndex.Connection -Path ([IO.Path]::GetFullPath($historyResponsePath))
    Assert-ServiceTierEqual 1 $indexedResponseRows.Rows.Count 'indexed response override row'
    Assert-ServiceTierEqual 'default' (& $coreModule { param($value) ConvertTo-TokenRaderServiceTier $value } ([string]$indexedResponseRows.Rows[0]['service_tier'])) 'index stores actual response tier'

    $historyCached = Get-TokenRaderUsageHistoryWindow -SessionsRoot $historyRoot -PricingDocument $pricing -AnchorAt $historyAnchor
    Assert-ServiceTier ([bool]$historyCached.FromCache) 'second history read uses compact cached snapshot'
    Assert-ServiceTierEqual (($historyFirst.ModelBreakdown | ForEach-Object { [string]$_.ServiceTier } | Sort-Object) -join '|') `
        (($historyCached.ModelBreakdown | ForEach-Object { [string]$_.ServiceTier } | Sort-Object) -join '|') 'cached history preserves tier rows'
    Assert-ServiceTierNear ([double]$historyFirst.TotalCost) ([double]$historyCached.TotalCost) 0.0000000001 'cached history preserves tier cost'

    $historyChanged = Get-TokenRaderUsageHistoryWindow -SessionsRoot $historyRoot -PricingDocument $changedPricing -AnchorAt $historyAnchor
    Assert-ServiceTier (-not [bool]$historyChanged.FromCache) 'changed tier price invalidates cached history'
    Assert-ServiceTierNear 11.36 ([double]$historyChanged.TotalCost) 0.0000000001 'changed priority price recomputes history cost'
    Assert-ServiceTierEqual (($historyCached.ModelBreakdown | ForEach-Object { [string]$_.ServiceTier } | Sort-Object) -join '|') `
        (($historyChanged.ModelBreakdown | ForEach-Object { [string]$_.ServiceTier } | Sort-Object) -join '|') 'fresh history after cache invalidation preserves tier rows'

    Write-Output 'SERVICE_TIER_TESTS_PASSED'
} finally {
    try {
        $currentIndex = & $coreModule { $script:TokenRaderIndex }
        $currentRoot = if ($null -ne $currentIndex -and $null -ne $currentIndex.PSObject.Properties['SessionsRoot']) {
            [string]$currentIndex.SessionsRoot
        } else { '' }
        $isSyntheticIndex = $historyIndexTouched -and -not [string]::IsNullOrWhiteSpace($currentRoot) -and
            [string]::IsNullOrWhiteSpace($previousIndexRoot) -or
            ($historyIndexTouched -and -not [string]::IsNullOrWhiteSpace($currentRoot) -and
             -not [string]::Equals($currentRoot, $previousIndexRoot, [StringComparison]::OrdinalIgnoreCase))
        if ($isSyntheticIndex) {
            & $coreModule { Close-TokenRaderIndex } | Out-Null
        }
    } catch { }
    try {
        if ($null -eq $previousDbOverride) {
            Remove-Item Env:TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue
        } else {
            $env:TOKEN_RADER_INDEX_DB = $previousDbOverride
        }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace($previousIndexRoot)) {
        try {
            $restoredIndex = & $coreModule { param($root) Open-TokenRaderIndex -SessionsRoot $root } $previousIndexRoot
            [void]$restoredIndex
        } catch { }
    }
    # Resolve and validate the generated directory before recursive cleanup.
    # This guard intentionally refuses to remove anything outside the system
    # temp directory or with a name not created by this test.
    try {
        $resolvedTempRoot = $null
        if (Test-Path -LiteralPath $tempRoot) {
            $resolvedTempRoot = (Get-Item -LiteralPath $tempRoot -ErrorAction Stop).FullName
        }
        $systemTempRoot = ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd([char]'\', [char]'/')
        $systemTempPrefix = $systemTempRoot + [IO.Path]::DirectorySeparatorChar
        $tempLeaf = if ($null -ne $resolvedTempRoot) { Split-Path -Leaf $resolvedTempRoot } else { '' }
        $safeCleanup = $null -ne $resolvedTempRoot -and
            $resolvedTempRoot.StartsWith($systemTempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            $tempLeaf.StartsWith('token-rader-service-tier-test-', [StringComparison]::OrdinalIgnoreCase)
        if ($safeCleanup) {
            Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}
