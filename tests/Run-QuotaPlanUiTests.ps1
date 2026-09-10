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
$script:ManualIntervalRefreshes = 0
$script:AutomaticIntervalRefreshes = 0
function Update-QuotaCards { $script:QuotaCardRefreshes++ }
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
    $cache = [pscustomobject]@{ Signature = 'old-cache' }
    $limits = [pscustomobject]@{ PlanType = 'old-plan'; FiveHour = $null; Weekly = $null }
    $script:State = @{
        UiState = $UiState
        IntervalComputing = $IntervalComputing
        QuotaPlanSelection = 'old-plan'
        RateLimits = $limits
        QuotaEstimates = $estimate
        QuotaEstimateAccountIdentity = 'old-account'
        QuotaDiagnostics = [pscustomobject]@{ Status = 'old' }
        IntervalCache = $cache
        IntervalBaseline = if ($WithBaseline) { $baseline } else { $null }
        IntervalResult = $result
        QuotaCalibrationMessage = 'old-message'
    }
    $script:QuotaPlanButton = [pscustomobject]@{ Content = 'old button content' }
    $script:QuotaCardRefreshes = 0
    $script:ManualIntervalRefreshes = 0
    $script:AutomaticIntervalRefreshes = 0
    $script:SelectPlanCalls = @()
    [pscustomobject]@{ Baseline = $baseline; Result = $result; Estimate = $estimate; Cache = $cache; Limits = $limits }
}

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
Assert-QuotaPlanUi ([object]::ReferenceEquals($script:State.IntervalBaseline, $fixture.Baseline)) 'selection changed IntervalBaseline'
Assert-QuotaPlanUi ([object]::ReferenceEquals($script:State.IntervalResult, $fixture.Result)) 'selection changed the main IntervalResult'
Assert-QuotaPlanUi ($script:QuotaPlanButton.Content -match 'candidate' -and $script:QuotaPlanButton.Content -match '已确认') 'selected plan was not shown on QuotaPlanButton'
Assert-QuotaPlanUi ($script:QuotaCardRefreshes -eq 1) 'selection did not refresh quota cards exactly once'
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
}

$fixture = New-QuotaPlanUiState -UiState 'Ready' -IntervalComputing:$true
$beforeRateLimits = $script:State.RateLimits
Assert-QuotaPlanUi (-not (Set-TokenRaderQuotaPlanSelection -PlanType 'candidate')) 'IntervalComputing allowed a plan mutation'
Assert-QuotaPlanUi ([object]::ReferenceEquals($script:State.RateLimits, $beforeRateLimits) -and
    $script:SelectPlanCalls.Count -eq 0 -and $script:QuotaCardRefreshes -eq 0) 'IntervalComputing changed quota state or repainted the UI'

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

Write-Output 'QUOTA_PLAN_UI_TESTS_PASSED'
