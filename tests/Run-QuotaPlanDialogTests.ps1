[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'TokenRader.Core.psm1') -Force
$source=[IO.File]::ReadAllText((Join-Path $root 'TokenRader.ps1'))
foreach($name in @('Set-TokenRaderQuotaPlanSelection','Show-TokenRaderQuotaPlanDialog')) {
    $match=[regex]::Match($source,'(?s)function '+$name+'\b.*?(?=\r?\nfunction |\z)')
    if(!$match.Success){throw ('Missing dialog function '+$name)}
    Invoke-Expression $match.Value
}
function Update-QuotaCards {}
function Update-IntervalView { param([switch]$Manual) }
$script:Window=$null
$script:QuotaPlanButton=[pscustomobject]@{Content=''}
$script:StatusText=[pscustomobject]@{Text=''}
$application=if($null-ne[Windows.Application]::Current){[Windows.Application]::Current}else{New-Object Windows.Application}
$application.ShutdownMode='OnExplicitShutdown'
$now=[DateTimeOffset]::Now;$reset=$now.AddDays(7)
$identity=Get-TokenRaderResetIdentity -WindowMinutes 10080 -ResetsAt $reset
$candidate=[pscustomobject]@{PlanType='pro';UsedPercent=3;ObservedAt=$now;WindowMinutes=10080;ResetIdentity=$identity;LimitId='synthetic'}
$quotaWindow=[pscustomobject]@{PlanType='pro';UsedPercent=3;ObservedAt=$now;WindowMinutes=10080;ResetsAt=$reset;ResetIdentity=$identity;LimitId='synthetic';ScopeCandidates=@($candidate)}
$script:State=@{QuotaPlanSelection='';RateLimits=[pscustomobject]@{FiveHour=$null;Weekly=$quotaWindow};IntervalComputing=$false;UiState='Idle';IntervalBaseline=$null;QuotaEstimates=$null;IntervalCache=$null}
$script:dialogFailure=$null;$script:dialogClicked=$false
$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({
    $timer.Stop()
    try {
        $dialog=@($application.Windows | Where-Object {$_.Content -is [Windows.Controls.StackPanel]}) | Select-Object -Last 1
        if($null-eq$dialog){throw 'Synthetic quota dialog was not shown'}
        $dialog.ShowInTaskbar=$false
        $button=@($dialog.Content.Children | Where-Object {$_ -is [Windows.Controls.Button]}) | Select-Object -Last 1
        $script:dialogClicked=$true
        $button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    } catch {
        $script:dialogFailure=$_.Exception.Message
        foreach($open in @($application.Windows)){$open.Close()}
    }
})
try {
    $timer.Start()
    Show-TokenRaderQuotaPlanDialog
    if($script:dialogFailure){throw $script:dialogFailure}
    if(!$script:dialogClicked-or$script:State.RateLimits.Weekly.UsedPercent-ne3){throw 'Dialog confirmation did not preserve the single candidate'}
    'QUOTA_PLAN_DIALOG_TESTS_PASSED'
} finally {$timer.Stop()}
