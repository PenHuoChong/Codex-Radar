Set-StrictMode -Version Latest

function Get-TokenRaderPaths {
    param([string]$ProjectRoot = $PSScriptRoot)

    $codexRoot = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    } else {
        Join-Path $HOME '.codex'
    }

    [pscustomobject]@{
        ProjectRoot = $ProjectRoot
        CodexRoot = $codexRoot
        SessionsRoot = Join-Path $codexRoot 'sessions'
        AccountMetadataPath = Join-Path $codexRoot '.cockpit_codex_auth.json'
        PricingPath = Join-Path $ProjectRoot 'pricing.json'
    }
}

function Get-TokenRaderAccount {
    param([Parameter(Mandatory = $true)][string]$CodexRoot)

    # This intentionally does not read auth.json, because that file contains access,
    # ID, and refresh tokens. The small cockpit metadata file contains labels only.
    $path = Join-Path $CodexRoot '.cockpit_codex_auth.json'
    $fallback = [pscustomobject]@{
        Found = $false
        Email = ''
        AccountId = ''
        AccountIdShort = ''
        WrittenAt = $null
        DisplayName = '未检测到当前账号'
    }
    if (-not (Test-Path -LiteralPath $path)) { return $fallback }

    try {
        $metadata = Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json
        $accountId = [string]$metadata.account_id
        $email = [string]$metadata.email
        $shortId = $accountId
        if ($shortId.Length -gt 18) {
            $shortId = $shortId.Substring(0, 8) + '…' + $shortId.Substring($shortId.Length - 6)
        }
        $display = if (-not [string]::IsNullOrWhiteSpace($email)) { $email }
                   elseif (-not [string]::IsNullOrWhiteSpace($shortId)) { $shortId }
                   else { '当前 Codex 账号' }
        $writtenAt = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$metadata.written_at)) {
            try { $writtenAt = [DateTimeOffset]::Parse([string]$metadata.written_at).ToLocalTime() } catch { }
        }
        [pscustomobject]@{
            Found = $true
            Email = $email
            AccountId = $accountId
            AccountIdShort = $shortId
            WrittenAt = $writtenAt
            DisplayName = $display
        }
    } catch {
        return $fallback
    }
}

function Format-TokenRaderFileSize {
    param([Int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Get-TokenRaderSessionFiles {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [int]$MaximumFiles = 200
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First ([Math]::Max(1, $MaximumFiles)))

    $result = foreach ($file in $files) {
        $match = [regex]::Match($file.BaseName, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')
        $sessionId = if ($match.Success) { $match.Groups[1].Value } else { $file.BaseName }
        $shortId = if ($sessionId.Length -gt 8) { $sessionId.Substring(0, 8) } else { $sessionId }
        [pscustomobject]@{
            FilePath = $file.FullName
            SessionId = $sessionId
            ShortId = $shortId
            LastWriteTime = $file.LastWriteTime
            LastWriteTimeUtc = $file.LastWriteTimeUtc
            Length = [Int64]$file.Length
            DisplayName = ('{0:MM-dd HH:mm}   {1}   {2}' -f $file.LastWriteTime, $shortId, (Format-TokenRaderFileSize $file.Length))
        }
    }
    return @($result)
}

function New-TokenRaderUsage {
    param(
        [Int64]$InputTokens,
        [Int64]$CachedTokens,
        [Int64]$OutputTokens,
        [Int64]$ReasoningOutputTokens = 0
    )

    $cachedTokens = [Math]::Min([Math]::Max([Int64]0, $CachedTokens), [Math]::Max([Int64]0, $InputTokens))
    $inputTokens = [Math]::Max([Int64]0, $InputTokens)
    $outputTokens = [Math]::Max([Int64]0, $OutputTokens)
    $uncachedTokens = [Math]::Max([Int64]0, $inputTokens - $cachedTokens)
    $totalTokens = $inputTokens + $outputTokens
    $hitRate = if ($inputTokens -gt 0) { ($cachedTokens * 100.0) / $inputTokens } else { 0.0 }

    [pscustomobject]@{
        Input = $inputTokens
        Cached = $cachedTokens
        Uncached = $uncachedTokens
        Output = $outputTokens
        ReasoningOutput = [Math]::Max([Int64]0, $ReasoningOutputTokens)
        Total = $totalTokens
        CacheHitRate = [double]$hitRate
    }
}

function Get-TokenRaderPropertyValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-TokenRaderFirstPresentInt64 {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in @($Names)) {
        if ($null -eq $Object) { break }
        $property = $Object.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) { continue }
        $value = $property.Value
        try {
            if ($value -is [string]) {
                $text = $value.Trim()
                if ([string]::IsNullOrWhiteSpace($text)) { continue }
                [Int64]$parsed = 0
                if ([Int64]::TryParse($text, [Globalization.NumberStyles]::Integer,
                        [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                    if ($parsed -ge 0) { return [pscustomobject]@{ Found = $true; Value = $parsed } }
                }
                continue
            }
            [Int64]$converted = [Convert]::ToInt64($value, [Globalization.CultureInfo]::InvariantCulture)
            if ($converted -lt 0) { continue }
            return [pscustomobject]@{
                Found = $true
                Value = $converted
            }
        } catch {
            # An invalid earlier alias must not hide a later valid alias.
        }
    }
    return [pscustomobject]@{ Found = $false; Value = 0L }
}

function Get-TokenRaderFirstFastInt64 {
    param(
        [Parameter(Mandatory = $true)][string]$InnerText,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    foreach ($name in @($Names)) {
        $escapedName = [regex]::Escape($name)
        # Keep the alias order explicit instead of letting JSON property order
        # decide which cache-write spelling wins.  null/invalid values are
        # skipped, while a valid numeric zero remains a real observation.
        $match = [regex]::Match($InnerText, '"' + $escapedName + '"\s*:\s*(?:(?:"([^"]*)")|(-?\d+)|null)')
        if (-not $match.Success -or
            (-not $match.Groups[1].Success -and -not $match.Groups[2].Success)) { continue }
        $text = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        [Int64]$parsed = 0
        if ([Int64]::TryParse($text.Trim(), [Globalization.NumberStyles]::Integer,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            if ($parsed -ge 0) { return [pscustomobject]@{ Found = $true; Value = $parsed } }
        }
    }
    return [pscustomobject]@{ Found = $false; Value = 0L }
}

function ConvertTo-TokenRaderUsage {
    param([Parameter(Mandatory = $true)]$RawUsage)

    $reasoningRaw = Get-TokenRaderPropertyValue -Object $RawUsage -Name 'reasoning_output_tokens'
    $reasoning = if ($null -ne $reasoningRaw) { ConvertTo-TokenRaderSafeInt64 $reasoningRaw } else { 0L }
    # Codex has used several names for the cache-read portion over time.  The
    # canonical cached_input_tokens field wins, then the equivalent
    # cache_read_tokens/cached_tokens aliases.  Missing cache fields mean zero,
    # not a malformed usage record.
    $cachedRaw = $null
    foreach ($name in @('cached_input_tokens', 'cache_read_tokens', 'cached_tokens')) {
        if ($null -ne $RawUsage.PSObject.Properties[$name]) {
            $cachedRaw = $RawUsage.PSObject.Properties[$name].Value
            break
        }
    }
    New-TokenRaderUsage `
        -InputTokens (ConvertTo-TokenRaderSafeInt64 (Get-TokenRaderPropertyValue -Object $RawUsage -Name 'input_tokens')) `
        -CachedTokens $(if ($null -eq $cachedRaw) { 0L } else { ConvertTo-TokenRaderSafeInt64 $cachedRaw }) `
        -OutputTokens (ConvertTo-TokenRaderSafeInt64 (Get-TokenRaderPropertyValue -Object $RawUsage -Name 'output_tokens')) `
        -ReasoningOutputTokens $reasoning
}

# JSON produced by different Codex builds may encode numeric metadata as a
# number, a numeric string, null, or an unexpected value.  Metadata must never
# abort an otherwise valid token record, so keep conversion tolerant and
# return the caller-provided default when the value is not a finite Int64.
function ConvertTo-TokenRaderSafeInt64 {
    param(
        $Value,
        [Int64]$Default = 0
    )
    if ($null -eq $Value -or $Value -is [DBNull]) { return $Default }
    try {
        if ($Value -is [string]) {
            $text = $Value.Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
            [Int64]$parsed = 0
            if ([Int64]::TryParse($text, [Globalization.NumberStyles]::Integer,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                return $parsed
            }
            return $Default
        }
        return [Convert]::ToInt64($Value, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $Default
    }
}

function Get-TokenRaderSessionIdFromPath {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $baseName = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    $match = [regex]::Match($baseName, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$')
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    return $baseName.ToLowerInvariant()
}

function Get-TokenRaderSessionMetadata {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $fallbackId = Get-TokenRaderSessionIdFromPath -FilePath $FilePath
    $fallback = [pscustomobject]@{
        SessionId = $fallbackId
        ParentThreadId = ''
        ForkedFromId = ''
        RootHint = $fallbackId
        Cwd = ''
    }
    if (-not (Test-Path -LiteralPath $FilePath)) { return $fallback }

    $stream = $null
    $reader = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 65536)
        for ($i = 0; $i -lt 64 -and -not $reader.EndOfStream; $i++) {
            $line = $reader.ReadLine()
            if ($line.IndexOf('session_meta', [System.StringComparison]::Ordinal) -lt 0) { continue }
            try { $record = $line.TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { continue }
            if ($record.type -ne 'session_meta' -or $null -eq $record.payload) { continue }
            $payload = $record.payload
            $sessionId = if ($null -ne $payload.PSObject.Properties['id'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.id)) {
                ([string]$payload.id).ToLowerInvariant()
            } elseif ($null -ne $payload.PSObject.Properties['session_id'] -and -not [string]::IsNullOrWhiteSpace([string]$payload.session_id)) {
                ([string]$payload.session_id).ToLowerInvariant()
            } else { $fallbackId }
            $parentId = if ($null -ne $payload.PSObject.Properties['parent_thread_id']) { ([string]$payload.parent_thread_id).ToLowerInvariant() } else { '' }
            $forkedId = if ($null -ne $payload.PSObject.Properties['forked_from_id']) { ([string]$payload.forked_from_id).ToLowerInvariant() } else { '' }
            $cwd = if ($null -ne $payload.PSObject.Properties['cwd']) { [string]$payload.cwd } else { '' }
            return [pscustomobject]@{
                SessionId = $sessionId
                ParentThreadId = $parentId
                ForkedFromId = $forkedId
                RootHint = if (-not [string]::IsNullOrWhiteSpace($parentId)) { $parentId } elseif (-not [string]::IsNullOrWhiteSpace($forkedId)) { $forkedId } else { $sessionId }
                Cwd = $cwd
            }
        }
    } catch {
        return $fallback
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
    return $fallback
}

function Get-TokenRaderProjects {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [int]$MaximumFiles = 0
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($MaximumFiles -gt 0 -and $files.Count -gt $MaximumFiles) {
        $files = @($files | Select-Object -First $MaximumFiles)
    }

    $groups = @{}
    foreach ($file in $files) {
        $metadata = Get-TokenRaderSessionMetadata -FilePath $file.FullName
        $cwd = [string]$metadata.Cwd
        if ([string]::IsNullOrWhiteSpace($cwd)) { continue }
        try { $cwd = [IO.Path]::GetFullPath($cwd).TrimEnd([char]'\', [char]'/') } catch { $cwd = $cwd.TrimEnd([char]'\', [char]'/') }
        if ([string]::IsNullOrWhiteSpace($cwd)) { continue }
        $key = $cwd.ToLowerInvariant()
        if (-not $groups.ContainsKey($key)) {
            $name = [IO.Path]::GetFileName($cwd)
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $cwd }
            $groups[$key] = [pscustomobject]@{
                ProjectPath = $cwd
                ProjectName = $name
                LastWriteTime = $file.LastWriteTime
                LastWriteTimeUtc = $file.LastWriteTimeUtc
                TotalBytes = [Int64]0
                FilePaths = New-Object System.Collections.ArrayList
            }
        }
        $group = $groups[$key]
        [void]$group.FilePaths.Add($file.FullName)
        $group.TotalBytes += [Int64]$file.Length
        if ($file.LastWriteTimeUtc -gt $group.LastWriteTimeUtc) {
            $group.LastWriteTime = $file.LastWriteTime
            $group.LastWriteTimeUtc = $file.LastWriteTimeUtc
        }
    }

    $result = foreach ($group in $groups.Values) {
        $paths = @($group.FilePaths | Sort-Object)
        $signatureParts = foreach ($path in $paths) {
            try {
                $item = Get-Item -LiteralPath $path -ErrorAction Stop
                '{0}|{1}|{2}' -f $path, [Int64]$item.Length, $item.LastWriteTimeUtc.Ticks
            } catch { '{0}|missing' -f $path }
        }
        [pscustomobject]@{
            ProjectPath = [string]$group.ProjectPath
            ProjectName = [string]$group.ProjectName
            SessionCount = $paths.Count
            LastWriteTime = $group.LastWriteTime
            LastWriteTimeUtc = $group.LastWriteTimeUtc
            TotalBytes = [Int64]$group.TotalBytes
            FilePaths = $paths
            Signature = $signatureParts -join ';'
            DisplayName = ('{0}  ·  {1} 个日志' -f [string]$group.ProjectName, $paths.Count)
        }
    }
    return @($result | Sort-Object LastWriteTimeUtc -Descending)
}

function ConvertFrom-TokenRaderUsageTextFast {
    param([Parameter(Mandatory = $true)][string]$InnerText)

    # Builds the same usage object as New-TokenRaderUsage without the
    # function-call and [Math]::* overhead. Regex-extracted values are already
    # non-negative, so the original clamping rules reduce to a single check.
    $inputMatch = [regex]::Match($InnerText, '"input_tokens"\s*:\s*"?(\d+)"?')
    $cachedMatch = [regex]::Match($InnerText, '"(?:cached_input_tokens|cache_read_tokens|cached_tokens)"\s*:\s*"?(\d+)"?')
    $outputMatch = [regex]::Match($InnerText, '"output_tokens"\s*:\s*"?(\d+)"?')
    if (-not $inputMatch.Success -or -not $outputMatch.Success) { return $null }
    $reasoningMatch = [regex]::Match($InnerText, '"reasoning_output_tokens"\s*:\s*"?(\d+)"?')

    $inputTokens = [Int64]$inputMatch.Groups[1].Value
    $cachedTokens = if ($cachedMatch.Success) { [Int64]$cachedMatch.Groups[1].Value } else { 0L }
    $outputTokens = [Int64]$outputMatch.Groups[1].Value
    $reasoningTokens = if ($reasoningMatch.Success) { [Int64]$reasoningMatch.Groups[1].Value } else { 0 }
    if ($cachedTokens -gt $inputTokens) { $cachedTokens = $inputTokens }
    $uncachedTokens = $inputTokens - $cachedTokens
    $totalTokens = $inputTokens + $outputTokens
    $hitRate = if ($inputTokens -gt 0) { ($cachedTokens * 100.0) / $inputTokens } else { 0.0 }

    [pscustomobject]@{
        Input = $inputTokens
        Cached = $cachedTokens
        Uncached = $uncachedTokens
        Output = $outputTokens
        ReasoningOutput = $reasoningTokens
        Total = $totalTokens
        CacheHitRate = [double]$hitRate
    }
}

function ConvertTo-TokenRaderResetTime {
    param(
        $Value,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
        [bool]$RelativeSeconds = $false
    )

    if ($null -eq $Value) { return $null }
    if ($RelativeSeconds) {
        try { return $ObservedAt.AddSeconds([double]$Value).ToLocalTime() } catch { return $null }
    }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToLocalTime() }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToLocalTime() }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $number = [Int64]0
    if ([Int64]::TryParse($text, [ref]$number)) {
        try {
            if ([Math]::Abs([double]$number) -ge 100000000000.0) {
                return [DateTimeOffset]::FromUnixTimeMilliseconds($number).ToLocalTime()
            }
            return [DateTimeOffset]::FromUnixTimeSeconds($number).ToLocalTime()
        } catch { return $null }
    }
    try { return [DateTimeOffset]::Parse($text).ToLocalTime() } catch { return $null }
}

function Get-TokenRaderResetIdentity {
    param(
        [int]$WindowMinutes,
        $ResetsAt
    )

    if ($null -eq $ResetsAt) { return '' }
    try {
        $utcMinute = [Math]::Floor(([DateTimeOffset]$ResetsAt).ToUniversalTime().ToUnixTimeSeconds() / 60.0)
        return ('{0}|{1}' -f $WindowMinutes, [Int64]$utcMinute)
    } catch { return '' }
}

function Get-TokenRaderWindowPercentResolution {
    param($Window)

    if ($null -ne $Window -and $null -ne $Window.PSObject.Properties['PercentResolution']) {
        $declared = [double]$Window.PercentResolution
        if ($declared -gt 0 -and $declared -le 100) { return $declared }
    }
    if ($null -eq $Window) { return 1.0 }
    $text = ([double]$Window.UsedPercent).ToString('0.################', [Globalization.CultureInfo]::InvariantCulture)
    $separator = $text.IndexOf('.')
    if ($separator -lt 0) { return 1.0 }
    $digits = $text.Length - $separator - 1
    if ($digits -le 0) { return 1.0 }
    return [Math]::Pow(10.0, -$digits)
}

function Get-TokenRaderRateWindowKind {
    param([int]$WindowMinutes)

    if ($WindowMinutes -ge 240 -and $WindowMinutes -le 360) { return 'FiveHour' }
    if ($WindowMinutes -ge 9000 -and $WindowMinutes -le 11520) { return 'Weekly' }
    return ''
}

function New-TokenRaderEventFingerprint {
    param(
        [Parameter(Mandatory = $true)][DateTimeOffset]$Timestamp,
        [string]$Model,
        $TotalUsage,
        $CallUsage,
        [bool]$TotalAvailable = $true,
        [bool]$CallAvailable = $true
    )

    $totalParts = if ($TotalAvailable -and $null -ne $TotalUsage) {
        @($TotalUsage.Input, $TotalUsage.Cached, $TotalUsage.Output, $TotalUsage.ReasoningOutput)
    } else { @('missing-total') }
    $callParts = if ($CallAvailable -and $null -ne $CallUsage) {
        @($CallUsage.Input, $CallUsage.Cached, $CallUsage.Output, $CallUsage.ReasoningOutput)
    } else { @('missing-call') }
    $values = @(
        $Timestamp.ToUniversalTime().Ticks,
        ([string]$Model).ToLowerInvariant()
    )
    $values += $totalParts
    $values += $callParts
    $values -join ':'
}

function New-TokenRaderUsageFingerprint {
    param(
        $TotalUsage,
        $CallUsage,
        [bool]$TotalAvailable = $true,
        [bool]$CallAvailable = $true
    )

    $totalParts = if ($TotalAvailable -and $null -ne $TotalUsage) {
        @($TotalUsage.Input, $TotalUsage.Cached, $TotalUsage.Output, $TotalUsage.ReasoningOutput)
    } else { @('missing-total') }
    $callParts = if ($CallAvailable -and $null -ne $CallUsage) {
        @($CallUsage.Input, $CallUsage.Cached, $CallUsage.Output, $CallUsage.ReasoningOutput)
    } else { @('missing-call') }
    $values = @()
    $values += $totalParts
    $values += $callParts
    $values -join ':'
}

function New-TokenRaderCumulativeFingerprint {
    param(
        $TotalUsage,
        [bool]$Available = $true
    )

    if (-not $Available -or $null -eq $TotalUsage) { return $null }
    @(
        $TotalUsage.Input, $TotalUsage.Cached, $TotalUsage.Output, $TotalUsage.ReasoningOutput
    ) -join ':'
}

function ConvertTo-TokenRaderUsageDelta {
    param(
        [Parameter(Mandatory = $true)]$Previous,
        [Parameter(Mandatory = $true)]$Current
    )

    if ($null -eq $Previous -or $null -eq $Current) { return $null }
    $names = @('Input', 'Cached', 'Output', 'ReasoningOutput')
    foreach ($name in $names) {
        if ([Int64]$Current.$name -lt [Int64]$Previous.$name) { return $null }
    }
    $inputDelta = [Int64]$Current.Input - [Int64]$Previous.Input
    $cachedDelta = [Int64]$Current.Cached - [Int64]$Previous.Cached
    $outputDelta = [Int64]$Current.Output - [Int64]$Previous.Output
    $reasoningDelta = [Int64]$Current.ReasoningOutput - [Int64]$Previous.ReasoningOutput
    if ($cachedDelta -gt $inputDelta) { return $null }
    if ($inputDelta -eq 0 -and $cachedDelta -eq 0 -and $outputDelta -eq 0 -and $reasoningDelta -eq 0) {
        return $null
    }
    New-TokenRaderUsage -InputTokens $inputDelta -CachedTokens $cachedDelta `
        -OutputTokens $outputDelta -ReasoningOutputTokens $reasoningDelta
}

function ConvertFrom-TokenRaderRateWindowTextFast {
    param(
        [Parameter(Mandatory = $true)][string]$InnerText,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
        [string]$SourceFile = '',
        [string]$PlanType = ''
    )

    if ([string]::IsNullOrWhiteSpace($InnerText)) { return $null }
    $used = [regex]::Match($InnerText, '"used_percent"\s*:\s*"?([0-9.]+)"?')
    $minutes = [regex]::Match($InnerText, '"window_minutes"\s*:\s*"?(\d+)"?')
    if (-not $used.Success -or -not $minutes.Success) { return $null }
    $usedText = [string]$used.Groups[1].Value
    $usedPercent = [Math]::Max(0.0, [Math]::Min(100.0, [double]$usedText))
    $usedDecimal = $usedText.IndexOf('.')
    $percentResolution = if ($usedDecimal -ge 0 -and $usedDecimal -lt ($usedText.Length - 1)) {
        [Math]::Pow(10.0, -($usedText.Length - $usedDecimal - 1))
    } else { 1.0 }
    $windowMinutes = [int]$minutes.Groups[1].Value
    $resetsAt = $null
    $resetMatch = [regex]::Match($InnerText, '"(?:resets_at|reset_at)"\s*:\s*(?:"([^"]+)"|([-0-9.]+))')
    if ($resetMatch.Success) {
        $resetValue = if ($resetMatch.Groups[1].Success) { $resetMatch.Groups[1].Value } else { $resetMatch.Groups[2].Value }
        $resetsAt = ConvertTo-TokenRaderResetTime -Value $resetValue -ObservedAt $ObservedAt
    } else {
        $relativeMatch = [regex]::Match($InnerText, '"resets_in_seconds"\s*:\s*"?([-0-9.]+)"?')
        if ($relativeMatch.Success) {
            $resetsAt = ConvertTo-TokenRaderResetTime -Value $relativeMatch.Groups[1].Value -ObservedAt $ObservedAt -RelativeSeconds $true
        }
    }
    $usedTokensMatch = [regex]::Match($InnerText, '"used_tokens"\s*:\s*"?(\d+)"?')
    $remainingTokensMatch = [regex]::Match($InnerText, '"remaining_tokens"\s*:\s*"?(\d+)"?')
    $limitTokensMatch = [regex]::Match($InnerText, '"limit_tokens"\s*:\s*"?(\d+)"?')
    [pscustomobject]@{
        UsedPercent = $usedPercent
        RemainingPercent = 100.0 - $usedPercent
        WindowMinutes = $windowMinutes
        ResetsAt = $resetsAt
        ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes $windowMinutes -ResetsAt $resetsAt
        ObservedAt = $ObservedAt
        SourceFile = $SourceFile
        PlanType = $PlanType
        PercentResolution = $percentResolution
        UsedTokens = if ($usedTokensMatch.Success) { ConvertTo-TokenRaderSafeInt64 $usedTokensMatch.Groups[1].Value } else { $null }
        RemainingTokens = if ($remainingTokensMatch.Success) { ConvertTo-TokenRaderSafeInt64 $remainingTokensMatch.Groups[1].Value } else { $null }
        LimitTokens = if ($limitTokensMatch.Success) { ConvertTo-TokenRaderSafeInt64 $limitTokensMatch.Groups[1].Value } else { $null }
    }
}

function ConvertFrom-TokenRaderTokenLineFast {
    param(
        [Parameter(Mandatory = $true)][string]$LineText,
        [string]$Model,
        [string]$SourceFile = '',
        [string]$ServiceTier = ''
    )

    # Fast path: extract the fields this program needs from a well-formed
    # token_count line without a full JSON parse (ConvertFrom-Json is slow on
    # Windows PowerShell 5.1). Any structural mismatch falls back to the full
    # JSON parser so behaviour is always identical to the original logic.
    $structure = [regex]::Match($LineText, '^\{\s*"timestamp"\s*:\s*"([^"]+)"\s*,\s*"type"\s*:\s*"(?:event_msg|token_count)"\s*,\s*"payload"\s*:\s*\{\s*"type"\s*:\s*"token_count"\s*,\s*"info"\s*:\s*\{')
    if (-not $structure.Success) { return $null }
    # Tier metadata can occur on payload/info or the response. Use the JSON
    # path for these records to avoid treating nested requested settings as
    # an actual response tier.
    if ($LineText.Contains('service_tier')) { return $null }

    $totalMatch = [regex]::Match($LineText, '"total_token_usage"\s*:\s*\{([^{}]*)\}')
    $lastMatch = [regex]::Match($LineText, '"last_token_usage"\s*:\s*\{([^{}]*)\}')
    if (-not $totalMatch.Success -and -not $lastMatch.Success) { return $null }

    $totalUsage = if ($totalMatch.Success) {
        ConvertFrom-TokenRaderUsageTextFast -InnerText $totalMatch.Groups[1].Value
    } else { $null }
    $callUsage = if ($lastMatch.Success) {
        ConvertFrom-TokenRaderUsageTextFast -InnerText $lastMatch.Groups[1].Value
    } else { $null }
    if ($totalMatch.Success -and $null -eq $totalUsage) { return $null }
    if ($lastMatch.Success -and $null -eq $callUsage) { return $null }
    $contextMatch = [regex]::Match($LineText, '"model_context_window"\s*:\s*"?(\d+)"?')
    $cacheWrite = if ($lastMatch.Success) {
        Get-TokenRaderFirstFastInt64 -InnerText $lastMatch.Groups[1].Value `
            -Names @('cache_creation_tokens', 'cache_write_tokens', 'cache_creation_input_tokens', 'cache_write_input_tokens')
    } else {
        [pscustomobject]@{ Found = $false; Value = 0L }
    }
    $requestMatch = [regex]::Match($LineText, '"request_id"\s*:\s*"([^"]*)"')
    $responseMatch = [regex]::Match($LineText, '"response_id"\s*:\s*"([^"]*)"')
    $turnMatch = [regex]::Match($LineText, '"turn_id"\s*:\s*"([^"]*)"')

    $timestamp = [DateTimeOffset]::Now
    try { $timestamp = [DateTimeOffset]::Parse($structure.Groups[1].Value).ToLocalTime() } catch { }

    # Events without a rate_limits block carry no rate-limit snapshot; the
    # interval aggregation treats that exactly like a snapshot with empty
    # windows, so a plain $null is equivalent and much cheaper.
    $rateLimits = $null
    if ($LineText.Contains('rate_limits')) {
        $planMatch = [regex]::Match($LineText, '"plan_type"\s*:\s*"([^"]*)"')
        $planType = if ($planMatch.Success) { $planMatch.Groups[1].Value } else { '' }
        $primaryMatch = [regex]::Match($LineText, '"primary"\s*:\s*\{([^{}]*)\}')
        $secondaryMatch = [regex]::Match($LineText, '"secondary"\s*:\s*\{([^{}]*)\}')
        $primaryWindow = if ($primaryMatch.Success) { ConvertFrom-TokenRaderRateWindowTextFast -InnerText $primaryMatch.Groups[1].Value -ObservedAt $timestamp -SourceFile $SourceFile -PlanType $planType } else { $null }
        $secondaryWindow = if ($secondaryMatch.Success) { ConvertFrom-TokenRaderRateWindowTextFast -InnerText $secondaryMatch.Groups[1].Value -ObservedAt $timestamp -SourceFile $SourceFile -PlanType $planType } else { $null }
        if (($primaryMatch.Success -and $null -eq $primaryWindow) -or ($secondaryMatch.Success -and $null -eq $secondaryWindow)) { return $null }

        # Inline equivalent of ConvertTo-TokenRaderRateLimits over the two
        # windows in the original primary-then-secondary order.
        $fiveHour = $null
        $weekly = $null
        if ($null -ne $primaryWindow) {
            $kind = Get-TokenRaderRateWindowKind -WindowMinutes $primaryWindow.WindowMinutes
            if ($kind -eq 'FiveHour') { $fiveHour = $primaryWindow }
            elseif ($kind -eq 'Weekly') { $weekly = $primaryWindow }
        }
        if ($null -ne $secondaryWindow) {
            $kind = Get-TokenRaderRateWindowKind -WindowMinutes $secondaryWindow.WindowMinutes
            if ($kind -eq 'FiveHour') { $fiveHour = $secondaryWindow }
            elseif ($kind -eq 'Weekly') { $weekly = $secondaryWindow }
        }
        $rateLimits = [pscustomobject]@{
            ObservedAt = $timestamp
            PlanType = $planType
            FiveHour = $fiveHour
            Weekly = $weekly
        }
    }

    $fingerprint = New-TokenRaderEventFingerprint -Timestamp $timestamp -Model $Model `
        -TotalUsage $totalUsage -CallUsage $callUsage -TotalAvailable $totalMatch.Success -CallAvailable $lastMatch.Success
    $usageFingerprint = New-TokenRaderUsageFingerprint -TotalUsage $totalUsage -CallUsage $callUsage `
        -TotalAvailable $totalMatch.Success -CallAvailable $lastMatch.Success
    return [pscustomobject]@{
        Timestamp = $timestamp
        Model = $Model
        ServiceTier = ConvertTo-TokenRaderServiceTier $ServiceTier
        ServiceTierSource = 'turn_context'
        Total = $totalUsage
        Call = $callUsage
        HasTotal = [bool]$totalMatch.Success
        HasCall = [bool]$lastMatch.Success
        CallAvailable = [bool]$lastMatch.Success
        CallDerived = $false
        RequestId = if ($requestMatch.Success) { $requestMatch.Groups[1].Value } else { '' }
        ResponseId = if ($responseMatch.Success) { $responseMatch.Groups[1].Value } else { '' }
        TurnId = if ($turnMatch.Success) { $turnMatch.Groups[1].Value } else { '' }
        Fingerprint = $fingerprint
        UsageFingerprint = $usageFingerprint
        RateLimits = $rateLimits
        ModelContextWindow = if ($contextMatch.Success) { ConvertTo-TokenRaderSafeInt64 $contextMatch.Groups[1].Value } else { 0L }
        CacheCreationTokens = [Math]::Max(0L, [Int64]$cacheWrite.Value)
        CacheWriteObservable = [bool]$cacheWrite.Found
    }
}

function Add-TokenRaderLineEvent {
    param(
        [Parameter(Mandatory = $true)][string]$LineText,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$Events
    )

    if ([string]::IsNullOrWhiteSpace($LineText)) { return }
    if ($null -eq $State.PSObject.Properties['ServiceTier']) { $State | Add-Member -NotePropertyName ServiceTier -NotePropertyValue '' }
    $trimmed = $LineText.TrimStart([char]0xFEFF)
    $hasTurnContext = $trimmed.Contains('turn_context')
    $hasTokenCount = $trimmed.Contains('token_count')
    if (-not $hasTurnContext -and -not $hasTokenCount) { return }

    # Fast paths only apply to complete JSON object lines; anything else falls
    # back to the original full JSON parsing below.
    $completeObject = $trimmed.EndsWith('}')

    if ($hasTurnContext -and $completeObject) {
        $turnMatch = [regex]::Match($trimmed, '^\{\s*"timestamp"\s*:\s*"[^"]*"\s*,\s*"type"\s*:\s*"turn_context"\s*,\s*"payload"\s*:\s*\{[^{}]*"model"\s*:\s*"([^"]+)"[^{}]*\}\s*\}$')
        if ($turnMatch.Success) {
            $State.Model = $turnMatch.Groups[1].Value
            $tierMatch = [regex]::Match($trimmed, '"service_tier"\s*:\s*(?:"([^"]*)"|null)')
            $State.ServiceTier = if ($tierMatch.Success) { ConvertTo-TokenRaderServiceTier $tierMatch.Groups[1].Value } else { '' }
            return
        }
    }

    if ($hasTokenCount -and $completeObject) {
        $event = ConvertFrom-TokenRaderTokenLineFast -LineText $trimmed -Model ([string]$State.Model) -SourceFile ([string]$State.SourceFile) -ServiceTier ([string]$State.ServiceTier)
        if ($null -ne $event) {
            Add-TokenRaderUsageEventWithTier -Event $event -State $State -Events $Events
            return
        }
    }

    # Fallback: full JSON parsing with the original dispatch rules.
    try {
        $record = $trimmed | ConvertFrom-Json
    } catch { return }

    if ($record.type -eq 'turn_context') {
        $State.ServiceTier = Get-TokenRaderMetadataServiceTier -Containers @($record.payload)
        if ($null -ne $record.payload -and $null -ne $record.payload.PSObject.Properties['model']) {
            $candidate = [string]$record.payload.model
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $State.Model = $candidate }
        }
        return
    }

    $isTokenRecord = ($record.type -eq 'event_msg' -and $record.payload.type -eq 'token_count') -or ($record.type -eq 'token_count')
    if (-not $isTokenRecord -or $null -eq $record.payload -or $null -eq $record.payload.info) { return }
    $info = $record.payload.info
    $rawTotal = Get-TokenRaderPropertyValue -Object $info -Name 'total_token_usage'
    $rawCall = Get-TokenRaderPropertyValue -Object $info -Name 'last_token_usage'
    $hasTotal = $null -ne $rawTotal
    $hasCall = $null -ne $rawCall
    if (-not $hasTotal -and -not $hasCall) { return }
    $totalUsage = if ($hasTotal) { ConvertTo-TokenRaderUsage $rawTotal } else { $null }
    $callUsage = if ($hasCall) { ConvertTo-TokenRaderUsage $rawCall } else { $null }
    $timestamp = [DateTimeOffset]::Now
    try { $timestamp = [DateTimeOffset]::Parse([string]$record.timestamp).ToLocalTime() } catch { }
    $rateLimits = ConvertTo-TokenRaderRateLimits -RawRateLimits $(if ($null -ne $record.payload.PSObject.Properties['rate_limits']) { $record.payload.rate_limits } else { $null }) -ObservedAt $timestamp -SourceFile ([string]$State.SourceFile)
    $contextRaw = Get-TokenRaderPropertyValue -Object $info -Name 'model_context_window'
    $contextWindow = if ($null -ne $contextRaw) { ConvertTo-TokenRaderSafeInt64 $contextRaw } else { 0L }
    $cacheWrite = if ($hasCall) {
        Get-TokenRaderFirstPresentInt64 -Object $rawCall `
            -Names @('cache_creation_tokens', 'cache_write_tokens', 'cache_creation_input_tokens', 'cache_write_input_tokens')
    } else {
        [pscustomobject]@{ Found = $false; Value = 0L }
    }
    $requestId = [string](Get-TokenRaderPropertyValue -Object $record.payload -Name 'request_id')
    if ([string]::IsNullOrWhiteSpace($requestId)) {
        $requestId = [string](Get-TokenRaderPropertyValue -Object $record -Name 'request_id')
    }
    if ([string]::IsNullOrWhiteSpace($requestId)) {
        $requestId = [string](Get-TokenRaderPropertyValue -Object $info -Name 'request_id')
    }
    $responseId = [string](Get-TokenRaderPropertyValue -Object $record.payload -Name 'response_id')
    if ([string]::IsNullOrWhiteSpace($responseId)) {
        $responseId = [string](Get-TokenRaderPropertyValue -Object $record -Name 'response_id')
    }
    if ([string]::IsNullOrWhiteSpace($responseId)) {
        $responseId = [string](Get-TokenRaderPropertyValue -Object $info -Name 'response_id')
    }
    $turnId = [string](Get-TokenRaderPropertyValue -Object $record.payload -Name 'turn_id')
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        $turnId = [string](Get-TokenRaderPropertyValue -Object $record -Name 'turn_id')
    }
    if ([string]::IsNullOrWhiteSpace($turnId)) {
        $turnId = [string](Get-TokenRaderPropertyValue -Object $info -Name 'turn_id')
    }
    $fingerprint = New-TokenRaderEventFingerprint -Timestamp $timestamp -Model ([string]$State.Model) `
        -TotalUsage $totalUsage -CallUsage $callUsage -TotalAvailable $hasTotal -CallAvailable $hasCall
    $usageFingerprint = New-TokenRaderUsageFingerprint -TotalUsage $totalUsage -CallUsage $callUsage `
        -TotalAvailable $hasTotal -CallAvailable $hasCall
    $tierEvidence = Get-TokenRaderMetadataServiceTier -Containers @($info, $record.payload, $record) -Fallback ([string]$State.ServiceTier) -IncludeSource
    $event = [pscustomobject]@{
        Timestamp = $timestamp
        Model = [string]$State.Model
        ServiceTier = [string]$tierEvidence.Tier
        ServiceTierSource = [string]$tierEvidence.Source
        Total = $totalUsage
        Call = $callUsage
        HasTotal = [bool]$hasTotal
        HasCall = [bool]$hasCall
        CallAvailable = [bool]$hasCall
        CallDerived = $false
        RequestId = $requestId
        ResponseId = $responseId
        TurnId = $turnId
        Fingerprint = $fingerprint
        UsageFingerprint = $usageFingerprint
        RateLimits = $rateLimits
        ModelContextWindow = $contextWindow
        CacheCreationTokens = [Math]::Max(0L, [Int64]$cacheWrite.Value)
        CacheWriteObservable = [bool]$cacheWrite.Found
    }
    Add-TokenRaderUsageEventWithTier -Event $event -State $State -Events $Events
}

function Resolve-TokenRaderEventUsage {
    param(
        [Parameter(Mandatory = $true)]$Event,
        [Parameter(Mandatory = $true)]$State
    )

    if ($null -eq $State.PSObject.Properties['PreviousTotalKnown']) {
        $State | Add-Member -NotePropertyName PreviousTotalKnown -NotePropertyValue $false
    }
    if ($null -eq $State.PSObject.Properties['PreviousTotalUsage']) {
        $State | Add-Member -NotePropertyName PreviousTotalUsage -NotePropertyValue $null
    }

    $hasTotal = if ($null -ne $Event.PSObject.Properties['HasTotal']) {
        [bool]$Event.HasTotal
    } else { $null -ne $Event.Total }
    $hasCall = if ($null -ne $Event.PSObject.Properties['HasCall']) {
        [bool]$Event.HasCall
    } else { $null -ne $Event.Call }
    if (-not $hasTotal -and -not $hasCall) { return $false }

    $callAvailable = $hasCall -and $null -ne $Event.Call
    $callDerived = $false
    $resetDetected = $false
    if ($hasTotal -and $null -ne $Event.Total) {
        if (-not $hasCall) {
            if ([bool]$State.PreviousTotalKnown) {
                $delta = ConvertTo-TokenRaderUsageDelta -Previous $State.PreviousTotalUsage -Current $Event.Total
                if ($null -ne $delta) {
                    $Event.Call = $delta
                    $callAvailable = $true
                    $callDerived = $true
                } else {
                    # A lower cumulative value is a reset; an unchanged value
                    # is a duplicate/status snapshot. Neither is a call.
                    $Event.Call = New-TokenRaderUsage -InputTokens 0 -CachedTokens 0 -OutputTokens 0 -ReasoningOutputTokens 0
                    $callAvailable = $false
                    $resetDetected = $true
                }
            } else {
                # Without a same-session prior cumulative value, the record is
                # baseline-only. Never charge its historical total as one call.
                $Event.Call = New-TokenRaderUsage -InputTokens 0 -CachedTokens 0 -OutputTokens 0 -ReasoningOutputTokens 0
                $callAvailable = $false
            }
        }
        $State.PreviousTotalUsage = $Event.Total
        $State.PreviousTotalKnown = $true
    } elseif (-not $hasTotal -and $hasCall) {
        # A last-only record may already be included in the next cumulative
        # total. Do not retain an older anchor and charge that call again when
        # a later total-only snapshot arrives.
        $State.PreviousTotalUsage = $null
        $State.PreviousTotalKnown = $false
    }

    $Event.HasTotal = [bool]$hasTotal
    $Event.HasCall = [bool]$hasCall
    $Event.CallAvailable = [bool]$callAvailable
    $Event.CallDerived = [bool]$callDerived
    if ($null -eq $Event.PSObject.Properties['ResetDetected']) {
        $Event | Add-Member -NotePropertyName ResetDetected -NotePropertyValue ([bool]$resetDetected)
    } else { $Event.ResetDetected = [bool]$resetDetected }
    if ($null -eq $Event.PSObject.Properties['CumulativeAvailable']) {
        $Event | Add-Member -NotePropertyName CumulativeAvailable -NotePropertyValue ([bool]$hasTotal)
    } else { $Event.CumulativeAvailable = [bool]$hasTotal }
    $Event.UsageFingerprint = New-TokenRaderUsageFingerprint `
        -TotalUsage $Event.Total -CallUsage $Event.Call `
        -TotalAvailable $hasTotal -CallAvailable $callAvailable
    $Event.Fingerprint = New-TokenRaderEventFingerprint `
        -Timestamp ([DateTimeOffset]$Event.Timestamp) -Model ([string]$Event.Model) `
        -TotalUsage $Event.Total -CallUsage $Event.Call `
        -TotalAvailable $hasTotal -CallAvailable $callAvailable
    return $true
}

function Add-TokenRaderUsageEventWithTier {
    param($Event, $State, $Events)
    if (-not (Resolve-TokenRaderEventUsage -Event $Event -State $State)) { return }
    if ($null -eq $State.PSObject.Properties['TierEvents']) { $State | Add-Member -NotePropertyName TierEvents -NotePropertyValue @{} }
    $key = if ($null -ne $Event.PSObject.Properties['HasTotal'] -and -not [bool]$Event.HasTotal) {
        [string]$Event.Fingerprint
    } else { [string]$Event.UsageFingerprint }
    $previous = $State.TierEvents[$key]
    if ($null -ne $previous) {
        $rank = @{ turn_context = 0; service_tier = 1; response = 2 }
        $oldRank = if ($rank.ContainsKey([string]$previous.ServiceTierSource)) { $rank[[string]$previous.ServiceTierSource] } else { 0 }
        $newRank = if ($rank.ContainsKey([string]$Event.ServiceTierSource)) { $rank[[string]$Event.ServiceTierSource] } else { 0 }
        if ($newRank -gt $oldRank) {
            $previous.ServiceTier = $Event.ServiceTier
            $previous.ServiceTierSource = $Event.ServiceTierSource
        }
    } else { $State.TierEvents[$key] = $Event }
    [void]$Events.Add($Event)
}

function Get-TokenRaderUsageEvents {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Int64]$StartOffset = 0,
        [Int64]$EndOffset = 0,
        [string]$InitialModel = '',
        [Int64]$MaximumLineBytes = 4MB,
        [string]$InitialServiceTier = '',
        $InitialTotal = $null
    )

    $events = New-Object System.Collections.ArrayList
    $state = [pscustomobject]@{
        Model = $InitialModel
        SourceFile = $FilePath
        ServiceTier = $InitialServiceTier
        PreviousTotalKnown = $false
        PreviousTotalUsage = $null
    }
    if ($null -ne $InitialTotal) {
        $state.PreviousTotalKnown = $true
        $state.PreviousTotalUsage = $InitialTotal
    }
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return [pscustomobject]@{ Events = @(); LastModel = $InitialModel; BytesRead = 0 }
    }

    $stream = $null
    $lineBuffer = New-Object System.IO.MemoryStream
    [Int64]$bytesReadTotal = 0
    try {
        $stream = New-Object System.IO.FileStream(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $effectiveStart = [Math]::Max([Int64]0, [Math]::Min([Int64]$stream.Length, $StartOffset))
        $effectiveEnd = if ($EndOffset -gt 0) { [Math]::Min([Int64]$stream.Length, $EndOffset) } else { [Int64]$stream.Length }
        if ($effectiveEnd -le $effectiveStart) {
            return [pscustomobject]@{ Events = @(); LastModel = [string]$state.Model; BytesRead = 0 }
        }

        $discardLine = $false
        if ($effectiveStart -gt 0) {
            [void]$stream.Seek($effectiveStart - 1, [System.IO.SeekOrigin]::Begin)
            $previousByte = $stream.ReadByte()
            $discardLine = ($previousByte -ne 10)
        }
        [void]$stream.Seek($effectiveStart, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] (1MB)
        [Int64]$remaining = $effectiveEnd - $effectiveStart
        while ($remaining -gt 0) {
            $requested = [int][Math]::Min([Int64]$buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $requested)
            if ($read -le 0) { break }
            $remaining -= $read
            $bytesReadTotal += $read
            $position = 0
            while ($position -lt $read) {
                $newLine = [Array]::IndexOf($buffer, [byte]10, $position, $read - $position)
                $segmentEnd = if ($newLine -ge 0) { $newLine } else { $read }
                $segmentLength = $segmentEnd - $position
                if (-not $discardLine -and $segmentLength -gt 0) {
                    if (($lineBuffer.Length + $segmentLength) -le $MaximumLineBytes) {
                        $lineBuffer.Write($buffer, $position, $segmentLength)
                    } else {
                        $discardLine = $true
                        $lineBuffer.SetLength(0)
                    }
                }
                if ($newLine -lt 0) { break }
                if (-not $discardLine -and $lineBuffer.Length -gt 0) {
                    $lineText = [Text.Encoding]::UTF8.GetString($lineBuffer.ToArray()).TrimEnd("`r")
                    Add-TokenRaderLineEvent -LineText $lineText -State $state -Events $events
                }
                $lineBuffer.SetLength(0)
                $discardLine = $false
                $position = $newLine + 1
            }
        }
        if (-not $discardLine -and $lineBuffer.Length -gt 0) {
            $lineText = [Text.Encoding]::UTF8.GetString($lineBuffer.ToArray()).TrimEnd("`r")
            Add-TokenRaderLineEvent -LineText $lineText -State $state -Events $events
        }
    } catch {
        return [pscustomobject]@{ Events = @($events); LastModel = [string]$state.Model; BytesRead = $bytesReadTotal }
    } finally {
        $lineBuffer.Dispose()
        if ($null -ne $stream) { $stream.Dispose() }
    }

    [pscustomobject]@{
        Events = @($events)
        LastModel = [string]$state.Model
        BytesRead = $bytesReadTotal
    }
}

function ConvertTo-TokenRaderRateWindow {
    param(
        [Parameter(Mandatory = $true)]$RawWindow,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
        [string]$SourceFile = '',
        [string]$PlanType = '',
        [string]$LimitId = ''
    )

    $usedPercent = [Math]::Max(0.0, [Math]::Min(100.0, [double]$RawWindow.used_percent))
    $windowMinutes = [int]$RawWindow.window_minutes
    $resetValue = $null
    foreach ($propertyName in @('resets_at', 'reset_at')) {
        if ($null -ne $RawWindow.PSObject.Properties[$propertyName] -and $null -ne $RawWindow.$propertyName) {
            $resetValue = $RawWindow.$propertyName
            break
        }
    }
    $resetsAt = $null
    if ($null -ne $resetValue) {
        $resetsAt = ConvertTo-TokenRaderResetTime -Value $resetValue -ObservedAt $ObservedAt
    } elseif ($null -ne $RawWindow.PSObject.Properties['resets_in_seconds'] -and $null -ne $RawWindow.resets_in_seconds) {
        $resetsAt = ConvertTo-TokenRaderResetTime -Value $RawWindow.resets_in_seconds -ObservedAt $ObservedAt -RelativeSeconds $true
    }

    [pscustomobject]@{
        UsedPercent = $usedPercent
        RemainingPercent = 100.0 - $usedPercent
        WindowMinutes = $windowMinutes
        ResetsAt = $resetsAt
        ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes $windowMinutes -ResetsAt $resetsAt
        ObservedAt = $ObservedAt
        SourceFile = $SourceFile
        PlanType = $PlanType
        LimitId = $LimitId
        ScopeConflict = $false
        ConflictDescription = ''
        ConflictPlans = @()
        UsedTokens = if ($null -ne $RawWindow.PSObject.Properties['used_tokens']) { [Int64]$RawWindow.used_tokens } else { $null }
        RemainingTokens = if ($null -ne $RawWindow.PSObject.Properties['remaining_tokens']) { [Int64]$RawWindow.remaining_tokens } else { $null }
        LimitTokens = if ($null -ne $RawWindow.PSObject.Properties['limit_tokens']) { [Int64]$RawWindow.limit_tokens } else { $null }
    }
}

function ConvertTo-TokenRaderRateLimits {
    param(
        $RawRateLimits,
        [Parameter(Mandatory = $true)][DateTimeOffset]$ObservedAt,
        [string]$SourceFile = ''
    )

    $fiveHour = $null
    $weekly = $null
    $planType = ''
    if ($null -ne $RawRateLimits) {
        if ($null -ne $RawRateLimits.PSObject.Properties['plan_type']) { $planType = [string]$RawRateLimits.plan_type }
        foreach ($propertyName in @('primary', 'secondary')) {
            if ($null -eq $RawRateLimits.PSObject.Properties[$propertyName]) { continue }
            $rawWindow = $RawRateLimits.$propertyName
            if ($null -eq $rawWindow -or $null -eq $rawWindow.PSObject.Properties['window_minutes'] -or $null -eq $rawWindow.PSObject.Properties['used_percent']) { continue }
            $limitId = if ($null -ne $RawRateLimits.PSObject.Properties['limit_id']) { [string]$RawRateLimits.limit_id } else { '' }
            $window = ConvertTo-TokenRaderRateWindow -RawWindow $rawWindow -ObservedAt $ObservedAt -SourceFile $SourceFile -PlanType $planType -LimitId $limitId
            $kind = Get-TokenRaderRateWindowKind -WindowMinutes $window.WindowMinutes
            if ($kind -eq 'FiveHour') { $fiveHour = $window }
            elseif ($kind -eq 'Weekly') { $weekly = $window }
        }
    }

    [pscustomobject]@{
        ObservedAt = $ObservedAt
        PlanType = $planType
        LimitId = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['limit_id']) { [string]$RawRateLimits.limit_id } else { '' }
        LimitName = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['limit_name']) { [string]$RawRateLimits.limit_name } else { '' }
        IndividualLimit = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['individual_limit']) { [bool]$RawRateLimits.individual_limit } else { $null }
        RateLimitReachedType = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['rate_limit_reached_type']) { [string]$RawRateLimits.rate_limit_reached_type } else { '' }
        SpendControlReached = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['spend_control_reached']) { [bool]$RawRateLimits.spend_control_reached } else { $null }
        CreditsBalance = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['credits'] -and $null -ne $RawRateLimits.credits -and $null -ne $RawRateLimits.credits.PSObject.Properties['balance']) { [double]$RawRateLimits.credits.balance } else { $null }
        CreditsHas = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['credits'] -and $null -ne $RawRateLimits.credits -and $null -ne $RawRateLimits.credits.PSObject.Properties['has_credits']) { [bool]$RawRateLimits.credits.has_credits } else { $null }
        CreditsUnlimited = if ($null -ne $RawRateLimits -and $null -ne $RawRateLimits.PSObject.Properties['credits'] -and $null -ne $RawRateLimits.credits -and $null -ne $RawRateLimits.credits.PSObject.Properties['unlimited']) { [bool]$RawRateLimits.credits.unlimited } else { $null }
        ScopeConflict = $false
        ConflictDescription = ''
        ConflictPlans = @()
        FiveHour = $fiveHour
        Weekly = $weekly
    }
}

function ConvertFrom-TokenRaderRateLimitCandidates {
    param(
        [AllowNull()][object[]]$Candidates
    )

    $allCandidates = @($Candidates | Where-Object {
        $null -ne $_ -and $null -ne $_.Window -and
        -not [string]::IsNullOrWhiteSpace([string]$_.WindowKind)
    })
    if ($allCandidates.Count -eq 0) { return $null }

    $selectedWindows = @{}
    $selectedScopes = @{}
    foreach ($windowKind in @('FiveHour', 'Weekly')) {
        $kindCandidates = @($allCandidates | Where-Object { [string]$_.WindowKind -eq $windowKind })
        if ($kindCandidates.Count -eq 0) { continue }

        # A scope is one normalized reset cycle and limit pool. Keep plans in
        # the same scope together so an alternate plan cannot be overwritten
        # by the latest timestamp. Different reset identities remain separate.
        $scopeGroups = @{}
        foreach ($candidate in $kindCandidates) {
            $window = $candidate.Window
            $windowMinutes = [int]$window.WindowMinutes
            $resetIdentity = if ($null -ne $window.PSObject.Properties['ResetIdentity']) {
                [string]$window.ResetIdentity
            } else {
                Get-TokenRaderResetIdentity -WindowMinutes $windowMinutes -ResetsAt $window.ResetsAt
            }
            $limitId = if ($null -ne $window.PSObject.Properties['LimitId']) {
                [string]$window.LimitId
            } elseif ($null -ne $candidate.Metadata -and $null -ne $candidate.Metadata.PSObject.Properties['LimitId']) {
                [string]$candidate.Metadata.LimitId
            } else { '' }
            $planType = if ($null -ne $window.PSObject.Properties['PlanType']) {
                [string]$window.PlanType
            } elseif ($null -ne $candidate.Metadata -and $null -ne $candidate.Metadata.PSObject.Properties['PlanType']) {
                [string]$candidate.Metadata.PlanType
            } else { '' }
            if ($null -eq $window.PSObject.Properties['LimitId']) {
                Add-Member -InputObject $window -NotePropertyName LimitId -NotePropertyValue $limitId -Force
            } else { $window.LimitId = $limitId }
            if ($null -eq $window.PSObject.Properties['PlanType']) {
                Add-Member -InputObject $window -NotePropertyName PlanType -NotePropertyValue $planType -Force
            } else { $window.PlanType = $planType }
            $scopeKey = @(
                $windowMinutes.ToString([Globalization.CultureInfo]::InvariantCulture),
                $resetIdentity,
                $limitId.Trim().ToLowerInvariant()
            ) -join ([char]0x1f)
            if (-not $scopeGroups.ContainsKey($scopeKey)) {
                $scopeGroups[$scopeKey] = New-Object System.Collections.ArrayList
            }
            [void]$scopeGroups[$scopeKey].Add($candidate)
        }

        # Select the most recently observed reset scope. The scope key still
        # includes reset identity, so older cycles do not create a conflict
        # with the current cycle even if their plan differs.
        $selectedGroup = $null
        $selectedLatest = $null
        [DateTimeOffset]$selectedAt = [DateTimeOffset]::MinValue
        [Int64]$selectedId = [Int64]::MinValue
        foreach ($group in @($scopeGroups.Values)) {
            foreach ($candidate in @($group)) {
                [DateTimeOffset]$candidateAt = [DateTimeOffset]::MinValue
                try { $candidateAt = [DateTimeOffset]$candidate.Window.ObservedAt } catch { }
                [Int64]$candidateId = 0L
                if ($null -ne $candidate.PSObject.Properties['RecordId']) {
                    try { $candidateId = [Int64]$candidate.RecordId } catch { }
                }
                if ($null -eq $selectedLatest -or $candidateAt -gt $selectedAt -or
                    ($candidateAt -eq $selectedAt -and $candidateId -gt $selectedId)) {
                    $selectedGroup = @($group)
                    $selectedLatest = $candidate
                    $selectedAt = $candidateAt
                    $selectedId = $candidateId
                }
            }
        }
        if ($null -eq $selectedLatest) { continue }

        $planMap = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        $planLatest = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($candidate in @($selectedGroup)) {
            $plan = ([string]$candidate.Window.PlanType).Trim()
            if (-not [string]::IsNullOrWhiteSpace($plan)) {
                $planMap[$plan] = $true
                if (-not $planLatest.ContainsKey($plan)) {
                    $planLatest[$plan] = $candidate
                } else {
                    [DateTimeOffset]$existingAt = [DateTimeOffset]::MinValue
                    [DateTimeOffset]$candidateAt = [DateTimeOffset]::MinValue
                    try { $existingAt = [DateTimeOffset]$planLatest[$plan].Window.ObservedAt } catch { }
                    try { $candidateAt = [DateTimeOffset]$candidate.Window.ObservedAt } catch { }
                    if ($candidateAt -gt $existingAt) { $planLatest[$plan] = $candidate }
                }
            }
        }
        $plans = @($planMap.Keys | Sort-Object)
        $scopeConflict = $plans.Count -gt 1
        $planDetails = @($plans | ForEach-Object {
            $planCandidate = $planLatest[$_]
            '{0}={1:0.####}%' -f $_, [double]$planCandidate.Window.UsedPercent
        })
        $conflictDescription = if ($scopeConflict) {
            '额度周期存在冲突计划：' + ($planDetails -join '; ')
        } else { '' }
        $selectedWindow = $selectedLatest.Window
        if ($null -eq $selectedWindow.PSObject.Properties['ScopeConflict']) {
            Add-Member -InputObject $selectedWindow -NotePropertyName ScopeConflict -NotePropertyValue ([bool]$scopeConflict) -Force
        } else { $selectedWindow.ScopeConflict = [bool]$scopeConflict }
        if ($null -eq $selectedWindow.PSObject.Properties['ConflictDescription']) {
            Add-Member -InputObject $selectedWindow -NotePropertyName ConflictDescription -NotePropertyValue $conflictDescription -Force
        } else { $selectedWindow.ConflictDescription = $conflictDescription }
        if ($null -eq $selectedWindow.PSObject.Properties['ConflictPlans']) {
            Add-Member -InputObject $selectedWindow -NotePropertyName ConflictPlans -NotePropertyValue @($plans) -Force
        } else { $selectedWindow.ConflictPlans = @($plans) }

        $scopeSummary = foreach ($candidate in @($selectedGroup)) {
            $candidateResetIdentity = if ($null -ne $candidate.Window.PSObject.Properties['ResetIdentity']) {
                [string]$candidate.Window.ResetIdentity
            } else {
                Get-TokenRaderResetIdentity -WindowMinutes ([int]$candidate.Window.WindowMinutes) -ResetsAt $candidate.Window.ResetsAt
            }
            [pscustomobject]@{
                WindowKind = $windowKind
                WindowMinutes = [int]$candidate.Window.WindowMinutes
                ResetIdentity = $candidateResetIdentity
                PlanType = [string]$candidate.Window.PlanType
                LimitId = [string]$candidate.Window.LimitId
                UsedPercent = [double]$candidate.Window.UsedPercent
                ObservedAt = $candidate.Window.ObservedAt
                RecordId = if ($null -ne $candidate.PSObject.Properties['RecordId']) { [Int64]$candidate.RecordId } else { 0L }
            }
        }
        if ($null -eq $selectedWindow.PSObject.Properties['ScopeCandidates']) {
            Add-Member -InputObject $selectedWindow -NotePropertyName ScopeCandidates -NotePropertyValue @($scopeSummary) -Force
        } else { $selectedWindow.ScopeCandidates = @($scopeSummary) }
        $selectedWindows[$windowKind] = $selectedWindow
        $selectedScopes[$windowKind] = [pscustomobject]@{
            ScopeConflict = [bool]$scopeConflict
            ConflictDescription = $conflictDescription
            ConflictPlans = @($plans)
            Candidates = @($scopeSummary)
        }
    }

    $fiveHour = if ($selectedWindows.ContainsKey('FiveHour')) { $selectedWindows['FiveHour'] } else { $null }
    $weekly = if ($selectedWindows.ContainsKey('Weekly')) { $selectedWindows['Weekly'] } else { $null }
    if ($null -eq $fiveHour -and $null -eq $weekly) { return $null }

    # Preserve the existing top-level metadata contract by using the newest
    # source metadata row, while each selected window carries its own scope.
    $latestMetadata = $null
    [DateTimeOffset]$latestMetadataAt = [DateTimeOffset]::MinValue
    [Int64]$latestMetadataId = [Int64]::MinValue
    foreach ($candidate in $allCandidates) {
        $metadata = $candidate.Metadata
        if ($null -eq $metadata) { continue }
        [DateTimeOffset]$candidateAt = [DateTimeOffset]::MinValue
        try { $candidateAt = [DateTimeOffset]$candidate.Window.ObservedAt } catch { }
        [Int64]$candidateId = 0L
        if ($null -ne $candidate.PSObject.Properties['RecordId']) {
            try { $candidateId = [Int64]$candidate.RecordId } catch { }
        }
        if ($null -eq $latestMetadata -or $candidateAt -gt $latestMetadataAt -or
            ($candidateAt -eq $latestMetadataAt -and $candidateId -gt $latestMetadataId)) {
            $latestMetadata = $metadata
            $latestMetadataAt = $candidateAt
            $latestMetadataId = $candidateId
        }
    }
    $planType = if ($null -ne $fiveHour -and $null -ne $weekly -and
        [DateTimeOffset]$fiveHour.ObservedAt -ge [DateTimeOffset]$weekly.ObservedAt) { [string]$fiveHour.PlanType }
        elseif ($null -ne $weekly) { [string]$weekly.PlanType }
        elseif ($null -ne $fiveHour) { [string]$fiveHour.PlanType } else { '' }
    $scopeConflict = ($null -ne $fiveHour -and [bool]$fiveHour.ScopeConflict) -or
        ($null -ne $weekly -and [bool]$weekly.ScopeConflict)
    $conflictPlans = @(
        if ($null -ne $fiveHour -and [bool]$fiveHour.ScopeConflict) { @($fiveHour.ConflictPlans) }
        if ($null -ne $weekly -and [bool]$weekly.ScopeConflict) { @($weekly.ConflictPlans) }
    ) | Sort-Object -Unique
    [pscustomobject]@{
        ObservedAt = if ($null -ne $fiveHour -and $null -ne $weekly -and [DateTimeOffset]$fiveHour.ObservedAt -gt [DateTimeOffset]$weekly.ObservedAt) { $fiveHour.ObservedAt } elseif ($null -ne $weekly) { $weekly.ObservedAt } else { $fiveHour.ObservedAt }
        PlanType = $planType
        LimitId = if ($null -ne $latestMetadata) { [string]$latestMetadata.LimitId } else { '' }
        LimitName = if ($null -ne $latestMetadata) { [string]$latestMetadata.LimitName } else { '' }
        IndividualLimit = if ($null -ne $latestMetadata) { $latestMetadata.IndividualLimit } else { $null }
        RateLimitReachedType = if ($null -ne $latestMetadata) { [string]$latestMetadata.RateLimitReachedType } else { '' }
        SpendControlReached = if ($null -ne $latestMetadata) { $latestMetadata.SpendControlReached } else { $null }
        CreditsBalance = if ($null -ne $latestMetadata) { $latestMetadata.CreditsBalance } else { $null }
        CreditsHas = if ($null -ne $latestMetadata) { $latestMetadata.CreditsHas } else { $null }
        CreditsUnlimited = if ($null -ne $latestMetadata) { $latestMetadata.CreditsUnlimited } else { $null }
        ScopeConflict = [bool]$scopeConflict
        ConflictDescription = if ($scopeConflict) {
            $details = @()
            foreach ($plan in @($conflictPlans)) {
                $window = if ($null -ne $fiveHour -and @($fiveHour.ConflictPlans) -contains $plan) { $fiveHour } else { $weekly }
                if ($null -ne $window) { $details += ('{0}={1:0.####}%' -f $plan, [double]$window.UsedPercent) }
            }
            '额度周期存在冲突计划：' + ($details -join '; ')
        } else { '' }
        ConflictPlans = @($conflictPlans)
        ScopeCandidates = @(
            if ($null -ne $fiveHour -and $null -ne $fiveHour.PSObject.Properties['ScopeCandidates']) { @($fiveHour.ScopeCandidates) }
            if ($null -ne $weekly -and $null -ne $weekly.PSObject.Properties['ScopeCandidates']) { @($weekly.ScopeCandidates) }
        )
        FiveHour = $fiveHour
        Weekly = $weekly
    }
}

function Get-TokenRaderUsageSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [int]$Tail = 5000,
        [Int64]$MaximumTailBytes = 16MB,
        [Int64]$EndOffset = 0
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
    $stream = $null
    try {
        # Get-Content -Tail can become very slow when a JSONL log contains multi-megabyte
        # tool-output lines. Reading a bounded byte window keeps the HUD responsive while
        # still covering far more records than are normally needed for the latest count.
        $stream = New-Object System.IO.FileStream(
            $FilePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        $effectiveEnd = if ($EndOffset -gt 0) { [Math]::Min([Int64]$stream.Length, $EndOffset) } else { [Int64]$stream.Length }
        if ($effectiveEnd -le 0) { return $null }
        $bytesToRead = [Math]::Min($effectiveEnd, [Math]::Max([Int64]65536, $MaximumTailBytes))
        [void]$stream.Seek($effectiveEnd - $bytesToRead, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] ([int]$bytesToRead)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $offset)
        if ($bytesToRead -lt $effectiveEnd) {
            $firstNewLine = $text.IndexOf("`n", [System.StringComparison]::Ordinal)
            if ($firstNewLine -ge 0) { $text = $text.Substring($firstNewLine + 1) }
        }
        $allLines = @($text -split "`r?`n")
        if ($allLines.Count -gt $Tail) {
            $lines = @($allLines | Select-Object -Last $Tail)
        } else {
            $lines = $allLines
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $tokenRecord = $null
    $tokenIndex = -1
    $model = ''
    $fallbackModel = ''
    $serviceTier = ''
    $tierContextFound = $false
    $activeServiceTier = ''
    $activeTierFound = $false
    $latestRateLimits = $null
    $latestRateLimitsFallback = $null
    $selectedHasTotal = $false
    $selectedHasCall = $false
    $needPreviousTotal = $false
    $previousTotalKnown = $false
    $previousTotalUsage = $null

    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $line = ([string]$lines[$i]).TrimStart([char]0xFEFF)
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.IndexOf('token_count', [System.StringComparison]::Ordinal) -lt 0 -and
            $line.IndexOf('turn_context', [System.StringComparison]::Ordinal) -lt 0) { continue }

        try { $record = $line | ConvertFrom-Json } catch { continue }

        if ($record.type -eq 'turn_context') {
            if (-not $activeTierFound) {
                $activeServiceTier = Get-TokenRaderMetadataServiceTier -Containers @($record.payload)
                $activeTierFound = $true
            }
            if ($null -ne $tokenRecord -and -not $tierContextFound) {
                $serviceTier = Get-TokenRaderMetadataServiceTier -Containers @($record.payload)
                $tierContextFound = $true
            }
            $candidate = [string]$record.payload.model
            if ([string]::IsNullOrWhiteSpace($fallbackModel) -and -not [string]::IsNullOrWhiteSpace($candidate)) {
                $fallbackModel = $candidate
            }
            if ($null -ne $tokenRecord -and [string]::IsNullOrWhiteSpace($model) -and -not [string]::IsNullOrWhiteSpace($candidate)) {
                $model = $candidate
                if ($null -ne $latestRateLimits -and -not $needPreviousTotal) { break }
            }
            continue
        }

        $payload = Get-TokenRaderPropertyValue -Object $record -Name 'payload'
        $payloadType = Get-TokenRaderPropertyValue -Object $payload -Name 'type'
        $recordType = [string](Get-TokenRaderPropertyValue -Object $record -Name 'type')
        $isTokenRecord = ($recordType -eq 'event_msg' -and $payloadType -eq 'token_count') -or
                         ($recordType -eq 'token_count')
        if (-not $isTokenRecord -or $null -eq $payload) { continue }

        $recordTimestamp = [DateTimeOffset]::Now
        try { $recordTimestamp = [DateTimeOffset]::Parse([string](Get-TokenRaderPropertyValue -Object $record -Name 'timestamp')).ToLocalTime() } catch { }
        $rawRateLimits = Get-TokenRaderPropertyValue -Object $payload -Name 'rate_limits'
        if ($null -eq $latestRateLimits -and $null -ne $rawRateLimits) {
            $candidateLimits = ConvertTo-TokenRaderRateLimits -RawRateLimits $rawRateLimits -ObservedAt $recordTimestamp -SourceFile $FilePath
            if ($null -eq $latestRateLimitsFallback) { $latestRateLimitsFallback = $candidateLimits }
            if ($null -ne $candidateLimits.FiveHour -or $null -ne $candidateLimits.Weekly) {
                $latestRateLimits = $candidateLimits
            }
        }
        $candidateInfo = Get-TokenRaderPropertyValue -Object $payload -Name 'info'
        $candidateTotal = Get-TokenRaderPropertyValue -Object $candidateInfo -Name 'total_token_usage'
        $candidateCall = Get-TokenRaderPropertyValue -Object $candidateInfo -Name 'last_token_usage'
        if ($null -eq $tokenRecord -and $null -ne $candidateInfo -and
            ($null -ne $candidateTotal -or $null -ne $candidateCall)) {
            $tokenRecord = $record
            $tokenIndex = $i
            $selectedHasTotal = $null -ne $candidateTotal
            $selectedHasCall = $null -ne $candidateCall
            $needPreviousTotal = $selectedHasTotal -and -not $selectedHasCall
        } elseif ($null -ne $tokenRecord -and $needPreviousTotal -and -not $previousTotalKnown) {
            # The reverse scan reaches the immediately preceding record after
            # selecting the latest total-only record. A last-only record breaks
            # the cumulative anchor because its call may already be included
            # in the next total.
            if ($null -ne $candidateCall -and $null -eq $candidateTotal) {
                $needPreviousTotal = $false
            } elseif ($null -ne $candidateTotal) {
                $previousTotalUsage = ConvertTo-TokenRaderUsage $candidateTotal
                $previousTotalKnown = $true
            }
        }
        if ($null -ne $tokenRecord -and -not $needPreviousTotal -and
            -not [string]::IsNullOrWhiteSpace($model) -and $null -ne $latestRateLimits) {
            break
        }
        if ($null -ne $tokenRecord -and $needPreviousTotal -and $previousTotalKnown -and
            -not [string]::IsNullOrWhiteSpace($model) -and $null -ne $latestRateLimits) { break }
    }

    if ($null -eq $tokenRecord) { return $null }
    if ([string]::IsNullOrWhiteSpace($model)) { $model = $fallbackModel }

    $payload = $tokenRecord.payload
    $info = $payload.info
    if ($null -eq $info) { return $null }
    $rawTotal = Get-TokenRaderPropertyValue -Object $info -Name 'total_token_usage'
    $rawCall = Get-TokenRaderPropertyValue -Object $info -Name 'last_token_usage'
    $hasTotal = $null -ne $rawTotal
    $hasCall = $null -ne $rawCall
    if (-not $hasTotal -and -not $hasCall) { return $null }
    $contextServiceTier = $activeServiceTier
    $serviceTier = Get-TokenRaderMetadataServiceTier -Containers @($info, $payload, $tokenRecord) -Fallback $serviceTier

    $timestamp = $null
    try { $timestamp = [DateTimeOffset]::Parse([string]$tokenRecord.timestamp).ToLocalTime() } catch { $timestamp = [DateTimeOffset]::Now }
    $snapshotRateLimits = if ($null -ne $latestRateLimits) { $latestRateLimits } else { $latestRateLimitsFallback }
    $planType = if ($null -ne $snapshotRateLimits) { [string]$snapshotRateLimits.PlanType } else { '' }
    # Older or synthetic token_count records may omit the model context
    # window. Keep that metadata explicitly unknown instead of dereferencing
    # an uninitialised variable under StrictMode.
    [Int64]$contextWindow = 0L
    $contextRaw = Get-TokenRaderPropertyValue -Object $info -Name 'model_context_window'
    if ($null -ne $contextRaw) {
        $contextWindow = ConvertTo-TokenRaderSafeInt64 $contextRaw
    }
    $cacheWrite = if ($hasCall) {
        Get-TokenRaderFirstPresentInt64 -Object $rawCall `
            -Names @('cache_creation_tokens', 'cache_write_tokens', 'cache_creation_input_tokens', 'cache_write_input_tokens')
    } else {
        [pscustomobject]@{ Found = $false; Value = 0L }
    }

    $task = if ($hasTotal) { ConvertTo-TokenRaderUsage $rawTotal } else { $null }
    $call = if ($hasCall) { ConvertTo-TokenRaderUsage $rawCall } else { $null }
    $callAvailable = $hasCall
    $callDerived = $false
    if ($hasTotal -and -not $hasCall) {
        if ($previousTotalKnown) {
            $delta = ConvertTo-TokenRaderUsageDelta -Previous $previousTotalUsage -Current $task
            if ($null -ne $delta) {
                $call = $delta
                $callAvailable = $true
                $callDerived = $true
            } else {
                $call = New-TokenRaderUsage -InputTokens 0 -CachedTokens 0 -OutputTokens 0 -ReasoningOutputTokens 0
                $callAvailable = $false
            }
        } else {
            $call = New-TokenRaderUsage -InputTokens 0 -CachedTokens 0 -OutputTokens 0 -ReasoningOutputTokens 0
            $callAvailable = $false
        }
    }

    [pscustomobject]@{
        FilePath = $FilePath
        Timestamp = $timestamp
        Model = $model
        ServiceTier = $serviceTier
        ContextServiceTier = $contextServiceTier
        ServiceTierKnown = $serviceTier -ne ''
        PlanType = $planType
        RateLimits = $snapshotRateLimits
        Task = $task
        Call = $call
        HasTotal = [bool]$hasTotal
        HasCall = [bool]$hasCall
        CallAvailable = [bool]$callAvailable
        CallDerived = [bool]$callDerived
        RequestInputObservable = -not [bool]$callDerived
        LongContextPricingUncertain = $false
        ContextWindow = $contextWindow
        ModelContextWindow = $contextWindow
        CacheCreationTokens = [Math]::Max(0L, [Int64]$cacheWrite.Value)
        CacheWriteObservable = [bool]$cacheWrite.Found
        TailLinesRead = $lines.Count
        TokenRecordIndex = $tokenIndex
    }
}

function Get-TokenRaderLatestRateLimits {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [int]$MaximumFiles = 0,
        [hashtable]$EndOffsets = $null,
        [hashtable]$SnapshotCache = $null
    )

    if (-not (Test-Path -LiteralPath $SessionsRoot)) { return $null }
    $endOffsetMap = $null
    if ($null -ne $EndOffsets) {
        $endOffsetMap = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($EndOffsets.Keys)) {
            $endOffsetMap[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$key))] = [Int64]$EndOffsets[$key]
        }
    }
    $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($MaximumFiles -gt 0 -and $files.Count -gt $MaximumFiles) {
        $files = @($files | Select-Object -First $MaximumFiles)
    }
    $candidates = New-Object System.Collections.ArrayList

    foreach ($file in $files) {
        $canonicalPath = ConvertTo-TokenRaderCanonicalPath -Path ([string]$file.FullName)
        if ($null -ne $endOffsetMap -and -not $endOffsetMap.ContainsKey($canonicalPath)) { continue }
        $effectiveEnd = [Int64]$file.Length
        if ($null -ne $endOffsetMap) { $effectiveEnd = [Math]::Min($effectiveEnd, [Int64]$endOffsetMap[$canonicalPath]) }
        if ($effectiveEnd -le 0) { continue }

        $snapshot = $null
        if ($null -ne $SnapshotCache -and $SnapshotCache.ContainsKey($canonicalPath)) {
            $cachedEntry = $SnapshotCache[$canonicalPath]
            if ([Int64]$cachedEntry.EndOffset -eq $effectiveEnd -and
                [Int64]$cachedEntry.LastWriteTimeUtcTicks -eq [Int64]$file.LastWriteTimeUtc.Ticks) {
                $snapshot = $cachedEntry.Snapshot
            }
        }
        if ($null -eq $snapshot) {
            $snapshot = Get-TokenRaderUsageSnapshot -FilePath $canonicalPath -EndOffset $effectiveEnd
            if ($null -ne $SnapshotCache) {
                $SnapshotCache[$canonicalPath] = [pscustomobject]@{
                    EndOffset = $effectiveEnd
                    LastWriteTimeUtcTicks = [Int64]$file.LastWriteTimeUtc.Ticks
                    Snapshot = $snapshot
                }
            }
        }
        if ($null -eq $snapshot -or $null -eq $snapshot.RateLimits) { continue }
        $rateLimits = $snapshot.RateLimits
        if ($null -ne $rateLimits.FiveHour) {
            [void]$candidates.Add([pscustomobject]@{
                WindowKind = 'FiveHour'; Window = $rateLimits.FiveHour; Metadata = $rateLimits
                RecordId = 0L; SourceFile = $canonicalPath
            })
        }
        if ($null -ne $rateLimits.Weekly) {
            [void]$candidates.Add([pscustomobject]@{
                WindowKind = 'Weekly'; Window = $rateLimits.Weekly; Metadata = $rateLimits
                RecordId = 0L; SourceFile = $canonicalPath
            })
        }
    }
    return ConvertFrom-TokenRaderRateLimitCandidates -Candidates @($candidates)
}

function Get-TokenRaderPrices {
    param([Parameter(Mandatory = $true)][string]$PricingPath)

    if (-not (Test-Path -LiteralPath $PricingPath)) { throw "Pricing file not found: $PricingPath" }
    $document = Get-Content -Raw -Encoding UTF8 -LiteralPath $PricingPath | ConvertFrom-Json
    return $document
}

function Resolve-TokenRaderPrice {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory = $true)]$PricingDocument
    )

    if ([string]::IsNullOrWhiteSpace($Model)) { return $null }
    $normalized = $Model.Trim().ToLowerInvariant()
    $entries = @($PricingDocument.models | Sort-Object @{ Expression = { ([string]$_.id).Length }; Descending = $true })

    foreach ($entry in $entries) {
        $id = ([string]$entry.id).ToLowerInvariant()
        $aliases = @($entry.aliases | ForEach-Object { ([string]$_).ToLowerInvariant() })
        if ($normalized -eq $id -or $aliases -contains $normalized) { return $entry }
        if ($normalized.StartsWith($id + '-20', [System.StringComparison]::OrdinalIgnoreCase)) { return $entry }
    }
    return $null
}

function Resolve-TokenRaderLongContextPricing {
    param(
        [Parameter(Mandatory = $true)]$Price,
        [Parameter(Mandatory = $true)]$Usage,
        [ValidateSet('task', 'call')][string]$Scope = 'task',
        [Int64]$ModelContextWindow = 0,
        [Int64]$LongContextThreshold = 0,
        [Nullable[bool]]$LongContextApplied = $null
    )
    $threshold = if ($LongContextThreshold -gt 0) { $LongContextThreshold } elseif ($null -ne $Price.PSObject.Properties['longContextThreshold']) { [Int64]$Price.longContextThreshold } else { 0L }
    $applied = if ($null -ne $LongContextApplied) { [bool]$LongContextApplied } else {
        $Scope -eq 'call' -and $threshold -gt 0L -and [Int64]$Usage.Input -gt $threshold
    }
    [pscustomobject]@{
        Applied = $applied
        Threshold = if ($threshold -gt 0L) { $threshold } else { $null }
        ContextWindow = if ($ModelContextWindow -gt 0L) { $ModelContextWindow } else { $null }
        Source = if ($threshold -gt 0L) { 'pricing_threshold' } else { 'no_threshold' }
        InputMultiplier = if ($applied) { if ($null -ne $Price.PSObject.Properties['longContextInputMultiplier']) { [double]$Price.longContextInputMultiplier } else { 2.0 } } else { 1.0 }
        OutputMultiplier = if ($applied) { if ($null -ne $Price.PSObject.Properties['longContextOutputMultiplier']) { [double]$Price.longContextOutputMultiplier } else { 1.5 } } else { 1.0 }
    }
}

function ConvertTo-TokenRaderServiceTier {
    param([AllowNull()][AllowEmptyString()][string]$ServiceTier = '')
    switch (([string]$ServiceTier).Trim().ToLowerInvariant()) {
        'fast' { return 'priority' }
        'standard' { return 'default' }
        'normal' { return 'default' }
        'auto' { return '' }
        'unknown' { return '' }
        default { return ([string]$ServiceTier).Trim().ToLowerInvariant() }
    }
}

function Get-TokenRaderMetadataServiceTier {
    param([object[]]$Containers, [string]$Fallback = '', [switch]$IncludeSource)
    # An actual response tier takes precedence over a requested turn tier.
    foreach ($container in $Containers) {
        if ($null -ne $container -and $null -ne $container.PSObject.Properties['response'] -and
            $null -ne $container.response -and $null -ne $container.response.PSObject.Properties['service_tier']) {
            $tier = ConvertTo-TokenRaderServiceTier ([string]$container.response.service_tier)
            if ($IncludeSource) { return [pscustomobject]@{Tier=$tier;Source='response'} }
            return $tier
        }
    }
    foreach ($container in $Containers) {
        if ($null -ne $container -and $null -ne $container.PSObject.Properties['service_tier']) {
            $tier = ConvertTo-TokenRaderServiceTier ([string]$container.service_tier)
            if ($IncludeSource) { return [pscustomobject]@{Tier=$tier;Source='service_tier'} }
            return $tier
        }
    }
    $tier = ConvertTo-TokenRaderServiceTier $Fallback
    if ($IncludeSource) { return [pscustomobject]@{Tier=$tier;Source='turn_context'} }
    return $tier
}

function Resolve-TokenRaderServiceTierPrice {
    param($Price, [AllowEmptyString()][string]$ServiceTier = '')
    if ($null -eq $Price) { return $null }
    $tier = ConvertTo-TokenRaderServiceTier $ServiceTier
    if ($tier -eq '' -or $tier -eq 'default') { return $Price }
    if ($null -eq $Price.PSObject.Properties['serviceTiers'] -or $null -eq $Price.serviceTiers -or
        $null -eq $Price.serviceTiers.PSObject.Properties[$tier]) { return $null }
    $tierPrice = $Price.serviceTiers.PSObject.Properties[$tier].Value
    if ($null -eq $tierPrice) { return $null }
    foreach ($name in @('input', 'cachedInput', 'output')) {
        if ($null -eq $tierPrice.PSObject.Properties[$name] -or $null -eq $tierPrice.PSObject.Properties[$name].Value) { return $null }
        [double]$rate = 0
        if (-not [double]::TryParse([string]$tierPrice.PSObject.Properties[$name].Value, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$rate) -or [double]::IsNaN($rate) -or [double]::IsInfinity($rate) -or $rate -lt 0) { return $null }
    }
    $resolved = [ordered]@{}
    foreach ($property in $Price.PSObject.Properties) { $resolved[$property.Name] = $property.Value }
    foreach ($property in $tierPrice.PSObject.Properties) { $resolved[$property.Name] = $property.Value }
    $resolved['ServiceTier'] = $tier
    return [pscustomobject]$resolved
}

function Get-TokenRaderManualServiceTier {
    <#
    ManualServiceTiers is deliberately a transient measurement-only overlay.
    It is not part of the official pricing document and is never written to
    the index/history cache.  A caller may pass either a hashtable or a JSON
    object whose keys are model ids, aliases, or the model name seen in a log.
    Only the two priced processing modes are accepted; an invalid/unknown
    choice is treated as no confirmation.
    #>
    param(
        [Parameter(Mandatory = $true)]$PricingDocument,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model
    )

    if ([string]::IsNullOrWhiteSpace($Model) -or $null -eq $PricingDocument -or
        $null -eq $PricingDocument.PSObject.Properties['ManualServiceTiers'] -or
        $null -eq $PricingDocument.ManualServiceTiers) { return '' }

    $manual = $PricingDocument.ManualServiceTiers
    $requested = $Model.Trim()
    $value = $null

    # Do an explicit case-insensitive key walk.  PowerShell hashtables may be
    # case-sensitive when supplied by a caller, while JSON objects expose
    # PSObject properties with their original casing.
    if ($manual -is [Collections.IDictionary]) {
        foreach ($key in @($manual.Keys)) {
            if ([string]::Equals(([string]$key).Trim(), $requested, [StringComparison]::OrdinalIgnoreCase)) {
                $value = $manual[$key]
                break
            }
        }
    } else {
        foreach ($property in @($manual.PSObject.Properties)) {
            if ([string]::Equals(([string]$property.Name).Trim(), $requested, [StringComparison]::OrdinalIgnoreCase)) {
                $value = $property.Value
                break
            }
        }
    }

    # If the model was recorded under an alias (or the canonical id), allow
    # the confirmation to be keyed by the other spelling as well.
    if ($null -eq $value) {
        $price = Resolve-TokenRaderPrice -Model $requested -PricingDocument $PricingDocument
        if ($null -ne $price) {
            $candidateKeys = @([string]$price.id) + @($price.aliases | ForEach-Object { [string]$_ })
            foreach ($candidateKey in $candidateKeys) {
                if ([string]::IsNullOrWhiteSpace($candidateKey)) { continue }
                if ($manual -is [Collections.IDictionary]) {
                    foreach ($key in @($manual.Keys)) {
                        if ([string]::Equals(([string]$key).Trim(), $candidateKey.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                            $value = $manual[$key]
                            break
                        }
                    }
                } else {
                    foreach ($property in @($manual.PSObject.Properties)) {
                        if ([string]::Equals(([string]$property.Name).Trim(), $candidateKey.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                            $value = $property.Value
                            break
                        }
                    }
                }
                if ($null -ne $value) { break }
            }
        }
    }
    if ($null -eq $value) { return '' }

    # Keep the public shape intentionally simple (model -> "default"|
    # "priority"), but tolerate an object wrapper so a UI can carry a label
    # without changing the core contract.
    if ($value -isnot [string] -and $null -ne $value.PSObject) {
        foreach ($propertyName in @('ServiceTier', 'Tier', 'Mode', 'Value')) {
            if ($null -ne $value.PSObject.Properties[$propertyName]) {
                $value = $value.PSObject.Properties[$propertyName].Value
                break
            }
        }
    }
    $tier = ConvertTo-TokenRaderServiceTier ([string]$value)
    if ($tier -eq 'default' -or $tier -eq 'priority') { return $tier }
    return ''
}

function Get-TokenRaderCost {
    param(
        [Parameter(Mandatory = $true)]$Usage,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Model,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [ValidateSet('task', 'call')][string]$Scope = 'task',
        [Int64]$ModelContextWindow = 0,
        [Int64]$LongContextThreshold = 0,
        [Nullable[bool]]$LongContextApplied = $null,
        [Int64]$CacheCreationTokens = 0,
        [Nullable[bool]]$CacheWriteObservable = $null,
        [bool]$RequestInputObservable = $true,
        [Nullable[bool]]$LongContextPricingUncertain = $null,
        [AllowEmptyString()][string]$ServiceTier = '',
        [AllowNull()][AllowEmptyString()][string]$ServiceTierSource = $null,
        [Nullable[bool]]$ServiceTierEvidenceComplete = $null,
        $ResolvedPrice = $null
    )

    $observedTier = ConvertTo-TokenRaderServiceTier $ServiceTier
    # A missing/auto/unknown log tier may be completed by the caller's
    # transient measurement confirmation.  A non-empty tier is always kept as
    # observed evidence, even when its price is unsupported: manual input must
    # never rewrite an explicit log tier.
    $tierSourceProvided = $PSBoundParameters.ContainsKey('ServiceTierSource')
    $normalizedTierSource = if ($tierSourceProvided) { ([string]$ServiceTierSource).Trim().ToLowerInvariant() } else { '' }
    $untrustedTierSource = $tierSourceProvided -and @('', 'indexed', 'mixed', 'missing', 'response_null', 'service_tier_null', 'turn_context_missing') -contains $normalizedTierSource -and
        ($null -eq $ServiceTierEvidenceComplete -or -not [bool]$ServiceTierEvidenceComplete)
    $manualTier = if ($observedTier -eq '' -or $untrustedTierSource) { Get-TokenRaderManualServiceTier -PricingDocument $PricingDocument -Model $Model } else { '' }
    $manualModeAssumption = ($observedTier -eq '' -or $untrustedTierSource) -and $manualTier -ne ''
    $tier = if ($manualModeAssumption) { $manualTier } else { $observedTier }
    $modeEvidenceComplete = $observedTier -ne '' -and -not $untrustedTierSource
    $serviceTierComplete = $tier -ne ''
    $effectiveServiceTierSource = if ($manualModeAssumption) { 'manual_confirmation' }
        elseif ($tier -eq '') { 'standard_fallback' }
        elseif ($untrustedTierSource) { if ($normalizedTierSource -ne '') { $normalizedTierSource } else { 'untrusted' } }
        else { 'log' }
    $basePrice = if ($null -ne $ResolvedPrice) { $ResolvedPrice } else { Resolve-TokenRaderPrice -Model $Model -PricingDocument $PricingDocument }
    $missingRequestInput = $false
    $requestBoundaryUncertain = if ($null -ne $LongContextPricingUncertain) {
        [bool]$LongContextPricingUncertain
    } else {
        $null -ne $basePrice -and $null -ne $basePrice.PSObject.Properties['longContextThreshold'] -and
            [Int64]$basePrice.longContextThreshold -gt 0L -and
            [Int64]$Usage.Input -gt [Int64]$basePrice.longContextThreshold
    }
    if (-not $RequestInputObservable -and $requestBoundaryUncertain -and $null -ne $basePrice -and
        $null -ne $basePrice.PSObject.Properties['longContextThreshold'] -and
        [Int64]$basePrice.longContextThreshold -gt 0L) {
        # A total-only delta can combine several calls.  Preserve its token
        # evidence, but do not guess a long-context premium from an unknown
        # per-request boundary.
        $missingRequestInput = $true
    }
    $price = if ($missingRequestInput) { $null } else {
        Resolve-TokenRaderServiceTierPrice -Price $basePrice -ServiceTier $tier
    }
    $unsupportedContext = $false
    if ($null -ne $price -and $null -ne $price.PSObject.Properties['maximumInputTokens']) {
        # Compact buckets carry the original per-call context classification;
        # their summed input must not be tested as if it were one request.
        $unsupportedContext = if ($null -ne $LongContextApplied) { [bool]$LongContextApplied } else {
            $Scope -eq 'call' -and [Int64]$Usage.Input -gt [Int64]$price.maximumInputTokens
        }
        if ($unsupportedContext) { $price = $null }
    }
    $unsupportedCacheWrite = $null -ne $price -and $tier -ne '' -and $tier -ne 'default' -and $CacheCreationTokens -gt 0 -and
        $null -eq $price.PSObject.Properties['cacheWrite'] -and $null -eq $price.PSObject.Properties['cacheWriteMultiplier']
    if ($unsupportedCacheWrite) { $price = $null }
    if ($null -eq $price) {
        return [pscustomobject]@{
            Known = $false
            Model = $Model
            Price = $null
            ServiceTier = $tier
            ServiceTierKnown = $serviceTierComplete
            ServiceTierComplete = $serviceTierComplete
            ServiceTierEvidenceComplete = $modeEvidenceComplete
            ModeEvidenceComplete = $modeEvidenceComplete
            ModeAssumptionApplied = $manualModeAssumption
            ManualServiceTierApplied = $manualModeAssumption
            ServiceTierSource = $effectiveServiceTierSource
            PricingReason = if ($missingRequestInput) { 'missing_request_input' } elseif ($unsupportedCacheWrite) { 'unsupported_service_tier_cache_write' } elseif ($unsupportedContext) { 'unsupported_service_tier_context' } elseif ($null -eq $basePrice) { 'unknown_model' } else { 'unknown_service_tier_price' }
            InputCost = $null
            CachedCost = $null
            OutputCost = $null
            TotalCost = $null
            CacheCreationCost = [double]0
            CacheWriteObservable = $false
            CostCoverage = 'observable_tokens_only'
            LongContextApplied = $false
            InputMultiplier = 1.0
            OutputMultiplier = 1.0
            ModelContextWindow = if ($ModelContextWindow -gt 0) { $ModelContextWindow } else { $null }
            LongContextThreshold = if ($LongContextThreshold -gt 0) { $LongContextThreshold } elseif ($missingRequestInput) { [Int64]$basePrice.longContextThreshold } else { $null }
            LongContextSource = if ($missingRequestInput) { 'missing_input' } elseif ($null -eq $basePrice) { 'unknown_model' } else { 'no_threshold' }
        }
    }

    $longContext = Resolve-TokenRaderLongContextPricing -Price $price -Usage $Usage -Scope $Scope -ModelContextWindow $ModelContextWindow -LongContextThreshold $LongContextThreshold -LongContextApplied $LongContextApplied
    $inputMultiplier = [double]$longContext.InputMultiplier
    $outputMultiplier = [double]$longContext.OutputMultiplier

    $unitTokens = if ($null -ne $PricingDocument.PSObject.Properties['unitTokens'] -and [double]$PricingDocument.unitTokens -gt 0) {
        [double]$PricingDocument.unitTokens
    } else { 1000000.0 }
    # Cache creation/write tokens are a subset of uncached input. Price them
    # once at the official 1.25x write rate, then price only the remainder at
    # the normal input rate. This keeps task, call, interval, project and
    # history paths on the same formula.
    [Int64]$cacheCreation = [Math]::Min([Math]::Max([Int64]0, $CacheCreationTokens), [Math]::Max([Int64]0, [Int64]$Usage.Uncached))
    [Int64]$ordinaryUncached = [Math]::Max([Int64]0, [Int64]$Usage.Uncached - $cacheCreation)
    $cacheWritePrice = if ($null -ne $price.PSObject.Properties['cacheWrite']) { [double]$price.cacheWrite } else {
        [double]$price.input * $(if ($null -ne $price.PSObject.Properties['cacheWriteMultiplier']) { [double]$price.cacheWriteMultiplier } else { 1.25 })
    }
    $cacheCreationCost = ([double]$cacheCreation / $unitTokens) * $cacheWritePrice * $inputMultiplier
    $inputCost = ([double]$ordinaryUncached / $unitTokens) * [double]$price.input * $inputMultiplier + $cacheCreationCost
    $cachedCost = ([double]$Usage.Cached / $unitTokens) * [double]$price.cachedInput * $inputMultiplier
    $outputCost = ([double]$Usage.Output / $unitTokens) * [double]$price.output * $outputMultiplier

    [pscustomobject]@{
        Known = $true
        Model = $Model
        Price = $price
        ServiceTier = $tier
        ServiceTierKnown = $serviceTierComplete
        ServiceTierComplete = $serviceTierComplete
        ServiceTierEvidenceComplete = $modeEvidenceComplete
        ModeEvidenceComplete = $modeEvidenceComplete
        ModeAssumptionApplied = $manualModeAssumption
        ManualServiceTierApplied = $manualModeAssumption
        ServiceTierSource = $effectiveServiceTierSource
        PricingReason = 'priced'
        InputCost = $inputCost
        CachedCost = $cachedCost
        OutputCost = $outputCost
        TotalCost = $inputCost + $cachedCost + $outputCost
        CacheCreationCost = $cacheCreationCost
        CacheWriteObservable = if ($null -ne $CacheWriteObservable) { [bool]$CacheWriteObservable } else { $false }
        CostCoverage = if ($null -ne $CacheWriteObservable -and [bool]$CacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
        LongContextApplied = [bool]$longContext.Applied
        InputMultiplier = $inputMultiplier
        OutputMultiplier = $outputMultiplier
        ModelContextWindow = $longContext.ContextWindow
        LongContextThreshold = $longContext.Threshold
        LongContextSource = $longContext.Source
    }
}

function New-TokenRaderMeasurementBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [hashtable]$RateLimitSnapshotCache = $null,
        [string]$AccountIdentity = ''
    )

    $startedAt = [DateTimeOffset]::Now
    $files = @()
    if (Test-Path -LiteralPath $SessionsRoot) {
        $files = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{
                FilePath = $_.FullName
                Length = [Int64]$_.Length
                LastWriteTimeUtc = $_.LastWriteTimeUtc
                BaselineLoaded = $false
                BaselineTask = $null
                BaselineModel = ''
            }
        })
    }
    $startOffsets = @{}
    foreach ($entry in $files) { $startOffsets[[string]$entry.FilePath] = [Int64]$entry.Length }
    $rateLimits = Get-TokenRaderLatestRateLimits -SessionsRoot $SessionsRoot -EndOffsets $startOffsets -SnapshotCache $RateLimitSnapshotCache

    [pscustomobject]@{
        StartedAt = $startedAt
        SessionsRoot = $SessionsRoot
        Files = $files
        StartOffsets = $startOffsets
        RateLimits = $rateLimits
        StartRateLimits = $rateLimits
        AccountIdentity = $AccountIdentity
    }
}

function ConvertTo-TokenRaderSignature {
    param([string[]]$Parts)

    # Deterministic content hash over "path|length|lastWriteTicks" lines. The
    # newline separator cannot appear inside Windows file names, so the joined
    # string is unambiguous.
    $joined = @($Parts) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($joined))
        return ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-TokenRaderSessionTreeSignature {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)

    $parts = @()
    if (Test-Path -LiteralPath $SessionsRoot) {
        $parts = @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue | ForEach-Object {
            '{0}|{1}|{2}' -f $_.FullName, [Int64]$_.Length, $_.LastWriteTimeUtc.Ticks
        })
    }
    return ConvertTo-TokenRaderSignature -Parts $parts
}

function ConvertTo-TokenRaderCanonicalPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)

    # Expands 8.3 short names (e.g. RUNNER~1 -> runneradmin) and normalizes
    # separators so path keys match regardless of which form the string came
    # from ($env:TEMP can resolve to a short form on CI runners while
    # Get-ChildItem returns the long form).
    try { return [IO.Path]::GetFullPath($Path) } catch { return $Path }
}

function Get-TokenRaderIntervalResult {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [string[]]$IncludedFiles = @(),
        [hashtable]$BaselineSnapshots = $null,
        [hashtable]$EndOffsets = $null
    )

    # Windows file paths are case-insensitive and may be expressed as 8.3 short
    # names, so every path-keyed lookup below uses canonical full paths in an
    # OrdinalIgnoreCase comparer.
    $baselineMap = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($Baseline.Files)) { $baselineMap[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$entry.FilePath))] = $entry }

    $currentFiles = @()
    if (@($IncludedFiles).Count -gt 0) {
        $currentFiles = @($IncludedFiles | ForEach-Object {
            if (Test-Path -LiteralPath $_) { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue }
        })
    } elseif (Test-Path -LiteralPath ([string]$Baseline.SessionsRoot)) {
        $currentFiles = @(Get-ChildItem -LiteralPath ([string]$Baseline.SessionsRoot) -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
    }
    $fileBySessionId = @{}
    foreach ($file in $currentFiles) { $fileBySessionId[(Get-TokenRaderSessionIdFromPath -FilePath $file.FullName)] = (ConvertTo-TokenRaderCanonicalPath -Path ([string]$file.FullName)) }

    $endOffsetMap = $null
    if ($null -ne $EndOffsets) {
        $endOffsetMap = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($EndOffsets.Keys)) { $endOffsetMap[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$key))] = $EndOffsets[$key] }
    }
    if ($null -ne $BaselineSnapshots) {
        $normalizedSnapshots = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in @($BaselineSnapshots.Keys)) { $normalizedSnapshots[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$key))] = $BaselineSnapshots[$key] }
        $BaselineSnapshots = $normalizedSnapshots
    }

    $metadataByPath = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    $metadataBySessionId = @{}
    $loadMetadata = {
        param([string]$FilePath)
        $canonicalPath = ConvertTo-TokenRaderCanonicalPath -Path $FilePath
        if ($metadataByPath.ContainsKey($canonicalPath)) { return $metadataByPath[$canonicalPath] }
        $metadata = Get-TokenRaderSessionMetadata -FilePath $FilePath
        $metadataByPath[$canonicalPath] = $metadata
        $metadataBySessionId[[string]$metadata.SessionId] = $metadata
        if (-not $fileBySessionId.ContainsKey([string]$metadata.SessionId)) { $fileBySessionId[[string]$metadata.SessionId] = $canonicalPath }
        return $metadata
    }
    $loadBaselineSnapshot = {
        param($Entry)
        if ($null -eq $Entry) { return $null }
        $snapshotPath = ConvertTo-TokenRaderCanonicalPath -Path ([string]$Entry.FilePath)
        if ($null -ne $BaselineSnapshots -and $BaselineSnapshots.ContainsKey($snapshotPath)) {
            return $BaselineSnapshots[$snapshotPath].Task
        }
        if (-not [bool]$Entry.BaselineLoaded) {
            $snapshot = Get-TokenRaderUsageSnapshot -FilePath $snapshotPath -EndOffset ([Int64]$Entry.Length)
            $Entry.BaselineTask = if ($null -ne $snapshot) { $snapshot.Task } else { $null }
            $Entry.BaselineModel = if ($null -ne $snapshot) { [string]$snapshot.Model } else { '' }
            $baselineTier = if ($null -ne $snapshot) { [string]$snapshot.ContextServiceTier } else { '' }
            $Entry | Add-Member -NotePropertyName BaselineServiceTier -NotePropertyValue $baselineTier -Force
            $Entry.BaselineLoaded = $true
            if ($null -ne $BaselineSnapshots) {
                $BaselineSnapshots[$snapshotPath] = [pscustomobject]@{
                    Task = $Entry.BaselineTask
                    Model = $Entry.BaselineModel
                    ServiceTier = $baselineTier
                }
            }
        }
        return $Entry.BaselineTask
    }
    $baselineEventFingerprintsByPath = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    $loadBaselineEventFingerprints = {
        param($Entry)
        $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        if ($null -eq $Entry) { return ,$keys }
        $ancestorPath = ConvertTo-TokenRaderCanonicalPath -Path ([string]$Entry.FilePath)
        if ($baselineEventFingerprintsByPath.ContainsKey($ancestorPath)) {
            return ,$baselineEventFingerprintsByPath[$ancestorPath]
        }
        $ancestorEvents = Get-TokenRaderUsageEvents -FilePath $ancestorPath -StartOffset 0 -EndOffset ([Int64]$Entry.Length)
        foreach ($ancestorEvent in @($ancestorEvents.Events)) {
            $hasTotal = if ($null -ne $ancestorEvent.PSObject.Properties['HasTotal']) {
                [bool]$ancestorEvent.HasTotal
            } else { $null -ne $ancestorEvent.Total }
            if ($hasTotal) { [void]$keys.Add([string]$ancestorEvent.UsageFingerprint) }
        }
        $baselineEventFingerprintsByPath[$ancestorPath] = $keys
        return ,$keys
    }

    $changed = New-Object System.Collections.ArrayList
    foreach ($file in $currentFiles) {
        $fullPath = ConvertTo-TokenRaderCanonicalPath -Path ([string]$file.FullName)
        if ($null -ne $endOffsetMap -and -not $endOffsetMap.ContainsKey($fullPath)) { continue }
        $baselineEntry = if ($baselineMap.ContainsKey($fullPath)) { $baselineMap[$fullPath] } else { $null }
        $visibleLength = [Int64]$file.Length
        if ($null -ne $endOffsetMap -and $endOffsetMap.ContainsKey($fullPath)) {
            $visibleLength = [Math]::Min($visibleLength, [Int64]$endOffsetMap[$fullPath])
        }
        if ($null -ne $baselineEntry -and $visibleLength -eq [Int64]$baselineEntry.Length) { continue }
        $metadata = & $loadMetadata $fullPath
        [void]$changed.Add([pscustomobject]@{
            File = $file
            FullPath = $fullPath
            BaselineEntry = $baselineEntry
            Metadata = $metadata
            IsNew = ($null -eq $baselineEntry)
            RootId = [string]$metadata.SessionId
            Depth = 0
            BaselineAncestor = $null
        })
    }

    foreach ($change in @($changed)) {
        $currentMetadata = $change.Metadata
        $rootId = [string]$currentMetadata.SessionId
        $depth = 0
        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        while ($null -ne $currentMetadata -and $depth -lt 64) {
            if (-not $visited.Add([string]$currentMetadata.SessionId)) { break }
            $parentId = if (-not [string]::IsNullOrWhiteSpace([string]$currentMetadata.ParentThreadId)) {
                [string]$currentMetadata.ParentThreadId
            } else { [string]$currentMetadata.ForkedFromId }
            if ([string]::IsNullOrWhiteSpace($parentId)) { break }
            $rootId = $parentId
            $depth++
            if (-not $fileBySessionId.ContainsKey($parentId)) { break }
            $parentPath = [string]$fileBySessionId[$parentId]
            if ($null -eq $change.BaselineAncestor -and $baselineMap.ContainsKey($parentPath)) {
                $change.BaselineAncestor = $baselineMap[$parentPath]
            }
            $currentMetadata = & $loadMetadata $parentPath
            if ($null -ne $currentMetadata) { $rootId = [string]$currentMetadata.SessionId }
        }
        $change.RootId = $rootId
        $change.Depth = $depth
    }

    [Int64]$aggregateInput = 0
    [Int64]$cached = 0
    [Int64]$output = 0
    [Int64]$reasoning = 0
    [double]$inputCost = 0
    [double]$cachedCost = 0
    [double]$outputCost = 0
    [double]$cacheCreationCost = 0
    [Int64]$standardContextEvents = 0
    [Int64]$longContextEvents = 0
    [Int64]$standardContextInput = 0
    [Int64]$longContextInput = 0
    [Int64]$longContextOutput = 0
    [double]$longContextExtraCost = 0
    $cacheWriteObservable = $true
    [Int64]$rawEventCount = 0
    [Int64]$countedEventCount = 0
    [Int64]$duplicateEventCount = 0
    [Int64]$inheritedEventCount = 0
    $firstCountedAt = $null
    $lastCountedAt = $null
    [Int64]$bytesRead = 0
    $seenEvents = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $partialStrongIdentities = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    $rootHistoryEvents = @{}
    $activeFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $models = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $unknownModels = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $costBuckets = @{}
    [bool]$serviceTierComplete = $true
    [bool]$modeEvidenceComplete = $true
    [bool]$modeAssumptionApplied = $false
    # Price resolution is deterministic per model string; Resolve-TokenRaderPrice
    # sorts the pricing table on every call, so memoize per call.
    $priceCache = @{}
    $latestRateLimits = $null
    $latestRateObserved = [DateTimeOffset]::MinValue

    foreach ($change in @($changed | Sort-Object Depth, @{ Expression = { $_.File.CreationTimeUtc } })) {
        $changePath = [string]$change.FullPath
        $rootHistoryKey = ([string]$change.RootId).ToLowerInvariant()
        if (-not $rootHistoryEvents.ContainsKey($rootHistoryKey)) {
            $rootHistoryEvents[$rootHistoryKey] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        }
        $rootHistory = $rootHistoryEvents[$rootHistoryKey]
        $baselineTask = $null
        $initialModel = ''
        $initialServiceTier = ''
        $startOffset = 0
        if ($null -ne $change.BaselineEntry) {
            $baselineTask = & $loadBaselineSnapshot $change.BaselineEntry
            $initialModel = [string]$change.BaselineEntry.BaselineModel
            if ($null -ne $change.BaselineEntry.PSObject.Properties['BaselineServiceTier']) { $initialServiceTier = [string]$change.BaselineEntry.BaselineServiceTier }
            if ($null -ne $BaselineSnapshots -and $BaselineSnapshots.ContainsKey($changePath) -and
                $null -ne $BaselineSnapshots[$changePath].PSObject.Properties['ServiceTier']) { $initialServiceTier = [string]$BaselineSnapshots[$changePath].ServiceTier }
            $startOffset = [Int64]$change.BaselineEntry.Length
        }
        $ancestorEventFingerprints = if ($change.IsNew -and $null -ne $change.BaselineAncestor) {
            & $loadBaselineEventFingerprints $change.BaselineAncestor
        } else { $null }

        $effectiveEnd = [Int64]$change.File.Length
        if ($null -ne $endOffsetMap -and $endOffsetMap.ContainsKey($changePath)) {
            $effectiveEnd = [Math]::Min($effectiveEnd, [Int64]$endOffsetMap[$changePath])
        }

        # Every recompute re-parses the bytes written since the baseline so no
        # per-event state is retained between calls (memory stays flat during a
        # measurement). The desktop UI keeps the UI responsive by running this
        # in a background runspace and skips recomputes entirely when the
        # session-tree signature is unchanged.
        $parsed = Get-TokenRaderUsageEvents -FilePath $changePath -StartOffset $startOffset -EndOffset $effectiveEnd `
            -InitialModel $initialModel -InitialServiceTier $initialServiceTier -InitialTotal $baselineTask
        $bytesRead += [Int64]$parsed.BytesRead
        if (@($parsed.Events).Count -gt 0) { [void]$activeFiles.Add($changePath) }
        $fallbackModel = [string]$parsed.LastModel
        $seenCumulativeSnapshots = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        if ($null -ne $baselineTask) {
            [void]$seenCumulativeSnapshots.Add((New-TokenRaderCumulativeFingerprint -TotalUsage $baselineTask))
        }

        # A missing-total row has no safe cumulative identity.  When the same
        # session nevertheless exposes an explicit request/response id on both
        # a partial row and a complete row, the complete/terminal observation
        # must win regardless of arrival order.  Preselect it before the
        # accounting pass so a partial-first file cannot become first-wins and
        # a complete-first file cannot double count the later partial row.
        # Scope this map to the session path, not RootId: sibling sessions may
        # legitimately reuse a request id and must remain independent.
        $strongIdentityGroups = New-Object hashtable ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($candidateEvent in @($parsed.Events)) {
            $candidateHasTotal = if ($null -ne $candidateEvent.PSObject.Properties['HasTotal']) {
                [bool]$candidateEvent.HasTotal
            } else { $null -ne $candidateEvent.Total }
            $candidateRequestId = if ($null -ne $candidateEvent.PSObject.Properties['RequestId']) { ([string]$candidateEvent.RequestId).Trim() } else { '' }
            $candidateResponseId = if ($null -ne $candidateEvent.PSObject.Properties['ResponseId']) { ([string]$candidateEvent.ResponseId).Trim() } else { '' }
            $candidateStrongIdentity = if (-not [string]::IsNullOrWhiteSpace($candidateRequestId)) {
                'request:' + $candidateRequestId.ToLowerInvariant()
            } elseif (-not [string]::IsNullOrWhiteSpace($candidateResponseId)) {
                'response:' + $candidateResponseId.ToLowerInvariant()
            } else { '' }
            if ([string]::IsNullOrWhiteSpace($candidateStrongIdentity)) { continue }
            $candidateGroupKey = $changePath.ToLowerInvariant() + '|' + $candidateStrongIdentity
            if (-not $strongIdentityGroups.ContainsKey($candidateGroupKey)) {
                $strongIdentityGroups[$candidateGroupKey] = [pscustomobject]@{
                    HasMissingTotal = $false
                    HasComplete = $false
                    CompleteEvent = $null
                }
            }
            $candidateGroup = $strongIdentityGroups[$candidateGroupKey]
            if ($candidateHasTotal) {
                $candidateGroup.HasComplete = $true
                if ($null -eq $candidateGroup.CompleteEvent -or
                    $candidateEvent.Timestamp -ge $candidateGroup.CompleteEvent.Timestamp) {
                    $candidateGroup.CompleteEvent = $candidateEvent
                }
            } else {
                $candidateGroup.HasMissingTotal = $true
            }
        }

        foreach ($event in @($parsed.Events)) {
            $rawEventCount++
            if ($null -ne $event.RateLimits -and $event.RateLimits.ObservedAt -gt $latestRateObserved -and
                ($null -ne $event.RateLimits.FiveHour -or $null -ne $event.RateLimits.Weekly)) {
                $latestRateLimits = $event.RateLimits
                $latestRateObserved = $event.RateLimits.ObservedAt
            }
            $usageFingerprint = [string]$event.UsageFingerprint
            $hasTotal = if ($null -ne $event.PSObject.Properties['HasTotal']) {
                [bool]$event.HasTotal
            } else { $null -ne $event.Total }
            $callAvailable = if ($null -ne $event.PSObject.Properties['CallAvailable']) {
                [bool]$event.CallAvailable
            } else { $null -ne $event.Call }

            $requestId = if ($null -ne $event.PSObject.Properties['RequestId']) { ([string]$event.RequestId).Trim() } else { '' }
            $responseId = if ($null -ne $event.PSObject.Properties['ResponseId']) { ([string]$event.ResponseId).Trim() } else { '' }
            $strongIdentity = if (-not [string]::IsNullOrWhiteSpace($requestId)) {
                'request:' + $requestId.ToLowerInvariant()
            } elseif (-not [string]::IsNullOrWhiteSpace($responseId)) {
                'response:' + $responseId.ToLowerInvariant()
            } else { '' }

            # Reconcile a partial last-only observation with an explicit
            # request/response identity only inside this same session.  If a
            # complete terminal row exists anywhere in the parsed group, it is
            # the sole representative; this is intentionally order-independent.
            # Groups containing only partial rows retain first-wins behaviour
            # for the same session/id, while rows without a strong id remain
            # independent because no cumulative identity can be invented.
            if (-not [string]::IsNullOrWhiteSpace($strongIdentity)) {
                $partialKey = $changePath.ToLowerInvariant() + '|' + $strongIdentity
                $eventGroup = if ($strongIdentityGroups.ContainsKey($partialKey)) { $strongIdentityGroups[$partialKey] } else { $null }
                if ($null -ne $eventGroup -and $eventGroup.HasMissingTotal) {
                    if ($eventGroup.HasComplete) {
                        if (-not [object]::ReferenceEquals($event, $eventGroup.CompleteEvent)) {
                            $duplicateEventCount++
                            continue
                        }
                    } elseif (-not $hasTotal) {
                        if ($partialStrongIdentities.ContainsKey($partialKey)) {
                            $duplicateEventCount++
                            continue
                        }
                        $partialStrongIdentities[$partialKey] = $true
                    }
                }
            }

            # Cumulative snapshots are the only reliable identity for a
            # status refresh. A last-only record has no cumulative identity;
            # treating its call as a fabricated total would collapse distinct
            # calls (and parent/child copies) incorrectly, so it is counted
            # independently.
            if ($hasTotal) {
                $cumulativeFingerprint = New-TokenRaderCumulativeFingerprint -TotalUsage $event.Total
                if (-not $seenCumulativeSnapshots.Add($cumulativeFingerprint)) {
                    $duplicateEventCount++
                    continue
                }
                if ($change.IsNew -and $null -ne $ancestorEventFingerprints -and $ancestorEventFingerprints.Contains($usageFingerprint)) {
                    $inheritedEventCount++
                    continue
                }
                if ($change.Depth -gt 0 -and $rootHistory.Contains($usageFingerprint)) {
                    $duplicateEventCount++
                    continue
                }
                [void]$rootHistory.Add($usageFingerprint)
                # Fingerprints produced by the parser include timestamp/model
                # for display/debugging. Lineage identity uses token usage only
                # for records with a trustworthy cumulative total.
                $eventKey = ([string]$change.RootId) + '|' + $usageFingerprint
                if (-not $seenEvents.Add($eventKey)) {
                    $duplicateEventCount++
                    continue
                }
            }
            $call = $event.Call
            if (-not $callAvailable -or $null -eq $call -or
                ([Int64]$call.Input -le 0 -and [Int64]$call.Output -le 0)) { continue }
            $countedEventCount++
            if ($null -eq $firstCountedAt -or $event.Timestamp -lt $firstCountedAt) { $firstCountedAt = $event.Timestamp }
            if ($null -eq $lastCountedAt -or $event.Timestamp -gt $lastCountedAt) { $lastCountedAt = $event.Timestamp }
            $aggregateInput += [Int64]$call.Input
            $cached += [Int64]$call.Cached
            $output += [Int64]$call.Output
            $reasoning += [Int64]$call.ReasoningOutput

            $model = if (-not [string]::IsNullOrWhiteSpace([string]$event.Model)) { [string]$event.Model } else { $fallbackModel }
            if (-not [string]::IsNullOrWhiteSpace($model)) { [void]$models.Add($model) }
            if (-not $priceCache.ContainsKey($model)) {
                $priceCache[$model] = Resolve-TokenRaderPrice -Model $model -PricingDocument $PricingDocument
            }
            $price = $priceCache[$model]
            $callDerived = $null -ne $event.PSObject.Properties['CallDerived'] -and [bool]$event.CallDerived
            $requestInputObservable = -not $callDerived
            $longContextThreshold = if ($null -ne $price -and $null -ne $price.PSObject.Properties['longContextThreshold']) { [Int64]$price.longContextThreshold } else { 0L }
            $longContextPricingUncertain = $callDerived -and $longContextThreshold -gt 0L -and [Int64]$call.Input -gt $longContextThreshold
            $longContext = $false
            if ($requestInputObservable -and $longContextThreshold -gt 0L) {
                $longContext = [Int64]$call.Input -gt $longContextThreshold
            }
            if ($null -ne $event.PSObject.Properties['CacheWriteObservable'] -and -not [bool]$event.CacheWriteObservable) { $cacheWriteObservable = $false }
            if ($longContext) {
                $longContextEvents++
                $longContextInput += [Int64]$call.Input
                $longContextOutput += [Int64]$call.Output
            } else {
                $standardContextEvents++
                $standardContextInput += [Int64]$call.Input
            }
            $serviceTier = ConvertTo-TokenRaderServiceTier ([string]$event.ServiceTier)
            $bucketKey = $model.ToLowerInvariant() + '|' + $serviceTier + '|' + $(if ($longContext) { 'long' } else { 'standard' }) +
                $(if (-not $requestInputObservable) { '|' + $(if ($longContextPricingUncertain) { 'uncertain' } else { 'bounded' }) } else { '' })
            if (-not $costBuckets.ContainsKey($bucketKey)) {
                $costBuckets[$bucketKey] = [pscustomobject]@{
                    Model = $model
                    ServiceTier = $serviceTier
                    LongContext = $longContext
                    RequestInputObservable = $requestInputObservable
                    LongContextPricingUncertain = $longContextPricingUncertain
                    Input = [Int64]0
                    Cached = [Int64]0
                    Output = [Int64]0
                    Reasoning = [Int64]0
                    CacheCreationTokens = [Int64]0
                    CacheWriteObservable = $true
                    Events = [Int64]0
                }
            }
            $bucket = $costBuckets[$bucketKey]
            $bucket.Input += [Int64]$call.Input
            $bucket.Cached += [Int64]$call.Cached
            $bucket.Output += [Int64]$call.Output
            $bucket.Reasoning += [Int64]$call.ReasoningOutput
            if ($null -ne $event.PSObject.Properties['CacheCreationTokens']) {
                $bucket.CacheCreationTokens += [Int64]$event.CacheCreationTokens
            }
            if ($null -eq $event.PSObject.Properties['CacheWriteObservable'] -or
                -not [bool]$event.CacheWriteObservable) {
                $bucket.CacheWriteObservable = $false
            }
            $bucket.RequestInputObservable = $bucket.RequestInputObservable -and $requestInputObservable
            $bucket.LongContextPricingUncertain = $bucket.LongContextPricingUncertain -or $longContextPricingUncertain
            $bucket.Events++
        }
    }

    $items = New-Object System.Collections.ArrayList
    foreach ($bucket in @($costBuckets.Values)) {
        $bucketUsage = New-TokenRaderUsage -InputTokens $bucket.Input -CachedTokens $bucket.Cached -OutputTokens $bucket.Output -ReasoningOutputTokens $bucket.Reasoning
        $cost = Get-TokenRaderCost -Usage $bucketUsage -Model ([string]$bucket.Model) -PricingDocument $PricingDocument `
            -Scope call -LongContextApplied ([bool]$bucket.LongContext) `
            -CacheCreationTokens ([Int64]$bucket.CacheCreationTokens) `
            -CacheWriteObservable ([bool]$bucket.CacheWriteObservable) `
            -RequestInputObservable ([bool]$bucket.RequestInputObservable) `
            -LongContextPricingUncertain ([bool]$bucket.LongContextPricingUncertain) `
            -ServiceTier ([string]$bucket.ServiceTier)
        $itemTierComplete = $null -ne $cost.PSObject.Properties['ServiceTierComplete'] -and [bool]$cost.ServiceTierComplete
        $itemModeComplete = $null -ne $cost.PSObject.Properties['ModeEvidenceComplete'] -and [bool]$cost.ModeEvidenceComplete
        $itemAssumption = $null -ne $cost.PSObject.Properties['ModeAssumptionApplied'] -and [bool]$cost.ModeAssumptionApplied
        # A compiled aggregate carries ServiceTierSource even for legacy rows.
        # A non-empty tier with an explicitly empty source is not proof of an
        # observed mode; retain its Standard/tier price for compatibility but
        # keep strict quota evidence incomplete.  Synthetic callers that
        # predate this property remain compatible when it is absent.
        $hasTierSource = $null -ne $bucket.PSObject.Properties['ServiceTierSource']
        $bucketTierSource = if ($hasTierSource) { ([string]$bucket.ServiceTierSource).Trim().ToLowerInvariant() } else { '' }
        $bucketEvidenceProperty = if ($null -ne $bucket.PSObject.Properties['ServiceTierEvidenceComplete']) {
            $bucket.PSObject.Properties['ServiceTierEvidenceComplete']
        } elseif ($null -ne $bucket.PSObject.Properties['ModeEvidenceComplete']) {
            $bucket.PSObject.Properties['ModeEvidenceComplete']
        } else { $null }
        if ($null -ne $bucketEvidenceProperty -and -not $itemAssumption) {
            $itemModeComplete = [bool]$bucketEvidenceProperty.Value
        } else {
            $untrustedTierSource = $bucketTierSource -eq '' -or $bucketTierSource -eq 'indexed' -or $bucketTierSource -eq 'mixed'
            if ($hasTierSource -and $tier -ne '' -and $untrustedTierSource) {
                $itemModeComplete = $false
            }
        }
        if (-not $itemTierComplete) { $serviceTierComplete = $false }
        if (-not $itemModeComplete) { $modeEvidenceComplete = $false }
        if ($itemAssumption) { $modeAssumptionApplied = $true }
        if ($cost.Known) {
            $bucketInputCost = [double]$cost.InputCost
            $bucketCachedCost = [double]$cost.CachedCost
            $bucketOutputCost = [double]$cost.OutputCost
            $cacheCreationCost += [double]$cost.CacheCreationCost
            $inputCost += $bucketInputCost
            $cachedCost += $bucketCachedCost
            $outputCost += $bucketOutputCost
            if ([bool]$bucket.LongContext) {
                [double]$standardInputCost = if ([double]$cost.InputMultiplier -gt 0) { $bucketInputCost / [double]$cost.InputMultiplier } else { $bucketInputCost }
                [double]$standardCachedCost = if ([double]$cost.InputMultiplier -gt 0) { $bucketCachedCost / [double]$cost.InputMultiplier } else { $bucketCachedCost }
                [double]$standardOutputCost = if ([double]$cost.OutputMultiplier -gt 0) { $bucketOutputCost / [double]$cost.OutputMultiplier } else { $bucketOutputCost }
                $longContextExtraCost += ($bucketInputCost + $bucketCachedCost + $bucketOutputCost) -
                    ($standardInputCost + $standardCachedCost + $standardOutputCost)
            }
        } else {
            $unknownLabel = if ([string]::IsNullOrWhiteSpace([string]$bucket.Model)) { '未知模型' } else { [string]$bucket.Model }
            [void]$unknownModels.Add($unknownLabel)
        }
        [void]$items.Add([pscustomobject]@{
            Model = [string]$bucket.Model
            ServiceTier = [string]$cost.ServiceTier
            ServiceTierKnown = [bool]$cost.ServiceTierKnown
            ServiceTierComplete = $itemTierComplete
            ModeEvidenceComplete = $itemModeComplete
            ModeAssumptionApplied = $itemAssumption
            ManualServiceTierApplied = $itemAssumption
            ServiceTierSource = [string]$cost.ServiceTierSource
            LongContext = [bool]$bucket.LongContext
            RequestInputObservable = [bool]$bucket.RequestInputObservable
            LongContextPricingUncertain = [bool]$bucket.LongContextPricingUncertain
            Usage = $bucketUsage
            Cost = $cost
            Events = [Int64]$bucket.Events
        })
    }

    $usage = New-TokenRaderUsage -InputTokens $aggregateInput -CachedTokens $cached -OutputTokens $output -ReasoningOutputTokens $reasoning
    $modelList = @($models | Sort-Object)
    $modelDisplay = if ($modelList.Count -eq 0) { '等待模型调用' }
                    elseif ($modelList.Count -eq 1) { $modelList[0] }
                    else { ('{0} 个模型' -f $modelList.Count) }

    $startRateLimits = if ($null -ne $Baseline.PSObject.Properties['StartRateLimits']) {
        $Baseline.StartRateLimits
    } elseif ($null -ne $Baseline.PSObject.Properties['RateLimits']) {
        $Baseline.RateLimits
    } else { $null }
    $endRateLimits = $latestRateLimits
    if ($null -ne $Baseline.PSObject.Properties['StartOffsets']) {
        $endRateLimits = Get-TokenRaderLatestRateLimits -SessionsRoot ([string]$Baseline.SessionsRoot) -EndOffsets $EndOffsets
    }
    $pricingComplete = ($unknownModels.Count -eq 0)

    $signatureParts = foreach ($file in $currentFiles) {
        '{0}|{1}|{2}' -f $file.FullName, [Int64]$file.Length, $file.LastWriteTimeUtc.Ticks
    }

    [pscustomobject]@{
        StartedAt = $Baseline.StartedAt
        EndedAt = [DateTimeOffset]::Now
        Usage = $usage
        Models = $modelList
        ModelDisplay = $modelDisplay
        ChangedSessions = $activeFiles.Count
        Items = @($items)
        InputCost = $inputCost
        CachedCost = $cachedCost
        OutputCost = $outputCost
        TotalCost = $inputCost + $cachedCost + $outputCost
        CacheCreationCost = $cacheCreationCost
        PricingComplete = $pricingComplete
        CostComplete = $pricingComplete
        ServiceTierComplete = $serviceTierComplete
        ModeEvidenceComplete = $modeEvidenceComplete
        ModeAssumptionApplied = $modeAssumptionApplied
        ManualServiceTierApplied = $modeAssumptionApplied
        QuotaEvidenceComplete = $pricingComplete -and $serviceTierComplete -and
            ($modeEvidenceComplete -or $modeAssumptionApplied)
        UnknownModels = @($unknownModels | Sort-Object)
        StartRateLimits = $startRateLimits
        EndRateLimits = $endRateLimits
        RateLimits = $endRateLimits
        RawEvents = $rawEventCount
        CountedEvents = $countedEventCount
        DuplicateEventsDropped = $duplicateEventCount
        InheritedEventsDropped = $inheritedEventCount
        BytesRead = $bytesRead
        Signature = ConvertTo-TokenRaderSignature -Parts $signatureParts
        BaselineSnapshots = if ($null -ne $BaselineSnapshots) { $BaselineSnapshots } else { @{} }
        FirstCountedAt = $firstCountedAt
        LastCountedAt = $lastCountedAt
        StandardContextEvents = $standardContextEvents
        LongContextEvents = $longContextEvents
        StandardContextInput = $standardContextInput
        LongContextInput = $longContextInput
        LongContextOutput = $longContextOutput
        LongContextExtraCost = $longContextExtraCost
        CacheWriteObservable = $cacheWriteObservable
        CostCoverage = if ($cacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
    }
}

function Get-TokenRaderProjectResult {
    param(
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [Parameter(Mandatory = $true)]$PricingDocument
    )

    $filePaths = @($Project.FilePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($filePaths.Count -eq 0) { return $null }
    $index = $script:TokenRaderIndex
    if ($null -ne $index -and $null -ne $index.Connection -and
        [string]::Equals([string]$index.SessionsRoot, [string]$SessionsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $allEnds = Get-TokenRaderCursorOffsets -Connection $index.Connection
        $starts = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        $ends = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in $filePaths) {
            $canonical = ConvertTo-TokenRaderCanonicalPath -Path ([string]$path)
            if (-not $allEnds.ContainsKey($canonical)) { continue }
            $starts[$canonical] = 0L
            $ends[$canonical] = [Int64]$allEnds[$canonical]
        }
        if ($ends.Count -gt 0) {
            $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in @($PricingDocument.models)) {
                $threshold = if ($null -ne $entry.PSObject.Properties['longContextThreshold']) { [Int64]$entry.longContextThreshold } else { 0L }
                if (-not [string]::IsNullOrWhiteSpace([string]$entry.id)) { $thresholds[[string]$entry.id] = $threshold }
                foreach ($alias in @($entry.aliases)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { $thresholds[[string]$alias] = $threshold }
                }
            }
            $aggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
                $index.Connection, $starts, $ends, [DateTimeOffset]::MinValue,
                $thresholds, [Threading.CancellationToken]::None, $null)
            $priced = ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $PricingDocument
            $indexedResult = [pscustomobject]@{
                StartedAt = [DateTimeOffset]::MinValue
                EndedAt = [DateTimeOffset]::Now
                Usage = $priced.Usage
                Models = @($priced.Models)
                ModelDisplay = [string]$priced.ModelDisplay
                ChangedSessions = [int]$aggregate.ChangedSessions
                Items = @($priced.Items)
                InputCost = [double]$priced.InputCost
                CachedCost = [double]$priced.CachedCost
                OutputCost = [double]$priced.OutputCost
                TotalCost = [double]$priced.TotalCost
                CacheCreationCost = [double]$priced.CacheCreationCost
                StandardContextEvents = [Int64]$priced.StandardContextEvents
                LongContextEvents = [Int64]$priced.LongContextEvents
                StandardContextInput = [Int64]$priced.StandardContextInput
                LongContextInput = [Int64]$priced.LongContextInput
                LongContextOutput = [Int64]$priced.LongContextOutput
                LongContextExtraCost = [double]$priced.LongContextExtraCost
                CacheWriteObservable = [bool]$priced.CacheWriteObservable
                CostCoverage = [string]$priced.CostCoverage
                PricingComplete = [bool]$priced.PricingComplete
                CostComplete = [bool]$priced.CostComplete
                ServiceTierComplete = [bool]$priced.ServiceTierComplete
                ModeEvidenceComplete = [bool]$priced.ModeEvidenceComplete
                ModeAssumptionApplied = [bool]$priced.ModeAssumptionApplied
                ManualServiceTierApplied = [bool]$priced.ManualServiceTierApplied
                QuotaEvidenceComplete = [bool]$priced.QuotaEvidenceComplete
                UnknownModels = @($priced.UnknownModels)
                StartRateLimits = $null
                EndRateLimits = $null
                RateLimits = $null
                RawEvents = [Int64]$aggregate.RawEvents
                CountedEvents = [Int64]$aggregate.CountedEvents
                DuplicateEventsDropped = [Int64]$aggregate.DuplicateEventsDropped
                InheritedEventsDropped = [Int64]$aggregate.InheritedEventsDropped
                BytesRead = [Int64]$aggregate.BytesRead
                ProcessedRows = [Int64]$aggregate.ProcessedRows
                ProcessingMilliseconds = [double]$aggregate.ProcessingMilliseconds
                FirstCountedAt = $aggregate.FirstCountedAt
                LastCountedAt = $aggregate.LastCountedAt
                IdentityComplete = [bool]$aggregate.IdentityComplete
                IdentitySources = @($aggregate.IdentitySources)
                UnidentifiedEvents = [Int64]$aggregate.UnidentifiedEvents
            }
            $indexedResult | Add-Member -NotePropertyName ProjectPath -NotePropertyValue ([string]$Project.ProjectPath)
            $indexedResult | Add-Member -NotePropertyName ProjectName -NotePropertyValue ([string]$Project.ProjectName)
            $indexedResult | Add-Member -NotePropertyName ProjectSessionCount -NotePropertyValue $filePaths.Count
            return $indexedResult
        }
    }
    $baseline = [pscustomobject]@{
        StartedAt = [DateTimeOffset]::MinValue
        SessionsRoot = $SessionsRoot
        Files = @()
        RateLimits = $null
    }
    $result = Get-TokenRaderIntervalResult -Baseline $baseline -PricingDocument $PricingDocument -IncludedFiles $filePaths
    $result | Add-Member -NotePropertyName ProjectPath -NotePropertyValue ([string]$Project.ProjectPath)
    $result | Add-Member -NotePropertyName ProjectName -NotePropertyValue ([string]$Project.ProjectName)
    $result | Add-Member -NotePropertyName ProjectSessionCount -NotePropertyValue $filePaths.Count
    return $result
}

function Get-TokenRaderSessionResult {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [Parameter(Mandatory = $true)]$PricingDocument
    )

    if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
    $baseline = [pscustomobject]@{
        StartedAt = [DateTimeOffset]::MinValue
        SessionsRoot = $SessionsRoot
        Files = @()
        RateLimits = $null
    }
    return Get-TokenRaderIntervalResult -Baseline $baseline -PricingDocument $PricingDocument -IncludedFiles @($FilePath)
}

function Get-TokenRaderQuotaEstimate {
    param(
        $StartRateLimits,
        $EndRateLimits,
        [double]$IntervalCost,
        [bool]$CostComplete = $true,
        $StartReferenceAt = $null,
        $EndReferenceAt = $null,
        $QuotaEvidence = $null
    )
    $useQuotaEvidence = $PSBoundParameters.ContainsKey('QuotaEvidence')

    function Get-WindowEstimate {
        param($StartWindow, $EndWindow, [string]$StartPlanType, [string]$EndPlanType, $Evidence)
        if ($null -eq $EndWindow) { return $null }
        if ($null -ne $EndWindow.PSObject.Properties['ScopeConflict'] -and [bool]$EndWindow.ScopeConflict) { return $null }
        if ($useQuotaEvidence) {
            $evidenceServiceTierComplete = if ($null -ne $Evidence -and $null -ne $Evidence.PSObject.Properties['ServiceTierComplete']) { [bool]$Evidence.ServiceTierComplete } else { $true }
            $evidenceModeComplete = if ($null -ne $Evidence -and $null -ne $Evidence.PSObject.Properties['ModeEvidenceComplete']) { [bool]$Evidence.ModeEvidenceComplete } else { $true }
            $evidenceModeAssumption = if ($null -ne $Evidence -and $null -ne $Evidence.PSObject.Properties['ModeAssumptionApplied']) { [bool]$Evidence.ModeAssumptionApplied } else { $false }
            $evidenceQuotaComplete = if ($null -ne $Evidence -and $null -ne $Evidence.PSObject.Properties['QuotaEvidenceComplete']) {
                [bool]$Evidence.QuotaEvidenceComplete
            } else {
                $evidenceServiceTierComplete -and ($evidenceModeComplete -or $evidenceModeAssumption)
            }
            if ($null -eq $Evidence -or $null -eq $Evidence.PSObject.Properties['BoundaryValid'] -or
                -not [bool]$Evidence.BoundaryValid -or $null -eq $Evidence.PSObject.Properties['EstimateSource'] -or
                ($null -ne $Evidence.PSObject.Properties['AttributionComplete'] -and -not [bool]$Evidence.AttributionComplete) -or
                [string]::IsNullOrWhiteSpace([string]$Evidence.EstimateSource) -or
                $null -eq $Evidence.PSObject.Properties['PricingComplete'] -or -not [bool]$Evidence.PricingComplete -or
                (-not $evidenceQuotaComplete -and -not ($null -ne $Evidence.PSObject.Properties['ReferencePricingApplied'] -and [bool]$Evidence.ReferencePricingApplied)) -or
                $null -eq $Evidence.PSObject.Properties['EstimatedTotalUsd'] -or [double]$Evidence.EstimatedTotalUsd -le 0 -or
                $null -eq $Evidence.PSObject.Properties['TotalCost'] -or [double]$Evidence.TotalCost -le 0 -or
                $null -eq $Evidence.PSObject.Properties['EndObservedAt'] -or
                $null -eq $Evidence.PSObject.Properties['EffectiveDeltaPercent'] -or
                [double]$Evidence.EffectiveDeltaPercent -le 0) { return $null }
            $evidenceCurrentAt = if ($null -ne $Evidence.PSObject.Properties['CurrentObservedAt']) {
                [DateTimeOffset]$Evidence.CurrentObservedAt
            } elseif ($null -ne $Evidence.PSObject.Properties['EndObservedAt']) {
                [DateTimeOffset]$Evidence.EndObservedAt
            } else { [DateTimeOffset]::MinValue }
            if ($null -eq $EndWindow.PSObject.Properties['ObservedAt'] -or
                $evidenceCurrentAt -ne [DateTimeOffset]$EndWindow.ObservedAt) { return $null }
            if ($null -ne $Evidence.PSObject.Properties['WindowMinutes'] -and
                [int]$Evidence.WindowMinutes -ne [int]$EndWindow.WindowMinutes) { return $null }
            if ($null -ne $Evidence.PSObject.Properties['LimitId'] -and $null -ne $EndWindow.PSObject.Properties['LimitId'] -and
                -not [string]::Equals([string]$Evidence.LimitId,[string]$EndWindow.LimitId,[StringComparison]::OrdinalIgnoreCase)) { return $null }
            if ($null -ne $Evidence.PSObject.Properties['PlanType'] -and
                -not [string]::IsNullOrWhiteSpace([string]$Evidence.PlanType) -and
                -not [string]::Equals([string]$Evidence.PlanType, [string]$EndPlanType, [StringComparison]::OrdinalIgnoreCase)) { return $null }
            if ($null -ne $Evidence.PSObject.Properties['ResetIdentity']) {
                $windowResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes ([int]$EndWindow.WindowMinutes) -ResetsAt $EndWindow.ResetsAt
                if ([string]::IsNullOrWhiteSpace($windowResetIdentity) -or
                    -not [string]::Equals([string]$Evidence.ResetIdentity, $windowResetIdentity, [StringComparison]::Ordinal)) { return $null }
            }
            if ($null -ne $EndReferenceAt -and $null -ne $EndWindow.ResetsAt -and
                [DateTimeOffset]$EndWindow.ResetsAt -le [DateTimeOffset]$EndReferenceAt) { return $null }
            if ($null -ne $Evidence.PSObject.Properties['LastCountedAt'] -and $null -ne $Evidence.LastCountedAt -and
                [DateTimeOffset]$Evidence.LastCountedAt -gt [DateTimeOffset]$Evidence.EndObservedAt) { return $null }
            [double]$currentUsedPercent = [double]$EndWindow.UsedPercent
            [double]$totalUsd = [double]$Evidence.EstimatedTotalUsd
            return [pscustomobject]@{
                StartUsedPercent = if ($null -ne $Evidence.PSObject.Properties['StartUsedPercent']) { [double]$Evidence.StartUsedPercent } elseif ($null -ne $StartWindow) { [double]$StartWindow.UsedPercent } else { $currentUsedPercent }
                CalibrationEndUsedPercent = if ($null -ne $Evidence.PSObject.Properties['CalibrationEndUsedPercent']) { [double]$Evidence.CalibrationEndUsedPercent } else { $currentUsedPercent }
                EndUsedPercent = $currentUsedPercent
                DeltaPercent = [double]$Evidence.EffectiveDeltaPercent
                EffectiveDeltaPercent = [double]$Evidence.EffectiveDeltaPercent
                PercentResolution = if ($null -ne $Evidence.PSObject.Properties['PercentResolution']) { [double]$Evidence.PercentResolution } else { [double](Get-TokenRaderWindowPercentResolution $EndWindow) }
                ResolutionAssumptionApplied = if ($null -ne $Evidence.PSObject.Properties['ResolutionAssumptionApplied']) { [bool]$Evidence.ResolutionAssumptionApplied } else { $false }
                HistoryLookbackApplied = if ($null -ne $Evidence.PSObject.Properties['HistoryLookbackApplied']) { [bool]$Evidence.HistoryLookbackApplied } else { $false }
                CalibrationStartObservedAt = if ($null -ne $Evidence.PSObject.Properties['StartObservedAt']) { $Evidence.StartObservedAt } else { $null }
                CalibrationEndObservedAt = if ($null -ne $Evidence.PSObject.Properties['EndObservedAt']) { $Evidence.EndObservedAt } else { $null }
                CurrentObservedAt = $evidenceCurrentAt
                TotalTokens = if ($null -ne $Evidence.PSObject.Properties['TotalTokens']) { [Int64]$Evidence.TotalTokens } else { 0L }
                UsedTokens = if ($null -ne $Evidence.PSObject.Properties['UsedTokens']) { [Int64]$Evidence.UsedTokens } else { 0L }
                RemainingTokens = if ($null -ne $Evidence.PSObject.Properties['RemainingTokens']) { [Int64]$Evidence.RemainingTokens } else { 0L }
                ObservedTokens = if ($null -ne $Evidence.PSObject.Properties['ObservedTokens']) { [Int64]$Evidence.ObservedTokens } else { 0L }
                EstimateSource = [string]$Evidence.EstimateSource
                CapacitySource = [string]$Evidence.CapacitySource
                ServiceTierComplete = if ($null -ne $Evidence.PSObject.Properties['ServiceTierComplete']) { [bool]$Evidence.ServiceTierComplete } else { $true }
                ModeEvidenceComplete = if ($null -ne $Evidence.PSObject.Properties['ModeEvidenceComplete']) { [bool]$Evidence.ModeEvidenceComplete } else { $true }
                ModeAssumptionApplied = if ($null -ne $Evidence.PSObject.Properties['ModeAssumptionApplied']) { [bool]$Evidence.ModeAssumptionApplied } else { $false }
                ManualServiceTierApplied = if ($null -ne $Evidence.PSObject.Properties['ManualServiceTierApplied']) { [bool]$Evidence.ManualServiceTierApplied } else { $false }
                QuotaEvidenceComplete = if ($null -ne $Evidence.PSObject.Properties['QuotaEvidenceComplete']) { [bool]$Evidence.QuotaEvidenceComplete } else { $true }
                ReferencePricingApplied = $null -ne $Evidence.PSObject.Properties['ReferencePricingApplied'] -and [bool]$Evidence.ReferencePricingApplied
                IdentityComplete = if ($null -ne $Evidence.PSObject.Properties['IdentityComplete']) { [bool]$Evidence.IdentityComplete } else { $false }
                IdentitySources = if ($null -ne $Evidence.PSObject.Properties['IdentitySources']) { @($Evidence.IdentitySources) } else { @() }
                UnidentifiedEvents = if ($null -ne $Evidence.PSObject.Properties['UnidentifiedEvents']) { [Int64]$Evidence.UnidentifiedEvents } else { 0L }
                EvidenceCost = [double]$Evidence.TotalCost
                EvidenceFirstCountedAt = if ($null -ne $Evidence.PSObject.Properties['FirstCountedAt']) { $Evidence.FirstCountedAt } else { $null }
                EvidenceLastCountedAt = if ($null -ne $Evidence.PSObject.Properties['LastCountedAt']) { $Evidence.LastCountedAt } else { $null }
                AverageUsdPerToken = if ($null -ne $Evidence.PSObject.Properties['AverageUsdPerToken']) { [double]$Evidence.AverageUsdPerToken } else { 0.0 }
                TotalUsd = $totalUsd
                UsedUsd = if ($null -ne $Evidence.PSObject.Properties['EstimatedUsedUsd']) { [double]$Evidence.EstimatedUsedUsd } else { $totalUsd * ($currentUsedPercent / 100.0) }
                RemainingUsd = if ($null -ne $Evidence.PSObject.Properties['EstimatedRemainingUsd']) { [double]$Evidence.EstimatedRemainingUsd } else { $totalUsd * ([Math]::Max(0.0, 100.0 - $currentUsedPercent) / 100.0) }
                WindowMinutes = [int]$EndWindow.WindowMinutes
                ResetsAt = $EndWindow.ResetsAt
                PlanType = $EndPlanType
                LimitId = if ($null -ne $Evidence.PSObject.Properties['LimitId']) { [string]$Evidence.LimitId } else { '' }
                AccountIdentity = if ($null -ne $Evidence.PSObject.Properties['AccountIdentity']) { [string]$Evidence.AccountIdentity } else { '' }
            }
        }
        if ($null -eq $StartWindow) { return $null }
        [double]$effectiveCost = $IntervalCost
        [bool]$effectiveCostComplete = $CostComplete
        if (-not $effectiveCostComplete -or $effectiveCost -le 0) { return $null }
        if (-not $StartPlanType.Equals($EndPlanType, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        if ([int]$StartWindow.WindowMinutes -ne [int]$EndWindow.WindowMinutes) { return $null }
        if ($null -eq $StartWindow.ResetsAt -or $null -eq $EndWindow.ResetsAt) { return $null }
        if ($null -ne $StartReferenceAt -and [DateTimeOffset]$StartWindow.ResetsAt -le [DateTimeOffset]$StartReferenceAt) { return $null }
        if ($null -ne $EndReferenceAt -and [DateTimeOffset]$EndWindow.ResetsAt -le [DateTimeOffset]$EndReferenceAt) { return $null }
        $startResetIdentity = if ($null -ne $StartWindow.PSObject.Properties['ResetIdentity']) { [string]$StartWindow.ResetIdentity } else {
            Get-TokenRaderResetIdentity -WindowMinutes ([int]$StartWindow.WindowMinutes) -ResetsAt $StartWindow.ResetsAt
        }
        $endResetIdentity = if ($null -ne $EndWindow.PSObject.Properties['ResetIdentity']) { [string]$EndWindow.ResetIdentity } else {
            Get-TokenRaderResetIdentity -WindowMinutes ([int]$EndWindow.WindowMinutes) -ResetsAt $EndWindow.ResetsAt
        }
        if ([string]::IsNullOrWhiteSpace($startResetIdentity) -or $startResetIdentity -ne $endResetIdentity) { return $null }
        if ($null -ne $StartWindow.PSObject.Properties['ObservedAt'] -and $null -ne $EndWindow.PSObject.Properties['ObservedAt'] -and
            [DateTimeOffset]$EndWindow.ObservedAt -lt [DateTimeOffset]$StartWindow.ObservedAt) { return $null }
        $deltaPercent = [double]$EndWindow.UsedPercent - [double]$StartWindow.UsedPercent
        if ($deltaPercent -lt -0.000000001) { return $null }
        if ([Math]::Abs($deltaPercent) -lt 0.000000001) { $deltaPercent = 0.0 }
        $percentResolution = [Math]::Min(
            [double](Get-TokenRaderWindowPercentResolution $StartWindow),
            [double](Get-TokenRaderWindowPercentResolution $EndWindow))
        $effectiveDeltaPercent = if ($deltaPercent -gt 0) { $deltaPercent } else { $percentResolution }
        if ($effectiveDeltaPercent -le 0) { return $null }
        $totalUsd = $effectiveCost / ($effectiveDeltaPercent / 100.0)
        [pscustomobject]@{
            StartUsedPercent = [double]$StartWindow.UsedPercent
            EndUsedPercent = [double]$EndWindow.UsedPercent
            DeltaPercent = $deltaPercent
            EffectiveDeltaPercent = $effectiveDeltaPercent
            PercentResolution = $percentResolution
            ResolutionAssumptionApplied = $deltaPercent -eq 0.0
            CalibrationStartObservedAt = if ($null -ne $StartWindow.PSObject.Properties['ObservedAt']) { $StartWindow.ObservedAt } else { $null }
            CalibrationEndObservedAt = if ($null -ne $EndWindow.PSObject.Properties['ObservedAt']) { $EndWindow.ObservedAt } else { $null }
            EvidenceCost = $effectiveCost
            EvidenceFirstCountedAt = if ($useQuotaEvidence -and $null -ne $Evidence) { $Evidence.FirstCountedAt } else { $null }
            EvidenceLastCountedAt = if ($useQuotaEvidence -and $null -ne $Evidence) { $Evidence.LastCountedAt } else { $null }
            TotalUsd = $totalUsd
            UsedUsd = $totalUsd * ([double]$EndWindow.UsedPercent / 100.0)
            RemainingUsd = $totalUsd * ([double]$EndWindow.RemainingPercent / 100.0)
            WindowMinutes = [int]$EndWindow.WindowMinutes
            ResetsAt = $EndWindow.ResetsAt
            PlanType = $EndPlanType
        }
    }

    function Get-WindowPlanType {
        param($RateLimits, $Window)
        if ($null -ne $Window -and $null -ne $Window.PSObject.Properties['PlanType'] -and
            -not [string]::IsNullOrWhiteSpace([string]$Window.PlanType)) { return [string]$Window.PlanType }
        if ($null -ne $RateLimits -and $null -ne $RateLimits.PSObject.Properties['PlanType']) { return [string]$RateLimits.PlanType }
        return ''
    }
    [pscustomobject]@{
        FiveHour = if ($null -ne $EndRateLimits -and ($useQuotaEvidence -or $null -ne $StartRateLimits)) {
            Get-WindowEstimate $(if ($null -ne $StartRateLimits) { $StartRateLimits.FiveHour } else { $null }) $EndRateLimits.FiveHour $(if ($null -ne $StartRateLimits) { Get-WindowPlanType $StartRateLimits $StartRateLimits.FiveHour } else { '' }) (Get-WindowPlanType $EndRateLimits $EndRateLimits.FiveHour) $(if ($useQuotaEvidence -and $null -ne $QuotaEvidence) { $QuotaEvidence.FiveHour } else { $null })
        } else { $null }
        Weekly = if ($null -ne $EndRateLimits -and ($useQuotaEvidence -or $null -ne $StartRateLimits)) {
            Get-WindowEstimate $(if ($null -ne $StartRateLimits) { $StartRateLimits.Weekly } else { $null }) $EndRateLimits.Weekly $(if ($null -ne $StartRateLimits) { Get-WindowPlanType $StartRateLimits $StartRateLimits.Weekly } else { '' }) (Get-WindowPlanType $EndRateLimits $EndRateLimits.Weekly) $(if ($useQuotaEvidence -and $null -ne $QuotaEvidence) { $QuotaEvidence.Weekly } else { $null })
        } else { $null }
    }
}

function Format-TokenRaderNumber {
    param([Int64]$Value)
    return $Value.ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
}

function Format-TokenRaderUsd {
    param([double]$Value)
    if ($Value -lt 0.0001) { return ('$' + $Value.ToString('0.000000')) }
    if ($Value -lt 1.0) { return ('$' + $Value.ToString('0.0000')) }
    return ('$' + $Value.ToString('N4'))
}

# ── SQLite 索引引擎（磁盘数据库，sub2api 式，内存恒定） ─────────────────

$script:TokenRaderIndex = $null

function Get-TokenRaderIndexerPath {
    return Join-Path $PSScriptRoot 'indexer\TokenRader.Indexer.dll'
}

function Get-TokenRaderIndexerDataDir {
    $dir = Join-Path $PSScriptRoot 'data\private\index'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-TokenRaderIndexerDbPath {
    # Tests may select another ignored data/private subdirectory so they never
    # overwrite a user's persistent index. Production always uses index.db.
    if (-not [string]::IsNullOrWhiteSpace($env:TOKEN_RADER_INDEX_DB)) {
        $candidate = [IO.Path]::GetFullPath($env:TOKEN_RADER_INDEX_DB)
        $normalizedCandidate = $candidate.Replace([IO.Path]::AltDirectorySeparatorChar, [IO.Path]::DirectorySeparatorChar)
        $privateSegment = [IO.Path]::DirectorySeparatorChar + 'data' + [IO.Path]::DirectorySeparatorChar + 'private' + [IO.Path]::DirectorySeparatorChar
        if ($normalizedCandidate.IndexOf($privateSegment, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw 'TOKEN_RADER_INDEX_DB 必须位于某个项目的 data/private 目录内。'
        }
        $candidateDir = Split-Path -Parent $candidate
        if (-not (Test-Path -LiteralPath $candidateDir)) { New-Item -ItemType Directory -Path $candidateDir -Force | Out-Null }
        return $candidate
    }
    return Join-Path (Get-TokenRaderIndexerDataDir) 'index.db'
}

<#
.SYNOPSIS
    加载 C# 和 SQLite DLL，返回是否成功。
#>
function Initialize-TokenRaderIndexer {
    $dllPath = Get-TokenRaderIndexerPath
    $sqlitePath = Join-Path $PSScriptRoot 'indexer\System.Data.SQLite.dll'
    if (-not (Test-Path -LiteralPath $dllPath) -or -not (Test-Path -LiteralPath $sqlitePath)) { return $false }
    try {
        Add-Type -Path $sqlitePath -ErrorAction Stop
        Add-Type -Path $dllPath -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Close-TokenRaderIndex {
    param([switch]$KeepWatcher)
    $index = $script:TokenRaderIndex
    if (-not $KeepWatcher -and $null -ne $index -and -not [string]::IsNullOrWhiteSpace([string]$index.SessionsRoot) -and
        $null -ne ('TokenRaderIndexer' -as [type])) {
        try { [TokenRaderIndexer]::StopWatcher([string]$index.SessionsRoot) } catch { }
    }
    if ($null -ne $index -and $null -ne $index.Connection) {
        try { $index.Connection.Close(); $index.Connection.Dispose() } catch { }
    }
    $script:TokenRaderIndex = $null
}

function Open-TokenRaderIndex {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)

    if (-not (Initialize-TokenRaderIndexer)) {
        throw 'C# Indexer DLL 不可用，请先运行 Build.ps1'
    }
    $canonicalRoot = [IO.Path]::GetFullPath($SessionsRoot).TrimEnd([char]'\', [char]'/')
    $existing = $script:TokenRaderIndex
    if ($null -ne $existing -and $null -ne $existing.Connection -and
        [string]$existing.SessionsRoot -eq $canonicalRoot) {
        return $existing
    }
    Close-TokenRaderIndex

    $dbPath = Get-TokenRaderIndexerDbPath
    $wasPresent = Test-Path -LiteralPath $dbPath
    $schemaLock = [TokenRaderIndexer]::AcquireFileLock(($dbPath + '.lock'), 10000)
    $conn = $null
    try {
        $conn = New-Object System.Data.SQLite.SQLiteConnection ('Data Source=' + $dbPath + ';Version=3;Default Timeout=30;')
        $conn.Open()
        $pragma = $conn.CreateCommand()
        try {
            # WAL lets readers retain a stable snapshot while another Radar
            # process commits an index batch; busy_timeout handles brief SQLite
            # lock hand-offs that occur before the explicit writer lock is held.
            $pragma.CommandText = 'PRAGMA busy_timeout=30000; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;'
            [void]$pragma.ExecuteNonQuery()
        } finally { $pragma.Dispose() }
        [TokenRaderIndexer]::CreateSchema($conn)
    } catch {
        if ($null -ne $conn) {
            try { $conn.Close(); $conn.Dispose() } catch { }
            $conn = $null
        }
        throw
    } finally {
        if ($null -ne $schemaLock) { $schemaLock.Dispose() }
    }
    try { [TokenRaderIndexer]::StartWatcher($canonicalRoot) } catch { }
    $metadata = [TokenRaderIndexer]::GetFileMetadata($conn)
    $catalogInitialized = [string][TokenRaderIndexer]::GetSetting($conn, 'catalog_initialized') -eq '1'
    $indexedRoot = [string][TokenRaderIndexer]::GetSetting($conn, 'sessions_root')
    $rootMatches = -not [string]::IsNullOrWhiteSpace($indexedRoot) -and
        $indexedRoot.Equals($canonicalRoot, [StringComparison]::OrdinalIgnoreCase)
    $script:TokenRaderIndex = [pscustomobject]@{
        DbPath = $dbPath
        Connection = $conn
        SessionsRoot = $canonicalRoot
        LastSync = $null
        LastFullReconcile = $null
        IsNew = (-not $wasPresent -or -not $catalogInitialized -or -not $rootMatches)
        CatalogInitialized = ($catalogInitialized -and $rootMatches)
        IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($conn)
        ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision($canonicalRoot)
        IndexedFileCount = [int]$metadata.Rows.Count
        LastImportedFiles = 0
        LastImportedRecords = 0
        LastFailedFiles = @()
        LastFailureMessages = @()
        SyncComplete = $true
        RootBackfilledRows = 0
    }
    return $script:TokenRaderIndex
}

function ConvertTo-TokenRaderMetadataMap {
    param([Parameter(Mandatory = $true)]$Table)
    $map = @{}
    foreach ($row in @($Table.Rows)) {
        $path = [string]$row['path']
        if (-not [string]::IsNullOrWhiteSpace($path)) { $map[$path.ToLowerInvariant()] = $row }
    }
    return $map
}

function Get-TokenRaderIndexRetentionCutoff {
    param([Parameter(Mandatory = $true)]$Connection)

    $raw = [TokenRaderIndexer]::GetSetting($Connection, 'retention_cutoff_ticks')
    if ([string]::IsNullOrWhiteSpace([string]$raw)) { return 0L }
    $cutoff = [Int64]0
    if ([Int64]::TryParse([string]$raw, [ref]$cutoff) -and $cutoff -gt 0) { return $cutoff }
    return 0L
}

function Get-TokenRaderCompleteJsonlOffset {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $FilePath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        $length = [Int64]$stream.Length
        if ($length -le 0) { return 0L }
        $bufferSize = 65536
        $end = $length
        while ($end -gt 0) {
            $start = [Math]::Max([Int64]0, $end - $bufferSize)
            $count = [int]($end - $start)
            $buffer = New-Object byte[] $count
            [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
            $read = $stream.Read($buffer, 0, $count)
            for ($i = $read - 1; $i -ge 0; $i--) {
                if ($buffer[$i] -eq 10) { return [Int64]($start + $i + 1) }
            }
            $end = $start
        }
        return 0L
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Sync-TokenRaderIndexFiles {
    param(
        [Parameter(Mandatory = $true)]$Index,
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [AllowNull()][string[]]$CandidateFiles,
        [switch]$FullReconcile,
        [hashtable]$ProgressState
    )

    $crossProcessLock = $null
    try {
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$Index.DbPath + '.lock'), 10000)
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '读取索引游标'
        $ProgressState.ProcessedFiles = 0
        $ProgressState.TotalFiles = 0
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $conn = $Index.Connection
    $candidateMetadataOnly = -not $FullReconcile -and $null -ne $CandidateFiles
    $metadataTable = $null
    if ($candidateMetadataOnly) {
        $metadataTable = [TokenRaderIndexer]::CaptureFileCursorTableForPaths($conn, [System.Collections.IEnumerable]@($CandidateFiles))
    } else { $metadataTable = [TokenRaderIndexer]::CaptureFileCursorTable($conn) }
    $known = ConvertTo-TokenRaderMetadataMap -Table $metadataTable
    $retentionCutoff = Get-TokenRaderIndexRetentionCutoff -Connection $conn
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '枚举日志'
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $files = if ($null -eq $CandidateFiles) {
        if (Test-Path -LiteralPath $SessionsRoot) {
            @(Get-ChildItem -LiteralPath $SessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue)
        } else { @() }
    } else {
        @($CandidateFiles | Select-Object -Unique | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath $_ -PathType Leaf)) {
                $item = Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue
                if ($null -ne $item -and $item.Extension -eq '.jsonl') { $item }
            }
        })
    }

    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '比较日志游标'
        $ProgressState.ProcessedFiles = 0
        $ProgressState.TotalFiles = @($files).Count
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $seen = @{}
    $relationshipBySession = @{}
    $storedRootBySession = @{}
    $hasRelationshipChanges = $false

    $workItems = New-Object System.Collections.ArrayList
    $catalogProcessed = 0
    foreach ($file in $files) {
        $catalogProcessed++
        if ($null -ne $ProgressState -and ($catalogProcessed -eq 1 -or $catalogProcessed % 25 -eq 0)) {
            $ProgressState.ProcessedFiles = $catalogProcessed
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }
        $canonical = [IO.Path]::GetFullPath($file.FullName)
        $key = $canonical.ToLowerInvariant()
        $seen[$key] = $true
        $knownRow = if ($known.ContainsKey($key)) { $known[$key] } else { $null }
        $unchanged = $null -ne $knownRow -and
            [Int64]$knownRow['length'] -eq [Int64]$file.Length -and
            [Int64]$knownRow['last_write_ticks'] -eq [Int64]$file.LastWriteTimeUtc.Ticks
        $hasRelationship = $null -ne $knownRow -and -not [string]::IsNullOrWhiteSpace([string]$knownRow['session_id'])
        if ($unchanged -and $hasRelationship) { continue }

        $sessionMetadata = Get-TokenRaderSessionMetadata -FilePath $canonical
        if (-not [string]::IsNullOrWhiteSpace([string]$sessionMetadata.SessionId)) {
            $relationshipBySession[([string]$sessionMetadata.SessionId).ToLowerInvariant()] = $sessionMetadata
        }
        $relationshipChanged = $null -eq $knownRow -or
            -not [string]::Equals([string]$knownRow['session_id'], [string]$sessionMetadata.SessionId, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$knownRow['parent_thread_id'], [string]$sessionMetadata.ParentThreadId, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$knownRow['forked_from_id'], [string]$sessionMetadata.ForkedFromId, [StringComparison]::OrdinalIgnoreCase)
        if ($relationshipChanged) { $hasRelationshipChanges = $true }
        [void]$workItems.Add([pscustomobject]@{
            File = $file
            Canonical = $canonical
            Key = $key
            KnownRow = $knownRow
            Metadata = $sessionMetadata
            Unchanged = $unchanged
            RelationshipChanged = $relationshipChanged
        })
    }
    if ($hasRelationshipChanges) {
        # A newly discovered parent/root can resolve rows that were genuinely
        # orphaned during the previous backfill pass.
        [TokenRaderIndexer]::SetSetting($conn, 'missing_model_backfill_version', '0')
        # Relationship traversal/backfill is only needed when a candidate adds
        # or changes task ancestry. Ordinary token appends reuse the already
        # resolved root from their cursor row and avoid walking the whole
        # catalog on every refresh.
        $relationshipTable = $metadataTable
        if ($candidateMetadataOnly) { $relationshipTable = [TokenRaderIndexer]::CaptureFileCursorTable($conn) }
        foreach ($row in @($relationshipTable.Rows)) {
            $sessionId = [string]$row['session_id']
            if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
            $sessionKey = $sessionId.ToLowerInvariant()
            if (-not $relationshipBySession.ContainsKey($sessionKey)) {
                $relationshipBySession[$sessionKey] = [pscustomobject]@{
                    SessionId = $sessionId
                    ParentThreadId = [string]$row['parent_thread_id']
                    ForkedFromId = [string]$row['forked_from_id']
                }
            }
            $storedRootBySession[$sessionKey] = [string]$row['root_session_id']
        }
    }
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '处理变化日志'
        $ProgressState.ProcessedFiles = 0
        $ProgressState.TotalFiles = $workItems.Count
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }

    $resolveRoot = {
        param($Metadata)
        $root = [string]$Metadata.SessionId
        $current = $Metadata
        $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        for ($depth = 0; $null -ne $current -and $depth -lt 64; $depth++) {
            $currentId = [string]$current.SessionId
            if (-not [string]::IsNullOrWhiteSpace($currentId) -and -not $visited.Add($currentId)) { break }
            $parent = if (-not [string]::IsNullOrWhiteSpace([string]$current.ParentThreadId)) {
                [string]$current.ParentThreadId
            } else { [string]$current.ForkedFromId }
            if ([string]::IsNullOrWhiteSpace($parent)) { break }
            $root = $parent
            $parentKey = $parent.ToLowerInvariant()
            if (-not $relationshipBySession.ContainsKey($parentKey)) { break }
            $current = $relationshipBySession[$parentKey]
            if (-not [string]::IsNullOrWhiteSpace([string]$current.SessionId)) { $root = [string]$current.SessionId }
        }
        if ([string]::IsNullOrWhiteSpace($root)) { $root = [string]$Metadata.SessionId }
        return $root
    }

    $importedFiles = 0
    $importedRecords = 0
    $changed = $false
    $nextRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($conn) + 1L
    $failedFiles = New-Object System.Collections.ArrayList
    $failureMessages = New-Object System.Collections.ArrayList
    $canonicalRoots = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    if ($hasRelationshipChanges) {
        foreach ($relationship in @($relationshipBySession.Values)) {
            $sessionId = [string]$relationship.SessionId
            if ([string]::IsNullOrWhiteSpace($sessionId)) { continue }
            $canonicalRoot = [string](& $resolveRoot $relationship)
            $sessionKey = $sessionId.ToLowerInvariant()
            if ($storedRootBySession.ContainsKey($sessionKey) -and
                -not [string]::IsNullOrWhiteSpace($canonicalRoot) -and
                -not [string]::Equals([string]$storedRootBySession[$sessionKey], $canonicalRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $canonicalRoots[$sessionId] = $canonicalRoot
            }
        }
    }
    $rootBackfilledRows = if ($canonicalRoots.Count -gt 0) {
        [int][TokenRaderIndexer]::BackfillSessionRoots($conn, $canonicalRoots, $nextRevision)
    } else { 0 }
    if ($rootBackfilledRows -gt 0) { $changed = $true }
    $workProcessed = 0
    foreach ($work in @($workItems)) {
        $workProcessed++
        if ($null -ne $ProgressState) {
            $ProgressState.ProcessedFiles = $workProcessed
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }
        $file = $work.File
        $canonical = [string]$work.Canonical
        $knownRow = $work.KnownRow
        $metadata = $work.Metadata
        $storedRoot = if ($null -ne $knownRow) { [string]$knownRow['root_session_id'] } else { '' }
        $rootSessionId = if (-not [bool]$work.RelationshipChanged -and -not [string]::IsNullOrWhiteSpace($storedRoot)) {
            $storedRoot
        } else { & $resolveRoot $metadata }
        $length = [Int64]$file.Length
        $lastWrite = [Int64]$file.LastWriteTimeUtc.Ticks
        $startOffset = if ($null -ne $knownRow) { [Int64]$knownRow['parsed_offset'] } else { 0L }
        $knownRetained = $null -ne $knownRow -and [int]$knownRow['content_retained'] -ne 0
        $catalogOnly = $retentionCutoff -gt 0 -and $lastWrite -lt $retentionCutoff -and -not $knownRetained
        if ($null -eq $knownRow -and $retentionCutoff -gt 0 -and $lastWrite -lt $retentionCutoff) { $catalogOnly = $true }

        try {
            $completeOffset = Get-TokenRaderCompleteJsonlOffset -FilePath $canonical
            if ($catalogOnly) {
                # Preserve only enough information to detect a later append.
                # This direct parameterized update intentionally keeps
                # content_retained=0; no token rows are reconstructed here.
                $cmd = $conn.CreateCommand()
                try {
                    $cmd.CommandText = 'INSERT OR REPLACE INTO file_metadata (path,length,last_write_ticks,parsed_offset,session_id,cwd,parent_thread_id,forked_from_id,content_retained,root_session_id) VALUES (@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,0,@p9)'
                    [void]$cmd.Parameters.AddWithValue('@p1', $canonical)
                    [void]$cmd.Parameters.AddWithValue('@p2', $length)
                    [void]$cmd.Parameters.AddWithValue('@p3', $lastWrite)
                    [void]$cmd.Parameters.AddWithValue('@p4', [Int64]$completeOffset)
                    [void]$cmd.Parameters.AddWithValue('@p5', [string]$metadata.SessionId)
                    [void]$cmd.Parameters.AddWithValue('@p6', [string]$metadata.Cwd)
                    [void]$cmd.Parameters.AddWithValue('@p7', [string]$metadata.ParentThreadId)
                    [void]$cmd.Parameters.AddWithValue('@p8', [string]$metadata.ForkedFromId)
                    [void]$cmd.Parameters.AddWithValue('@p9', [string]$rootSessionId)
                    [void]$cmd.ExecuteNonQuery()
                } finally { $cmd.Dispose() }
                $changed = $true
                continue
            }

            $knownSessionId = if ($null -ne $knownRow) { [string]$knownRow['session_id'] } else { '' }
            $requiresReplacement = $null -ne $knownRow -and (
                $length -lt $startOffset -or
                ($lastWrite -ne [Int64]$knownRow['last_write_ticks'] -and $length -le [Int64]$knownRow['length'])
            )
            if ($requiresReplacement) {
                if ([string]::IsNullOrWhiteSpace($knownSessionId)) { $knownSessionId = [string]$metadata.SessionId }
                [void][TokenRaderIndexer]::DeleteTokenRecordsBySessionId($conn, $knownSessionId)
                [void][TokenRaderIndexer]::DeleteToolRecordsBySourcePath($conn, $canonical)
                $startOffset = 0L
            }

            $count = if ($completeOffset -gt $startOffset) {
                $directParentId = if (-not [string]::IsNullOrWhiteSpace([string]$metadata.ParentThreadId)) {
                    [string]$metadata.ParentThreadId
                } else { [string]$metadata.ForkedFromId }
                [TokenRaderIndexer]::ImportFile($conn, $canonical, $startOffset, $completeOffset,
                    [string]$rootSessionId, $directParentId, $nextRevision)
            } else { 0 }
            $fresh = Get-Item -LiteralPath $canonical -ErrorAction Stop
            [TokenRaderIndexer]::UpdateFileMetadata(
                $conn, $canonical, [Int64]$fresh.Length, [Int64]$fresh.LastWriteTimeUtc.Ticks,
                [Int64]$completeOffset, [string]$metadata.SessionId, [string]$metadata.Cwd,
                [string]$metadata.ParentThreadId, [string]$metadata.ForkedFromId, [string]$rootSessionId)
            $importedFiles++
            $importedRecords += [int]$count
            $changed = $true
        } catch {
            # The watcher notification was already drained before this import.
            # Put the path back so a transient lock or replacement can never
            # silently disappear from the next synchronization attempt.
            [void]$failedFiles.Add($canonical)
            [void]$failureMessages.Add([string]$_.Exception.Message)
            [TokenRaderIndexer]::RequeueChangedPath($SessionsRoot, $canonical)
            continue
        }
    }

    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '完成索引同步'
        $ProgressState.ProcessedFiles = $ProgressState.TotalFiles
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $candidatePaths = @{}
    if ($null -ne $CandidateFiles) {
        foreach ($candidate in @($CandidateFiles | Select-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
            $canonical = [IO.Path]::GetFullPath([string]$candidate)
            $candidatePaths[$canonical.ToLowerInvariant()] = $canonical
        }
    }
    if ($FullReconcile) {
        foreach ($row in @($metadataTable.Rows)) {
            $path = [string]$row['path']
            $key = $path.ToLowerInvariant()
            if ($seen.ContainsKey($key) -or (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $sessionId = [string]$row['session_id']
            if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = Get-TokenRaderSessionIdFromPath -FilePath $path }
            [void][TokenRaderIndexer]::DeleteTokenRecordsBySessionId($conn, $sessionId)
            [void][TokenRaderIndexer]::DeleteToolRecordsBySourcePath($conn, $path)
            [TokenRaderIndexer]::RemoveFileMetadata($conn, $path)
            $changed = $true
        }
    } elseif ($null -ne $CandidateFiles) {
        foreach ($key in @($candidatePaths.Keys)) {
            $path = [string]$candidatePaths[$key]
            if ((Test-Path -LiteralPath $path -PathType Leaf) -or -not $known.ContainsKey($key)) { continue }
            $row = $known[$key]
            $sessionId = [string]$row['session_id']
            if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = Get-TokenRaderSessionIdFromPath -FilePath $path }
            [void][TokenRaderIndexer]::DeleteTokenRecordsBySessionId($conn, $sessionId)
            [void][TokenRaderIndexer]::DeleteToolRecordsBySourcePath($conn, $path)
            [TokenRaderIndexer]::RemoveFileMetadata($conn, $path)
            $changed = $true
        }
    }
    if ($FullReconcile) {
        $Index.LastFullReconcile = [DateTimeOffset]::Now
        [TokenRaderIndexer]::SetSetting($conn, 'catalog_initialized', '1')
        [TokenRaderIndexer]::SetSetting($conn, 'sessions_root', ([string]$Index.SessionsRoot))
        $Index.CatalogInitialized = $true
    }
    if ($changed) { $Index.IndexRevision = [Int64][TokenRaderIndexer]::IncrementIndexRevision($conn) }
    else { $Index.IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($conn) }
    $Index.ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision([string]$Index.SessionsRoot)
    $Index.LastSync = [DateTimeOffset]::Now
    $Index.IsNew = $false
    $Index.LastImportedFiles = $importedFiles
    $Index.LastImportedRecords = $importedRecords
    $Index.LastFailedFiles = @($failedFiles)
    $Index.LastFailureMessages = @($failureMessages)
    $Index.SyncComplete = $failedFiles.Count -eq 0
    $Index.RootBackfilledRows = $rootBackfilledRows
    $Index.IndexedFileCount = [int][TokenRaderIndexer]::GetFileCursorCount($conn)
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '同步完成'
        $ProgressState.ProcessedFiles = $ProgressState.TotalFiles
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    return $Index
    } catch {
        # Candidate watcher events may already have been drained before the
        # cross-process lock or SQLite operation failed. Requeue the complete
        # batch so a later refresh can retry it.
        if ($null -ne $CandidateFiles) {
            foreach ($candidate in @($CandidateFiles)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                    [TokenRaderIndexer]::RequeueChangedPath($SessionsRoot, [string]$candidate)
                }
            }
        }
        throw
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

<#
.SYNOPSIS
    构建索引：扫描所有 JSONL 文件，导入 SQLite 磁盘数据库。
.PARAMETER SessionsRoot
    Codex 会话日志根目录。
.PARAMETER Force
    强制重建（删除已有数据库）。
#>
function New-TokenRaderIndex {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [switch]$Force
    )

    $dbPath = Get-TokenRaderIndexerDbPath
    if ($Force) {
        $rebuildLock = [TokenRaderIndexer]::AcquireFileLock(($dbPath + '.lock'), 10000)
        try {
            Close-TokenRaderIndex
            foreach ($suffix in @('', '-wal', '-shm')) {
                $target = $dbPath + $suffix
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
            }
        } finally {
            if ($null -ne $rebuildLock) { $rebuildLock.Dispose() }
        }
    }
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $result = Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -FullReconcile
    $modelBackfill = [TokenRaderIndexer]::BackfillMissingTokenModels($result.Connection)
    $result.IndexRevision = [Int64]$modelBackfill.IndexRevision
    if (-not [bool]$modelBackfill.Completed) {
        $result.SyncComplete = $false
        $result.LastFailedFiles = @($result.LastFailedFiles) + @($modelBackfill.FailedSourcePaths)
        throw ('空模型索引回填有 {0} 个日志暂时无法校验；未将不完整索引视为成功。' -f [int]$modelBackfill.FailedFiles)
    }
    if (-not [bool]$result.SyncComplete) {
        throw ('索引构建有 {0} 个日志暂时无法读取；已保留待重试路径，未将不完整索引视为成功。' -f @($result.LastFailedFiles).Count)
    }
    return $result
}

<#
.SYNOPSIS
    增量同步：检查文件变化，只解析新增/变更部分。
#>
function Update-TokenRaderIndex {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [AllowNull()][string[]]$CandidateFiles,
        [switch]$FullReconcile,
        [switch]$AllowIncomplete,
        [hashtable]$ProgressState
    )

    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) {
        $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    }
    $watcherWasActive = [TokenRaderIndexer]::IsWatcherActive($SessionsRoot)
    if (-not $watcherWasActive) { [TokenRaderIndexer]::StartWatcher($SessionsRoot) }
    $result = if ($PSBoundParameters.ContainsKey('CandidateFiles')) {
        Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -CandidateFiles $CandidateFiles -ProgressState $ProgressState
    } elseif ($FullReconcile -or [bool]$index.IsNew -or (-not $watcherWasActive -and (Test-Path -LiteralPath $SessionsRoot)) -or
        [TokenRaderIndexer]::ConsumeWatcherOverflow($SessionsRoot)) {
        Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -FullReconcile -ProgressState $ProgressState
    } else {
        $changedPaths = @([TokenRaderIndexer]::DrainChangedPaths($SessionsRoot))
        if ($changedPaths.Count -gt 0) {
            Sync-TokenRaderIndexFiles -Index $index -SessionsRoot $SessionsRoot -CandidateFiles $changedPaths -ProgressState $ProgressState
        } else {
            $index.IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
            $index.ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot)
            $index.LastImportedFiles = 0
            $index.LastImportedRecords = 0
            $index.LastFailedFiles = @()
            $index.LastFailureMessages = @()
            $index.SyncComplete = $true
            $index.RootBackfilledRows = 0
            if ($null -ne $ProgressState) {
                $ProgressState.Stage = '同步完成'
                $ProgressState.ProcessedFiles = 0
                $ProgressState.TotalFiles = 0
                $ProgressState.LastProgressAt = [DateTimeOffset]::Now
            }
            $index
        }
    }
    $modelBackfill = [TokenRaderIndexer]::BackfillMissingTokenModels($result.Connection)
    $result.IndexRevision = [Int64]$modelBackfill.IndexRevision
    if (-not [bool]$modelBackfill.Completed) {
        $result.SyncComplete = $false
        $result.LastFailedFiles = @($result.LastFailedFiles) + @($modelBackfill.FailedSourcePaths)
        if (-not $AllowIncomplete) {
            throw ('空模型索引回填有 {0} 个日志暂时无法校验；未将不完整计价视为成功。' -f [int]$modelBackfill.FailedFiles)
        }
    }
    if (-not $AllowIncomplete -and -not [bool]$result.SyncComplete) {
        throw ('索引同步有 {0} 个日志暂时无法读取；路径已重新排队，请稍后重试。' -f @($result.LastFailedFiles).Count)
    }
    return $result
}

<#
.SYNOPSIS
    删除可重建的本地索引；不会修改 Codex 原始日志。
#>
function Clear-TokenRaderIndex {
    $dbPath = Get-TokenRaderIndexerDbPath
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(($dbPath + '.lock'), 10000)
    try {
        Close-TokenRaderIndex
        foreach ($suffix in @('', '-wal', '-shm')) {
            $target = $dbPath + $suffix
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
        }
        [GC]::Collect()
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

function Remove-TokenRaderIndexHistory {
    param([ValidateRange(1, 36500)][int]$Days = 30)

    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) {
        throw '本地索引尚未打开。'
    }
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$index.DbPath + '.lock'), 10000)
    try {
        $requestedCutoff = [DateTime]::UtcNow.AddDays(-$Days).Ticks
        $existingCutoff = Get-TokenRaderIndexRetentionCutoff -Connection $index.Connection
        $effectiveCutoff = [Math]::Max([Int64]$requestedCutoff, [Int64]$existingCutoff)
        $removed = [TokenRaderIndexer]::PurgeIndexBefore($index.Connection, $effectiveCutoff)
        [TokenRaderIndexer]::SetSetting($index.Connection, 'retention_cutoff_ticks', ([Int64]$effectiveCutoff).ToString([Globalization.CultureInfo]::InvariantCulture))
        if ([int]$removed -gt 0) { $index.IndexRevision = [Int64][TokenRaderIndexer]::IncrementIndexRevision($index.Connection) }
        else { $index.IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) }
        $index.LastSync = [DateTimeOffset]::Now
        $index.IndexedFileCount = [int]([TokenRaderIndexer]::GetFileMetadata($index.Connection).Rows.Count)
        [pscustomobject]@{
            Days = $Days
            CutoffUtc = [DateTime]::new([Int64]$effectiveCutoff, [DateTimeKind]::Utc)
            RemovedFiles = [int]$removed
            DbPath = [string]$index.DbPath
        }
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

function Get-TokenRaderIndex {
    return $script:TokenRaderIndex
}

function Get-TokenRaderIndexedFileMetadata {
    param(
        [int]$Days = 30,
        [int]$MaximumFiles = 0
    )
    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) { return $null }
    $cutoffTicks = if ($Days -gt 0) { [DateTime]::UtcNow.AddDays(-$Days).Ticks } else { 0L }
    $table = [TokenRaderIndexer]::QueryFileMetadata($index.Connection, [Int64]$cutoffTicks, [int][Math]::Max(0, $MaximumFiles))
    return ,$table
}

function ConvertFrom-TokenRaderIndexedFileRow {
    param([Parameter(Mandatory = $true)]$Row)
    $path = [string]$Row['path']
    $sessionId = if ($Row.Table.Columns.Contains('session_id')) { [string]$Row['session_id'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = Get-TokenRaderSessionIdFromPath -FilePath $path }
    $shortId = if ($sessionId.Length -gt 8) { $sessionId.Substring(0, 8) } else { $sessionId }
    $utc = [DateTime]::new([Int64]$Row['last_write_ticks'], [DateTimeKind]::Utc)
    $local = $utc.ToLocalTime()
    $length = [Int64]$Row['length']
    [pscustomobject]@{
        FilePath = $path
        SessionId = $sessionId
        ShortId = $shortId
        LastWriteTime = $local
        LastWriteTimeUtc = $utc
        Length = $length
        Cwd = if ($Row.Table.Columns.Contains('cwd')) { [string]$Row['cwd'] } else { '' }
        ParentThreadId = if ($Row.Table.Columns.Contains('parent_thread_id')) { [string]$Row['parent_thread_id'] } else { '' }
        ForkedFromId = if ($Row.Table.Columns.Contains('forked_from_id')) { [string]$Row['forked_from_id'] } else { '' }
        DisplayName = ('{0:MM-dd HH:mm}   {1}   {2}' -f $local, $shortId, (Format-TokenRaderFileSize $length))
    }
}

function Get-TokenRaderIndexedSessionFiles {
    param(
        [int]$Days = 30,
        [int]$MaximumFiles = 200
    )
    $table = Get-TokenRaderIndexedFileMetadata -Days $Days -MaximumFiles ([Math]::Max(1, $MaximumFiles))
    if ($null -eq $table) { return @() }
    $rows = foreach ($row in @($table.Rows)) { ConvertFrom-TokenRaderIndexedFileRow -Row $row }
    return @($rows)
}

function Get-TokenRaderIndexedProjects {
    param([int]$Days = 30)

    $table = Get-TokenRaderIndexedFileMetadata -Days $Days -MaximumFiles 0
    if ($null -eq $table) { return @() }
    $groups = @{}
    foreach ($row in @($table.Rows)) {
        $item = ConvertFrom-TokenRaderIndexedFileRow -Row $row
        $cwd = [string]$item.Cwd
        if ([string]::IsNullOrWhiteSpace($cwd)) { continue }
        try { $cwd = [IO.Path]::GetFullPath($cwd).TrimEnd([char]'\', [char]'/') } catch { $cwd = $cwd.TrimEnd([char]'\', [char]'/') }
        if ([string]::IsNullOrWhiteSpace($cwd)) { continue }
        $key = $cwd.ToLowerInvariant()
        if (-not $groups.ContainsKey($key)) {
            $name = [IO.Path]::GetFileName($cwd)
            if ([string]::IsNullOrWhiteSpace($name)) { $name = $cwd }
            $groups[$key] = [pscustomobject]@{
                ProjectPath = $cwd
                ProjectName = $name
                LastWriteTime = $item.LastWriteTime
                LastWriteTimeUtc = $item.LastWriteTimeUtc
                TotalBytes = [Int64]0
                Entries = New-Object System.Collections.ArrayList
            }
        }
        $group = $groups[$key]
        [void]$group.Entries.Add($item)
        $group.TotalBytes += [Int64]$item.Length
        if ($item.LastWriteTimeUtc -gt $group.LastWriteTimeUtc) {
            $group.LastWriteTime = $item.LastWriteTime
            $group.LastWriteTimeUtc = $item.LastWriteTimeUtc
        }
    }

    $projects = foreach ($group in $groups.Values) {
        $entries = @($group.Entries | Sort-Object FilePath)
        $paths = @($entries | ForEach-Object { [string]$_.FilePath })
        $signature = @($entries | ForEach-Object { '{0}|{1}|{2}' -f $_.FilePath, [Int64]$_.Length, $_.LastWriteTimeUtc.Ticks }) -join ';'
        [pscustomobject]@{
            ProjectPath = [string]$group.ProjectPath
            ProjectName = [string]$group.ProjectName
            SessionCount = $paths.Count
            LastWriteTime = $group.LastWriteTime
            LastWriteTimeUtc = $group.LastWriteTimeUtc
            TotalBytes = [Int64]$group.TotalBytes
            FilePaths = $paths
            Signature = $signature
            DisplayName = ('{0}  ·  {1} 个日志' -f [string]$group.ProjectName, $paths.Count)
        }
    }
    return @($projects | Sort-Object LastWriteTimeUtc -Descending)
}

<#
.SYNOPSIS
    从 SQLite 索引中查询 token 记录，返回 DataTable。
#>
function Get-TokenRaderIndexRecords {
    param(
        [string]$SessionId = '',
        [string]$StartTimestamp = '',
        [string]$EndTimestamp = ''
    )

    $index = $script:TokenRaderIndex
    if ($null -eq $index -or $null -eq $index.Connection) { return $null }

    $conn = $index.Connection
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
        return [TokenRaderIndexer]::QuerySessionSnapshot($conn, $SessionId)
    }
    if (-not [string]::IsNullOrWhiteSpace($StartTimestamp) -or -not [string]::IsNullOrWhiteSpace($EndTimestamp)) {
        $start = if ([string]::IsNullOrWhiteSpace($StartTimestamp)) { '0000-01-01' } else { $StartTimestamp }
        $end = if ([string]::IsNullOrWhiteSpace($EndTimestamp)) { '9999-12-31' } else { $EndTimestamp }
        return [TokenRaderIndexer]::QueryTimeRange($conn, $start, $end)
    }
    return $null
}

<#
.SYNOPSIS
    将 SQLite 查询结果行（DataRow）转换为 UI 可用的 pscustomobject 格式。
.PARAMETER Row
    DataRow，来自 Get-TokenRaderIndexRecords 返回的 DataTable。
#>
function ConvertFrom-TokenRaderIndexRecord {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [string]$FilePath = ''
    )

    $totalInput = [Int64]$Row['total_input']
    $totalCached = [Int64]$Row['total_cached']
    $totalOutput = [Int64]$Row['total_output']
    $totalUncached = $totalInput - $totalCached
    $totalTotal = $totalInput + $totalOutput
    $totalHitRate = if ($totalInput -gt 0) { ($totalCached * 100.0) / $totalInput } else { 0.0 }

    $callInput = [Int64]$Row['call_input']
    $callCached = [Int64]$Row['call_cached']
    $callOutput = [Int64]$Row['call_output']
    $callUncached = $callInput - $callCached
    $callTotal = $callInput + $callOutput
    $callHitRate = if ($callInput -gt 0) { ($callCached * 100.0) / $callInput } else { 0.0 }

    $timestamp = [DateTimeOffset]::MinValue
    try { $timestamp = [DateTimeOffset]::Parse([string]$Row['timestamp']).ToLocalTime() } catch { }
    $sourceFile = if ($Row.Table.Columns.Contains('source_path')) { [string]$Row['source_path'] } else { $FilePath }
    if ([string]::IsNullOrWhiteSpace($FilePath)) { $FilePath = $sourceFile }
    $planType = [string]$Row['plan_type']
    $readNullableInt64 = {
        param([string]$Name)
        if (-not $Row.Table.Columns.Contains($Name)) { return $null }
        $value = $Row[$Name]
        if ($null -eq $value -or [DBNull]::Value.Equals($value)) { return $null }
        return [Int64]$value
    }

    $fiveHour = $null
    $weekly = $null
    $fhUsed = $Row['five_hour_used']
    if ($null -ne $fhUsed -and -not [DBNull]::Value.Equals($fhUsed)) {
        $fiveHour = [pscustomobject]@{
            UsedPercent = [double]$fhUsed
            RemainingPercent = 100.0 - [double]$fhUsed
            WindowMinutes = [int]$Row['five_hour_window']
            ResetsAt = if ($null -ne $Row['five_hour_resets'] -and -not [DBNull]::Value.Equals($Row['five_hour_resets'])) { [DateTimeOffset]::FromUnixTimeSeconds([Int64]$Row['five_hour_resets']).ToLocalTime() } else { $null }
            ObservedAt = $timestamp
            SourceFile = $sourceFile
            PlanType = $planType
            LimitId = if ($Row.Table.Columns.Contains('rate_limit_id')) { [string]$Row['rate_limit_id'] } else { '' }
            ScopeConflict = $false
            ConflictDescription = ''
            ConflictPlans = @()
            LimitName = if ($Row.Table.Columns.Contains('rate_limit_name')) { [string]$Row['rate_limit_name'] } else { '' }
            UsedTokens = & $readNullableInt64 'five_hour_used_tokens'
            RemainingTokens = & $readNullableInt64 'five_hour_remaining_tokens'
            LimitTokens = & $readNullableInt64 'five_hour_limit_tokens'
            ResetIdentity = if ($null -ne $Row['five_hour_resets'] -and -not [DBNull]::Value.Equals($Row['five_hour_resets'])) { '300:' + [string][Int64]$Row['five_hour_resets'] } else { '' }
        }
        $fiveHour.ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes ([int]$fiveHour.WindowMinutes) -ResetsAt $fiveHour.ResetsAt
    }
    $wkUsed = $Row['weekly_used']
    if ($null -ne $wkUsed -and -not [DBNull]::Value.Equals($wkUsed)) {
        $weekly = [pscustomobject]@{
            UsedPercent = [double]$wkUsed
            RemainingPercent = 100.0 - [double]$wkUsed
            WindowMinutes = [int]$Row['weekly_window']
            ResetsAt = if ($null -ne $Row['weekly_resets'] -and -not [DBNull]::Value.Equals($Row['weekly_resets'])) { [DateTimeOffset]::FromUnixTimeSeconds([Int64]$Row['weekly_resets']).ToLocalTime() } else { $null }
            ObservedAt = $timestamp
            SourceFile = $sourceFile
            PlanType = $planType
            LimitId = if ($Row.Table.Columns.Contains('rate_limit_id')) { [string]$Row['rate_limit_id'] } else { '' }
            ScopeConflict = $false
            ConflictDescription = ''
            ConflictPlans = @()
            LimitName = if ($Row.Table.Columns.Contains('rate_limit_name')) { [string]$Row['rate_limit_name'] } else { '' }
            UsedTokens = & $readNullableInt64 'weekly_used_tokens'
            RemainingTokens = & $readNullableInt64 'weekly_remaining_tokens'
            LimitTokens = & $readNullableInt64 'weekly_limit_tokens'
            ResetIdentity = ''
        }
        $weekly.ResetIdentity = Get-TokenRaderResetIdentity -WindowMinutes ([int]$weekly.WindowMinutes) -ResetsAt $weekly.ResetsAt
    }

    $rateLimits = [pscustomobject]@{
        ObservedAt = $timestamp
        PlanType = $planType
        LimitId = if ($Row.Table.Columns.Contains('rate_limit_id')) { [string]$Row['rate_limit_id'] } else { '' }
        LimitName = if ($Row.Table.Columns.Contains('rate_limit_name')) { [string]$Row['rate_limit_name'] } else { '' }
        IndividualLimit = if ($Row.Table.Columns.Contains('rate_limit_individual') -and -not [DBNull]::Value.Equals($Row['rate_limit_individual'])) { [bool]([int]$Row['rate_limit_individual']) } else { $null }
        RateLimitReachedType = if ($Row.Table.Columns.Contains('rate_limit_reached_type')) { [string]$Row['rate_limit_reached_type'] } else { '' }
        SpendControlReached = if ($Row.Table.Columns.Contains('spend_control_reached') -and -not [DBNull]::Value.Equals($Row['spend_control_reached'])) { [bool]([int]$Row['spend_control_reached']) } else { $null }
        CreditsBalance = if ($Row.Table.Columns.Contains('credits_balance') -and -not [DBNull]::Value.Equals($Row['credits_balance'])) { [double]$Row['credits_balance'] } else { $null }
        CreditsHas = if ($Row.Table.Columns.Contains('credits_has') -and -not [DBNull]::Value.Equals($Row['credits_has'])) { [bool]([int]$Row['credits_has']) } else { $null }
        CreditsUnlimited = if ($Row.Table.Columns.Contains('credits_unlimited') -and -not [DBNull]::Value.Equals($Row['credits_unlimited'])) { [bool]([int]$Row['credits_unlimited']) } else { $null }
        ScopeConflict = $false
        ConflictDescription = ''
        ConflictPlans = @()
        FiveHour = $fiveHour
        Weekly = $weekly
    }

    $recordModel = [string]$Row['model']
    $recordIdentitySource = if ($Row.Table.Columns.Contains('identity_source')) { [string]$Row['identity_source'] } else { '' }
    [Int64]$recordLongThreshold = if ($Row.Table.Columns.Contains('long_context_threshold') -and -not [DBNull]::Value.Equals($Row['long_context_threshold'])) { [Int64]$Row['long_context_threshold'] } else { 0L }
    $recordLongSource = if ($Row.Table.Columns.Contains('long_context_source')) { [string]$Row['long_context_source'] } else { '' }
    if (@('pricing_threshold', 'no_threshold', 'unknown_model', 'missing_input') -notcontains $recordLongSource) {
        $recordLongSource = if ($callInput -le 0L) { 'missing_input' }
                            elseif ([string]::IsNullOrWhiteSpace($recordModel)) { 'unknown_model' }
                            elseif ($recordLongThreshold -gt 0L) { 'pricing_threshold' }
                            else { 'no_threshold' }
    }

    [pscustomobject]@{
        FilePath = $FilePath
        Timestamp = $timestamp
        Model = $recordModel
        ModelSource = if ($Row.Table.Columns.Contains('model_source')) { [string]$Row['model_source'] } else { '' }
        TurnId = if ($Row.Table.Columns.Contains('turn_id')) { [string]$Row['turn_id'] } else { '' }
        RequestId = if ($Row.Table.Columns.Contains('request_id')) { [string]$Row['request_id'] } else { '' }
        ResponseId = if ($Row.Table.Columns.Contains('response_id')) { [string]$Row['response_id'] } else { '' }
        IdentitySource = if ($Row.Table.Columns.Contains('identity_source')) { [string]$Row['identity_source'] } else { '' }
        ServiceTier = if ($Row.Table.Columns.Contains('service_tier')) { ConvertTo-TokenRaderServiceTier ([string]$Row['service_tier']) } else { '' }
        ServiceTierSource = if ($Row.Table.Columns.Contains('service_tier_source')) { [string]$Row['service_tier_source'] } else { '' }
        ReasoningEffort = if ($Row.Table.Columns.Contains('reasoning_effort')) { [string]$Row['reasoning_effort'] } else { '' }
        ModelContextWindow = if ($Row.Table.Columns.Contains('model_context_window') -and -not [DBNull]::Value.Equals($Row['model_context_window'])) { [Int64]$Row['model_context_window'] } else { $null }
        LongContextThreshold = if ($recordLongThreshold -gt 0L) { $recordLongThreshold } else { $null }
        LongContextApplied = if ($Row.Table.Columns.Contains('long_context_applied')) { [bool]([int]$Row['long_context_applied']) } else { $false }
        LongContextSource = $recordLongSource
        RequestInputObservable = -not ($recordIdentitySource -ieq 'missing_last')
        LongContextPricingUncertain = ($recordIdentitySource -ieq 'missing_last') -and $recordLongThreshold -gt 0L -and $callInput -gt $recordLongThreshold
        CacheCreationTokens = if ($Row.Table.Columns.Contains('cache_creation_tokens')) { [Int64]$Row['cache_creation_tokens'] } else { 0L }
        CacheWriteObservable = if ($Row.Table.Columns.Contains('cache_write_observable')) { [bool]([int]$Row['cache_write_observable']) } else { $false }
        PlanType = [string]$Row['plan_type']
        RateLimits = $rateLimits
        Task = [pscustomobject]@{
            Input = $totalInput
            Cached = $totalCached
            Uncached = $totalUncached
            Output = $totalOutput
            ReasoningOutput = [Int64]$Row['total_reasoning']
            Total = $totalTotal
            CacheHitRate = $totalHitRate
        }
        Call = [pscustomobject]@{
            Input = $callInput
            Cached = $callCached
            Uncached = $callUncached
            Output = $callOutput
            ReasoningOutput = [Int64]$Row['call_reasoning']
            Total = $callTotal
            CacheHitRate = $callHitRate
        }
        ContextWindow = if ($Row.Table.Columns.Contains('model_context_window') -and -not [DBNull]::Value.Equals($Row['model_context_window'])) { [Int64]$Row['model_context_window'] } else { [Int64]0 }
        TailLinesRead = 0
        TokenRecordIndex = 0
        RecordId = if ($Row.Table.Columns.Contains('id')) { [Int64]$Row['id'] } else { 0L }
        SessionId = if ($Row.Table.Columns.Contains('session_id')) { [string]$Row['session_id'] } else { '' }
        RootSessionId = if ($Row.Table.Columns.Contains('root_session_id')) { [string]$Row['root_session_id'] } else { '' }
        SourceOffsetEnd = if ($Row.Table.Columns.Contains('source_offset_end')) { [Int64]$Row['source_offset_end'] } else { 0L }
        UsageFingerprint = if ($Row.Table.Columns.Contains('fingerprint')) { [string]$Row['fingerprint'] } else { '' }
        IndexRevision = if ($Row.Table.Columns.Contains('index_revision')) { [Int64]$Row['index_revision'] } else { 0L }
    }
}

function ConvertTo-TokenRaderOffsetMap {
    param($Value)
    $map = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    if ($null -eq $Value) { return $map }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            try { $map[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$key))] = [Int64]$Value[$key] } catch { }
        }
    } elseif ($null -ne $Value.PSObject) {
        foreach ($property in @($Value.PSObject.Properties)) {
            try { $map[(ConvertTo-TokenRaderCanonicalPath -Path ([string]$property.Name))] = [Int64]$property.Value } catch { }
        }
    }
    return $map
}

function Get-TokenRaderCursorOffsets {
    param([Parameter(Mandatory = $true)]$Connection)
    return ,([TokenRaderIndexer]::CaptureFileCursorOffsets($Connection))
}

function ConvertFrom-TokenRaderRateLimitRows {
    param($Table)
    if ($null -eq $Table -or $Table.Rows.Count -eq 0) { return $null }
    $candidates = New-Object System.Collections.ArrayList
    foreach ($row in @($Table.Rows)) {
        $record = ConvertFrom-TokenRaderIndexRecord -Row $row
        $rowId = if ($Table.Columns.Contains('id') -and $row['id'] -isnot [DBNull]) { [long]$row['id'] } else { 0L }
        if ($null -ne $record.RateLimits.FiveHour) {
            [void]$candidates.Add([pscustomobject]@{
                WindowKind = 'FiveHour'; Window = $record.RateLimits.FiveHour
                Metadata = $record.RateLimits; RecordId = $rowId
            })
        }
        if ($null -ne $record.RateLimits.Weekly) {
            [void]$candidates.Add([pscustomobject]@{
                WindowKind = 'Weekly'; Window = $record.RateLimits.Weekly
                Metadata = $record.RateLimits; RecordId = $rowId
            })
        }
    }
    return ConvertFrom-TokenRaderRateLimitCandidates -Candidates @($candidates)
}

function Get-TokenRaderIndexedRateLimitsAtOffsets {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)]$EndOffsets
    )
    $ends = ConvertTo-TokenRaderOffsetMap -Value $EndOffsets
    $starts = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ends.Keys)) { $starts[$path] = 0L }
    if ($ends.Count -eq 0) { return $null }
    $table = [TokenRaderIndexer]::QueryLatestRateLimitsByOffsets($Connection, $starts, $ends)
    return ConvertFrom-TokenRaderRateLimitRows -Table $table
}

function Get-TokenRaderIndexedLatestRateLimits {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $offsets = Get-TokenRaderCursorOffsets -Connection $index.Connection
    return Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $index.Connection -EndOffsets $offsets
}

function GetIndexRevision {
    param([string]$SessionsRoot = '')
    $index = $script:TokenRaderIndex
    if (($null -eq $index -or $null -eq $index.Connection) -and -not [string]::IsNullOrWhiteSpace($SessionsRoot)) {
        $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    }
    if ($null -eq $index -or $null -eq $index.Connection) { return 0L }
    $index.IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
    return [Int64]$index.IndexRevision
}

function Get-TokenRaderChangeRevision {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)
    if ($null -eq ('TokenRaderIndexer' -as [type])) { return 0L }
    return [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot)
}

function Sync-TokenRaderMeasurementBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [hashtable]$ProgressState = $null,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 25
    )

    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    $stableCatalogPasses = 0
    $attempt = 0
    $totalImportedFiles = 0
    $totalImportedRecords = 0
    $totalRootBackfills = 0
    $lastSyncError = ''
    do {
        $attempt++
        if ($null -ne $ProgressState) {
            $ProgressState.Stage = '核对全部日志边界'
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }

        # Compare every lightweight cursor in compiled code on every pass and
        # merge the watcher queue before import. A subsequent catalog with no
        # changed path defines the frozen boundary without depending on watcher
        # delivery latency or processing the same notification twice.
        $openIndex = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
        $changedFiles = @()
        $catalogChangedFiles = @()
        $indexWasNew = [bool]$openIndex.IsNew
        $revisionBeforePass = [Int64][TokenRaderIndexer]::GetIndexRevision($openIndex.Connection)
        if (-not $indexWasNew) {
            $catalogChangedFiles = @([TokenRaderIndexer]::FindChangedFiles($openIndex.Connection, $SessionsRoot))
            $changedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($path in @($catalogChangedFiles)) { [void]$changedSet.Add([string]$path) }
            foreach ($path in @([TokenRaderIndexer]::DrainChangedPaths($SessionsRoot))) { [void]$changedSet.Add([string]$path) }
            $changedFiles = @($changedSet)
        }
        if ($null -ne $ProgressState) {
            $ProgressState.Stage = '同步边界变化日志'
            $ProgressState.TotalFiles = $changedFiles.Count
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }
        try {
            $index = if ($indexWasNew) {
                Update-TokenRaderIndex -SessionsRoot $SessionsRoot -FullReconcile -AllowIncomplete -ProgressState $ProgressState
            } elseif ($changedFiles.Count -gt 0) {
                Update-TokenRaderIndex -SessionsRoot $SessionsRoot -CandidateFiles $changedFiles -AllowIncomplete -ProgressState $ProgressState
            } else {
                Update-TokenRaderIndex -SessionsRoot $SessionsRoot -AllowIncomplete -ProgressState $ProgressState
            }
        } catch {
            # A competing Radar process, file replacement, or brief SQLite
            # hand-off can fail before a per-file incomplete result exists.
            # Sync-TokenRaderIndexFiles has already requeued the candidates;
            # keep retrying within the same bounded boundary capture.
            $lastSyncError = [string]$_.Exception.Message
            $stableCatalogPasses = 0
            if ($null -ne $ProgressState) {
                $ProgressState.Stage = '等待并发索引写入完成后重试'
                $ProgressState.LastProgressAt = [DateTimeOffset]::Now
            }
            if ([DateTimeOffset]::Now -ge $deadline) { break }
            Start-Sleep -Milliseconds ([Math]::Min(500, 50 + ($attempt * 25)))
            continue
        }
        $totalImportedFiles += [int]$index.LastImportedFiles
        $totalImportedRecords += [int]$index.LastImportedRecords
        $totalRootBackfills += [int]$index.RootBackfilledRows
        $failedCount = @($index.LastFailedFiles).Count
        if ($failedCount -gt 0) {
            $stableCatalogPasses = 0
            if ($null -ne $ProgressState) {
                $ProgressState.Stage = ('重试 {0} 个暂时不可读日志' -f $failedCount)
                $ProgressState.LastProgressAt = [DateTimeOffset]::Now
            }
            if ([DateTimeOffset]::Now -ge $deadline) { break }
            Start-Sleep -Milliseconds ([Math]::Min(500, 50 + ($attempt * 25)))
            continue
        }

        # A late duplicate watcher notification can name a file that the
        # previous pass already imported. It is still verified above, but it
        # must not force an unnecessary third catalog scan. Only a real catalog
        # difference or an actual index revision advance counts as new work.
        $didWork = $indexWasNew -or $catalogChangedFiles.Count -gt 0 -or
            [Int64]$index.IndexRevision -gt $revisionBeforePass -or
            [int]$index.LastImportedFiles -gt 0 -or [int]$index.RootBackfilledRows -gt 0
        if ($didWork) {
            $stableCatalogPasses = 0
        } else {
            $stableCatalogPasses++
        }
        if ($stableCatalogPasses -ge 1) {
            $index.LastImportedFiles = $totalImportedFiles
            $index.LastImportedRecords = $totalImportedRecords
            $index.RootBackfilledRows = $totalRootBackfills
            if ($null -ne $ProgressState) {
                $ProgressState.Stage = '日志边界已稳定'
                $ProgressState.LastProgressAt = [DateTimeOffset]::Now
            }
            return $index
        }
    } while ([DateTimeOffset]::Now -lt $deadline)

    $remaining = if ($null -ne $index) { @($index.LastFailedFiles).Count } else { 0 }
    $detail = if ([string]::IsNullOrWhiteSpace($lastSyncError)) { '' } else { ' 最近错误：' + $lastSyncError }
    throw ('无法在 {0} 秒内获得完整且稳定的日志边界（仍有 {1} 个日志待同步）；未冻结不完整结果。{2}' -f $TimeoutSeconds, $remaining, $detail)
}

function CaptureMeasurementBaseline {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        $PricingDocument = $null,
        [string]$AccountIdentity = ''
    )
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $gate = [TokenRaderIndexer]::AcquireIndexGate($SessionsRoot)
    try {
        $index = Sync-TokenRaderMeasurementBoundary -SessionsRoot $SessionsRoot
        $startOffsets = Get-TokenRaderCursorOffsets -Connection $index.Connection
        $startRateLimits = Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $index.Connection -EndOffsets $startOffsets
        $files = foreach ($path in @($startOffsets.Keys)) {
            [pscustomobject]@{
                FilePath = [string]$path
                Length = [Int64]$startOffsets[$path]
                LastWriteTimeUtc = [DateTime]::MinValue
                BaselineLoaded = $false
                BaselineTask = $null
                BaselineModel = ''
            }
        }
        # The real timer starts only after synchronization and both snapshots
        # are frozen. Calls generated during Starting are filtered by time.
        $startedAt = [DateTimeOffset]::Now
        [pscustomobject]@{
            StartedAt = $startedAt
            SessionsRoot = [string]$index.SessionsRoot
            Files = @($files)
            StartOffsets = $startOffsets
            RateLimits = $startRateLimits
            StartRateLimits = $startRateLimits
            AccountIdentity = $AccountIdentity
            PlanType = if ($null -ne $startRateLimits) { [string]$startRateLimits.PlanType } else { '' }
            IndexRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
            ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot)
        }
    } finally {
        $gate.Dispose()
    }
}

function CaptureMeasurementEnd {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [switch]$IncludeRateLimits,
        [hashtable]$ProgressState
    )
    $sessionsRoot = [string]$Baseline.SessionsRoot
    $index = Open-TokenRaderIndex -SessionsRoot $sessionsRoot
    $gate = [TokenRaderIndexer]::AcquireIndexGate($sessionsRoot)
    try {
        $index = Sync-TokenRaderMeasurementBoundary -SessionsRoot $sessionsRoot -ProgressState $ProgressState
        $endOffsets = Get-TokenRaderCursorOffsets -Connection $index.Connection
        # The UI only needs immutable offsets/revision to finish Stopping.
        # Quota lookup is intentionally deferred to interval settlement, where
        # it queries these same frozen offsets and cannot see later appends.
        $endRateLimits = if ($IncludeRateLimits) {
            Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $index.Connection -EndOffsets $endOffsets
        } else { $null }
        [pscustomobject]@{
            EndedAt = [DateTimeOffset]::Now
            EndOffsets = $endOffsets
            EndRateLimits = $endRateLimits
            EndRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
            ChangeRevision = [Int64][TokenRaderIndexer]::GetChangeRevision($sessionsRoot)
        }
    } finally {
        $gate.Dispose()
    }
}

function QueryIntervalRecords {
    param(
        [Parameter(Mandatory = $true)]$StartOffsets,
        [Parameter(Mandatory = $true)]$EndOffsets,
        [string]$SessionsRoot = ''
    )
    $index = $script:TokenRaderIndex
    if (($null -eq $index -or $null -eq $index.Connection) -and -not [string]::IsNullOrWhiteSpace($SessionsRoot)) {
        $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    }
    if ($null -eq $index -or $null -eq $index.Connection) { return $null }
    $startsInput = ConvertTo-TokenRaderOffsetMap -Value $StartOffsets
    $ends = ConvertTo-TokenRaderOffsetMap -Value $EndOffsets
    $starts = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($ends.Keys)) {
        $starts[$path] = if ($startsInput.ContainsKey($path)) { [Int64]$startsInput[$path] } else { 0L }
    }
    return ,([TokenRaderIndexer]::QueryIntervalRecords($index.Connection, $starts, $ends))
}

function ConvertFrom-TokenRaderPricedAggregate {
    param(
        [Parameter(Mandatory = $true)]$Aggregate,
        [Parameter(Mandatory = $true)]$PricingDocument
    )
    $unknownModels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    [double]$inputCost = 0
    [double]$cachedCost = 0
    [double]$outputCost = 0
    [double]$cacheCreationCost = 0
    [double]$longContextExtraCost = 0
    [Int64]$standardContextEvents = 0
    [Int64]$longContextEvents = 0
    [Int64]$standardContextInput = 0
    [Int64]$longContextInput = 0
    [Int64]$longContextOutput = 0
    $cacheWriteObservable = $true
    $priceCache = @{}
    [bool]$serviceTierComplete = $true
    [bool]$modeEvidenceComplete = $true
    [bool]$modeAssumptionApplied = $false
    $items = foreach ($bucket in @($Aggregate.Buckets)) {
        $bucketObservable = $null -ne $bucket.PSObject.Properties['CacheWriteObservable'] -and [bool]$bucket.CacheWriteObservable
        if (-not $bucketObservable) { $cacheWriteObservable = $false }
        $bucketUsage = New-TokenRaderUsage -InputTokens $bucket.Input -CachedTokens $bucket.Cached -OutputTokens $bucket.Output -ReasoningOutputTokens $bucket.Reasoning
        $model = [string]$bucket.Model
        $tier = if ($null -ne $bucket.PSObject.Properties['ServiceTier']) { [string]$bucket.ServiceTier } else { '' }
        # The base price is independent of the selected mode, but include the
        # transient confirmation in the local key so a caller cannot
        # accidentally reuse a result from a different measurement overlay.
        $manualChoice = Get-TokenRaderManualServiceTier -PricingDocument $PricingDocument -Model $model
        $priceCacheKey = $model.ToLowerInvariant() + '|' + $manualChoice
        if (-not $priceCache.ContainsKey($priceCacheKey)) { $priceCache[$priceCacheKey] = Resolve-TokenRaderPrice -Model $model -PricingDocument $PricingDocument }
        $costArgs = @{
            Usage = $bucketUsage; Model = $model; PricingDocument = $PricingDocument
            ResolvedPrice = $priceCache[$priceCacheKey]; ServiceTier = $tier; Scope = 'call'
            LongContextApplied = [bool]$bucket.LongContext; CacheWriteObservable = $bucketObservable
            RequestInputObservable = if ($null -ne $bucket.PSObject.Properties['RequestInputObservable']) { [bool]$bucket.RequestInputObservable } else { $true }
            LongContextPricingUncertain = if ($null -ne $bucket.PSObject.Properties['LongContextPricingUncertain']) { [bool]$bucket.LongContextPricingUncertain } else { $null }
            CacheCreationTokens = $(if ($null -ne $bucket.PSObject.Properties['CacheCreationTokens']) { [Int64]$bucket.CacheCreationTokens } else { 0L })
            ModelContextWindow = $(if ($null -ne $bucket.PSObject.Properties['ModelContextWindow']) { [Int64]$bucket.ModelContextWindow } else { 0L })
        }
        if ($null -ne $bucket.PSObject.Properties['ServiceTierSource']) {
            $costArgs.ServiceTierSource = [string]$bucket.ServiceTierSource
        }
        if ($null -ne $bucket.PSObject.Properties['ServiceTierEvidenceComplete']) {
            $costArgs.ServiceTierEvidenceComplete = [bool]$bucket.ServiceTierEvidenceComplete
        } elseif ($null -ne $bucket.PSObject.Properties['ModeEvidenceComplete']) {
            $costArgs.ServiceTierEvidenceComplete = [bool]$bucket.ModeEvidenceComplete
        }
        $cost = Get-TokenRaderCost @costArgs
        $itemTier = [string]$cost.ServiceTier
        $itemTierComplete = $null -ne $cost.PSObject.Properties['ServiceTierComplete'] -and [bool]$cost.ServiceTierComplete
        $itemModeComplete = $null -ne $cost.PSObject.Properties['ModeEvidenceComplete'] -and [bool]$cost.ModeEvidenceComplete
        $itemAssumption = $null -ne $cost.PSObject.Properties['ModeAssumptionApplied'] -and [bool]$cost.ModeAssumptionApplied
        if (-not $itemTierComplete) { $serviceTierComplete = $false }
        if (-not $itemModeComplete) { $modeEvidenceComplete = $false }
        if ($itemAssumption) { $modeAssumptionApplied = $true }
        if ($null -ne $bucket.PSObject.Properties['ServiceTierSource'] -and
            -not [string]::IsNullOrWhiteSpace([string]$bucket.ServiceTierSource) -and
            -not $itemAssumption -and $itemTier -ne '') {
            # Preserve the strongest source carried by the compiled aggregate
            # (response/service_tier/turn_context) for the visible summary.
            $cost.ServiceTierSource = [string]$bucket.ServiceTierSource
        }
        if ($cost.Known) {
            $inputCost += [double]$cost.InputCost
            $cachedCost += [double]$cost.CachedCost
            $outputCost += [double]$cost.OutputCost
            $cacheCreationCost += [double]$cost.CacheCreationCost
            if ([bool]$cost.LongContextApplied) {
                $longContextEvents += [Int64]$bucket.Events
                $longContextInput += [Int64]$bucketUsage.Input
                $longContextOutput += [Int64]$bucketUsage.Output
                $shortCost = ([double]$cost.InputCost + [double]$cost.CachedCost) / [double]$cost.InputMultiplier + [double]$cost.OutputCost / [double]$cost.OutputMultiplier
                $longContextExtraCost += [double]$cost.TotalCost - $shortCost
            } else {
                $standardContextEvents += [Int64]$bucket.Events
                $standardContextInput += [Int64]$bucketUsage.Input
            }
        } else {
            [void]$unknownModels.Add($(if ([string]::IsNullOrWhiteSpace($model)) { '未知模型' } else { $model }))
        }
        [pscustomobject]@{
            Model = $model
            ServiceTier = $itemTier
            ServiceTierKnown = [bool]$cost.ServiceTierKnown
            ServiceTierComplete = $itemTierComplete
            ModeEvidenceComplete = $itemModeComplete
            ModeAssumptionApplied = $itemAssumption
            ManualServiceTierApplied = $itemAssumption
            ServiceTierSource = if ($itemAssumption) { 'manual_confirmation' } elseif ($itemTier -eq '') { [string]$cost.ServiceTierSource } elseif ($null -ne $bucket.PSObject.Properties['ServiceTierSource'] -and -not [string]::IsNullOrWhiteSpace([string]$bucket.ServiceTierSource)) { [string]$bucket.ServiceTierSource } else { [string]$cost.ServiceTierSource }
            LongContext = [bool]$bucket.LongContext
            RequestInputObservable = if ($null -ne $bucket.PSObject.Properties['RequestInputObservable']) { [bool]$bucket.RequestInputObservable } else { $true }
            LongContextPricingUncertain = if ($null -ne $bucket.PSObject.Properties['LongContextPricingUncertain']) { [bool]$bucket.LongContextPricingUncertain } else { $false }
            Usage = $bucketUsage
            Events = [Int64]$bucket.Events
            ModelContextWindow = $cost.ModelContextWindow
            LongContextThreshold = $cost.LongContextThreshold
            LongContextSource = $cost.LongContextSource
            CacheWriteObservable = $bucketObservable
            Cost = $cost
        }
    }
    $models = @($Aggregate.Models)
    $usage = New-TokenRaderUsage -InputTokens $Aggregate.TotalInput -CachedTokens $Aggregate.TotalCached -OutputTokens $Aggregate.TotalOutput -ReasoningOutputTokens $Aggregate.TotalReasoning
    [pscustomobject]@{
        Usage = $usage
        Models = $models
        ModelDisplay = if ($models.Count -eq 0) { '等待模型调用' } elseif ($models.Count -eq 1) { $models[0] } else { '{0} 个模型' -f $models.Count }
        Items = @($items)
        InputCost = $inputCost
        CachedCost = $cachedCost
        OutputCost = $outputCost
        CacheCreationCost = $cacheCreationCost
        TotalCost = $inputCost + $cachedCost + $outputCost
        PricingComplete = $unknownModels.Count -eq 0
        CostComplete = $unknownModels.Count -eq 0
        ServiceTierComplete = $serviceTierComplete
        ModeEvidenceComplete = $modeEvidenceComplete
        ModeAssumptionApplied = $modeAssumptionApplied
        ManualServiceTierApplied = $modeAssumptionApplied
        # Strict quota evidence may use an explicit per-model confirmation as
        # an assumption, but an unconfirmed/missing tier must not qualify.
        QuotaEvidenceComplete = $unknownModels.Count -eq 0 -and $serviceTierComplete -and
            ($modeEvidenceComplete -or $modeAssumptionApplied)
        UnknownModels = @($unknownModels | Sort-Object)
        StandardContextEvents = $standardContextEvents
        LongContextEvents = $longContextEvents
        StandardContextInput = $standardContextInput
        LongContextInput = $longContextInput
        LongContextOutput = $longContextOutput
        LongContextExtraCost = $longContextExtraCost
        CacheWriteObservable = $cacheWriteObservable
        CostCoverage = if ($cacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
    }
}

function Set-TokenRaderQuotaDiagnostic {
    param([hashtable]$State, [string]$ReasonCode, [string]$Message, [string]$Status = 'unavailable')
    if ($null -eq $State) { return }
    $State.Status=$Status; $State.ReasonCode=$ReasonCode; $State.Message=$Message; $State.Retained=$false
}

function Get-TokenRaderQuotaWindowEvidence {
    param(
        $StartWindow,
        $EndWindow,
        $MainLastCountedAt,
        [Parameter(Mandatory = $true)][ValidateSet('FiveHour', 'Weekly')][string]$WindowKind,
        [string]$RateLimitId = '',
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)]$EndOffsets,
        [Parameter(Mandatory = $true)]$Thresholds,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [Parameter(Mandatory = $true)][Threading.CancellationToken]$CancellationToken,
        [hashtable]$ProgressState,
        [hashtable]$Cache,
        [hashtable]$DiagnosticState,
        [string]$AccountIdentity = '',
        $QuotaNotBefore = $null
    )
    # Dollar capacity is calibrated from the API-equivalent cost that occurred
    # between two quota snapshots and the *actual percentage increase* between
    # those same snapshots. It must never divide a partial interval cost by the
    # account's cumulative current percentage.
    Set-TokenRaderQuotaDiagnostic $DiagnosticState 'missing_window' '没有当前额度窗口'
    if ($null -eq $EndWindow) { return $null }
    Set-TokenRaderQuotaDiagnostic $DiagnosticState 'missing_metadata' '额度快照缺少观察时间、计划或重置标识'
    if ($null -eq $EndWindow.PSObject.Properties['ObservedAt'] -or $null -eq $EndWindow.ObservedAt -or
        $null -eq $EndWindow.PSObject.Properties['ResetsAt'] -or $null -eq $EndWindow.ResetsAt -or
        $null -eq $EndWindow.PSObject.Properties['WindowMinutes'] -or [int]$EndWindow.WindowMinutes -le 0 -or
        $null -eq $EndWindow.PSObject.Properties['UsedPercent'] -or $null -eq $EndWindow.UsedPercent -or
        $null -eq $EndWindow.PSObject.Properties['PlanType'] -or
        [string]::IsNullOrWhiteSpace([string]$EndWindow.PlanType)) { return $null }
    $endScopeConflict = $null -ne $EndWindow.PSObject.Properties['ScopeConflict'] -and [bool]$EndWindow.ScopeConflict
    if ($endScopeConflict) {
        $conflictDescription = if ($endScopeConflict -and $null -ne $EndWindow.PSObject.Properties['ConflictDescription']) {
            [string]$EndWindow.ConflictDescription
        } else { '额度周期存在冲突计划' }
        if ($null -ne $DiagnosticState) { $DiagnosticState.ConflictDescription = $conflictDescription }
        Set-TokenRaderQuotaDiagnostic $DiagnosticState 'scope_conflict' $conflictDescription
        return $null
    }
    [DateTimeOffset]$currentObservedAt = [DateTimeOffset]$EndWindow.ObservedAt
    [double]$currentUsedPercent = [double]$EndWindow.UsedPercent
    if ([DateTimeOffset]$EndWindow.ResetsAt -le $currentObservedAt) {
        Set-TokenRaderQuotaDiagnostic $DiagnosticState 'expired_window' '额度窗口在观察时已过期'
        return $null
    }
    $endReset = Get-TokenRaderResetIdentity -WindowMinutes ([int]$EndWindow.WindowMinutes) -ResetsAt $EndWindow.ResetsAt
    if ([string]::IsNullOrWhiteSpace($endReset)) { return $null }

    $calibrationStart = $null
    $calibrationEnd = $null
    $historyLookbackApplied = $false
    # Main measurement and current quota cycle have independent boundaries.
    # The selector validates the current cycle's monotonic envelope itself.

    # Historical fallback precedes the first full percentage point. Its
    # endpoint then becomes a fixed cumulative anchor for this measurement.
    # A split 5h/weekly record can carry different metadata timestamps. Use
    # the id attached to this exact window row when available, including an
    # explicitly empty id; only legacy window objects fall back to the
    # top-level value supplied by the caller.
    $effectiveLimitId = if ($null -ne $EndWindow.PSObject.Properties['LimitId']) { [string]$EndWindow.LimitId } else { $RateLimitId }
    if ($null -ne $DiagnosticState) {
        $DiagnosticState.AccountIdentity=$AccountIdentity; $DiagnosticState.PlanType=[string]$EndWindow.PlanType
        $DiagnosticState.WindowMinutes=[int]$EndWindow.WindowMinutes; $DiagnosticState.ResetIdentity=$endReset
        $DiagnosticState.LimitId=$effectiveLimitId
        $DiagnosticState.CurrentUsedPercent=$currentUsedPercent; $DiagnosticState.CurrentObservedAt=$currentObservedAt
        $DiagnosticState.ResetsAt=$EndWindow.ResetsAt
    }
    $baselineAt = [DateTimeOffset]::MinValue
    $baselinePercent = [double]::NaN
    if ($null -ne $StartWindow -and $null -ne $StartWindow.ObservedAt -and
        $null -ne $StartWindow.ResetsAt -and
        [int]$StartWindow.WindowMinutes -eq [int]$EndWindow.WindowMinutes -and
        [string]$StartWindow.PlanType -eq [string]$EndWindow.PlanType -and
        (Get-TokenRaderResetIdentity -WindowMinutes ([int]$StartWindow.WindowMinutes) -ResetsAt $StartWindow.ResetsAt) -eq $endReset -and
        ($null -eq $StartWindow.PSObject.Properties['LimitId'] -or [string]$StartWindow.LimitId -eq $effectiveLimitId)) {
        $baselineAt = [DateTimeOffset]$StartWindow.ObservedAt
        $baselinePercent = [double]$StartWindow.UsedPercent
    }
    if ($null -ne $QuotaNotBefore -and $baselineAt -lt [DateTimeOffset]$QuotaNotBefore) {
        $baselineAt = [DateTimeOffset]$QuotaNotBefore
        $baselinePercent = [double]::NaN
    }
    $selection = [TokenRaderIndexer]::QueryQuotaMeasurementCalibrationPairWithDiagnostics(
        $Connection, $EndOffsets, $WindowKind, [int]$EndWindow.WindowMinutes,
        ([DateTimeOffset]$EndWindow.ResetsAt).ToUniversalTime().ToUnixTimeSeconds(),
        [string]$EndWindow.PlanType, [string]$effectiveLimitId, $currentUsedPercent,
        $currentObservedAt, $CancellationToken, $baselineAt, $baselinePercent)
    $historyRows = $selection.Rows
    if ($null -eq $historyRows -or $historyRows.Rows.Count -ne 2) {
        $code=[string]$selection.ReasonCode
        $message=if ($code -eq 'stale_snapshot') { '当前快照百分比低于本周期已观察值，等待有效快照' } else { '当前周期缺少两个可用快照组成的完整百分比步长' }
        Set-TokenRaderQuotaDiagnostic $DiagnosticState $code $message
        return $null
    }
    $historyStartRecord = ConvertFrom-TokenRaderIndexRecord -Row $historyRows.Rows[0]
    $historyEndRecord = ConvertFrom-TokenRaderIndexRecord -Row $historyRows.Rows[1]
    if ($WindowKind -eq 'FiveHour') {
        $calibrationStart = $historyStartRecord.RateLimits.FiveHour
        $calibrationEnd = $historyEndRecord.RateLimits.FiveHour
    } else {
        $calibrationStart = $historyStartRecord.RateLimits.Weekly
        $calibrationEnd = $historyEndRecord.RateLimits.Weekly
    }
    if ($null -eq $calibrationStart -or $null -eq $calibrationEnd) {
        Set-TokenRaderQuotaDiagnostic $DiagnosticState 'missing_metadata' '校准窗口元数据不完整'; return $null
    }
    $historyLookbackApplied = $null -eq $StartWindow -or
        ($null -ne $StartWindow.PSObject.Properties['ObservedAt'] -and [DateTimeOffset]$calibrationStart.ObservedAt -lt [DateTimeOffset]$StartWindow.ObservedAt)

    [DateTimeOffset]$startObservedAt = [DateTimeOffset]$calibrationStart.ObservedAt
    [DateTimeOffset]$endObservedAt = [DateTimeOffset]$calibrationEnd.ObservedAt
    if ($null -ne $QuotaNotBefore -and $startObservedAt -lt [DateTimeOffset]$QuotaNotBefore) {
        Set-TokenRaderQuotaDiagnostic $DiagnosticState 'account_boundary' '账号标签切换后尚未形成完整校准步长'
        return $null
    }
    [double]$deltaPercent = [double]$calibrationEnd.UsedPercent - [double]$calibrationStart.UsedPercent
    $sameWindow = [int]$calibrationStart.WindowMinutes -eq [int]$calibrationEnd.WindowMinutes -and
        [int]$calibrationEnd.WindowMinutes -eq [int]$EndWindow.WindowMinutes
    $samePlan = [string]::Equals([string]$calibrationStart.PlanType, [string]$calibrationEnd.PlanType, [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$calibrationEnd.PlanType, [string]$EndWindow.PlanType, [StringComparison]::OrdinalIgnoreCase)
    $calibrationStartReset = Get-TokenRaderResetIdentity -WindowMinutes ([int]$calibrationStart.WindowMinutes) -ResetsAt $calibrationStart.ResetsAt
    $calibrationEndReset = Get-TokenRaderResetIdentity -WindowMinutes ([int]$calibrationEnd.WindowMinutes) -ResetsAt $calibrationEnd.ResetsAt
    $boundaryValid = $sameWindow -and $samePlan -and $calibrationStartReset -eq $endReset -and
        $calibrationEndReset -eq $endReset -and $endObservedAt -gt $startObservedAt -and $deltaPercent -gt 0.000000001
    if (-not $boundaryValid) { Set-TokenRaderQuotaDiagnostic $DiagnosticState 'invalid_boundary' '校准快照时间或周期边界不一致'; return $null }
    $coverageComplete = $currentObservedAt -ge $endObservedAt -and ($null -eq $MainLastCountedAt -or
        $currentObservedAt -ge [DateTimeOffset]$MainLastCountedAt)

    $cacheKey = '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $startObservedAt.UtcDateTime.Ticks, $endObservedAt.UtcDateTime.Ticks,$WindowKind,$EndWindow.WindowMinutes,$endReset,$EndWindow.PlanType,$effectiveLimitId
    $aggregate = if ($null -ne $Cache -and $Cache.ContainsKey($cacheKey)) {
        $Cache[$cacheKey]
    } else {
        $value = [TokenRaderIndexer]::AggregateQuotaTimeRangeRecordsAtOffsets(
            $Connection, $EndOffsets, $startObservedAt, $endObservedAt,
            $Thresholds, $CancellationToken, $ProgressState, $WindowKind, [int]$EndWindow.WindowMinutes,
            ([DateTimeOffset]$EndWindow.ResetsAt).ToUnixTimeSeconds(), [string]$EndWindow.PlanType, $effectiveLimitId)
        if ($null -ne $Cache) { $Cache[$cacheKey] = $value }
        $value
    }
    $priced = ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $PricingDocument
    if ($null -ne $DiagnosticState) {
        $DiagnosticState.StartObservedAt=$startObservedAt; $DiagnosticState.EndObservedAt=$endObservedAt
        $DiagnosticState.StartUsedPercent=[double]$calibrationStart.UsedPercent; $DiagnosticState.EndUsedPercent=[double]$calibrationEnd.UsedPercent
        $DiagnosticState.TotalCost=[double]$priced.TotalCost; $DiagnosticState.PricingComplete=[bool]$priced.PricingComplete
        $DiagnosticState.AttributionComplete=[bool]$aggregate.AttributionComplete
        $DiagnosticState.UnattributedEvents=[long]$aggregate.UnattributedEvents
    }
    if (-not [bool]$aggregate.AttributionComplete) {
        Set-TokenRaderQuotaDiagnostic $DiagnosticState 'unknown_attribution' '校准区间存在无法确认额度周期归属的调用'
        return $null
    }
    if (-not [bool]$priced.PricingComplete) { Set-TokenRaderQuotaDiagnostic $DiagnosticState 'pricing_incomplete' '校准区间价格不完整' }
    elseif ([double]$priced.TotalCost -le 0) { Set-TokenRaderQuotaDiagnostic $DiagnosticState 'zero_cost' '完整步长内没有可计价调用' }
    else { Set-TokenRaderQuotaDiagnostic $DiagnosticState 'ok' '本次更新' 'updated' }
    # PricingComplete intentionally retains its historical meaning: an
    # unobserved tier can still be shown at the Standard reference rate.  A
    # confirmed quota calibration requires known tiers. Unknown modes may
    # produce a separately labelled reference without upgrading this flag.
    $quotaEvidenceComplete = $null -ne $priced.PSObject.Properties['QuotaEvidenceComplete'] -and
        [bool]$priced.QuotaEvidenceComplete
    [Int64]$observedTokens = [Int64]$priced.Usage.Total
    $directUsed = if ($null -ne $EndWindow.PSObject.Properties['UsedTokens']) { $EndWindow.UsedTokens } else { $null }
    $directRemaining = if ($null -ne $EndWindow.PSObject.Properties['RemainingTokens']) { $EndWindow.RemainingTokens } else { $null }
    $directLimit = if ($null -ne $EndWindow.PSObject.Properties['LimitTokens']) { $EndWindow.LimitTokens } else { $null }
    if ($null -eq $directLimit -and $null -ne $directUsed -and $null -ne $directRemaining) {
        $directLimit = [Int64]$directUsed + [Int64]$directRemaining
    }
    [Int64]$totalTokens = 0
    [Int64]$usedTokens = 0
    [Int64]$remainingTokens = 0
    $capacitySource = ''
    if ($null -ne $directLimit -and [Int64]$directLimit -gt 0) {
        $totalTokens = [Int64]$directLimit
        $usedTokens = [Int64][Math]::Round($totalTokens * ($currentUsedPercent / 100.0))
        $remainingTokens = [Math]::Max([Int64]0, $totalTokens - $usedTokens)
        $capacitySource = 'direct_limit_tokens'
    } elseif ($observedTokens -gt 0 -and $deltaPercent -gt 0) {
        $totalTokens = [Int64][Math]::Round($observedTokens * 100.0 / $deltaPercent)
        if ($totalTokens -lt $observedTokens) { $totalTokens = $observedTokens }
        $usedTokens = [Int64][Math]::Round($totalTokens * ($currentUsedPercent / 100.0))
        $remainingTokens = [Math]::Max([Int64]0, $totalTokens - $usedTokens)
        $capacitySource = 'percent_delta_tokens'
    }
    [double]$averageUsdPerToken = 0
    [double]$estimatedTotalUsd = 0
    [double]$estimatedRemainingUsd = 0
    $usdEstimateSource = ''
    [double]$estimatedUsedUsd = 0
    # Missing mode evidence must not hide a usable dollar reference. Keep the
    # strict evidence flag false and disclose Standard-reference pricing.
    $referencePricingApplied = [bool]$priced.PricingComplete -and -not $quotaEvidenceComplete
    if ([bool]$priced.PricingComplete -and [double]$priced.TotalCost -gt 0 -and $deltaPercent -gt 0) {
        if ($observedTokens -gt 0) { $averageUsdPerToken = [double]$priced.TotalCost / [double]$observedTokens }
        $estimatedTotalUsd = [double]$priced.TotalCost / ($deltaPercent / 100.0)
        $estimatedUsedUsd = $estimatedTotalUsd * ($currentUsedPercent / 100.0)
        $estimatedRemainingUsd = $estimatedTotalUsd * ([Math]::Max(0.0, 100.0 - $currentUsedPercent) / 100.0)
        $usdEstimateSource = 'snapshot_delta_usd_estimate'
    }
    $percentResolution = [Math]::Min(
        [double](Get-TokenRaderWindowPercentResolution $calibrationStart),
        [double](Get-TokenRaderWindowPercentResolution $calibrationEnd))
    [pscustomobject]@{
        BoundaryValid = $true
        CoverageComplete = [bool]$coverageComplete
        StartObservedAt = $startObservedAt
        EndObservedAt = $endObservedAt
        CurrentObservedAt = $currentObservedAt
        StartUsedPercent = [double]$calibrationStart.UsedPercent
        CalibrationEndUsedPercent = [double]$calibrationEnd.UsedPercent
        CurrentUsedPercent = $currentUsedPercent
        DeltaPercent = $deltaPercent
        EffectiveDeltaPercent = $deltaPercent
        PercentResolution = $percentResolution
        ResolutionAssumptionApplied = $false
        HistoryLookbackApplied = $historyLookbackApplied
        WindowMinutes = [int]$EndWindow.WindowMinutes
        ResetsAt = $EndWindow.ResetsAt
        ResetIdentity = $endReset
        PlanType = [string]$EndWindow.PlanType
        LimitId = $effectiveLimitId
        AccountIdentity = $AccountIdentity
        AttributionComplete = [bool]$aggregate.AttributionComplete
        Usage = $priced.Usage
        InputCost = [double]$priced.InputCost
        CachedCost = [double]$priced.CachedCost
        OutputCost = [double]$priced.OutputCost
        TotalCost = [double]$priced.TotalCost
        CacheCreationCost = [double]$priced.CacheCreationCost
        PricingComplete = [bool]$priced.PricingComplete
        CostComplete = [bool]$priced.CostComplete
        ServiceTierComplete = if ($null -ne $priced.PSObject.Properties['ServiceTierComplete']) { [bool]$priced.ServiceTierComplete } else { $true }
        ModeEvidenceComplete = if ($null -ne $priced.PSObject.Properties['ModeEvidenceComplete']) { [bool]$priced.ModeEvidenceComplete } else { $true }
        ModeAssumptionApplied = if ($null -ne $priced.PSObject.Properties['ModeAssumptionApplied']) { [bool]$priced.ModeAssumptionApplied } else { $false }
        ManualServiceTierApplied = if ($null -ne $priced.PSObject.Properties['ManualServiceTierApplied']) { [bool]$priced.ManualServiceTierApplied } else { $false }
        QuotaEvidenceComplete = $quotaEvidenceComplete
        ReferencePricingApplied = $referencePricingApplied
        UnknownModels = @($priced.UnknownModels)
        CountedEvents = [Int64]$aggregate.CountedEvents
        FirstCountedAt = $aggregate.FirstCountedAt
        LastCountedAt = $aggregate.LastCountedAt
        StandardContextEvents = [Int64]$priced.StandardContextEvents
        LongContextEvents = [Int64]$priced.LongContextEvents
        StandardContextInput = [Int64]$priced.StandardContextInput
        LongContextInput = [Int64]$priced.LongContextInput
        LongContextOutput = [Int64]$priced.LongContextOutput
        LongContextExtraCost = [double]$priced.LongContextExtraCost
        CacheWriteObservable = [bool]$priced.CacheWriteObservable
        CostCoverage = [string]$priced.CostCoverage
        ProcessingMilliseconds = [double]$aggregate.ProcessingMilliseconds
        ObservedTokens = $observedTokens
        TotalTokens = $totalTokens
        UsedTokens = $usedTokens
        RemainingTokens = $remainingTokens
        EstimateSource = $usdEstimateSource
        CapacitySource = $capacitySource
        UsdEstimateSource = $usdEstimateSource
        AverageUsdPerToken = $averageUsdPerToken
        EstimatedTotalUsd = $estimatedTotalUsd
        EstimatedUsedUsd = $estimatedUsedUsd
        ObservedCostUsd = [double]$priced.TotalCost
        EstimatedRemainingUsd = $estimatedRemainingUsd
        IdentityComplete = [bool]$aggregate.IdentityComplete
        IdentitySources = @($aggregate.IdentitySources)
        UnidentifiedEvents = [Int64]$aggregate.UnidentifiedEvents
    }
}

function Get-TokenRaderIndexedIntervalResult {
    param(
        [Parameter(Mandatory = $true)]$Baseline,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [hashtable]$BaselineSnapshots = $null,
        $EndOffsets = $null,
        $EndRevision = $null,
        $EndedAt = $null,
        [bool]$ScanRateLimits = $true,
        [string]$SessionsRoot = '',
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [hashtable]$ProgressState = $null,
        [string]$AccountIdentity = '',
        $QuotaNotBefore = $null
    )
    if ([string]::IsNullOrWhiteSpace($SessionsRoot)) { $SessionsRoot = [string]$Baseline.SessionsRoot }
    $ending = $null
    if ($null -eq $EndOffsets) {
        $ending = CaptureMeasurementEnd -Baseline $Baseline -ProgressState $ProgressState
        $EndOffsets = $ending.EndOffsets
        $EndRevision = $ending.EndRevision
    }
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $starts = ConvertTo-TokenRaderOffsetMap -Value $Baseline.StartOffsets
    $ends = ConvertTo-TokenRaderOffsetMap -Value $EndOffsets
    $startedAt = [DateTimeOffset]$Baseline.StartedAt
    $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($PricingDocument.models)) {
        $threshold = if ($null -ne $entry.PSObject.Properties['longContextThreshold']) { [Int64]$entry.longContextThreshold } else { 0L }
        $id = [string]$entry.id
        if (-not [string]::IsNullOrWhiteSpace($id)) { $thresholds[$id] = $threshold }
        foreach ($alias in @($entry.aliases)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { $thresholds[[string]$alias] = $threshold }
        }
    }
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '流式聚合区间记录'
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    $aggregate = [TokenRaderIndexer]::AggregateIntervalRecords(
        $index.Connection, $starts, $ends, $startedAt, $thresholds, $CancellationToken, $ProgressState)
    $priced = ConvertFrom-TokenRaderPricedAggregate -Aggregate $aggregate -PricingDocument $PricingDocument

    $endRateLimits = if ($null -ne $ending -and $null -ne $ending.EndRateLimits) { $ending.EndRateLimits }
                     elseif ($ScanRateLimits) { Get-TokenRaderIndexedRateLimitsAtOffsets -Connection $index.Connection -EndOffsets $ends }
                     else { $null }
    $startRateLimits = if ($null -ne $Baseline.PSObject.Properties['StartRateLimits']) { $Baseline.StartRateLimits }
                       elseif ($null -ne $Baseline.PSObject.Properties['RateLimits']) { $Baseline.RateLimits }
                       else { $null }
    $quotaEvidence = $null
    $quotaDiagnosticMaps = @{FiveHour=@{};Weekly=@{}}
    foreach ($kind in @('FiveHour','Weekly')) { Set-TokenRaderQuotaDiagnostic $quotaDiagnosticMaps[$kind] 'missing_window' '没有当前额度窗口' }
    if ($ScanRateLimits -and $null -ne $endRateLimits) {
        $quotaAggregateCache = @{}
        $quotaEvidence = [pscustomobject]@{
            FiveHour = Get-TokenRaderQuotaWindowEvidence `
                -StartWindow $(if ($null -ne $startRateLimits) { $startRateLimits.FiveHour } else { $null }) `
                -EndWindow $endRateLimits.FiveHour `
                -MainLastCountedAt $aggregate.LastCountedAt `
                -WindowKind 'FiveHour' `
                -RateLimitId $(if ($null -ne $endRateLimits.PSObject.Properties['LimitId']) { [string]$endRateLimits.LimitId } else { '' }) `
                -Connection $index.Connection `
                -EndOffsets $ends `
                -Thresholds $thresholds `
                -PricingDocument $PricingDocument `
                -CancellationToken $CancellationToken `
                -ProgressState $ProgressState `
                -Cache $quotaAggregateCache -DiagnosticState $quotaDiagnosticMaps.FiveHour -AccountIdentity $AccountIdentity -QuotaNotBefore $QuotaNotBefore
            Weekly = Get-TokenRaderQuotaWindowEvidence `
                -StartWindow $(if ($null -ne $startRateLimits) { $startRateLimits.Weekly } else { $null }) `
                -EndWindow $endRateLimits.Weekly `
                -MainLastCountedAt $aggregate.LastCountedAt `
                -WindowKind 'Weekly' `
                -RateLimitId $(if ($null -ne $endRateLimits.PSObject.Properties['LimitId']) { [string]$endRateLimits.LimitId } else { '' }) `
                -Connection $index.Connection `
                -EndOffsets $ends `
                -Thresholds $thresholds `
                -PricingDocument $PricingDocument `
                -CancellationToken $CancellationToken `
                -ProgressState $ProgressState `
                -Cache $quotaAggregateCache -DiagnosticState $quotaDiagnosticMaps.Weekly -AccountIdentity $AccountIdentity -QuotaNotBefore $QuotaNotBefore
        }
    }
    $modelList = @($priced.Models)
    $usage = $priced.Usage
    [pscustomobject]@{
        StartedAt = $startedAt
        EndedAt = if ($null -ne $ending) { $ending.EndedAt } elseif ($null -ne $EndedAt) { [DateTimeOffset]$EndedAt } else { [DateTimeOffset]::Now }
        Usage = $usage
        Models = $modelList
        ModelDisplay = [string]$priced.ModelDisplay
        ChangedSessions = [int]$aggregate.ChangedSessions
        Items = @($priced.Items)
        InputCost = [double]$priced.InputCost
        CachedCost = [double]$priced.CachedCost
        OutputCost = [double]$priced.OutputCost
        TotalCost = [double]$priced.TotalCost
        PricingComplete = [bool]$priced.PricingComplete
        CostComplete = [bool]$priced.CostComplete
        ServiceTierComplete = [bool]$priced.ServiceTierComplete
        ModeEvidenceComplete = [bool]$priced.ModeEvidenceComplete
        ModeAssumptionApplied = [bool]$priced.ModeAssumptionApplied
        ManualServiceTierApplied = [bool]$priced.ManualServiceTierApplied
        QuotaEvidenceComplete = [bool]$priced.QuotaEvidenceComplete
        UnknownModels = @($priced.UnknownModels)
        StartRateLimits = $startRateLimits
        EndRateLimits = $endRateLimits
        RateLimits = $endRateLimits
        QuotaEvidence = $quotaEvidence
        QuotaDiagnostics = [pscustomobject]@{FiveHour=[pscustomobject]$quotaDiagnosticMaps.FiveHour;Weekly=[pscustomobject]$quotaDiagnosticMaps.Weekly}
        AccountIdentity = $AccountIdentity
        RawEvents = [Int64]$aggregate.RawEvents
        CountedEvents = [Int64]$aggregate.CountedEvents
        DuplicateEventsDropped = [Int64]$aggregate.DuplicateEventsDropped
        InheritedEventsDropped = [Int64]$aggregate.InheritedEventsDropped
        BytesRead = [Int64]$aggregate.BytesRead
        ProcessedRows = [Int64]$aggregate.ProcessedRows
        ProcessingMilliseconds = [double]$aggregate.ProcessingMilliseconds
        FirstCountedAt = $aggregate.FirstCountedAt
        LastCountedAt = $aggregate.LastCountedAt
        StandardContextEvents = [Int64]$priced.StandardContextEvents
        LongContextEvents = [Int64]$priced.LongContextEvents
        StandardContextInput = [Int64]$priced.StandardContextInput
        LongContextInput = [Int64]$priced.LongContextInput
        LongContextOutput = [Int64]$priced.LongContextOutput
        LongContextExtraCost = [double]$priced.LongContextExtraCost
        CacheWriteObservable = [bool]$priced.CacheWriteObservable
        CostCoverage = [string]$priced.CostCoverage
        IndexRevision = if ($null -ne $EndRevision) { [Int64]$EndRevision } else { [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) }
        ChangeRevision = if ($null -ne $ending) { [Int64]$ending.ChangeRevision } else { [Int64][TokenRaderIndexer]::GetChangeRevision($SessionsRoot) }
        Signature = 'index:' + $(if ($null -ne $EndRevision) { [string][Int64]$EndRevision } else { [string][Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) })
        BaselineSnapshots = if ($null -ne $BaselineSnapshots) { $BaselineSnapshots } else { @{} }
        StartOffsets = $starts
        EndOffsets = $ends
    }
}

function Get-TokenRaderPricingCacheKey {
    param([Parameter(Mandatory = $true)]$PricingDocument)
    $modelParts = foreach ($entry in @($PricingDocument.models | Sort-Object id)) {
        $aliasValues = if ($null -ne $entry.PSObject.Properties['aliases']) { @($entry.aliases) } else { @() }
        $aliases = @($aliasValues | ForEach-Object {
            ([string]$_).Trim().ToLowerInvariant()
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ','
        @(
            [string]$entry.id,
            $aliases,
            [string]$entry.input,
            [string]$entry.cachedInput,
            [string]$entry.output,
            $(if ($null -ne $entry.PSObject.Properties['contextWindow']) { [string]$entry.contextWindow } else { '' }),
            $(if ($null -ne $entry.PSObject.Properties['longContextThreshold']) { [string]$entry.longContextThreshold } else { '' }),
            $(if ($null -ne $entry.PSObject.Properties['longContextInputMultiplier']) { [string]$entry.longContextInputMultiplier } else { '' }),
            $(if ($null -ne $entry.PSObject.Properties['longContextOutputMultiplier']) { [string]$entry.longContextOutputMultiplier } else { '' }),
            $(if ($null -ne $entry.PSObject.Properties['serviceTiers']) { ConvertTo-Json -InputObject $entry.serviceTiers -Depth 8 -Compress } else { '' })
        ) -join ':'
    }
    $manualParts = @()
    if ($null -ne $PricingDocument.PSObject.Properties['ManualServiceTiers'] -and $null -ne $PricingDocument.ManualServiceTiers) {
        $manual = $PricingDocument.ManualServiceTiers
        $manualParts = foreach ($property in @(
            if ($manual -is [Collections.IDictionary]) {
                foreach ($key in @($manual.Keys)) { [pscustomobject]@{ Name = [string]$key; Value = $manual[$key] } }
            } else { @($manual.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } }) }
        ) | Sort-Object @{ Expression = { ([string]$_.Name).Trim().ToLowerInvariant() } }) {
            $tier = ConvertTo-TokenRaderServiceTier ([string]$property.Value)
            '{0}={1}' -f ([string]$property.Name).Trim().ToLowerInvariant(), $tier
        }
    }
    # Preserve the v6 prefix for callers that display/diagnose it, while
    # ensuring a transient manual mode selection cannot reuse a cached result
    # computed under another selection.
    return (@('usage-history-v6', [string]$PricingDocument.verifiedAt, [string]$PricingDocument.unitTokens, ($modelParts -join ';'), ('manual:' + ($manualParts -join ','))) -join '|')
}

function ConvertFrom-TokenRaderUsageHistorySnapshot {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [bool]$FromCache = $true
    )
    $windowStart = [DateTimeOffset]::new([DateTime]::new([Int64]$Snapshot.WindowStartTicks, [DateTimeKind]::Utc))
    $windowEnd = [DateTimeOffset]::new([DateTime]::new([Int64]$Snapshot.WindowEndTicks, [DateTimeKind]::Utc))
    $computedAt = [DateTimeOffset]::new([DateTime]::new([Int64]$Snapshot.ComputedAtTicks, [DateTimeKind]::Utc))
    $models = if ([string]::IsNullOrWhiteSpace([string]$Snapshot.Models)) {
        @()
    } else {
        @(([string]$Snapshot.Models).Split([char]0x1F, [StringSplitOptions]::RemoveEmptyEntries))
    }
    $usage = New-TokenRaderUsage `
        -InputTokens ([Int64]$Snapshot.TotalInput) `
        -CachedTokens ([Int64]$Snapshot.TotalCached) `
        -OutputTokens ([Int64]$Snapshot.TotalOutput) `
        -ReasoningOutputTokens ([Int64]$Snapshot.TotalReasoning)
    $modelBreakdown = foreach ($modelSnapshot in @($Snapshot.ModelBreakdown)) {
        if ($null -eq $modelSnapshot) { continue }
        $modelUsage = New-TokenRaderUsage `
            -InputTokens ([Int64]$modelSnapshot.TotalInput) `
            -CachedTokens ([Int64]$modelSnapshot.TotalCached) `
            -OutputTokens ([Int64]$modelSnapshot.TotalOutput) `
            -ReasoningOutputTokens ([Int64]$modelSnapshot.TotalReasoning)
        [pscustomobject]@{
            Model = $(if ([string]::IsNullOrWhiteSpace([string]$modelSnapshot.Model)) { '未知模型' } else { [string]$modelSnapshot.Model })
            ServiceTier = if ($null -ne $modelSnapshot.PSObject.Properties['ServiceTier']) { [string]$modelSnapshot.ServiceTier } else { '' }
            Usage = $modelUsage
            InputCost = [double]$modelSnapshot.InputCost
            CachedCost = [double]$modelSnapshot.CachedCost
            OutputCost = [double]$modelSnapshot.OutputCost
            TotalCost = [double]$modelSnapshot.InputCost + [double]$modelSnapshot.CachedCost + [double]$modelSnapshot.OutputCost
            PricingComplete = [bool]$modelSnapshot.PricingComplete
            CostComplete = [bool]$modelSnapshot.PricingComplete
            Events = [Int64]$modelSnapshot.Events
            CacheCreationTokens = [Int64]$modelSnapshot.CacheCreationTokens
            CacheWriteObservable = [bool]$modelSnapshot.CacheWriteObservable
            StandardContextEvents = [Int64]$modelSnapshot.StandardContextEvents
            LongContextEvents = [Int64]$modelSnapshot.LongContextEvents
            StandardContextInput = [Int64]$modelSnapshot.StandardContextInput
            LongContextInput = [Int64]$modelSnapshot.LongContextInput
            LongContextOutput = [Int64]$modelSnapshot.LongContextOutput
            CostCoverage = if ([bool]$modelSnapshot.CacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
        }
    }
    [pscustomobject]@{
        WindowStart = $windowStart
        WindowEnd = $windowEnd
        ComputedAt = $computedAt
        IndexRevision = [Int64]$Snapshot.IndexRevision
        Usage = $usage
        Models = $models
        ModelDisplay = [string]$Snapshot.ModelDisplay
        ModelBreakdown = @($modelBreakdown)
        InputCost = [double]$Snapshot.InputCost
        CachedCost = [double]$Snapshot.CachedCost
        OutputCost = [double]$Snapshot.OutputCost
        TotalCost = [double]$Snapshot.InputCost + [double]$Snapshot.CachedCost + [double]$Snapshot.OutputCost
        PricingComplete = [bool]$Snapshot.PricingComplete
        CostComplete = [bool]$Snapshot.PricingComplete
        RawEvents = [Int64]$Snapshot.RawEvents
        CountedEvents = [Int64]$Snapshot.CountedEvents
        DuplicateEventsDropped = [Int64]$Snapshot.DuplicateEventsDropped
        InheritedEventsDropped = [Int64]$Snapshot.InheritedEventsDropped
        ProcessedRows = [Int64]$Snapshot.ProcessedRows
        CacheCreationTokens = [Int64]$Snapshot.CacheCreationTokens
        CacheWriteObservable = [bool]$Snapshot.CacheWriteObservable
        CostCoverage = if ([bool]$Snapshot.CacheWriteObservable) { 'observable_tokens_and_cache_write' } else { 'observable_tokens_only' }
        StandardContextEvents = [Int64]$Snapshot.StandardContextEvents
        LongContextEvents = [Int64]$Snapshot.LongContextEvents
        StandardContextInput = [Int64]$Snapshot.StandardContextInput
        LongContextInput = [Int64]$Snapshot.LongContextInput
        LongContextOutput = [Int64]$Snapshot.LongContextOutput
        LongContextExtraCost = [double]$Snapshot.LongContextExtraCost
        FromCache = $FromCache
    }
}

function Add-TokenRaderToolUsageToHistoryResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Connection
    )
    $toolUsage = [TokenRaderIndexer]::AggregateToolUsage(
        $Connection, [DateTimeOffset]$Result.WindowStart, [DateTimeOffset]$Result.WindowEnd)
    if ($null -ne $Result.PSObject.Properties['ToolUsage']) {
        $Result.ToolUsage = $toolUsage
    } else {
        Add-Member -InputObject $Result -NotePropertyName ToolUsage -NotePropertyValue $toolUsage
    }
    return $Result
}

function Get-TokenRaderUsageHistoryWindow {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [Parameter(Mandatory = $true)]$PricingDocument,
        [ValidateRange(0, 6)][int]$DayOffset = 0,
        $AnchorAt = $null,
        [switch]$ForceRefresh,
        [switch]$PurgeExpired,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [hashtable]$ProgressState = $null
    )

    $anchor = if ($null -eq $AnchorAt) { [DateTimeOffset]::Now } else { [DateTimeOffset]$AnchorAt }
    # ManualServiceTiers is a transient measurement overlay.  History results
    # are persisted in the indexer's snapshot cache, so deliberately use a
    # shallow pricing-document copy without that property.  Do not mutate the
    # caller's document: the same document may be used by the interval worker
    # for an explicitly confirmed measurement immediately afterwards.
    $historyPricingDocument = $PricingDocument
    if ($null -ne $PricingDocument.PSObject.Properties['ManualServiceTiers']) {
        $historyPricingDocument = [pscustomobject]@{}
        foreach ($property in @($PricingDocument.PSObject.Properties)) {
            if ([string]::Equals([string]$property.Name, 'ManualServiceTiers', [StringComparison]::OrdinalIgnoreCase)) { continue }
            Add-Member -InputObject $historyPricingDocument -MemberType NoteProperty -Name ([string]$property.Name) -Value $property.Value
        }
    }
    # Second-aligned boundaries preserve an exact rolling-24-hour view while
    # avoiding one cache row per sub-second UI request. These are not
    # calendar-day buckets.
    $alignedAnchor = [DateTimeOffset]::new(
        $anchor.Year, $anchor.Month, $anchor.Day, $anchor.Hour, $anchor.Minute, $anchor.Second, $anchor.Offset)
    $windowEnd = $alignedAnchor.AddDays(-$DayOffset)
    $windowStart = $windowEnd.AddHours(-24)
    $startTicks = [Int64]$windowStart.UtcDateTime.Ticks
    $endTicks = [Int64]$windowEnd.UtcDateTime.Ticks
    # The cache identity likewise excludes any transient manual selection.
    $pricingKey = Get-TokenRaderPricingCacheKey -PricingDocument $historyPricingDocument
    if ($null -ne $ProgressState) {
        $ProgressState.Stage = '同步最新日志后冻结24小时边界'
        $ProgressState.LastProgressAt = [DateTimeOffset]::Now
    }
    # A history selection is itself a freshness boundary: do not rely on the
    # five-minute timer or a prior View Result having already consumed the file
    # watcher queue. The compiled catalog pass also catches delayed/lost file
    # notifications before the timestamp aggregate is evaluated.
    $index = Sync-TokenRaderMeasurementBoundary `
        -SessionsRoot $SessionsRoot `
        -ProgressState $ProgressState `
        -TimeoutSeconds 25
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$index.DbPath + '.lock'), 10000)
    try {
        $revision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection)
        if ($PurgeExpired) {
            $cutoffTicks = [Int64][DateTimeOffset]::Now.AddDays(-7).UtcDateTime.Ticks
            [void][TokenRaderIndexer]::PurgeUsageHistory($index.Connection, $cutoffTicks)
        }
        if (-not $ForceRefresh) {
            $cached = [TokenRaderIndexer]::GetUsageHistorySnapshot(
                $index.Connection, $startTicks, $endTicks, $revision, $pricingKey)
            if ($null -ne $cached) {
                $cachedResult = ConvertFrom-TokenRaderUsageHistorySnapshot -Snapshot $cached -FromCache $true
                return Add-TokenRaderToolUsageToHistoryResult -Result $cachedResult -Connection $index.Connection
            }
        }

        $thresholds = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in @($historyPricingDocument.models)) {
            $threshold = if ($null -ne $entry.PSObject.Properties['longContextThreshold']) { [Int64]$entry.longContextThreshold } else { 0L }
            $id = [string]$entry.id
            if (-not [string]::IsNullOrWhiteSpace($id)) { $thresholds[$id] = $threshold }
            foreach ($alias in @($entry.aliases)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$alias)) { $thresholds[[string]$alias] = $threshold }
            }
        }
        if ($null -ne $ProgressState) {
            $ProgressState.Stage = '读取24小时磁盘用量'
            $ProgressState.LastProgressAt = [DateTimeOffset]::Now
        }
        $aggregate = [TokenRaderIndexer]::AggregateTimeRangeRecords(
            $index.Connection, $windowStart, $windowEnd, $thresholds, $CancellationToken, $ProgressState)

        $unknownModels = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [double]$inputCost = 0
        [double]$cachedCost = 0
        [double]$outputCost = 0
        [double]$cacheCreationCost = 0
        [double]$longContextExtraCost = 0
        $modelTotals = New-Object hashtable ([StringComparer]::OrdinalIgnoreCase)
        foreach ($bucket in @($aggregate.Buckets)) {
            $bucketUsage = New-TokenRaderUsage -InputTokens $bucket.Input -CachedTokens $bucket.Cached -OutputTokens $bucket.Output -ReasoningOutputTokens $bucket.Reasoning
            $model = [string]$bucket.Model
            $serviceTier = if ($null -ne $bucket.PSObject.Properties['ServiceTier']) { ConvertTo-TokenRaderServiceTier ([string]$bucket.ServiceTier) } else { '' }
            $serviceTierSourceProvided = $null -ne $bucket.PSObject.Properties['ServiceTierSource']
            $serviceTierSource = if ($serviceTierSourceProvided) { [string]$bucket.ServiceTierSource } else { $null }
            # Keep history on the same per-call/bucket pricing path as the
            # interval and quota views.  In particular, cache creation tokens
            # are charged once at 1.25x and a >272K bucket receives the input
            # and output long-context multipliers exactly once.
            $costArgs = @{
                Usage = $bucketUsage; Model = $model; PricingDocument = $historyPricingDocument
                Scope = 'call'; LongContextApplied = [bool]$bucket.LongContext
                CacheCreationTokens = [Int64]$bucket.CacheCreationTokens
                CacheWriteObservable = [bool]$bucket.CacheWriteObservable
                RequestInputObservable = if ($null -ne $bucket.PSObject.Properties['RequestInputObservable']) { [bool]$bucket.RequestInputObservable } else { $true }
                LongContextPricingUncertain = if ($null -ne $bucket.PSObject.Properties['LongContextPricingUncertain']) { [bool]$bucket.LongContextPricingUncertain } else { $null }
                ServiceTier = $serviceTier
            }
            if ($null -ne $bucket.PSObject.Properties['ServiceTierSource']) { $costArgs.ServiceTierSource = $serviceTierSource }
            if ($null -ne $bucket.PSObject.Properties['ServiceTierEvidenceComplete']) { $costArgs.ServiceTierEvidenceComplete = [bool]$bucket.ServiceTierEvidenceComplete }
            elseif ($null -ne $bucket.PSObject.Properties['ModeEvidenceComplete']) { $costArgs.ServiceTierEvidenceComplete = [bool]$bucket.ModeEvidenceComplete }
            $cost = Get-TokenRaderCost @costArgs
            # Determine the effective tier before choosing the model-total
            # bucket.  In particular, a missing/untrusted indexed tier stays
            # Standard-priced for display but remains an empty evidence tier;
            # it must not be merged into a genuinely observed priority row.
            $modelKey = $model + '|' + [string]$cost.ServiceTier
            if (-not $modelTotals.ContainsKey($modelKey)) {
                $modelTotals[$modelKey] = [pscustomobject]@{
                    Model = $model
                    ServiceTier = [string]$cost.ServiceTier
                    TotalInput = [Int64]0
                    TotalCached = [Int64]0
                    TotalOutput = [Int64]0
                    TotalReasoning = [Int64]0
                    InputCost = [double]0
                    CachedCost = [double]0
                    OutputCost = [double]0
                    PricingComplete = $true
                    Events = [Int64]0
                    CacheCreationTokens = [Int64]0
                    CacheWriteObservable = $true
                    StandardContextEvents = [Int64]0
                    LongContextEvents = [Int64]0
                    StandardContextInput = [Int64]0
                    LongContextInput = [Int64]0
                    LongContextOutput = [Int64]0
                }
            }
            $modelTotal = $modelTotals[$modelKey]
            $modelTotal.TotalInput += [Int64]$bucket.Input
            $modelTotal.TotalCached += [Int64]$bucket.Cached
            $modelTotal.TotalOutput += [Int64]$bucket.Output
            $modelTotal.TotalReasoning += [Int64]$bucket.Reasoning
            $modelTotal.Events += [Int64]$bucket.Events
            $modelTotal.CacheCreationTokens += [Int64]$bucket.CacheCreationTokens
            if (-not [bool]$bucket.CacheWriteObservable) { $modelTotal.CacheWriteObservable = $false }
            if ([bool]$bucket.LongContext) {
                $modelTotal.LongContextEvents += [Int64]$bucket.Events
                $modelTotal.LongContextInput += [Int64]$bucket.Input
                $modelTotal.LongContextOutput += [Int64]$bucket.Output
            } else {
                $modelTotal.StandardContextEvents += [Int64]$bucket.Events
                $modelTotal.StandardContextInput += [Int64]$bucket.Input
            }
            $modelTotal.ServiceTier = [string]$cost.ServiceTier
            if (-not [bool]$cost.Known) {
                [void]$unknownModels.Add($(if ([string]::IsNullOrWhiteSpace($model)) { '未知模型' } else { $model }))
                $modelTotal.PricingComplete = $false
                continue
            }
            $bucketInputCost = [double]$cost.InputCost
            $bucketCachedCost = [double]$cost.CachedCost
            $bucketOutputCost = [double]$cost.OutputCost
            $cacheCreationCost += [double]$cost.CacheCreationCost
            $inputCost += $bucketInputCost
            $cachedCost += $bucketCachedCost
            $outputCost += $bucketOutputCost
            if ([bool]$bucket.LongContext) {
                [double]$standardInputCost = if ([double]$cost.InputMultiplier -gt 0) { $bucketInputCost / [double]$cost.InputMultiplier } else { $bucketInputCost }
                [double]$standardCachedCost = if ([double]$cost.InputMultiplier -gt 0) { $bucketCachedCost / [double]$cost.InputMultiplier } else { $bucketCachedCost }
                [double]$standardOutputCost = if ([double]$cost.OutputMultiplier -gt 0) { $bucketOutputCost / [double]$cost.OutputMultiplier } else { $bucketOutputCost }
                $longContextExtraCost += ($bucketInputCost + $bucketCachedCost + $bucketOutputCost) -
                    ($standardInputCost + $standardCachedCost + $standardOutputCost)
            }
            $modelTotal.InputCost += $bucketInputCost
            $modelTotal.CachedCost += $bucketCachedCost
            $modelTotal.OutputCost += $bucketOutputCost
        }

        $models = @($aggregate.Models)
        $snapshot = New-Object TokenRaderUsageHistorySnapshot
        $snapshot.WindowStartTicks = $startTicks
        $snapshot.WindowEndTicks = $endTicks
        $snapshot.ComputedAtTicks = [Int64][DateTimeOffset]::UtcNow.UtcDateTime.Ticks
        $snapshot.IndexRevision = $revision
        $snapshot.PricingKey = $pricingKey
        $snapshot.TotalInput = [Int64]$aggregate.TotalInput
        $snapshot.TotalCached = [Int64]$aggregate.TotalCached
        $snapshot.TotalOutput = [Int64]$aggregate.TotalOutput
        $snapshot.TotalReasoning = [Int64]$aggregate.TotalReasoning
        $snapshot.InputCost = $inputCost
        $snapshot.CachedCost = $cachedCost
        $snapshot.OutputCost = $outputCost
        $snapshot.PricingComplete = ($unknownModels.Count -eq 0)
        $snapshot.ModelDisplay = if ($models.Count -eq 0) { '无调用' } elseif ($models.Count -eq 1) { [string]$models[0] } else { '{0} 个模型' -f $models.Count }
        $snapshot.Models = $models -join [char]0x1F
        $snapshot.RawEvents = [Int64]$aggregate.RawEvents
        $snapshot.CountedEvents = [Int64]$aggregate.CountedEvents
        $snapshot.DuplicateEventsDropped = [Int64]$aggregate.DuplicateEventsDropped
        $snapshot.InheritedEventsDropped = [Int64]$aggregate.InheritedEventsDropped
        $snapshot.ProcessedRows = [Int64]$aggregate.ProcessedRows
        $snapshot.CacheCreationTokens = [Int64]$aggregate.CacheCreationTokens
        $snapshot.CacheWriteObservable = [bool]$aggregate.CacheWriteObservable
        $snapshot.StandardContextEvents = [Int64]$aggregate.StandardContextEvents
        $snapshot.LongContextEvents = [Int64]$aggregate.LongContextEvents
        $snapshot.StandardContextInput = [Int64]$aggregate.StandardContextInput
        $snapshot.LongContextInput = [Int64]$aggregate.LongContextInput
        $snapshot.LongContextOutput = [Int64]$aggregate.LongContextOutput
        $snapshot.LongContextExtraCost = $longContextExtraCost
        $modelSnapshots = foreach ($modelTotal in @($modelTotals.Values | Sort-Object Model)) {
            $modelSnapshot = New-Object TokenRaderUsageHistoryModelSnapshot
            $modelSnapshot.Model = [string]$modelTotal.Model
            # A running desktop process may still hold the previous DLL until
            # restart; old aggregate objects contain only unobserved tiers.
            if ($null -ne $modelSnapshot.PSObject.Properties['ServiceTier']) {
                $modelSnapshot.ServiceTier = [string]$modelTotal.ServiceTier
            }
            $modelSnapshot.TotalInput = [Int64]$modelTotal.TotalInput
            $modelSnapshot.TotalCached = [Int64]$modelTotal.TotalCached
            $modelSnapshot.TotalOutput = [Int64]$modelTotal.TotalOutput
            $modelSnapshot.TotalReasoning = [Int64]$modelTotal.TotalReasoning
            $modelSnapshot.InputCost = [double]$modelTotal.InputCost
            $modelSnapshot.CachedCost = [double]$modelTotal.CachedCost
            $modelSnapshot.OutputCost = [double]$modelTotal.OutputCost
            $modelSnapshot.PricingComplete = [bool]$modelTotal.PricingComplete
            $modelSnapshot.Events = [Int64]$modelTotal.Events
            $modelSnapshot.CacheCreationTokens = [Int64]$modelTotal.CacheCreationTokens
            $modelSnapshot.CacheWriteObservable = [bool]$modelTotal.CacheWriteObservable
            $modelSnapshot.StandardContextEvents = [Int64]$modelTotal.StandardContextEvents
            $modelSnapshot.LongContextEvents = [Int64]$modelTotal.LongContextEvents
            $modelSnapshot.StandardContextInput = [Int64]$modelTotal.StandardContextInput
            $modelSnapshot.LongContextInput = [Int64]$modelTotal.LongContextInput
            $modelSnapshot.LongContextOutput = [Int64]$modelTotal.LongContextOutput
            $modelSnapshot
        }
        $snapshot.ModelBreakdown = [TokenRaderUsageHistoryModelSnapshot[]]@($modelSnapshots)
        [TokenRaderIndexer]::SaveUsageHistorySnapshot($index.Connection, $snapshot)
        $freshResult = ConvertFrom-TokenRaderUsageHistorySnapshot -Snapshot $snapshot -FromCache $false
        return Add-TokenRaderToolUsageToHistoryResult -Result $freshResult -Connection $index.Connection
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

function Get-TokenRaderToolBackfillStatus {
    param([Parameter(Mandatory = $true)][string]$SessionsRoot)
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $version = [string][TokenRaderIndexer]::GetSetting($index.Connection, 'tool_metadata_backfill_version')
    $completedAt = [string][TokenRaderIndexer]::GetSetting($index.Connection, 'tool_metadata_backfill_completed_at')
    [pscustomobject]@{
        Completed = $version -eq '1'
        Version = $version
        CompletedAt = $completedAt
    }
}

function Invoke-TokenRaderToolBackfill {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [ValidateRange(1, 7)][int]$Days = 7,
        [switch]$Force,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [hashtable]$ProgressState = $null
    )
    $index = Sync-TokenRaderMeasurementBoundary -SessionsRoot $SessionsRoot -ProgressState $ProgressState -TimeoutSeconds 25
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$index.DbPath + '.lock'), 10000)
    try {
        $currentVersion = [string][TokenRaderIndexer]::GetSetting($index.Connection, 'tool_metadata_backfill_version')
        if (-not $Force -and $currentVersion -eq '1') {
            return [pscustomobject]@{
                AlreadyCompleted = $true
                ProcessedFiles = 0
                CandidateFiles = 0
                DetectedRecords = 0L
                ScannedBytes = 0L
            }
        }
        $cutoffTicks = [Int64][DateTimeOffset]::Now.AddDays(-$Days).UtcDateTime.Ticks
        $nextRevision = [Int64][TokenRaderIndexer]::GetIndexRevision($index.Connection) + 1L
        $backfill = [TokenRaderIndexer]::BackfillRecentToolRecords(
            $index.Connection, $cutoffTicks, $nextRevision, $CancellationToken, $ProgressState)
        if ([Int64]$backfill.DetectedRecords -gt 0) {
            $index.IndexRevision = [Int64][TokenRaderIndexer]::IncrementIndexRevision($index.Connection)
        }
        $completedAt = [DateTimeOffset]::Now.ToString('o')
        [TokenRaderIndexer]::SetSetting($index.Connection, 'tool_metadata_backfill_version', '1')
        [TokenRaderIndexer]::SetSetting($index.Connection, 'tool_metadata_backfill_completed_at', $completedAt)
        [pscustomobject]@{
            AlreadyCompleted = $false
            ProcessedFiles = [int]$backfill.ProcessedFiles
            CandidateFiles = [int]$backfill.CandidateFiles
            DetectedRecords = [Int64]$backfill.DetectedRecords
            ScannedBytes = [Int64]$backfill.ScannedBytes
            CompletedAt = $completedAt
        }
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

function Remove-TokenRaderUsageHistory {
    param(
        [Parameter(Mandatory = $true)][string]$SessionsRoot,
        [ValidateRange(1, 30)][int]$RetentionDays = 7,
        $ReferenceAt = $null
    )
    $reference = if ($null -eq $ReferenceAt) { [DateTimeOffset]::Now } else { [DateTimeOffset]$ReferenceAt }
    $index = Open-TokenRaderIndex -SessionsRoot $SessionsRoot
    $crossProcessLock = [TokenRaderIndexer]::AcquireFileLock(([string]$index.DbPath + '.lock'), 10000)
    try {
        $cutoff = [Int64]$reference.AddDays(-$RetentionDays).UtcDateTime.Ticks
        return [int][TokenRaderIndexer]::PurgeUsageHistory($index.Connection, $cutoff)
    } finally {
        if ($null -ne $crossProcessLock) { $crossProcessLock.Dispose() }
    }
}

Export-ModuleMember -Function ConvertTo-TokenRaderServiceTier, Resolve-TokenRaderServiceTierPrice
Export-ModuleMember -Function Get-TokenRaderPaths, Get-TokenRaderAccount, Get-TokenRaderSessionFiles, Get-TokenRaderSessionMetadata, Get-TokenRaderProjects, Get-TokenRaderUsageSnapshot, Get-TokenRaderLatestRateLimits, Get-TokenRaderResetIdentity, Get-TokenRaderPrices, Resolve-TokenRaderPrice, Get-TokenRaderCost, New-TokenRaderMeasurementBaseline, Get-TokenRaderIntervalResult, Get-TokenRaderProjectResult, Get-TokenRaderSessionResult, Get-TokenRaderQuotaEstimate, Get-TokenRaderSessionTreeSignature, Format-TokenRaderNumber, Format-TokenRaderUsd, Initialize-TokenRaderIndexer, Open-TokenRaderIndex, Close-TokenRaderIndex, New-TokenRaderIndex, Update-TokenRaderIndex, Clear-TokenRaderIndex, Remove-TokenRaderIndexHistory, Get-TokenRaderIndex, Get-TokenRaderIndexedSessionFiles, Get-TokenRaderIndexedProjects, Get-TokenRaderIndexRecords, ConvertFrom-TokenRaderIndexRecord, CaptureMeasurementBaseline, CaptureMeasurementEnd, QueryIntervalRecords, GetIndexRevision, Get-TokenRaderIndexedIntervalResult, Get-TokenRaderIndexedLatestRateLimits, Get-TokenRaderChangeRevision, Get-TokenRaderUsageHistoryWindow, Remove-TokenRaderUsageHistory, Get-TokenRaderToolBackfillStatus, Invoke-TokenRaderToolBackfill
