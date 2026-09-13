[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-QuotaPool {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw ('QUOTA POOL TEST FAILED: ' + $Message) }
}

function Add-QuotaPoolParameter {
    param(
        [Parameter(Mandatory = $true)]$Command,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    [void]$Command.Parameters.AddWithValue($Name, $(if ($null -eq $Value) { [DBNull]::Value } else { $Value }))
}

function Add-QuotaPoolRow {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][Int64]$SourceOffset,
        [Parameter(Mandatory = $true)][string]$RateLimitId,
        [object]$FiveHourUsed = $null,
        [object]$WeeklyUsed = $null,
        [object]$FiveHourWindow = $null,
        [object]$WeeklyWindow = $null,
        [object]$FiveHourReset = $null,
        [object]$WeeklyReset = $null,
        [string]$PlanType = 'pro'
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = @'
INSERT INTO token_records
(session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning,
 call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,
 source_offset_end,root_session_id,index_revision,model_source,turn_id,request_id,
 response_id,identity_source,service_tier,service_tier_source,
 five_hour_used,five_hour_window,five_hour_resets,weekly_used,weekly_window,
 weekly_resets,plan_type,rate_limit_id,cache_write_observable)
VALUES
(@session,@timestamp,'gpt-5.6-sol',0,0,0,0,
 0,0,0,0,@fingerprint,@source_path,
 @source_offset,@session,1,'response','','quota-pool-request',
 'quota-pool-response','request_id','default','response',
 @five_used,@five_window,@five_reset,@weekly_used,@weekly_window,
 @weekly_reset,@plan,@limit,1)
'@
        Add-QuotaPoolParameter $command '@session' $SessionId
        Add-QuotaPoolParameter $command '@timestamp' $Timestamp
        Add-QuotaPoolParameter $command '@fingerprint' ('quota-pool-' + $SourceOffset.ToString([Globalization.CultureInfo]::InvariantCulture))
        Add-QuotaPoolParameter $command '@source_path' $SourcePath
        Add-QuotaPoolParameter $command '@source_offset' $SourceOffset
        Add-QuotaPoolParameter $command '@five_used' $FiveHourUsed
        Add-QuotaPoolParameter $command '@five_window' $FiveHourWindow
        Add-QuotaPoolParameter $command '@five_reset' $FiveHourReset
        Add-QuotaPoolParameter $command '@weekly_used' $WeeklyUsed
        Add-QuotaPoolParameter $command '@weekly_window' $WeeklyWindow
        Add-QuotaPoolParameter $command '@weekly_reset' $WeeklyReset
        Add-QuotaPoolParameter $command '@plan' $PlanType
        Add-QuotaPoolParameter $command '@limit' $RateLimitId
        [void]$command.ExecuteNonQuery()
    } finally {
        $command.Dispose()
    }
}

function Get-QuotaPoolRowCount {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [string]$Where = ''
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = 'SELECT COUNT(*) FROM token_records' + $Where
        return [Int64]$command.ExecuteScalar()
    } finally {
        $command.Dispose()
    }
}

function New-QuotaPoolWindow {
    param(
        [Parameter(Mandatory = $true)][double]$UsedPercent,
        [Parameter(Mandatory = $true)][string]$ObservedAt,
        [string]$LimitId = '',
        [string]$PlanType = 'pro',
        [int]$WindowMinutes = 10080,
        [Int64]$ResetUnixSeconds = 1900000000
    )
    $observed = [DateTimeOffset]::Parse($ObservedAt)
    $resetsAt = [DateTimeOffset]::FromUnixTimeSeconds($ResetUnixSeconds)
    [pscustomobject]@{
        UsedPercent = $UsedPercent
        RemainingPercent = 100.0 - $UsedPercent
        WindowMinutes = $WindowMinutes
        ResetsAt = $resetsAt
        ResetIdentity = (& $script:QuotaPoolCoreModule {
                param($minutes, $reset)
                Get-TokenRaderResetIdentity -WindowMinutes $minutes -ResetsAt $reset
            } $WindowMinutes $resetsAt)
        ObservedAt = $observed
        SourceFile = 'synthetic://quota-pool'
        PlanType = $PlanType
        LimitId = $LimitId
        ScopeConflict = $false
        ConflictDescription = ''
        ConflictPlans = @()
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $projectRoot 'TokenRader.Core.psm1'
Import-Module $corePath -Force
$script:QuotaPoolCoreModule = Get-Module TokenRader.Core

$sqliteDll = Join-Path $projectRoot 'indexer\System.Data.SQLite.dll'
$indexerDll = Join-Path $projectRoot 'indexer\TokenRader.Indexer.dll'
if ($null -eq ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
if ($null -eq ('TokenRaderIndexer' -as [type])) { Add-Type -Path $indexerDll }

# These tests deliberately use only a synthetic in-memory index.  No account,
# auth, session-file, or live-log APIs are called.
$db = [System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
$db.Open()
try {
    [TokenRaderIndexer]::CreateSchema($db)
    # Core canonicalizes offset-map keys as filesystem paths.  Use a synthetic
    # absolute path so the in-memory row and the Core lookup have the same key;
    # no file is created or read.
    $path = Join-Path $projectRoot 'synthetic-quota-pool.jsonl'
    $reset = 1900000000L
    $codexAt = [DateTimeOffset]::Parse('2030-03-01T00:00:10Z')
    $bengalAt = [DateTimeOffset]::Parse('2030-03-01T00:00:20Z')

    # The regular Codex pool is older (74% weekly).  A newer model-specific
    # pool has a 0% weekly snapshot and a five-hour snapshot; it must remain in
    # SQLite but must not become the displayed regular-pool result.
    Add-QuotaPoolRow $db 'quota-pool-codex' $codexAt.ToString('o') $path 10 'codex' `
        -WeeklyUsed 74.0 -WeeklyWindow 10080 -WeeklyReset $reset
    Add-QuotaPoolRow $db 'quota-pool-bengal' $bengalAt.ToString('o') $path 20 'codex_bengalfox0' `
        -FiveHourUsed 18.0 -FiveHourWindow 300 -FiveHourReset $reset `
        -WeeklyUsed 0.0 -WeeklyWindow 10080 -WeeklyReset $reset

    $beforeRows = Get-QuotaPoolRowCount -Connection $db
    Assert-QuotaPool ($beforeRows -eq 2) 'synthetic fixture did not create both quota-pool rows'

    # This is the production indexed Core path.  It must explicitly select the
    # regular Codex pool, even though that pool has the older timestamp.
    $ends = @{ $path = 100L }
    $indexed = & $script:QuotaPoolCoreModule {
        param($connection, $offsets)
        Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $connection -EndOffsets $offsets
    } $db $ends
    Assert-QuotaPool ($null -ne $indexed) 'indexed Core path returned no regular-pool result'
    Assert-QuotaPool ($null -eq $indexed.FiveHour) 'model-specific five-hour pool leaked into the regular card'
    Assert-QuotaPool ($null -ne $indexed.Weekly -and [double]$indexed.Weekly.UsedPercent -eq 74.0) `
        'indexed Core path selected newer model-specific weekly 0% instead of Codex 74%'
    Assert-QuotaPool ([string]$indexed.Weekly.LimitId -ieq 'codex') 'indexed Core result was not tagged as Codex'

    $afterRows = Get-QuotaPoolRowCount -Connection $db
    $otherRows = Get-QuotaPoolRowCount -Connection $db -Where " WHERE rate_limit_id='codex_bengalfox0'"
    Assert-QuotaPool ($afterRows -eq $beforeRows -and $otherRows -eq 1) `
        'pool filtering deleted or rewrote the model-specific token row'

    # A database containing only another pool is not a regular-pool snapshot;
    # the production indexed query must return no displayable windows.
    $otherOnly = [System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;')
    $otherOnly.Open()
    try {
        [TokenRaderIndexer]::CreateSchema($otherOnly)
        Add-QuotaPoolRow $otherOnly 'quota-pool-other-only' $bengalAt.ToString('o') $path 20 'codex_bengalfox0' `
            -FiveHourUsed 18.0 -FiveHourWindow 300 -FiveHourReset $reset `
            -WeeklyUsed 0.0 -WeeklyWindow 10080 -WeeklyReset $reset
        $onlyOther = & $script:QuotaPoolCoreModule {
            param($connection, $offsets)
            Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $connection -EndOffsets $offsets
        } $otherOnly $ends
        Assert-QuotaPool ($null -eq $onlyOther) 'other-pool-only index produced a displayable regular quota'
        Assert-QuotaPool ((Get-QuotaPoolRowCount -Connection $otherOnly) -eq 1) 'other-pool-only row was removed'
    } finally {
        $otherOnly.Dispose()
    }

    # The rows converter keeps its old no-filter behavior for callers that
    # explicitly need every pool.  The indexed production wrapper supplies the
    # Codex filter above.
    $allRows = [TokenRaderIndexer]::QueryLatestRateLimitsByOffsets($db, @{ $path = 0L }, $ends)
    $unfiltered = & $script:QuotaPoolCoreModule {
        param($table)
        ConvertFrom-TokenRaderRateLimitRows -Table $table
    } $allRows
    Assert-QuotaPool ($null -ne $unfiltered -and $null -ne $unfiltered.Weekly -and
        [double]$unfiltered.Weekly.UsedPercent -eq 0.0 -and
        [string]$unfiltered.Weekly.LimitId -ieq 'codex_bengalfox0') `
        'rows converter default filter was not backward-compatible'
} finally {
    $db.Dispose()
}

# Pure converter coverage: an explicit Codex pool wins over a newer other
# pool, while a legacy no-id set is accepted only when every candidate is
# legacy.  A blank candidate must not silently fall back when any explicit
# other-pool id is present.
$blankLegacy = [pscustomobject]@{
    WindowKind = 'Weekly'
    Window = New-QuotaPoolWindow 41.0 '2030-03-02T00:00:10Z' ''
    Metadata = [pscustomobject]@{
        LimitId = ''; PlanType = 'pro'; LimitName = ''; IndividualLimit = $null
        RateLimitReachedType = ''; SpendControlReached = $null
        CreditsBalance = $null; CreditsHas = $null; CreditsUnlimited = $null
    }
    RecordId = 1L
}
$codexCandidate = [pscustomobject]@{
    WindowKind = 'Weekly'
    Window = New-QuotaPoolWindow 74.0 '2030-03-02T00:00:20Z' 'codex'
    Metadata = [pscustomobject]@{
        LimitId = 'codex'; PlanType = 'pro'; LimitName = ''; IndividualLimit = $null
        RateLimitReachedType = ''; SpendControlReached = $null
        CreditsBalance = $null; CreditsHas = $null; CreditsUnlimited = $null
    }
    RecordId = 2L
}
$otherCandidate = [pscustomobject]@{
    WindowKind = 'Weekly'
    Window = New-QuotaPoolWindow 0.0 '2030-03-02T00:00:30Z' 'codex_bengalfox0'
    Metadata = [pscustomobject]@{
        LimitId = 'codex_bengalfox0'; PlanType = 'pro'; LimitName = ''; IndividualLimit = $null
        RateLimitReachedType = ''; SpendControlReached = $null
        CreditsBalance = $null; CreditsHas = $null; CreditsUnlimited = $null
    }
    RecordId = 3L
}

$legacyOnly = & $script:QuotaPoolCoreModule {
    param($candidates)
    ConvertFrom-TokenRaderRateLimitCandidates -Candidates $candidates -LimitId 'codex'
} @($blankLegacy)
Assert-QuotaPool ($null -ne $legacyOnly -and $null -ne $legacyOnly.Weekly -and
    [double]$legacyOnly.Weekly.UsedPercent -eq 41.0) `
    'all-legacy empty pool candidates were not accepted by an explicit Codex filter'

$mixedBlankOther = & $script:QuotaPoolCoreModule {
    param($candidates)
    ConvertFrom-TokenRaderRateLimitCandidates -Candidates $candidates -LimitId 'codex'
} @($blankLegacy, $otherCandidate)
Assert-QuotaPool ($null -eq $mixedBlankOther) `
    'legacy empty candidate fell back when an explicit non-Codex pool was present'

$explicitCodexWins = & $script:QuotaPoolCoreModule {
    param($candidates)
    ConvertFrom-TokenRaderRateLimitCandidates -Candidates $candidates -LimitId 'codex'
} @($blankLegacy, $codexCandidate, $otherCandidate)
Assert-QuotaPool ($null -ne $explicitCodexWins -and $null -ne $explicitCodexWins.Weekly -and
    [double]$explicitCodexWins.Weekly.UsedPercent -eq 74.0 -and
    [string]$explicitCodexWins.Weekly.LimitId -ieq 'codex') `
    'explicit Codex filter did not win over newer other-pool and legacy candidates'

# The fast token-line parser must carry the pool id through both the enclosing
# metadata and the parsed window; otherwise a later Core filter cannot tell a
# model-specific snapshot from the regular pool.
$fastLine = '{"timestamp":"2030-03-02T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2}},"rate_limits":{"plan_type":"pro","limit_id":"codex_bengalfox0","primary":{"used_percent":0,"window_minutes":300,"resets_at":1900000000}}}}'
$fastEvent = & $script:QuotaPoolCoreModule {
    param($line)
    ConvertFrom-TokenRaderTokenLineFast -LineText $line -Model 'gpt-5.6-sol'
} $fastLine
Assert-QuotaPool ($null -ne $fastEvent -and $null -ne $fastEvent.RateLimits -and
    [string]$fastEvent.RateLimits.LimitId -ieq 'codex_bengalfox0' -and
    $null -ne $fastEvent.RateLimits.FiveHour -and
    [string]$fastEvent.RateLimits.FiveHour.LimitId -ieq 'codex_bengalfox0') `
    'fast token-line parser dropped the explicit non-Codex pool id'

# UI extraction keeps this test independent of WPF startup.  Merge must drop
# model-specific windows before state can expose them, and estimate matching
# must reject an explicitly non-Codex estimate.
$uiSource = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $projectRoot 'TokenRader.ps1')
foreach ($name in @('Merge-LatestRateLimits', 'Test-TokenRaderQuotaEstimateMatchesWindow')) {
    $match = [regex]::Match($uiSource, '(?s)function ' + $name + '\b.*?(?=\r?\nfunction |\z)')
    if (-not $match.Success) { throw ('QUOTA POOL TEST FAILED: missing production UI function ' + $name) }
    Invoke-Expression $match.Value
}

$uiNow = [DateTimeOffset]::Parse('2030-03-03T00:00:00Z')
$uiReset = $uiNow.AddDays(5)
$uiOtherFive = New-QuotaPoolWindow 18.0 $uiNow.ToString('o') 'codex_bengalfox0' 'pro' 300 $reset
$uiCodexWeekly = New-QuotaPoolWindow 74.0 $uiNow.ToString('o') 'codex' 'pro' 10080 $reset
$script:State = @{
    RateLimits = $null
    QuotaPlanSelection = ''
}
Merge-LatestRateLimits -Candidate ([pscustomobject]@{
        FiveHour = $uiOtherFive
        Weekly = $uiCodexWeekly
        ObservedAt = $uiNow
        PlanType = 'pro'
    })
Assert-QuotaPool ($null -ne $script:State.RateLimits -and $null -eq $script:State.RateLimits.FiveHour -and
    $null -ne $script:State.RateLimits.Weekly -and [string]$script:State.RateLimits.Weekly.LimitId -ieq 'codex') `
    'UI merge exposed a non-Codex five-hour window'

$uiWindow = New-QuotaPoolWindow 74.0 $uiNow.ToString('o') 'codex' 'pro' 10080 $reset
$uiOtherEstimate = [pscustomobject]@{
    TotalUsd = 12.0
    UsedUsd = 1.0
    RemainingUsd = 11.0
    WindowMinutes = 10080
    PlanType = 'pro'
    LimitId = 'codex_bengalfox0'
    ResetsAt = $uiReset
}
Assert-QuotaPool (-not (Test-TokenRaderQuotaEstimateMatchesWindow -Estimate $uiOtherEstimate -Window $uiWindow)) `
    'UI estimate matcher accepted an explicitly non-Codex estimate'

Write-Output 'QUOTA_POOL_TESTS_PASSED'
