[CmdletBinding()]
param(
    [ValidateRange(1,10000)][int]$Files = 5000,
    [ValidateRange(1,10000)][int]$Changed = 4,
    [ValidateRange(1,10)][int]$Samples = 3
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Changed -gt $Files) { throw 'Changed must not exceed Files' }
$projectRoot = Split-Path -Parent $PSScriptRoot
$tempRoot = Join-Path $env:TEMP ('token-rader-interval-profile-' + [Guid]::NewGuid().ToString('N'))
$sessionsRoot = Join-Path $tempRoot 'sessions'
$previousDb = $env:TOKEN_RADER_INDEX_DB
New-Item -ItemType Directory -Path $sessionsRoot -Force | Out-Null
$env:TOKEN_RADER_INDEX_DB = Join-Path $tempRoot 'data\private\synthetic-index.db'
New-Item -ItemType Directory -Path (Split-Path -Parent $env:TOKEN_RADER_INDEX_DB) -Force | Out-Null
try {
    Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force
    if (-not (Initialize-TokenRaderIndexer)) { throw 'Indexer runtime could not be loaded' }
    $module = Get-Module TokenRader.Core
    $prices = Get-TokenRaderPrices -PricingPath (Join-Path $projectRoot 'pricing.json')
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $encoding = New-Object Text.UTF8Encoding($false)
    for ($i=1; $i -le $Files; $i++) {
        $id = '{0:D8}-0000-0000-0000-000000000000' -f $i
        $path = Join-Path $sessionsRoot ('rollout-perf-' + $id + '.jsonl')
        $stamp = [DateTimeOffset]::UtcNow.AddMinutes(-10).AddMilliseconds($i).ToString('o')
        $content = '{"timestamp":"' + $stamp + '","type":"session_meta","payload":{"id":"' + $id + '"}}' + "`n" +
            '{"timestamp":"' + $stamp + '","type":"turn_context","payload":{"model":"gpt-5.5"}}' + "`n" +
            '{"timestamp":"' + $stamp + '","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":1010},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":1010},"model_context_window":1050000},"rate_limits":{"plan_type":"pro","primary":{"used_percent":10,"window_minutes":300,"resets_at":1890000000},"secondary":{"used_percent":20,"window_minutes":10080,"resets_at":1890600000}}}}' + "`n"
        [IO.File]::WriteAllText($path,$content,$encoding)
        [void]$paths.Add($path)
    }
    New-TokenRaderIndex -SessionsRoot $sessionsRoot -Force | Out-Null
    $db = (Get-TokenRaderIndex).Connection
    [void][TokenRaderIndexer]::BackfillRecentToolRecords($db,[DateTimeOffset]::UtcNow.AddDays(-7).UtcDateTime.Ticks,([long][TokenRaderIndexer]::GetIndexRevision($db)+1L),[Threading.CancellationToken]::None,$null)
    $baseline = CaptureMeasurementBaseline -SessionsRoot $sessionsRoot -PricingDocument $prices
    $watchRevision = [TokenRaderIndexer]::GetChangeRevision($sessionsRoot)
    for ($i=0; $i -lt $Changed; $i++) {
        $stamp=[DateTimeOffset]::UtcNow.AddSeconds($i+1).ToString('o'); $input=2000+$i
        $line='{"timestamp":"' + $stamp + '","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":' + $input + ',"cached_input_tokens":200,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":' + ($input+20) + '},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":100,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":1010},"model_context_window":1050000},"rate_limits":{"plan_type":"pro","primary":{"used_percent":11,"window_minutes":300,"resets_at":1890000000},"secondary":{"used_percent":21,"window_minutes":10080,"resets_at":1890600000}}}}' + "`n"
        [IO.File]::AppendAllText($paths[$i],$line,$encoding)
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(2)
    while ([TokenRaderIndexer]::GetChangeRevision($sessionsRoot) -le $watchRevision -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
    $ending=CaptureMeasurementEnd -Baseline $baseline
    $ending | Add-Member -NotePropertyName ExpectedChanged -NotePropertyValue $Changed
    for ($sample=0; $sample -lt $Samples; $sample++) {
        & $module {
            param($baseline,$ending,$prices,$db,$sample)
            $timings=[ordered]@{ Sample=$sample }
            $watch=[Diagnostics.Stopwatch]::StartNew(); $starts=ConvertTo-TokenRaderOffsetMap $baseline.StartOffsets; $timings.StartMapMs=$watch.Elapsed.TotalMilliseconds
            $watch.Restart(); $ends=ConvertTo-TokenRaderOffsetMap $ending.EndOffsets; $timings.EndMapMs=$watch.Elapsed.TotalMilliseconds
            $thresholds=New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in @($prices.models)) { $threshold=if ($null -ne $entry.PSObject.Properties['longContextThreshold']) { [long]$entry.longContextThreshold } else { 0L }; $thresholds[[string]$entry.id]=$threshold; foreach ($alias in @($entry.aliases)) { $thresholds[[string]$alias]=$threshold } }
            $watch.Restart(); $agg=[TokenRaderIndexer]::AggregateIntervalRecords($db,$starts,$ends,[DateTimeOffset]$baseline.StartedAt,$thresholds,[Threading.CancellationToken]::None,$null); $timings.MainAggregateMs=$watch.Elapsed.TotalMilliseconds
            $watch.Restart(); $priced=ConvertFrom-TokenRaderPricedAggregate $agg $prices; $timings.MainPricingMs=$watch.Elapsed.TotalMilliseconds
            $watch.Restart(); $rlEnds=ConvertTo-TokenRaderOffsetMap $ends; $rlStarts=New-Object hashtable ([StringComparer]::OrdinalIgnoreCase); foreach ($path in @($rlEnds.Keys)) { $rlStarts[$path]=0L }; $timings.RateMapMs=$watch.Elapsed.TotalMilliseconds
            $watch.Restart(); $table=[TokenRaderIndexer]::QueryLatestRateLimitsByOffsets($db,$rlStarts,$rlEnds); $timings.RateQueryMs=$watch.Elapsed.TotalMilliseconds; $timings.RateRows=$table.Rows.Count
            $watch.Restart(); $endLimits=ConvertFrom-TokenRaderRateLimitRows $table 'codex'; $timings.RateConvertMs=$watch.Elapsed.TotalMilliseconds
            $cache=@{}
            foreach ($kind in @('FiveHour','Weekly')) {
                $watch.Restart(); $diag=@{}
                $evidence=Get-TokenRaderQuotaWindowEvidence -StartWindow $baseline.StartRateLimits.$kind -EndWindow $endLimits.$kind -MainLastCountedAt $agg.LastCountedAt -WindowKind $kind -RateLimitId $endLimits.LimitId -Connection $db -EndOffsets $ends -Thresholds $thresholds -PricingDocument $prices -CancellationToken ([Threading.CancellationToken]::None) -Cache $cache -DiagnosticState $diag
                $timings[($kind+'EvidenceMs')]=$watch.Elapsed.TotalMilliseconds
                $timings[($kind+'Reason')]=$diag.ReasonCode
            }
            $watch.Restart(); $result=Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $prices -EndOffsets $ending.EndOffsets -EndRevision $ending.EndRevision; $timings.FullComputeMs=$watch.Elapsed.TotalMilliseconds
            $watch.Restart(); $noQuota=Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $prices -EndOffsets $ending.EndOffsets -EndRevision $ending.EndRevision -ScanRateLimits $false; $timings.NoQuotaComputeMs=$watch.Elapsed.TotalMilliseconds
            $originalMap=(Get-Item Function:ConvertTo-TokenRaderOffsetMap).ScriptBlock
            try {
                Set-Item Function:ConvertTo-TokenRaderOffsetMap -Value {
                    param($Value)
                    $map=New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
                    if ($null -eq $Value) { return $map }
                    if ($Value -is [Collections.IDictionary]) {
                        foreach ($key in @($Value.Keys)) {
                            try { $path=[string]$key; try { $path=[IO.Path]::GetFullPath($path) } catch { }; $map[$path]=[long]$Value[$key] } catch { }
                        }
                    } elseif ($null -ne $Value.PSObject) {
                        foreach ($property in @($Value.PSObject.Properties)) {
                            try { $path=[string]$property.Name; try { $path=[IO.Path]::GetFullPath($path) } catch { }; $map[$path]=[long]$property.Value } catch { }
                        }
                    }
                    return $map
                }
                $watch.Restart(); $inlineMap=Get-TokenRaderIndexedIntervalResult -Baseline $baseline -PricingDocument $prices -EndOffsets $ending.EndOffsets -EndRevision $ending.EndRevision; $timings.InlineMapComputeMs=$watch.Elapsed.TotalMilliseconds
                if ($inlineMap.CountedEvents -ne $result.CountedEvents -or $inlineMap.TotalCost -ne $result.TotalCost -or $inlineMap.Usage.Total -ne $result.Usage.Total) { throw 'In-memory candidate changed result' }
            } finally { Set-Item Function:ConvertTo-TokenRaderOffsetMap -Value $originalMap }
            if ($result.CountedEvents -ne $ending.ExpectedChanged -or $noQuota.CountedEvents -ne $ending.ExpectedChanged) { throw 'Synthetic counted-event mismatch' }
            [pscustomobject]$timings | ConvertTo-Json -Compress
        } $baseline $ending $prices $db $sample
    }
} finally {
    Close-TokenRaderIndex
    if ($null -eq $previousDb) { Remove-Item Env:TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue } else { $env:TOKEN_RADER_INDEX_DB=$previousDb }
    $resolved=[IO.Path]::GetFullPath($tempRoot)
    $safeTemp=[IO.Path]::GetFullPath($env:TEMP).TrimEnd([char]'\')+[IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($safeTemp,[StringComparison]::OrdinalIgnoreCase)) { throw 'Synthetic cleanup target is not in TEMP' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
