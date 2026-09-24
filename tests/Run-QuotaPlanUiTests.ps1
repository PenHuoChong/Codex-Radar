[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-QuotaPlanUi {
    param(
        [bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw ('QUOTA PLAN UI TEST FAILED: ' + $Message) }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$tokenRaderSource = [IO.File]::ReadAllText((Join-Path $projectRoot 'TokenRader.ps1'))

$labelMatch = [regex]::Match(
    $tokenRaderSource,
    '(?s)function Update-TokenRaderQuotaPlanLabel\b.*?(?=\r?\nfunction |\z)'
)
Assert-QuotaPlanUi $labelMatch.Success 'automatic quota-plan label helper was not found'
Invoke-Expression $labelMatch.Value
$quotaCardsMatch = [regex]::Match(
    $tokenRaderSource,
    '(?s)function Update-QuotaCards\b.*?(?=\r?\nfunction |\z)'
)
Assert-QuotaPlanUi ($quotaCardsMatch.Success -and $quotaCardsMatch.Value -match 'Update-TokenRaderQuotaPlanLabel') 'quota-card refresh does not update the plan label'

# Extract only the pure setter, as the measurement UI tests do.  Loading the
# application would run startup refresh and could touch the user's auth/index;
# this test intentionally exercises neither path.
$setterMatch = [regex]::Match(
    $tokenRaderSource,
    '(?s)function Set-TokenRaderQuotaPlanSelection\b.*?(?=\r?\nfunction |\z)'
)
Assert-QuotaPlanUi $setterMatch.Success 'production quota-plan setter was not found'
$setterSource = $setterMatch.Value
Invoke-Expression $setterSource

# Keep the contract visible in the test even if the implementation is
# refactored: selection must go through the exported pure helper and repaint
# the quota/interval views without touching the main interval result.
Assert-QuotaPlanUi ($setterSource -match '\bSelect-TokenRaderQuotaPlan\b') 'setter bypasses Select-TokenRaderQuotaPlan'
Assert-QuotaPlanUi ($setterSource -match '\bUpdate-QuotaCards\b') 'setter does not refresh quota cards'
Assert-QuotaPlanUi ($setterSource -match 'Update-QuotaCards\s+-DisplayOnly') 'same-plan confirmation does not request display-only cards'
Assert-QuotaPlanUi ($quotaCardsMatch.Value -match 'if\s*\(-not\s+\$DisplayOnly\)') 'display-only card refresh can mutate retained quota evidence'
Assert-QuotaPlanUi ($setterSource -match 'Update-IntervalView\s+-Manual') 'setter does not request a manual interval refresh'
Assert-QuotaPlanUi ($setterSource -notmatch 'State\.IntervalResult\s*=') 'setter rewrites the main interval result'
Assert-QuotaPlanUi ($setterSource -notmatch 'State\.IntervalBaseline\s*=') 'setter rewrites the measurement baseline'

# A local mock is deliberate: it proves the UI setter delegates plan
# filtering, while keeping this test independent from auth, the index, and
# any real quota snapshot source.
$script:SelectPlanCalls = @()
function Select-TokenRaderQuotaPlan {
    param($RateLimits, [string]$PlanType)
    $script:SelectPlanCalls += [pscustomobject]@{ RateLimits = $RateLimits; PlanType = $PlanType }
    [pscustomobject]@{
        Source = $RateLimits
        SelectedPlanType = $PlanType
        SelectedBy = 'synthetic-ui-test'
    }
}

$script:QuotaCardRefreshes = 0
$script:DisplayOnlyCardRefreshes = 0
$script:ManualIntervalRefreshes = 0
$script:AutomaticIntervalRefreshes = 0
function Update-QuotaCards {
    param([switch]$DisplayOnly)
    $script:QuotaCardRefreshes++
    if ($DisplayOnly) { $script:DisplayOnlyCardRefreshes++ }
}
function Update-IntervalView {
    param([switch]$Manual)
    if ($Manual) { $script:ManualIntervalRefreshes++ }
    else { $script:AutomaticIntervalRefreshes++ }
}

function New-QuotaPlanUiState {
    param(
        [string]$UiState = 'Ready',
        [bool]$IntervalComputing = $false,
        [bool]$WithBaseline = $true
    )
    $baseline = [pscustomobject]@{ Kind = 'synthetic-baseline' }
    $result = [pscustomobject]@{ Kind = 'synthetic-interval-result' }
    $estimate = [pscustomobject]@{ Weekly = 'old-estimate' }
    $diagnostics = [pscustomobject]@{ Weekly = 'old-weekly-diagnostic' }
    $cache = [pscustomobject]@{ Signature = 'old-cache' }
    $frozenEnd = [pscustomobject]@{ Kind = 'synthetic-frozen-end' }
    $limits = [pscustomobject]@{ PlanType = 'old-plan'; FiveHour = $null; Weekly = $null }
    $script:State = @{
        UiState = $UiState
        IntervalComputing = $IntervalComputing
        QuotaPlanSelection = 'old-plan'
        RateLimits = $limits
        QuotaEstimates = $estimate
        QuotaEstimateAccountIdentity = 'old-account'
        QuotaDiagnostics = $diagnostics
        FiveHourNotApplicable = $false
        IntervalCache = $cache
        IntervalBaseline = if ($WithBaseline) { $baseline } else { $null }
        IntervalEnd = $frozenEnd
        IntervalResult = $result
        QuotaCalibrationMessage = 'old-message'
    }
    $script:QuotaPlanButton = [pscustomobject]@{ Content = 'old button content' }
    $script:QuotaCardRefreshes = 0
    $script:DisplayOnlyCardRefreshes = 0
    $script:ManualIntervalRefreshes = 0
    $script:AutomaticIntervalRefreshes = 0
    $script:SelectPlanCalls = @()
    [pscustomobject]@{ Baseline = $baseline; Result = $result; End = $frozenEnd; Estimate = $estimate; Diagnostics = $diagnostics; Cache = $cache; Limits = $limits }
}

# Confirming the same normalized plan, including either direction of the
# display-only 5-hour switch, must retain weekly evidence and the frozen
# measurement state. It must not queue an interval recomputation.
$fixture = New-QuotaPlanUiState
foreach ($choice in @(
    [pscustomobject]@{ Plan = ' OLD-PLAN '; NoFive = $true },
    [pscustomobject]@{ Plan = 'old-plan'; NoFive = $false },
    [pscustomobject]@{ Plan = '  Old-Plan  '; NoFive = $false }
)) {
    $beforeCards = $script:QuotaCardRefreshes
    Assert-QuotaPlanUi (Set-TokenRaderQuotaPlanSelection -PlanType $choice.Plan -FiveHourNotApplicable $choice.NoFive) 'same-plan confirmation was rejected'
    Assert-QuotaPlanUi ([bool]$script:State.FiveHourNotApplicable -eq $choice.NoFive) 'display-only 5-hour choice was not updated'
    Assert-QuotaPlanUi ([string]$script:State.QuotaPlanSelection -eq 'old-plan' -and
        [object]::ReferenceEquals($script:State.RateLimits, $fixture.Limits) -and
        [object]::ReferenceEquals($script:State.QuotaEstimates, $fixture.Estimate) -and
        [object]::ReferenceEquals($script:State.QuotaDiagnostics, $fixture.Diagnostics) -and
        [string]$script:State.QuotaEstimateAccountIdentity -eq 'old-account' -and
        [object]::ReferenceEquals($script:State.IntervalCache, $fixture.Cache) -and
        [object]::ReferenceEquals($script:State.IntervalBaseline, $fixture.Baseline) -and
        [object]::ReferenceEquals($script:State.IntervalEnd, $fixture.End) -and
        [object]::ReferenceEquals($script:State.IntervalResult, $fixture.Result) -and
        [string]$script:State.QuotaCalibrationMessage -eq 'old-message') 'same-plan confirmation changed quota evidence or measurement state'
    Assert-QuotaPlanUi ($script:SelectPlanCalls.Count -eq 0 -and
        $script:ManualIntervalRefreshes -eq 0 -and $script:AutomaticIntervalRefreshes -eq 0 -and
        $script:QuotaCardRefreshes -eq ($beforeCards + 1) -and
        $script:DisplayOnlyCardRefreshes -eq $script:QuotaCardRefreshes) 'same-plan confirmation recomputed instead of repainting cards'
}

# Automatic mode is also a normalized same-plan confirmation.
$fixture = New-QuotaPlanUiState
$script:State.QuotaPlanSelection = ''
Assert-QuotaPlanUi (Set-TokenRaderQuotaPlanSelection -PlanType '  ' -FiveHourNotApplicable $true) 'unchanged automatic mode was rejected'
Assert-QuotaPlanUi ($script:SelectPlanCalls.Count -eq 0 -and $script:ManualIntervalRefreshes -eq 0 -and
    [object]::ReferenceEquals($script:State.QuotaEstimates, $fixture.Estimate) -and
    [object]::ReferenceEquals($script:State.IntervalEnd, $fixture.End)) 'unchanged automatic mode invalidated evidence or recomputed'

# A normal selection is normalized, delegated, and only invalidated quota
# caches are discarded. The token interval result and its immutable baseline
# must survive the plan choice.
$fixture = New-QuotaPlanUiState
$ok = Set-TokenRaderQuotaPlanSelection -PlanType '  Candidate  '
Assert-QuotaPlanUi $ok 'candidate plan selection was rejected'
Assert-QuotaPlanUi ([string]$script:State.QuotaPlanSelection -eq 'candidate') 'plan selection was not normalized'
Assert-QuotaPlanUi ($script:SelectPlanCalls.Count -eq 1 -and
    [string]$script:SelectPlanCalls[0].PlanType -eq 'candidate' -and
    [object]::ReferenceEquals($script:SelectPlanCalls[0].RateLimits, $fixture.Limits)) 'selection did not use the current RateLimits through the pure helper'
Assert-QuotaPlanUi ([string]$script:State.RateLimits.SelectedPlanType -eq 'candidate') 'helper-selected RateLimits were not retained'
Assert-QuotaPlanUi ($null -eq $script:State.QuotaEstimates -and $null -eq $script:State.IntervalCache) 'old quota estimate/cache survived selection'
Assert-QuotaPlanUi ($null -eq $script:State.QuotaDiagnostics -and
    [string]$script:State.QuotaEstimateAccountIdentity -eq '') 'changed plan retained old quota diagnostics or account binding'
Assert-QuotaPlanUi ([object]::ReferenceEquals($script:State.IntervalBaseline, $fixture.Baseline)) 'selection changed IntervalBaseline'
Assert-QuotaPlanUi ([object]::ReferenceEquals($script:State.IntervalEnd, $fixture.End)) 'selection changed the frozen ending'
Assert-QuotaPlanUi ([object]::ReferenceEquals($script:State.IntervalResult, $fixture.Result)) 'selection changed the main IntervalResult'
Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match 'candidate' -and $script:QuotaPlanButton.Content -match '已确认') 'selected plan was not shown on QuotaPlanButton'
Assert-QuotaPlanUi ($script:QuotaCardRefreshes -eq 1) 'selection did not refresh quota cards exactly once'
Assert-QuotaPlanUi ($script:DisplayOnlyCardRefreshes -eq 0) 'changed plan used display-only card refresh'
Assert-QuotaPlanUi ($script:ManualIntervalRefreshes -eq 1 -and $script:AutomaticIntervalRefreshes -eq 0) 'selection did not perform one manual interval refresh'

# Clearing the selection follows the same safe path and restores the automatic
# label. It still preserves the measurement objects.
$fixture = New-QuotaPlanUiState
$ok = Set-TokenRaderQuotaPlanSelection -PlanType ''
Assert-QuotaPlanUi $ok 'clearing the plan selection was rejected'
Assert-QuotaPlanUi ([string]$script:State.QuotaPlanSelection -eq '') 'clearing selection did not store an empty plan'
Assert-QuotaPlanUi ([string]$script:SelectPlanCalls[0].PlanType -eq '') 'clearing selection did not delegate an empty plan'
Assert-QuotaPlanUi ([string]$script:QuotaPlanButton.Content -eq '当前套餐：自动识别…') 'clearing selection did not restore the automatic button label'
Assert-QuotaPlanUi ([object]::ReferenceEquals($script:State.IntervalBaseline, $fixture.Baseline) -and
    [object]::ReferenceEquals($script:State.IntervalResult, $fixture.Result)) 'clearing selection changed measurement state'
Assert-QuotaPlanUi ($script:ManualIntervalRefreshes -eq 1) 'clearing selection did not refresh a baselined interval manually'

# Without a baseline the setter still updates cards, but must not ask the
# interval view to render a manual result.
$fixture = New-QuotaPlanUiState -WithBaseline:$false
$ok = Set-TokenRaderQuotaPlanSelection -PlanType 'candidate'
Assert-QuotaPlanUi $ok 'selection without a baseline was rejected'
Assert-QuotaPlanUi ($script:ManualIntervalRefreshes -eq 0) 'selection without a baseline refreshed the interval view'
Assert-QuotaPlanUi ($script:QuotaCardRefreshes -eq 1) 'selection without a baseline did not refresh quota cards'
Assert-QuotaPlanUi ([object]::ReferenceEquals($script:State.IntervalResult, $fixture.Result)) 'selection without a baseline changed IntervalResult'

# A state transition or in-flight computation is a hard no-op: no helper,
# cache mutation, button repaint, or view refresh is allowed.
foreach ($blockedState in @('Starting', 'Stopping', 'ComputingFinal')) {
    $fixture = New-QuotaPlanUiState -UiState $blockedState
    $beforeButton = [string]$script:QuotaPlanButton.Content
    $beforeSelection = [string]$script:State.QuotaPlanSelection
    $beforeEstimate = $script:State.QuotaEstimates
    $beforeCache = $script:State.IntervalCache
    $beforeRateLimits = $script:State.RateLimits
    Assert-QuotaPlanUi (-not (Set-TokenRaderQuotaPlanSelection -PlanType 'candidate')) "$blockedState allowed a plan mutation"
    Assert-QuotaPlanUi ([string]$script:State.QuotaPlanSelection -eq $beforeSelection -and
        [object]::ReferenceEquals($script:State.QuotaEstimates, $beforeEstimate) -and
        [object]::ReferenceEquals($script:State.IntervalCache, $beforeCache) -and
        [object]::ReferenceEquals($script:State.RateLimits, $beforeRateLimits) -and
        [string]$script:QuotaPlanButton.Content -eq $beforeButton) "$blockedState changed quota state"
    Assert-QuotaPlanUi ($script:SelectPlanCalls.Count -eq 0 -and $script:QuotaCardRefreshes -eq 0 -and
        $script:ManualIntervalRefreshes -eq 0) "$blockedState invoked downstream UI work"
    Assert-QuotaPlanUi (-not (Set-TokenRaderQuotaPlanSelection -PlanType ' OLD-PLAN ' -FiveHourNotApplicable $true)) "$blockedState allowed a display-only mutation"
    Assert-QuotaPlanUi (-not [bool]$script:State.FiveHourNotApplicable -and $script:QuotaCardRefreshes -eq 0) "$blockedState changed the display-only flag"
}

$fixture = New-QuotaPlanUiState -UiState 'Ready' -IntervalComputing:$true
$beforeRateLimits = $script:State.RateLimits
Assert-QuotaPlanUi (-not (Set-TokenRaderQuotaPlanSelection -PlanType 'candidate')) 'IntervalComputing allowed a plan mutation'
Assert-QuotaPlanUi ([object]::ReferenceEquals($script:State.RateLimits, $beforeRateLimits) -and
    $script:SelectPlanCalls.Count -eq 0 -and $script:QuotaCardRefreshes -eq 0) 'IntervalComputing changed quota state or repainted the UI'

function New-AutoPlanLabelWindow {
    param(
        [string]$PlanType,
        [string]$LimitId = 'codex',
        [DateTimeOffset]$ResetsAt = [DateTimeOffset]::Now.AddHours(2),
        [bool]$ScopeConflict = $false,
        [string[]]$ConflictPlans = @()
    )
    [pscustomobject]@{
        PlanType = $PlanType
        LimitId = $LimitId
        ResetsAt = $ResetsAt
        WindowMinutes = 300
        ResetIdentity = 'synthetic-current-cycle'
        ScopeConflict = $ScopeConflict
        ConflictPlans = @($ConflictPlans)
        ScopeCandidates = @(
            foreach ($plan in $ConflictPlans) {
                [pscustomobject]@{ WindowKind = 'FiveHour'; WindowMinutes = 300; ResetIdentity = 'synthetic-current-cycle'; LimitId = $LimitId; PlanType = $plan }
            }
        )
    }
}

function Set-AutoPlanLabelFixture {
    param($RateLimits, [string]$Selection = '')
    $script:State = @{ RateLimits = $RateLimits; QuotaPlanSelection = $Selection }
    $script:QuotaPlanButton = [pscustomobject]@{ Content = 'old label' }
}

$future = [DateTimeOffset]::Now.AddHours(2)
$proLimits = [pscustomobject]@{
    FiveHour = New-AutoPlanLabelWindow -PlanType 'pro' -ResetsAt $future
    Weekly = [pscustomobject]@{ PlanType = 'pro'; LimitId = 'codex'; ResetsAt = $future.AddDays(3); ScopeConflict = $false }
}
Set-AutoPlanLabelFixture -RateLimits $proLimits
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ([string]$script:QuotaPlanButton.Content -eq '当前套餐：Pro（pro；档位未提供，自动）') 'active pro was not identified without inventing a tier'

# Replacing the accepted snapshot must replace the automatic label too; the
# helper must not retain an old plan across a current-plan switch.
$teamLimits = [pscustomobject]@{
    FiveHour = New-AutoPlanLabelWindow -PlanType 'team' -ResetsAt $future
    Weekly = [pscustomobject]@{ PlanType = 'team'; LimitId = 'codex'; ResetsAt = $future.AddDays(3); ScopeConflict = $false }
}
Set-AutoPlanLabelFixture -RateLimits $teamLimits
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ([string]$script:QuotaPlanButton.Content -eq '当前套餐：Business（team，自动）') 'current plan switch retained the previous automatic label'

Set-AutoPlanLabelFixture -RateLimits $null
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ([string]$script:QuotaPlanButton.Content -match '自动识别' -and $script:QuotaPlanButton.Content -match '暂无有效窗口') 'missing quota data was not labeled as unavailable'

$conflictWindow = New-AutoPlanLabelWindow -PlanType 'pro-lite' -ResetsAt $future -ScopeConflict:$true -ConflictPlans @('pro', 'pro-lite')
$conflictLimits = [pscustomobject]@{ FiveHour = $conflictWindow; Weekly = $null }
Set-AutoPlanLabelFixture -RateLimits $conflictLimits
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ([string]$script:QuotaPlanButton.Content -match '冲突' -and
    [string]$script:QuotaPlanButton.Content -match 'pro' -and
    [string]$script:QuotaPlanButton.Content -match 'pro-lite' -and
    [string]$script:QuotaPlanButton.Content -notmatch '5x') 'plan conflict was hidden or a Pro tier was inferred'

$expiredWindow = New-AutoPlanLabelWindow -PlanType 'plus' -ResetsAt ([DateTimeOffset]::Now.AddMinutes(-1))
Set-AutoPlanLabelFixture -RateLimits ([pscustomobject]@{ FiveHour = $expiredWindow; Weekly = $null })
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ([string]$script:QuotaPlanButton.Content -match '自动识别' -and
    $script:QuotaPlanButton.Content -match '暂无有效窗口') 'an expired window was used for automatic plan identification'

$foreignWindow = New-AutoPlanLabelWindow -PlanType 'enterprise' -LimitId 'model-specialized' -ResetsAt $future
Set-AutoPlanLabelFixture -RateLimits ([pscustomobject]@{ FiveHour = $foreignWindow; Weekly = $null })
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ([string]$script:QuotaPlanButton.Content -match '暂无有效窗口') 'a non-codex pool was used for automatic plan identification'

# Manual selection keeps its historical raw, confirmed-plan label and takes
# precedence over any automatically inferred conflict.
Set-AutoPlanLabelFixture -RateLimits $conflictLimits -Selection 'pro-5x'
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ([string]$script:QuotaPlanButton.Content -eq '当前套餐：pro-5x（已确认）…') 'automatic labeling overrode the manual plan selection'

$unknownLimits = [pscustomobject]@{
    FiveHour = New-AutoPlanLabelWindow -PlanType 'pro-lite' -ResetsAt $future
    Weekly = $null
}
Set-AutoPlanLabelFixture -RateLimits $unknownLimits
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ([string]$script:QuotaPlanButton.Content -eq '当前套餐：pro-lite（自动）') 'an unrecognized variant was not preserved as raw text'

# XAML and account-switch contracts are checked as source/data only. No
# Refresh-Application call is made, so this test never reads real auth or an
# index database.
[xml]$xaml = [IO.File]::ReadAllText((Join-Path $projectRoot 'MainWindow.xaml'))
$quotaButton = $xaml.SelectSingleNode("//*[local-name()='Button' and @*[local-name()='Name']='QuotaPlanButton']")
Assert-QuotaPlanUi ($null -ne $quotaButton) 'QuotaPlanButton is missing from MainWindow.xaml'
Assert-QuotaPlanUi ([string]$quotaButton.Attributes['Content'].Value -eq '当前套餐：自动识别…') 'QuotaPlanButton has the wrong initial Content'
Assert-QuotaPlanUi ($tokenRaderSource -match '\$script:QuotaPlanButton\.Add_Click\s*\(\{\s*Show-TokenRaderQuotaPlanDialog') 'QuotaPlanButton click wiring is missing'

$refreshMatch = [regex]::Match($tokenRaderSource, '(?s)function Refresh-Application\b.*?(?=\r?\nfunction |\z)')
Assert-QuotaPlanUi $refreshMatch.Success 'Refresh-Application source was not found for account-switch contract check'
$refreshSource = $refreshMatch.Value
Assert-QuotaPlanUi ($refreshSource -match 'previousAccountIdentity' -and $refreshSource -match 'newAccountIdentity') 'account identity comparison is missing'
Assert-QuotaPlanUi ($refreshSource -match '\$script:State\.QuotaPlanSelection\s*=\s*[''\"]{2}') 'account switch does not clear QuotaPlanSelection'
Assert-QuotaPlanUi ($refreshSource -match [regex]::Escape("QuotaPlanButton.Content = '当前套餐：自动识别…'")) 'account switch does not restore QuotaPlanButton Content'

$labelMatch = [regex]::Match($tokenRaderSource, '(?s)function Update-TokenRaderQuotaPlanLabel\b.*?(?=\r?\nfunction |\z)')
Assert-QuotaPlanUi $labelMatch.Success 'automatic plan label helper exists'
Invoke-Expression $labelMatch.Value
$cardMatch = [regex]::Match($tokenRaderSource, '(?s)function Update-QuotaCards\b.*?(?=\r?\nfunction |\z)')
Assert-QuotaPlanUi ($cardMatch.Value -match 'Update-TokenRaderQuotaPlanLabel') 'quota refresh updates plan label'
$script:State = @{ QuotaPlanSelection=''; RateLimits=$null }
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match '暂无有效窗口') 'missing data is explicit'
$window = [pscustomobject]@{ PlanType='pro'; LimitId='codex'; ResetsAt=[DateTimeOffset]::Now.AddDays(1); ScopeConflict=$false }
$script:State.RateLimits = [pscustomobject]@{ FiveHour=$null; Weekly=$window }
foreach ($plan in @('free','go','plus','pro','team','business','edu','enterprise','prolite','future-plan')) {
    $window.PlanType=$plan
    Update-TokenRaderQuotaPlanLabel
    Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match [regex]::Escape($plan) -and $script:QuotaPlanButton.Content -match '自动') ('identified raw plan retained: '+$plan)
    Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -notmatch '5x|20x') 'no inferred Pro multiplier'
}
$window.PlanType='pro'
$window.ScopeConflict=$true
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match '冲突') 'conflicting plan is not selected'
$window.ScopeConflict=$false
$other = [pscustomobject]@{ PlanType='team'; LimitId='codex'; ResetsAt=[DateTimeOffset]::Now.AddHours(1) }
$script:State.RateLimits.FiveHour=$other
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match '冲突') 'different active window plans conflict'
$other.ResetsAt=[DateTimeOffset]::Now.AddHours(-1)
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match 'Pro' -and $script:QuotaPlanButton.Content -notmatch '冲突') 'expired competing plan ignored'
$window.LimitId='other-pool'
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match '暂无有效窗口') 'foreign pool ignored'
$window.LimitId='codex';$window.ResetsAt=$null
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match '暂无有效窗口') 'missing reset does not prove current plan'
$script:State.QuotaPlanSelection='team'
Update-TokenRaderQuotaPlanLabel
Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match 'team' -and $script:QuotaPlanButton.Content -match '已确认') 'manual choice retained'
Write-Output 'QUOTA_PLAN_UI_TESTS_PASSED'
