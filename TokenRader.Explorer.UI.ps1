# Definitions only: no disk scans, database opens, or workers until the user
# opens the separate explorer. This state never modifies measurement state.
$script:Explorer = $null

function Get-ExplorerTimeRange {
    param([string]$Choice, [string]$From, [string]$To, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($Choice -eq 'all') { return @{StartAt=$null; EndAt=$Now} }
    if ($Choice -ne 'custom') { return @{StartAt=$Now.AddDays(-[int]$Choice); EndAt=$Now} }
    $start = [DateTimeOffset]::ParseExact($From, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    $end = [DateTimeOffset]::ParseExact($To, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    if ($end -le $start) { throw '结束时间必须晚于开始时间。' }
    return @{StartAt=$start; EndAt=$end}
}

function Set-ExplorerBusy {
    param([bool]$Busy)
    foreach ($name in @('Reload','Backfill','Titles','Query','Tree','Range','From','To','Search','SearchButton')) {
        $script:Explorer.Controls[$name].IsEnabled = -not $Busy
    }
    $script:Explorer.Controls.Cancel.IsEnabled = $Busy
    if (-not $Busy) {
        $custom=[string]$script:Explorer.Controls.Range.SelectedItem.Tag -eq 'custom'
        $script:Explorer.Controls.From.IsEnabled=$custom
        $script:Explorer.Controls.To.IsEnabled=$custom
    }
}

function Set-ExplorerCatalog {
    param($Catalog)
    $script:Explorer.Catalog = $Catalog
    $tree = $script:Explorer.Controls.Tree
    $tree.Items.Clear()
    $filter = $script:Explorer.Controls.Search.Text.Trim()
    foreach ($project in @($Catalog.Projects)) {
        $sessions = @(foreach ($session in @($project.Sessions)) {
            $title = Get-ExplorerConversationName $session
            if ($filter.Length -eq 0 -or ([string]$project.ProjectName).IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $title.IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $session }
        })
        if ($filter.Length -gt 0 -and $sessions.Count -eq 0) { continue }
        $node = New-Object Windows.Controls.TreeViewItem
        $node.Header = [string]$project.ProjectName
        $node.ToolTip = [string]$project.ProjectPath
        $node.Tag = [pscustomobject]@{ProjectPath=[string]$project.ProjectPath;SessionId='';Name=[string]$project.ProjectName;Sessions=$sessions;Loaded=$false}
        [void]$node.Items.Add('展开查看对话')
        $node.Add_Expanded({
            param($sender,$eventArgs)
            if ($sender -ne $eventArgs.OriginalSource -or $sender.Tag.Loaded) { return }
            $sender.Items.Clear()
            foreach ($session in @($sender.Tag.Sessions)) {
                $child = New-Object Windows.Controls.TreeViewItem
                $title = Get-ExplorerConversationName $session
                $child.Header=$title
                $child.ToolTip=[string]$session.SessionId
                $child.Tag=[pscustomobject]@{ProjectPath=[string]$sender.Tag.ProjectPath;SessionId=[string]$session.SessionId;Name=$title}
                [void]$sender.Items.Add($child)
            }
            $sender.Tag.Loaded=$true
        })
        [void]$tree.Items.Add($node)
        if ($filter.Length -gt 0) { $node.IsExpanded = $true }
    }
}

function Get-ExplorerConversationName {
    param($Session)
    $id = [string]$Session.SessionId
    if ($script:Explorer.TitleMap.ContainsKey($id) -and -not [string]::IsNullOrWhiteSpace([string]$script:Explorer.TitleMap[$id])) { return [string]$script:Explorer.TitleMap[$id] }
    return '未命名对话（标题未读取或不可用）'
}

function Confirm-ExplorerTitleAccess {
    $answer=[Windows.MessageBox]::Show($script:Explorer.Window,'是否只读本机 .codex/session_index.jsonl 的对话 ID 和标题，用于按名称显示和检索？标题可能包含私人信息，仅保留在此窗口内存中；不读取正文、auth.json 或密钥，不写入缓存。','读取标题授权',[Windows.MessageBoxButton]::YesNo)
    $script:Explorer.TitlesAuthorized = $answer -eq [Windows.MessageBoxResult]::Yes
    return $script:Explorer.TitlesAuthorized
}

function Complete-ExplorerWork {
    param($Result,[string]$Operation)
    $c=$script:Explorer.Controls
    if ($Operation -eq 'Titles') {
        $script:Explorer.TitleMap=$Result
        if ($null -ne $script:Explorer.Catalog) { Set-ExplorerCatalog $script:Explorer.Catalog }
        $c.Status.Text='已读取本机标题元数据；未读取正文，标题只保留在此窗口内存中。'
    } elseif ($Operation -in @('Catalog','Backfill')) {
        if ($null -ne $Result.PSObject.Properties['TitleMap']) { $script:Explorer.TitleMap=$Result.TitleMap; Set-ExplorerCatalog $Result.Catalog }
        else { Set-ExplorerCatalog $Result }
        $c.Status.Text='项目列表已更新。选择项目或展开后选择对话；全部时间仅覆盖本机保留的日志。'
    } else {
        $partial=if ($Result.PricingComplete) {''} else {'（部分）'}
        $c.Summary.Text=('总 Token：{0}    API 等价美元：{1}{2}' -f (Format-TokenRaderNumber $Result.Usage.Total),(Format-TokenRaderUsd $Result.TotalCost),$partial)
        $c.Coverage.Text=[string]$Result.CoverageMessage
        if ($null -ne $Result.PSObject.Properties['Coverage'] -and $null -ne $Result.Coverage.PSObject.Properties['BackfillCompletedAt'] -and
            -not [string]::IsNullOrWhiteSpace([string]$Result.Coverage.BackfillCompletedAt)) {
            $c.Coverage.Text += ' 最近手动补齐：'+[string]$Result.Coverage.BackfillCompletedAt+'；需要新增日志时请点击“补齐 / 更新全部历史日志”。'
        }
        $rows=@(foreach ($item in @($Result.Items)) {
            $cost=if ($null -ne $item.PSObject.Properties['TotalCost']) {$item.TotalCost} else {$item.Cost.TotalCost}
            $tier=if ($null -ne $item.PSObject.Properties['ServiceTier']) {[string]$item.ServiceTier} else {''}
            [pscustomobject]@{Model=([string]$item.Model+' '+$tier);Cached=Format-TokenRaderNumber $item.Usage.Cached;Uncached=Format-TokenRaderNumber $item.Usage.Uncached;Output=Format-TokenRaderNumber $item.Usage.Output;Total=Format-TokenRaderNumber $item.Usage.Total;Cost=Format-TokenRaderUsd $cost}
        })
        $c.Models.ItemsSource=$rows
        $c.Status.Text='查询完成。模式缺失按普通价；此独立历史查询不使用主测量的临时 Fast 选择。'
    }
}

function Stop-ExplorerWork {
    if ($null -eq $script:Explorer -or $null -eq $script:Explorer.Job) { return }
    $job=$script:Explorer.Job
    $job.Cancelled=$true
    $job.Cancellation.Cancel()
    if ($null -eq $job.StopHandle) { $job.StopHandle=$job.Worker.BeginStop($null,$null) }
    $script:Explorer.Controls.Status.Text='正在取消；保留上次结果。'
}

function Start-ExplorerWork {
    param([string]$Operation)
    $e=$script:Explorer
    if ($null -ne $e.Job) { return }
    $args=@{ProjectRoot=$PSScriptRoot;Operation=$Operation;CodexRoot=$script:Paths.CodexRoot;ReadTitles=[bool]$e.TitlesAuthorized}
    try {
        if ($Operation -eq 'Query') {
            $node=$e.Controls.Tree.SelectedItem
            if ($null -eq $node -or $null -eq $node.Tag) { return }
            $range=Get-ExplorerTimeRange -Choice ([string]$e.Controls.Range.SelectedItem.Tag) -From $e.Controls.From.Text -To $e.Controls.To.Text
            $args.ProjectPath=[string]$node.Tag.ProjectPath
            $args.SessionId=[string]$node.Tag.SessionId
            $args.StartAt=$range.StartAt; $args.EndAt=$range.EndAt
            if ($null -ne $range.StartAt) { $e.Controls.From.Text=$range.StartAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') }
            $e.Controls.To.Text=$range.EndAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
            $e.Controls.Selection.Text=[string]$node.Tag.Name
        }
        $cts=New-Object Threading.CancellationTokenSource
        $progress=[hashtable]::Synchronized(@{Stage='正在读取索引'})
        $args.CancellationToken=$cts.Token; $args.ProgressState=$progress
        $worker=[PowerShell]::Create()
        [void]$worker.AddScript({
            param($ProjectRoot,$Operation,$CodexRoot,$ProjectPath='',$SessionId='',$StartAt=$null,$EndAt=$null,$CancellationToken,$ProgressState,[bool]$ReadTitles=$false)
            $ErrorActionPreference='Stop'
            Import-Module (Join-Path $ProjectRoot 'TokenRader.Explorer.psm1') -Force
            if ($ReadTitles -and $Operation -in @('Titles','Catalog','Backfill')) {
                # Explicit UI consent precedes this one-file metadata read.
                $map=@{}; $path=Join-Path $CodexRoot 'session_index.jsonl'
                if (Test-Path -LiteralPath $path) {
                    $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                    $reader=[IO.StreamReader]::new($stream)
                    try { while (-not $reader.EndOfStream) {
                        $CancellationToken.ThrowIfCancellationRequested()
                        try { $entry=$reader.ReadLine() | ConvertFrom-Json } catch { continue }
                        if (-not [string]::IsNullOrWhiteSpace([string]$entry.id) -and -not [string]::IsNullOrWhiteSpace([string]$entry.thread_name)) { $map[[string]$entry.id]=[string]$entry.thread_name }
                    } } finally { $reader.Dispose() }
                }
                if ($Operation -eq 'Titles') { return ,$map }
            }
            if ($Operation -eq 'Backfill') { Update-TokenRaderExplorerIndex -ProjectRoot $ProjectRoot -CancellationToken $CancellationToken -ProgressState $ProgressState | Out-Null }
            if ($Operation -in @('Catalog','Backfill')) {
                $catalog=Get-TokenRaderExplorerCatalog -ProjectRoot $ProjectRoot
                if ($ReadTitles) { return [pscustomobject]@{Catalog=$catalog;TitleMap=$map} }
                return $catalog
            }
            Get-TokenRaderExplorerResult -ProjectRoot $ProjectRoot -ProjectPath $ProjectPath -SessionId $SessionId -StartAt $StartAt -EndAt $EndAt -CancellationToken $CancellationToken
        }.ToString())
        foreach ($key in $args.Keys) { [void]$worker.AddParameter($key,$args[$key]) }
        $handle=$worker.BeginInvoke()
        $e.Job=@{Worker=$worker;Handle=$handle;Cancellation=$cts;Cancelled=$false;StopHandle=$null;Operation=$Operation;Progress=$progress;StartedAt=[DateTimeOffset]::Now}
        Set-ExplorerBusy $true
        $e.Controls.Status.Text='正在后台处理，保留上次结果…'
        $e.Timer.Start()
    } catch {
        if ($null -ne (Get-Variable worker -ErrorAction SilentlyContinue)) { if ($null -ne $worker) { $worker.Dispose() } }
        if ($null -ne (Get-Variable cts -ErrorAction SilentlyContinue)) { if ($null -ne $cts) { $cts.Dispose() } }
        $e.Controls.Status.Text='查询启动失败：'+$_.Exception.Message
        Set-ExplorerBusy $false
    }
}

function Show-TokenRaderExplorer {
    if ($null -ne $script:Explorer) {
        if (-not $script:Explorer.Closed) { [void]$script:Explorer.Window.Activate() }
        return
    }
    [xml]$xaml=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'ExplorerWindow.xaml')
    $window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
    $window.Owner=$script:Window
    $controls=@{}
    foreach ($name in @('Reload','Backfill','Titles','Cancel','Query','Tree','Range','From','To','Selection','Summary','Coverage','Models','Status','Search','SearchButton')) { $controls[$name]=$window.FindName($name) }
    $script:Explorer=@{Window=$window;Controls=$controls;Job=$null;Closed=$false;CloseOwner=$false;Catalog=$null;TitleMap=@{};TitlesAuthorized=$false;Timer=(New-Object Windows.Threading.DispatcherTimer)}
    $controls.From.Text=[DateTime]::Now.AddDays(-1).ToString('yyyy-MM-dd HH:mm:ss')
    $controls.To.Text=[DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    $controls.From.IsEnabled=$false; $controls.To.IsEnabled=$false
    $controls.Range.Add_SelectionChanged({ if ($null -eq $script:Explorer.Job) { Set-ExplorerBusy $false } })
    $controls.Reload.Add_Click({Start-ExplorerWork 'Catalog'})
    $controls.Query.Add_Click({Start-ExplorerWork 'Query'})
    $controls.Tree.Add_SelectedItemChanged({Start-ExplorerWork 'Query'})
    $controls.Cancel.Add_Click({Stop-ExplorerWork})
    $controls.SearchButton.Add_Click({ if ($null -ne $script:Explorer.Catalog) { Set-ExplorerCatalog $script:Explorer.Catalog } })
    $controls.Search.Add_KeyDown({ param($sender,$eventArgs) if ($eventArgs.Key -eq [Windows.Input.Key]::Return -and $null -eq $script:Explorer.Job -and $null -ne $script:Explorer.Catalog) { Set-ExplorerCatalog $script:Explorer.Catalog; $eventArgs.Handled=$true } })
    $controls.Backfill.Add_Click({
        $answer=[Windows.MessageBox]::Show($script:Explorer.Window,'将只读扫描本机 sessions 中保留的日志，提取项目、任务关系和 Token 元数据，写入本项目独立查询缓存。不读取密钥，不保存对话正文，不修改原始日志。历史较多时可能耗时较长，可取消。是否继续？','手动补齐历史',[Windows.MessageBoxButton]::YesNo)
        if ($answer -eq [Windows.MessageBoxResult]::Yes) { Start-ExplorerWork 'Backfill' }
    })
    $controls.Titles.Add_Click({
        if (Confirm-ExplorerTitleAccess) { Start-ExplorerWork 'Titles' }
    })
    $script:Explorer.Timer.Interval=[TimeSpan]::FromMilliseconds(100)
    $script:Explorer.Timer.Add_Tick({
        $e=$script:Explorer; $job=$e.Job
        if ($null -eq $job) { $e.Timer.Stop(); return }
        if (-not $job.Handle.IsCompleted -or ($null -ne $job.StopHandle -and -not $job.StopHandle.IsCompleted)) {
            $e.Controls.Status.Text=('{0} · {1:N0} 秒' -f $job.Progress.Stage,([DateTimeOffset]::Now-$job.StartedAt).TotalSeconds)
            return
        }
        try {
            if ($null -ne $job.StopHandle) { $job.Worker.EndStop($job.StopHandle) }
            $output=$job.Worker.EndInvoke($job.Handle)
            if ($job.Worker.HadErrors) { throw $job.Worker.Streams.Error[0].Exception }
            if (-not $job.Cancelled -and -not $e.Closed) { Complete-ExplorerWork -Result @($output)[-1] -Operation $job.Operation }
        } catch { if (-not $e.Closed) { $e.Controls.Status.Text=if ($job.Cancelled) {'已取消，保留上次结果。'} else {'查询失败：'+$_.Exception.Message} } }
        finally {
            $job.Worker.Dispose(); $job.Cancellation.Dispose(); $e.Job=$null; $e.Timer.Stop()
            if ($e.Closed) { $script:Explorer=$null } else { Set-ExplorerBusy $false }
            if ($e.CloseOwner) { $script:Window.Close() }
        }
    })
    $window.Add_Closed({
        $script:Explorer.Closed=$true
        if ($null -ne $script:Explorer.Job) { Stop-ExplorerWork } else { $script:Explorer.Timer.Stop(); $script:Explorer=$null }
    })
    $window.Show()
    [void](Confirm-ExplorerTitleAccess)
    Start-ExplorerWork 'Catalog'
}
