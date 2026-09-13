[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
# Loads real UI functions with synthetic controls and no application startup.
. (Join-Path $PSScriptRoot 'Run-MeasurementPricingUiTests.ps1')
function Assert-Refresh($ok,$message){if(!$ok){throw ('QUOTA REFRESH TEST: '+$message)}}
$module=Get-Module TokenRader.Core
$at=[DateTimeOffset]::Now;$reset=$at.AddDays(5)
foreach($value in @($null,'','NaN','Infinity','bad',-1,101,$true,0)) {
    $parsed=& $module {param($v,$at,$reset) ConvertTo-TokenRaderRateLimits -RawRateLimits ([pscustomobject]@{plan_type='pro';primary=[pscustomobject]@{used_percent=$v;window_minutes=10080;resets_at=$reset.ToUnixTimeSeconds()}}) -ObservedAt $at} $value $at $reset
    $valid=$null-ne$value -and $value -isnot [bool] -and [string]$value-eq'0'
    Assert-Refresh (($null-ne$parsed.Weekly)-eq$valid) 'invalid percent became a window or valid zero was lost'
    $inner='"used_percent":'+($value|ConvertTo-Json -Compress)+',"window_minutes":10080,"resets_at":'+$reset.ToUnixTimeSeconds()
    $fast=& $module {param($text,$at) ConvertFrom-TokenRaderRateWindowTextFast -InnerText $text -ObservedAt $at} $inner $at
    Assert-Refresh (($null-ne$fast)-eq$valid) 'fast parser disagreed on percent validity'
}
function New-RefreshLimits($percent,$observed,$reset) {
    $identity=Get-TokenRaderResetIdentity -WindowMinutes 10080 -ResetsAt $reset
    $w=[pscustomobject]@{PlanType='pro';UsedPercent=$percent;RemainingPercent=(100-$percent);ObservedAt=$observed;ResetsAt=$reset;ResetIdentity=$identity;WindowMinutes=10080;LimitId='synthetic';ScopeConflict=$false;ScopeCandidates=@([pscustomobject]@{PlanType='pro';UsedPercent=$percent;ObservedAt=$observed;ResetIdentity=$identity;WindowMinutes=10080;LimitId='synthetic'})}
    [pscustomobject]@{FiveHour=$null;Weekly=$w;ObservedAt=$observed;PlanType='pro'}
}
$script:State.QuotaPlanSelection='pro';$script:State.RateLimits=$null
$accepted=New-RefreshLimits 9 $at $reset
Merge-LatestRateLimits $accepted
$rejected=New-RefreshLimits 0 $at.AddSeconds(1) $reset
Merge-LatestRateLimits $rejected
Assert-Refresh ($script:State.RateLimits.Weekly.UsedPercent-eq9) 'regressed zero replaced accepted nine'
foreach($plan in @('pro','')) {
    $selected=Select-TokenRaderQuotaPlan $script:State.RateLimits $plan
    Assert-Refresh ($selected.Weekly.UsedPercent-eq9) 'rejected original snapshot returned during plan selection'
}
$oldEstimate=[pscustomobject]@{TotalUsd=100;PlanType='pro';WindowMinutes=10080;ResetsAt=$reset;LimitId='synthetic'}
$estimate=$oldEstimate.PSObject.Copy();$estimate.TotalUsd=500
$script:State.AccountIdentity='current-tag';$script:State.QuotaEstimateAccountIdentity='current-tag'
$script:State.QuotaEstimates=[pscustomobject]@{FiveHour=$null;Weekly=$oldEstimate}
$script:State.IntervalBaseline=[pscustomobject]@{StartedAt=$at.AddMinutes(-5);AccountIdentity='current-tag';RateLimits=$accepted}
$result=[pscustomobject]@{AccountIdentity='current-tag';StartRateLimits=$accepted;EndRateLimits=$rejected;PricingComplete=$true;TotalCost=2;EndedAt=$at;QuotaEvidence=[pscustomobject]@{FiveHour=$null;Weekly=[pscustomobject]@{}}}
Update-QuotaEstimatesFromInterval $result
Assert-Refresh ($script:State.QuotaEstimates.Weekly.TotalUsd-eq100) 'rejected endpoint estimate replaced retained dollars'
$fresh=New-RefreshLimits 0 $at.AddSeconds(2) $reset.AddDays(7)
Merge-LatestRateLimits $fresh
Retain-TokenRaderQuotaEstimatesForCurrentWindow -RateLimits $script:State.RateLimits -AccountIdentity 'current-tag'
Assert-Refresh ($script:State.RateLimits.Weekly.UsedPercent-eq0 -and $null-eq$script:State.QuotaEstimates) 'new-cycle zero was blocked or retained old dollars'
if($null-eq('System.Data.SQLite.SQLiteConnection'-as[type])){Add-Type -Path (Join-Path $root 'indexer/System.Data.SQLite.dll')}
if($null-eq('TokenRaderIndexer'-as[type])){Add-Type -Path (Join-Path $root 'indexer/TokenRader.Indexer.dll')}
$db=[System.Data.SQLite.SQLiteConnection]::new('Data Source=:memory:;Version=3;New=True;');$db.Open()
$path=Join-Path $env:TEMP ('quota-refresh-synthetic-'+[Guid]::NewGuid().ToString('N')+'.jsonl')
try {
    [TokenRaderIndexer]::CreateSchema($db)
    $lines=@();$i=0
    foreach($value in @($null,'','NaN','Infinity','bad',-1,101,$true,0)) {
        $i++;$usage=@{input_tokens=10;cached_input_tokens=0;output_tokens=1;reasoning_output_tokens=0}
        $lines+=(@{timestamp=$at.AddSeconds($i).ToString('o');type='event_msg';payload=@{type='token_count';info=@{total_token_usage=$usage;last_token_usage=$usage};rate_limits=@{plan_type='pro';primary=@{used_percent=$value;window_minutes=10080;resets_at=$reset.ToUnixTimeSeconds()}}}}|ConvertTo-Json -Depth 12 -Compress)
    }
    [IO.File]::WriteAllLines($path,[string[]]$lines,[Text.UTF8Encoding]::new($false))
    [void][TokenRaderIndexer]::ImportFile($db,$path,0L)
    $q=$db.CreateCommand();$q.CommandText='SELECT COUNT(*) FROM token_records';Assert-Refresh ($q.ExecuteScalar()-eq9) 'invalid quota metadata discarded token rows'
    $q.CommandText='SELECT COUNT(*) FROM token_records WHERE weekly_used IS NULL';Assert-Refresh ($q.ExecuteScalar()-eq8) 'index manufactured zero from invalid metadata'
    $q.CommandText='SELECT COUNT(*) FROM token_records WHERE weekly_used=0';Assert-Refresh ($q.ExecuteScalar()-eq1) 'index lost valid zero'
}finally{$db.Dispose();if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}}
'QUOTA_REFRESH_REGRESSION_TESTS_PASSED'
