[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PlanBinding {
    param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { throw ('QUOTA PLAN BINDING TEST FAILED: ' + $Message) }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'TokenRader.Core.psm1') -Force

$currentReset = [DateTimeOffset]::Parse('2030-06-01T05:00:00Z')
$oldReset = $currentReset.AddDays(-7)
$observed = [DateTimeOffset]::Parse('2030-06-01T00:00:00Z')
$currentIdentity = Get-TokenRaderResetIdentity -WindowMinutes 300 -ResetsAt $currentReset
$oldIdentity = Get-TokenRaderResetIdentity -WindowMinutes 300 -ResetsAt $oldReset

$rawSentinel = [pscustomobject]@{ Tag = 'raw-candidate-preserved' }
$weeklyIdentity = Get-TokenRaderResetIdentity -WindowMinutes 10080 -ResetsAt $currentReset.AddDays(7)
$fiveHour = [pscustomobject]@{
    UsedPercent = 11.0
    RemainingPercent = 89.0
    WindowMinutes = 300
    ResetsAt = $currentReset
    ResetIdentity = $currentIdentity
    ObservedAt = $observed
    PlanType = 'pro-lite'
    LimitId = 'synthetic-limit'
    ScopeConflict = $true
    ConflictDescription = 'synthetic pro/pro-lite conflict'
    ConflictPlans = @('pro', 'pro-lite')
    RawCandidates = @($rawSentinel)
    ScopeCandidates = @(
        [pscustomobject]@{ WindowKind = 'FiveHour'; WindowMinutes = 300; ResetIdentity = $currentIdentity; PlanType = 'pro'; LimitId = 'synthetic-limit'; UsedPercent = 3.0; ObservedAt = $observed.AddMinutes(-1); RecordId = 1L }
        [pscustomobject]@{ WindowKind = 'FiveHour'; WindowMinutes = 300; ResetIdentity = $currentIdentity; PlanType = 'pro-lite'; LimitId = 'synthetic-limit'; UsedPercent = 11.0; ObservedAt = $observed; RecordId = 2L }
        # A newer-looking row from a prior reset cycle must not win.
        [pscustomobject]@{ WindowKind = 'FiveHour'; WindowMinutes = 300; ResetIdentity = $oldIdentity; PlanType = 'pro'; LimitId = 'synthetic-limit'; UsedPercent = 99.0; ObservedAt = $observed.AddMinutes(1); RecordId = 3L }
    )
}
$weekly = [pscustomobject]@{
    UsedPercent = 21.0
    RemainingPercent = 79.0
    WindowMinutes = 10080
    ResetsAt = $currentReset.AddDays(7)
    ResetIdentity = $weeklyIdentity
    ObservedAt = $observed
    PlanType = 'pro'
    LimitId = 'synthetic-limit'
    ScopeConflict = $false
    ScopeCandidates = @(
        [pscustomobject]@{ WindowKind = 'Weekly'; WindowMinutes = 10080; ResetIdentity = $weeklyIdentity; PlanType = 'pro'; LimitId = 'synthetic-limit'; UsedPercent = 21.0; ObservedAt = $observed; RecordId = 4L }
    )
}
$rateLimits = [pscustomobject]@{
    ObservedAt = $observed
    PlanType = 'pro-lite'
    ScopeConflict = $true
    FiveHour = $fiveHour
    Weekly = $weekly
    ScopeCandidates = @($fiveHour.ScopeCandidates + $weekly.ScopeCandidates)
}

$previousIndexOverride = [Environment]::GetEnvironmentVariable('TOKEN_RADER_INDEX_DB', 'Process')
$sentinelIndexPath = Join-Path $env:TEMP ('token-rader-plan-binding-' + [Guid]::NewGuid().ToString('N') + '.db')
try {
    # The selector is pure: changing the index override cannot make it create
    # or open a database, and it never consults account/auth state.
    $env:TOKEN_RADER_INDEX_DB = $sentinelIndexPath
    $selected = Select-TokenRaderQuotaPlan -RateLimits $rateLimits -PlanType 'pro'
    Assert-PlanBinding (-not (Test-Path -LiteralPath $sentinelIndexPath)) 'selection touched the configured index path'
} finally {
    if ($null -eq $previousIndexOverride) { Remove-Item Env:TOKEN_RADER_INDEX_DB -ErrorAction SilentlyContinue }
    else { $env:TOKEN_RADER_INDEX_DB = $previousIndexOverride }
}

Assert-PlanBinding ($selected -ne $rateLimits) 'selection must clone the rate-limits object'
Assert-PlanBinding ([double]$selected.FiveHour.UsedPercent -eq 3.0) 'same-cycle pro candidate was not selected'
Assert-PlanBinding ([double]$selected.FiveHour.RemainingPercent -eq 97.0) 'remaining percent was not recomputed from selected usage'
Assert-PlanBinding ([string]$selected.FiveHour.PlanType -eq 'pro') 'selected window plan was not overridden'
Assert-PlanBinding (-not [bool]$selected.FiveHour.ScopeConflict -and [bool]$selected.FiveHour.PlanSelectionApplied) 'selected window stayed conflicted'
Assert-PlanBinding (-not [bool]$selected.ScopeConflict -and [bool]$selected.PlanSelectionApplied) 'selected rate-limits stayed conflicted'
Assert-PlanBinding ([string]$selected.PlanType -eq 'pro') 'top-level plan was not updated'
Assert-PlanBinding (@($selected.FiveHour.ScopeCandidates).Count -eq 3) 'scope candidates were not preserved'
Assert-PlanBinding ([string]$selected.FiveHour.RawCandidates[0].Tag -eq 'raw-candidate-preserved') 'raw candidates were not preserved'
Assert-PlanBinding ([double]$rateLimits.FiveHour.UsedPercent -eq 11.0 -and [bool]$rateLimits.ScopeConflict) 'pure selector mutated its input'

$missing = Select-TokenRaderQuotaPlan -RateLimits $rateLimits -PlanType 'team'
Assert-PlanBinding ([double]$missing.FiveHour.UsedPercent -eq 11.0) 'missing plan fell back to another plan'
Assert-PlanBinding ([bool]$missing.ScopeConflict -and [string]$missing.ScopeConflictReason -eq 'selected_plan_missing') 'missing plan did not report selected_plan_missing'
Assert-PlanBinding ($null -eq (Get-TokenRaderQuotaEstimate -StartRateLimits $missing -EndRateLimits $missing -IntervalCost 1.0 -CostComplete $true).FiveHour) 'missing plan was treated as usable quota evidence'

$weeklyMissing = Select-TokenRaderQuotaPlan -RateLimits $rateLimits -PlanType 'pro-lite'
Assert-PlanBinding (-not [bool]$weeklyMissing.FiveHour.ScopeConflict -and [double]$weeklyMissing.FiveHour.UsedPercent -eq 11.0) 'valid five-hour plan was incorrectly discarded with another window missing'
Assert-PlanBinding ([bool]$weeklyMissing.Weekly.ScopeConflict -and [string]$weeklyMissing.Weekly.ScopeConflictReason -eq 'selected_plan_missing') 'missing weekly plan was not isolated'

$restored = Select-TokenRaderQuotaPlan -RateLimits $selected -PlanType ''
Assert-PlanBinding ([bool]$restored.ScopeConflict -and [double]$restored.FiveHour.UsedPercent -eq 11.0) 'automatic mode did not restore the original conflict'

$coreSource = [IO.File]::ReadAllText((Join-Path $projectRoot 'TokenRader.Core.psm1'))
$selectorMatch = [regex]::Match($coreSource, '(?s)function Select-TokenRaderQuotaPlan\b.*?(?=\r?\nfunction |\z)')
Assert-PlanBinding $selectorMatch.Success 'selector function source was not found'
Assert-PlanBinding ($selectorMatch.Value -notmatch 'Get-TokenRaderAccount|Open-TokenRaderIndex|Get-ChildItem|auth\.json|SQLiteConnection') 'selector reads private/auth data or opens the database'

Write-Output 'QUOTA_PLAN_BINDING_TESTS_PASSED'
