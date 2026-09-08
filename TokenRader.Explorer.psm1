Set-StrictMode -Version Latest

# Manual, opt-in usage explorer.  The catalog/result paths only inspect the
# project-local SQLite index.  Source JSONL is read only by
# Update-TokenRaderExplorerIndex, which is an explicit backfill operation.
$script:ExplorerCore = $null

function Get-ExplorerCore {
    if ($null -eq $script:ExplorerCore) {
        $corePath = Join-Path $PSScriptRoot 'TokenRader.Core.psm1'
        $script:ExplorerCore = Import-Module -Name $corePath -Force -PassThru
        $loaded = 'TokenRaderIndexer' -as [type]
        if ($null -eq $loaded -or $null -eq $loaded.GetMethod('AggregateScopedTimeRangeRecordsAtOffsets')) {
            if (-not (Initialize-TokenRaderIndexer)) { throw 'TokenRader Indexer DLL 不可用，请先运行 Build.ps1。' }
        }
        if ($null -eq ([TokenRaderIndexer]).GetMethod('AggregateScopedTimeRangeRecordsAtOffsets')) { throw '请关闭旧版窗口，完成构建后重新启动。' }
    }
    return $script:ExplorerCore
}

function Get-ExplorerProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name) -and $null -ne $Object[$Name]) { return $Object[$Name] }
        return $Default
    }
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) { return $Default }
    $value = $Object.PSObject.Properties[$Name].Value
    if ($null -eq $value) { return $Default }
    return $value
}

function Get-ExplorerPaths {
    param([string]$ProjectRoot, $Paths = $null)
    $root = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $PSScriptRoot } else { $ProjectRoot }))
    $main = Get-ExplorerProperty $Paths 'MainIndexPath' $null
    if ([string]::IsNullOrWhiteSpace([string]$main)) { $main = Get-ExplorerProperty $Paths 'IndexPath' $null }
    if ([string]::IsNullOrWhiteSpace([string]$main)) { $main = Join-Path $root 'data\private\index\index.db' }
    $explorer = Get-ExplorerProperty $Paths 'ExplorerIndexPath' $null
    if ([string]::IsNullOrWhiteSpace([string]$explorer)) { $explorer = Join-Path $root 'data\private\explorer\index.db' }
    $sessions = Get-ExplorerProperty $Paths 'SessionsRoot' $null
    $pricing = Get-ExplorerProperty $Paths 'PricingPath' $null
    if ([string]::IsNullOrWhiteSpace([string]$pricing)) { $pricing = Join-Path $root 'pricing.json' }
    [pscustomobject]@{
        ProjectRoot = $root
        MainIndexPath = [IO.Path]::GetFullPath([string]$main)
        ExplorerIndexPath = [IO.Path]::GetFullPath([string]$explorer)
        SessionsRoot = if ([string]::IsNullOrWhiteSpace([string]$sessions)) { $null } else { [IO.Path]::GetFullPath([string]$sessions) }
        PricingPath = [IO.Path]::GetFullPath([string]$pricing)
    }
}

function Open-ExplorerReadOnly {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $builder=New-Object System.Data.SQLite.SQLiteConnectionStringBuilder
    $builder.DataSource=$Path; $builder.ReadOnly=$true; $builder.DefaultTimeout=5
    $connection = New-Object System.Data.SQLite.SQLiteConnection($builder.ConnectionString)
    $connection.Open()
    return $connection
}

function Get-ExplorerPreferredIndex {
    param([Parameter(Mandatory)]$ResolvedPaths)
    if (Test-Path -LiteralPath $ResolvedPaths.ExplorerIndexPath -PathType Leaf) {
        $candidate = Open-ExplorerReadOnly -Path $ResolvedPaths.ExplorerIndexPath
        if ($null -ne $candidate) {
            try {
                $marker = [string][TokenRaderIndexer]::GetSetting($candidate, 'explorer_backfill_complete')
                if (-not [string]::IsNullOrWhiteSpace($marker)) { return [pscustomobject]@{ Path=$ResolvedPaths.ExplorerIndexPath; IsExplorer=$true } }
            } finally { $candidate.Close(); $candidate.Dispose() }
        }
    }
    return [pscustomobject]@{ Path=$ResolvedPaths.MainIndexPath; IsExplorer=$false }
}

function Invoke-ExplorerTable {
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][string]$Sql, [hashtable]$Parameters = @{})
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Sql
        foreach ($key in $Parameters.Keys) { [void]$command.Parameters.AddWithValue([string]$key, $Parameters[$key]) }
        $table = New-Object System.Data.DataTable
        $adapter = New-Object System.Data.SQLite.SQLiteDataAdapter($command)
        try { [void]$adapter.Fill($table) } finally { $adapter.Dispose() }
        return ,$table
    } finally { $command.Dispose() }
}

function Convert-ExplorerMetadata {
    param([Parameter(Mandatory)]$Row)
    $path = [string]$Row['path']
    $session = [string]$Row['session_id']
    if ([string]::IsNullOrWhiteSpace($session)) { $session = [IO.Path]::GetFileNameWithoutExtension($path) }
    $short = if ($session.Length -gt 8) { $session.Substring(0, 8) } else { $session }
    $root = [string]$Row['root_session_id']; if ([string]::IsNullOrWhiteSpace($root)) { $root = $session }
    $ticks = [Int64]$Row['last_write_ticks']
    $utc = [DateTime]::new($ticks, [DateTimeKind]::Utc)
    [pscustomobject]@{
        SessionId = $session
        ShortId = $short
        Title = $short
        DisplayName = $short
        ParentThreadId = [string]$Row['parent_thread_id']
        ForkedFromId = [string]$Row['forked_from_id']
        RootSessionId = $root
        Cwd = [string]$Row['cwd']
        Path = $path
        FilePath = $path
        ParsedOffset = if ($Row.Table.Columns.Contains('parsed_offset')) { [Int64]$Row['parsed_offset'] } else { 0L }
        ContentRetained = if ($Row.Table.Columns.Contains('content_retained')) { [bool]([int]$Row['content_retained']) } else { $true }
        LastWriteTimeUtc = [DateTimeOffset]$utc
        Length = [Int64]$Row['length']
    }
}

function Read-ExplorerMetadata {
    param([Parameter(Mandatory)]$Connection)
    $table = Invoke-ExplorerTable -Connection $Connection -Sql 'SELECT path,length,last_write_ticks,parsed_offset,session_id,cwd,parent_thread_id,forked_from_id,content_retained,root_session_id FROM file_metadata ORDER BY last_write_ticks DESC,path ASC'
    return @($table.Rows | ForEach-Object { Convert-ExplorerMetadata $_ })
}

function Get-ExplorerSessionSelection {
    param([object[]]$Metadata, [string]$ProjectPath = '', [string]$SessionId = '')
    $all = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Metadata)) { if (-not [string]::IsNullOrWhiteSpace([string]$item.SessionId)) { $all[[string]$item.SessionId] = $item } }
    $selected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        [void]$selected.Add($SessionId)
        # A session selection is intentionally anchored at that session.  Its
        # parent is not implicitly included; only descendants are added below.
    } elseif (-not [string]::IsNullOrWhiteSpace($ProjectPath)) {
        try { $ProjectPath = [IO.Path]::GetFullPath($ProjectPath).TrimEnd([char]'\',[char]'/') } catch { }
        foreach ($item in @($Metadata)) {
            $cwd = [string]$item.Cwd
            try { $cwd = [IO.Path]::GetFullPath($cwd).TrimEnd([char]'\',[char]'/') } catch { }
            if ($cwd.Equals($ProjectPath, [StringComparison]::OrdinalIgnoreCase)) { [void]$selected.Add([string]$item.SessionId) }
        }
    } else {
        foreach ($item in @($Metadata)) { [void]$selected.Add([string]$item.SessionId) }
    }
    # Parent/fork links are authoritative when available. Root membership is a
    # second guard for old indexes whose child parent field was not retained.
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($item in @($Metadata)) {
            $parent = [string]$item.ParentThreadId; if ([string]::IsNullOrWhiteSpace($parent)) { $parent = [string]$item.ForkedFromId }
            if ($selected.Contains($parent)) {
                if ($selected.Add([string]$item.SessionId)) { $changed = $true }
            }
        }
    }
    return ,$selected
}

function Get-ExplorerPricing {
    param([Parameter(Mandatory)]$Paths)
    $core = Get-ExplorerCore
    if (Test-Path -LiteralPath $Paths.PricingPath -PathType Leaf) { return Get-TokenRaderPrices -PricingPath $Paths.PricingPath }
    return [pscustomobject]@{ models = @(); verifiedAt = ''; unitTokens = 1000000 }
}

function New-ExplorerUsage {
    param([Int64]$InputTokens = 0, [Int64]$CachedTokens = 0, [Int64]$OutputTokens = 0, [Int64]$Reasoning = 0)
    $input = [Math]::Max([Int64]0,$InputTokens); $cached = [Math]::Min($input,[Math]::Max([Int64]0,$CachedTokens)); $output = [Math]::Max([Int64]0,$OutputTokens)
    [pscustomobject]@{ Input=$input; Cached=$cached; Uncached=($input-$cached); Output=$output; ReasoningOutput=[Math]::Max([Int64]0,$Reasoning); Total=($input+$output); CacheHitRate=if($input -gt 0){$cached*100.0/$input}else{0.0} }
}

function Get-ExplorerCoverage {
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)]$Paths, [object[]]$Metadata, $StartAt, $EndAt, [bool]$ExplorerSource = $false)
    $cutoff = [Int64]0
    try { $raw = [TokenRaderIndexer]::GetSetting($Connection, 'retention_cutoff_ticks'); [void][Int64]::TryParse([string]$raw, [ref]$cutoff) } catch { }
    $completeSetting = $false
    try { $completeSetting = [string][TokenRaderIndexer]::GetSetting($Connection, 'explorer_backfill_complete') -eq '1' } catch { }
    $missingRetained = @($Metadata | Where-Object { -not [bool]$_.ContentRetained }).Count -gt 0
    $boundedBeforeCutoff = $false
    if ($cutoff -gt 0 -and $null -ne $StartAt) { try { $boundedBeforeCutoff = ([DateTimeOffset]$StartAt).UtcDateTime.Ticks -lt $cutoff } catch { } }
    $partial = $missingRetained -or $boundedBeforeCutoff -or (-not $completeSetting)
    $message = if ($missingRetained) { '索引中有已清理源内容的会话，覆盖不完整。' } elseif ($boundedBeforeCutoff) { '请求范围早于索引保留边界，覆盖不完整。' } elseif (-not $completeSetting) { '结果来自当前索引快照；如需全历史，请手动执行历史回填。' } else { '历史回填已完成，覆盖范围以可读源日志为准。' }
    $completedAt = ''
    try { $completedAt = [string][TokenRaderIndexer]::GetSetting($Connection, 'explorer_backfill_completed_at') } catch { }
    [pscustomobject]@{ IsComplete=(-not $partial); Status=if($partial){'Partial'}else{'Complete'}; Source=if($ExplorerSource){'ExplorerIndex'}else{'MainIndex'}; RetentionCutoffUtc=if($cutoff -gt 0){[DateTimeOffset]::new([DateTime]::new($cutoff,[DateTimeKind]::Utc))}else{$null}; BackfillCompletedAt=$completedAt; Message=$message }
}

function Get-TokenRaderExplorerCatalog {
    [CmdletBinding()]
    param([string]$ProjectRoot = $PSScriptRoot, $Paths = $null)
    $resolved = Get-ExplorerPaths -ProjectRoot $ProjectRoot -Paths $Paths
    [void](Get-ExplorerCore)
    $preferred = Get-ExplorerPreferredIndex -ResolvedPaths $resolved
    $dbPath = [string]$preferred.Path
    $connection = Open-ExplorerReadOnly -Path $dbPath
    if ($null -eq $connection) { return [pscustomobject]@{ Projects=@(); Source='None'; IndexPath=$dbPath; Sessions=@() } }
    try {
        $metadata = @(Read-ExplorerMetadata -Connection $connection)
        $byId = @{}; foreach ($entry in $metadata) { $byId[[string]$entry.SessionId] = $entry }
        foreach ($entry in $metadata) {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.Cwd)) { continue }
            $cursor = $entry; $seen = @{}
            while ($null -ne $cursor -and [string]::IsNullOrWhiteSpace([string]$cursor.Cwd)) {
                if ($seen.ContainsKey([string]$cursor.SessionId)) { break }; $seen[[string]$cursor.SessionId] = $true
                $parent = [string]$cursor.ParentThreadId; if ([string]::IsNullOrWhiteSpace($parent)) { $parent=[string]$cursor.ForkedFromId }
                if (-not $byId.ContainsKey($parent)) { break }; $cursor=$byId[$parent]
            }
            if ($null -ne $cursor -and -not [string]::IsNullOrWhiteSpace([string]$cursor.Cwd)) { $entry.Cwd=$cursor.Cwd }
        }
        $groups = @{}
        foreach ($session in $metadata) {
            $cwd = [string]$session.Cwd; if ([string]::IsNullOrWhiteSpace($cwd)) { continue }
            try { $cwd = [IO.Path]::GetFullPath($cwd).TrimEnd([char]'\',[char]'/') } catch { }
            $key = $cwd.ToLowerInvariant()
            if (-not $groups.ContainsKey($key)) { $name = [IO.Path]::GetFileName($cwd); if ([string]::IsNullOrWhiteSpace($name)){$name=$cwd}; $groups[$key]=[ordered]@{Path=$cwd;Name=$name;Sessions=New-Object Collections.ArrayList} }
            [void]$groups[$key].Sessions.Add($session)
        }
        $projects = foreach ($group in $groups.Values) { $sessions=@($group.Sessions | Sort-Object LastWriteTimeUtc -Descending); [pscustomobject]@{ Path=[string]$group.Path; Name=[string]$group.Name; ProjectPath=[string]$group.Path; ProjectName=[string]$group.Name; Sessions=$sessions; SessionCount=$sessions.Count; DisplayName=[string]$group.Name } }
        [pscustomobject]@{ Projects=@($projects | Sort-Object Name); Source=if([bool]$preferred.IsExplorer){'ExplorerIndex'}else{'MainIndex'}; IndexPath=$dbPath; Sessions=$metadata }
    } finally { $connection.Close(); $connection.Dispose() }
}

function Get-TokenRaderExplorerResult {
    [CmdletBinding()]
    param([string]$ProjectRoot=$PSScriptRoot, $Paths=$null, [string]$ProjectPath='', [string]$SessionId='', $StartAt=$null, $EndAt=$null, [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None, [hashtable]$ProgressState=$null)
    $resolved=Get-ExplorerPaths -ProjectRoot $ProjectRoot -Paths $Paths; $core=Get-ExplorerCore
    $preferred = Get-ExplorerPreferredIndex -ResolvedPaths $resolved
    $dbPath=[string]$preferred.Path; $sourceExplorer=[bool]$preferred.IsExplorer
    $connection=Open-ExplorerReadOnly -Path $dbPath
    if($null -eq $connection){ return [pscustomobject]@{Usage=(New-ExplorerUsage);TotalCost=0.0;Items=@();Count=0;PricingComplete=$false;Coverage=[pscustomobject]@{IsComplete=$false;Status='Unavailable';Source='None';BackfillCompletedAt='';Message='索引不存在。'};CoverageMessage='索引不存在。'} }
    try {
        $metadata=@(Read-ExplorerMetadata -Connection $connection); $selected=Get-ExplorerSessionSelection -Metadata $metadata -ProjectPath $ProjectPath -SessionId $SessionId
        $allSelected=([string]::IsNullOrWhiteSpace($ProjectPath) -and [string]::IsNullOrWhiteSpace($SessionId))
        $start=if($null -eq $StartAt){[DateTimeOffset]::MinValue.AddDays(2)}else{[DateTimeOffset]$StartAt}; $end=if($null -eq $EndAt){[DateTimeOffset]::MaxValue.AddDays(-2)}else{[DateTimeOffset]$EndAt}; if($end -le $start){throw 'EndAt must be later than StartAt.'}
        $ends = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        $evidenceIds=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $selected) { [void]$evidenceIds.Add([string]$id) }
        $byId=@{}; foreach ($item in $metadata) { $byId[[string]$item.SessionId]=$item }
        foreach ($id in @($selected)) {
            $cursor=$byId[[string]$id]; $seen=@{}
            while ($null -ne $cursor -and -not $seen.ContainsKey([string]$cursor.SessionId)) {
                $seen[[string]$cursor.SessionId]=$true
                $parent=if ([string]::IsNullOrWhiteSpace([string]$cursor.ParentThreadId)) {[string]$cursor.ForkedFromId} else {[string]$cursor.ParentThreadId}
                if ([string]::IsNullOrWhiteSpace($parent)) { break }
                [void]$evidenceIds.Add($parent); $cursor=$byId[$parent]
            }
        }
        foreach ($item in @($metadata)) {
            if ($allSelected -or $evidenceIds.Contains([string]$item.SessionId)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$item.Path) -and [Int64]$item.ParsedOffset -gt 0) { $ends[[string]$item.Path] = [Int64]$item.ParsedOffset }
            }
        }
        $thresholds=New-Object hashtable ([StringComparer]::OrdinalIgnoreCase); $prices=Get-ExplorerPricing -Paths $resolved
        foreach($entry in @($prices.models)){if(-not [string]::IsNullOrWhiteSpace([string]$entry.id)){$thresholds[[string]$entry.id]=if($null -ne $entry.PSObject.Properties['longContextThreshold']){[Int64]$entry.longContextThreshold}else{0L};foreach($alias in @($entry.aliases)){if(-not [string]::IsNullOrWhiteSpace([string]$alias)){$thresholds[[string]$alias]=[Int64]$thresholds[[string]$entry.id]}}}}
        $countedIds = [string[]]@($selected)
        $aggregate=[TokenRaderIndexer]::AggregateScopedTimeRangeRecordsAtOffsets($connection,$ends,$start,$end,$thresholds,$CancellationToken,$ProgressState,$countedIds)
        $priced=& $core { param($a,$p) ConvertFrom-TokenRaderPricedAggregate -Aggregate $a -PricingDocument $p } $aggregate $prices
        $coverage=Get-ExplorerCoverage -Connection $connection -Paths $resolved -Metadata $metadata -StartAt $StartAt -EndAt $EndAt -ExplorerSource $sourceExplorer
        [pscustomobject]@{Usage=$priced.Usage;TotalCost=[double]$priced.TotalCost;Items=@($priced.Items);Count=[Int64]$aggregate.CountedEvents;PricingComplete=[bool]$priced.PricingComplete;Coverage=$coverage;CoverageMessage=[string]$coverage.Message;Models=@($priced.Models);RawEvents=[Int64]$aggregate.RawEvents;DuplicateEventsDropped=[Int64]$aggregate.DuplicateEventsDropped;InheritedEventsDropped=[Int64]$aggregate.InheritedEventsDropped;FirstCountedAt=$aggregate.FirstCountedAt;LastCountedAt=$aggregate.LastCountedAt;Source=$coverage.Source}
    } finally { $connection.Close();$connection.Dispose() }
}

function Update-TokenRaderExplorerIndex {
    [CmdletBinding()]
    param([string]$ProjectRoot=$PSScriptRoot,$Paths=$null,[Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None,[hashtable]$ProgressState=$null)
    $resolved=Get-ExplorerPaths -ProjectRoot $ProjectRoot -Paths $Paths
    $core=Get-ExplorerCore
    $sessions=[string]$resolved.SessionsRoot
    if ([string]::IsNullOrWhiteSpace($sessions)) { $sessions=(Get-TokenRaderPaths -ProjectRoot $resolved.ProjectRoot).SessionsRoot }
    if (-not (Test-Path -LiteralPath $sessions -PathType Container)) { throw 'Source sessions directory does not exist.' }
    if ([string]::Equals($resolved.ExplorerIndexPath,$resolved.MainIndexPath,[StringComparison]::OrdinalIgnoreCase)) { throw 'Explorer index must be separate from the measurement index.' }
    $CancellationToken.ThrowIfCancellationRequested()
    $dir=Split-Path -Parent $resolved.ExplorerIndexPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # No environment-variable or Core global-index mutation: these are shared
    # by other runspaces in the same application process.
    $builder=New-Object System.Data.SQLite.SQLiteConnectionStringBuilder
    $builder.DataSource=$resolved.ExplorerIndexPath; $builder.DefaultTimeout=5
    $db=New-Object System.Data.SQLite.SQLiteConnection($builder.ConnectionString)
    $lock=$null
    try {
        $lock=[IO.FileStream]::new((Join-Path $dir 'backfill.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $db.Open(); [TokenRaderIndexer]::CreateSchema($db)
        [TokenRaderIndexer]::SetSetting($db,'explorer_backfill_complete','0')
        $known=@{}; $byId=@{}
        foreach ($row in @([TokenRaderIndexer]::GetFileMetadata($db).Rows)) { $known[[string]$row.path]=$row }
        if ($null -ne $ProgressState) { $ProgressState.Stage='枚举本机保留日志' }
        $files=@(Get-ChildItem -LiteralPath $sessions -Recurse -File -Filter '*.jsonl' -ErrorAction Stop)
        $work=@(foreach ($file in $files) {
            $CancellationToken.ThrowIfCancellationRequested()
            $path=[IO.Path]::GetFullPath($file.FullName).ToLowerInvariant()
            $old=$known[$path]
            $unchanged=$null -ne $old -and [Int64]$old.length -eq $file.Length -and [Int64]$old.last_write_ticks -eq $file.LastWriteTimeUtc.Ticks
            $meta=if ($unchanged) { [pscustomobject]@{SessionId=[string]$old.session_id;Cwd=[string]$old.cwd;ParentThreadId=[string]$old.parent_thread_id;ForkedFromId=[string]$old.forked_from_id} } else { Get-TokenRaderSessionMetadata -FilePath $path }
            $byId[[string]$meta.SessionId]=$meta
            [pscustomobject]@{Path=$path;File=$file;Old=$old;Meta=$meta;Unchanged=$unchanged;Root=[string]$meta.SessionId;Depth=0}
        })
        foreach ($item in $work) {
            $seen=@{}; $cursor=$item.Meta
            while ($null -ne $cursor) {
                $id=[string]$cursor.SessionId
                if ($seen.ContainsKey($id)) { break }
                $seen[$id]=$true; $item.Root=$id
                $parent=if ([string]::IsNullOrWhiteSpace([string]$cursor.ParentThreadId)) { [string]$cursor.ForkedFromId } else { [string]$cursor.ParentThreadId }
                if ([string]::IsNullOrWhiteSpace($parent)) { break }
                $item.Root=$parent; $item.Depth++; $cursor=$byId[$parent]
            }
        }
        $revision=[TokenRaderIndexer]::GetIndexRevision($db)+1L
        $roots=@{}; foreach ($item in $work) { $roots[[string]$item.Meta.SessionId]=[string]$item.Root }
        [void][TokenRaderIndexer]::BackfillSessionRoots($db,$roots,$revision)
        $count=0L; $done=0
        foreach ($item in @($work | Sort-Object Depth,Path)) {
            $CancellationToken.ThrowIfCancellationRequested()
            $done++
            if ($null -ne $ProgressState) { $ProgressState.Stage=('补齐历史：{0}/{1} 个文件' -f $done,$work.Count) }
            if ($item.Unchanged) { continue }
            $start=if ($null -ne $item.Old) { [Int64]$item.Old.parsed_offset } else { 0L }
            if ($null -ne $item.Old -and ($item.File.Length -lt $start -or ($item.File.Length -le [Int64]$item.Old.length -and $item.File.LastWriteTimeUtc.Ticks -ne [Int64]$item.Old.last_write_ticks))) {
                $cmd=$db.CreateCommand()
                try { $cmd.CommandText='DELETE FROM token_records WHERE source_path=@path'; [void]$cmd.Parameters.AddWithValue('@path',$item.Path); [void]$cmd.ExecuteNonQuery() } finally { $cmd.Dispose() }
                [void][TokenRaderIndexer]::DeleteToolRecordsBySourcePath($db,$item.Path)
                [TokenRaderIndexer]::RemoveFileMetadata($db,$item.Path)
                $start=0L
            }
            $parent=if ([string]::IsNullOrWhiteSpace([string]$item.Meta.ParentThreadId)) {[string]$item.Meta.ForkedFromId} else {[string]$item.Meta.ParentThreadId}
            $stream=[IO.FileStream]::new($item.Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            try {
                $limit=[Math]::Min([Int64]$item.File.Length,$stream.Length)
                while ($start -lt $limit) {
                    $CancellationToken.ThrowIfCancellationRequested()
                    # End chunks on complete lines, and poll cancellation between
                    # chunks instead of parsing a huge source file in one call.
                    $end=[Math]::Min($limit,$start+4MB)
                    [void]$stream.Seek($end,[IO.SeekOrigin]::Begin)
                    $scan=New-Object byte[] 65536
                    while ($end -lt $limit) {
                        $CancellationToken.ThrowIfCancellationRequested()
                        $read=$stream.Read($scan,0,[int][Math]::Min($scan.Length,$limit-$end))
                        if ($read -le 0) { break }
                        $newline=[Array]::IndexOf($scan,[byte]10,0,$read)
                        if ($newline -ge 0) { $end += $newline+1; break }
                        $end += $read
                    }
                    if ($end -eq $limit) {
                        $probe=$end; $found=$false; $buffer=New-Object byte[] 65536
                        while ($probe -gt $start -and -not $found) {
                            $CancellationToken.ThrowIfCancellationRequested()
                            $begin=[Math]::Max($start,$probe-$buffer.Length); [void]$stream.Seek($begin,[IO.SeekOrigin]::Begin)
                            $read=$stream.Read($buffer,0,[int]($probe-$begin))
                            for ($i=$read-1;$i -ge 0;$i--) { if ($buffer[$i] -eq 10) { $end=$begin+$i+1; $found=$true; break } }
                            $probe=$begin
                        }
                        if (-not $found) { break }
                    }
                    if ($end -le $start) { break }
                    $count += [TokenRaderIndexer]::ImportFile($db,$item.Path,$start,$end,$item.Root,$parent,$revision)
                    $start=$end
                    [TokenRaderIndexer]::UpdateFileMetadata($db,$item.Path,$item.File.Length,$item.File.LastWriteTimeUtc.Ticks,$start,$item.Meta.SessionId,$item.Meta.Cwd,$item.Meta.ParentThreadId,$item.Meta.ForkedFromId,$item.Root)
                }
                # Empty/new files still need a catalog row.
                [TokenRaderIndexer]::UpdateFileMetadata($db,$item.Path,$item.File.Length,$item.File.LastWriteTimeUtc.Ticks,$start,$item.Meta.SessionId,$item.Meta.Cwd,$item.Meta.ParentThreadId,$item.Meta.ForkedFromId,$item.Root)
            } finally { $stream.Dispose() }
        }
        $CancellationToken.ThrowIfCancellationRequested()
        [void][TokenRaderIndexer]::IncrementIndexRevision($db)
        [TokenRaderIndexer]::SetSetting($db,'explorer_backfill_complete','1')
        [TokenRaderIndexer]::SetSetting($db,'explorer_backfill_completed_at',[DateTimeOffset]::Now.ToString('o'))
        [pscustomobject]@{DbPath=$resolved.ExplorerIndexPath;SyncComplete=$true;ImportedFiles=$done;ImportedRecords=$count;CoverageComplete=$true}
    } finally { $db.Dispose(); if ($null -ne $lock) { $lock.Dispose() } }
}

Export-ModuleMember -Function Get-TokenRaderExplorerCatalog,Get-TokenRaderExplorerResult,Update-TokenRaderExplorerIndex
