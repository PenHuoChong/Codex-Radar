using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Data;
using System.Data.SQLite;
using System.Globalization;
using System.IO;
using System.Diagnostics;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

[DataContract]
internal sealed class TokenRaderJsonUsage
{
    [DataMember(Name = "input_tokens", EmitDefaultValue = false)] public object InputTokens { get; set; }
    [DataMember(Name = "cached_input_tokens", EmitDefaultValue = false)] public object CachedInputTokens { get; set; }
    [DataMember(Name = "output_tokens", EmitDefaultValue = false)] public object OutputTokens { get; set; }
    [DataMember(Name = "reasoning_output_tokens", EmitDefaultValue = false)] public object ReasoningOutputTokens { get; set; }
    [DataMember(Name = "cache_read_tokens", EmitDefaultValue = false)] public object CacheReadTokens { get; set; }
    [DataMember(Name = "cached_tokens", EmitDefaultValue = false)] public object CachedTokens { get; set; }
    [DataMember(Name = "cache_creation_tokens", EmitDefaultValue = false)] public object CacheCreationTokens { get; set; }
    [DataMember(Name = "cache_creation_input_tokens", EmitDefaultValue = false)] public object CacheCreationInputTokens { get; set; }
    [DataMember(Name = "cache_write_tokens", EmitDefaultValue = false)] public object CacheWriteTokens { get; set; }
    [DataMember(Name = "cache_write_input_tokens", EmitDefaultValue = false)] public object CacheWriteInputTokens { get; set; }
}

[DataContract]
internal sealed class TokenRaderJsonInfo
{
    [DataMember(Name = "total_token_usage", EmitDefaultValue = false)] public TokenRaderJsonUsage TotalTokenUsage { get; set; }
    [DataMember(Name = "last_token_usage", EmitDefaultValue = false)] public TokenRaderJsonUsage LastTokenUsage { get; set; }
    [DataMember(Name = "model_context_window", EmitDefaultValue = false)] public object ModelContextWindow { get; set; }
}

[DataContract]
internal sealed class TokenRaderJsonRateWindow
{
    [DataMember(Name = "used_percent", EmitDefaultValue = false)] public object UsedPercent { get; set; }
    [DataMember(Name = "window_minutes", EmitDefaultValue = false)] public object WindowMinutes { get; set; }
    [DataMember(Name = "resets_at", EmitDefaultValue = false)] public object ResetsAt { get; set; }
    [DataMember(Name = "reset_at", EmitDefaultValue = false)] public object ResetAt { get; set; }
    [DataMember(Name = "resets_in_seconds", EmitDefaultValue = false)] public object ResetsInSeconds { get; set; }
    [DataMember(Name = "used_tokens", EmitDefaultValue = false)] public object UsedTokens { get; set; }
    [DataMember(Name = "remaining_tokens", EmitDefaultValue = false)] public object RemainingTokens { get; set; }
    [DataMember(Name = "limit_tokens", EmitDefaultValue = false)] public object LimitTokens { get; set; }
}

[DataContract]
internal sealed class TokenRaderJsonCredits
{
    [DataMember(Name = "balance", EmitDefaultValue = false)] public object Balance { get; set; }
    [DataMember(Name = "has_credits", EmitDefaultValue = false)] public object HasCredits { get; set; }
    [DataMember(Name = "unlimited", EmitDefaultValue = false)] public object Unlimited { get; set; }
}

[DataContract]
internal sealed class TokenRaderJsonRateLimits
{
    [DataMember(Name = "plan_type", EmitDefaultValue = false)] public string PlanType { get; set; }
    [DataMember(Name = "primary", EmitDefaultValue = false)] public TokenRaderJsonRateWindow Primary { get; set; }
    [DataMember(Name = "secondary", EmitDefaultValue = false)] public TokenRaderJsonRateWindow Secondary { get; set; }
    [DataMember(Name = "limit_id", EmitDefaultValue = false)] public string LimitId { get; set; }
    [DataMember(Name = "limit_name", EmitDefaultValue = false)] public string LimitName { get; set; }
    [DataMember(Name = "individual_limit", EmitDefaultValue = false)] public object IndividualLimit { get; set; }
    [DataMember(Name = "rate_limit_reached_type", EmitDefaultValue = false)] public string RateLimitReachedType { get; set; }
    [DataMember(Name = "spend_control_reached", EmitDefaultValue = false)] public object SpendControlReached { get; set; }
    [DataMember(Name = "credits", EmitDefaultValue = false)] public TokenRaderJsonCredits Credits { get; set; }
}

[DataContract]
internal sealed class TokenRaderJsonPayload
{
    [DataMember(Name = "type", EmitDefaultValue = false)] public string Type { get; set; }
    [DataMember(Name = "name", EmitDefaultValue = false)] public string Name { get; set; }
    [DataMember(Name = "call_id", EmitDefaultValue = false)] public string CallId { get; set; }
    [DataMember(Name = "id", EmitDefaultValue = false)] public string Id { get; set; }
    [DataMember(Name = "status", EmitDefaultValue = false)] public string Status { get; set; }
    [DataMember(Name = "info", EmitDefaultValue = false)] public TokenRaderJsonInfo Info { get; set; }
    [DataMember(Name = "rate_limits", EmitDefaultValue = false)] public TokenRaderJsonRateLimits RateLimits { get; set; }
    [DataMember(Name = "turn_id", EmitDefaultValue = false)] public string TurnId { get; set; }
    [DataMember(Name = "request_id", EmitDefaultValue = false)] public string RequestId { get; set; }
    [DataMember(Name = "response_id", EmitDefaultValue = false)] public string ResponseId { get; set; }
}

[DataContract]
internal sealed class TokenRaderJsonRecord
{
    [DataMember(Name = "timestamp", EmitDefaultValue = false)] public object Timestamp { get; set; }
    [DataMember(Name = "type", EmitDefaultValue = false)] public string Type { get; set; }
    [DataMember(Name = "payload", EmitDefaultValue = false)] public TokenRaderJsonPayload Payload { get; set; }
}

/// <summary>区间聚合的单个模型/上下文桶；不包含价格，价格由调用方按模型一次解析。</summary>
public sealed class TokenRaderIntervalAggregateBucket
{
    public string Model { get; set; }
    /// <summary>
    /// Normalized processing tier for this bucket.  "priority" represents
    /// both Fast and Priority wire values; "default" represents Standard,
    /// Normal, and Default.  An empty value means that the log did not expose
    /// a resolvable tier (including Auto/Unknown), so callers must not guess.
    /// </summary>
    public string ServiceTier { get; set; }
    public bool ServiceTierObservable { get; set; }
    public string ServiceTierSource { get; set; }
    /// <summary>
    /// True only when the tier bucket is backed by an explicit response,
    /// service-tier, or turn-context observation. Legacy/index-inherited tier
    /// labels remain visible for diagnostics but cannot override trusted mode.
    /// </summary>
    public bool ServiceTierEvidenceComplete { get; set; }
    public bool LongContext { get; set; }
    public long Input { get; set; }
    public long Cached { get; set; }
    public long Output { get; set; }
    public long Reasoning { get; set; }
    public long Events { get; set; }
    public long CacheCreationTokens { get; set; }
    public long ModelContextWindow { get; set; }
    public long LongContextThreshold { get; set; }
    public string LongContextSource { get; set; }
    /// <summary>
    /// True when the bucket's input amount is tied to an observed request
    /// boundary. A total-only delta can span multiple calls, so it remains
    /// billable token evidence but is marked false for long-context pricing.
    /// </summary>
    public bool RequestInputObservable { get; set; }
    public bool LongContextPricingUncertain { get; set; }
    public bool CacheWriteObservable { get; set; }

    public TokenRaderIntervalAggregateBucket()
    {
        Model = "";
        ServiceTier = "";
        ServiceTierSource = "";
        LongContextSource = "";
        RequestInputObservable = true;
    }
}

/// <summary>
/// SQLite 流式区间聚合结果。结果只携带紧凑的 token 桶，不携带 DataTable 或
/// 单条记录；调用方可据此按模型及长上下文价格计算成本。
/// </summary>
public sealed class TokenRaderIntervalAggregateResult
{
    public long RawEvents { get; set; }
    public long CountedEvents { get; set; }
    public long DuplicateEventsDropped { get; set; }
    public long InheritedEventsDropped { get; set; }
    public long BytesRead { get; set; }
    public long ProcessedRows { get; set; }
    public long ProcessingMilliseconds { get; set; }
    public long TotalInput { get; set; }
    public long TotalCached { get; set; }
    public long TotalOutput { get; set; }
    public long TotalReasoning { get; set; }
    public DateTimeOffset? FirstCountedAt { get; set; }
    public DateTimeOffset? LastCountedAt { get; set; }
    public bool IdentityComplete { get; set; }
    public long StandardContextEvents { get; set; }
    public long LongContextEvents { get; set; }
    public long StandardContextInput { get; set; }
    public long LongContextInput { get; set; }
    public long LongContextOutput { get; set; }
    public double LongContextExtraCost { get; set; }
    public bool CacheWriteObservable { get; set; }
    public long CacheCreationTokens { get; set; }
    public long UnidentifiedEvents { get; set; }
    public string[] IdentitySources { get; set; }
    public int ChangedSessions { get; set; }
    public string[] Models { get; set; }
    public TokenRaderIntervalAggregateBucket[] Buckets { get; set; }
    /// <summary>
    /// True when a quota-scoped aggregate could attribute every canonical
    /// event to the requested reset cycle.  Non quota-scoped aggregates leave
    /// this true for backwards compatibility.
    /// </summary>
    public bool AttributionComplete { get; set; }
    /// <summary>Canonical events whose quota cycle could not be determined.</summary>
    public long UnattributedEvents { get; set; }
    /// <summary>Canonical events known to belong to another reset cycle.</summary>
    public long ExcludedCycleEvents { get; set; }

    public TokenRaderIntervalAggregateResult()
    {
        Models = new string[0];
        Buckets = new TokenRaderIntervalAggregateBucket[0];
        IdentitySources = new string[0];
        AttributionComplete = true;
    }
}

/// <summary>
/// Diagnostics returned by the quota calibration selector.  Rows retains the
/// historical two-row DataTable shape so existing callers can migrate without
/// materializing a second query.
/// </summary>
public sealed class TokenRaderQuotaCalibrationPairDiagnostics
{
    public DataTable Rows { get; set; }
    public string ReasonCode { get; set; }

    public TokenRaderQuotaCalibrationPairDiagnostics()
    {
        ReasonCode = "no_pair";
    }
}

/// <summary>
/// Compact per-model totals belonging to one rolling 24-hour disk snapshot.
/// </summary>
public sealed class TokenRaderUsageHistoryModelSnapshot
{
    public string Model { get; set; }
    /// <summary>Normalized processing tier for this model history row.</summary>
    public string ServiceTier { get; set; }
    public long TotalInput { get; set; }
    public long TotalCached { get; set; }
    public long TotalOutput { get; set; }
    public long TotalReasoning { get; set; }
    public double InputCost { get; set; }
    public double CachedCost { get; set; }
    public double OutputCost { get; set; }
    public bool PricingComplete { get; set; }
    public long Events { get; set; }
    // Diagnostics are persisted with the seven-day rolling history so the UI
    // can explain long-context and cache-write coverage even when a result is
    // loaded from disk rather than recomputed in memory.
    public long CacheCreationTokens { get; set; }
    public bool CacheWriteObservable { get; set; }
    public long StandardContextEvents { get; set; }
    public long LongContextEvents { get; set; }
    public long StandardContextInput { get; set; }
    public long LongContextInput { get; set; }
    public long LongContextOutput { get; set; }

    public TokenRaderUsageHistoryModelSnapshot()
    {
        Model = "";
        ServiceTier = "";
    }
}

/// <summary>
/// A single rolling 24-hour aggregate persisted in the project-local SQLite
/// database. Only compact totals are stored; prompt/response content and
/// individual calls are never copied into the history cache.
/// </summary>
public sealed class TokenRaderUsageHistorySnapshot
{
    public long WindowStartTicks { get; set; }
    public long WindowEndTicks { get; set; }
    public long ComputedAtTicks { get; set; }
    public long IndexRevision { get; set; }
    public string PricingKey { get; set; }
    public long TotalInput { get; set; }
    public long TotalCached { get; set; }
    public long TotalOutput { get; set; }
    public long TotalReasoning { get; set; }
    public double InputCost { get; set; }
    public double CachedCost { get; set; }
    public double OutputCost { get; set; }
    public bool PricingComplete { get; set; }
    public string ModelDisplay { get; set; }
    public string Models { get; set; }
    public long RawEvents { get; set; }
    public long CountedEvents { get; set; }
    public long DuplicateEventsDropped { get; set; }
    public long InheritedEventsDropped { get; set; }
    public long ProcessedRows { get; set; }
    public long CacheCreationTokens { get; set; }
    public bool CacheWriteObservable { get; set; }
    public long StandardContextEvents { get; set; }
    public long LongContextEvents { get; set; }
    public long StandardContextInput { get; set; }
    public long LongContextInput { get; set; }
    public long LongContextOutput { get; set; }
    public double LongContextExtraCost { get; set; }
    public TokenRaderUsageHistoryModelSnapshot[] ModelBreakdown { get; set; }

    public TokenRaderUsageHistorySnapshot()
    {
        PricingKey = "";
        ModelDisplay = "";
        Models = "";
        ModelBreakdown = new TokenRaderUsageHistoryModelSnapshot[0];
    }
}

/// <summary>Compact aggregate for one locally observed tool/image category.</summary>
public sealed class TokenRaderToolUsageItem
{
    public string EventKind { get; set; }
    public string ToolName { get; set; }
    public long Calls { get; set; }
    public long Completed { get; set; }
    public long Failed { get; set; }
    public long ImageCount { get; set; }

    public TokenRaderToolUsageItem()
    {
        EventKind = "";
        ToolName = "";
    }
}

/// <summary>Disk-backed tool/image totals for one rolling time window.</summary>
public sealed class TokenRaderToolUsageAggregateResult
{
    public long TotalToolCalls { get; set; }
    public long CompletedToolCalls { get; set; }
    public long FailedToolCalls { get; set; }
    public long InputImages { get; set; }
    public long GeneratedImages { get; set; }
    public long ComputerScreenshots { get; set; }
    public TokenRaderToolUsageItem[] Items { get; set; }

    public TokenRaderToolUsageAggregateResult()
    {
        Items = new TokenRaderToolUsageItem[0];
    }
}

/// <summary>One-time recent-log metadata backfill diagnostics.</summary>
public sealed class TokenRaderToolBackfillResult
{
    public int ProcessedFiles { get; set; }
    public int CandidateFiles { get; set; }
    public long DetectedRecords { get; set; }
    public long ScannedBytes { get; set; }
}

/// <summary>Missing token-model repair diagnostics.</summary>
public sealed class TokenRaderModelBackfillResult
{
    public int CandidateFiles { get; set; }
    public int ProcessedFiles { get; set; }
    public int FailedFiles { get; set; }
    public long UpdatedRows { get; set; }
    public long UnresolvedRows { get; set; }
    public bool Completed { get; set; }
    public long IndexRevision { get; set; }
    public string[] FailedSourcePaths { get; set; }

    public TokenRaderModelBackfillResult()
    {
        FailedSourcePaths = new string[0];
    }
}

/// <summary>
/// 磁盘 SQLite 索引引擎。将 Codex 会话日志（JSONL）中的 token 记录解析后
/// 写入项目 data/private/index/index.db，后续所有查询走 SQL，
/// 数据在磁盘而非内存，进程内存保持恒定。
///
/// 编译：csc /target:library /reference:System.Runtime.Serialization.dll /reference:System.Data.SQLite.dll /optimize+ ...
/// </summary>
public static class TokenRaderIndexer
{
    private enum QuotaCycleAttribution
    {
        Unattributed = 0,
        Target = 1,
        Foreign = 2
    }

    private sealed class QuotaCycleScope
    {
        public string WindowKind = "";
        public int WindowMinutes;
        public long ResetUnixSeconds;
        public long ResetMinute;
        public string PlanType = "";
        public string RateLimitId = "";
    }

    /// <summary>
    /// Finds the latest complete quota step and reports why no pair was
    /// available without a second scan.  New callers use exact plan and
    /// limit-id matching, including an explicit empty legacy bucket.
    /// </summary>
    public static TokenRaderQuotaCalibrationPairDiagnostics QueryQuotaCalibrationPairWithDiagnostics(
        SQLiteConnection db,
        IDictionary endOffsets,
        string windowKind,
        int windowMinutes,
        long resetUnixSeconds,
        string planType,
        string rateLimitId,
        double currentUsedPercent,
        DateTimeOffset currentObservedAt,
        CancellationToken cancellationToken)
    {
        return QueryQuotaCalibrationPairWithDiagnosticsInternal(db, endOffsets,
            windowKind, windowMinutes, resetUnixSeconds, planType, rateLimitId,
            currentUsedPercent, currentObservedAt, cancellationToken, true);
    }

    public static TokenRaderQuotaCalibrationPairDiagnostics QueryQuotaMeasurementCalibrationPairWithDiagnostics(
        SQLiteConnection db, IDictionary endOffsets, string windowKind,
        int windowMinutes, long resetUnixSeconds, string planType, string rateLimitId,
        double currentUsedPercent, DateTimeOffset currentObservedAt,
        CancellationToken cancellationToken, DateTimeOffset baselineObservedAt,
        double baselineUsedPercent)
    {
        return QueryQuotaCalibrationPairWithDiagnosticsInternal(db, endOffsets,
            windowKind, windowMinutes, resetUnixSeconds, planType, rateLimitId,
            currentUsedPercent, currentObservedAt, cancellationToken, true,
            true, baselineObservedAt, baselineUsedPercent);
    }

    /// <summary>
    /// Only quota-window metadata is retained here.  No prompt, response, or
    /// other private log content is read by the cycle attribution index.
    /// </summary>
    private sealed class QuotaCycleMetadata
    {
        public bool HasAny;
        public bool HasTargetWindowMetadata;
        public bool HasKnownCycle;
        public int WindowMinutes;
        public long ResetUnixSeconds;
        public string PlanType = "";
        public string RateLimitId = "";
    }

    private sealed class QuotaCycleMetadataRecord
    {
        public long Id;
        public string SessionId = "";
        public string SourcePath = "";
        public long SourceOffsetEnd;
        public DateTimeOffset ObservedAt;
        public QuotaCycleMetadata Metadata;
    }

    private sealed class QuotaCycleMetadataIndex
    {
        private Func<QuotaCycleMetadataIndex> _loader;
        private QuotaCycleMetadataIndex _loaded;
        private sealed class MetadataPrefix
        {
            public string Path;
            public QuotaCycleMetadata[] States;
            public bool[] Blocked;
        }
        private readonly Dictionary<string, MetadataPrefix> _prefixes =
            new Dictionary<string, MetadataPrefix>(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<long> _metadataIds = new HashSet<long>();
        public QuotaCycleMetadataIndex() { }
        public QuotaCycleMetadataIndex(Func<QuotaCycleMetadataIndex> loader) { _loader = loader; }
        private readonly Dictionary<string, List<QuotaCycleMetadataRecord>> _bySession =
            new Dictionary<string, List<QuotaCycleMetadataRecord>>(StringComparer.OrdinalIgnoreCase);

        public void Add(QuotaCycleMetadataRecord record)
        {
            if (record == null || string.IsNullOrWhiteSpace(record.SessionId) ||
                record.Metadata == null || !record.Metadata.HasAny) return;
            if (record.Id > 0L && !_metadataIds.Add(record.Id)) return;
            List<QuotaCycleMetadataRecord> records;
            if (!_bySession.TryGetValue(record.SessionId, out records))
            {
                records = new List<QuotaCycleMetadataRecord>();
                _bySession.Add(record.SessionId, records);
            }
            records.Add(record);
        }

        public void Sort()
        {
            foreach (List<QuotaCycleMetadataRecord> records in _bySession.Values)
            {
                records.Sort(delegate(QuotaCycleMetadataRecord left, QuotaCycleMetadataRecord right) {
                    int comparison = DateTimeOffset.Compare(
                        left.ObservedAt.ToUniversalTime(), right.ObservedAt.ToUniversalTime());
                    if (comparison != 0) return comparison;
                    comparison = StringComparer.OrdinalIgnoreCase.Compare(
                        left.SourcePath ?? "", right.SourcePath ?? "");
                    if (comparison != 0) return comparison;
                    comparison = left.SourceOffsetEnd.CompareTo(right.SourceOffsetEnd);
                    return comparison != 0 ? comparison : left.Id.CompareTo(right.Id);
                });
            }
        }

        public QuotaCycleMetadata FindPreceding(string sessionId, string sourcePath,
            long sourceOffsetEnd, long id, DateTimeOffset observedAt,
            QuotaCycleScope scope, out bool blocked)
        {
            if (_loader != null)
            {
                _loaded = _loader();
                _loader = null;
            }
            if (_loaded != null)
                return _loaded.FindPreceding(sessionId, sourcePath, sourceOffsetEnd, id, observedAt, scope, out blocked);
            blocked = false;
            List<QuotaCycleMetadataRecord> records;
            if (string.IsNullOrWhiteSpace(sessionId) ||
                !_bySession.TryGetValue(sessionId, out records) || records.Count == 0) return null;

            // Ordinary append-only sessions have monotonic time and offsets.
            // Cache their state prefixes once, then binary-search each call;
            // replaying every earlier split-window row would be quadratic.
            MetadataPrefix prefix;
            if (!_prefixes.TryGetValue(sessionId, out prefix))
            {
                bool monotonic = true;
                for (int i = 1; i < records.Count; i++)
                    if (!string.Equals(records[0].SourcePath, records[i].SourcePath, StringComparison.OrdinalIgnoreCase) ||
                        records[i].SourceOffsetEnd <= records[i - 1].SourceOffsetEnd ||
                        records[i].ObservedAt < records[i - 1].ObservedAt) { monotonic = false; break; }
                if (monotonic)
                {
                    prefix = new MetadataPrefix { Path = records[0].SourcePath,
                        States = new QuotaCycleMetadata[records.Count], Blocked = new bool[records.Count] };
                    QuotaCycleMetadata state = null; bool stateBlocked = false;
                    for (int i = 0; i < records.Count; i++)
                    {
                        ApplyMetadataState(records[i].Metadata, scope, ref state, ref stateBlocked);
                        prefix.States[i] = state; prefix.Blocked[i] = stateBlocked;
                    }
                }
                _prefixes[sessionId] = prefix;
            }
            if (prefix != null && string.Equals(prefix.Path, sourcePath, StringComparison.OrdinalIgnoreCase))
            {
                int low = 0, high = records.Count;
                while (low < high)
                {
                    int middle = low + (high - low) / 2;
                    if (IsPreceding(records[middle], sourcePath, sourceOffsetEnd, id, observedAt)) low = middle + 1;
                    else high = middle;
                }
                if (low == 0) return null;
                blocked = prefix.Blocked[low - 1];
                return prefix.States[low - 1];
            }

            // The index is sorted by the same timestamp/path/offset/id order
            // used by the C# readers.  Keep the latest eligible row without a
            // SQLite query per token event.  For one source file, byte offset
            // is authoritative in addition to timestamp: a delayed older
            // record appended at a later offset must not retroactively alter
            // the cycle of an earlier call.
            QuotaCycleMetadata active = null;
            for (int i = 0; i < records.Count; i++)
            {
                QuotaCycleMetadataRecord candidate = records[i];
                if (!IsPreceding(candidate, sourcePath, sourceOffsetEnd, id, observedAt)) continue;
                ApplyMetadataState(candidate.Metadata, scope, ref active, ref blocked);
            }
            return active;
        }

        private static void ApplyMetadataState(QuotaCycleMetadata metadata,
            QuotaCycleScope scope, ref QuotaCycleMetadata active, ref bool blocked)
        {
            if (metadata == null || !metadata.HasAny) return;
            if (metadata.HasTargetWindowMetadata)
            {
                if (metadata.HasKnownCycle)
                {
                    active = metadata;
                    blocked = false;
                }
                else
                {
                    active = null;
                    blocked = true;
                }
                return;
            }
            if (active != null &&
                ((metadata.PlanType.Length > 0 && !string.Equals(metadata.PlanType,
                    active.PlanType ?? "", StringComparison.OrdinalIgnoreCase)) ||
                 (metadata.RateLimitId.Length > 0 && !string.Equals(metadata.RateLimitId,
                    active.RateLimitId ?? "", StringComparison.OrdinalIgnoreCase))))
            {
                // A discriminator change without a target-window payload is
                // still an explicit switch; the earlier cycle cannot be
                // silently carried through it.
                active = null;
                blocked = true;
            }
        }

        private static bool IsPreceding(QuotaCycleMetadataRecord record,
            string sourcePath, long sourceOffsetEnd, long id, DateTimeOffset observedAt)
        {
            if (string.Equals(record.SourcePath ?? "", sourcePath ?? "",
                StringComparison.OrdinalIgnoreCase))
            {
                return record.SourceOffsetEnd < sourceOffsetEnd && record.ObservedAt <= observedAt;
            }
            // Offsets from different files are not comparable.  Require a
            // strictly earlier timestamp and use deterministic ordering only
            // when selecting among otherwise eligible records.
            return record.ObservedAt < observedAt;
        }

        private static int CompareMetadataRecords(QuotaCycleMetadataRecord left,
            QuotaCycleMetadataRecord right)
        {
            int comparison = DateTimeOffset.Compare(left.ObservedAt.ToUniversalTime(),
                right.ObservedAt.ToUniversalTime());
            if (comparison != 0) return comparison;
            comparison = StringComparer.OrdinalIgnoreCase.Compare(left.SourcePath ?? "",
                right.SourcePath ?? "");
            if (comparison != 0) return comparison;
            comparison = left.SourceOffsetEnd.CompareTo(right.SourceOffsetEnd);
            return comparison != 0 ? comparison : left.Id.CompareTo(right.Id);
        }
    }

    private sealed class AggregateEventCandidate
    {
        public long Id;
        public long SourceOffsetEnd;
        public string SessionId = "";
        public string RootSessionId = "";
        public string SourcePath = "";
        public string Model = "";
        public string ServiceTier = "";
        public bool ServiceTierObservable;
        public string ServiceTierSource = "";
        public DateTimeOffset EventAt;
        public bool HasTimestamp;
        public string TurnId = "";
        public string RequestId = "";
        public string ResponseId = "";
        public string IdentitySource = "";
        public long ModelContextWindow;
        public long LongContextThreshold;
        public bool LongContextApplied;
        public string LongContextSource = "";
        public long CacheCreationTokens;
        public bool CacheWriteObservable;
        public long CallInput;
        public long CallCached;
        public long CallOutput;
        public long CallReasoning;
        public bool IncludeInResult = true;
        public QuotaCycleMetadata QuotaMetadata;
        public QuotaCycleAttribution QuotaAttribution = QuotaCycleAttribution.Target;
    }

    // Cumulative snapshots are deduplicated for billing, but a later status
    // refresh can contain a stronger, actual response-tier observation. Keep
    // the first candidate reference so that observation can enrich its tier
    // without changing any usage totals, timestamps or lineage identity.
    private sealed class AggregateCumulativeSnapshotIndex
    {
        private readonly HashSet<string> _seen =
            new HashSet<string>(StringComparer.Ordinal);
        private readonly Dictionary<string, AggregateEventCandidate> _candidates =
            new Dictionary<string, AggregateEventCandidate>(StringComparer.Ordinal);

        public bool Observe(string key, string sessionId, string serviceTier, string serviceTierSource)
        {
            if (_seen.Add(key ?? "")) return true;

            AggregateEventCandidate existing;
            if (_candidates.TryGetValue(key ?? "", out existing) && existing != null &&
                string.Equals(existing.SessionId ?? "", sessionId ?? "", StringComparison.OrdinalIgnoreCase) &&
                IsStrongerServiceTierEvidence(existing.ServiceTierSource, serviceTierSource))
            {
                existing.ServiceTier = NormalizeServiceTier(serviceTier);
                existing.ServiceTierObservable = !string.IsNullOrWhiteSpace(existing.ServiceTier);
                existing.ServiceTierSource = NormalizeServiceTierSource(
                    serviceTierSource, existing.ServiceTier);
            }
            return false;
        }

        public void Register(string key, AggregateEventCandidate candidate)
        {
            if (candidate == null || !_seen.Contains(key ?? "")) return;
            string normalizedKey = key ?? "";
            AggregateEventCandidate existing;
            if (!_candidates.TryGetValue(normalizedKey, out existing) || existing == null)
                _candidates[normalizedKey] = candidate;
        }
    }

    private sealed class QuotaSnapshotCandidate
    {
        public long Id;
        public DateTimeOffset ObservedAt;
        public double UsedPercent;
    }

    private sealed class WatchState : IDisposable
    {
        public readonly ConcurrentDictionary<string, byte> ChangedPaths =
            new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);
        public readonly FileSystemWatcher Watcher;
        public long ChangeRevision;
        public int Overflowed;

        public WatchState(string root)
        {
            Watcher = new FileSystemWatcher(root, "*.jsonl");
            Watcher.IncludeSubdirectories = true;
            Watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size;
            Watcher.InternalBufferSize = 64 * 1024;
            Watcher.Changed += OnChanged;
            Watcher.Created += OnChanged;
            Watcher.Deleted += OnChanged;
            Watcher.Renamed += OnRenamed;
            Watcher.Error += OnError;
            Watcher.EnableRaisingEvents = true;
        }

        private void Enqueue(string path)
        {
            if (string.IsNullOrWhiteSpace(path) ||
                !string.Equals(Path.GetExtension(path), ".jsonl", StringComparison.OrdinalIgnoreCase)) return;
            ChangedPaths[GetCanonicalPath(path)] = 0;
            Interlocked.Increment(ref ChangeRevision);
        }

        private void OnChanged(object sender, FileSystemEventArgs args) { Enqueue(args.FullPath); }
        private void OnRenamed(object sender, RenamedEventArgs args)
        {
            Enqueue(args.OldFullPath);
            Enqueue(args.FullPath);
        }
        private void OnError(object sender, ErrorEventArgs args)
        {
            Interlocked.Exchange(ref Overflowed, 1);
            Interlocked.Increment(ref ChangeRevision);
        }

        public void Dispose()
        {
            Watcher.EnableRaisingEvents = false;
            Watcher.Changed -= OnChanged;
            Watcher.Created -= OnChanged;
            Watcher.Deleted -= OnChanged;
            Watcher.Renamed -= OnRenamed;
            Watcher.Error -= OnError;
            Watcher.Dispose();
        }
    }

    private static readonly object _watcherGate = new object();
    private static readonly Dictionary<string, WatchState> _watchers =
        new Dictionary<string, WatchState>(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, object> _indexGates =
        new ConcurrentDictionary<string, object>(StringComparer.OrdinalIgnoreCase);

    private sealed class MonitorReleaser : IDisposable
    {
        private object _gate;
        public MonitorReleaser(object gate) { _gate = gate; }
        public void Dispose()
        {
            object gate = Interlocked.Exchange(ref _gate, null);
            if (gate != null) Monitor.Exit(gate);
        }
    }

    private sealed class FileLockReleaser : IDisposable
    {
        private FileStream _stream;
        public FileLockReleaser(FileStream stream) { _stream = stream; }
        public void Dispose()
        {
            FileStream stream = Interlocked.Exchange(ref _stream, null);
            if (stream != null) stream.Dispose();
        }
    }

    /// <summary>
    /// Serializes drain/import/cursor capture sequences across PowerShell
    /// runspaces. Monitor is re-entrant, so a capture may safely call the
    /// normal update function while holding this gate.
    /// </summary>
    public static IDisposable AcquireIndexGate(string sessionsRoot)
    {
        string root = string.IsNullOrWhiteSpace(sessionsRoot)
            ? "__default__"
            : GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        object gate = _indexGates.GetOrAdd(root, delegate(string ignored) { return new object(); });
        Monitor.Enter(gate);
        return new MonitorReleaser(gate);
    }

    /// <summary>
    /// Acquires an operating-system file lock so separate Token Radar processes
    /// cannot mutate the same SQLite index concurrently. The lock file contains
    /// no data and remains reusable after a clean exit or process crash.
    /// </summary>
    public static IDisposable AcquireFileLock(string lockFilePath, int timeoutMilliseconds)
    {
        if (string.IsNullOrWhiteSpace(lockFilePath))
            throw new ArgumentException("A lock file path is required.", "lockFilePath");

        string canonical = GetCanonicalPath(lockFilePath);
        string directory = Path.GetDirectoryName(canonical);
        if (!string.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
        int timeout = Math.Max(0, timeoutMilliseconds);
        var stopwatch = Stopwatch.StartNew();
        Exception lastError = null;
        while (true)
        {
            try
            {
                var stream = new FileStream(canonical, FileMode.OpenOrCreate,
                    FileAccess.ReadWrite, FileShare.None, 1, FileOptions.WriteThrough);
                return new FileLockReleaser(stream);
            }
            catch (IOException ex)
            {
                lastError = ex;
            }
            catch (UnauthorizedAccessException ex)
            {
                lastError = ex;
            }

            if (stopwatch.ElapsedMilliseconds >= timeout)
                throw new TimeoutException("Timed out waiting for the Token Radar index lock: " + canonical, lastError);
            Thread.Sleep(25);
        }
    }

    /// <summary>为会话目录建立一次性递归变化监视；重复调用会复用现有监视器。</summary>
    public static void StartWatcher(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot) || !Directory.Exists(sessionsRoot)) return;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        lock (_watcherGate)
        {
            if (_watchers.ContainsKey(root)) return;
            _watchers[root] = new WatchState(root);
        }
    }

    /// <summary>取出并清空本批次新增、修改、删除或重命名的 JSONL 路径。</summary>
    public static string[] DrainChangedPaths(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return new string[0];
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        WatchState state;
        lock (_watcherGate) { if (!_watchers.TryGetValue(root, out state)) return new string[0]; }
        var paths = new List<string>();
        foreach (string path in state.ChangedPaths.Keys)
        {
            byte ignored;
            if (state.ChangedPaths.TryRemove(path, out ignored)) paths.Add(path);
        }
        paths.Sort(StringComparer.OrdinalIgnoreCase);
        return paths.ToArray();
    }

    /// <summary>
    /// Requeues a path after a transient read/import failure. A drained watcher
    /// notification must never disappear merely because the source file was
    /// temporarily locked or still being replaced.
    /// </summary>
    public static void RequeueChangedPath(string sessionsRoot, string path)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot) || string.IsNullOrWhiteSpace(path)) return;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        WatchState state;
        lock (_watcherGate) { if (!_watchers.TryGetValue(root, out state)) return; }
        string canonical = GetCanonicalPath(path);
        if (!string.Equals(Path.GetExtension(canonical), ".jsonl", StringComparison.OrdinalIgnoreCase)) return;
        state.ChangedPaths[canonical] = 0;
        Interlocked.Increment(ref state.ChangeRevision);
    }

    public static long GetChangeRevision(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return 0L;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        WatchState state;
        lock (_watcherGate) { if (!_watchers.TryGetValue(root, out state)) return 0L; }
        return Interlocked.Read(ref state.ChangeRevision);
    }

    public static bool IsWatcherActive(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return false;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        lock (_watcherGate) { return _watchers.ContainsKey(root); }
    }

    /// <summary>读取并清除监视器溢出标志；为 true 时调用方应完整核对目录元数据。</summary>
    public static bool ConsumeWatcherOverflow(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return false;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        WatchState state;
        lock (_watcherGate) { if (!_watchers.TryGetValue(root, out state)) return false; }
        return Interlocked.Exchange(ref state.Overflowed, 0) != 0;
    }

    public static void StopWatcher(string sessionsRoot)
    {
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return;
        string root = GetCanonicalPath(sessionsRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        WatchState state = null;
        lock (_watcherGate)
        {
            if (_watchers.TryGetValue(root, out state)) _watchers.Remove(root);
        }
        if (state != null) state.Dispose();
    }

    // ── Schema ──────────────────────────────────────────────────────────

    public static void CreateSchema(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "CREATE TABLE IF NOT EXISTS file_metadata (path TEXT PRIMARY KEY, length INTEGER NOT NULL, last_write_ticks INTEGER NOT NULL, parsed_offset INTEGER NOT NULL DEFAULT 0, session_id TEXT NOT NULL DEFAULT '', cwd TEXT NOT NULL DEFAULT '', parent_thread_id TEXT NOT NULL DEFAULT '', forked_from_id TEXT NOT NULL DEFAULT '', content_retained INTEGER NOT NULL DEFAULT 1, root_session_id TEXT NOT NULL DEFAULT '', turn_context_service_tier TEXT NOT NULL DEFAULT '', turn_context_service_tier_source TEXT NOT NULL DEFAULT '', turn_context_model TEXT NOT NULL DEFAULT '', turn_context_model_source TEXT NOT NULL DEFAULT '', turn_context_model_timestamp TEXT NOT NULL DEFAULT '', turn_context_model_timestamp_ticks INTEGER NOT NULL DEFAULT 0)";
            cmd.ExecuteNonQuery();

            // Existing installations may have a four-column file_metadata table.
            // ALTER TABLE is intentionally additive so the on-disk index remains
            // readable and existing rows retain their offsets and timestamps.
            EnsureFileMetadataColumn(db, "session_id", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "cwd", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "parent_thread_id", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "forked_from_id", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "content_retained", "INTEGER NOT NULL DEFAULT 1");
            EnsureFileMetadataColumn(db, "root_session_id", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "turn_context_service_tier", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "turn_context_service_tier_source", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "turn_context_model", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "turn_context_model_source", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "turn_context_model_timestamp", "TEXT NOT NULL DEFAULT ''");
            EnsureFileMetadataColumn(db, "turn_context_model_timestamp_ticks", "INTEGER NOT NULL DEFAULT 0");

            cmd.CommandText = "CREATE TABLE IF NOT EXISTS token_records (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, timestamp TEXT NOT NULL, model TEXT NOT NULL DEFAULT '', total_input INTEGER NOT NULL, total_cached INTEGER NOT NULL, total_output INTEGER NOT NULL, total_reasoning INTEGER NOT NULL DEFAULT 0, call_input INTEGER NOT NULL, call_cached INTEGER NOT NULL, call_output INTEGER NOT NULL, call_reasoning INTEGER NOT NULL DEFAULT 0, fingerprint TEXT NOT NULL DEFAULT '', five_hour_used REAL, five_hour_window INTEGER, five_hour_resets INTEGER, weekly_used REAL, weekly_window INTEGER, weekly_resets INTEGER, plan_type TEXT NOT NULL DEFAULT '', source_path TEXT NOT NULL DEFAULT '', source_offset_end INTEGER NOT NULL DEFAULT 0, root_session_id TEXT NOT NULL DEFAULT '', index_revision INTEGER NOT NULL DEFAULT 0, model_source TEXT NOT NULL DEFAULT '', turn_id TEXT NOT NULL DEFAULT '', request_id TEXT NOT NULL DEFAULT '', response_id TEXT NOT NULL DEFAULT '', identity_source TEXT NOT NULL DEFAULT '', service_tier TEXT NOT NULL DEFAULT '', service_tier_source TEXT NOT NULL DEFAULT '', turn_context_service_tier TEXT NOT NULL DEFAULT '', reasoning_effort TEXT NOT NULL DEFAULT '', rate_limit_id TEXT NOT NULL DEFAULT '', rate_limit_name TEXT NOT NULL DEFAULT '', credits_balance REAL, credits_has INTEGER, credits_unlimited INTEGER, five_hour_used_tokens INTEGER, five_hour_remaining_tokens INTEGER, five_hour_limit_tokens INTEGER, weekly_used_tokens INTEGER, weekly_remaining_tokens INTEGER, weekly_limit_tokens INTEGER, rate_limit_individual INTEGER, rate_limit_reached_type TEXT NOT NULL DEFAULT '', spend_control_reached INTEGER, model_context_window INTEGER, long_context_threshold INTEGER, long_context_applied INTEGER NOT NULL DEFAULT 0, long_context_source TEXT NOT NULL DEFAULT '', cache_creation_tokens INTEGER NOT NULL DEFAULT 0, cache_write_observable INTEGER NOT NULL DEFAULT 0, timestamp_ticks INTEGER NOT NULL DEFAULT 0)";
            cmd.ExecuteNonQuery();

            // New columns are additive so databases created by older builds
            // remain readable. SQLite applies the declared defaults to rows
            // already present when an ALTER TABLE is performed.
            EnsureTokenRecordColumn(db, "source_path", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "source_offset_end", "INTEGER NOT NULL DEFAULT 0");
            EnsureTokenRecordColumn(db, "root_session_id", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "index_revision", "INTEGER NOT NULL DEFAULT 0");
            EnsureTokenRecordColumn(db, "model_source", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "turn_id", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "request_id", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "response_id", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "identity_source", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "service_tier", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "service_tier_source", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "turn_context_service_tier", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "reasoning_effort", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "rate_limit_id", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "rate_limit_name", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "credits_balance", "REAL");
            EnsureTokenRecordColumn(db, "credits_has", "INTEGER");
            EnsureTokenRecordColumn(db, "credits_unlimited", "INTEGER");
            EnsureTokenRecordColumn(db, "five_hour_used_tokens", "INTEGER");
            EnsureTokenRecordColumn(db, "five_hour_remaining_tokens", "INTEGER");
            EnsureTokenRecordColumn(db, "five_hour_limit_tokens", "INTEGER");
            EnsureTokenRecordColumn(db, "weekly_used_tokens", "INTEGER");
            EnsureTokenRecordColumn(db, "weekly_remaining_tokens", "INTEGER");
            EnsureTokenRecordColumn(db, "weekly_limit_tokens", "INTEGER");
            EnsureTokenRecordColumn(db, "rate_limit_individual", "INTEGER");
            EnsureTokenRecordColumn(db, "rate_limit_reached_type", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "spend_control_reached", "INTEGER");
            EnsureTokenRecordColumn(db, "model_context_window", "INTEGER");
            EnsureTokenRecordColumn(db, "long_context_threshold", "INTEGER");
            EnsureTokenRecordColumn(db, "long_context_applied", "INTEGER NOT NULL DEFAULT 0");
            EnsureTokenRecordColumn(db, "long_context_source", "TEXT NOT NULL DEFAULT ''");
            EnsureTokenRecordColumn(db, "cache_creation_tokens", "INTEGER NOT NULL DEFAULT 0");
            EnsureTokenRecordColumn(db, "cache_write_observable", "INTEGER NOT NULL DEFAULT 0");
            EnsureTokenRecordColumn(db, "timestamp_ticks", "INTEGER NOT NULL DEFAULT 0");

            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_session ON token_records(session_id)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_timestamp ON token_records(timestamp)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_model ON token_records(model)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_source_offset ON token_records(source_path, source_offset_end)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_root_session ON token_records(root_session_id, timestamp)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_records_session_timestamp_ticks ON token_records(session_id, timestamp_ticks, id)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_file_metadata_last_write ON file_metadata(last_write_ticks)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_file_metadata_session ON file_metadata(session_id)";
            cmd.ExecuteNonQuery();

            cmd.CommandText = "CREATE TABLE IF NOT EXISTS tool_records (event_key TEXT PRIMARY KEY, call_key TEXT NOT NULL DEFAULT '', session_id TEXT NOT NULL DEFAULT '', event_ticks INTEGER NOT NULL DEFAULT 0, timestamp TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '', event_kind TEXT NOT NULL DEFAULT '', tool_name TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT '', image_count INTEGER NOT NULL DEFAULT 0, source_path TEXT NOT NULL DEFAULT '', source_offset_end INTEGER NOT NULL DEFAULT 0, root_session_id TEXT NOT NULL DEFAULT '', index_revision INTEGER NOT NULL DEFAULT 0)";
            cmd.ExecuteNonQuery();
            EnsureToolRecordColumn(db, "call_key", "TEXT NOT NULL DEFAULT ''");
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_tool_records_time ON tool_records(event_ticks)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_tool_records_kind_name ON tool_records(event_kind,tool_name,event_ticks)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_tool_records_source ON tool_records(source_path,source_offset_end)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_tool_records_call ON tool_records(call_key,event_kind,event_ticks)";
            cmd.ExecuteNonQuery();

            cmd.CommandText = "CREATE TABLE IF NOT EXISTS index_settings (key TEXT PRIMARY KEY, value TEXT)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "INSERT OR IGNORE INTO index_settings (key, value) VALUES ('IndexRevision', '0')";
            cmd.ExecuteNonQuery();

            cmd.CommandText = "CREATE TABLE IF NOT EXISTS usage_history (window_start_ticks INTEGER NOT NULL, window_end_ticks INTEGER NOT NULL, computed_at_ticks INTEGER NOT NULL, index_revision INTEGER NOT NULL, pricing_key TEXT NOT NULL DEFAULT '', total_input INTEGER NOT NULL DEFAULT 0, total_cached INTEGER NOT NULL DEFAULT 0, total_output INTEGER NOT NULL DEFAULT 0, total_reasoning INTEGER NOT NULL DEFAULT 0, input_cost REAL NOT NULL DEFAULT 0, cached_cost REAL NOT NULL DEFAULT 0, output_cost REAL NOT NULL DEFAULT 0, pricing_complete INTEGER NOT NULL DEFAULT 1, model_display TEXT NOT NULL DEFAULT '', models TEXT NOT NULL DEFAULT '', raw_events INTEGER NOT NULL DEFAULT 0, counted_events INTEGER NOT NULL DEFAULT 0, duplicate_events_dropped INTEGER NOT NULL DEFAULT 0, inherited_events_dropped INTEGER NOT NULL DEFAULT 0, processed_rows INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(window_start_ticks,window_end_ticks))";
            cmd.ExecuteNonQuery();
            EnsureUsageHistoryColumn(db, "cache_creation_tokens", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryColumn(db, "cache_write_observable", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryColumn(db, "standard_context_events", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryColumn(db, "long_context_events", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryColumn(db, "standard_context_input", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryColumn(db, "long_context_input", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryColumn(db, "long_context_output", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryColumn(db, "long_context_extra_cost", "REAL NOT NULL DEFAULT 0");
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_usage_history_end ON usage_history(window_end_ticks)";
            cmd.ExecuteNonQuery();
            cmd.CommandText = "CREATE TABLE IF NOT EXISTS usage_history_models (window_start_ticks INTEGER NOT NULL, window_end_ticks INTEGER NOT NULL, model TEXT NOT NULL DEFAULT '', service_tier TEXT NOT NULL DEFAULT '', total_input INTEGER NOT NULL DEFAULT 0, total_cached INTEGER NOT NULL DEFAULT 0, total_output INTEGER NOT NULL DEFAULT 0, total_reasoning INTEGER NOT NULL DEFAULT 0, input_cost REAL NOT NULL DEFAULT 0, cached_cost REAL NOT NULL DEFAULT 0, output_cost REAL NOT NULL DEFAULT 0, pricing_complete INTEGER NOT NULL DEFAULT 1, events INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(window_start_ticks,window_end_ticks,model,service_tier))";
            cmd.ExecuteNonQuery();
            // Existing indexes used (window_start_ticks,window_end_ticks,model)
            // as the key.  Rebuild that small history table once so two tiers
            // for one model can coexist; token rows themselves remain fully
            // additive/migratable through EnsureTokenRecordColumn above.
            EnsureUsageHistoryModelColumn(db, "cache_creation_tokens", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryModelColumn(db, "cache_write_observable", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryModelColumn(db, "standard_context_events", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryModelColumn(db, "long_context_events", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryModelColumn(db, "standard_context_input", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryModelColumn(db, "long_context_input", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryModelColumn(db, "long_context_output", "INTEGER NOT NULL DEFAULT 0");
            EnsureUsageHistoryModelColumn(db, "service_tier", "TEXT NOT NULL DEFAULT ''");
            EnsureUsageHistoryModelServiceTierKey(db);
            cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_usage_history_models_end ON usage_history_models(window_end_ticks)";
            cmd.ExecuteNonQuery();
        }
    }

    public static TokenRaderUsageHistorySnapshot GetUsageHistorySnapshot(
        SQLiteConnection db,
        long windowStartTicks,
        long windowEndTicks,
        long indexRevision,
        string pricingKey)
    {
        if (db == null) throw new ArgumentNullException("db");
        TokenRaderUsageHistorySnapshot snapshot = null;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT window_start_ticks,window_end_ticks,computed_at_ticks,index_revision,pricing_key," +
                "total_input,total_cached,total_output,total_reasoning,input_cost,cached_cost,output_cost," +
                "pricing_complete,model_display,models,raw_events,counted_events,duplicate_events_dropped," +
                "inherited_events_dropped,processed_rows,cache_creation_tokens,cache_write_observable," +
                "standard_context_events,long_context_events,standard_context_input,long_context_input,long_context_output,long_context_extra_cost FROM usage_history " +
                "WHERE window_start_ticks=@start AND window_end_ticks=@end AND index_revision=@revision AND pricing_key=@pricing LIMIT 1";
            cmd.Parameters.AddWithValue("@start", windowStartTicks);
            cmd.Parameters.AddWithValue("@end", windowEndTicks);
            cmd.Parameters.AddWithValue("@revision", indexRevision);
            cmd.Parameters.AddWithValue("@pricing", pricingKey ?? "");
            using (var reader = cmd.ExecuteReader())
            {
                if (!reader.Read()) return null;
                snapshot = ReadUsageHistorySnapshot(reader);
            }
        }
        snapshot.ModelBreakdown = ReadUsageHistoryModels(db, windowStartTicks, windowEndTicks);
        return snapshot;
    }

    public static void SaveUsageHistorySnapshot(SQLiteConnection db, TokenRaderUsageHistorySnapshot snapshot)
    {
        if (db == null) throw new ArgumentNullException("db");
        if (snapshot == null) throw new ArgumentNullException("snapshot");
        using (var tx = db.BeginTransaction())
        {
            using (var cmd = db.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText =
                    "INSERT OR REPLACE INTO usage_history " +
                    "(window_start_ticks,window_end_ticks,computed_at_ticks,index_revision,pricing_key," +
                    "total_input,total_cached,total_output,total_reasoning,input_cost,cached_cost,output_cost," +
                    "pricing_complete,model_display,models,raw_events,counted_events,duplicate_events_dropped," +
                    "inherited_events_dropped,processed_rows,cache_creation_tokens,cache_write_observable," +
                    "standard_context_events,long_context_events,standard_context_input,long_context_input,long_context_output,long_context_extra_cost) VALUES " +
                    "(@start,@end,@computed,@revision,@pricing,@input,@cached,@output,@reasoning,@input_cost," +
                    "@cached_cost,@output_cost,@complete,@model_display,@models,@raw,@counted,@duplicate,@inherited,@processed," +
                    "@cache_creation,@cache_write,@standard_events,@long_events,@standard_input,@long_input,@long_output,@long_extra_cost)";
                cmd.Parameters.AddWithValue("@start", snapshot.WindowStartTicks);
                cmd.Parameters.AddWithValue("@end", snapshot.WindowEndTicks);
                cmd.Parameters.AddWithValue("@computed", snapshot.ComputedAtTicks);
                cmd.Parameters.AddWithValue("@revision", snapshot.IndexRevision);
                cmd.Parameters.AddWithValue("@pricing", snapshot.PricingKey ?? "");
                cmd.Parameters.AddWithValue("@input", snapshot.TotalInput);
                cmd.Parameters.AddWithValue("@cached", snapshot.TotalCached);
                cmd.Parameters.AddWithValue("@output", snapshot.TotalOutput);
                cmd.Parameters.AddWithValue("@reasoning", snapshot.TotalReasoning);
                cmd.Parameters.AddWithValue("@input_cost", snapshot.InputCost);
                cmd.Parameters.AddWithValue("@cached_cost", snapshot.CachedCost);
                cmd.Parameters.AddWithValue("@output_cost", snapshot.OutputCost);
                cmd.Parameters.AddWithValue("@complete", snapshot.PricingComplete ? 1 : 0);
                cmd.Parameters.AddWithValue("@model_display", snapshot.ModelDisplay ?? "");
                cmd.Parameters.AddWithValue("@models", snapshot.Models ?? "");
                cmd.Parameters.AddWithValue("@raw", snapshot.RawEvents);
                cmd.Parameters.AddWithValue("@counted", snapshot.CountedEvents);
                cmd.Parameters.AddWithValue("@duplicate", snapshot.DuplicateEventsDropped);
                cmd.Parameters.AddWithValue("@inherited", snapshot.InheritedEventsDropped);
                cmd.Parameters.AddWithValue("@processed", snapshot.ProcessedRows);
                cmd.Parameters.AddWithValue("@cache_creation", snapshot.CacheCreationTokens);
                cmd.Parameters.AddWithValue("@cache_write", snapshot.CacheWriteObservable ? 1 : 0);
                cmd.Parameters.AddWithValue("@standard_events", snapshot.StandardContextEvents);
                cmd.Parameters.AddWithValue("@long_events", snapshot.LongContextEvents);
                cmd.Parameters.AddWithValue("@standard_input", snapshot.StandardContextInput);
                cmd.Parameters.AddWithValue("@long_input", snapshot.LongContextInput);
                cmd.Parameters.AddWithValue("@long_output", snapshot.LongContextOutput);
                cmd.Parameters.AddWithValue("@long_extra_cost", snapshot.LongContextExtraCost);
                cmd.ExecuteNonQuery();
            }
            using (var deleteModels = db.CreateCommand())
            {
                deleteModels.Transaction = tx;
                deleteModels.CommandText = "DELETE FROM usage_history_models WHERE window_start_ticks=@start AND window_end_ticks=@end";
                deleteModels.Parameters.AddWithValue("@start", snapshot.WindowStartTicks);
                deleteModels.Parameters.AddWithValue("@end", snapshot.WindowEndTicks);
                deleteModels.ExecuteNonQuery();
            }
            foreach (TokenRaderUsageHistoryModelSnapshot model in snapshot.ModelBreakdown ?? new TokenRaderUsageHistoryModelSnapshot[0])
            {
                if (model == null) continue;
                using (var modelCmd = db.CreateCommand())
                {
                    modelCmd.Transaction = tx;
                    modelCmd.CommandText =
                        "INSERT INTO usage_history_models (window_start_ticks,window_end_ticks,model,service_tier,total_input,total_cached,total_output,total_reasoning,input_cost,cached_cost,output_cost,pricing_complete,events," +
                        "cache_creation_tokens,cache_write_observable,standard_context_events,long_context_events,standard_context_input,long_context_input,long_context_output) " +
                        "VALUES (@start,@end,@model,@service_tier,@input,@cached,@output,@reasoning,@input_cost,@cached_cost,@output_cost,@complete,@events,@cache_creation,@cache_write," +
                        "@standard_events,@long_events,@standard_input,@long_input,@long_output)";
                    modelCmd.Parameters.AddWithValue("@start", snapshot.WindowStartTicks);
                    modelCmd.Parameters.AddWithValue("@end", snapshot.WindowEndTicks);
                    modelCmd.Parameters.AddWithValue("@model", model.Model ?? "");
                    modelCmd.Parameters.AddWithValue("@service_tier", NormalizeServiceTier(model.ServiceTier));
                    modelCmd.Parameters.AddWithValue("@input", model.TotalInput);
                    modelCmd.Parameters.AddWithValue("@cached", model.TotalCached);
                    modelCmd.Parameters.AddWithValue("@output", model.TotalOutput);
                    modelCmd.Parameters.AddWithValue("@reasoning", model.TotalReasoning);
                    modelCmd.Parameters.AddWithValue("@input_cost", model.InputCost);
                    modelCmd.Parameters.AddWithValue("@cached_cost", model.CachedCost);
                    modelCmd.Parameters.AddWithValue("@output_cost", model.OutputCost);
                    modelCmd.Parameters.AddWithValue("@complete", model.PricingComplete ? 1 : 0);
                    modelCmd.Parameters.AddWithValue("@events", model.Events);
                    modelCmd.Parameters.AddWithValue("@cache_creation", model.CacheCreationTokens);
                    modelCmd.Parameters.AddWithValue("@cache_write", model.CacheWriteObservable ? 1 : 0);
                    modelCmd.Parameters.AddWithValue("@standard_events", model.StandardContextEvents);
                    modelCmd.Parameters.AddWithValue("@long_events", model.LongContextEvents);
                    modelCmd.Parameters.AddWithValue("@standard_input", model.StandardContextInput);
                    modelCmd.Parameters.AddWithValue("@long_input", model.LongContextInput);
                    modelCmd.Parameters.AddWithValue("@long_output", model.LongContextOutput);
                    modelCmd.ExecuteNonQuery();
                }
            }
            tx.Commit();
        }
    }

    public static int PurgeUsageHistory(SQLiteConnection db, long cutoffWindowEndTicks)
    {
        if (db == null) throw new ArgumentNullException("db");
        using (var tx = db.BeginTransaction())
        {
            using (var toolCmd = db.CreateCommand())
            {
                toolCmd.Transaction = tx;
                toolCmd.CommandText = "DELETE FROM tool_records WHERE event_ticks < @cutoff";
                toolCmd.Parameters.AddWithValue("@cutoff", cutoffWindowEndTicks);
                toolCmd.ExecuteNonQuery();
            }
            using (var childCmd = db.CreateCommand())
            {
                childCmd.Transaction = tx;
                childCmd.CommandText = "DELETE FROM usage_history_models WHERE window_end_ticks < @cutoff";
                childCmd.Parameters.AddWithValue("@cutoff", cutoffWindowEndTicks);
                childCmd.ExecuteNonQuery();
            }
            int removed;
            using (var cmd = db.CreateCommand())
            {
                cmd.Transaction = tx;
                cmd.CommandText = "DELETE FROM usage_history WHERE window_end_ticks < @cutoff";
                cmd.Parameters.AddWithValue("@cutoff", cutoffWindowEndTicks);
                removed = cmd.ExecuteNonQuery();
            }
            tx.Commit();
            return removed;
        }
    }

    public static int GetUsageHistoryCount(SQLiteConnection db)
    {
        if (db == null) throw new ArgumentNullException("db");
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM usage_history";
            return Convert.ToInt32(cmd.ExecuteScalar(), CultureInfo.InvariantCulture);
        }
    }

    private static TokenRaderUsageHistorySnapshot ReadUsageHistorySnapshot(SQLiteDataReader reader)
    {
        return new TokenRaderUsageHistorySnapshot {
            WindowStartTicks = ReadReaderInt64(reader, 0),
            WindowEndTicks = ReadReaderInt64(reader, 1),
            ComputedAtTicks = ReadReaderInt64(reader, 2),
            IndexRevision = ReadReaderInt64(reader, 3),
            PricingKey = ReadReaderString(reader, 4),
            TotalInput = ReadReaderInt64(reader, 5),
            TotalCached = ReadReaderInt64(reader, 6),
            TotalOutput = ReadReaderInt64(reader, 7),
            TotalReasoning = ReadReaderInt64(reader, 8),
            InputCost = reader.IsDBNull(9) ? 0.0 : Convert.ToDouble(reader.GetValue(9), CultureInfo.InvariantCulture),
            CachedCost = reader.IsDBNull(10) ? 0.0 : Convert.ToDouble(reader.GetValue(10), CultureInfo.InvariantCulture),
            OutputCost = reader.IsDBNull(11) ? 0.0 : Convert.ToDouble(reader.GetValue(11), CultureInfo.InvariantCulture),
            PricingComplete = !reader.IsDBNull(12) && Convert.ToInt32(reader.GetValue(12), CultureInfo.InvariantCulture) != 0,
            ModelDisplay = ReadReaderString(reader, 13),
            Models = ReadReaderString(reader, 14),
            RawEvents = ReadReaderInt64(reader, 15),
            CountedEvents = ReadReaderInt64(reader, 16),
            DuplicateEventsDropped = ReadReaderInt64(reader, 17),
            InheritedEventsDropped = ReadReaderInt64(reader, 18),
            ProcessedRows = ReadReaderInt64(reader, 19),
            CacheCreationTokens = ReadReaderInt64(reader, 20),
            CacheWriteObservable = !reader.IsDBNull(21) && Convert.ToInt32(reader.GetValue(21), CultureInfo.InvariantCulture) != 0,
            StandardContextEvents = ReadReaderInt64(reader, 22),
            LongContextEvents = ReadReaderInt64(reader, 23),
            StandardContextInput = ReadReaderInt64(reader, 24),
            LongContextInput = ReadReaderInt64(reader, 25),
            LongContextOutput = ReadReaderInt64(reader, 26),
            LongContextExtraCost = reader.IsDBNull(27) ? 0.0 : Convert.ToDouble(reader.GetValue(27), CultureInfo.InvariantCulture)
        };
    }

    private static TokenRaderUsageHistoryModelSnapshot[] ReadUsageHistoryModels(
        SQLiteConnection db, long windowStartTicks, long windowEndTicks)
    {
        var result = new List<TokenRaderUsageHistoryModelSnapshot>();
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT model,service_tier,total_input,total_cached,total_output,total_reasoning,input_cost,cached_cost,output_cost,pricing_complete,events," +
                "cache_creation_tokens,cache_write_observable,standard_context_events,long_context_events,standard_context_input,long_context_input,long_context_output " +
                "FROM usage_history_models WHERE window_start_ticks=@start AND window_end_ticks=@end ORDER BY model ASC,service_tier ASC";
            cmd.Parameters.AddWithValue("@start", windowStartTicks);
            cmd.Parameters.AddWithValue("@end", windowEndTicks);
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    result.Add(new TokenRaderUsageHistoryModelSnapshot {
                        Model = ReadReaderString(reader, 0),
                        ServiceTier = NormalizeServiceTier(ReadReaderString(reader, 1)),
                        TotalInput = ReadReaderInt64(reader, 2),
                        TotalCached = ReadReaderInt64(reader, 3),
                        TotalOutput = ReadReaderInt64(reader, 4),
                        TotalReasoning = ReadReaderInt64(reader, 5),
                        InputCost = reader.IsDBNull(6) ? 0.0 : Convert.ToDouble(reader.GetValue(6), CultureInfo.InvariantCulture),
                        CachedCost = reader.IsDBNull(7) ? 0.0 : Convert.ToDouble(reader.GetValue(7), CultureInfo.InvariantCulture),
                        OutputCost = reader.IsDBNull(8) ? 0.0 : Convert.ToDouble(reader.GetValue(8), CultureInfo.InvariantCulture),
                        PricingComplete = !reader.IsDBNull(9) && Convert.ToInt32(reader.GetValue(9), CultureInfo.InvariantCulture) != 0,
                        Events = ReadReaderInt64(reader, 10),
                        CacheCreationTokens = ReadReaderInt64(reader, 11),
                        CacheWriteObservable = !reader.IsDBNull(12) && Convert.ToInt32(reader.GetValue(12), CultureInfo.InvariantCulture) != 0,
                        StandardContextEvents = ReadReaderInt64(reader, 13),
                        LongContextEvents = ReadReaderInt64(reader, 14),
                        StandardContextInput = ReadReaderInt64(reader, 15),
                        LongContextInput = ReadReaderInt64(reader, 16),
                        LongContextOutput = ReadReaderInt64(reader, 17)
                    });
                }
            }
        }
        return result.ToArray();
    }

    // ── Import ──────────────────────────────────────────────────────────

    private static readonly Regex _requestIdValue = new Regex(
        @"""request_id""\s*:\s*""([^""]+)""", RegexOptions.Compiled);
    private static readonly Regex _responseIdValue = new Regex(
        @"""response_id""\s*:\s*""([^""]+)""", RegexOptions.Compiled);

    private static readonly string[][] _turnContextModelPaths = new[] {
        new[] { "payload", "model" }, new[] { "model" }
    };
    private static readonly string[][] _reasoningEffortPaths = new[] {
        new[] { "payload", "reasoning_effort" },
        new[] { "payload", "info", "reasoning_effort" },
        new[] { "reasoning_effort" }
    };
    private static readonly string[][] _turnIdPaths = new[] {
        new[] { "payload", "turn_id" }, new[] { "turn_id" }
    };

    private static readonly Regex _sessionIdFromPath = new Regex(
        @"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$",
        RegexOptions.Compiled);

    private static readonly Regex _inputImageType = new Regex(
        @"""type""\s*:\s*""(?:input_image|image_url|local_image)""",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly Regex _computerScreenshotType = new Regex(
        @"""type""\s*:\s*""computer_screenshot""",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private static readonly string[][] _responseServiceTierPaths = new[] {
        new[] { "payload", "info", "response", "service_tier" },
        new[] { "payload", "response", "service_tier" },
        new[] { "response", "service_tier" }
    };

    private static readonly string[][] _serviceTierPaths = new[] {
        new[] { "payload", "info", "service_tier" },
        new[] { "payload", "service_tier" },
        new[] { "service_tier" }
    };

    /// <summary>
    /// Parses only the small event envelope needed for stateful metadata.
    /// Callers must use the returned top-level record type; a marker appearing
    /// in arbitrary prompt/response text is never treated as an event.
    /// </summary>
    private static bool TryDeserializeMetadataRecord(string line, out TokenRaderJsonRecord record)
    {
        record = null;
        if (string.IsNullOrWhiteSpace(line)) return false;
        try { record = DeserializeLogRecord(line); }
        catch { record = null; }
        return record != null && !string.IsNullOrWhiteSpace(record.Type);
    }

    private static bool TryGetMetadataString(
        string line,
        string[] path,
        out string value,
        out bool present)
    {
        value = "";
        present = false;
        string raw;
        bool isNull;
        if (!TryGetJsonStringOrNullAtPath(line, path, out raw, out isNull)) return false;
        present = true;
        value = isNull ? "" : (raw ?? "");
        return true;
    }

    private static bool TryGetTurnContextModel(
        string line,
        out string model,
        out bool present)
    {
        for (int i = 0; i < _turnContextModelPaths.Length; i++)
        {
            if (TryGetMetadataString(line, _turnContextModelPaths[i], out model, out present)) return true;
        }
        model = "";
        present = false;
        return false;
    }

    private static bool TryGetMetadataStringFromPaths(
        string line,
        string[][] paths,
        out string value,
        out bool present)
    {
        value = "";
        present = false;
        if (paths == null) return false;
        for (int i = 0; i < paths.Length; i++)
        {
            if (TryGetMetadataString(line, paths[i], out value, out present)) return true;
        }
        return false;
    }

    /// <summary>
    /// Normalizes the small set of documented wire aliases without inferring
    /// an unobserved mode.  Auto/Unknown are deliberately unresolved; other
    /// non-empty labels are retained so the caller can report unsupported
    /// pricing instead of silently charging them as Standard.
    /// </summary>
    private static string NormalizeServiceTier(string raw)
    {
        string value = (raw ?? "").Trim().ToLowerInvariant();
        if (value.Length == 0 || value == "auto" || value == "unknown") return "";
        if (value == "fast" || value == "priority") return "priority";
        if (value == "default" || value == "standard" || value == "normal") return "default";
        return value;
    }

    private static string NormalizeServiceTierSource(string source, string tier)
    {
        string normalized = (source ?? "").Trim().ToLowerInvariant();
        if (normalized.Length == 0)
            return string.IsNullOrWhiteSpace(tier) ? "missing" : "indexed";
        return normalized;
    }

    /// <summary>
    /// Selects a token row's actual response tier before falling back to the
    /// turn context.  Response fields win over service_tier fields, matching
    /// the precedence used by the API payloads across rollout versions.
    /// </summary>
    private static bool TryExtractTokenServiceTier(
        string line,
        string fallbackTier,
        string fallbackSource,
        out string tier,
        out bool observable,
        out string source)
    {
        tier = NormalizeServiceTier(fallbackTier);
        observable = !string.IsNullOrWhiteSpace(tier);
        source = NormalizeServiceTierSource(fallbackSource, tier);
        if (string.IsNullOrWhiteSpace(line) || line.IndexOf("service_tier", StringComparison.OrdinalIgnoreCase) < 0)
            return false;

        string raw;
        bool isNull;
        for (int i = 0; i < _responseServiceTierPaths.Length; i++)
        {
            if (!TryGetJsonStringOrNullAtPath(line, _responseServiceTierPaths[i], out raw, out isNull)) continue;
            tier = isNull ? "" : NormalizeServiceTier(raw);
            observable = !isNull && !string.IsNullOrWhiteSpace(tier);
            source = isNull ? "response_null" : "response";
            return true;
        }
        for (int i = 0; i < _serviceTierPaths.Length; i++)
        {
            if (!TryGetJsonStringOrNullAtPath(line, _serviceTierPaths[i], out raw, out isNull)) continue;
            tier = isNull ? "" : NormalizeServiceTier(raw);
            observable = !isNull && !string.IsNullOrWhiteSpace(tier);
            source = isNull ? "service_tier_null" : "service_tier";
            return true;
        }

        return false;
    }

    private static bool TryExtractTurnContextServiceTier(
        string line,
        out string tier,
        out bool observable,
        out string source)
    {
        tier = "";
        observable = false;
        source = "turn_context_missing";
        string raw;
        bool isNull;
        // A new turn is a fresh tier boundary.  Missing and explicit null
        // both clear the preceding context value so Fast cannot stick to a
        // later request merely because that request omitted the field.
        for (int i = 0; i < _serviceTierPaths.Length; i++)
        {
            if (!TryGetJsonStringOrNullAtPath(line, _serviceTierPaths[i], out raw, out isNull)) continue;
            tier = isNull ? "" : NormalizeServiceTier(raw);
            observable = !isNull && !string.IsNullOrWhiteSpace(tier);
            source = isNull ? "turn_context_null" : "turn_context";
            return true;
        }
        // Preserve the missing marker (rather than an inherited value) for a
        // turn_context line that has no service_tier member at all.
        return false;
    }

    private static bool TryGetJsonStringOrNullAtPath(
        string json,
        string[] path,
        out string value,
        out bool isNull)
    {
        value = "";
        isNull = false;
        if (string.IsNullOrWhiteSpace(json) || path == null || path.Length == 0) return false;
        int index = 0;
        SkipJsonWhitespace(json, ref index);
        return TryFindJsonStringOrNullAtPath(json, ref index, path, 0, out value, out isNull);
    }

    /// <summary>
    /// Tiny tolerant JSON walker used only for service-tier field paths.  The
    /// regular token deserializer remains the source of usage data; this
    /// walker exists to distinguish missing from null and to handle response
    /// fields that are intentionally not part of the stable DataContract.
    /// </summary>
    private static bool TryFindJsonStringOrNullAtPath(
        string json,
        ref int index,
        string[] path,
        int depth,
        out string value,
        out bool isNull)
    {
        value = "";
        isNull = false;
        SkipJsonWhitespace(json, ref index);
        if (index >= json.Length || json[index] != '{') return false;
        index++;
        while (index < json.Length)
        {
            SkipJsonWhitespace(json, ref index);
            if (index < json.Length && json[index] == '}') { index++; return false; }
            string key;
            if (!TryReadJsonString(json, ref index, out key)) return false;
            SkipJsonWhitespace(json, ref index);
            if (index >= json.Length || json[index] != ':') return false;
            index++;
            SkipJsonWhitespace(json, ref index);
            int valueStart = index;
            bool keyMatches = depth < path.Length &&
                string.Equals(key, path[depth], StringComparison.OrdinalIgnoreCase);
            if (keyMatches && depth == path.Length - 1)
            {
                if (index < json.Length && json[index] == 'n' &&
                    StartsWithJsonLiteral(json, index, "null"))
                {
                    index += 4;
                    isNull = true;
                    return true;
                }
                if (TryReadJsonString(json, ref index, out value))
                {
                    isNull = false;
                    return true;
                }
                // Non-string service tier values are retained as a scalar
                // diagnostic rather than being mistaken for an absent field.
                if (TryReadJsonScalar(json, ref index, out value))
                {
                    isNull = false;
                    return true;
                }
                return false;
            }
            if (keyMatches && index < json.Length && json[index] == '{')
            {
                if (TryFindJsonStringOrNullAtPath(json, ref index, path, depth + 1,
                    out value, out isNull)) return true;
                index = valueStart;
            }
            if (!SkipJsonValue(json, ref index)) return false;
            SkipJsonWhitespace(json, ref index);
            if (index < json.Length && json[index] == ',') { index++; continue; }
            if (index < json.Length && json[index] == '}') { index++; return false; }
            return false;
        }
        return false;
    }

    private static bool StartsWithJsonLiteral(string json, int index, string literal)
    {
        if (json == null || literal == null || index < 0 || index + literal.Length > json.Length) return false;
        if (!string.Equals(json.Substring(index, literal.Length), literal, StringComparison.Ordinal)) return false;
        int end = index + literal.Length;
        return end >= json.Length || json[end] == ',' || json[end] == '}' ||
            json[end] == ']' || char.IsWhiteSpace(json[end]);
    }

    private static void SkipJsonWhitespace(string json, ref int index)
    {
        while (index < json.Length && char.IsWhiteSpace(json[index])) index++;
    }

    private static bool TryReadJsonString(string json, ref int index, out string value)
    {
        value = "";
        if (json == null || index < 0 || index >= json.Length || json[index] != '"') return false;
        index++;
        var builder = new StringBuilder();
        while (index < json.Length)
        {
            char current = json[index++];
            if (current == '"')
            {
                value = builder.ToString();
                return true;
            }
            if (current != '\\')
            {
                builder.Append(current);
                continue;
            }
            if (index >= json.Length) return false;
            char escaped = json[index++];
            switch (escaped)
            {
                case '"': builder.Append('"'); break;
                case '\\': builder.Append('\\'); break;
                case '/': builder.Append('/'); break;
                case 'b': builder.Append('\b'); break;
                case 'f': builder.Append('\f'); break;
                case 'n': builder.Append('\n'); break;
                case 'r': builder.Append('\r'); break;
                case 't': builder.Append('\t'); break;
                case 'u':
                    if (index + 4 > json.Length) return false;
                    int codePoint = 0;
                    for (int i = 0; i < 4; i++)
                    {
                        int digit = HexDigit(json[index++]);
                        if (digit < 0) return false;
                        codePoint = (codePoint * 16) + digit;
                    }
                    builder.Append((char)codePoint);
                    break;
                default: builder.Append(escaped); break;
            }
        }
        return false;
    }

    private static int HexDigit(char value)
    {
        if (value >= '0' && value <= '9') return value - '0';
        if (value >= 'a' && value <= 'f') return value - 'a' + 10;
        if (value >= 'A' && value <= 'F') return value - 'A' + 10;
        return -1;
    }

    private static bool TryReadJsonScalar(string json, ref int index, out string value)
    {
        value = "";
        int start = index;
        while (index < json.Length && json[index] != ',' && json[index] != '}' &&
            json[index] != ']' && !char.IsWhiteSpace(json[index])) index++;
        if (index <= start) return false;
        value = json.Substring(start, index - start);
        return true;
    }

    private static bool SkipJsonValue(string json, ref int index)
    {
        SkipJsonWhitespace(json, ref index);
        if (index >= json.Length) return false;
        if (json[index] == '"')
        {
            string ignored;
            return TryReadJsonString(json, ref index, out ignored);
        }
        if (json[index] == '{')
        {
            index++;
            while (index < json.Length)
            {
                SkipJsonWhitespace(json, ref index);
                if (index < json.Length && json[index] == '}') { index++; return true; }
                string ignoredKey;
                if (!TryReadJsonString(json, ref index, out ignoredKey)) return false;
                SkipJsonWhitespace(json, ref index);
                if (index >= json.Length || json[index] != ':') return false;
                index++;
                if (!SkipJsonValue(json, ref index)) return false;
                SkipJsonWhitespace(json, ref index);
                if (index < json.Length && json[index] == ',') { index++; continue; }
                if (index < json.Length && json[index] == '}') { index++; return true; }
                return false;
            }
            return false;
        }
        if (json[index] == '[')
        {
            index++;
            while (index < json.Length)
            {
                SkipJsonWhitespace(json, ref index);
                if (index < json.Length && json[index] == ']') { index++; return true; }
                if (!SkipJsonValue(json, ref index)) return false;
                SkipJsonWhitespace(json, ref index);
                if (index < json.Length && json[index] == ',') { index++; continue; }
                if (index < json.Length && json[index] == ']') { index++; return true; }
                return false;
            }
            return false;
        }
        string ignoredScalar;
        return TryReadJsonScalar(json, ref index, out ignoredScalar);
    }

    private static readonly HashSet<string> _canonicalToolCallTypes =
        new HashSet<string>(new[] {
            "function_call", "custom_tool_call", "tool_call", "local_shell_call", "shell_call",
            "apply_patch_call", "web_search_call", "file_search_call", "computer_call",
            "code_interpreter_call", "image_generation_call", "mcp_call", "mcp_tool_call",
            "tool_search_call", "programmatic_tool_call"
        }, StringComparer.OrdinalIgnoreCase);

    [ThreadStatic]
    private static DataContractJsonSerializer _jsonSerializer;

    /// <summary>增量解析一个 JSONL 文件，插入 SQLite，返回新记录数。</summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset)
    {
        return ImportFile(db, filePath, startOffset, long.MaxValue, null, null, null);
    }

    /// <summary>解析指定字节边界内的 JSONL，避免并发追加越过冻结边界。</summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset)
    {
        return ImportFile(db, filePath, startOffset, endOffset, null, null, null);
    }

    /// <summary>
    /// 解析指定范围，并允许调用方显式指定任务树根会话。该重载保留
    /// 与旧索引器相同的参数顺序，index_revision 仍使用当前索引 revision。
    /// </summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset, string rootSessionId)
    {
        return ImportFile(db, filePath, startOffset, endOffset, rootSessionId, null, null);
    }

    /// <summary>
    /// 解析指定范围，并将记录标记为调用方捕获的 index revision。导入本身
    /// 不递增 revision；调用方应在导入事务成功后显式调用 IncrementIndexRevision。
    /// </summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset, string rootSessionId, long indexRevision)
    {
        return ImportFile(db, filePath, startOffset, endOffset, rootSessionId, null, (long?)indexRevision);
    }

    /// <summary>
    /// Relationship-aware overload used by the incremental indexer. Existing
    /// callers remain source compatible with the older overloads above.
    /// </summary>
    public static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset,
        string rootSessionId, string parentSessionId, long indexRevision)
    {
        return ImportFile(db, filePath, startOffset, endOffset, rootSessionId, parentSessionId, (long?)indexRevision);
    }

    /// <summary>
    /// Returns the latest trustworthy cumulative usage for an incremental
    /// session import. If the latest row has no total usage, its stored zero
    /// totals are only a placeholder for independently observable last-call
    /// usage; the baseline is invalidated until a new total is observed.
    /// </summary>
    private static bool TryGetLatestSessionCumulativeBaseline(
        SQLiteConnection db,
        string sessionId,
        string sourcePath,
        long sourceOffsetEnd,
        out long totalInput,
        out long totalCached,
        out long totalOutput,
        out long totalReasoning)
    {
        totalInput = 0L;
        totalCached = 0L;
        totalOutput = 0L;
        totalReasoning = 0L;
        if (db == null || string.IsNullOrWhiteSpace(sessionId) ||
            string.IsNullOrWhiteSpace(sourcePath) || sourceOffsetEnd <= 0L) return false;

        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT total_input,total_cached,total_output,total_reasoning,identity_source " +
                "FROM token_records WHERE session_id=@session AND source_path=@path " +
                "AND source_offset_end>0 AND source_offset_end<=@offset " +
                "ORDER BY source_offset_end DESC,id DESC LIMIT 1";
            cmd.Parameters.AddWithValue("@session", sessionId);
            cmd.Parameters.AddWithValue("@path", sourcePath);
            cmd.Parameters.AddWithValue("@offset", sourceOffsetEnd);
            using (var reader = cmd.ExecuteReader())
            {
                if (!reader.Read()) return false;
                // A last-only row is billable on its own but does not prove
                // where the cumulative stream ended. Do not let a later
                // total-only delta charge that same call a second time.
                if (IsMissingTotalIdentitySource(ReadReaderString(reader, 4)))
                    return false;
                totalInput = ReadReaderInt64(reader, 0);
                totalCached = ReadReaderInt64(reader, 1);
                totalOutput = ReadReaderInt64(reader, 2);
                totalReasoning = ReadReaderInt64(reader, 3);
                return true;
            }
        }
    }

    private static int ImportFile(SQLiteConnection db, string filePath, long startOffset, long endOffset,
        string rootSessionId, string parentSessionId, long? explicitIndexRevision)
    {
        int count = 0;
        string sessionId = ExtractSessionId(filePath);
        string effectiveRootSessionId = string.IsNullOrWhiteSpace(rootSessionId) ? sessionId : rootSessionId;
        string sourcePath = GetCanonicalPath(filePath);
        long indexRevision = explicitIndexRevision.HasValue
            ? Math.Max(0L, explicitIndexRevision.Value)
            : GetIndexRevision(db);

        // Read this before opening the import transaction: the lookup command
        // intentionally uses the connection's normal transaction context.
        // A child can be imported after its parent has advanced further, so
        // parent/root model fallback is bounded by the first event in this
        // source segment rather than blindly using the parent's latest row.
        DateTimeOffset firstImportedEventAt;
        bool hasFirstImportedEventAt = TryReadFirstEventTimestamp(
            filePath, startOffset, endOffset, out firstImportedEventAt);
        DateTimeOffset? inheritedModelCutoff = hasFirstImportedEventAt
            ? (DateTimeOffset?)firstImportedEventAt : null;
        string persistedFileModel = GetLatestFileTextColumnIncludingEmpty(
            db, sourcePath, "turn_context_model");
        string persistedFileModelSource = GetLatestFileTextColumnIncludingEmpty(
            db, sourcePath, "turn_context_model_source");
        string persistedFileModelTimestamp = GetLatestFileTextColumnIncludingEmpty(
            db, sourcePath, "turn_context_model_timestamp");
        string inheritedModelSource;
        string inheritedModel;
        if (startOffset > 0L && persistedFileModel != null &&
            !string.IsNullOrWhiteSpace(persistedFileModelSource))
        {
            // File metadata is the authoritative trailing model context.  It
            // survives a context-only chunk that has not emitted a token row.
            inheritedModel = persistedFileModel;
            inheritedModelSource = persistedFileModelSource;
        }
        else
        {
            inheritedModel = ResolveInheritedModel(db, sessionId, parentSessionId,
                effectiveRootSessionId, inheritedModelCutoff, startOffset > 0L,
                out inheritedModelSource);
        }
        string inheritedTurnId = GetLatestSessionTextColumn(db, sessionId, "turn_id");
        string persistedFileContextTier = GetLatestFileTextColumnIncludingEmpty(
            db, sourcePath, "turn_context_service_tier");
        string persistedFileContextSource = GetLatestFileTextColumnIncludingEmpty(
            db, sourcePath, "turn_context_service_tier_source");
        string persistedContextTier;
        if (persistedFileContextTier != null && !string.IsNullOrWhiteSpace(persistedFileContextSource))
        {
            // File metadata is the authoritative trailing-context snapshot;
            // unlike service_tier on the last token row it cannot be polluted
            // by a one-off response-tier override.
            persistedContextTier = persistedFileContextTier;
        }
        else
        {
            persistedContextTier = GetLatestSessionTextColumnIncludingEmpty(
                db, sessionId, "turn_context_service_tier");
        }
        // The context column is populated by tier-aware imports.  A null
        // result means an older index has no such rows, so retain the legacy
        // fallback for compatibility (those rows may require a bounded
        // source re-read/backfill to correct old token overrides).
        string inheritedServiceTier = NormalizeServiceTier(
            persistedContextTier == null
                ? GetLatestSessionTextColumn(db, sessionId, "service_tier")
                : persistedContextTier);
        string inheritedServiceTierSource = string.IsNullOrWhiteSpace(inheritedServiceTier)
            ? "" : "inherited_index";
        if (startOffset <= 0L)
        {
            // A replacement/full import starts a new source history.  Do not
            // carry a tier snapshot from the deleted/truncated incarnation
            // of the same session into a file whose context is absent.
            inheritedServiceTier = "";
            inheritedServiceTierSource = "";
        }
        string inheritedReasoningEffort = GetLatestSessionTextColumn(db, sessionId, "reasoning_effort");
        if (startOffset <= 0L)
        {
            // A replacement/full import starts a new source history. Do not
            // carry turn identity or reasoning metadata from the truncated
            // incarnation into its first token.
            inheritedTurnId = "";
            inheritedReasoningEffort = "";
        }
        long previousTotalInput = 0L;
        long previousTotalCached = 0L;
        long previousTotalOutput = 0L;
        long previousTotalReasoning = 0L;
        bool hasPreviousTotal = startOffset > 0L &&
            TryGetLatestSessionCumulativeBaseline(db, sessionId, sourcePath, startOffset,
                out previousTotalInput, out previousTotalCached,
                out previousTotalOutput, out previousTotalReasoning);
        bool insertedUnresolvedModel = false;

        using (var tx = db.BeginTransaction())
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "INSERT INTO token_records (session_id, timestamp, model, total_input, total_cached, total_output, total_reasoning, call_input, call_cached, call_output, call_reasoning, fingerprint, five_hour_used, five_hour_window, five_hour_resets, weekly_used, weekly_window, weekly_resets, plan_type, source_path, source_offset_end, root_session_id, index_revision, model_source, turn_id, request_id, response_id, identity_source, service_tier, service_tier_source, turn_context_service_tier, reasoning_effort, rate_limit_id, rate_limit_name, credits_balance, credits_has, credits_unlimited, five_hour_used_tokens, five_hour_remaining_tokens, five_hour_limit_tokens, weekly_used_tokens, weekly_remaining_tokens, weekly_limit_tokens, rate_limit_individual, rate_limit_reached_type, spend_control_reached, model_context_window, long_context_threshold, long_context_applied, long_context_source, cache_creation_tokens, cache_write_observable) VALUES (@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9,@p10,@p11,@p12,@p13,@p14,@p15,@p16,@p17,@p18,@p19,@p20,@p21,@p22,@p23,@p24,@p25,@p26,@p27,@p28,@p29,@p30,@p31,@p32,@p33,@p34,@p35,@p36,@p37,@p38,@p39,@p40,@p41,@p42,@p43,@p44,@p45,@p46,@p47,@p48,@p49,@p50,@p51,@p52)";
            var p = new SQLiteParameter[52];
            for (int i = 0; i < p.Length; i++)
            {
                var prm = new SQLiteParameter("@p" + (i + 1));
                cmd.Parameters.Add(prm);
                p[i] = prm;
            }

            using (var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                long safeStart = Math.Max(0L, startOffset);
                long requestedEnd = endOffset < 0L ? 0L : endOffset;
                long effectiveEnd = Math.Min(fs.Length, requestedEnd);
                if (safeStart >= effectiveEnd) { tx.Commit(); return 0; }

                string currentModel = inheritedModel;
                string currentModelSource = inheritedModelSource;
                string currentModelContextTimestamp = startOffset > 0L
                    ? (persistedFileModelTimestamp ?? "") : "";
                string currentTurnId = inheritedTurnId;
                string currentServiceTier = inheritedServiceTier;
                string currentServiceTierSource = inheritedServiceTierSource;
                string currentReasoningEffort = inheritedReasoningEffort;
                long currentPreviousTotalInput = previousTotalInput;
                long currentPreviousTotalCached = previousTotalCached;
                long currentPreviousTotalOutput = previousTotalOutput;
                long currentPreviousTotalReasoning = previousTotalReasoning;
                bool currentHasPreviousTotal = hasPreviousTotal;

                bool skipPartialLine = false;
                if (safeStart > 0L)
                {
                    fs.Seek(safeStart - 1L, SeekOrigin.Begin);
                    int previousByte = fs.ReadByte();
                    skipPartialLine = previousByte != '\n' && previousByte != '\r';
                }

                // StreamReader is convenient but buffers past the current line,
                // so its BaseStream.Position cannot identify a JSONL line end.
                // The byte reader below reports the exact UTF-8 end offset,
                // including the newline, for every inserted token record.
                using (var lineReader = new Utf8JsonlLineReader(fs, safeStart, effectiveEnd))
                {
                    if (skipPartialLine)
                    {
                        string discarded; long discardedEnd; bool discardedTerminated;
                        lineReader.ReadLine(out discarded, out discardedEnd, out discardedTerminated);
                    }

                    // An incremental import starts in the middle of a JSONL file,
                    // where the preceding turn_context is not available. Inherit
                    // the latest non-empty model already indexed for this session;
                    // a later turn_context in the appended segment still wins.
                    string line; long lineEndOffset; bool lineTerminated;
                    while (lineReader.ReadLine(out line, out lineEndOffset, out lineTerminated))
                    {
                        // Match the previous importer: an unterminated final line
                        // is a still-growing JSON record and must wait for the next
                        // refresh before it can enter the index.
                        if (!lineTerminated) break;
                        if (string.IsNullOrWhiteSpace(line)) continue;
                        line = line.TrimStart('\uFEFF');

                        // Metadata state is driven only by the top-level event
                        // envelope.  Prompt/response text can mention words
                        // such as "turn_context" or "reasoning_effort" and
                        // must never clear or overwrite the current context.
                        TokenRaderJsonRecord metadataRecord = null;
                        string topLevelType = "";
                        bool metadataMarker = line.IndexOf("turn_context", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            line.IndexOf("task_started", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            line.IndexOf("item_completed", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            line.IndexOf("task_complete", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            line.IndexOf("reasoning_effort", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            line.IndexOf("turn_id", StringComparison.OrdinalIgnoreCase) >= 0;
                        if (metadataMarker && TryDeserializeMetadataRecord(line, out metadataRecord))
                            topLevelType = metadataRecord.Type ?? "";

                        bool isTurnContextLine = string.Equals(topLevelType,
                            "turn_context", StringComparison.OrdinalIgnoreCase);
                        bool isTurnBoundaryLine = isTurnContextLine ||
                            string.Equals(topLevelType, "task_started", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(topLevelType, "item_completed", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(topLevelType, "task_complete", StringComparison.OrdinalIgnoreCase);
                        if (isTurnBoundaryLine)
                        {
                            string turnId = metadataRecord == null || metadataRecord.Payload == null
                                ? "" : (metadataRecord.Payload.TurnId ?? "");
                            bool turnIdPresent;
                            string parsedTurnId;
                            if (string.IsNullOrWhiteSpace(turnId) &&
                                TryGetMetadataStringFromPaths(line, _turnIdPaths,
                                    out parsedTurnId, out turnIdPresent) &&
                                turnIdPresent)
                                turnId = parsedTurnId;
                            if (!string.IsNullOrWhiteSpace(turnId)) currentTurnId = turnId;
                        }
                        if (isTurnContextLine)
                        {
                            string contextTier;
                            bool contextObservable;
                            string contextSource;
                            // Every new turn starts a fresh tier boundary.
                            // Missing and explicit null both clear inherited
                            // Fast/priority state; only a value in this line
                            // can establish the new context tier.
                            if (TryExtractTurnContextServiceTier(line, out contextTier,
                                out contextObservable, out contextSource))
                            {
                                currentServiceTier = contextTier;
                                currentServiceTierSource = contextSource;
                            }
                            else
                            {
                                currentServiceTier = "";
                                currentServiceTierSource = "turn_context_missing";
                            }

                            string contextModel;
                            bool modelPresent;
                            if (TryGetTurnContextModel(line, out contextModel, out modelPresent))
                            {
                                currentModel = modelPresent ? (contextModel ?? "") : "";
                                currentModelSource = modelPresent && !string.IsNullOrWhiteSpace(currentModel)
                                    ? "turn_context" : "turn_context_missing";
                            }
                            else
                            {
                                currentModel = "";
                                currentModelSource = "turn_context_missing";
                            }
                            currentModelContextTimestamp = metadataRecord == null
                                ? "" : (Convert.ToString(metadataRecord.Timestamp, CultureInfo.InvariantCulture) ?? "");

                            string effort;
                            bool effortPresent;
                            currentReasoningEffort = TryGetMetadataStringFromPaths(
                                line, _reasoningEffortPaths, out effort, out effortPresent) && effortPresent
                                ? (effort ?? "") : "";
                            continue;
                        }
                        if (MightContainToolMetadata(line))
                        {
                            try
                            {
                                IndexToolMetadataLine(db, tx, line, sessionId, effectiveRootSessionId,
                                    currentModel, sourcePath, lineEndOffset, indexRevision, 0L);
                            }
                            catch
                            {
                                // Tool metadata is auxiliary. A malformed or
                                // newly introduced event shape must never stop
                                // token indexing or advance an incomplete file
                                // cursor incorrectly.
                            }
                        }
                        if (!line.Contains("token_count")) continue;

                        try
                        {
                            var record = DeserializeLogRecord(line);
                            if (record == null) continue;
                            string type = record.Type ?? "";
                            var payload = record.Payload;
                            if (payload == null) continue;
                            bool isTokenRecord = type == "token_count" ||
                                (type == "event_msg" && string.Equals(payload.Type, "token_count", StringComparison.Ordinal));
                            if (!isTokenRecord) continue;
                            var info = payload.Info;
                            if (info == null) continue;
                            var total = info.TotalTokenUsage;
                            var last = info.LastTokenUsage;
                            bool hasTotalUsage = HasAnyUsageValue(total);
                            bool hasLastUsage = HasAnyUsageValue(last);
                            if (!hasTotalUsage && !hasLastUsage) continue;

                            // A missing total is represented by zero in the
                            // legacy schema, but its provenance is retained in
                            // identity_source below.  Never turn a last-only
                            // event into a made-up cumulative total: the last
                            // call is independently observable, while its
                            // parent/child identity must remain incomplete.
                            long totalInput = hasTotalUsage ? GetInt64Value(total.InputTokens) : 0L;
                            long totalCached = hasTotalUsage ? GetCachedTokenValue(total) : 0L;
                            long totalOutput = hasTotalUsage ? GetInt64Value(total.OutputTokens) : 0L;
                            long totalReasoning = hasTotalUsage ? GetInt64Value(total.ReasoningOutputTokens) : 0L;
                            long callInput = hasLastUsage ? GetInt64Value(last.InputTokens) : 0L;
                            long callCached = hasLastUsage ? GetCachedTokenValue(last) : 0L;
                            long callOutput = hasLastUsage ? GetInt64Value(last.OutputTokens) : 0L;
                            long callReasoning = hasLastUsage ? GetInt64Value(last.ReasoningOutputTokens) : 0L;
                            bool callDerivedFromTotal = false;
                            bool resetDetected = false;
                            if (hasTotalUsage && !hasLastUsage && currentHasPreviousTotal)
                            {
                                resetDetected = totalInput < currentPreviousTotalInput ||
                                    totalCached < currentPreviousTotalCached ||
                                    totalOutput < currentPreviousTotalOutput ||
                                    totalReasoning < currentPreviousTotalReasoning;
                                if (!resetDetected)
                                {
                                    callInput = totalInput - currentPreviousTotalInput;
                                    callCached = totalCached - currentPreviousTotalCached;
                                    callOutput = totalOutput - currentPreviousTotalOutput;
                                    callReasoning = totalReasoning - currentPreviousTotalReasoning;
                                    callDerivedFromTotal = callInput > 0L || callOutput > 0L ||
                                        callReasoning > 0L;
                                }
                                else
                                {
                                    // A reset starts a new cumulative stream,
                                    // but the first post-reset total can still
                                    // include history from that stream. Keep it
                                    // as a baseline-only row until a later
                                    // total supplies an attributable delta.
                                    callInput = 0L;
                                    callCached = 0L;
                                    callOutput = 0L;
                                    callReasoning = 0L;
                                }
                            }
                            long modelContextWindow = GetInt64Value(info.ModelContextWindow);
                            long cacheCreationTokens;
                            bool cacheWriteObservable;
                            GetCacheCreationTokenValue(last, out cacheCreationTokens,
                                out cacheWriteObservable);
                            if (totalCached > totalInput) totalCached = totalInput;
                            if (callCached > callInput) callCached = callInput;

                            string recordServiceTier;
                            bool recordServiceTierObservable;
                            string recordServiceTierSource;
                            TryExtractTokenServiceTier(line, currentServiceTier,
                                currentServiceTierSource, out recordServiceTier,
                                out recordServiceTierObservable, out recordServiceTierSource);

                            string fingerprint = string.Format("{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}",
                                totalInput, totalCached, totalOutput, totalReasoning,
                                callInput, callCached, callOutput, callReasoning);
                            if (!hasTotalUsage)
                            {
                                // Keep the persisted diagnostic fingerprint
                                // visibly non-cumulative; aggregate lineage
                                // uses the explicit fallback identity below.
                                fingerprint = "missing_total|" + fingerprint;
                            }

                            double? fiveHourUsed = null; int? fiveHourWindow = null; long? fiveHourResets = null;
                            double? weeklyUsed = null; int? weeklyWindow = null; long? weeklyResets = null;
                            long? fiveHourUsedTokens = null; long? fiveHourRemainingTokens = null; long? fiveHourLimitTokens = null;
                            long? weeklyUsedTokens = null; long? weeklyRemainingTokens = null; long? weeklyLimitTokens = null;
                            string planType = "";
                            string rateLimitId = ""; string rateLimitName = "";
                            int? rateLimitIndividual = null; int? spendControlReached = null;
                            string rateLimitReachedType = "";
                            double? creditsBalance = null; int? creditsHas = null; int? creditsUnlimited = null;
                            long longContextThreshold = 0L;
                            bool longContextApplied = false;
                            string longContextSource = "missing_input";
                            if (callInput > 0L && !string.IsNullOrWhiteSpace(currentModel) && IsKnownLongContextModel(currentModel))
                            {
                                longContextThreshold = 272000L;
                                // The source records which rule was available;
                                // LongContextApplied separately records whether
                                // this particular call crossed the threshold.
                                longContextSource = "pricing_threshold";
                                longContextApplied = callInput > longContextThreshold;
                            }
                            else if (callInput <= 0L) longContextSource = "missing_input";
                            else if (string.IsNullOrWhiteSpace(currentModel)) longContextSource = "unknown_model";
                            else longContextSource = "no_threshold";
                            if (callDerivedFromTotal)
                            {
                                longContextSource = "missing_input";
                                longContextApplied = false;
                            }
                            var rateLimits = payload.RateLimits;
                            if (rateLimits != null)
                            {
                                planType = rateLimits.PlanType ?? "";
                                rateLimitId = rateLimits.LimitId ?? "";
                                rateLimitName = rateLimits.LimitName ?? "";
                                rateLimitReachedType = rateLimits.RateLimitReachedType ?? "";
                                bool parsedLimitBool;
                                if (TryGetBooleanValue(rateLimits.IndividualLimit, out parsedLimitBool)) rateLimitIndividual = parsedLimitBool ? 1 : 0;
                                if (TryGetBooleanValue(rateLimits.SpendControlReached, out parsedLimitBool)) spendControlReached = parsedLimitBool ? 1 : 0;
                                if (rateLimits.Credits != null)
                                {
                                    double parsedBalance;
                                    if (TryGetDoubleValue(rateLimits.Credits.Balance, out parsedBalance)) creditsBalance = parsedBalance;
                                    bool parsedBool;
                                    if (TryGetBooleanValue(rateLimits.Credits.HasCredits, out parsedBool)) creditsHas = parsedBool ? 1 : 0;
                                    if (TryGetBooleanValue(rateLimits.Credits.Unlimited, out parsedBool)) creditsUnlimited = parsedBool ? 1 : 0;
                                }
                                DateTimeOffset observedAt;
                                bool hasObservedAt = TryParseTimestamp(record.Timestamp, out observedAt);
                                foreach (TokenRaderJsonRateWindow win in new[] { rateLimits.Primary, rateLimits.Secondary })
                                {
                                    if (win == null) continue;
                                    double used = GetDoubleValueOrZero(win.UsedPercent);
                                    int winMin = (int)GetInt64Value(win.WindowMinutes);
                                    long resetSeconds;
                                    long? normalizedResets = TryGetResetUnixSeconds(win, hasObservedAt ? (DateTimeOffset?)observedAt : null, out resetSeconds)
                                        ? (long?)resetSeconds
                                        : null;
                                    if (winMin >= 240 && winMin <= 360)
                                    {
                                        fiveHourUsed = ClampPercent(used); fiveHourWindow = winMin; fiveHourResets = normalizedResets;
                                        fiveHourUsedTokens = GetNullableNonNegativeInt64(win.UsedTokens);
                                        fiveHourRemainingTokens = GetNullableNonNegativeInt64(win.RemainingTokens);
                                        fiveHourLimitTokens = GetNullablePositiveInt64(win.LimitTokens);
                                    }
                                    else if (winMin >= 9000 && winMin <= 11520)
                                    {
                                        weeklyUsed = ClampPercent(used); weeklyWindow = winMin; weeklyResets = normalizedResets;
                                        weeklyUsedTokens = GetNullableNonNegativeInt64(win.UsedTokens);
                                        weeklyRemainingTokens = GetNullableNonNegativeInt64(win.RemainingTokens);
                                        weeklyLimitTokens = GetNullablePositiveInt64(win.LimitTokens);
                                    }
                                }
                            }

                            string requestId = payload.RequestId ?? "";
                            string responseId = payload.ResponseId ?? "";
                            if (string.IsNullOrWhiteSpace(requestId) && line.Contains("request_id"))
                            {
                                Match requestMatch = _requestIdValue.Match(line);
                                if (requestMatch.Success) requestId = requestMatch.Groups[1].Value;
                            }
                            if (string.IsNullOrWhiteSpace(responseId) && line.Contains("response_id"))
                            {
                                Match responseMatch = _responseIdValue.Match(line);
                                if (responseMatch.Success) responseId = responseMatch.Groups[1].Value;
                            }
                            string identitySource = !string.IsNullOrWhiteSpace(requestId) ? "request_id" :
                                (!string.IsNullOrWhiteSpace(responseId) ? "response_id" :
                                (!string.IsNullOrWhiteSpace(currentTurnId) ? "turn_id" : "unresolved"));
                            if (!hasTotalUsage)
                            {
                                // Preserve the normal request/response fields
                                // for lineage matching, but make the fallback
                                // provenance explicit. Without a strong id,
                                // the source offset keeps two genuinely
                                // identical last-only calls in one session
                                // distinct; it is never presented as a real
                                // request id.
                                identitySource = "missing_total";
                                if (string.IsNullOrWhiteSpace(requestId) &&
                                    string.IsNullOrWhiteSpace(responseId))
                                    identitySource += ":" + lineEndOffset.ToString(
                                        CultureInfo.InvariantCulture);
                            }
                            else if (callDerivedFromTotal)
                            {
                                // The delta is useful token evidence, but it
                                // may combine several calls. Keep request and
                                // response fields intact while exposing that
                                // the per-call boundary (and therefore any
                                // long-context classification) is unknown.
                                identitySource = "missing_last";
                            }

                            p[0].Value = sessionId; p[1].Value = Convert.ToString(record.Timestamp, CultureInfo.InvariantCulture) ?? ""; p[2].Value = currentModel;
                            p[3].Value = totalInput; p[4].Value = totalCached; p[5].Value = totalOutput; p[6].Value = totalReasoning;
                            p[7].Value = callInput; p[8].Value = callCached; p[9].Value = callOutput; p[10].Value = callReasoning;
                            p[11].Value = fingerprint;
                            p[12].Value = (object)fiveHourUsed ?? DBNull.Value; p[13].Value = (object)fiveHourWindow ?? DBNull.Value;
                            p[14].Value = (object)fiveHourResets ?? DBNull.Value;
                            p[15].Value = (object)weeklyUsed ?? DBNull.Value; p[16].Value = (object)weeklyWindow ?? DBNull.Value;
                            p[17].Value = (object)weeklyResets ?? DBNull.Value;
                            p[18].Value = planType;
                            p[19].Value = sourcePath;
                            p[20].Value = lineEndOffset;
                            p[21].Value = effectiveRootSessionId;
                            p[22].Value = indexRevision;
                            p[23].Value = currentModelSource;
                            p[24].Value = currentTurnId ?? "";
                            p[25].Value = requestId;
                            p[26].Value = responseId;
                            p[27].Value = identitySource;
                            p[28].Value = recordServiceTier ?? "";
                            p[29].Value = recordServiceTierSource ?? "";
                            p[30].Value = currentServiceTier ?? "";
                            p[31].Value = currentReasoningEffort ?? "";
                            p[32].Value = rateLimitId;
                            p[33].Value = rateLimitName;
                            p[34].Value = (object)creditsBalance ?? DBNull.Value;
                            p[35].Value = (object)creditsHas ?? DBNull.Value;
                            p[36].Value = (object)creditsUnlimited ?? DBNull.Value;
                            p[37].Value = (object)fiveHourUsedTokens ?? DBNull.Value;
                            p[38].Value = (object)fiveHourRemainingTokens ?? DBNull.Value;
                            p[39].Value = (object)fiveHourLimitTokens ?? DBNull.Value;
                            p[40].Value = (object)weeklyUsedTokens ?? DBNull.Value;
                            p[41].Value = (object)weeklyRemainingTokens ?? DBNull.Value;
                            p[42].Value = (object)weeklyLimitTokens ?? DBNull.Value;
                            p[43].Value = (object)rateLimitIndividual ?? DBNull.Value;
                            p[44].Value = rateLimitReachedType;
                            p[45].Value = (object)spendControlReached ?? DBNull.Value;
                            p[46].Value = (object)(modelContextWindow > 0L ? (long?)modelContextWindow : null) ?? DBNull.Value;
                            p[47].Value = (object)(longContextThreshold > 0L ? (long?)longContextThreshold : null) ?? DBNull.Value;
                            p[48].Value = longContextApplied ? 1 : 0;
                            p[49].Value = longContextSource;
                            p[50].Value = cacheCreationTokens;
                            p[51].Value = cacheWriteObservable ? 1 : 0;
                            cmd.ExecuteNonQuery();
                            if (hasTotalUsage)
                            {
                                // Only a real cumulative snapshot advances
                                // the persisted delta baseline. Last-only rows
                                // remain independently billable but cannot be
                                // used to manufacture a cumulative identity.
                                currentPreviousTotalInput = totalInput;
                                currentPreviousTotalCached = totalCached;
                                currentPreviousTotalOutput = totalOutput;
                                currentPreviousTotalReasoning = totalReasoning;
                                currentHasPreviousTotal = true;
                            }
                            else if (hasLastUsage)
                            {
                                // The next trusted cumulative snapshot must be
                                // treated as a new baseline. Carrying the old
                                // total across this row would include the
                                // already-counted last-only call in its delta.
                                currentHasPreviousTotal = false;
                            }
                            if (string.IsNullOrWhiteSpace(currentModel)) insertedUnresolvedModel = true;
                            count++;
                        }
                        catch { continue; }
                    }
                }
                UpsertFileContextTier(db, tx, sourcePath, sessionId,
                    effectiveRootSessionId, effectiveEnd, currentServiceTier,
                    currentServiceTierSource);
                UpsertFileContextModel(db, tx, sourcePath, sessionId,
                    effectiveRootSessionId, effectiveEnd, currentModel,
                    currentModelSource, currentModelContextTimestamp);
            }
            tx.Commit();
        }
        if (insertedUnresolvedModel) SetSetting(db, "missing_model_backfill_version", "0");
        return count;
    }

    private static bool MightContainToolMetadata(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return false;
        return line.IndexOf("function_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("custom_tool_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("tool_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("shell_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("apply_patch_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("search_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("computer_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("code_interpreter_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("image_generation_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("mcp_call", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("input_image", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("local_image", StringComparison.OrdinalIgnoreCase) >= 0 ||
            line.IndexOf("computer_screenshot", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private static int IndexToolMetadataLine(
        SQLiteConnection db,
        SQLiteTransaction transaction,
        string line,
        string sessionId,
        string rootSessionId,
        string currentModel,
        string sourcePath,
        long sourceOffsetEnd,
        long indexRevision,
        long cutoffEventTicks)
    {
        TokenRaderJsonRecord record = DeserializeLogRecord(line);
        if (record == null) return 0;
        DateTimeOffset observedAt;
        if (!TryParseTimestamp(record.Timestamp, out observedAt)) return 0;
        long eventTicks = observedAt.UtcDateTime.Ticks;
        if (cutoffEventTicks > 0L && eventTicks < cutoffEventTicks) return 0;

        int detected = 0;
        TokenRaderJsonPayload payload = record.Payload;
        string payloadType = payload == null ? "" : (payload.Type ?? "");
        string candidateType = string.IsNullOrWhiteSpace(payloadType) ? (record.Type ?? "") : payloadType;
        if (_canonicalToolCallTypes.Contains(candidateType))
        {
            string status = NormalizeToolStatus(payload == null ? "" : payload.Status);
            string toolName = ResolveToolName(candidateType, payload == null ? "" : payload.Name);
            string eventKind = string.Equals(candidateType, "image_generation_call", StringComparison.OrdinalIgnoreCase)
                ? "image_generation"
                : "tool_call";
            string callId = payload == null ? "" : (payload.CallId ?? "");
            if (string.IsNullOrWhiteSpace(callId) && payload != null) callId = payload.Id ?? "";
            string eventKey = BuildToolSourceEventKey(sourcePath, sourceOffsetEnd, eventKind, toolName);
            int imageCount = eventKind == "image_generation" &&
                status != "failed" && status != "in_progress" ? 1 : 0;
            UpsertToolRecord(db, transaction, eventKey, callId, sessionId, eventTicks,
                observedAt.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                currentModel, eventKind, toolName, status, imageCount,
                sourcePath, sourceOffsetEnd, rootSessionId, indexRevision);
            detected++;
        }

        int inputImages = _inputImageType.Matches(line).Count;
        if (inputImages > 0)
        {
            UpsertToolRecord(db, transaction,
                BuildToolSourceEventKey(sourcePath, sourceOffsetEnd, "image_input", "image_input"),
                "", sessionId, eventTicks, observedAt.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                currentModel, "image_input", "image_input", "observed", inputImages,
                sourcePath, sourceOffsetEnd, rootSessionId, indexRevision);
            detected++;
        }

        int screenshots = _computerScreenshotType.Matches(line).Count;
        if (screenshots > 0)
        {
            UpsertToolRecord(db, transaction,
                BuildToolSourceEventKey(sourcePath, sourceOffsetEnd, "computer_screenshot", "computer_screenshot"),
                "", sessionId, eventTicks, observedAt.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture),
                currentModel, "computer_screenshot", "computer_screenshot", "observed", screenshots,
                sourcePath, sourceOffsetEnd, rootSessionId, indexRevision);
            detected++;
        }
        return detected;
    }

    private static string NormalizeToolStatus(string status)
    {
        string normalized = (status ?? "").Trim().ToLowerInvariant();
        if (normalized == "completed" || normalized == "success" || normalized == "succeeded") return "completed";
        if (normalized == "failed" || normalized == "error" || normalized == "cancelled" || normalized == "canceled") return "failed";
        if (normalized == "in_progress" || normalized == "running" || normalized == "started") return "in_progress";
        return "observed";
    }

    private static string ResolveToolName(string callType, string payloadName)
    {
        if (!string.IsNullOrWhiteSpace(payloadName)) return payloadName.Trim();
        string value = (callType ?? "tool_call").Trim().ToLowerInvariant();
        if (value.EndsWith("_call", StringComparison.Ordinal)) value = value.Substring(0, value.Length - 5);
        return value.Length == 0 ? "tool" : value;
    }

    private static string BuildToolSourceEventKey(
        string sourcePath, long sourceOffsetEnd, string eventKind, string toolName)
    {
        return "source|" + (sourcePath ?? "").ToLowerInvariant() + "|" +
            sourceOffsetEnd.ToString(CultureInfo.InvariantCulture) + "|" +
            (eventKind ?? "").ToLowerInvariant() + "|" + (toolName ?? "").ToLowerInvariant();
    }

    private static void UpsertToolRecord(
        SQLiteConnection db,
        SQLiteTransaction transaction,
        string eventKey,
        string callKey,
        string sessionId,
        long eventTicks,
        string timestamp,
        string model,
        string eventKind,
        string toolName,
        string status,
        int imageCount,
        string sourcePath,
        long sourceOffsetEnd,
        string rootSessionId,
        long indexRevision)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = transaction;
            cmd.CommandText =
                "INSERT OR REPLACE INTO tool_records (event_key,call_key,session_id,event_ticks,timestamp,model,event_kind,tool_name,status,image_count,source_path,source_offset_end,root_session_id,index_revision) " +
                "VALUES (@key,@call,@session,@ticks,@timestamp,@model,@kind,@name,@status,@images,@path,@offset,@root,@revision)";
            cmd.Parameters.AddWithValue("@key", eventKey ?? "");
            cmd.Parameters.AddWithValue("@call", callKey ?? "");
            cmd.Parameters.AddWithValue("@session", sessionId ?? "");
            cmd.Parameters.AddWithValue("@ticks", eventTicks);
            cmd.Parameters.AddWithValue("@timestamp", timestamp ?? "");
            cmd.Parameters.AddWithValue("@model", model ?? "");
            cmd.Parameters.AddWithValue("@kind", eventKind ?? "");
            cmd.Parameters.AddWithValue("@name", toolName ?? "");
            cmd.Parameters.AddWithValue("@status", status ?? "observed");
            cmd.Parameters.AddWithValue("@images", Math.Max(0, imageCount));
            cmd.Parameters.AddWithValue("@path", sourcePath ?? "");
            cmd.Parameters.AddWithValue("@offset", sourceOffsetEnd);
            cmd.Parameters.AddWithValue("@root", rootSessionId ?? "");
            cmd.Parameters.AddWithValue("@revision", indexRevision);
            cmd.ExecuteNonQuery();
        }
    }

    public static TokenRaderToolUsageAggregateResult AggregateToolUsage(
        SQLiteConnection db, DateTimeOffset startedAt, DateTimeOffset endedAt)
    {
        if (db == null) throw new ArgumentNullException("db");
        if (endedAt <= startedAt) throw new ArgumentException("endedAt must be later than startedAt");
        var result = new TokenRaderToolUsageAggregateResult();
        var observed = new Dictionary<string, ToolObservedRecord>(StringComparer.OrdinalIgnoreCase);
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT event_key,call_key,event_kind,tool_name,status,image_count,event_ticks " +
                "FROM tool_records WHERE event_ticks>=@start AND event_ticks<@end " +
                "ORDER BY event_ticks ASC,event_key ASC";
            cmd.Parameters.AddWithValue("@start", startedAt.UtcDateTime.Ticks);
            cmd.Parameters.AddWithValue("@end", endedAt.UtcDateTime.Ticks);
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string eventKey = ReadReaderString(reader, 0);
                    string callKey = ReadReaderString(reader, 1);
                    string kind = ReadReaderString(reader, 2);
                    string name = ReadReaderString(reader, 3);
                    string status = ReadReaderString(reader, 4);
                    long images = ReadReaderInt64(reader, 5);
                    long ticks = ReadReaderInt64(reader, 6);
                    string identity = !string.IsNullOrWhiteSpace(callKey) &&
                        (kind == "tool_call" || kind == "image_generation")
                        ? "call|" + kind + "|" + callKey
                        : eventKey;
                    ToolObservedRecord current;
                    if (!observed.TryGetValue(identity, out current))
                    {
                        observed[identity] = new ToolObservedRecord {
                            EventKind = kind, ToolName = name, Status = status,
                            ImageCount = images, EventTicks = ticks
                        };
                    }
                    else if (GetToolStatusRank(status) > GetToolStatusRank(current.Status) ||
                        (GetToolStatusRank(status) == GetToolStatusRank(current.Status) && ticks >= current.EventTicks))
                    {
                        current.EventKind = kind;
                        current.ToolName = name;
                        current.Status = status;
                        current.ImageCount = Math.Max(current.ImageCount, images);
                        current.EventTicks = ticks;
                    }
                }
            }
        }

        var grouped = new Dictionary<string, TokenRaderToolUsageItem>(StringComparer.OrdinalIgnoreCase);
        foreach (ToolObservedRecord record in observed.Values)
        {
            string groupKey = record.EventKind + "|" + record.ToolName;
            TokenRaderToolUsageItem item;
            if (!grouped.TryGetValue(groupKey, out item))
            {
                item = new TokenRaderToolUsageItem {
                    EventKind = record.EventKind,
                    ToolName = record.ToolName
                };
                grouped[groupKey] = item;
            }
            item.Calls++;
            if (record.Status == "completed") item.Completed++;
            else if (record.Status == "failed") item.Failed++;
            item.ImageCount += record.ImageCount;
        }
        var items = new List<TokenRaderToolUsageItem>(grouped.Values);
        items.Sort(delegate(TokenRaderToolUsageItem left, TokenRaderToolUsageItem right) {
            int kindComparison = StringComparer.OrdinalIgnoreCase.Compare(left.EventKind, right.EventKind);
            return kindComparison != 0 ? kindComparison : StringComparer.OrdinalIgnoreCase.Compare(left.ToolName, right.ToolName);
        });
        foreach (TokenRaderToolUsageItem item in items)
        {
            if (item.EventKind == "tool_call" || item.EventKind == "image_generation")
            {
                result.TotalToolCalls += item.Calls;
                result.CompletedToolCalls += item.Completed;
                result.FailedToolCalls += item.Failed;
            }
            if (item.EventKind == "image_input") result.InputImages += item.ImageCount;
            else if (item.EventKind == "image_generation") result.GeneratedImages += item.ImageCount;
            else if (item.EventKind == "computer_screenshot") result.ComputerScreenshots += item.ImageCount;
        }
        result.Items = items.ToArray();
        return result;
    }

    private sealed class ToolObservedRecord
    {
        public string EventKind;
        public string ToolName;
        public string Status;
        public long ImageCount;
        public long EventTicks;
    }

    private static int GetToolStatusRank(string status)
    {
        if (status == "completed" || status == "failed") return 3;
        if (status == "observed") return 2;
        if (status == "in_progress") return 1;
        return 0;
    }

    public static int GetToolRecordCount(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM tool_records";
            return Convert.ToInt32(cmd.ExecuteScalar(), CultureInfo.InvariantCulture);
        }
    }

    public static TokenRaderToolBackfillResult BackfillRecentToolRecords(
        SQLiteConnection db,
        long cutoffEventTicks,
        long indexRevision,
        CancellationToken cancellationToken,
        IDictionary progressState = null)
    {
        if (db == null) throw new ArgumentNullException("db");
        var files = new List<ToolBackfillFile>();
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT path,session_id,root_session_id FROM file_metadata " +
                "WHERE content_retained<>0 AND last_write_ticks>=@cutoff ORDER BY last_write_ticks ASC,path ASC";
            cmd.Parameters.AddWithValue("@cutoff", cutoffEventTicks);
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    files.Add(new ToolBackfillFile {
                        Path = ReadReaderString(reader, 0),
                        SessionId = ReadReaderString(reader, 1),
                        RootSessionId = ReadReaderString(reader, 2)
                    });
                }
            }
        }

        var result = new TokenRaderToolBackfillResult { CandidateFiles = files.Count };
        SetToolBackfillProgress(progressState, "扫描最近7天工具元数据", 0, files.Count, 0L);
        for (int fileIndex = 0; fileIndex < files.Count; fileIndex++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            ToolBackfillFile file = files[fileIndex];
            if (string.IsNullOrWhiteSpace(file.Path) || !File.Exists(file.Path)) continue;
            long length;
            try { length = new FileInfo(file.Path).Length; }
            catch (IOException) { continue; }
            catch (UnauthorizedAccessException) { continue; }
            string sessionId = string.IsNullOrWhiteSpace(file.SessionId) ? ExtractSessionId(file.Path) : file.SessionId;
            string rootSessionId = string.IsNullOrWhiteSpace(file.RootSessionId) ? sessionId : file.RootSessionId;
            int detectedInFile = 0;
            using (var tx = db.BeginTransaction())
            using (var stream = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var lineReader = new Utf8JsonlLineReader(stream, 0L, Math.Min(length, stream.Length)))
            {
                string currentModel = "";
                string line; long lineEndOffset; bool lineTerminated;
                while (lineReader.ReadLine(out line, out lineEndOffset, out lineTerminated))
                {
                    if (!lineTerminated) break;
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    line = line.TrimStart('\uFEFF');
                    TokenRaderJsonRecord metadataRecord;
                    if (TryDeserializeMetadataRecord(line, out metadataRecord) &&
                        string.Equals(metadataRecord.Type, "turn_context", StringComparison.OrdinalIgnoreCase))
                    {
                        string model;
                        bool modelPresent;
                        currentModel = TryGetTurnContextModel(line, out model, out modelPresent) && modelPresent
                            ? (model ?? "") : "";
                        continue;
                    }
                    if (!MightContainToolMetadata(line)) continue;
                    try
                    {
                        detectedInFile += IndexToolMetadataLine(db, tx, line, sessionId, rootSessionId,
                            currentModel, GetCanonicalPath(file.Path), lineEndOffset, indexRevision, cutoffEventTicks);
                    }
                    catch { }
                }
                tx.Commit();
            }
            result.ProcessedFiles++;
            result.DetectedRecords += detectedInFile;
            result.ScannedBytes += length;
            SetToolBackfillProgress(progressState, "扫描最近7天工具元数据",
                result.ProcessedFiles, files.Count, result.DetectedRecords);
        }
        SetToolBackfillProgress(progressState, "工具元数据回填完成",
            result.ProcessedFiles, files.Count, result.DetectedRecords);
        return result;
    }

    private sealed class ToolBackfillFile
    {
        public string Path;
        public string SessionId;
        public string RootSessionId;
    }

    private static void SetToolBackfillProgress(
        IDictionary progressState, string stage, int processedFiles, int totalFiles, long detectedRecords)
    {
        if (progressState == null) return;
        try
        {
            progressState["Stage"] = stage;
            progressState["ProcessedFiles"] = processedFiles;
            progressState["TotalFiles"] = totalFiles;
            progressState["DetectedRecords"] = detectedRecords;
            progressState["LastProgressAt"] = DateTimeOffset.Now;
        }
        catch { }
    }

    // ── Queries ─────────────────────────────────────────────────────────

    /// <summary>获取会话最新 token 快照。</summary>
    public static DataTable QuerySessionSnapshot(SQLiteConnection db, string sessionId)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT * FROM token_records WHERE session_id = @p ORDER BY timestamp DESC LIMIT 1";
            cmd.Parameters.AddWithValue("@p", sessionId);
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    /// <summary>获取时间段内全部记录。</summary>
    public static DataTable QueryTimeRange(SQLiteConnection db, string startTs, string endTs)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT * FROM token_records WHERE timestamp >= @p1 AND timestamp <= @p2 ORDER BY timestamp ASC";
            cmd.Parameters.AddWithValue("@p1", startTs); cmd.Parameters.AddWithValue("@p2", endTs);
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    /// <summary>获取指定会话列表的记录。</summary>
    public static DataTable QuerySessions(SQLiteConnection db, string[] sessionIds)
    {
        using (var cmd = db.CreateCommand())
        {
            var sb = new StringBuilder();
            for (int i = 0; i < sessionIds.Length; i++)
            {
                if (i > 0) sb.Append(',');
                string pn = "@p" + i;
                sb.Append(pn);
                cmd.Parameters.AddWithValue(pn, sessionIds[i]);
            }
            cmd.CommandText = "SELECT * FROM token_records WHERE session_id IN (" + sb + ") ORDER BY timestamp ASC";
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    // ── File metadata ───────────────────────────────────────────────────

    public static DataTable GetFileMetadata(SQLiteConnection db)
    {
        return QueryFileMetadata(db, 0L, 0);
    }

    /// <summary>
    /// 按文件最后写入时间起始截止点和最大行数查询元数据。
    /// cutoffLastWriteTicks 为 0 表示不限制时间，非零值表示只保留
    /// last_write_ticks >= cutoffLastWriteTicks 的最近文件；maximumCount
    /// 为 0 表示返回全部记录。结果按最近写入时间倒序，路径作为稳定的次序键。
    /// </summary>
    public static DataTable QueryFileMetadata(SQLiteConnection db, long cutoffLastWriteTicks, int maximumCount)
    {
        using (var cmd = db.CreateCommand())
        {
            var where = cutoffLastWriteTicks > 0L
                ? " WHERE content_retained <> 0 AND last_write_ticks >= @cutoff"
                : " WHERE content_retained <> 0";
            var limit = maximumCount > 0 ? " LIMIT @maximum" : "";
            cmd.CommandText = "SELECT * FROM file_metadata" + where + " ORDER BY last_write_ticks DESC, path ASC" + limit;
            if (cutoffLastWriteTicks > 0L) cmd.Parameters.AddWithValue("@cutoff", cutoffLastWriteTicks);
            if (maximumCount > 0) cmd.Parameters.AddWithValue("@maximum", maximumCount);
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    /// <summary>按 DateTimeOffset 截止时间查询文件元数据。</summary>
    public static DataTable QueryFileMetadata(SQLiteConnection db, DateTimeOffset cutoff, int maximumCount)
    {
        return QueryFileMetadata(db, cutoff.UtcDateTime.Ticks, maximumCount);
    }

    /// <summary>按 ISO 8601 截止时间查询文件元数据；空字符串表示不限制。</summary>
    public static DataTable QueryFileMetadata(SQLiteConnection db, string cutoff, int maximumCount)
    {
        if (string.IsNullOrWhiteSpace(cutoff)) return QueryFileMetadata(db, 0L, maximumCount);
        DateTimeOffset parsed;
        if (!DateTimeOffset.TryParse(cutoff, CultureInfo.InvariantCulture,
            DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
            out parsed)) return new DataTable();
        return QueryFileMetadata(db, parsed.UtcDateTime.Ticks, maximumCount);
    }

    /// <summary>
    /// GetFileMetadata 的带截止时间/数量兼容重载。
    /// </summary>
    public static DataTable GetFileMetadata(SQLiteConnection db, long cutoffLastWriteTicks, int maximumCount)
    {
        return QueryFileMetadata(db, cutoffLastWriteTicks, maximumCount);
    }

    public static DataTable GetFileMetadata(SQLiteConnection db, DateTimeOffset cutoff, int maximumCount)
    {
        return QueryFileMetadata(db, cutoff, maximumCount);
    }

    public static DataTable GetFileMetadata(SQLiteConnection db, string cutoff, int maximumCount)
    {
        return QueryFileMetadata(db, cutoff, maximumCount);
    }

    /// <summary>
    /// 捕获所有文件的轻量游标。即使 content_retained=0，游标也会返回，
    /// 这样调用方仍能判断源文件是否后来恢复、被截断或追加；本查询不读
    /// 源 JSONL 内容，也不删除任何历史元数据。
    /// </summary>
    public static DataTable CaptureFileCursorTable(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT path, length, last_write_ticks, parsed_offset, session_id, cwd, parent_thread_id, forked_from_id, content_retained, root_session_id FROM file_metadata ORDER BY path ASC";
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    /// <summary>
    /// Captures cursor rows only for the supplied candidate paths. Normal
    /// incremental updates usually contain 1-4 files, so this avoids copying
    /// the complete catalog into PowerShell merely to locate those rows.
    /// </summary>
    public static DataTable CaptureFileCursorTableForPaths(SQLiteConnection db, IEnumerable paths)
    {
        if (db == null) throw new ArgumentNullException("db");
        var unique = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (paths != null)
        {
            foreach (object value in paths)
            {
                string path = value == null ? "" : Convert.ToString(value, CultureInfo.InvariantCulture);
                if (!string.IsNullOrWhiteSpace(path)) unique.Add(GetCanonicalPath(path));
            }
        }

        var candidates = new List<string>(unique);
        candidates.Sort(StringComparer.OrdinalIgnoreCase);
        var result = new DataTable();
        int offset = 0;
        do
        {
            int count = Math.Min(400, candidates.Count - offset);
            using (var cmd = db.CreateCommand())
            {
                var sql = new StringBuilder(
                    "SELECT path,length,last_write_ticks,parsed_offset,session_id,cwd,parent_thread_id,forked_from_id,content_retained,root_session_id FROM file_metadata WHERE ");
                if (count <= 0)
                {
                    sql.Append("1=0");
                }
                else
                {
                    sql.Append("path IN (");
                    for (int i = 0; i < count; i++)
                    {
                        if (i > 0) sql.Append(',');
                        string parameterName = "@p" + i.ToString(CultureInfo.InvariantCulture);
                        sql.Append(parameterName);
                        cmd.Parameters.AddWithValue(parameterName, candidates[offset + i]);
                    }
                    sql.Append(')');
                }
                sql.Append(" ORDER BY path ASC");
                cmd.CommandText = sql.ToString();
                using (var adapter = new SQLiteDataAdapter(cmd)) { adapter.Fill(result); }
            }
            offset += count;
        } while (offset < candidates.Count);
        return result;
    }

    /// <summary>
    /// 以紧凑字典冻结全部 parsed_offset，供开始/结束测量使用。该路径不创建
    /// DataTable，也不把关系元数据复制到 PowerShell；数据库中的路径已经
    /// 在导入时规范化，因此可直接作为冻结边界。
    /// </summary>
    public static IDictionary CaptureFileCursorOffsets(SQLiteConnection db)
    {
        var offsets = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT path,parsed_offset FROM file_metadata WHERE path IS NOT NULL AND path<>''";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string path = reader.IsDBNull(0) ? "" : Convert.ToString(reader.GetValue(0), CultureInfo.InvariantCulture);
                    if (string.IsNullOrWhiteSpace(path)) continue;
                    offsets[path] = reader.IsDBNull(1) ? 0L : Convert.ToInt64(reader.GetValue(1), CultureInfo.InvariantCulture);
                }
            }
        }
        return offsets;
    }

    public static int GetFileCursorCount(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM file_metadata";
            object value = cmd.ExecuteScalar();
            return value == null || value == DBNull.Value ? 0 : Convert.ToInt32(value, CultureInfo.InvariantCulture);
        }
    }

    /// <summary>
    /// Performs a lightweight catalog reconciliation entirely in compiled
    /// code. Only path, length and last-write ticks are compared; JSONL content
    /// is never opened here. The result includes new, modified and deleted
    /// paths so the normal incremental importer can process only those files.
    /// </summary>
    public static string[] FindChangedFiles(SQLiteConnection db, string sessionsRoot)
    {
        if (db == null) throw new ArgumentNullException("db");
        if (string.IsNullOrWhiteSpace(sessionsRoot)) return new string[0];
        string canonicalRoot = GetCanonicalPath(sessionsRoot).TrimEnd(
            Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string rootPrefix = canonicalRoot + Path.DirectorySeparatorChar;
        string alternateRootPrefix = Path.AltDirectorySeparatorChar == Path.DirectorySeparatorChar
            ? rootPrefix
            : canonicalRoot + Path.AltDirectorySeparatorChar;
        var known = new Dictionary<string, FileCursorState>(StringComparer.OrdinalIgnoreCase);
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT path,length,last_write_ticks FROM file_metadata WHERE path IS NOT NULL AND path<>''";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string path = ReadReaderString(reader, 0);
                    // Paths are canonicalized before being stored. Comparing
                    // against the precomputed root prefix avoids thousands of
                    // redundant Path.GetFullPath calls during every boundary
                    // snapshot while still excluding metadata from another
                    // sessions root.
                    if (string.IsNullOrWhiteSpace(path) ||
                        (!path.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase) &&
                         !path.StartsWith(alternateRootPrefix, StringComparison.OrdinalIgnoreCase))) continue;
                    known[path] = new FileCursorState {
                        Length = ReadReaderInt64(reader, 1),
                        LastWriteTicks = ReadReaderInt64(reader, 2)
                    };
                }
            }
        }

        var changed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (Directory.Exists(canonicalRoot))
        {
            var pending = new Stack<DirectoryInfo>();
            pending.Push(new DirectoryInfo(canonicalRoot));
            while (pending.Count > 0)
            {
                DirectoryInfo directory = pending.Pop();
                try
                {
                    // DirectoryInfo returns FileInfo instances populated from
                    // the directory enumeration itself. Reusing Length and
                    // LastWriteTimeUtc avoids a second metadata lookup for
                    // every JSONL file.
                    foreach (FileSystemInfo entry in directory.EnumerateFileSystemInfos())
                    {
                        DirectoryInfo child = entry as DirectoryInfo;
                        if (child != null)
                        {
                            pending.Push(child);
                            continue;
                        }
                        FileInfo file = entry as FileInfo;
                        if (file == null || !file.Extension.Equals(".jsonl", StringComparison.OrdinalIgnoreCase)) continue;
                        string path = file.FullName;
                        FileCursorState cursor;
                        if (!known.TryGetValue(path, out cursor) ||
                            cursor.Length != file.Length || cursor.LastWriteTicks != file.LastWriteTimeUtc.Ticks)
                            changed.Add(path);
                        known.Remove(path);
                    }
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        // Metadata left in the map represents a file that disappeared or was
        // renamed. Candidate synchronization removes those stale rows.
        foreach (string missing in known.Keys) changed.Add(missing);
        var result = new List<string>(changed);
        result.Sort(StringComparer.OrdinalIgnoreCase);
        return result.ToArray();
    }

    private static bool IsPathWithinRoot(string path, string root)
    {
        if (string.IsNullOrWhiteSpace(path) || string.IsNullOrWhiteSpace(root)) return false;
        string canonicalPath = GetCanonicalPath(path);
        string canonicalRoot = GetCanonicalPath(root).TrimEnd(
            Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string prefix = canonicalRoot + Path.DirectorySeparatorChar;
        return canonicalPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private sealed class FileCursorState
    {
        public long Length;
        public long LastWriteTicks;
    }

    /// <summary>
    /// 查询每个文件 [start_offset,end_offset) 范围内的 token 记录。
    /// fileRanges 至少需要 path、start_offset、end_offset 三列；列名比较
    /// 不区分大小写，并兼容 StartOffset/EndOffset 等 PowerShell 常见命名。
    /// </summary>
    public static DataTable QueryIntervalRecords(SQLiteConnection db, DataTable fileRanges)
    {
        return QueryRowsByOffsetRanges(db, ReadOffsetRanges(fileRanges), false);
    }

    /// <summary>
    /// 以两个非泛型 IDictionary（PowerShell Hashtable 可直接传入）表达
    /// 每个文件的起止偏移，查询范围内全部 token 记录。
    /// </summary>
    public static DataTable QueryIntervalRecords(SQLiteConnection db, IDictionary startOffsets, IDictionary endOffsets)
    {
        return QueryRowsByOffsetRanges(db, ReadOffsetRanges(startOffsets, endOffsets), false);
    }

    /// <summary>
    /// 流式聚合每个文件的冻结字节范围。该 API 不创建 DataTable，也不将
    /// 区间内的所有记录载入内存；SQLiteDataReader 每次只保留当前行，结果
    /// 仅包含按模型/长上下文分桶后的计数。旧格式 source_offset_end=0 的
    /// 记录永远不会命中范围条件。
    ///
    /// longContextThresholds 为模型名到长上下文阈值的 IDictionary（大小写
    /// 不敏感）；阈值大于 0 且 call_input 大于阈值时归入 LongContext 桶。
    /// progressState 可选，若提供则每 256 行写入 ProcessedRows、
    /// LastProgressTicks 和 Stage，供后台 UI 显示进度。
    /// </summary>
    public static TokenRaderIntervalAggregateResult AggregateIntervalRecords(
        SQLiteConnection db,
        IDictionary startOffsets,
        IDictionary endOffsets,
        DateTimeOffset startedAt,
        IDictionary longContextThresholds,
        CancellationToken cancellationToken,
        IDictionary progressState = null)
    {
        if (db == null) throw new ArgumentNullException("db");

        var ranges = ReadAggregateOffsetRanges(startOffsets, endOffsets);
        var thresholds = ReadLongContextThresholds(longContextThresholds);
        var baselinePaths = ReadOffsetPathSet(startOffsets);
        var baselineOffsets = ReadAggregateOffsetMap(startOffsets);
        var result = new TokenRaderIntervalAggregateResult();
        var parentBySession = ReadAggregateParentMap(db);
        Dictionary<string, string> sessionByPath;
        var pathBySession = ReadAggregateSessionPathMaps(db, out sessionByPath);
        var seededAncestorSessions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var lineageGroups = new Dictionary<string, List<AggregateEventCandidate>>(StringComparer.Ordinal);
        // token_count is also emitted for status/rate-limit refreshes. Those
        // rows can carry the same cumulative total_token_usage and the same
        // last_token_usage at a later timestamp; they are snapshots of one
        // call, not additional calls. Keep a per-session cumulative identity
        // so timestamp-only refreshes cannot be billed repeatedly.
        var seenCumulativeSnapshots = new AggregateCumulativeSnapshotIndex();
        var stopwatch = Stopwatch.StartNew();

        SetAggregateProgress(progressState, 0L, "聚合区间记录");
        for (int rangeIndex = 0; rangeIndex < ranges.Count; rangeIndex++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            OffsetRange range = ranges[rangeIndex];
            SeedAggregateCumulativeSnapshot(db, range, seenCumulativeSnapshots,
                lineageGroups, parentBySession, result);
            SeedAggregateAncestorSnapshots(db, range.Path, baselineOffsets,
                pathBySession, sessionByPath, parentBySession, seededAncestorSessions,
                seenCumulativeSnapshots, lineageGroups, result);
            using (var cmd = db.CreateCommand())
            {
                // Select only columns required by the existing interval
                // semantics. No SELECT * and no SQL-side/global sort are used.
                cmd.CommandText =
                    "SELECT session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning," +
                    "call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,source_offset_end,root_session_id," +
                    "turn_id,request_id,response_id,identity_source,model_context_window,long_context_threshold,long_context_applied,long_context_source,cache_creation_tokens,cache_write_observable,service_tier,service_tier_source " +
                    "FROM token_records WHERE source_path=@path AND source_offset_end>@start AND source_offset_end<=@end " +
                    "ORDER BY source_offset_end ASC";
                cmd.Parameters.AddWithValue("@path", range.Path);
                cmd.Parameters.AddWithValue("@start", range.Start);
                cmd.Parameters.AddWithValue("@end", range.End);

                using (var reader = cmd.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        result.RawEvents++;
                        result.ProcessedRows++;
                        if ((result.ProcessedRows & 255L) == 0L)
                        {
                            cancellationToken.ThrowIfCancellationRequested();
                            SetAggregateProgress(progressState, result.ProcessedRows, "聚合区间记录");
                        }

                        string sessionId = ReadReaderString(reader, 0);
                        string timestampText = ReadReaderString(reader, 1);
                        string model = ReadReaderString(reader, 2);
                        long totalInput = ReadReaderInt64(reader, 3);
                        long totalCached = ReadReaderInt64(reader, 4);
                        long totalOutput = ReadReaderInt64(reader, 5);
                        long totalReasoning = ReadReaderInt64(reader, 6);
                        long callInput = ReadReaderInt64(reader, 7);
                        long callCached = ReadReaderInt64(reader, 8);
                        long callOutput = ReadReaderInt64(reader, 9);
                        long callReasoning = ReadReaderInt64(reader, 10);
                        string fingerprint = ReadReaderString(reader, 11);
                        string sourcePath = ReadReaderString(reader, 12);
                        string rootSessionId = ReadReaderString(reader, 14);
                        string turnId = ReadReaderString(reader, 15);
                        string requestId = ReadReaderString(reader, 16);
                        string responseId = ReadReaderString(reader, 17);
                        string identitySource = ReadReaderString(reader, 18);
                        long modelContextWindow = ReadReaderInt64(reader, 19);
                        long longContextThreshold = ReadReaderInt64(reader, 20);
                        bool longContextApplied = ReadReaderInt64(reader, 21) != 0L;
                        string longContextSource = ReadReaderString(reader, 22);
                        long cacheCreationTokens = ReadReaderInt64(reader, 23);
                        bool cacheWriteObservable = ReadReaderInt64(reader, 24) != 0L;
                        string serviceTier = NormalizeServiceTier(ReadReaderString(reader, 25));
                        string serviceTierSource = NormalizeServiceTierSource(ReadReaderString(reader, 26), serviceTier);

                        if (callInput <= 0L && callOutput <= 0L) continue;

                        string cumulativeKey = BuildAggregateCumulativeKey(sessionId,
                            totalInput, totalCached, totalOutput, totalReasoning,
                            requestId, responseId, identitySource);
                        if (!seenCumulativeSnapshots.Observe(cumulativeKey, sessionId,
                            serviceTier, serviceTierSource))
                        {
                            result.DuplicateEventsDropped++;
                            continue;
                        }

                        DateTimeOffset eventAt;
                        bool hasTimestamp = TryParseTimestamp(timestampText, out eventAt);
                        if (!hasTimestamp) eventAt = DateTimeOffset.MinValue;
                        bool wasPresentAtStart = baselinePaths.Contains(sourcePath);
                        bool isStartingWindowEvent = false;
                        try { isStartingWindowEvent = eventAt >= startedAt.AddDays(-1.0); }
                        catch (ArgumentOutOfRangeException) { }
                        if (eventAt < startedAt && (!wasPresentAtStart || isStartingWindowEvent))
                        {
                            result.InheritedEventsDropped++;
                            continue;
                        }

                        if (string.IsNullOrWhiteSpace(rootSessionId)) rootSessionId = sessionId;
                        string eventKey = BuildAggregateEventKey(rootSessionId, eventAt, model,
                            totalInput, totalCached, totalOutput, totalReasoning,
                            callInput, callCached, callOutput, callReasoning, fingerprint);
                        var candidate = new AggregateEventCandidate {
                                SourceOffsetEnd = ReadReaderInt64(reader, 13),
                                SessionId = sessionId,
                                RootSessionId = rootSessionId,
                                SourcePath = sourcePath,
                                Model = model,
                                ServiceTier = serviceTier,
                                ServiceTierObservable = !string.IsNullOrWhiteSpace(serviceTier),
                                ServiceTierSource = serviceTierSource,
                                EventAt = eventAt,
                                HasTimestamp = hasTimestamp,
                                TurnId = turnId,
                                RequestId = requestId,
                                ResponseId = responseId,
                                IdentitySource = identitySource,
                                ModelContextWindow = modelContextWindow,
                                LongContextThreshold = longContextThreshold,
                                LongContextApplied = longContextApplied,
                                LongContextSource = longContextSource,
                                CacheCreationTokens = cacheCreationTokens,
                                CacheWriteObservable = cacheWriteObservable,
                                CallInput = callInput,
                                CallCached = callCached,
                                CallOutput = callOutput,
                                CallReasoning = callReasoning
                            };
                        AddAggregateLineageCandidate(lineageGroups, eventKey,
                            candidate, parentBySession, result);
                        seenCumulativeSnapshots.Register(cumulativeKey, candidate);
                    }
                }
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        FinalizeAggregateLineageCandidates(lineageGroups, thresholds, result);
        SetAggregateProgress(progressState, result.ProcessedRows, "区间聚合完成");
        result.BytesRead = ComputeRangeBytes(ranges);
        result.ProcessingMilliseconds = stopwatch.ElapsedMilliseconds;
        SetAggregateProgress(progressState, result.ProcessedRows, "区间聚合完成");
        return result;
    }

    /// <summary>
    /// Streams token calls whose event timestamps fall inside one exact
    /// half-open range [startedAt, endedAt). This powers the rolling 24-hour
    /// history card without loading individual SQLite rows into PowerShell or
    /// keeping a seven-day in-memory collection.
    /// </summary>
    public static TokenRaderIntervalAggregateResult AggregateTimeRangeRecords(
        SQLiteConnection db,
        DateTimeOffset startedAt,
        DateTimeOffset endedAt,
        IDictionary longContextThresholds,
        CancellationToken cancellationToken,
        IDictionary progressState = null)
    {
        if (db == null) throw new ArgumentNullException("db");
        if (endedAt <= startedAt) throw new ArgumentException("endedAt must be later than startedAt");

        var thresholds = ReadLongContextThresholds(longContextThresholds);
        var result = new TokenRaderIntervalAggregateResult();
        var parentBySession = ReadAggregateParentMap(db);
        var lineageGroups = new Dictionary<string, List<AggregateEventCandidate>>(StringComparer.Ordinal);
        var seenCumulativeSnapshots = new AggregateCumulativeSnapshotIndex();
        var stopwatch = Stopwatch.StartNew();

        // ISO timestamps emitted by Codex are normally UTC. Widen the indexed
        // lexical SQL range by one UTC date on each side, then apply the exact
        // DateTimeOffset boundary in managed code. This also handles records
        // carrying an explicit non-UTC offset without scanning all history.
        string broadStart = startedAt.UtcDateTime.Date.AddDays(-1.0)
            .ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);
        string broadEnd = endedAt.UtcDateTime.Date.AddDays(2.0)
            .ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);

        SetAggregateProgress(progressState, 0L, "读取24小时磁盘记录");
        string[] sourcePaths = ReadTimeRangeSourcePaths(db, broadStart, broadEnd);
        SeedTimeRangeCumulativeSnapshots(db, sourcePaths, startedAt,
            seenCumulativeSnapshots, lineageGroups, parentBySession, result,
            cancellationToken);

        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning," +
                "call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,source_offset_end,root_session_id," +
                "turn_id,request_id,response_id,identity_source,model_context_window,long_context_threshold,long_context_applied,long_context_source,cache_creation_tokens,cache_write_observable,service_tier,service_tier_source " +
                "FROM token_records WHERE source_offset_end>0 AND timestamp>=@broad_start AND timestamp<@broad_end " +
                "ORDER BY timestamp ASC,source_path ASC,source_offset_end ASC";
            cmd.Parameters.AddWithValue("@broad_start", broadStart);
            cmd.Parameters.AddWithValue("@broad_end", broadEnd);
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    result.ProcessedRows++;
                    if ((result.ProcessedRows & 255L) == 0L)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        SetAggregateProgress(progressState, result.ProcessedRows, "读取24小时磁盘记录");
                    }

                    string sessionId = ReadReaderString(reader, 0);
                    string timestampText = ReadReaderString(reader, 1);
                    string model = ReadReaderString(reader, 2);
                    long totalInput = ReadReaderInt64(reader, 3);
                    long totalCached = ReadReaderInt64(reader, 4);
                    long totalOutput = ReadReaderInt64(reader, 5);
                    long totalReasoning = ReadReaderInt64(reader, 6);
                    long callInput = ReadReaderInt64(reader, 7);
                    long callCached = ReadReaderInt64(reader, 8);
                    long callOutput = ReadReaderInt64(reader, 9);
                    long callReasoning = ReadReaderInt64(reader, 10);
                    string fingerprint = ReadReaderString(reader, 11);
                    string sourcePath = ReadReaderString(reader, 12);
                    string rootSessionId = ReadReaderString(reader, 14);
                    string turnId = ReadReaderString(reader, 15);
                    string requestId = ReadReaderString(reader, 16);
                    string responseId = ReadReaderString(reader, 17);
                    string identitySource = ReadReaderString(reader, 18);
                    long modelContextWindow = ReadReaderInt64(reader, 19);
                    long longContextThreshold = ReadReaderInt64(reader, 20);
                    bool longContextApplied = ReadReaderInt64(reader, 21) != 0L;
                    string longContextSource = ReadReaderString(reader, 22);
                    long cacheCreationTokens = ReadReaderInt64(reader, 23);
                    bool cacheWriteObservable = ReadReaderInt64(reader, 24) != 0L;
                    string serviceTier = NormalizeServiceTier(ReadReaderString(reader, 25));
                    string serviceTierSource = NormalizeServiceTierSource(ReadReaderString(reader, 26), serviceTier);

                    DateTimeOffset eventAt;
                    if (!TryParseTimestamp(timestampText, out eventAt) || eventAt < startedAt || eventAt >= endedAt) continue;
                    result.RawEvents++;
                    if (callInput <= 0L && callOutput <= 0L) continue;

                    string cumulativeKey = BuildAggregateCumulativeKey(sessionId,
                        totalInput, totalCached, totalOutput, totalReasoning,
                        requestId, responseId, identitySource);
                    if (!seenCumulativeSnapshots.Observe(cumulativeKey, sessionId,
                        serviceTier, serviceTierSource))
                    {
                        result.DuplicateEventsDropped++;
                        continue;
                    }

                    if (string.IsNullOrWhiteSpace(rootSessionId)) rootSessionId = sessionId;
                    string eventKey = BuildAggregateEventKey(rootSessionId, eventAt, model,
                        totalInput, totalCached, totalOutput, totalReasoning,
                        callInput, callCached, callOutput, callReasoning, fingerprint);
                    var candidate = new AggregateEventCandidate {
                            SourceOffsetEnd = ReadReaderInt64(reader, 13),
                            SessionId = sessionId,
                            RootSessionId = rootSessionId,
                            SourcePath = sourcePath,
                            Model = model,
                            ServiceTier = serviceTier,
                            ServiceTierObservable = !string.IsNullOrWhiteSpace(serviceTier),
                            ServiceTierSource = serviceTierSource,
                            EventAt = eventAt,
                            HasTimestamp = true,
                            TurnId = turnId,
                            RequestId = requestId,
                            ResponseId = responseId,
                            IdentitySource = identitySource,
                            ModelContextWindow = modelContextWindow,
                            LongContextThreshold = longContextThreshold,
                            LongContextApplied = longContextApplied,
                            LongContextSource = longContextSource,
                            CacheCreationTokens = cacheCreationTokens,
                            CacheWriteObservable = cacheWriteObservable,
                            CallInput = callInput,
                            CallCached = callCached,
                            CallOutput = callOutput,
                            CallReasoning = callReasoning
                        };
                    AddAggregateLineageCandidate(lineageGroups, eventKey,
                        candidate, parentBySession, result);
                    seenCumulativeSnapshots.Register(cumulativeKey, candidate);
                }
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        FinalizeAggregateLineageCandidates(lineageGroups, thresholds, result);
        result.ProcessingMilliseconds = stopwatch.ElapsedMilliseconds;
        SetAggregateProgress(progressState, result.ProcessedRows, "24小时磁盘汇总完成");
        return result;
    }

    /// <summary>
    /// Aggregates the exact timestamp interval (startedExclusive, endedInclusive]
    /// while never reading token rows beyond the caller's frozen per-file end
    /// offsets. This is used only for quota evidence, whose percentage snapshots
    /// describe a global account interval rather than the UI measurement start.
    /// </summary>
    public static TokenRaderIntervalAggregateResult AggregateTimeRangeRecordsAtOffsets(
        SQLiteConnection db,
        IDictionary endOffsets,
        DateTimeOffset startedExclusive,
        DateTimeOffset endedInclusive,
        IDictionary longContextThresholds,
        CancellationToken cancellationToken,
        IDictionary progressState = null)
    {
        return AggregateScopedTimeRangeRecordsAtOffsets(db, endOffsets,
            startedExclusive, endedInclusive, longContextThresholds,
            cancellationToken, progressState, null);
    }

    /// <summary>
    /// Aggregates quota evidence in the exact timestamp interval while
    /// retaining only calls attributable to the requested plan/reset cycle.
    /// Parent/child lineage is canonicalized by the normal time-range
    /// aggregator before cycle filtering is applied.
    /// </summary>
    public static TokenRaderIntervalAggregateResult AggregateQuotaTimeRangeRecordsAtOffsets(
        SQLiteConnection db,
        IDictionary endOffsets,
        DateTimeOffset startedExclusive,
        DateTimeOffset endedInclusive,
        IDictionary longContextThresholds,
        CancellationToken cancellationToken,
        IDictionary progressState,
        string windowKind,
        int windowMinutes,
        long resetUnixSeconds,
        string planType,
        string rateLimitId)
    {
        if (db == null) throw new ArgumentNullException("db");
        if (endedInclusive <= startedExclusive)
            throw new ArgumentException("endedInclusive must be later than startedExclusive");

        QuotaCycleScope scope;
        if (!TryCreateQuotaCycleScope(windowKind, windowMinutes, resetUnixSeconds,
            planType, rateLimitId, out scope))
        {
            var invalid = new TokenRaderIntervalAggregateResult();
            invalid.AttributionComplete = false;
            return invalid;
        }
        return AggregateScopedTimeRangeRecordsAtOffsetsInternal(db, endOffsets,
            startedExclusive, endedInclusive, longContextThresholds,
            cancellationToken, progressState, null, scope);
    }

    // Explorer filters ownership only AFTER lineage canonicalization. Ancestor
    // records may be provided as evidence without charging them to a child.
    public static TokenRaderIntervalAggregateResult AggregateScopedTimeRangeRecordsAtOffsets(
        SQLiteConnection db, IDictionary endOffsets,
        DateTimeOffset startedExclusive, DateTimeOffset endedInclusive,
        IDictionary longContextThresholds, CancellationToken cancellationToken,
        IDictionary progressState, string[] countedSessionIds)
    {
        return AggregateScopedTimeRangeRecordsAtOffsetsInternal(db, endOffsets,
            startedExclusive, endedInclusive, longContextThresholds,
            cancellationToken, progressState, countedSessionIds, null);
    }

    private static TokenRaderIntervalAggregateResult AggregateScopedTimeRangeRecordsAtOffsetsInternal(
        SQLiteConnection db, IDictionary endOffsets,
        DateTimeOffset startedExclusive, DateTimeOffset endedInclusive,
        IDictionary longContextThresholds, CancellationToken cancellationToken,
        IDictionary progressState, string[] countedSessionIds,
        QuotaCycleScope quotaScope)
    {
        if (db == null) throw new ArgumentNullException("db");
        if (endedInclusive <= startedExclusive)
            throw new ArgumentException("endedInclusive must be later than startedExclusive");

        var ranges = ReadAggregateOffsetRanges(null, endOffsets);
        var thresholds = ReadLongContextThresholds(longContextThresholds);
        var result = new TokenRaderIntervalAggregateResult();
        var parentBySession = ReadAggregateParentMap(db);
        var lineageGroups = new Dictionary<string, List<AggregateEventCandidate>>(StringComparer.Ordinal);
        var seenCumulativeSnapshots = new AggregateCumulativeSnapshotIndex();
        var stopwatch = Stopwatch.StartNew();
        string broadStart = startedExclusive.UtcDateTime.Date.AddDays(-1.0)
            .ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);
        string broadEnd = endedInclusive.UtcDateTime.Date.AddDays(2.0)
            .ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture);
        var relevantPaths = new HashSet<string>(
            ReadTimeRangeSourcePaths(db, broadStart, broadEnd), StringComparer.OrdinalIgnoreCase);
        // Complete per-call metadata needs no historical lookup. Defer the
        // supplemental index until a canonical candidate needs inheritance.
        QuotaCycleMetadataIndex quotaMetadataIndex = quotaScope == null ? null :
            new QuotaCycleMetadataIndex(delegate {
                return ReadQuotaCycleMetadataIndex(db, ranges, relevantPaths, quotaScope,
                    startedExclusive, endedInclusive, broadStart, broadEnd, cancellationToken);
            });

        SetAggregateProgress(progressState, 0L, "聚合区间记录");
        for (int rangeIndex = 0; rangeIndex < ranges.Count; rangeIndex++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            OffsetRange range = ranges[rangeIndex];
            if (!relevantPaths.Contains(range.Path)) continue;
            SeedTimeRangeCumulativeSnapshotAtOffset(db, range, startedExclusive,
                seenCumulativeSnapshots, lineageGroups, parentBySession, result,
                cancellationToken, quotaScope, quotaMetadataIndex);
            using (var cmd = db.CreateCommand())
            {
                cmd.CommandText = BuildAggregateRecordSelect(quotaScope != null) +
                    "FROM token_records WHERE source_path=@path AND source_offset_end>0 AND source_offset_end<=@end " +
                    "AND timestamp>=@broad_start AND timestamp<@broad_end ORDER BY source_offset_end ASC";
                cmd.Parameters.AddWithValue("@path", range.Path);
                cmd.Parameters.AddWithValue("@end", range.End);
                cmd.Parameters.AddWithValue("@broad_start", broadStart);
                cmd.Parameters.AddWithValue("@broad_end", broadEnd);
                using (var reader = cmd.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        result.ProcessedRows++;
                        if ((result.ProcessedRows & 255L) == 0L)
                        {
                            cancellationToken.ThrowIfCancellationRequested();
                            SetAggregateProgress(progressState, result.ProcessedRows, "聚合区间记录");
                        }

                        DateTimeOffset eventAt;
                        if (!TryParseTimestamp(ReadReaderString(reader, 1), out eventAt) ||
                            eventAt <= startedExclusive || eventAt > endedInclusive) continue;
                        result.RawEvents++;
                        string sessionId = ReadReaderString(reader, 0);
                        string model = ReadReaderString(reader, 2);
                        long totalInput = ReadReaderInt64(reader, 3);
                        long totalCached = ReadReaderInt64(reader, 4);
                        long totalOutput = ReadReaderInt64(reader, 5);
                        long totalReasoning = ReadReaderInt64(reader, 6);
                        long callInput = ReadReaderInt64(reader, 7);
                        long callCached = ReadReaderInt64(reader, 8);
                        long callOutput = ReadReaderInt64(reader, 9);
                        long callReasoning = ReadReaderInt64(reader, 10);
                        string fingerprint = ReadReaderString(reader, 11);
                        string sourcePath = ReadReaderString(reader, 12);
                        string rootSessionId = ReadReaderString(reader, 14);
                        string turnId = ReadReaderString(reader, 15);
                        string requestId = ReadReaderString(reader, 16);
                        string responseId = ReadReaderString(reader, 17);
                        string identitySource = ReadReaderString(reader, 18);
                        long modelContextWindow = ReadReaderInt64(reader, 19);
                        long longContextThreshold = ReadReaderInt64(reader, 20);
                        bool longContextApplied = ReadReaderInt64(reader, 21) != 0L;
                        string longContextSource = ReadReaderString(reader, 22);
                        long cacheCreationTokens = ReadReaderInt64(reader, 23);
                        bool cacheWriteObservable = ReadReaderInt64(reader, 24) != 0L;
                        string serviceTier = NormalizeServiceTier(ReadReaderString(reader, 25));
                        string serviceTierSource = NormalizeServiceTierSource(ReadReaderString(reader, 26), serviceTier);
                        long rowId = quotaScope == null ? 0L : ReadReaderInt64(reader, 27);
                        QuotaCycleMetadata quotaMetadata = quotaScope == null ? null :
                            ReadQuotaCycleMetadata(reader, quotaScope);
                        if (callInput <= 0L && callOutput <= 0L) continue;

                        string cumulativeKey = BuildAggregateCumulativeKey(sessionId,
                            totalInput, totalCached, totalOutput, totalReasoning,
                            requestId, responseId, identitySource);
                        if (!seenCumulativeSnapshots.Observe(cumulativeKey, sessionId,
                            serviceTier, serviceTierSource))
                        {
                            result.DuplicateEventsDropped++;
                            continue;
                        }
                        if (string.IsNullOrWhiteSpace(rootSessionId)) rootSessionId = sessionId;
                        string eventKey = BuildAggregateEventKey(rootSessionId, eventAt, model,
                            totalInput, totalCached, totalOutput, totalReasoning,
                            callInput, callCached, callOutput, callReasoning, fingerprint);
                        var candidate = new AggregateEventCandidate {
                                Id = rowId,
                                SourceOffsetEnd = ReadReaderInt64(reader, 13),
                                SessionId = sessionId,
                                RootSessionId = rootSessionId,
                                SourcePath = sourcePath,
                                Model = model,
                                ServiceTier = serviceTier,
                                ServiceTierObservable = !string.IsNullOrWhiteSpace(serviceTier),
                                ServiceTierSource = serviceTierSource,
                                EventAt = eventAt,
                                HasTimestamp = true,
                                TurnId = turnId,
                                RequestId = requestId,
                                ResponseId = responseId,
                                IdentitySource = identitySource,
                                ModelContextWindow = modelContextWindow,
                                LongContextThreshold = longContextThreshold,
                                LongContextApplied = longContextApplied,
                                LongContextSource = longContextSource,
                                CacheCreationTokens = cacheCreationTokens,
                                CacheWriteObservable = cacheWriteObservable,
                                CallInput = callInput,
                                CallCached = callCached,
                                CallOutput = callOutput,
                                CallReasoning = callReasoning,
                                QuotaMetadata = quotaMetadata
                            };
                        if (quotaScope != null)
                            candidate.QuotaAttribution = ResolveQuotaCycleAttribution(
                                candidate, quotaScope, quotaMetadataIndex);
                        AddAggregateLineageCandidate(lineageGroups, eventKey,
                            candidate, parentBySession, result);
                        seenCumulativeSnapshots.Register(cumulativeKey, candidate);
                    }
                }
            }
        }

        cancellationToken.ThrowIfCancellationRequested();
        FinalizeAggregateLineageCandidates(lineageGroups, thresholds, result,
            countedSessionIds == null ? null : new HashSet<string>(countedSessionIds, StringComparer.OrdinalIgnoreCase),
            quotaScope);
        result.ProcessingMilliseconds = stopwatch.ElapsedMilliseconds;
        SetAggregateProgress(progressState, result.ProcessedRows, "区间聚合完成");
        return result;
    }

    private static string[] ReadTimeRangeSourcePaths(SQLiteConnection db, string broadStart, string broadEnd)
    {
        var paths = new List<string>();
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT DISTINCT source_path FROM token_records WHERE source_offset_end>0 AND source_path<>'' " +
                "AND timestamp>=@start AND timestamp<@end ORDER BY source_path ASC";
            cmd.Parameters.AddWithValue("@start", broadStart);
            cmd.Parameters.AddWithValue("@end", broadEnd);
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string path = ReadReaderString(reader, 0);
                    if (!string.IsNullOrWhiteSpace(path)) paths.Add(path);
                }
            }
        }
        return paths.ToArray();
    }

    private static void SeedTimeRangeCumulativeSnapshots(
        SQLiteConnection db,
        IEnumerable<string> sourcePaths,
        DateTimeOffset startedAt,
        AggregateCumulativeSnapshotIndex seenCumulativeSnapshots,
        Dictionary<string, List<AggregateEventCandidate>> lineageGroups,
        Dictionary<string, string> parentBySession,
        TokenRaderIntervalAggregateResult result,
        CancellationToken cancellationToken)
    {
        int pathIndex = 0;
        foreach (string path in sourcePaths)
        {
            if ((pathIndex++ & 31) == 0) cancellationToken.ThrowIfCancellationRequested();
            using (var cmd = db.CreateCommand())
            {
                cmd.CommandText =
                    "SELECT session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning," +
                    "call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,source_offset_end,root_session_id," +
                    "turn_id,request_id,response_id,identity_source,model_context_window,long_context_threshold,long_context_applied,long_context_source,cache_creation_tokens,cache_write_observable,service_tier,service_tier_source " +
                    "FROM token_records WHERE source_path=@path AND source_offset_end>0 " +
                    "ORDER BY source_offset_end DESC";
                cmd.Parameters.AddWithValue("@path", path);
                using (var reader = cmd.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        DateTimeOffset eventAt;
                        if (!TryParseTimestamp(ReadReaderString(reader, 1), out eventAt) || eventAt >= startedAt) continue;
                        SeedAggregateLineageFromReader(reader, seenCumulativeSnapshots,
                            lineageGroups, parentBySession, result);
                        break;
                    }
                }
            }
        }
    }

    private static void SeedTimeRangeCumulativeSnapshotAtOffset(
        SQLiteConnection db,
        OffsetRange range,
        DateTimeOffset startedExclusive,
        AggregateCumulativeSnapshotIndex seenCumulativeSnapshots,
        Dictionary<string, List<AggregateEventCandidate>> lineageGroups,
        Dictionary<string, string> parentBySession,
        TokenRaderIntervalAggregateResult result,
        CancellationToken cancellationToken,
        QuotaCycleScope quotaScope = null,
        QuotaCycleMetadataIndex quotaMetadataIndex = null)
    {
        if (db == null || range == null || seenCumulativeSnapshots == null) return;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = BuildAggregateRecordSelect(quotaScope != null) +
                "FROM token_records WHERE source_path=@path AND source_offset_end>0 AND source_offset_end<=@end " +
                "ORDER BY source_offset_end DESC";
            cmd.Parameters.AddWithValue("@path", range.Path);
            cmd.Parameters.AddWithValue("@end", range.End);
            using (var reader = cmd.ExecuteReader())
            {
                int inspected = 0;
                while (reader.Read())
                {
                    if ((inspected++ & 255) == 0) cancellationToken.ThrowIfCancellationRequested();
                    DateTimeOffset eventAt;
                    if (!TryParseTimestamp(ReadReaderString(reader, 1), out eventAt) ||
                        eventAt > startedExclusive) continue;
                    SeedAggregateLineageFromReader(reader, seenCumulativeSnapshots,
                        lineageGroups, parentBySession, result, db,
                        quotaScope, quotaMetadataIndex);
                    break;
                }
            }
        }
    }

    private static Dictionary<string, string> ReadAggregateParentMap(SQLiteConnection db)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT session_id,parent_thread_id,forked_from_id FROM file_metadata " +
                "WHERE session_id IS NOT NULL AND session_id<>''";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string session = ReadReaderString(reader, 0);
                    string parent = ReadReaderString(reader, 1);
                    if (string.IsNullOrWhiteSpace(parent)) parent = ReadReaderString(reader, 2);
                    if (!string.IsNullOrWhiteSpace(session) && !string.IsNullOrWhiteSpace(parent))
                        result[session] = parent;
                }
            }
        }
        return result;
    }

    private static Dictionary<string, string> ReadAggregateSessionPathMaps(
        SQLiteConnection db,
        out Dictionary<string, string> sessionByPath)
    {
        var pathBySession = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        sessionByPath = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT session_id,path FROM file_metadata WHERE session_id IS NOT NULL AND session_id<>'' AND path IS NOT NULL AND path<>''";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string session = ReadReaderString(reader, 0);
                    string path = ReadReaderString(reader, 1);
                    if (string.IsNullOrWhiteSpace(session) || string.IsNullOrWhiteSpace(path)) continue;
                    pathBySession[session] = path;
                    sessionByPath[path] = session;
                }
            }
        }
        return pathBySession;
    }

    private static void SeedAggregateAncestorSnapshots(
        SQLiteConnection db,
        string changedPath,
        Dictionary<string, long> baselineOffsets,
        Dictionary<string, string> pathBySession,
        Dictionary<string, string> sessionByPath,
        Dictionary<string, string> parentBySession,
        HashSet<string> seededAncestorSessions,
        AggregateCumulativeSnapshotIndex seenCumulativeSnapshots,
        Dictionary<string, List<AggregateEventCandidate>> lineageGroups,
        TokenRaderIntervalAggregateResult result)
    {
        if (string.IsNullOrWhiteSpace(changedPath) || sessionByPath == null ||
            pathBySession == null || parentBySession == null) return;
        string session;
        if (!sessionByPath.TryGetValue(changedPath, out session)) return;
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string current = session;
        for (int depth = 0; depth < 64 && visited.Add(current); depth++)
        {
            string parent;
            if (!parentBySession.TryGetValue(current, out parent) || string.IsNullOrWhiteSpace(parent)) break;
            current = parent;
            if (!seededAncestorSessions.Add(current)) continue;
            string parentPath;
            long parentOffset;
            if (!pathBySession.TryGetValue(current, out parentPath) ||
                !baselineOffsets.TryGetValue(parentPath, out parentOffset) || parentOffset <= 0L) continue;
            SeedAggregateCumulativeSnapshot(db,
                new OffsetRange { Path = parentPath, Start = parentOffset, End = parentOffset },
                seenCumulativeSnapshots, lineageGroups, parentBySession, result);
        }
    }

    private static void AddAggregateLineageCandidate(
        Dictionary<string, List<AggregateEventCandidate>> groups,
        string eventKey,
        AggregateEventCandidate candidate,
        Dictionary<string, string> parentBySession,
        TokenRaderIntervalAggregateResult result)
    {
        List<AggregateEventCandidate> representatives;
        if (!groups.TryGetValue(eventKey, out representatives))
        {
            representatives = new List<AggregateEventCandidate>();
            groups.Add(eventKey, representatives);
        }

        var relatedIndexes = new List<int>();
        bool existingAncestorFound = false;
        for (int i = 0; i < representatives.Count; i++)
        {
            AggregateEventCandidate existing = representatives[i];
            // Token usage is the first-line identity for a lineage copy. A
            // parent and child can receive different request/response/turn
            // identifiers while serialising the same call, and those IDs can
            // also be absent from older index rows. Do not let an auxiliary
            // identifier prevent a canonical token fingerprint from being
            // compared. Sibling sessions are still kept separate below by
            // the explicit same-session/ancestor relationship check.
            bool sameSession = string.Equals(candidate.SessionId, existing.SessionId,
                StringComparison.OrdinalIgnoreCase);
            bool candidateMissingTotal = IsMissingTotalIdentitySource(candidate.IdentitySource);
            bool existingMissingTotal = IsMissingTotalIdentitySource(existing.IdentitySource);
            if (candidateMissingTotal || existingMissingTotal)
            {
                // A zero-total fallback has no safe token-only lineage key.
                // Reconcile it only when both rows carry the same explicit
                // request/response identity; otherwise two identical calls
                // (including a parent/child copy with rewritten ids) must stay
                // separate rather than being silently merged.
                bool sameRequest = !string.IsNullOrWhiteSpace(candidate.RequestId) &&
                    !string.IsNullOrWhiteSpace(existing.RequestId) &&
                    string.Equals(candidate.RequestId, existing.RequestId,
                        StringComparison.OrdinalIgnoreCase);
                bool sameResponse = !string.IsNullOrWhiteSpace(candidate.ResponseId) &&
                    !string.IsNullOrWhiteSpace(existing.ResponseId) &&
                    string.Equals(candidate.ResponseId, existing.ResponseId,
                        StringComparison.OrdinalIgnoreCase);
                if (!sameRequest && !sameResponse) continue;
            }
            // Within one session, distinct strong identifiers may represent
            // two real calls with an identical cumulative/token fingerprint.
            // Across an ancestor/descendant boundary, however, identifiers and
            // model labels are auxiliary: copied child records commonly receive
            // a new turn/request id and a child turn_context model.
            if (sameSession)
            {
                bool distinctRequest = !string.IsNullOrWhiteSpace(candidate.RequestId) &&
                    !string.IsNullOrWhiteSpace(existing.RequestId) &&
                    !string.Equals(candidate.RequestId, existing.RequestId, StringComparison.OrdinalIgnoreCase);
                bool distinctResponse = !string.IsNullOrWhiteSpace(candidate.ResponseId) &&
                    !string.IsNullOrWhiteSpace(existing.ResponseId) &&
                    !string.Equals(candidate.ResponseId, existing.ResponseId, StringComparison.OrdinalIgnoreCase);
                bool distinctTurn = !string.IsNullOrWhiteSpace(candidate.TurnId) &&
                    !string.IsNullOrWhiteSpace(existing.TurnId) &&
                    !string.Equals(candidate.TurnId, existing.TurnId, StringComparison.OrdinalIgnoreCase);
                if (distinctRequest || distinctResponse || distinctTurn) continue;
            }
            bool candidateIsRoot = !string.IsNullOrWhiteSpace(candidate.RootSessionId) &&
                string.Equals(candidate.SessionId, candidate.RootSessionId, StringComparison.OrdinalIgnoreCase);
            bool existingIsRoot = !string.IsNullOrWhiteSpace(existing.RootSessionId) &&
                string.Equals(existing.SessionId, existing.RootSessionId, StringComparison.OrdinalIgnoreCase);
            bool candidateAncestor = !sameSession &&
                (candidateIsRoot || IsAggregateAncestor(candidate.SessionId, existing.SessionId, parentBySession));
            bool existingAncestor = !sameSession &&
                (existingIsRoot || IsAggregateAncestor(existing.SessionId, candidate.SessionId, parentBySession));
            if (!sameSession && !candidateAncestor && !existingAncestor) continue;

            relatedIndexes.Add(i);
            if (existingAncestor) existingAncestorFound = true;
            if (sameSession)
            {
                if (candidate.IncludeInResult || existing.IncludeInResult) result.DuplicateEventsDropped++;
                if (candidate.HasTimestamp && (!existing.HasTimestamp || candidate.EventAt >= existing.EventAt))
                    representatives[i] = candidate;
                return;
            }
        }

        if (existingAncestorFound)
        {
            // A canonical ancestor is already present. The new descendant is a
            // copied record and must never replace the ancestor's model/price.
            if (candidate.IncludeInResult) result.DuplicateEventsDropped++;
            return;
        }
        if (relatedIndexes.Count > 0)
        {
            // The parent can be encountered after multiple descendant copies.
            // Remove every related descendant before adding the parent so the
            // result does not depend on file enumeration order.
            int duplicateCount = 0;
            for (int i = relatedIndexes.Count - 1; i >= 0; i--)
            {
                AggregateEventCandidate removed = representatives[relatedIndexes[i]];
                if (candidate.IncludeInResult || removed.IncludeInResult) duplicateCount++;
                representatives.RemoveAt(relatedIndexes[i]);
            }
            result.DuplicateEventsDropped += duplicateCount;
        }
        representatives.Add(candidate);
    }

    private static void FinalizeAggregateLineageCandidates(
        Dictionary<string, List<AggregateEventCandidate>> groups,
        Dictionary<string, long> thresholds,
        TokenRaderIntervalAggregateResult result,
        HashSet<string> countedSessionIds = null,
        QuotaCycleScope quotaScope = null)
    {
        var activeFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var models = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var buckets = new Dictionary<string, TokenRaderIntervalAggregateBucket>(StringComparer.OrdinalIgnoreCase);
        var resolvedThresholds = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        var identitySources = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var latestByStableIdentity = new Dictionary<string, AggregateEventCandidate>(StringComparer.OrdinalIgnoreCase);
        result.CacheWriteObservable = true;
        DateTimeOffset? firstCountedAt = null;
        DateTimeOffset? lastCountedAt = null;

        // Request/response identifiers describe a lifecycle whose intermediate
        // rows can carry progressively larger token totals. Lineage comparison
        // above deliberately uses token fingerprints first; collapse lifecycle
        // updates here, within the same session, so auxiliary IDs cannot block
        // parent/child copy detection.
        foreach (List<AggregateEventCandidate> representatives in groups.Values)
        {
            for (int i = 0; i < representatives.Count; i++)
            {
                AggregateEventCandidate candidate = representatives[i];
                if (!candidate.IncludeInResult ||
                    (countedSessionIds != null && !countedSessionIds.Contains(candidate.SessionId))) continue;
                if (quotaScope != null && candidate.QuotaAttribution != QuotaCycleAttribution.Target)
                    continue;
                string stableId = !string.IsNullOrWhiteSpace(candidate.RequestId)
                    ? "request:" + candidate.RequestId
                    : (!string.IsNullOrWhiteSpace(candidate.ResponseId) ? "response:" + candidate.ResponseId : "");
                if (stableId.Length == 0) continue;
                string stableKey = candidate.SessionId.ToLowerInvariant() + "|" + stableId;
                AggregateEventCandidate current;
                bool hasCurrent = latestByStableIdentity.TryGetValue(stableKey, out current);
                bool candidateIsFallback = IsMissingTotalIdentitySource(candidate.IdentitySource);
                bool currentIsFallback = hasCurrent && current != null &&
                    IsMissingTotalIdentitySource(current.IdentitySource);
                if (!hasCurrent ||
                    (currentIsFallback && !candidateIsFallback) ||
                    (candidateIsFallback == currentIsFallback && candidate.HasTimestamp &&
                     (!current.HasTimestamp || candidate.EventAt >= current.EventAt)))
                    latestByStableIdentity[stableKey] = candidate;
            }
        }

        foreach (List<AggregateEventCandidate> representatives in groups.Values)
        {
            for (int i = 0; i < representatives.Count; i++)
            {
                AggregateEventCandidate candidate = representatives[i];
                if (!candidate.IncludeInResult ||
                    (countedSessionIds != null && !countedSessionIds.Contains(candidate.SessionId))) continue;
                if (quotaScope != null)
                {
                    if (candidate.QuotaAttribution == QuotaCycleAttribution.Foreign)
                    {
                        result.ExcludedCycleEvents++;
                        continue;
                    }
                    if (candidate.QuotaAttribution != QuotaCycleAttribution.Target)
                    {
                        result.UnattributedEvents++;
                        result.AttributionComplete = false;
                        continue;
                    }
                }
                string stableId = !string.IsNullOrWhiteSpace(candidate.RequestId)
                    ? "request:" + candidate.RequestId
                    : (!string.IsNullOrWhiteSpace(candidate.ResponseId) ? "response:" + candidate.ResponseId : "");
                if (stableId.Length > 0)
                {
                    AggregateEventCandidate terminal;
                    string stableKey = candidate.SessionId.ToLowerInvariant() + "|" + stableId;
                    if (latestByStableIdentity.TryGetValue(stableKey, out terminal) &&
                        !object.ReferenceEquals(candidate, terminal))
                    {
                        result.DuplicateEventsDropped++;
                        continue;
                    }
                }
                result.CountedEvents++;
                result.TotalInput += candidate.CallInput;
                result.TotalCached += candidate.CallCached;
                result.TotalOutput += candidate.CallOutput;
                result.TotalReasoning += candidate.CallReasoning;
                result.CacheCreationTokens += candidate.CacheCreationTokens;
                if (!string.IsNullOrWhiteSpace(candidate.SourcePath)) activeFiles.Add(candidate.SourcePath);
                if (!string.IsNullOrWhiteSpace(candidate.Model)) models.Add(candidate.Model);
                string identitySource = candidate.IdentitySource;
                if (string.IsNullOrWhiteSpace(identitySource))
                {
                    identitySource = !string.IsNullOrWhiteSpace(candidate.RequestId) ? "request_id" :
                        (!string.IsNullOrWhiteSpace(candidate.ResponseId) ? "response_id" :
                        (!string.IsNullOrWhiteSpace(candidate.TurnId) ? "turn_id" : "unresolved"));
                }
                identitySources.Add(identitySource);
                if (!string.Equals(identitySource, "request_id", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(identitySource, "response_id", StringComparison.OrdinalIgnoreCase))
                    result.UnidentifiedEvents++;
                if (candidate.HasTimestamp)
                {
                    if (!firstCountedAt.HasValue || candidate.EventAt < firstCountedAt.Value)
                        firstCountedAt = candidate.EventAt;
                    if (!lastCountedAt.HasValue || candidate.EventAt > lastCountedAt.Value)
                        lastCountedAt = candidate.EventAt;
                }

                long threshold;
                if (!resolvedThresholds.TryGetValue(candidate.Model, out threshold))
                {
                    threshold = ResolveAggregateLongContextThreshold(candidate.Model, thresholds);
                    resolvedThresholds[candidate.Model] = threshold;
                }
                bool longContextEvidenceComplete = !IsMissingLastIdentitySource(
                    candidate.IdentitySource);
                bool longContext = longContextEvidenceComplete &&
                    threshold > 0L && candidate.CallInput > threshold;
                if (longContext) {
                    result.LongContextEvents++;
                    result.LongContextInput += candidate.CallInput;
                    result.LongContextOutput += candidate.CallOutput;
                } else {
                    result.StandardContextEvents++;
                    result.StandardContextInput += candidate.CallInput;
                }
                if (!candidate.CacheWriteObservable) result.CacheWriteObservable = false;
                string normalizedLongContextSource = IsMissingLastIdentitySource(candidate.IdentitySource)
                    ? "missing_input" : NormalizeLongContextSource(
                        candidate.LongContextSource, candidate.Model, candidate.CallInput, threshold);
                string normalizedTier = NormalizeServiceTier(candidate.ServiceTier);
                string tierEvidenceClass = IsReliableServiceTierSource(
                    candidate.ServiceTierSource) ? "trusted" : "untrusted";
                bool requestInputObservable = !IsMissingLastIdentitySource(
                    candidate.IdentitySource);
                bool longContextPricingUncertain = !requestInputObservable &&
                    threshold > 0L && candidate.CallInput > threshold;
                string bucketKey = candidate.Model.ToLowerInvariant() + "|" +
                    normalizedTier + "|" + (longContext ? "long" : "standard") +
                    "|" + tierEvidenceClass + "|" +
                    (requestInputObservable ? "observed" : "derived") +
                    (longContextPricingUncertain ? "|uncertain" : "|bounded");
                TokenRaderIntervalAggregateBucket bucket;
                if (!buckets.TryGetValue(bucketKey, out bucket))
                {
                    bucket = new TokenRaderIntervalAggregateBucket {
                        Model = candidate.Model,
                        ServiceTier = normalizedTier,
                        ServiceTierObservable = candidate.ServiceTierObservable &&
                            !string.IsNullOrWhiteSpace(normalizedTier),
                        ServiceTierSource = NormalizeServiceTierSource(
                            candidate.ServiceTierSource, normalizedTier),
                        ServiceTierEvidenceComplete = tierEvidenceClass == "trusted",
                        LongContext = longContext,
                        ModelContextWindow = candidate.ModelContextWindow,
                        LongContextThreshold = threshold,
                        LongContextSource = normalizedLongContextSource,
                        RequestInputObservable = requestInputObservable,
                        LongContextPricingUncertain = longContextPricingUncertain,
                        CacheWriteObservable = candidate.CacheWriteObservable
                    };
                    buckets.Add(bucketKey, bucket);
                }
                bucket.Input += candidate.CallInput;
                bucket.Cached += candidate.CallCached;
                bucket.Output += candidate.CallOutput;
                bucket.Reasoning += candidate.CallReasoning;
                bucket.CacheCreationTokens += candidate.CacheCreationTokens;
                bucket.Events++;
                if (candidate.ModelContextWindow > bucket.ModelContextWindow) bucket.ModelContextWindow = candidate.ModelContextWindow;
                bucket.CacheWriteObservable = bucket.CacheWriteObservable && candidate.CacheWriteObservable;
                bucket.ServiceTierObservable = bucket.ServiceTierObservable &&
                    candidate.ServiceTierObservable && !string.IsNullOrWhiteSpace(normalizedTier);
                bucket.ServiceTierSource = MergeServiceTierSource(bucket.ServiceTierSource,
                    NormalizeServiceTierSource(candidate.ServiceTierSource, normalizedTier));
                bucket.ServiceTierEvidenceComplete = bucket.ServiceTierEvidenceComplete &&
                    IsReliableServiceTierSource(candidate.ServiceTierSource);
                bucket.RequestInputObservable = bucket.RequestInputObservable &&
                    requestInputObservable;
            }
        }

        result.FirstCountedAt = firstCountedAt;
        result.LastCountedAt = lastCountedAt;
        result.IdentityComplete = result.CountedEvents > 0L && result.UnidentifiedEvents == 0L;
        var sortedIdentitySources = new List<string>(identitySources);
        sortedIdentitySources.Sort(StringComparer.OrdinalIgnoreCase);
        result.IdentitySources = sortedIdentitySources.ToArray();
        result.ChangedSessions = activeFiles.Count;
        var sortedModels = new List<string>(models);
        sortedModels.Sort(StringComparer.OrdinalIgnoreCase);
        result.Models = sortedModels.ToArray();
        var sortedBuckets = new List<TokenRaderIntervalAggregateBucket>(buckets.Values);
        sortedBuckets.Sort(delegate(TokenRaderIntervalAggregateBucket left, TokenRaderIntervalAggregateBucket right) {
            int comparison = StringComparer.OrdinalIgnoreCase.Compare(left.Model, right.Model);
            if (comparison != 0) return comparison;
            comparison = StringComparer.OrdinalIgnoreCase.Compare(left.ServiceTier, right.ServiceTier);
            if (comparison != 0) return comparison;
            comparison = left.LongContext.CompareTo(right.LongContext);
            if (comparison != 0) return comparison;
            if (left.ServiceTierEvidenceComplete != right.ServiceTierEvidenceComplete)
                return left.ServiceTierEvidenceComplete ? -1 : 1;
            if (left.RequestInputObservable != right.RequestInputObservable)
                return left.RequestInputObservable ? -1 : 1;
            return StringComparer.OrdinalIgnoreCase.Compare(left.ServiceTierSource, right.ServiceTierSource);
        });
        result.Buckets = sortedBuckets.ToArray();
    }

    private static string MergeServiceTierSource(string current, string next)
    {
        string left = current ?? "";
        string right = next ?? "";
        if (left.Length == 0) return right;
        if (right.Length == 0 || string.Equals(left, right, StringComparison.OrdinalIgnoreCase)) return left;
        return "mixed";
    }

    private static bool IsStrongerServiceTierEvidence(string existingSource, string nextSource)
    {
        int existingRank = GetServiceTierEvidenceRank(existingSource);
        int nextRank = GetServiceTierEvidenceRank(nextSource);
        return nextRank > existingRank;
    }

    private static int GetServiceTierEvidenceRank(string source)
    {
        string normalized = (source ?? "").Trim().ToLowerInvariant();
        if (normalized == "response" || normalized == "response_null") return 4;
        if (normalized == "service_tier" || normalized == "service_tier_null") return 3;
        if (normalized == "turn_context" || normalized == "turn_context_null" ||
            normalized == "turn_context_missing") return 2;
        if (normalized == "indexed") return 1;
        return 0;
    }

    private static bool IsReliableServiceTierSource(string source)
    {
        // Rank zero includes legacy rows with no provenance and the
        // inherited-index fallback. "indexed" is intentionally untrusted:
        // it may be a response-tier override copied into an older row.
        return GetServiceTierEvidenceRank(source) >= 2;
    }

    private static string NormalizeLongContextSource(string source, string model, long callInput, long threshold)
    {
        // The current pricing document is authoritative during aggregation.
        // An older index may have stored no_threshold before support for a new
        // model was added; retaining that stale label would contradict the
        // threshold and long-context bucket computed above.
        if (callInput <= 0L) return "missing_input";
        if (string.IsNullOrWhiteSpace(model)) return "unknown_model";
        return threshold > 0L ? "pricing_threshold" : "no_threshold";
    }

    private static bool IsAggregateAncestor(
        string possibleAncestor,
        string session,
        Dictionary<string, string> parentBySession)
    {
        if (string.IsNullOrWhiteSpace(possibleAncestor) || string.IsNullOrWhiteSpace(session) ||
            parentBySession == null || parentBySession.Count == 0) return false;
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string current = session;
        for (int depth = 0; depth < 64 && !string.IsNullOrWhiteSpace(current) && visited.Add(current); depth++)
        {
            string parent;
            if (!parentBySession.TryGetValue(current, out parent) || string.IsNullOrWhiteSpace(parent)) return false;
            if (string.Equals(parent, possibleAncestor, StringComparison.OrdinalIgnoreCase)) return true;
            current = parent;
        }
        return false;
    }

    private static Dictionary<string, long> ReadLongContextThresholds(IDictionary input)
    {
        var result = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        if (input == null) return result;
        foreach (DictionaryEntry entry in input)
        {
            string model = entry.Key == null ? "" : Convert.ToString(entry.Key, CultureInfo.InvariantCulture);
            long threshold;
            if (!string.IsNullOrWhiteSpace(model) && TryConvertInt64(entry.Value, out threshold))
                result[model] = threshold;
        }
        return result;
    }

    private static List<OffsetRange> ReadAggregateOffsetRanges(IDictionary starts, IDictionary ends)
    {
        var ranges = new List<OffsetRange>();
        if (ends == null) return ranges;

        // The frozen end snapshot is authoritative. A baseline file omitted
        // from EndOffsets must never become an unbounded range, while a file
        // first observed after the baseline starts at byte zero.
        var startMap = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        if (starts != null)
        {
            foreach (DictionaryEntry entry in starts)
            {
                string path = entry.Key == null ? "" : Convert.ToString(entry.Key, CultureInfo.InvariantCulture);
                long start;
                if (!string.IsNullOrWhiteSpace(path) && TryConvertInt64(entry.Value, out start))
                    startMap[path] = Math.Max(0L, start);
            }
        }

        var seenPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry entry in ends)
        {
            string path = entry.Key == null ? "" : Convert.ToString(entry.Key, CultureInfo.InvariantCulture);
            long end;
            if (string.IsNullOrWhiteSpace(path) || !seenPaths.Add(path) ||
                !TryConvertInt64(entry.Value, out end)) continue;
            end = end < 0L ? long.MaxValue : end;
            long start;
            if (!startMap.TryGetValue(path, out start)) start = 0L;
            if (end <= start) continue;
            ranges.Add(new OffsetRange { Path = path, Start = start, End = end });
        }
        return ranges;
    }

    private static HashSet<string> ReadOffsetPathSet(IDictionary offsets)
    {
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (offsets == null) return paths;
        foreach (DictionaryEntry entry in offsets)
        {
            string candidate = entry.Key == null ? "" : Convert.ToString(entry.Key, CultureInfo.InvariantCulture);
            if (!string.IsNullOrWhiteSpace(candidate)) paths.Add(candidate);
        }
        return paths;
    }

    private static Dictionary<string, long> ReadAggregateOffsetMap(IDictionary offsets)
    {
        var result = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        if (offsets == null) return result;
        foreach (DictionaryEntry entry in offsets)
        {
            string path = entry.Key == null ? "" : Convert.ToString(entry.Key, CultureInfo.InvariantCulture);
            long value;
            if (!string.IsNullOrWhiteSpace(path) && TryConvertInt64(entry.Value, out value))
                result[path] = Math.Max(0L, value);
        }
        return result;
    }

    private static string BuildAggregateRecordSelect(bool includeQuotaMetadata)
    {
        string select =
            "SELECT session_id,timestamp,model,total_input,total_cached,total_output,total_reasoning," +
            "call_input,call_cached,call_output,call_reasoning,fingerprint,source_path,source_offset_end,root_session_id," +
            "turn_id,request_id,response_id,identity_source,model_context_window,long_context_threshold,long_context_applied,long_context_source,cache_creation_tokens,cache_write_observable,service_tier,service_tier_source";
        if (includeQuotaMetadata)
        {
            select += ",id,five_hour_used,five_hour_window,five_hour_resets," +
                "weekly_used,weekly_window,weekly_resets,plan_type,rate_limit_id";
        }
        return select + " ";
    }

    private static bool TryCreateQuotaCycleScope(
        string windowKind,
        int windowMinutes,
        long resetUnixSeconds,
        string planType,
        string rateLimitId,
        out QuotaCycleScope scope)
    {
        scope = null;
        if (windowMinutes <= 0 || resetUnixSeconds <= 0L) return false;
        if (!string.Equals(windowKind, "FiveHour", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(windowKind, "Weekly", StringComparison.OrdinalIgnoreCase)) return false;
        long resetMinute;
        try { resetMinute = resetUnixSeconds / 60L; }
        catch (OverflowException) { return false; }
        scope = new QuotaCycleScope {
            WindowKind = string.Equals(windowKind, "Weekly", StringComparison.OrdinalIgnoreCase)
                ? "Weekly" : "FiveHour",
            WindowMinutes = windowMinutes,
            ResetUnixSeconds = resetUnixSeconds,
            ResetMinute = resetMinute,
            PlanType = planType ?? "",
            RateLimitId = rateLimitId ?? ""
        };
        return true;
    }

    private static QuotaCycleMetadata ReadQuotaCycleMetadata(
        SQLiteDataReader reader, QuotaCycleScope scope)
    {
        if (reader == null || scope == null) return null;
        // These ordinals are appended by BuildAggregateRecordSelect and are
        // deliberately kept separate from the long-standing aggregate row
        // ordinals above.
        int usedOrdinal = string.Equals(scope.WindowKind, "Weekly", StringComparison.OrdinalIgnoreCase)
            ? 31 : 28;
        int windowOrdinal = string.Equals(scope.WindowKind, "Weekly", StringComparison.OrdinalIgnoreCase)
            ? 32 : 29;
        int resetOrdinal = string.Equals(scope.WindowKind, "Weekly", StringComparison.OrdinalIgnoreCase)
            ? 33 : 30;
        bool hasUsed = !reader.IsDBNull(usedOrdinal);
        bool hasWindow = !reader.IsDBNull(windowOrdinal);
        bool hasReset = !reader.IsDBNull(resetOrdinal);
        string plan = ReadReaderString(reader, 34);
        string limit = ReadReaderString(reader, 35);
        var metadata = new QuotaCycleMetadata {
            HasAny = hasUsed || hasWindow || hasReset ||
                !string.IsNullOrWhiteSpace(plan) || !string.IsNullOrWhiteSpace(limit),
            HasTargetWindowMetadata = hasUsed || hasWindow || hasReset,
            PlanType = plan,
            RateLimitId = limit
        };
        if (hasWindow && hasReset)
        {
            int window;
            long reset;
            if (TryConvertInt32(reader.GetValue(windowOrdinal), out window) &&
                TryConvertInt64(reader.GetValue(resetOrdinal), out reset) &&
                window > 0 && reset > 0L)
            {
                metadata.HasKnownCycle = true;
                metadata.WindowMinutes = window;
                metadata.ResetUnixSeconds = reset;
            }
        }
        return metadata.HasAny ? metadata : null;
    }

    private static bool QuotaMetadataMatchesScope(
        QuotaCycleMetadata metadata, QuotaCycleScope scope)
    {
        if (metadata == null || scope == null || !metadata.HasKnownCycle) return false;
        if (metadata.WindowMinutes != scope.WindowMinutes) return false;
        if (metadata.ResetUnixSeconds / 60L != scope.ResetMinute) return false;
        // Empty plan/limit values are an explicit legacy bucket.  They are
        // not wildcards here: a named pool must never be mixed with rows that
        // omitted the pool identifier.
        return string.Equals(metadata.PlanType ?? "", scope.PlanType ?? "",
                StringComparison.OrdinalIgnoreCase) &&
            string.Equals(metadata.RateLimitId ?? "", scope.RateLimitId ?? "",
            StringComparison.OrdinalIgnoreCase);
    }

    private static bool QuotaMetadataIsAmbiguous(
        QuotaCycleMetadata metadata, QuotaCycleScope scope)
    {
        if (metadata == null || scope == null || !metadata.HasKnownCycle) return true;
        if (metadata.WindowMinutes != scope.WindowMinutes ||
            metadata.ResetUnixSeconds / 60L != scope.ResetMinute) return false;
        // A named target cannot safely adopt a legacy row that omitted the
        // corresponding discriminator.  The reverse direction is explicit
        // evidence for the legacy empty bucket and is therefore foreign.
        if (!string.IsNullOrWhiteSpace(scope.PlanType) &&
            string.IsNullOrWhiteSpace(metadata.PlanType)) return true;
        if (!string.IsNullOrWhiteSpace(scope.RateLimitId) &&
            string.IsNullOrWhiteSpace(metadata.RateLimitId)) return true;
        return false;
    }

    private static QuotaCycleAttribution ResolveQuotaCycleAttribution(
        AggregateEventCandidate candidate,
        QuotaCycleScope scope,
        QuotaCycleMetadataIndex metadataIndex)
    {
        if (candidate == null || scope == null) return QuotaCycleAttribution.Unattributed;
        QuotaCycleMetadata metadata = candidate.QuotaMetadata;
        if (metadata == null || !metadata.HasAny || !metadata.HasTargetWindowMetadata)
        {
            bool blocked = false;
            QuotaCycleMetadata preceding = metadataIndex == null ? null : metadataIndex.FindPreceding(
                candidate.SessionId, candidate.SourcePath, candidate.SourceOffsetEnd,
                candidate.Id, candidate.EventAt, scope, out blocked);
            if (metadata != null && metadata.HasAny && preceding != null &&
                ((metadata.PlanType.Length > 0 && !string.Equals(metadata.PlanType,
                    preceding.PlanType ?? "", StringComparison.OrdinalIgnoreCase)) ||
                 (metadata.RateLimitId.Length > 0 && !string.Equals(metadata.RateLimitId,
                    preceding.RateLimitId ?? "", StringComparison.OrdinalIgnoreCase))))
                return QuotaCycleAttribution.Unattributed;
            if (blocked || preceding == null) return QuotaCycleAttribution.Unattributed;
            metadata = preceding;
        }
        if (metadata == null || !metadata.HasAny) return QuotaCycleAttribution.Unattributed;
        if (!metadata.HasKnownCycle) return QuotaCycleAttribution.Unattributed;
        if (QuotaMetadataIsAmbiguous(metadata, scope)) return QuotaCycleAttribution.Unattributed;
        return QuotaMetadataMatchesScope(metadata, scope)
            ? QuotaCycleAttribution.Target : QuotaCycleAttribution.Foreign;
    }

    private static QuotaCycleMetadataIndex ReadQuotaCycleMetadataIndex(
        SQLiteConnection db,
        List<OffsetRange> ranges,
        HashSet<string> relevantPaths,
        QuotaCycleScope scope,
        DateTimeOffset startedExclusive,
        DateTimeOffset endedInclusive,
        string broadStart,
        string broadEnd,
        CancellationToken cancellationToken)
    {
        var index = new QuotaCycleMetadataIndex();
        if (db == null || ranges == null || ranges.Count == 0 || scope == null) return index;

        // Only rows in the frozen offsets are considered.  For each path keep
        // the latest pre-interval metadata row (bounded by the interval start)
        // plus all rows in the interval.  This avoids scanning the entire
        // historical index while still allowing a candidate to inherit a
        // same-session cycle at the exact frozen boundary.
        for (int rangeIndex = 0; rangeIndex < ranges.Count; rangeIndex++)
        {
            if ((rangeIndex & 31) == 0) cancellationToken.ThrowIfCancellationRequested();
            OffsetRange range = ranges[rangeIndex];
            if (relevantPaths != null && !relevantPaths.Contains(range.Path)) continue;
            using (var current = db.CreateCommand())
            {
                current.CommandText =
                    "SELECT id,session_id,timestamp,source_path,source_offset_end," +
                    "five_hour_used,five_hour_window,five_hour_resets,weekly_used,weekly_window,weekly_resets,plan_type,rate_limit_id " +
                    "FROM token_records WHERE source_path=@path AND source_offset_end>0 " +
                    "AND source_offset_end<=@end AND timestamp>=@broad_start AND timestamp<@broad_end " +
                    "ORDER BY source_offset_end ASC,id ASC";
                current.Parameters.AddWithValue("@path", range.Path);
                current.Parameters.AddWithValue("@end", range.End);
                current.Parameters.AddWithValue("@broad_start", broadStart);
                current.Parameters.AddWithValue("@broad_end", broadEnd);
                using (var reader = current.ExecuteReader())
                {
                    int inspected = 0;
                    while (reader.Read())
                    {
                        if ((inspected++ & 255) == 0) cancellationToken.ThrowIfCancellationRequested();
                        AddQuotaCycleMetadataRecord(index, reader, scope);
                    }
                }
            }
            using (var baseline = db.CreateCommand())
            {
                baseline.CommandText =
                    "SELECT id,session_id,timestamp,source_path,source_offset_end," +
                    "five_hour_used,five_hour_window,five_hour_resets,weekly_used,weekly_window,weekly_resets,plan_type,rate_limit_id " +
                    "FROM token_records WHERE source_path=@path AND source_offset_end>0 " +
                    "AND source_offset_end<=@end AND timestamp<=@at " +
                    "AND (five_hour_used IS NOT NULL OR five_hour_window IS NOT NULL OR five_hour_resets IS NOT NULL " +
                    "OR weekly_used IS NOT NULL OR weekly_window IS NOT NULL OR weekly_resets IS NOT NULL " +
                    "OR COALESCE(plan_type,'')<>'' OR COALESCE(rate_limit_id,'')<>'') " +
                    "ORDER BY source_offset_end DESC,id DESC LIMIT 1";
                baseline.Parameters.AddWithValue("@path", range.Path);
                baseline.Parameters.AddWithValue("@end", range.End);
                baseline.Parameters.AddWithValue("@at", startedExclusive.UtcDateTime.ToString(
                    "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", CultureInfo.InvariantCulture));
                using (var reader = baseline.ExecuteReader())
                {
                    if (reader.Read()) AddQuotaCycleMetadataRecord(index, reader, scope);
                }
            }
        }
        index.Sort();
        return index;
    }

    private static void AddQuotaCycleMetadataRecord(
        QuotaCycleMetadataIndex index,
        SQLiteDataReader reader,
        QuotaCycleScope scope)
    {
        if (index == null || reader == null || scope == null) return;
        DateTimeOffset observedAt;
        if (!TryParseTimestamp(ReadReaderString(reader, 2), out observedAt)) return;
        QuotaCycleMetadata metadata = ReadQuotaCycleMetadataFromIndexRow(reader, scope);
        if (metadata == null || !metadata.HasAny) return;
        index.Add(new QuotaCycleMetadataRecord {
            Id = ReadReaderInt64(reader, 0),
            SessionId = ReadReaderString(reader, 1),
            ObservedAt = observedAt,
            SourcePath = ReadReaderString(reader, 3),
            SourceOffsetEnd = ReadReaderInt64(reader, 4),
            Metadata = metadata
        });
    }

    private static QuotaCycleMetadata ReadQuotaCycleMetadataFromIndexRow(
        SQLiteDataReader reader, QuotaCycleScope scope)
    {
        if (reader == null || scope == null) return null;
        // Index-row ordinals: id,session,timestamp,path,offset then the six
        // per-window fields followed by plan_type/rate_limit_id.
        int usedOrdinal = string.Equals(scope.WindowKind, "Weekly", StringComparison.OrdinalIgnoreCase)
            ? 8 : 5;
        int windowOrdinal = string.Equals(scope.WindowKind, "Weekly", StringComparison.OrdinalIgnoreCase)
            ? 9 : 6;
        int resetOrdinal = string.Equals(scope.WindowKind, "Weekly", StringComparison.OrdinalIgnoreCase)
            ? 10 : 7;
        bool hasUsed = !reader.IsDBNull(usedOrdinal);
        bool hasWindow = !reader.IsDBNull(windowOrdinal);
        bool hasReset = !reader.IsDBNull(resetOrdinal);
        string plan = ReadReaderString(reader, 11);
        string limit = ReadReaderString(reader, 12);
        var metadata = new QuotaCycleMetadata {
            HasAny = hasUsed || hasWindow || hasReset ||
                !string.IsNullOrWhiteSpace(plan) || !string.IsNullOrWhiteSpace(limit),
            HasTargetWindowMetadata = hasUsed || hasWindow || hasReset,
            PlanType = plan,
            RateLimitId = limit
        };
        if (hasWindow && hasReset)
        {
            int window;
            long reset;
            if (TryConvertInt32(reader.GetValue(windowOrdinal), out window) &&
                TryConvertInt64(reader.GetValue(resetOrdinal), out reset) &&
                window > 0 && reset > 0L)
            {
                metadata.HasKnownCycle = true;
                metadata.WindowMinutes = window;
                metadata.ResetUnixSeconds = reset;
            }
        }
        return metadata.HasAny ? metadata : null;
    }

    private static long ResolveAggregateLongContextThreshold(string model, Dictionary<string, long> thresholds)
    {
        if (string.IsNullOrWhiteSpace(model) || thresholds == null) return 0L;
        long exact;
        if (thresholds.TryGetValue(model, out exact)) return exact;
        string normalized = model.Trim();
        string bestKey = null;
        long bestThreshold = 0L;
        foreach (KeyValuePair<string, long> entry in thresholds)
        {
            string key = entry.Key ?? "";
            if (key.Length == 0 || !normalized.StartsWith(key + "-20", StringComparison.OrdinalIgnoreCase)) continue;
            if (bestKey == null || key.Length > bestKey.Length)
            {
                bestKey = key;
                bestThreshold = entry.Value;
            }
        }
        return bestThreshold;
    }

    private static void SeedAggregateCumulativeSnapshot(
        SQLiteConnection db,
        OffsetRange range,
        AggregateCumulativeSnapshotIndex seenCumulativeSnapshots,
        Dictionary<string, List<AggregateEventCandidate>> lineageGroups,
        Dictionary<string, string> parentBySession,
        TokenRaderIntervalAggregateResult result,
        QuotaCycleScope quotaScope = null,
        QuotaCycleMetadataIndex quotaMetadataIndex = null)
    {
        if (db == null || range == null || range.Start <= 0L || seenCumulativeSnapshots == null) return;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = BuildAggregateRecordSelect(quotaScope != null) +
                "FROM token_records WHERE source_path=@path AND source_offset_end<=@start " +
                "ORDER BY source_offset_end DESC LIMIT 1";
            cmd.Parameters.AddWithValue("@path", range.Path);
            cmd.Parameters.AddWithValue("@start", range.Start);
            using (var reader = cmd.ExecuteReader())
            {
                if (!reader.Read()) return;
                SeedAggregateLineageFromReader(reader, seenCumulativeSnapshots,
                    lineageGroups, parentBySession, result, db,
                    quotaScope, quotaMetadataIndex);
            }
        }
    }

    private static void SeedAggregateLineageFromReader(
        SQLiteDataReader reader,
        AggregateCumulativeSnapshotIndex seenCumulativeSnapshots,
        Dictionary<string, List<AggregateEventCandidate>> lineageGroups,
        Dictionary<string, string> parentBySession,
        TokenRaderIntervalAggregateResult result,
        SQLiteConnection db = null,
        QuotaCycleScope quotaScope = null,
        QuotaCycleMetadataIndex quotaMetadataIndex = null)
    {
        if (reader == null) return;
        string sessionId = ReadReaderString(reader, 0);
        string model = ReadReaderString(reader, 2);
        long totalInput = ReadReaderInt64(reader, 3);
        long totalCached = ReadReaderInt64(reader, 4);
        long totalOutput = ReadReaderInt64(reader, 5);
        long totalReasoning = ReadReaderInt64(reader, 6);
        long callInput = ReadReaderInt64(reader, 7);
        long callCached = ReadReaderInt64(reader, 8);
        long callOutput = ReadReaderInt64(reader, 9);
        long callReasoning = ReadReaderInt64(reader, 10);
        string requestId = ReadReaderString(reader, 16);
        string responseId = ReadReaderString(reader, 17);
        string identitySource = ReadReaderString(reader, 18);
        long rowId = quotaScope == null ? 0L : ReadReaderInt64(reader, 27);
        string serviceTier = NormalizeServiceTier(ReadReaderString(reader, 25));
        string serviceTierSource = NormalizeServiceTierSource(ReadReaderString(reader, 26), serviceTier);
        if (seenCumulativeSnapshots != null)
            seenCumulativeSnapshots.Observe(BuildAggregateCumulativeKey(sessionId,
                totalInput, totalCached, totalOutput, totalReasoning,
                requestId, responseId, identitySource), sessionId,
                serviceTier, serviceTierSource);
        if ((callInput <= 0L && callOutput <= 0L) || lineageGroups == null || result == null) return;

        DateTimeOffset eventAt;
        bool hasTimestamp = TryParseTimestamp(ReadReaderString(reader, 1), out eventAt);
        if (!hasTimestamp) eventAt = DateTimeOffset.MinValue;
        string rootSessionId = ReadReaderString(reader, 14);
        if (string.IsNullOrWhiteSpace(rootSessionId)) rootSessionId = sessionId;
        string fingerprint = ReadReaderString(reader, 11);
        string eventKey = BuildAggregateEventKey(rootSessionId, eventAt, model,
            totalInput, totalCached, totalOutput, totalReasoning,
            callInput, callCached, callOutput, callReasoning, fingerprint);
        var candidate = new AggregateEventCandidate {
                Id = rowId,
                SourceOffsetEnd = ReadReaderInt64(reader, 13),
                SessionId = sessionId,
                RootSessionId = rootSessionId,
                SourcePath = ReadReaderString(reader, 12),
                Model = model,
                ServiceTier = serviceTier,
                ServiceTierObservable = !string.IsNullOrWhiteSpace(serviceTier),
                ServiceTierSource = serviceTierSource,
                EventAt = eventAt,
                HasTimestamp = hasTimestamp,
                TurnId = ReadReaderString(reader, 15),
                RequestId = requestId,
                ResponseId = responseId,
                IdentitySource = identitySource,
                ModelContextWindow = ReadReaderInt64(reader, 19),
                LongContextThreshold = ReadReaderInt64(reader, 20),
                LongContextApplied = ReadReaderInt64(reader, 21) != 0L,
                LongContextSource = ReadReaderString(reader, 22),
                CacheCreationTokens = ReadReaderInt64(reader, 23),
                CacheWriteObservable = ReadReaderInt64(reader, 24) != 0L,
                CallInput = callInput,
                CallCached = callCached,
                CallOutput = callOutput,
                CallReasoning = callReasoning,
                IncludeInResult = false,
                QuotaMetadata = quotaScope == null ? null : ReadQuotaCycleMetadata(reader, quotaScope)
            };
        if (quotaScope != null)
            candidate.QuotaAttribution = ResolveQuotaCycleAttribution(
                candidate, quotaScope, quotaMetadataIndex);
        AddAggregateLineageCandidate(lineageGroups, eventKey,
            candidate, parentBySession, result);
        seenCumulativeSnapshots.Register(BuildAggregateCumulativeKey(sessionId,
            totalInput, totalCached, totalOutput, totalReasoning,
            requestId, responseId, identitySource), candidate);
    }

    private static string BuildAggregateCumulativeKey(
        string sessionId,
        long totalInput,
        long totalCached,
        long totalOutput,
        long totalReasoning,
        string requestId = "",
        string responseId = "",
        string identitySource = "")
    {
        // Cumulative totals identify ordinary status refreshes only while no
        // stronger lifecycle identity is available. Distinct request/response
        // ids must survive this early gate and reach lineage reconciliation.
        string strongIdentity = !string.IsNullOrWhiteSpace(requestId)
            ? "|request:" + requestId.ToLowerInvariant()
            : (!string.IsNullOrWhiteSpace(responseId)
                ? "|response:" + responseId.ToLowerInvariant()
                : "");
        string fallbackIdentity = IsMissingTotalIdentitySource(identitySource)
            ? "|fallback:" + (identitySource ?? "") : "";
        return (sessionId ?? "").ToLowerInvariant() + strongIdentity + fallbackIdentity + "|" +
            string.Format(CultureInfo.InvariantCulture, "{0}:{1}:{2}:{3}",
                totalInput, totalCached, totalOutput, totalReasoning);
    }

    private static bool IsMissingTotalIdentitySource(string identitySource)
    {
        return !string.IsNullOrWhiteSpace(identitySource) &&
            identitySource.StartsWith("missing_total", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsMissingLastIdentitySource(string identitySource)
    {
        return string.Equals(identitySource ?? "", "missing_last",
            StringComparison.OrdinalIgnoreCase);
    }

    private static string BuildAggregateEventKey(
        string rootSessionId,
        DateTimeOffset eventAt,
        string model,
        long totalInput,
        long totalCached,
        long totalOutput,
        long totalReasoning,
        long callInput,
        long callCached,
        long callOutput,
        long callReasoning,
        string fingerprint)
    {
        // Always rebuild the lineage fingerprint from cumulative and
        // per-call usage. The persisted parser fingerprint in current
        // indexes also contains timestamp and model; using it here would make
        // a copied parent/child call fail to deduplicate when either value
        // differs. Keeping the unused parameter preserves the ABI for older
        // callers and synthetic indexes.
        string usage = string.Format(CultureInfo.InvariantCulture,
            "{0}:{1}:{2}:{3}:{4}:{5}:{6}:{7}",
            totalInput, totalCached, totalOutput, totalReasoning,
            callInput, callCached, callOutput, callReasoning);
        // A parent and its descendant can serialize the same inherited call at
        // different times. Timestamp is therefore deliberately excluded from
        // the lineage identity. The caller still requires an actual ancestor-
        // descendant relationship, so identical sibling calls remain distinct.
        return (rootSessionId ?? "").ToLowerInvariant() + "|" + usage;
    }

    private static long ComputeRangeBytes(List<OffsetRange> ranges)
    {
        long bytes = 0L;
        if (ranges == null) return bytes;
        foreach (OffsetRange range in ranges)
        {
            long length = range.End == long.MaxValue ? 0L : Math.Max(0L, range.End - range.Start);
            if (long.MaxValue - bytes < length) return long.MaxValue;
            bytes += length;
        }
        return bytes;
    }

    private static string ReadReaderString(SQLiteDataReader reader, int ordinal)
    {
        if (reader.IsDBNull(ordinal)) return "";
        object value = reader.GetValue(ordinal);
        return Convert.ToString(value, CultureInfo.InvariantCulture) ?? "";
    }

    private static long ReadReaderInt64(SQLiteDataReader reader, int ordinal)
    {
        if (reader.IsDBNull(ordinal)) return 0L;
        long value;
        return TryConvertInt64(reader.GetValue(ordinal), out value) ? value : 0L;
    }

    private static void SetAggregateProgress(IDictionary progressState, long processedRows, string stage)
    {
        if (progressState == null) return;
        try
        {
            progressState["ProcessedRows"] = processedRows;
            progressState["LastProgressTicks"] = DateTimeOffset.UtcNow.Ticks;
            progressState["LastProgressAt"] = DateTimeOffset.Now;
            progressState["Stage"] = stage ?? "";
        }
        catch (Exception) { }
    }

    /// <summary>
    /// 按每文件结束边界分别返回最新的 5 小时和周额度记录。两个窗口
    /// 可以来自不同的日志记录；若同一记录同时携带两个窗口，只返回一次。
    /// </summary>
    public static DataTable QueryLatestRateLimitsByOffsets(SQLiteConnection db, DataTable fileRanges)
    {
        return QueryLatestRateLimitRowsByOffsetRanges(db, ReadOffsetRanges(fileRanges));
    }

    /// <summary>Hashtable 兼容重载，语义与 DataTable 版本相同。</summary>
    public static DataTable QueryLatestRateLimitsByOffsets(SQLiteConnection db, IDictionary startOffsets, IDictionary endOffsets)
    {
        return QueryLatestRateLimitRowsByOffsetRanges(db, ReadOffsetRanges(startOffsets, endOffsets));
    }

    /// <summary>
    /// Finds the most recent fully observed quota-percentage step within one
    /// immutable reset cycle. The returned table contains exactly two rows in
    /// chronological order: the earliest observation of the greatest usage
    /// value below currentUsedPercent, followed by the first later observation
    /// above that value. Callers can then aggregate token calls over the exact
    /// (start, end] snapshot interval. No token rows are materialized here.
    /// </summary>
    private static TokenRaderQuotaCalibrationPairDiagnostics QueryQuotaCalibrationPairWithDiagnosticsInternal(
        SQLiteConnection db,
        IDictionary endOffsets,
        string windowKind,
        int windowMinutes,
        long resetUnixSeconds,
        string planType,
        string rateLimitId,
        double currentUsedPercent,
        DateTimeOffset currentObservedAt,
        CancellationToken cancellationToken,
        bool strictScope,
        bool cumulativeCalibration = false,
        DateTimeOffset baselineObservedAt = default(DateTimeOffset),
        double baselineUsedPercent = double.NaN)
    {
        if (db == null) throw new ArgumentNullException("db");
        DataTable empty = CreateEmptyTokenRecordsTable(db);
        var diagnostics = new TokenRaderQuotaCalibrationPairDiagnostics { Rows = empty };
        if (endOffsets == null || windowMinutes <= 0 || resetUnixSeconds <= 0L ||
            currentUsedPercent <= 0.0 || double.IsNaN(currentUsedPercent) ||
            double.IsInfinity(currentUsedPercent)) return diagnostics;

        string usedColumn;
        string windowColumn;
        string resetColumn;
        if (string.Equals(windowKind, "FiveHour", StringComparison.OrdinalIgnoreCase))
        {
            usedColumn = "five_hour_used";
            windowColumn = "five_hour_window";
            resetColumn = "five_hour_resets";
        }
        else if (string.Equals(windowKind, "Weekly", StringComparison.OrdinalIgnoreCase))
        {
            usedColumn = "weekly_used";
            windowColumn = "weekly_window";
            resetColumn = "weekly_resets";
        }
        else
        {
            diagnostics.ReasonCode = "invalid_scope";
            return diagnostics;
        }

        List<OffsetRange> ranges = ReadAggregateOffsetRanges(null, endOffsets);
        if (ranges.Count == 0)
        {
            diagnostics.ReasonCode = "missing_metadata";
            return diagnostics;
        }
        var candidates = new List<QuotaSnapshotCandidate>();
        bool sawMetadataRows = false;
        const int chunkSize = 100;
        const double epsilon = 0.000000001;
        for (int offset = 0; offset < ranges.Count; offset += chunkSize)
        {
            cancellationToken.ThrowIfCancellationRequested();
            int count = Math.Min(chunkSize, ranges.Count - offset);
            using (var cmd = db.CreateCommand())
            {
                var predicates = new StringBuilder();
                for (int i = 0; i < count; i++)
                {
                    if (i > 0) predicates.Append(" OR ");
                    predicates.Append("(source_path=@path");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end>0 AND source_offset_end<=@end");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(")");
                    OffsetRange range = ranges[offset + i];
                    cmd.Parameters.AddWithValue("@path" + i.ToString(CultureInfo.InvariantCulture), range.Path);
                    cmd.Parameters.AddWithValue("@end" + i.ToString(CultureInfo.InvariantCulture), range.End);
                }
                cmd.CommandText =
                    "SELECT id,timestamp," + usedColumn + " FROM token_records WHERE (" + predicates + ") " +
                    "AND " + usedColumn + " IS NOT NULL AND " + windowColumn + "=@window " +
                    "AND " + resetColumn + ">=@reset_min AND " + resetColumn + "<=@reset_max " +
                    "AND (@plan_wildcard=1 OR plan_type=@plan COLLATE NOCASE) " +
                    "AND (@limit_wildcard=1 OR rate_limit_id=@limit_id COLLATE NOCASE)";
                cmd.Parameters.AddWithValue("@window", windowMinutes);
                long resetMinute = (long)Math.Floor(resetUnixSeconds / 60.0);
                cmd.Parameters.AddWithValue("@reset_min", resetMinute * 60L);
                cmd.Parameters.AddWithValue("@reset_max", resetMinute * 60L + 59L);
                cmd.Parameters.AddWithValue("@plan", planType ?? "");
                cmd.Parameters.AddWithValue("@limit_id", rateLimitId ?? "");
                cmd.Parameters.AddWithValue("@plan_wildcard", strictScope ? 0 :
                    (string.IsNullOrWhiteSpace(planType) ? 1 : 0));
                cmd.Parameters.AddWithValue("@limit_wildcard", strictScope ? 0 :
                    (string.IsNullOrWhiteSpace(rateLimitId) ? 1 : 0));
                using (var reader = cmd.ExecuteReader())
                {
                    int inspected = 0;
                    while (reader.Read())
                    {
                        if ((inspected++ & 255) == 0) cancellationToken.ThrowIfCancellationRequested();
                        sawMetadataRows = true;
                        DateTimeOffset observedAt;
                        double usedPercent;
                        if (!TryParseTimestamp(ReadReaderString(reader, 1), out observedAt) ||
                            !TryConvertDouble(reader.GetValue(2), out usedPercent) ||
                            observedAt > currentObservedAt || usedPercent < -epsilon || usedPercent > 100.0 + epsilon)
                            continue;
                        candidates.Add(new QuotaSnapshotCandidate {
                            Id = ReadReaderInt64(reader, 0),
                            ObservedAt = observedAt,
                            UsedPercent = usedPercent
                        });
                    }
                }
            }
        }
        if (candidates.Count < 2)
        {
            diagnostics.ReasonCode = sawMetadataRows ? "no_pair" : "missing_metadata";
            return diagnostics;
        }
        candidates.Sort(delegate(QuotaSnapshotCandidate left, QuotaSnapshotCandidate right) {
            int comparison = DateTimeOffset.Compare(left.ObservedAt.ToUniversalTime(), right.ObservedAt.ToUniversalTime());
            return comparison != 0 ? comparison : left.Id.CompareTo(right.Id);
        });

        // Concurrent sessions can append a slightly older snapshot after a
        // newer one. Build a monotonic envelope and ignore only those stale
        // regressions; if the envelope itself exceeds the current ending
        // snapshot, the current snapshot is stale and calibration is unsafe.
        var monotonicCandidates = new List<QuotaSnapshotCandidate>();
        double runningMaximum = -1.0;
        for (int i = 0; i < candidates.Count; i++)
        {
            double used = candidates[i].UsedPercent;
            if (used + epsilon < runningMaximum) continue;
            if (used > runningMaximum) runningMaximum = used;
            monotonicCandidates.Add(candidates[i]);
        }
        if (runningMaximum > currentUsedPercent + epsilon)
        {
            diagnostics.ReasonCode = "stale_snapshot";
            return diagnostics;
        }
        candidates = monotonicCandidates;

        double previousUsed = -1.0;
        for (int i = 0; i < candidates.Count; i++)
        {
            double used = candidates[i].UsedPercent;
            if (used < currentUsedPercent - epsilon && used > previousUsed) previousUsed = used;
        }
        if (previousUsed < -epsilon)
        {
            diagnostics.ReasonCode = "no_pair";
            return diagnostics;
        }

        QuotaSnapshotCandidate start = null;
        QuotaSnapshotCandidate end = null;
        for (int i = 0; i < candidates.Count; i++)
        {
            QuotaSnapshotCandidate point = candidates[i];
            if (start == null && Math.Abs(point.UsedPercent - previousUsed) <= epsilon)
            {
                start = point;
                continue;
            }
            if (start != null && point.ObservedAt > start.ObservedAt &&
                point.UsedPercent > previousUsed + epsilon &&
                point.UsedPercent <= currentUsedPercent + epsilon)
            {
                end = point;
                break;
            }
        }
        if (cumulativeCalibration)
        {
            // Reconstruct the anchor from frozen evidence, never from mutable UI
            // state. A changed cycle starts independently at its first snapshot.
            QuotaSnapshotCandidate baseline = null;
            foreach (QuotaSnapshotCandidate point in candidates)
            {
                if ((double.IsNaN(baselineUsedPercent) && point.ObservedAt >= baselineObservedAt) ||
                    (point.ObservedAt == baselineObservedAt &&
                     Math.Abs(point.UsedPercent - baselineUsedPercent) <= epsilon))
                { baseline = point; break; }
            }
            QuotaSnapshotCandidate anchor = null;
            if (baseline != null)
                foreach (QuotaSnapshotCandidate point in candidates)
                    if (point.ObservedAt > baseline.ObservedAt &&
                        point.UsedPercent - baseline.UsedPercent >= 1.0 - epsilon)
                    { anchor = point; break; }
            if (baseline != null && anchor == null && !double.IsNaN(baselineUsedPercent))
            {
                // A partial first percentage point must not replace the
                // historical fallback with an unfinished measurement step.
                double historicalPrevious = -1.0;
                foreach (QuotaSnapshotCandidate point in candidates)
                    if (point.ObservedAt <= baseline.ObservedAt &&
                        point.UsedPercent < baseline.UsedPercent - epsilon &&
                        point.UsedPercent > historicalPrevious)
                        historicalPrevious = point.UsedPercent;
                start = null;
                end = null;
                foreach (QuotaSnapshotCandidate point in candidates)
                {
                    if (point.ObservedAt > baseline.ObservedAt) break;
                    if (start == null && Math.Abs(point.UsedPercent - historicalPrevious) <= epsilon)
                        start = point;
                    else if (start != null && point.ObservedAt > start.ObservedAt &&
                        point.UsedPercent > historicalPrevious + epsilon)
                    { end = point; break; }
                }
            }
            if (anchor != null)
            {
                start = baseline;
                end = anchor;
                // Until a further real increase, retain the first full-step
                // evidence. Thereafter the anchor never slides forward.
                if (currentUsedPercent > anchor.UsedPercent + epsilon)
                    foreach (QuotaSnapshotCandidate point in candidates)
                        if (point.ObservedAt > anchor.ObservedAt &&
                            Math.Abs(point.UsedPercent - currentUsedPercent) <= epsilon)
                        { start = anchor; end = point; break; }
            }
        }
        if (start == null || end == null || end.UsedPercent <= start.UsedPercent + epsilon)
        {
            diagnostics.ReasonCode = "no_pair";
            return diagnostics;
        }

        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT * FROM token_records WHERE id=@start_id OR id=@end_id ORDER BY timestamp ASC,id ASC";
            cmd.Parameters.AddWithValue("@start_id", start.Id);
            cmd.Parameters.AddWithValue("@end_id", end.Id);
            var result = new DataTable();
            using (var adapter = new SQLiteDataAdapter(cmd)) { adapter.Fill(result); }
            if (result.Rows.Count == 2)
            {
                diagnostics.Rows = result;
                diagnostics.ReasonCode = "ok";
            }
            else diagnostics.ReasonCode = "no_pair";
            return diagnostics;
        }
    }

    /// <summary>
    /// Backwards-compatible selector returning only the historical DataTable.
    /// Diagnostics are intentionally discarded for callers compiled against
    /// the original API.
    /// </summary>
    public static DataTable QueryQuotaCalibrationPairByOffsets(
        SQLiteConnection db,
        IDictionary endOffsets,
        string windowKind,
        int windowMinutes,
        long resetUnixSeconds,
        string planType,
        string rateLimitId,
        double currentUsedPercent,
        DateTimeOffset currentObservedAt,
        CancellationToken cancellationToken)
    {
        TokenRaderQuotaCalibrationPairDiagnostics diagnostics =
            QueryQuotaCalibrationPairWithDiagnosticsInternal(db, endOffsets, windowKind,
                windowMinutes, resetUnixSeconds, planType, rateLimitId,
                currentUsedPercent, currentObservedAt, cancellationToken, false);
        return diagnostics == null || diagnostics.Rows == null
            ? CreateEmptyTokenRecordsTable(db) : diagnostics.Rows;
    }

    /// <summary>
    /// Validates quota endpoint evidence against every matching snapshot in
    /// the caller's frozen file-offset set.  This is deliberately streaming:
    /// it keeps only the two running maxima and endpoint-match flags, never
    /// sorts or substitutes a boundary snapshot, and accepts a legitimate
    /// zero-percent start endpoint.
    /// </summary>
    public static bool ValidateQuotaSnapshotPairByOffsets(
        SQLiteConnection db,
        IDictionary endOffsets,
        string windowKind,
        int windowMinutes,
        long resetUnixSeconds,
        string planType,
        string rateLimitId,
        double startUsedPercent,
        DateTimeOffset startObservedAt,
        double endUsedPercent,
        DateTimeOffset endObservedAt,
        CancellationToken cancellationToken)
    {
        if (db == null) throw new ArgumentNullException("db");
        if (endOffsets == null || windowMinutes <= 0 || resetUnixSeconds <= 0L ||
            double.IsNaN(startUsedPercent) || double.IsInfinity(startUsedPercent) ||
            double.IsNaN(endUsedPercent) || double.IsInfinity(endUsedPercent) ||
            startUsedPercent < 0.0 || startUsedPercent > 100.0 ||
            endUsedPercent < 0.0 || endUsedPercent > 100.0 ||
            endObservedAt <= startObservedAt) return false;

        string usedColumn;
        string windowColumn;
        string resetColumn;
        if (string.Equals(windowKind, "FiveHour", StringComparison.OrdinalIgnoreCase))
        {
            usedColumn = "five_hour_used";
            windowColumn = "five_hour_window";
            resetColumn = "five_hour_resets";
        }
        else if (string.Equals(windowKind, "Weekly", StringComparison.OrdinalIgnoreCase))
        {
            usedColumn = "weekly_used";
            windowColumn = "weekly_window";
            resetColumn = "weekly_resets";
        }
        else return false;

        List<OffsetRange> ranges = ReadAggregateOffsetRanges(null, endOffsets);
        if (ranges.Count == 0) return false;

        const double epsilon = 0.000000001;
        double maximumAtStart = -1.0;
        double maximumAtEnd = -1.0;
        bool matchedStart = false;
        bool matchedEnd = false;
        const int chunkSize = 100;
        long resetMinute = (long)Math.Floor(resetUnixSeconds / 60.0);
        for (int offset = 0; offset < ranges.Count; offset += chunkSize)
        {
            cancellationToken.ThrowIfCancellationRequested();
            int count = Math.Min(chunkSize, ranges.Count - offset);
            using (var cmd = db.CreateCommand())
            {
                var predicates = new StringBuilder();
                for (int i = 0; i < count; i++)
                {
                    if (i > 0) predicates.Append(" OR ");
                    predicates.Append("(source_path=@path");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end>0 AND source_offset_end<=@end");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(")");
                    OffsetRange range = ranges[offset + i];
                    cmd.Parameters.AddWithValue("@path" + i.ToString(CultureInfo.InvariantCulture), range.Path);
                    cmd.Parameters.AddWithValue("@end" + i.ToString(CultureInfo.InvariantCulture), range.End);
                }
                cmd.CommandText =
                    "SELECT timestamp," + usedColumn + " FROM token_records WHERE (" + predicates + ") " +
                    "AND " + usedColumn + " IS NOT NULL AND " + windowColumn + "=@window " +
                    "AND " + resetColumn + ">=@reset_min AND " + resetColumn + "<=@reset_max " +
                    "AND (@plan='' OR plan_type=@plan COLLATE NOCASE) " +
                    "AND (@limit_id='' OR rate_limit_id=@limit_id COLLATE NOCASE)";
                cmd.Parameters.AddWithValue("@window", windowMinutes);
                cmd.Parameters.AddWithValue("@reset_min", resetMinute * 60L);
                cmd.Parameters.AddWithValue("@reset_max", resetMinute * 60L + 59L);
                cmd.Parameters.AddWithValue("@plan", planType ?? "");
                cmd.Parameters.AddWithValue("@limit_id", rateLimitId ?? "");
                using (var reader = cmd.ExecuteReader())
                {
                    int inspected = 0;
                    while (reader.Read())
                    {
                        if ((inspected++ & 255) == 0) cancellationToken.ThrowIfCancellationRequested();
                        DateTimeOffset observedAt;
                        double usedPercent;
                        if (!TryParseTimestamp(ReadReaderString(reader, 0), out observedAt) ||
                            !TryConvertDouble(reader.GetValue(1), out usedPercent) ||
                            usedPercent < -epsilon || usedPercent > 100.0 + epsilon ||
                            observedAt > endObservedAt) continue;
                        if (usedPercent < 0.0) usedPercent = 0.0;
                        if (usedPercent > 100.0) usedPercent = 100.0;

                        if (observedAt <= startObservedAt)
                        {
                            if (usedPercent > maximumAtStart) maximumAtStart = usedPercent;
                            if (observedAt == startObservedAt &&
                                Math.Abs(usedPercent - startUsedPercent) <= epsilon)
                                matchedStart = true;
                        }
                        if (observedAt <= endObservedAt)
                        {
                            if (usedPercent > maximumAtEnd) maximumAtEnd = usedPercent;
                            if (observedAt == endObservedAt &&
                                Math.Abs(usedPercent - endUsedPercent) <= epsilon)
                                matchedEnd = true;
                        }
                    }
                }
            }
        }

        return matchedStart && matchedEnd && maximumAtStart >= -epsilon &&
            maximumAtEnd >= -epsilon && maximumAtStart <= startUsedPercent + epsilon &&
            maximumAtEnd <= endUsedPercent + epsilon;
    }

    public static void UpdateFileMetadata(SQLiteConnection db, string path, long length, long lastWriteTicks, long parsedOffset)
    {
        // Keep relationship metadata untouched for callers compiled against
        // the original five-argument API; touching a file restores retained
        // content after a previous retention purge.
        UpsertFileMetadata(db, path, length, lastWriteTicks, parsedOffset, null, null, null, null, null, false);
    }

    /// <summary>
    /// 更新文件元数据及其会话关系字段。
    /// 参数顺序保留原有四个文件状态字段，新增 session_id/cwd/
    /// parent_thread_id/forked_from_id；这样旧 PowerShell 调用仍可使用
    /// 五参数重载，新索引器调用可一次写入完整元数据。
    /// </summary>
    public static void UpdateFileMetadata(
        SQLiteConnection db,
        string path,
        long length,
        long lastWriteTicks,
        long parsedOffset,
        string sessionId,
        string cwd,
        string parentThreadId,
        string forkedFromId)
    {
        string rootSessionId = !string.IsNullOrWhiteSpace(parentThreadId)
            ? parentThreadId
            : (!string.IsNullOrWhiteSpace(forkedFromId) ? forkedFromId : (sessionId ?? ""));
        UpsertFileMetadata(db, path, length, lastWriteTicks, parsedOffset,
            sessionId, cwd, parentThreadId, forkedFromId, rootSessionId, true);
    }

    /// <summary>
    /// 更新文件元数据，并显式写入任务树根会话。旧的九参数重载仍然
    /// 可用；当调用方没有根提示时，它会使用 parent/fork/session 的首个
    /// 非空值作为兼容的 root_session_id。
    /// </summary>
    public static void UpdateFileMetadata(
        SQLiteConnection db,
        string path,
        long length,
        long lastWriteTicks,
        long parsedOffset,
        string sessionId,
        string cwd,
        string parentThreadId,
        string forkedFromId,
        string rootSessionId)
    {
        string effectiveRoot = string.IsNullOrWhiteSpace(rootSessionId)
            ? (!string.IsNullOrWhiteSpace(parentThreadId)
                ? parentThreadId
                : (!string.IsNullOrWhiteSpace(forkedFromId) ? forkedFromId : (sessionId ?? "")))
            : rootSessionId;
        UpsertFileMetadata(db, path, length, lastWriteTicks, parsedOffset,
            sessionId, cwd, parentThreadId, forkedFromId, effectiveRoot, true);
    }

    /// <summary>
    /// Applies a newly resolved canonical task root to both the lightweight
    /// file catalog and all retained token rows. This repairs descendants that
    /// were indexed before their parent or root session metadata arrived.
    /// Returns the number of rows whose root changed.
    /// </summary>
    public static int BackfillSessionRoots(SQLiteConnection db, IDictionary sessionRoots, long indexRevision)
    {
        if (db == null) throw new ArgumentNullException("db");
        if (sessionRoots == null || sessionRoots.Count == 0) return 0;

        int affected = 0;
        using (var tx = db.BeginTransaction())
        using (var metadata = db.CreateCommand())
        using (var records = db.CreateCommand())
        using (var toolRecords = db.CreateCommand())
        {
            metadata.Transaction = tx;
            metadata.CommandText =
                "UPDATE file_metadata SET root_session_id=@root " +
                "WHERE session_id=@session AND (root_session_id IS NULL OR root_session_id<>@root)";
            metadata.Parameters.Add(new SQLiteParameter("@root"));
            metadata.Parameters.Add(new SQLiteParameter("@session"));

            records.Transaction = tx;
            records.CommandText =
                "UPDATE token_records SET root_session_id=@root,index_revision=@revision " +
                "WHERE session_id=@session AND (root_session_id IS NULL OR root_session_id<>@root)";
            records.Parameters.Add(new SQLiteParameter("@root"));
            records.Parameters.Add(new SQLiteParameter("@revision"));
            records.Parameters.Add(new SQLiteParameter("@session"));

            toolRecords.Transaction = tx;
            toolRecords.CommandText =
                "UPDATE tool_records SET root_session_id=@root,index_revision=@revision " +
                "WHERE session_id=@session AND (root_session_id IS NULL OR root_session_id<>@root)";
            toolRecords.Parameters.Add(new SQLiteParameter("@root"));
            toolRecords.Parameters.Add(new SQLiteParameter("@revision"));
            toolRecords.Parameters.Add(new SQLiteParameter("@session"));

            foreach (DictionaryEntry entry in sessionRoots)
            {
                string session = entry.Key == null ? "" : Convert.ToString(entry.Key, CultureInfo.InvariantCulture);
                string root = entry.Value == null ? "" : Convert.ToString(entry.Value, CultureInfo.InvariantCulture);
                if (string.IsNullOrWhiteSpace(session) || string.IsNullOrWhiteSpace(root)) continue;

                metadata.Parameters["@root"].Value = root;
                metadata.Parameters["@session"].Value = session;
                affected += metadata.ExecuteNonQuery();

                records.Parameters["@root"].Value = root;
                records.Parameters["@revision"].Value = Math.Max(0L, indexRevision);
                records.Parameters["@session"].Value = session;
                affected += records.ExecuteNonQuery();

                toolRecords.Parameters["@root"].Value = root;
                toolRecords.Parameters["@revision"].Value = Math.Max(0L, indexRevision);
                toolRecords.Parameters["@session"].Value = session;
                affected += toolRecords.ExecuteNonQuery();
            }
            tx.Commit();
        }
        return affected;
    }

    /// <summary>
    /// Repairs only retained token rows whose model is empty. The source file
    /// is streamed once, and only turn_context/token_count line boundaries are
    /// considered. Parent/root fallbacks come from indexed relationship
    /// metadata; prompt and response content is never copied to the database.
    /// </summary>
    public static TokenRaderModelBackfillResult BackfillMissingTokenModels(SQLiteConnection db)
    {
        if (db == null) throw new ArgumentNullException("db");
        var result = new TokenRaderModelBackfillResult();
        string version = GetSetting(db, "missing_model_backfill_version");
        if (string.Equals(version, "1", StringComparison.Ordinal))
        {
            result.Completed = true;
            result.IndexRevision = GetIndexRevision(db);
            result.UnresolvedRows = CountMissingTokenModels(db);
            return result;
        }

        var candidates = new DataTable();
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT tr.source_path,tr.session_id,MIN(tr.source_offset_end) AS first_offset," +
                "MAX(tr.source_offset_end) AS last_offset," +
                "COALESCE(fm.parent_thread_id,''),COALESCE(fm.forked_from_id,'')," +
                "COALESCE(fm.root_session_id,tr.root_session_id,'') " +
                "FROM token_records tr LEFT JOIN file_metadata fm ON fm.path=tr.source_path " +
                "WHERE (tr.model IS NULL OR tr.model='') AND tr.source_path<>'' AND tr.source_offset_end>0 " +
                "GROUP BY tr.source_path,tr.session_id";
            using (var adapter = new SQLiteDataAdapter(cmd)) adapter.Fill(candidates);
        }
        result.CandidateFiles = candidates.Rows.Count;
        long targetRevision = GetIndexRevision(db) + 1L;
        var failedSourcePaths = new List<string>();

        foreach (DataRow row in candidates.Rows)
        {
            string sourcePath = Convert.ToString(row[0], CultureInfo.InvariantCulture) ?? "";
            string sessionId = Convert.ToString(row[1], CultureInfo.InvariantCulture) ?? "";
            long firstOffset = Convert.ToInt64(row[2], CultureInfo.InvariantCulture);
            long lastOffset = Convert.ToInt64(row[3], CultureInfo.InvariantCulture);
            string parentSessionId = Convert.ToString(row[4], CultureInfo.InvariantCulture) ?? "";
            if (string.IsNullOrWhiteSpace(parentSessionId))
                parentSessionId = Convert.ToString(row[5], CultureInfo.InvariantCulture) ?? "";
            string rootSessionId = Convert.ToString(row[6], CultureInfo.InvariantCulture) ?? "";

            try
            {
                string modelSource;
                string currentModel = GetLatestSourceModelBefore(db, sourcePath, firstOffset);
                if (!string.IsNullOrWhiteSpace(currentModel)) modelSource = "same_session";
                // Do not use a later same-session model for rows that precede
                // the child's first turn_context. Only an earlier row in this
                // same source is valid; otherwise ancestry supplies the model.
                else currentModel = ResolveInheritedModel(db, "", parentSessionId, rootSessionId, out modelSource);

                var targetOffsets = ReadMissingModelOffsets(db, sourcePath);
                if (File.Exists(sourcePath))
                {
                    using (var fs = new FileStream(sourcePath, FileMode.Open, FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete))
                    using (var reader = new Utf8JsonlLineReader(fs, 0L, Math.Min(fs.Length, lastOffset)))
                    {
                        string line; long lineEndOffset; bool lineTerminated;
                        while (reader.ReadLine(out line, out lineEndOffset, out lineTerminated))
                        {
                            if (!lineTerminated) break;
                            if (string.IsNullOrWhiteSpace(line)) continue;
                            line = line.TrimStart('\uFEFF');
                            TokenRaderJsonRecord metadataRecord;
                            if (TryDeserializeMetadataRecord(line, out metadataRecord) &&
                                string.Equals(metadataRecord.Type, "turn_context", StringComparison.OrdinalIgnoreCase))
                            {
                                string model;
                                bool modelPresent;
                                if (TryGetTurnContextModel(line, out model, out modelPresent) && modelPresent)
                                {
                                    currentModel = model ?? "";
                                    modelSource = string.IsNullOrWhiteSpace(currentModel)
                                        ? "turn_context_missing" : "turn_context";
                                }
                                else
                                {
                                    currentModel = "";
                                    modelSource = "turn_context_missing";
                                }
                                continue;
                            }
                            if (!line.Contains("token_count") || !targetOffsets.Contains(lineEndOffset)) continue;
                            result.UpdatedRows += UpdateMissingModelAtOffset(db, sourcePath, lineEndOffset,
                                currentModel, modelSource, targetRevision);
                            targetOffsets.Remove(lineEndOffset);
                        }
                    }
                    // If a file was replaced after it was indexed, byte
                    // offsets are no longer trustworthy. Leave the completion
                    // marker unset so the next full sync can replace/retry it.
                    if (targetOffsets.Count > 0) throw new IOException("Token model offsets no longer match the source file.");
                }
                else
                {
                    // Missing retained source files can still be repaired from
                    // explicit ancestry. Truly orphaned rows remain unresolved.
                    result.UpdatedRows += UpdateMissingModelsForSource(db, sourcePath,
                        currentModel, modelSource, targetRevision);
                }
                result.ProcessedFiles++;
            }
            catch
            {
                result.FailedFiles++;
                failedSourcePaths.Add(sourcePath);
            }
        }

        if (result.UpdatedRows > 0L) result.IndexRevision = IncrementIndexRevision(db);
        else result.IndexRevision = GetIndexRevision(db);
        result.UnresolvedRows = CountMissingTokenModels(db);
        result.Completed = result.FailedFiles == 0;
        result.FailedSourcePaths = failedSourcePaths.ToArray();
        if (result.Completed) SetSetting(db, "missing_model_backfill_version", "1");
        return result;
    }

    private static HashSet<long> ReadMissingModelOffsets(SQLiteConnection db, string sourcePath)
    {
        var result = new HashSet<long>();
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT source_offset_end FROM token_records WHERE source_path=@path AND source_offset_end>0 AND (model IS NULL OR model='')";
            cmd.Parameters.AddWithValue("@path", sourcePath ?? "");
            using (var reader = cmd.ExecuteReader())
                while (reader.Read()) result.Add(ReadReaderInt64(reader, 0));
        }
        return result;
    }

    private static string GetLatestSourceModelBefore(SQLiteConnection db, string sourcePath, long offset)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT model FROM token_records WHERE source_path=@path AND source_offset_end>0 AND source_offset_end<@offset AND model<>'' ORDER BY source_offset_end DESC LIMIT 1";
            cmd.Parameters.AddWithValue("@path", sourcePath ?? "");
            cmd.Parameters.AddWithValue("@offset", offset);
            object value = cmd.ExecuteScalar();
            return value == null || value == DBNull.Value ? "" : (Convert.ToString(value, CultureInfo.InvariantCulture) ?? "");
        }
    }

    private static int UpdateMissingModelAtOffset(SQLiteConnection db, string sourcePath, long offset,
        string model, string modelSource, long indexRevision)
    {
        long threshold = !string.IsNullOrWhiteSpace(model) && IsKnownLongContextModel(model) ? 272000L : 0L;
        string longSource = string.IsNullOrWhiteSpace(model) ? "unknown_model" :
            (threshold > 0L ? "pricing_threshold" : "no_threshold");
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "UPDATE token_records SET model=@model,model_source=@source,index_revision=@revision,long_context_threshold=@threshold,long_context_applied=CASE WHEN @threshold>0 AND call_input>@threshold THEN 1 ELSE 0 END,long_context_source=@long_source WHERE source_path=@path AND source_offset_end=@offset AND (model IS NULL OR model='')";
            cmd.Parameters.AddWithValue("@model", model ?? "");
            cmd.Parameters.AddWithValue("@source", string.IsNullOrWhiteSpace(model) ? "unresolved" : (modelSource ?? "unresolved"));
            cmd.Parameters.AddWithValue("@revision", indexRevision);
            cmd.Parameters.AddWithValue("@threshold", threshold > 0L ? (object)threshold : DBNull.Value);
            cmd.Parameters.AddWithValue("@long_source", longSource);
            cmd.Parameters.AddWithValue("@path", sourcePath ?? "");
            cmd.Parameters.AddWithValue("@offset", offset);
            return cmd.ExecuteNonQuery();
        }
    }

    private static int UpdateMissingModelsForSource(SQLiteConnection db, string sourcePath,
        string model, string modelSource, long indexRevision)
    {
        long threshold = !string.IsNullOrWhiteSpace(model) && IsKnownLongContextModel(model) ? 272000L : 0L;
        string longSource = string.IsNullOrWhiteSpace(model) ? "unknown_model" :
            (threshold > 0L ? "pricing_threshold" : "no_threshold");
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "UPDATE token_records SET model=@model,model_source=@source,index_revision=@revision,long_context_threshold=@threshold,long_context_applied=CASE WHEN @threshold>0 AND call_input>@threshold THEN 1 ELSE 0 END,long_context_source=@long_source WHERE source_path=@path AND (model IS NULL OR model='')";
            cmd.Parameters.AddWithValue("@model", model ?? "");
            cmd.Parameters.AddWithValue("@source", string.IsNullOrWhiteSpace(model) ? "unresolved" : (modelSource ?? "unresolved"));
            cmd.Parameters.AddWithValue("@revision", indexRevision);
            cmd.Parameters.AddWithValue("@threshold", threshold > 0L ? (object)threshold : DBNull.Value);
            cmd.Parameters.AddWithValue("@long_source", longSource);
            cmd.Parameters.AddWithValue("@path", sourcePath ?? "");
            return cmd.ExecuteNonQuery();
        }
    }

    private static long CountMissingTokenModels(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT COUNT(*) FROM token_records WHERE model IS NULL OR model=''";
            return Convert.ToInt64(cmd.ExecuteScalar(), CultureInfo.InvariantCulture);
        }
    }

    private static void UpsertFileContextTier(
        SQLiteConnection db,
        SQLiteTransaction tx,
        string path,
        string sessionId,
        string rootSessionId,
        long parsedOffset,
        string serviceTier,
        string serviceTierSource)
    {
        if (db == null || tx == null || string.IsNullOrWhiteSpace(path)) return;
        string normalizedTier = NormalizeServiceTier(serviceTier);
        string normalizedSource = NormalizeServiceTierSource(serviceTierSource, normalizedTier);
        using (var update = db.CreateCommand())
        {
            update.Transaction = tx;
            update.CommandText =
                "UPDATE file_metadata SET turn_context_service_tier=@tier,turn_context_service_tier_source=@source WHERE path=@path";
            update.Parameters.AddWithValue("@tier", normalizedTier);
            update.Parameters.AddWithValue("@source", normalizedSource);
            update.Parameters.AddWithValue("@path", path);
            if (update.ExecuteNonQuery() > 0) return;
        }

        // ImportFile is also a public low-level API and can be called before
        // the normal indexer has inserted its catalog row.  Seed a minimal
        // row so a trailing turn_context (even with no token_count yet) is
        // available to the next incremental import; the normal metadata
        // upsert will fill authoritative file times/relationships later.
        using (var insert = db.CreateCommand())
        {
            insert.Transaction = tx;
            insert.CommandText =
                "INSERT OR IGNORE INTO file_metadata (path,length,last_write_ticks,parsed_offset,session_id,content_retained,root_session_id,turn_context_service_tier,turn_context_service_tier_source) " +
                "VALUES (@path,@length,0,@offset,@session,1,@root,@tier,@source)";
            insert.Parameters.AddWithValue("@path", path);
            insert.Parameters.AddWithValue("@length", Math.Max(0L, parsedOffset));
            insert.Parameters.AddWithValue("@offset", Math.Max(0L, parsedOffset));
            insert.Parameters.AddWithValue("@session", sessionId ?? "");
            insert.Parameters.AddWithValue("@root", rootSessionId ?? "");
            insert.Parameters.AddWithValue("@tier", normalizedTier);
            insert.Parameters.AddWithValue("@source", normalizedSource);
            insert.ExecuteNonQuery();
        }
    }

    private static void UpsertFileContextModel(
        SQLiteConnection db,
        SQLiteTransaction tx,
        string path,
        string sessionId,
        string rootSessionId,
        long parsedOffset,
        string model,
        string modelSource,
        string modelTimestamp)
    {
        if (db == null || tx == null || string.IsNullOrWhiteSpace(path)) return;
        using (var update = db.CreateCommand())
        {
            update.Transaction = tx;
            update.CommandText =
                "UPDATE file_metadata SET turn_context_model=@model,turn_context_model_source=@source,turn_context_model_timestamp=@timestamp WHERE path=@path";
            update.Parameters.AddWithValue("@model", model ?? "");
            update.Parameters.AddWithValue("@source", modelSource ?? "");
            update.Parameters.AddWithValue("@timestamp", modelTimestamp ?? "");
            update.Parameters.AddWithValue("@path", path);
            if (update.ExecuteNonQuery() > 0) return;
        }

        // ImportFile is a public low-level API and may run before the normal
        // file catalog update.  Keep a compact trailing model snapshot so a
        // later append can restore context even when this segment had no
        // token_count row.
        using (var insert = db.CreateCommand())
        {
            insert.Transaction = tx;
            insert.CommandText =
                "INSERT OR IGNORE INTO file_metadata (path,length,last_write_ticks,parsed_offset,session_id,content_retained,root_session_id,turn_context_model,turn_context_model_source,turn_context_model_timestamp) " +
                "VALUES (@path,@length,0,@offset,@session,1,@root,@model,@source,@timestamp)";
            insert.Parameters.AddWithValue("@path", path);
            insert.Parameters.AddWithValue("@length", Math.Max(0L, parsedOffset));
            insert.Parameters.AddWithValue("@offset", Math.Max(0L, parsedOffset));
            insert.Parameters.AddWithValue("@session", sessionId ?? "");
            insert.Parameters.AddWithValue("@root", rootSessionId ?? "");
            insert.Parameters.AddWithValue("@model", model ?? "");
            insert.Parameters.AddWithValue("@source", modelSource ?? "");
            insert.Parameters.AddWithValue("@timestamp", modelTimestamp ?? "");
            insert.ExecuteNonQuery();
        }
    }

    private static void UpsertFileMetadata(
        SQLiteConnection db,
        string path,
        long length,
        long lastWriteTicks,
        long parsedOffset,
        string sessionId,
        string cwd,
        string parentThreadId,
        string forkedFromId,
        string rootSessionId,
        bool writeRelationshipMetadata)
    {
        int affected;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = writeRelationshipMetadata
                ? "UPDATE file_metadata SET length=@p2, last_write_ticks=@p3, parsed_offset=@p4, session_id=@p5, cwd=@p6, parent_thread_id=@p7, forked_from_id=@p8, root_session_id=@p9, content_retained=1 WHERE path=@p1"
                : "UPDATE file_metadata SET length=@p2, last_write_ticks=@p3, parsed_offset=@p4, content_retained=1 WHERE path=@p1";
            cmd.Parameters.AddWithValue("@p1", path); cmd.Parameters.AddWithValue("@p2", length);
            cmd.Parameters.AddWithValue("@p3", lastWriteTicks); cmd.Parameters.AddWithValue("@p4", parsedOffset);
            if (writeRelationshipMetadata)
            {
                cmd.Parameters.AddWithValue("@p5", sessionId ?? "");
                cmd.Parameters.AddWithValue("@p6", cwd ?? "");
                cmd.Parameters.AddWithValue("@p7", parentThreadId ?? "");
                cmd.Parameters.AddWithValue("@p8", forkedFromId ?? "");
                cmd.Parameters.AddWithValue("@p9", rootSessionId ?? "");
            }
            affected = cmd.ExecuteNonQuery();
        }

        if (affected > 0) return;

        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = writeRelationshipMetadata
                ? "INSERT OR IGNORE INTO file_metadata (path, length, last_write_ticks, parsed_offset, session_id, cwd, parent_thread_id, forked_from_id, content_retained, root_session_id) VALUES (@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,1,@p9)"
                : "INSERT OR IGNORE INTO file_metadata (path, length, last_write_ticks, parsed_offset, content_retained) VALUES (@p1,@p2,@p3,@p4,1)";
            cmd.Parameters.AddWithValue("@p1", path); cmd.Parameters.AddWithValue("@p2", length);
            cmd.Parameters.AddWithValue("@p3", lastWriteTicks); cmd.Parameters.AddWithValue("@p4", parsedOffset);
            if (writeRelationshipMetadata)
            {
                cmd.Parameters.AddWithValue("@p5", sessionId ?? "");
                cmd.Parameters.AddWithValue("@p6", cwd ?? "");
                cmd.Parameters.AddWithValue("@p7", parentThreadId ?? "");
                cmd.Parameters.AddWithValue("@p8", forkedFromId ?? "");
                cmd.Parameters.AddWithValue("@p9", rootSessionId ?? "");
            }
            cmd.ExecuteNonQuery();
        }
    }

    public static void RemoveFileMetadata(SQLiteConnection db, string path)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM file_metadata WHERE path = @p";
            cmd.Parameters.AddWithValue("@p", path);
            cmd.ExecuteNonQuery();
        }
    }

    /// <summary>删除指定 session_id 的全部 token 记录，空 ID 不执行删除。</summary>
    public static int DeleteTokenRecordsBySessionId(SQLiteConnection db, string sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId)) return 0;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM token_records WHERE session_id = @p";
            cmd.Parameters.AddWithValue("@p", sessionId);
            return cmd.ExecuteNonQuery();
        }
    }

    /// <summary>删除某个源日志的工具/图片元数据；不接触原始 JSONL。</summary>
    public static int DeleteToolRecordsBySourcePath(SQLiteConnection db, string sourcePath)
    {
        if (string.IsNullOrWhiteSpace(sourcePath)) return 0;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "DELETE FROM tool_records WHERE source_path = @path";
            cmd.Parameters.AddWithValue("@path", sourcePath);
            return cmd.ExecuteNonQuery();
        }
    }

    /// <summary>读取索引级设置；不存在或值为 NULL 时返回 null。</summary>
    public static string GetSetting(SQLiteConnection db, string key)
    {
        if (string.IsNullOrWhiteSpace(key)) return null;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT value FROM index_settings WHERE key = @key LIMIT 1";
            cmd.Parameters.AddWithValue("@key", key);
            object value = cmd.ExecuteScalar();
            if (value == null || value == DBNull.Value) return null;
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }
    }

    /// <summary>写入索引级设置，使用参数化 SQL 并保留已有键的原子更新语义。</summary>
    public static void SetSetting(SQLiteConnection db, string key, string value)
    {
        if (string.IsNullOrWhiteSpace(key)) return;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "INSERT OR REPLACE INTO index_settings (key, value) VALUES (@key, @value)";
            cmd.Parameters.AddWithValue("@key", key);
            cmd.Parameters.AddWithValue("@value", value ?? "");
            cmd.ExecuteNonQuery();
        }
    }

    /// <summary>读取单调索引 revision；旧库或非法值按 0 处理。</summary>
    public static long GetIndexRevision(SQLiteConnection db)
    {
        string raw = GetSetting(db, "IndexRevision");
        long revision;
        if (!long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out revision))
            return 0L;
        return Math.Max(0L, revision);
    }

    /// <summary>
    /// 在一个短事务中将 IndexRevision 单调递增一次并返回新值。
    /// ImportFile 不调用此方法，因此一个批次不会因每行插入而产生大量
    /// revision；调用方应在导入事务全部成功后显式调用本 API。
    /// </summary>
    public static long IncrementIndexRevision(SQLiteConnection db)
    {
        using (var tx = db.BeginTransaction())
        {
            long current = 0L;
            using (var read = db.CreateCommand())
            {
                read.Transaction = tx;
                read.CommandText = "SELECT value FROM index_settings WHERE key = @key LIMIT 1";
                read.Parameters.AddWithValue("@key", "IndexRevision");
                object raw = read.ExecuteScalar();
                if (raw != null && raw != DBNull.Value)
                {
                    long parsed;
                    if (long.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture),
                        NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
                        current = Math.Max(0L, parsed);
                }
            }

            long next = current == long.MaxValue ? long.MaxValue : current + 1L;
            using (var write = db.CreateCommand())
            {
                write.Transaction = tx;
                write.CommandText = "INSERT OR REPLACE INTO index_settings (key, value) VALUES (@key, @value)";
                write.Parameters.AddWithValue("@key", "IndexRevision");
                write.Parameters.AddWithValue("@value", next.ToString(CultureInfo.InvariantCulture));
                write.ExecuteNonQuery();
            }
            tx.Commit();
            return next;
        }
    }

    /// <summary>
    /// 清理截止时间之前的 SQLite 内容记录，不删除源 JSONL 文件或游标。
    /// 旧 file_metadata 行会保留并标记 content_retained=0；返回本次新标记
    /// 的文件元数据行数。cutoffLastWriteTicks 为 0 或负数时不执行清理。
    /// </summary>
    public static int PurgeIndexBefore(SQLiteConnection db, long cutoffLastWriteTicks)
    {
        if (cutoffLastWriteTicks <= 0L) return 0;

        using (var tx = db.BeginTransaction())
        {
            // Delete token rows first while the qualifying file_metadata rows
            // are still visible to the subquery. Prefer source_path for new
            // rows, and retain the session fallback for records imported by an
            // older schema that has no source path. If the same session still
            // has a recent file, keep its token rows because they may describe
            // the active continuation of that session.
            using (var tokenCmd = db.CreateCommand())
            {
                tokenCmd.Transaction = tx;
                tokenCmd.CommandText = "DELETE FROM token_records WHERE (source_path IN (SELECT path FROM file_metadata WHERE last_write_ticks < @cutoff) OR (session_id IN (SELECT session_id FROM file_metadata WHERE last_write_ticks < @cutoff AND session_id IS NOT NULL AND session_id <> '') AND (source_path IS NULL OR source_path = ''))) AND session_id NOT IN (SELECT session_id FROM file_metadata WHERE last_write_ticks >= @cutoff AND session_id IS NOT NULL AND session_id <> '')";
                tokenCmd.Parameters.AddWithValue("@cutoff", cutoffLastWriteTicks);
                tokenCmd.ExecuteNonQuery();
            }

            int markedFiles;
            using (var metadataCmd = db.CreateCommand())
            {
                metadataCmd.Transaction = tx;
                metadataCmd.CommandText = "UPDATE file_metadata SET content_retained=0 WHERE last_write_ticks < @cutoff AND content_retained <> 0";
                metadataCmd.Parameters.AddWithValue("@cutoff", cutoffLastWriteTicks);
                markedFiles = metadataCmd.ExecuteNonQuery();
            }

            tx.Commit();
            return markedFiles;
        }
    }

    private sealed class OffsetRange
    {
        public string Path;
        public long Start;
        public long End;
    }

    private static List<OffsetRange> ReadOffsetRanges(DataTable table)
    {
        var ranges = new List<OffsetRange>();
        if (table == null) return ranges;

        string pathColumn = FindColumn(table, "path", "source_path", "file_path", "filepath");
        string startColumn = FindColumn(table, "start_offset", "start", "StartOffset");
        string endColumn = FindColumn(table, "end_offset", "end", "EndOffset");
        if (pathColumn == null || startColumn == null || endColumn == null) return ranges;

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (DataRow row in table.Rows)
        {
            string path = row[pathColumn] == DBNull.Value ? "" : Convert.ToString(row[pathColumn], CultureInfo.InvariantCulture);
            long start; long end;
            if (string.IsNullOrWhiteSpace(path) || !TryConvertInt64(row[startColumn], out start) ||
                !TryConvertInt64(row[endColumn], out end)) continue;
            start = Math.Max(0L, start);
            if (end < 0L) end = long.MaxValue;
            if (end <= start) continue;
            string key = path + "\u001F" + start.ToString(CultureInfo.InvariantCulture) + "\u001F" + end.ToString(CultureInfo.InvariantCulture);
            if (!seen.Add(key)) continue;
            ranges.Add(new OffsetRange { Path = path, Start = start, End = end });
        }
        return ranges;
    }

    private static List<OffsetRange> ReadOffsetRanges(IDictionary startOffsets, IDictionary endOffsets)
    {
        var ranges = new List<OffsetRange>();
        if (startOffsets == null) return ranges;

        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry entry in startOffsets)
        {
            string path = entry.Key == null ? "" : Convert.ToString(entry.Key, CultureInfo.InvariantCulture);
            long start;
            if (string.IsNullOrWhiteSpace(path) || !TryConvertInt64(entry.Value, out start)) continue;

            object rawEnd = null;
            if (endOffsets != null)
            {
                try
                {
                    if (endOffsets.Contains(entry.Key)) rawEnd = endOffsets[entry.Key];
                }
                catch (ArgumentException) { rawEnd = null; }
            }
            long end;
            if (rawEnd == null || !TryConvertInt64(rawEnd, out end)) end = long.MaxValue;
            start = Math.Max(0L, start);
            if (end < 0L) end = long.MaxValue;
            if (end <= start) continue;
            string key = path + "\u001F" + start.ToString(CultureInfo.InvariantCulture) + "\u001F" + end.ToString(CultureInfo.InvariantCulture);
            if (!seen.Add(key)) continue;
            ranges.Add(new OffsetRange { Path = path, Start = start, End = end });
        }
        return ranges;
    }

    private static DataTable QueryRowsByOffsetRanges(SQLiteConnection db, List<OffsetRange> ranges, bool onlyRateLimits)
    {
        DataTable result = CreateEmptyTokenRecordsTable(db);
        if (ranges == null || ranges.Count == 0) return result;

        // Three parameters per file keeps the generated statement well below
        // SQLite's default parameter limit while still reducing round trips.
        const int chunkSize = 100;
        for (int offset = 0; offset < ranges.Count; offset += chunkSize)
        {
            int count = Math.Min(chunkSize, ranges.Count - offset);
            using (var cmd = db.CreateCommand())
            {
                var predicates = new StringBuilder();
                for (int i = 0; i < count; i++)
                {
                    if (i > 0) predicates.Append(" OR ");
                    predicates.Append("(source_path=@path");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end>@start");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end<=@end");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(")");

                    OffsetRange range = ranges[offset + i];
                    cmd.Parameters.AddWithValue("@path" + i.ToString(CultureInfo.InvariantCulture), range.Path);
                    cmd.Parameters.AddWithValue("@start" + i.ToString(CultureInfo.InvariantCulture), range.Start);
                    cmd.Parameters.AddWithValue("@end" + i.ToString(CultureInfo.InvariantCulture), range.End);
                }

                cmd.CommandText = "SELECT * FROM token_records WHERE (" + predicates + ")" +
                    (onlyRateLimits ? " AND (five_hour_used IS NOT NULL OR weekly_used IS NOT NULL)" : "") +
                    " ORDER BY timestamp ASC, id ASC";
                var chunk = new DataTable();
                using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(chunk); }
                result.Merge(chunk, true, MissingSchemaAction.Add);
            }
        }
        return SortTokenRecordTable(result, false);
    }

    /// <summary>
    /// 额度快照候选按文件、窗口、归一化重置分钟、计划和额度池分别保留。
    /// 旧实现每个文件只保留两个窗口的最大 offset，因此同一个 reset 周期
    /// 内先出现的 plan 可能被另一个 plan 的较新行静默覆盖。这里保留每个
    /// scope 的最新行，跨文件再按相同 scope 去重；Core 层据此判断同周期
    /// 的计划冲突，而不是把最新行误当成唯一真相。
    /// </summary>
    private static DataTable QueryLatestRateLimitRowsByOffsetRanges(SQLiteConnection db, List<OffsetRange> ranges)
    {
        DataTable candidates = CreateEmptyTokenRecordsTable(db);
        if (ranges == null || ranges.Count == 0) return candidates;

        var seenIds = new HashSet<long>();
        const int chunkSize = 125;
        for (int offset = 0; offset < ranges.Count; offset += chunkSize)
        {
            int count = Math.Min(chunkSize, ranges.Count - offset);
            using (var cmd = db.CreateCommand())
            {
                var predicates = new StringBuilder();
                for (int i = 0; i < count; i++)
                {
                    if (i > 0) predicates.Append(" OR ");
                    predicates.Append("(source_path=@path");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end>@start");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(" AND source_offset_end<=@end");
                    predicates.Append(i.ToString(CultureInfo.InvariantCulture));
                    predicates.Append(")");

                    OffsetRange range = ranges[offset + i];
                    cmd.Parameters.AddWithValue("@path" + i.ToString(CultureInfo.InvariantCulture), range.Path);
                    cmd.Parameters.AddWithValue("@start" + i.ToString(CultureInfo.InvariantCulture), range.Start);
                    cmd.Parameters.AddWithValue("@end" + i.ToString(CultureInfo.InvariantCulture), range.End);
                }

                // Expand the two windows into scope rows before grouping. Reset
                // identity is normalized to UTC minutes, matching the Core
                // Get-TokenRaderResetIdentity contract. COALESCE keeps legacy
                // empty plan/limit and unknown reset rows queryable without
                // treating a missing reset as a real conflict later.
                cmd.CommandText =
                    "SELECT tr.* FROM token_records AS tr INNER JOIN (" +
                    "SELECT source_path, window_kind, plan_type, rate_limit_id, window_minutes, reset_minute, " +
                    "MAX(source_offset_end) AS latest_offset FROM (" +
                    "SELECT source_path, source_offset_end, 'FiveHour' AS window_kind, " +
                    "COALESCE(plan_type,'') AS plan_type, COALESCE(rate_limit_id,'') AS rate_limit_id, " +
                    "COALESCE(five_hour_window,-1) AS window_minutes, " +
                    "COALESCE(CAST(five_hour_resets / 60 AS INTEGER),-1) AS reset_minute " +
                    "FROM token_records WHERE (" + predicates + ") AND five_hour_used IS NOT NULL " +
                    "UNION ALL " +
                    "SELECT source_path, source_offset_end, 'Weekly' AS window_kind, " +
                    "COALESCE(plan_type,'') AS plan_type, COALESCE(rate_limit_id,'') AS rate_limit_id, " +
                    "COALESCE(weekly_window,-1) AS window_minutes, " +
                    "COALESCE(CAST(weekly_resets / 60 AS INTEGER),-1) AS reset_minute " +
                    "FROM token_records WHERE (" + predicates + ") AND weekly_used IS NOT NULL" +
                    ") AS scoped GROUP BY source_path, window_kind, plan_type, rate_limit_id, window_minutes, reset_minute" +
                    ") AS latest ON tr.source_path=latest.source_path AND tr.source_offset_end=latest.latest_offset AND (" +
                    "(latest.window_kind='FiveHour' AND tr.five_hour_used IS NOT NULL AND " +
                    "COALESCE(tr.plan_type,'')=latest.plan_type AND COALESCE(tr.rate_limit_id,'')=latest.rate_limit_id AND " +
                    "COALESCE(tr.five_hour_window,-1)=latest.window_minutes AND " +
                    "COALESCE(CAST(tr.five_hour_resets / 60 AS INTEGER),-1)=latest.reset_minute) OR " +
                    "(latest.window_kind='Weekly' AND tr.weekly_used IS NOT NULL AND " +
                    "COALESCE(tr.plan_type,'')=latest.plan_type AND COALESCE(tr.rate_limit_id,'')=latest.rate_limit_id AND " +
                    "COALESCE(tr.weekly_window,-1)=latest.window_minutes AND " +
                    "COALESCE(CAST(tr.weekly_resets / 60 AS INTEGER),-1)=latest.reset_minute))";

                var chunk = new DataTable();
                using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(chunk); }
                foreach (DataRow row in chunk.Rows)
                {
                    long id;
                    if (!TryConvertInt64(row["id"], out id) || !seenIds.Add(id)) continue;
                    candidates.ImportRow(row);
                }
            }
        }
        return SelectLatestRateLimitRows(candidates);
    }

    private static DataTable CreateEmptyTokenRecordsTable(SQLiteConnection db)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT * FROM token_records WHERE 1=0";
            var dt = new DataTable();
            using (var da = new SQLiteDataAdapter(cmd)) { da.Fill(dt); }
            return dt;
        }
    }

    private static DataTable SelectLatestRateLimitRows(DataTable candidates)
    {
        DataTable result = candidates == null ? new DataTable() : candidates.Clone();
        if (candidates == null || candidates.Rows.Count == 0) return result;

        // Keep one latest row for each normalized window scope. A row carrying
        // both windows can satisfy two keys, but it must be imported only once.
        var latestByScope = new Dictionary<string, DataRow>(StringComparer.OrdinalIgnoreCase);
        foreach (DataRow row in candidates.Rows)
        {
            if (HasData(row, "five_hour_used"))
            {
                string key = GetRateLimitScopeKey(row, false);
                DataRow current;
                if (!latestByScope.TryGetValue(key, out current) || IsLaterTokenRow(row, current))
                    latestByScope[key] = row;
            }
            if (HasData(row, "weekly_used"))
            {
                string key = GetRateLimitScopeKey(row, true);
                DataRow current;
                if (!latestByScope.TryGetValue(key, out current) || IsLaterTokenRow(row, current))
                    latestByScope[key] = row;
            }
        }

        var importedIds = new HashSet<long>();
        foreach (DataRow row in latestByScope.Values)
        {
            long id;
            if (!TryConvertInt64(row["id"], out id)) id = 0L;
            if (importedIds.Add(id)) result.ImportRow(row);
        }
        return SortTokenRecordTable(result, true);
    }

    private static string GetRateLimitScopeKey(DataRow row, bool weekly)
    {
        string plan = HasData(row, "plan_type")
            ? Convert.ToString(row["plan_type"], CultureInfo.InvariantCulture) ?? "" : "";
        string limit = HasData(row, "rate_limit_id")
            ? Convert.ToString(row["rate_limit_id"], CultureInfo.InvariantCulture) ?? "" : "";
        string windowColumn = weekly ? "weekly_window" : "five_hour_window";
        string resetColumn = weekly ? "weekly_resets" : "five_hour_resets";
        long window;
        long reset;
        if (!TryConvertInt64(row[windowColumn], out window)) window = -1L;
        if (!TryConvertInt64(row[resetColumn], out reset)) reset = -1L;
        long resetMinute = reset >= 0L ? reset / 60L : -1L;
        return (weekly ? "Weekly" : "FiveHour") + "\u001F" +
            window.ToString(CultureInfo.InvariantCulture) + "\u001F" +
            resetMinute.ToString(CultureInfo.InvariantCulture) + "\u001F" +
            plan + "\u001F" + limit;
    }

    private static DataTable SortTokenRecordTable(DataTable table, bool descending)
    {
        if (table == null || table.Rows.Count < 2) return table;
        DataTable sorted = table.Clone();
        DataView view = table.DefaultView;
        view.Sort = descending ? "timestamp DESC, id DESC" : "timestamp ASC, id ASC";
        foreach (DataRowView row in view) sorted.ImportRow(row.Row);
        return sorted;
    }

    private static bool HasData(DataRow row, string columnName)
    {
        return row != null && row.Table != null && row.Table.Columns.Contains(columnName) &&
            row[columnName] != null && row[columnName] != DBNull.Value;
    }

    private static bool IsLaterTokenRow(DataRow candidate, DataRow current)
    {
        if (candidate == null) return false;
        if (current == null) return true;
        string candidateTs = HasData(candidate, "timestamp")
            ? Convert.ToString(candidate["timestamp"], CultureInfo.InvariantCulture) : "";
        string currentTs = HasData(current, "timestamp")
            ? Convert.ToString(current["timestamp"], CultureInfo.InvariantCulture) : "";
        DateTimeOffset candidateAt; DateTimeOffset currentAt;
        int comparison;
        if (TryParseTimestamp(candidateTs, out candidateAt) && TryParseTimestamp(currentTs, out currentAt))
            comparison = DateTimeOffset.Compare(candidateAt.ToUniversalTime(), currentAt.ToUniversalTime());
        else
            comparison = string.CompareOrdinal(candidateTs, currentTs);
        if (comparison != 0) return comparison > 0;
        long candidateId; long currentId;
        if (!TryConvertInt64(candidate["id"], out candidateId)) candidateId = 0L;
        if (!TryConvertInt64(current["id"], out currentId)) currentId = 0L;
        return candidateId > currentId;
    }

    private static string FindColumn(DataTable table, params string[] names)
    {
        if (table == null || names == null) return null;
        foreach (DataColumn column in table.Columns)
        {
            foreach (string name in names)
            {
                if (string.Equals(column.ColumnName, name, StringComparison.OrdinalIgnoreCase))
                    return column.ColumnName;
            }
        }
        return null;
    }

    private static bool TryConvertInt64(object raw, out long value)
    {
        value = 0L;
        if (raw == null || raw == DBNull.Value || raw is bool) return false;
        try
        {
            if (raw is byte || raw is sbyte || raw is short || raw is ushort ||
                raw is int || raw is uint || raw is long || raw is ulong)
            {
                value = Convert.ToInt64(raw, CultureInfo.InvariantCulture);
                return true;
            }
            double number;
            if (TryGetDoubleValue(raw, out number) && !double.IsNaN(number) &&
                !double.IsInfinity(number) && number >= (double)long.MinValue &&
                number <= (double)long.MaxValue)
            {
                value = Convert.ToInt64(Math.Truncate(number), CultureInfo.InvariantCulture);
                return true;
            }
        }
        catch (Exception)
        {
            return false;
        }
        return false;
    }

    private static bool TryConvertInt32(object raw, out int value)
    {
        value = 0;
        long converted;
        if (!TryConvertInt64(raw, out converted) || converted < int.MinValue ||
            converted > int.MaxValue) return false;
        value = (int)converted;
        return true;
    }

    private static bool TryConvertDouble(object raw, out double value)
    {
        value = 0.0;
        if (raw == null || raw == DBNull.Value || raw is bool) return false;
        try
        {
            value = Convert.ToDouble(raw, CultureInfo.InvariantCulture);
            return !double.IsNaN(value) && !double.IsInfinity(value);
        }
        catch (FormatException) { return false; }
        catch (InvalidCastException) { return false; }
        catch (OverflowException) { return false; }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    /// <summary>
    /// 读取 [startOffset,endOffset) 内的 UTF-8 JSONL。StreamReader 会预读
    /// 数 KB 内容，无法用 BaseStream.Position 得到当前行结束位置；本类
    /// 直接按字节寻找换行，因此 source_offset_end 始终是准确的 UTF-8
    /// 字节边界（包含 LF 或 CRLF 的换行字节）。
    /// </summary>
    private sealed class Utf8JsonlLineReader : IDisposable
    {
        private readonly Stream _stream;
        private readonly long _endOffset;
        private readonly byte[] _buffer = new byte[64 * 1024];
        private int _bufferIndex;
        private int _bufferCount;
        private long _position;

        public Utf8JsonlLineReader(Stream stream, long startOffset, long endOffset)
        {
            _stream = stream;
            _position = Math.Max(0L, startOffset);
            _endOffset = Math.Max(_position, endOffset);
            _stream.Seek(_position, SeekOrigin.Begin);
            _bufferIndex = 0;
            _bufferCount = 0;
        }

        public bool ReadLine(out string line, out long lineEndOffset, out bool terminated)
        {
            line = null;
            lineEndOffset = _position;
            terminated = false;

            using (var bytes = new MemoryStream())
            {
                while (_position < _endOffset)
                {
                    int value = ReadByte();
                    if (value < 0) break;

                    if (value == 0x0A) // LF
                    {
                        terminated = true;
                        break;
                    }
                    if (value == 0x0D) // CR, with optional LF in CRLF
                    {
                        if (PeekByte() == 0x0A) ReadByte();
                        terminated = true;
                        break;
                    }
                    bytes.WriteByte((byte)value);
                }

                lineEndOffset = _position;
                if (bytes.Length == 0 && !terminated && _position >= _endOffset)
                    return false;
                line = Encoding.UTF8.GetString(bytes.ToArray());
                return true;
            }
        }

        private int PeekByte()
        {
            if (_position >= _endOffset) return -1;
            if (!FillBuffer()) return -1;
            return _buffer[_bufferIndex];
        }

        private int ReadByte()
        {
            if (_position >= _endOffset) return -1;
            if (!FillBuffer()) return -1;
            int value = _buffer[_bufferIndex++];
            _position++;
            return value;
        }

        private bool FillBuffer()
        {
            if (_bufferIndex < _bufferCount) return true;
            long remaining = _endOffset - _position;
            if (remaining <= 0L) return false;
            int requested = (int)Math.Min((long)_buffer.Length, remaining);
            _bufferIndex = 0;
            _bufferCount = _stream.Read(_buffer, 0, requested);
            return _bufferCount > 0;
        }

        public void Dispose()
        {
            // The importer owns and disposes the underlying FileStream.
        }
    }

    private static void EnsureFileMetadataColumn(SQLiteConnection db, string columnName, string columnDefinition)
    {
        bool exists = false;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(file_metadata)";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string existingName = reader.IsDBNull(1) ? "" : reader.GetString(1);
                    if (string.Equals(existingName, columnName, StringComparison.OrdinalIgnoreCase))
                    {
                        exists = true;
                        break;
                    }
                }
            }
        }
        if (exists) return;

        using (var cmd = db.CreateCommand())
        {
            // Column names and definitions are private constants at every
            // call site; no user-provided SQL is interpolated here.
            cmd.CommandText = "ALTER TABLE file_metadata ADD COLUMN " + columnName + " " + columnDefinition;
            cmd.ExecuteNonQuery();
        }
    }

    private static void EnsureTokenRecordColumn(SQLiteConnection db, string columnName, string columnDefinition)
    {
        bool exists = false;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(token_records)";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string existingName = reader.IsDBNull(1) ? "" : reader.GetString(1);
                    if (string.Equals(existingName, columnName, StringComparison.OrdinalIgnoreCase))
                    {
                        exists = true;
                        break;
                    }
                }
            }
        }
        if (exists) return;

        using (var cmd = db.CreateCommand())
        {
            // Column names and definitions are private constants at every
            // call site; no user-provided SQL is interpolated here.
            cmd.CommandText = "ALTER TABLE token_records ADD COLUMN " + columnName + " " + columnDefinition;
            cmd.ExecuteNonQuery();
        }
    }

    private static void EnsureToolRecordColumn(SQLiteConnection db, string columnName, string columnDefinition)
    {
        bool exists = false;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(tool_records)";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string existingName = reader.IsDBNull(1) ? "" : reader.GetString(1);
                    if (string.Equals(existingName, columnName, StringComparison.OrdinalIgnoreCase))
                    {
                        exists = true;
                        break;
                    }
                }
            }
        }
        if (exists) return;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "ALTER TABLE tool_records ADD COLUMN " + columnName + " " + columnDefinition;
            cmd.ExecuteNonQuery();
        }
    }

    private static void EnsureUsageHistoryModelColumn(SQLiteConnection db, string columnName, string columnDefinition)
    {
        bool exists = false;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(usage_history_models)";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string existingName = reader.IsDBNull(1) ? "" : reader.GetString(1);
                    if (string.Equals(existingName, columnName, StringComparison.OrdinalIgnoreCase))
                    {
                        exists = true;
                        break;
                    }
                }
            }
        }
        if (exists) return;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "ALTER TABLE usage_history_models ADD COLUMN " + columnName + " " + columnDefinition;
            cmd.ExecuteNonQuery();
        }
    }

    /// <summary>
    /// Adds service_tier to the history-model key for indexes created before
    /// tier-aware history existed.  SQLite cannot add a primary-key column in
    /// place, so copy the compact table inside one transaction.  The explicit
    /// column list deliberately preserves every existing history diagnostic.
    /// </summary>
    private static void EnsureUsageHistoryModelServiceTierKey(SQLiteConnection db)
    {
        bool tierIsInPrimaryKey = false;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(usage_history_models)";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string name = reader.IsDBNull(1) ? "" : reader.GetString(1);
                    if (string.Equals(name, "service_tier", StringComparison.OrdinalIgnoreCase))
                    {
                        tierIsInPrimaryKey = !reader.IsDBNull(5) && ReadReaderInt64(reader, 5) > 0L;
                        break;
                    }
                }
            }
        }
        if (tierIsInPrimaryKey) return;

        using (var tx = db.BeginTransaction())
        {
            using (var cmd = db.CreateCommand())
            {
                cmd.Transaction = tx;
                // The old index follows the renamed table in SQLite.  Drop it
                // first so the replacement table can receive the same stable
                // index name after the copy completes.
                cmd.CommandText = "DROP INDEX IF EXISTS idx_usage_history_models_end";
                cmd.ExecuteNonQuery();
                cmd.CommandText = "ALTER TABLE usage_history_models RENAME TO usage_history_models_legacy";
                cmd.ExecuteNonQuery();
                cmd.CommandText = "CREATE TABLE usage_history_models (window_start_ticks INTEGER NOT NULL, window_end_ticks INTEGER NOT NULL, model TEXT NOT NULL DEFAULT '', service_tier TEXT NOT NULL DEFAULT '', total_input INTEGER NOT NULL DEFAULT 0, total_cached INTEGER NOT NULL DEFAULT 0, total_output INTEGER NOT NULL DEFAULT 0, total_reasoning INTEGER NOT NULL DEFAULT 0, input_cost REAL NOT NULL DEFAULT 0, cached_cost REAL NOT NULL DEFAULT 0, output_cost REAL NOT NULL DEFAULT 0, pricing_complete INTEGER NOT NULL DEFAULT 1, events INTEGER NOT NULL DEFAULT 0, cache_creation_tokens INTEGER NOT NULL DEFAULT 0, cache_write_observable INTEGER NOT NULL DEFAULT 0, standard_context_events INTEGER NOT NULL DEFAULT 0, long_context_events INTEGER NOT NULL DEFAULT 0, standard_context_input INTEGER NOT NULL DEFAULT 0, long_context_input INTEGER NOT NULL DEFAULT 0, long_context_output INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(window_start_ticks,window_end_ticks,model,service_tier))";
                cmd.ExecuteNonQuery();
                cmd.CommandText =
                    "INSERT INTO usage_history_models (window_start_ticks,window_end_ticks,model,service_tier,total_input,total_cached,total_output,total_reasoning,input_cost,cached_cost,output_cost,pricing_complete,events,cache_creation_tokens,cache_write_observable,standard_context_events,long_context_events,standard_context_input,long_context_input,long_context_output) " +
                    "SELECT window_start_ticks,window_end_ticks,model,service_tier,total_input,total_cached,total_output,total_reasoning,input_cost,cached_cost,output_cost,pricing_complete,events,cache_creation_tokens,cache_write_observable,standard_context_events,long_context_events,standard_context_input,long_context_input,long_context_output FROM usage_history_models_legacy";
                cmd.ExecuteNonQuery();
                cmd.CommandText = "DROP TABLE usage_history_models_legacy";
                cmd.ExecuteNonQuery();
                cmd.CommandText = "CREATE INDEX IF NOT EXISTS idx_usage_history_models_end ON usage_history_models(window_end_ticks)";
                cmd.ExecuteNonQuery();
            }
            tx.Commit();
        }
    }

    private static void EnsureUsageHistoryColumn(SQLiteConnection db, string columnName, string columnDefinition)
    {
        bool exists = false;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(usage_history)";
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string existingName = reader.IsDBNull(1) ? "" : reader.GetString(1);
                    if (string.Equals(existingName, columnName, StringComparison.OrdinalIgnoreCase))
                    {
                        exists = true;
                        break;
                    }
                }
            }
        }
        if (exists) return;
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "ALTER TABLE usage_history ADD COLUMN " + columnName + " " + columnDefinition;
            cmd.ExecuteNonQuery();
        }
    }

    private static string GetLatestSessionModel(SQLiteConnection db, string sessionId)
    {
        return GetLatestSessionModel(db, sessionId, null);
    }

    private static string GetLatestSessionModel(
        SQLiteConnection db,
        string sessionId,
        DateTimeOffset? atOrBefore)
    {
        if (string.IsNullOrWhiteSpace(sessionId)) return "";

        string bestModel = "";
        DateTimeOffset bestObservedAt = default(DateTimeOffset);
        bool bestHasTimestamp = false;
        long bestSequence = long.MinValue;
        bool bestIsContext = false;

        // Do not use SQLite's textual timestamp ordering here.  Logs can
        // legally mix Z and explicit offsets, and fractional-second widths
        // are not guaranteed to be identical.  Parse every candidate so the
        // as-of boundary is an actual instant comparison.
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "SELECT id,model,timestamp FROM token_records WHERE session_id=@p AND model IS NOT NULL AND model<>''";
            cmd.Parameters.AddWithValue("@p", sessionId);
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string model = ReadReaderString(reader, 1);
                    if (string.IsNullOrWhiteSpace(model)) continue;
                    long sequence = ReadReaderInt64(reader, 0);
                    DateTimeOffset observedAt;
                    bool hasTimestamp = TryParseTimestamp(ReadReaderString(reader, 2), out observedAt);
                    if (atOrBefore.HasValue)
                    {
                        if (!hasTimestamp || observedAt > atOrBefore.Value) continue;
                        if (!bestHasTimestamp || observedAt > bestObservedAt ||
                            (observedAt == bestObservedAt && sequence >= bestSequence))
                        {
                            bestModel = model;
                            bestObservedAt = observedAt;
                            bestHasTimestamp = true;
                            bestSequence = sequence;
                            bestIsContext = false;
                        }
                    }
                    else if (hasTimestamp &&
                        (!bestHasTimestamp || observedAt > bestObservedAt ||
                         (observedAt == bestObservedAt && !bestIsContext && sequence >= bestSequence)))
                    {
                        // Prefer the latest actual instant.  The sequence id
                        // only breaks ties or covers legacy rows lacking a
                        // parseable timestamp.
                        bestModel = model;
                        bestObservedAt = observedAt;
                        bestHasTimestamp = true;
                        bestSequence = sequence;
                        bestIsContext = false;
                    }
                    else if (!bestHasTimestamp && !bestIsContext && sequence >= bestSequence)
                    {
                        bestModel = model;
                        bestSequence = sequence;
                        bestIsContext = false;
                    }
                }
            }
        }

        // A trailing turn_context may have no token row yet.  Its persisted
        // snapshot is a first-class model observation, but only when its own
        // timestamp is parsed and is not in the future relative to an as-of
        // child event.  Context observations at the same instant supersede a
        // token row because they are the explicit boundary for that turn.
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText =
                "SELECT turn_context_model,turn_context_model_timestamp,path FROM file_metadata " +
                "WHERE session_id=@p AND turn_context_model IS NOT NULL AND turn_context_model<>'' " +
                "AND turn_context_model_source IS NOT NULL AND turn_context_model_source<>''";
            cmd.Parameters.AddWithValue("@p", sessionId);
            using (var reader = cmd.ExecuteReader())
            {
                while (reader.Read())
                {
                    string model = ReadReaderString(reader, 0);
                    if (string.IsNullOrWhiteSpace(model)) continue;
                    DateTimeOffset observedAt;
                    bool hasTimestamp = TryParseTimestamp(ReadReaderString(reader, 1), out observedAt);
                    if (atOrBefore.HasValue)
                    {
                        if (!hasTimestamp || observedAt > atOrBefore.Value) continue;
                        if (!bestHasTimestamp || observedAt > bestObservedAt ||
                            (observedAt == bestObservedAt && !bestIsContext))
                        {
                            bestModel = model;
                            bestObservedAt = observedAt;
                            bestHasTimestamp = true;
                            bestSequence = long.MaxValue;
                            bestIsContext = true;
                        }
                    }
                    else if (hasTimestamp &&
                        (!bestHasTimestamp || observedAt > bestObservedAt ||
                         (observedAt == bestObservedAt && !bestIsContext)))
                    {
                        bestModel = model;
                        bestObservedAt = observedAt;
                        bestHasTimestamp = true;
                        bestSequence = long.MaxValue;
                        bestIsContext = true;
                    }
                    else if (string.IsNullOrWhiteSpace(bestModel) && !bestHasTimestamp)
                    {
                        // A legacy/new metadata row without a parseable
                        // timestamp is usable only when no dated observation
                        // exists; it must never displace a dated candidate in
                        // an as-of lookup.
                        bestModel = model;
                        bestSequence = long.MaxValue;
                        bestIsContext = true;
                    }
                }
            }
        }
        return bestModel;
    }

    private static string GetLatestSessionTextColumn(SQLiteConnection db, string sessionId, string columnName)
    {
        if (string.IsNullOrWhiteSpace(sessionId) || string.IsNullOrWhiteSpace(columnName)) return "";
        using (var cmd = db.CreateCommand())
        {
            // columnName is supplied only by private constant call sites.
            cmd.CommandText = "SELECT " + columnName + " FROM token_records WHERE session_id=@session AND " +
                columnName + " IS NOT NULL AND " + columnName + "<>'' ORDER BY id DESC LIMIT 1";
            cmd.Parameters.AddWithValue("@session", sessionId);
            object value = cmd.ExecuteScalar();
            return value == null || value == DBNull.Value ? "" :
                (Convert.ToString(value, CultureInfo.InvariantCulture) ?? "");
        }
    }

    /// <summary>
    /// Reads a persisted context value including an intentionally empty value.
    /// A null return means that this session has no indexed rows at all.  The
    /// distinction lets incremental import preserve a context tier without
    /// accidentally inheriting the previous token's one-off override.
    /// </summary>
    private static string GetLatestSessionTextColumnIncludingEmpty(
        SQLiteConnection db, string sessionId, string columnName)
    {
        if (string.IsNullOrWhiteSpace(sessionId) || string.IsNullOrWhiteSpace(columnName)) return null;
        using (var cmd = db.CreateCommand())
        {
            // columnName is supplied only by private constant call sites.
            cmd.CommandText = "SELECT " + columnName + " FROM token_records WHERE session_id=@session ORDER BY id DESC LIMIT 1";
            cmd.Parameters.AddWithValue("@session", sessionId);
            object value = cmd.ExecuteScalar();
            if (value == null) return null;
            return value == DBNull.Value ? "" :
                (Convert.ToString(value, CultureInfo.InvariantCulture) ?? "");
        }
    }

    private static string GetLatestFileTextColumnIncludingEmpty(
        SQLiteConnection db, string path, string columnName)
    {
        if (string.IsNullOrWhiteSpace(path) || string.IsNullOrWhiteSpace(columnName)) return null;
        using (var cmd = db.CreateCommand())
        {
            // columnName is supplied only by private constant call sites.
            cmd.CommandText = "SELECT " + columnName + " FROM file_metadata WHERE path=@path LIMIT 1";
            cmd.Parameters.AddWithValue("@path", path);
            object value = cmd.ExecuteScalar();
            if (value == null) return null;
            return value == DBNull.Value ? "" :
                (Convert.ToString(value, CultureInfo.InvariantCulture) ?? "");
        }
    }

    private static string ResolveInheritedModel(
        SQLiteConnection db,
        string sessionId,
        string parentSessionId,
        string rootSessionId,
        DateTimeOffset? asOf,
        bool includeSameSession,
        out string modelSource)
    {
        string model = includeSameSession
            ? GetLatestSessionModel(db, sessionId, asOf) : "";
        if (!string.IsNullOrWhiteSpace(model))
        {
            modelSource = "same_session";
            return model;
        }
        if (!string.IsNullOrWhiteSpace(parentSessionId) &&
            !string.Equals(parentSessionId, sessionId, StringComparison.OrdinalIgnoreCase))
        {
            model = GetLatestSessionModel(db, parentSessionId, asOf);
            if (!string.IsNullOrWhiteSpace(model))
            {
                modelSource = "parent";
                return model;
            }
        }
        if (!string.IsNullOrWhiteSpace(rootSessionId) &&
            !string.Equals(rootSessionId, sessionId, StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(rootSessionId, parentSessionId, StringComparison.OrdinalIgnoreCase))
        {
            model = GetLatestSessionModel(db, rootSessionId, asOf);
            if (!string.IsNullOrWhiteSpace(model))
            {
                modelSource = "root";
                return model;
            }
        }
        modelSource = "unresolved";
        return "";
    }

    private static string ResolveInheritedModel(
        SQLiteConnection db,
        string sessionId,
        string parentSessionId,
        string rootSessionId,
        out string modelSource)
    {
        return ResolveInheritedModel(db, sessionId, parentSessionId, rootSessionId,
            null, true, out modelSource);
    }

    private static string ExtractSessionId(string filePath)
    {
        string name = Path.GetFileNameWithoutExtension(filePath);
        var m = _sessionIdFromPath.Match(name);
        return m.Success ? m.Groups[1].Value.ToLowerInvariant() : name.ToLowerInvariant();
    }

    private static bool TryReadFirstEventTimestamp(
        string filePath,
        long startOffset,
        long endOffset,
        out DateTimeOffset timestamp)
    {
        timestamp = default(DateTimeOffset);
        if (string.IsNullOrWhiteSpace(filePath) || !File.Exists(filePath)) return false;
        try
        {
            using (var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                long safeStart = Math.Max(0L, startOffset);
                long requestedEnd = endOffset < 0L ? 0L : endOffset;
                long effectiveEnd = Math.Min(fs.Length, requestedEnd);
                if (safeStart >= effectiveEnd) return false;
                bool skipPartialLine = false;
                if (safeStart > 0L)
                {
                    fs.Seek(safeStart - 1L, SeekOrigin.Begin);
                    int previousByte = fs.ReadByte();
                    skipPartialLine = previousByte != '\n' && previousByte != '\r';
                }
                using (var lineReader = new Utf8JsonlLineReader(fs, safeStart, effectiveEnd))
                {
                    if (skipPartialLine)
                    {
                        string discarded; long discardedEnd; bool discardedTerminated;
                        lineReader.ReadLine(out discarded, out discardedEnd, out discardedTerminated);
                    }
                    string line; long lineEnd; bool terminated;
                    while (lineReader.ReadLine(out line, out lineEnd, out terminated))
                    {
                        if (!terminated) break;
                        if (string.IsNullOrWhiteSpace(line)) continue;
                        line = line.TrimStart('\uFEFF');
                        TokenRaderJsonRecord record;
                        if (!TryDeserializeMetadataRecord(line, out record)) continue;
                        if (TryParseTimestamp(record.Timestamp, out timestamp)) return true;
                    }
                }
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        catch (ArgumentException) { }
        return false;
    }

    private static string GetCanonicalPath(string filePath)
    {
        try { return Path.GetFullPath(filePath); }
        catch (Exception) { return filePath ?? ""; }
    }

    private static TokenRaderJsonRecord DeserializeLogRecord(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return null;
        if (_jsonSerializer == null)
            _jsonSerializer = new DataContractJsonSerializer(typeof(TokenRaderJsonRecord));
        byte[] bytes = Encoding.UTF8.GetBytes(line);
        using (var stream = new MemoryStream(bytes, false))
            return _jsonSerializer.ReadObject(stream) as TokenRaderJsonRecord;
    }

    private static double ClampPercent(double value)
    {
        if (double.IsNaN(value)) return 0.0;
        if (value < 0.0) return 0.0;
        if (value > 100.0) return 100.0;
        return value;
    }

    private static bool TryParseTimestamp(object raw, out DateTimeOffset value)
    {
        value = default(DateTimeOffset);
        if (raw == null) return false;

        string text = raw as string;
        if (!string.IsNullOrWhiteSpace(text))
        {
            text = text.Trim();
            double numeric;
            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out numeric))
            {
                return TryUnixNumberToDateTimeOffset(numeric, out value);
            }

            DateTimeOffset parsed;
            if (DateTimeOffset.TryParse(
                text,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out parsed))
            {
                value = parsed.ToUniversalTime();
                return true;
            }
            return false;
        }

        double number;
        return TryGetDoubleValue(raw, out number) && TryUnixNumberToDateTimeOffset(number, out value);
    }

    /// <summary>
    /// 将 reset_at/resets_at 的 Unix 秒或毫秒值，或 ISO 字符串，归一化为 Unix 秒。
    /// </summary>
    private static bool TryNormalizeResetValue(object raw, out long unixSeconds)
    {
        unixSeconds = 0L;
        if (raw == null) return false;

        DateTimeOffset dateValue;
        string text = raw as string;
        if (!string.IsNullOrWhiteSpace(text))
        {
            text = text.Trim();
            double numeric;
            if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out numeric))
            {
                if (!DateTimeOffset.TryParse(
                    text,
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                    out dateValue))
                {
                    return false;
                }
                return TryDateTimeOffsetToUnixSeconds(dateValue, out unixSeconds);
            }
            return TryUnixNumberToUnixSeconds(numeric, out unixSeconds);
        }

        double number;
        if (TryGetDoubleValue(raw, out number)) return TryUnixNumberToUnixSeconds(number, out unixSeconds);
        if (raw is DateTimeOffset)
        {
            dateValue = (DateTimeOffset)raw;
            return TryDateTimeOffsetToUnixSeconds(dateValue, out unixSeconds);
        }
        if (raw is DateTime)
        {
            dateValue = new DateTimeOffset((DateTime)raw);
            return TryDateTimeOffsetToUnixSeconds(dateValue, out unixSeconds);
        }
        return false;
    }

    private static bool TryGetResetUnixSeconds(
        TokenRaderJsonRateWindow window,
        DateTimeOffset? observedAt,
        out long unixSeconds)
    {
        unixSeconds = 0L;
        // Prefer an absolute reset time. Some log versions use reset_at while
        // current versions generally use resets_at.
        foreach (object raw in new[] { window.ResetsAt, window.ResetAt })
        {
            if (raw != null && TryNormalizeResetValue(raw, out unixSeconds))
                return true;
        }

        // Older/newer payloads may provide only a relative number of seconds.
        // It is meaningful only when the event timestamp is parseable.
        if (observedAt.HasValue && window.ResetsInSeconds != null)
        {
            double seconds;
            if (TryGetDoubleValue(window.ResetsInSeconds, out seconds) && !double.IsNaN(seconds) && !double.IsInfinity(seconds))
            {
                try
                {
                    DateTimeOffset resetAt = observedAt.Value.AddSeconds(seconds);
                    return TryDateTimeOffsetToUnixSeconds(resetAt, out unixSeconds);
                }
                catch (ArgumentOutOfRangeException) { }
            }
        }
        return false;
    }

    private static bool TryUnixNumberToDateTimeOffset(double number, out DateTimeOffset value)
    {
        value = default(DateTimeOffset);
        long seconds;
        if (!TryUnixNumberToUnixSeconds(number, out seconds)) return false;
        try
        {
            value = UnixEpoch.AddSeconds(seconds);
            return true;
        }
        catch (ArgumentOutOfRangeException) { return false; }
    }

    private static bool TryUnixNumberToUnixSeconds(double number, out long seconds)
    {
        seconds = 0L;
        if (double.IsNaN(number) || double.IsInfinity(number)) return false;

        // Unix milliseconds are approximately 1e12 today, while Unix seconds
        // are approximately 1e9. Keep the threshold broad enough for dates
        // before/after the present without confusing seconds with milliseconds.
        if (Math.Abs(number) >= 100000000000.0) number /= 1000.0;
        if (number < (double)long.MinValue || number > (double)long.MaxValue) return false;
        double truncated = Math.Truncate(number);
        try { seconds = Convert.ToInt64(truncated, CultureInfo.InvariantCulture); }
        catch (OverflowException) { return false; }
        return true;
    }

    private static bool TryDateTimeOffsetToUnixSeconds(DateTimeOffset value, out long unixSeconds)
    {
        unixSeconds = 0L;
        try
        {
            double seconds = (value.ToUniversalTime() - UnixEpoch).TotalSeconds;
            if (double.IsNaN(seconds) || double.IsInfinity(seconds)) return false;
            unixSeconds = Convert.ToInt64(Math.Truncate(seconds), CultureInfo.InvariantCulture);
            return true;
        }
        catch (OverflowException) { return false; }
    }

    private static readonly DateTimeOffset UnixEpoch =
        new DateTimeOffset(1970, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static bool TryGetDoubleValue(object raw, out double value)
    {
        value = 0.0;
        if (raw == null || raw is bool) return false;
        if (raw is double) { value = (double)raw; return true; }
        if (raw is float) { value = (float)raw; return true; }
        if (raw is decimal) { value = (double)(decimal)raw; return true; }
        if (raw is byte || raw is sbyte || raw is short || raw is ushort ||
            raw is int || raw is uint || raw is long || raw is ulong)
        {
            try { value = Convert.ToDouble(raw, CultureInfo.InvariantCulture); return true; }
            catch (OverflowException) { return false; }
        }

        string text = raw as string;
        if (text == null) return false;
        return double.TryParse(text.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out value);
    }

    private static bool TryGetBooleanValue(object raw, out bool value)
    {
        value = false;
        if (raw == null || raw == DBNull.Value) return false;
        if (raw is bool) { value = (bool)raw; return true; }
        string text = Convert.ToString(raw, CultureInfo.InvariantCulture) ?? "";
        if (bool.TryParse(text, out value)) return true;
        long number;
        if (long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out number))
        {
            value = number != 0L;
            return true;
        }
        return false;
    }

    private static long? GetNullableNonNegativeInt64(object raw)
    {
        if (raw == null || raw == DBNull.Value) return null;
        long value;
        if (!TryConvertInt64(raw, out value) || value < 0L) return null;
        return value;
    }

    private static long? GetNullablePositiveInt64(object raw)
    {
        long? value = GetNullableNonNegativeInt64(raw);
        return value.HasValue && value.Value > 0L ? value : null;
    }

    private static long GetInt64Value(object raw)
    {
        double value;
        if (TryGetDoubleValue(raw, out value) &&
            !double.IsNaN(value) && !double.IsInfinity(value) &&
            value >= (double)long.MinValue && value <= (double)long.MaxValue)
        {
            try { return Convert.ToInt64(Math.Truncate(value), CultureInfo.InvariantCulture); }
            catch (OverflowException) { }
        }
        return 0L;
    }

    private static long GetCachedTokenValue(TokenRaderJsonUsage usage)
    {
        if (usage == null) return 0L;
        // cached_input_tokens is the current spelling.  Older/newer Codex
        // emitters have also used cache_read_tokens or cached_tokens for the
        // same read portion; use the first field that is actually present.
        object raw = usage.CachedInputTokens;
        if (raw == null) raw = usage.CacheReadTokens;
        if (raw == null) raw = usage.CachedTokens;
        return GetInt64Value(raw);
    }

    private static bool HasAnyUsageValue(TokenRaderJsonUsage usage)
    {
        if (usage == null) return false;
        return usage.InputTokens != null ||
            usage.CachedInputTokens != null ||
            usage.OutputTokens != null ||
            usage.ReasoningOutputTokens != null ||
            usage.CacheReadTokens != null ||
            usage.CachedTokens != null ||
            usage.CacheCreationTokens != null ||
            usage.CacheCreationInputTokens != null ||
            usage.CacheWriteTokens != null ||
            usage.CacheWriteInputTokens != null;
    }

    /// <summary>
    /// Cache-write fields are aliases emitted by different log versions.
    /// Presence, rather than a positive numeric value, determines precedence:
    /// an explicit zero must win over a later alias with a non-zero value.
    /// </summary>
    private static void GetCacheCreationTokenValue(
        TokenRaderJsonUsage usage,
        out long value,
        out bool observable)
    {
        value = 0L;
        observable = false;
        if (usage == null) return;

        object[] aliases = new[] {
            usage.CacheCreationTokens,
            usage.CacheWriteTokens,
            usage.CacheCreationInputTokens,
            usage.CacheWriteInputTokens
        };
        for (int i = 0; i < aliases.Length; i++)
        {
            if (aliases[i] == null) continue;
            long parsed;
            if (!TryConvertInt64(aliases[i], out parsed)) continue;
            value = parsed < 0L ? 0L : parsed;
            observable = true;
            return;
        }
    }

    private static bool IsKnownLongContextModel(string model)
    {
        string normalized = (model ?? "").Trim().ToLowerInvariant();
        foreach (string id in new[] { "gpt-6-astra", "gpt-5.6", "gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.6-cyber", "gpt-daybreak-blue-latest", "gpt-daybreak-red-latest", "gpt-5.4" })
        {
            if (normalized == id || normalized.StartsWith(id + "-20", StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    private static double GetDoubleValueOrZero(object raw)
    {
        double value;
        if (TryGetDoubleValue(raw, out value)) return value;
        return 0.0;
    }
}
