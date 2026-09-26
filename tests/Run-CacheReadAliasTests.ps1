$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $projectRoot 'TokenRader.Core.psm1'
$coreModule = Import-Module -Name $corePath -Force -PassThru

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw ('ASSERT FAILED: {0}; expected <{1}>, actual <{2}>' -f $Message, $Expected, $Actual)
    }
}

function Assert-Near {
    param([double]$Expected, [double]$Actual, [double]$Tolerance, [string]$Message)
    if ([Math]::Abs($Expected - $Actual) -gt $Tolerance) {
        throw ('ASSERT FAILED: {0}; expected <{1:R}>, actual <{2:R}>' -f $Message, $Expected, $Actual)
    }
}

$cases = @(
    @{ Name = 'missing canonical'; Fields = '"cache_read_tokens":25'; Expected = [Int64]25 },
    @{ Name = 'null canonical'; Fields = '"cached_input_tokens":null,"cache_read_tokens":25'; Expected = [Int64]25 },
    @{ Name = 'empty canonical'; Fields = '"cached_input_tokens":"","cache_read_tokens":25'; Expected = [Int64]25 },
    @{ Name = 'invalid string canonical'; Fields = '"cached_input_tokens":"not-a-number","cache_read_tokens":25'; Expected = [Int64]25 },
    @{ Name = 'fractional canonical'; Fields = '"cached_input_tokens":1.5,"cache_read_tokens":25'; Expected = [Int64]25 },
    @{ Name = 'fractional string canonical'; Fields = '"cached_input_tokens":"1.5","cache_read_tokens":25'; Expected = [Int64]25 },
    @{ Name = 'negative canonical'; Fields = '"cached_input_tokens":-1,"cache_read_tokens":25'; Expected = [Int64]25 },
    @{ Name = 'explicit zero canonical'; Fields = '"cached_input_tokens":0,"cache_read_tokens":25'; Expected = [Int64]0 },
    @{ Name = 'numeric string canonical'; Fields = '"cached_input_tokens":" 20 ","cache_read_tokens":25'; Expected = [Int64]20 },
    @{ Name = 'alias appears first in JSON'; Fields = '"cache_read_tokens":25,  "cached_input_tokens":20'; Expected = [Int64]20 },
    @{ Name = 'read alias then cached alias'; Fields = '"cache_read_tokens":15,"cached_tokens":0'; Expected = [Int64]15 },
    @{ Name = 'invalid read falls through to cached alias'; Fields = '"cache_read_tokens":" ","cached_tokens":12'; Expected = [Int64]12 },
    @{ Name = 'no aliases'; Fields = '"reasoning_output_tokens":0'; Expected = [Int64]0 },
    @{ Name = 'integral decimal number'; Fields = '"cached_input_tokens":25.0,"cache_read_tokens":30'; Expected = [Int64]25 },
    @{ Name = 'integral exponent number'; Fields = '"cached_input_tokens":1e3,"cache_read_tokens":30'; Expected = [Int64]1000 },
    @{ Name = 'boolean canonical'; Fields = '"cached_input_tokens":true,"cache_read_tokens":25'; Expected = [Int64]25 },
    @{ Name = 'non-finite string canonical'; Fields = '"cached_input_tokens":"Infinity","cache_read_tokens":25'; Expected = [Int64]25 },
    @{ Name = 'oversized canonical'; Fields = '"cached_input_tokens":9223372036854775808,"cache_read_tokens":25'; Expected = [Int64]25 }
)

$pricing = [pscustomobject]@{
    unitTokens = 1000000
    models = @([pscustomobject]@{
        id = 'cache-alias-test-model'
        aliases = @()
        input = 10.0
        cachedInput = 1.0
        output = 20.0
    })
}

# Assembly initialization performs no account/log/database access. A preloaded
# staged assembly is also supported; all test data below uses a temporary DB.
if (-not (Initialize-TokenRaderIndexer)) { throw 'Indexer unavailable; build the project before running this test.' }

$oldDbPath = $env:TOKEN_RADER_INDEX_DB
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('TokenRader-CacheReadAlias-' + [Guid]::NewGuid().ToString('N'))
$sessionsRoot = Join-Path $tempRoot 'sessions'
$dbPath = Join-Path $tempRoot 'data\private\cache-alias-test.db'
$sessionPath = Join-Path $sessionsRoot 'rollout-cache-alias.jsonl'
$passed = 0

try {
    New-Item -ItemType Directory -Path $sessionsRoot -Force | Out-Null
    $env:TOKEN_RADER_INDEX_DB = $dbPath

    foreach ($case in $cases) {
        $usageJson = '{"input_tokens":2000,' + [string]$case.Fields + ',"output_tokens":10}'
        $legacy = & $coreModule {
            param($Json)
            $raw = ConvertFrom-Json -InputObject $Json -ErrorAction Stop
            ConvertTo-TokenRaderUsage -RawUsage $raw
        } $usageJson
        $innerText = $usageJson.Substring(1, $usageJson.Length - 2)
        $fast = & $coreModule {
            param($Text)
            ConvertFrom-TokenRaderUsageTextFast -InnerText $Text
        } $innerText

        Assert-Equal $case.Expected ([Int64]$legacy.Cached) ($case.Name + ' legacy cached count')
        Assert-Equal $case.Expected ([Int64]$fast.Cached) ($case.Name + ' fast cached count')
        # Regex callers pass the inside of a JSON object, without its closing
        # brace. A final cache property must therefore accept end-of-text.
        $cacheLastText = '"input_tokens":2000,"output_tokens":10,' + [string]$case.Fields
        $cacheLast = & $coreModule {
            param($Text)
            ConvertFrom-TokenRaderUsageTextFast -InnerText $Text
        } $cacheLastText
        Assert-Equal $case.Expected ([Int64]$cacheLast.Cached) ($case.Name + ' fast cache at end of text')

        $legacyCost = Get-TokenRaderCost -Usage $legacy -Model 'cache-alias-test-model' -PricingDocument $pricing -Scope call
        $fastCost = Get-TokenRaderCost -Usage $fast -Model 'cache-alias-test-model' -PricingDocument $pricing -Scope call
        if (-not $legacyCost.Known -or -not $fastCost.Known) { throw ('Synthetic price was not resolved for ' + $case.Name) }
        Assert-Near ([double]$legacyCost.TotalCost) ([double]$fastCost.TotalCost) 0.000000000001 ($case.Name + ' legacy/fast cost parity')

        $stamp = '2026-01-01T00:00:01Z'
        $turnLine = '{"timestamp":"2026-01-01T00:00:00Z","type":"turn_context","payload":{"model":"cache-alias-test-model"}}'
        $tokenLine = '{"timestamp":"' + $stamp + '","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":' + $usageJson + '}}}'
        [IO.File]::WriteAllText($sessionPath, $turnLine + "`n" + $tokenLine + "`n", (New-Object Text.UTF8Encoding($false)))

        Close-TokenRaderIndex
        New-TokenRaderIndex -SessionsRoot $sessionsRoot -Force | Out-Null
        $baseline = [pscustomobject]@{
            SessionsRoot = $sessionsRoot
            StartOffsets = @{}
            StartedAt = [DateTimeOffset]::MinValue
            StartRateLimits = $null
        }
        $endOffsets = @{}
        $endOffsets[$sessionPath] = [Int64](Get-Item -LiteralPath $sessionPath).Length
        $indexed = Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $pricing `
            -EndOffsets $endOffsets -EndedAt ([DateTimeOffset]::Parse($stamp)) -ScanRateLimits:$false
        Assert-Equal $case.Expected ([Int64]$indexed.Usage.Cached) ($case.Name + ' C# indexed cached count')
        Assert-Near ([double]$legacyCost.TotalCost) ([double]$indexed.TotalCost) 0.000000000001 ($case.Name + ' legacy/C# cost parity')
        $passed++
    }

    # JSON cannot encode NaN/Infinity as a numeric value. Exercise the legacy
    # object path directly to ensure non-finite numeric values are skipped.
    $nonFinite = & $coreModule {
        $raw = [pscustomobject]@{
            input_tokens = 2000
            cached_input_tokens = [double]::PositiveInfinity
            cache_read_tokens = 25
            output_tokens = 10
        }
        ConvertTo-TokenRaderUsage -RawUsage $raw
    }
    Assert-Equal ([Int64]25) ([Int64]$nonFinite.Cached) 'non-finite legacy value falls through'
    $passed++

    Write-Output ('PASS: cache-read alias parity (' + $passed + ' assertions groups)')
} finally {
    try { Close-TokenRaderIndex } catch { }
    if ($null -eq $oldDbPath) { Remove-Item Env:\TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue }
    else { $env:TOKEN_RADER_INDEX_DB = $oldDbPath }

    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemp).StartsWith('TokenRader-CacheReadAlias-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
