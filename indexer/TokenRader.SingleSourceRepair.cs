using System;
using System.Collections.Generic;
using System.Data.SQLite;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Manual, explicitly authorized recovery only. Nothing in normal startup calls this API.
public sealed class TokenRaderVerifiedSourceStage : IDisposable
{
    internal SQLiteConnection Db;
    internal FileStream Source;
    internal string Path;
    internal long End;
    internal byte[] Digest;
    internal int ParserVersion;
    internal bool Applied;
    internal TokenRaderIndexer.RepairFileIdentity Identity;
    internal TokenRaderIndexer.RepairRelationProof Relations;
    public long TokenRows { get; internal set; }
    public long ToolRows { get; internal set; }
    public long UnresolvedTokenRows { get; internal set; }
    public long VerifiedBytes { get; internal set; }
    public bool MetadataBackupVerified { get; internal set; }
    internal TokenRaderVerifiedSourceStage() { }
    public void Dispose()
    {
        if (Db != null) { Db.Dispose(); Db = null; }
        if (Source != null) { Source.Dispose(); Source = null; }
        if (Digest != null) { Array.Clear(Digest, 0, Digest.Length); Digest = null; }
        Relations = null;
    }
}

public sealed class TokenRaderSingleSourceRepairResult
{
    public long TokenRows { get; internal set; }
    public long ToolRows { get; internal set; }
    public long UnresolvedTokenRows { get; internal set; }
    public long IndexRevision { get; internal set; }
    public bool Applied { get; internal set; }
}

public sealed class TokenRaderRepairException : IOException
{
    public string Code { get; private set; }
    internal TokenRaderRepairException(string code) : base("Single-source repair refused: " + code + "; original index retained.") { Code = code; }
}

public static partial class TokenRaderIndexer
{
    private static readonly string[] RepairTables = {
        "token_records", "tool_records", "recent_lineage_evidence", "file_metadata",
        "history_gaps", "recent_history_work", "recent_history_sources", "recent_history_attempt_stamps"
    };
    private static string RepairPathColumn(string table)
    { return table == "token_records" || table == "tool_records" || table == "recent_lineage_evidence" ? "source_path" : "path"; }
    private static TokenRaderRepairException RepairRefusal(string code = "repair_validation_failed")
    { return new TokenRaderRepairException(code); }

    /// <summary>
    /// Validates and indexes exactly a complete frozen prefix of one source.
    /// Only metadata enters an isolated memory database. The source remains shared-read/write.
    /// The returned proof binds the bytes actually consumed by the line reader, not prefetches.
    /// </summary>
    public static TokenRaderVerifiedSourceStage StageSingleSourceRepair(
        string sourcePath, long frozenEnd, CancellationToken cancel)
    { return StageSingleSourceRepairCore(null, sourcePath, frozenEnd, cancel); }

    // Opt-in only: caller must separately authorize reading bounded index relations.
    public static TokenRaderVerifiedSourceStage StageSingleSourceRepair(
        SQLiteConnection liveDb, string sourcePath, long frozenEnd, CancellationToken cancel)
    {
        if (liveDb == null) throw RepairRefusal("repair_relationship_unverified");
        return StageSingleSourceRepairCore(liveDb, sourcePath, frozenEnd, cancel);
    }
    private static TokenRaderVerifiedSourceStage StageSingleSourceRepairCore(
        SQLiteConnection liveDb, string sourcePath, long frozenEnd, CancellationToken cancel)
    {
        var stage = new TokenRaderVerifiedSourceStage();
        try
        {
            cancel.ThrowIfCancellationRequested();
            stage.Path = GetCanonicalPath(sourcePath); stage.End = frozenEnd;
            stage.ParserVersion = RecentHistoryParserVersion;
            stage.Source = new FileStream(stage.Path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            stage.Identity = ReadRepairIdentity(stage.Source);
            long frozenWriteTicks = File.GetLastWriteTimeUtc(stage.Path).Ticks;
            if (frozenEnd == -1L) frozenEnd = FindRepairFrozenEnd(stage.Source, cancel);
            stage.End = frozenEnd;
            if (frozenEnd <= 0L || frozenEnd > stage.Source.Length) throw RepairRefusal("repair_invalid_boundary");
            DateTimeOffset frozenAt = DateTimeOffset.UtcNow;
            byte[] headerBytes = ReadRepairHeader(stage.Source, frozenEnd, cancel);
            string header = new UTF8Encoding(false, true).GetString(headerBytes).TrimStart('\uFEFF');
            var headerValues = new RepairJsonValidator(header).Validate();
            string session, cwd;
            if (!headerValues.TryGetValue("type", out session) || session != "session_meta" ||
                !headerValues.TryGetValue("payload.id", out session) || string.IsNullOrWhiteSpace(session))
                throw RepairRefusal("repair_session_header_invalid");
            headerValues.TryGetValue("payload.cwd", out cwd);
            string parent = "", fork = "", root = session;
            if (liveDb == null) ValidateRepairRelationships(headerValues, session);
            else
            {
                foreach (string key in new[] { "payload.parent_thread_id", "payload.parent_session_id", "payload.forked_from_id" })
                {
                    string value; if (!headerValues.TryGetValue(key, out value) || string.IsNullOrEmpty(value)) continue;
                    if (parent.Length != 0 && !string.Equals(parent, value, StringComparison.OrdinalIgnoreCase))
                        throw RepairRefusal("repair_relationship_unverified");
                    parent = value;
                }
                if (parent.Length == 0 || string.Equals(parent, session, StringComparison.OrdinalIgnoreCase))
                { ValidateRepairRelationships(headerValues, session); parent = ""; }
                else
                {
                    foreach (string key in new[] { "payload.root_session_id", "payload.root_thread_id" })
                    { string value; if (headerValues.TryGetValue(key, out value) && !string.IsNullOrEmpty(value) && !string.Equals(value, parent, StringComparison.OrdinalIgnoreCase)) throw RepairRefusal("repair_relationship_unverified"); }
                    headerValues.TryGetValue("payload.forked_from_id", out fork); root = parent;
                    stage.Relations = CaptureRepairRelations(liveDb, stage.Path, session, parent, cancel);
                }
            }
            stage.Db = new SQLiteConnection("Data Source=:memory:;Version=3;New=True;");
            stage.Db.Open(); CreateSchema(stage.Db);
            var history = new HistoryGapState { Path = stage.Path, Session = session, Root = root,
                Parent = parent, Start = 0L, End = frozenEnd, Cursor = 0L, Recent = true,
                Cutoff = DateTimeOffset.MinValue, FrozenEnd = frozenAt, BlockedReason = "" };
            bool first = true;
            Action<string> validate = delegate(string line)
            {
                string json = line.TrimStart('\uFEFF');
                var values = new RepairJsonValidator(json).Validate();
                if (first)
                {
                    first = false;
                    // The preliminary session header must be exactly the one parsed for staging.
                    if (!string.Equals(json, header, StringComparison.Ordinal)) throw RepairRefusal("repair_source_changed");
                }
                string type, payloadType;
                values.TryGetValue("type", out type); values.TryGetValue("payload.type", out payloadType);
                if (type == "session_meta" && json != header) throw RepairRefusal("repair_session_header_changed");
                bool output = type == "response_item" && (payloadType == "function_call_output" || payloadType == "custom_tool_call_output");
                string itemType; values.TryGetValue("payload.item.type", out itemType);
                bool command = type == "event_msg" && payloadType == "item_completed" && itemType == "CommandExecution";
                if (output || command || _canonicalToolCallTypes.Contains(string.IsNullOrEmpty(payloadType) ? type ?? "" : payloadType))
                {
                    string timestamp; DateTimeOffset toolAt;
                    if (!values.TryGetValue("timestamp", out timestamp) || !TryParseTimestamp(timestamp, out toolAt) || toolAt > frozenAt)
                        throw RepairRefusal("repair_tool_timestamp_invalid");
                    if (output)
                    {
                        var scan = new ToolOutputBodyScan(); byte[] body = Encoding.UTF8.GetBytes(json);
                        for (int i = 0; i < body.Length; i++) { if ((i & 65535) == 0) cancel.ThrowIfCancellationRequested(); scan.Feed(body[i]); }
                        if (!scan.Complete) throw RepairRefusal("repair_tool_shape_invalid");
                    }
                    if (command)
                    {
                        var scan = new CommandExecutionBodyScan(); byte[] body = Encoding.UTF8.GetBytes(json);
                        for (int i = 0; i < body.Length; i++) { if ((i & 65535) == 0) cancel.ThrowIfCancellationRequested(); scan.Feed(body[i]); }
                        if (scan.Projection == null) throw RepairRefusal("repair_tool_shape_invalid");
                    }
                }
                if (type == "token_count" || type == "event_msg" && payloadType == "token_count")
                {
                    var record = DeserializeLogRecord(json);
                    DateTimeOffset at;
                    if (record == null || record.Payload == null || record.Payload.Info == null ||
                        !TryParseTimestamp(record.Timestamp, out at) || at > frozenAt ||
                        !HasAnyUsageValue(record.Payload.Info.TotalTokenUsage) &&
                        !HasAnyUsageValue(record.Payload.Info.LastTokenUsage)) throw RepairRefusal("repair_usage_invalid");
                }
            };
            using (var consumed = new RepairConsumedDigest(cancel))
            using (var tx = stage.Db.BeginTransaction())
            {
                using (var cmd = stage.Db.CreateCommand())
                {
                    cmd.Transaction = tx;
                    cmd.CommandText = "INSERT INTO recent_history_work(path,start_offset,end_offset,cursor_offset) VALUES(@path,0,@end,0)";
                    cmd.Parameters.AddWithValue("@path", stage.Path); cmd.Parameters.AddWithValue("@end", frozenEnd);
                    cmd.ExecuteNonQuery();
                }
                ImportFile(stage.Db, stage.Path, 0L, frozenEnd, root, parent, 1L, null, cancel,
                    history, null, 0, tx, stage.Source, consumed.Feed, validate, frozenAt.UtcDateTime.Ticks);
                if (first || history.Cursor != frozenEnd || history.Discard ||
                    !string.IsNullOrEmpty(history.BlockedReason) || consumed.Count != frozenEnd)
                    throw RepairRefusal("repair_coverage_incomplete");
                stage.Digest = consumed.Finish();
                UpsertFileMetadata(stage.Db, stage.Path, frozenEnd, frozenWriteTicks,
                    frozenEnd, session, cwd ?? "", parent, fork ?? "", root, true, tx);
                UpsertFileContextTier(stage.Db, tx, stage.Path, session, root, frozenEnd,
                    history.Tier ?? "", history.TierSource ?? "");
                UpsertFileContextModel(stage.Db, tx, stage.Path, session, root, frozenEnd,
                    history.Model ?? "", history.ModelSource ?? "", history.ModelTimestamp ?? "");
                using (var cmd = stage.Db.CreateCommand())
                {
                    cmd.Transaction = tx;
                    cmd.CommandText = "INSERT INTO recent_history_sources(path,end_offset) VALUES(@path,@end)";
                    cmd.Parameters.AddWithValue("@path", stage.Path); cmd.Parameters.AddWithValue("@end", frozenEnd);
                    cmd.ExecuteNonQuery();
                }
                cancel.ThrowIfCancellationRequested(); tx.Commit();
            }
            VerifyRepairPrefix(stage, cancel);
            stage.TokenRows = RepairCount(stage.Db, null, "token_records", stage.Path);
            stage.ToolRows = RepairCount(stage.Db, null, "tool_records", stage.Path);
            using (var cmd = stage.Db.CreateCommand())
            {
                cmd.CommandText = "SELECT COUNT(*) FROM token_records WHERE source_path COLLATE BINARY=@path AND trim(COALESCE(model,''))=''";
                cmd.Parameters.AddWithValue("@path", stage.Path);
                stage.UnresolvedTokenRows = Convert.ToInt64(cmd.ExecuteScalar(), CultureInfo.InvariantCulture);
            }
            stage.VerifiedBytes = frozenEnd;
            return stage;
        }
        catch (OperationCanceledException) { stage.Dispose(); throw; }
        catch (TokenRaderRepairException) { stage.Dispose(); throw; }
        catch (DecoderFallbackException) { stage.Dispose(); throw RepairRefusal("repair_invalid_utf8"); }
        catch { stage.Dispose(); throw RepairRefusal("repair_stage_failed"); }
    }

    /// <summary>
    /// Backs up only this source's eight metadata tables, then atomically replaces them.
    /// Caller must hold the application's normal index gate/file lock. No session-wide deletion.
    /// The backup path must be beneath the live database's existing data/private ancestor.
    /// </summary>
    public static TokenRaderSingleSourceRepairResult CommitSingleSourceRepair(
        SQLiteConnection liveDb, TokenRaderVerifiedSourceStage stage,
        string metadataBackupPath, CancellationToken cancel)
    {
        try
        {
            cancel.ThrowIfCancellationRequested();
            if (stage == null || stage.Db == null || stage.Source == null || stage.Applied ||
                stage.ParserVersion != RecentHistoryParserVersion || stage.VerifiedBytes != stage.End)
                throw RepairRefusal("repair_stage_invalid");
            stage.MetadataBackupVerified = false;
            string privateRoot = RepairPrivateRoot(liveDb);
            string backupPath = System.IO.Path.GetFullPath(metadataBackupPath);
            if (!backupPath.StartsWith(privateRoot, StringComparison.OrdinalIgnoreCase) || File.Exists(backupPath))
                throw RepairRefusal("repair_backup_target_invalid");
            RejectRepairReparseParents(System.IO.Path.GetDirectoryName(backupPath));
            ValidateRepairSchema(liveDb, stage.Db);
            VerifyRepairPrefix(stage, cancel);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(backupPath));
            RejectRepairReparseParents(System.IO.Path.GetDirectoryName(backupPath));
            // Reserve without overwriting an existing backup. Only metadata is ever written here.
            using (var reserved = new FileStream(backupPath, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
            long revision;
            using (var tx = liveDb.BeginTransaction())
            {
                ValidateRepairSchema(liveDb, stage.Db);
                if (stage.Relations != null) RevalidateRepairRelations(liveDb, tx, stage, cancel);
                ValidateRepairAssociations(liveDb, tx, stage);
                using (var guard = liveDb.CreateCommand())
                {
                    guard.Transaction = tx;
                    guard.CommandText = "SELECT COUNT(*) FROM history_gaps WHERE path COLLATE BINARY=@path AND blocked_reason='source_replaced'";
                    guard.Parameters.AddWithValue("@path", stage.Path);
                    if (Convert.ToInt64(guard.ExecuteScalar(), CultureInfo.InvariantCulture) == 0L) throw RepairRefusal("repair_guard_missing");
                }
                var backupConnection = new SQLiteConnectionStringBuilder { DataSource = backupPath, Version = 3 };
                using (var backup = new SQLiteConnection(backupConnection.ConnectionString))
                {
                    backup.Open(); CreateSchema(backup);
                    using (var backupTx = backup.BeginTransaction())
                    {
                        foreach (string table in RepairTables)
                        {
                            cancel.ThrowIfCancellationRequested();
                            RepairCopyRows(liveDb, tx, backup, backupTx, table, stage.Path, true, null, cancel);
                        }
                        using (var manifest = backup.CreateCommand())
                        {
                            manifest.Transaction = backupTx;
                            manifest.CommandText = "CREATE TABLE repair_manifest(status TEXT NOT NULL,parser_version INTEGER NOT NULL,source_end INTEGER NOT NULL,old_revision INTEGER NOT NULL); INSERT INTO repair_manifest VALUES('metadata_backup',@parser,@end,@revision)";
                            manifest.Parameters.AddWithValue("@parser", stage.ParserVersion);
                            manifest.Parameters.AddWithValue("@end", stage.End);
                            manifest.Parameters.AddWithValue("@revision", GetIndexRevision(liveDb));
                            manifest.ExecuteNonQuery();
                        }
                        cancel.ThrowIfCancellationRequested(); backupTx.Commit();
                    }
                }
                backupConnection.ReadOnly = true;
                using (var backup = new SQLiteConnection(backupConnection.ConnectionString))
                {
                    backup.Open();
                    foreach (string table in RepairTables)
                        RepairVerifyRows(liveDb, tx, backup, null, table, stage.Path, cancel);
                }
                stage.MetadataBackupVerified = true;
                VerifyRepairPrefix(stage, cancel);
                revision = checked(GetIndexRevision(liveDb) + 1L);
                foreach (string table in RepairTables)
                {
                    cancel.ThrowIfCancellationRequested();
                    using (var cmd = liveDb.CreateCommand())
                    {
                        cmd.Transaction = tx;
                        cmd.CommandText = "DELETE FROM " + table + " WHERE " + RepairPathColumn(table) + " COLLATE BINARY=@path";
                        cmd.Parameters.AddWithValue("@path", stage.Path); cmd.ExecuteNonQuery();
                    }
                    RepairCopyRows(stage.Db, null, liveDb, tx, table, stage.Path, false, revision, cancel);
                }
                SetSettingInTransaction(liveDb, tx, "IndexRevision", revision.ToString(CultureInfo.InvariantCulture));
                SetSettingInTransaction(liveDb, tx, "recent_history_coverage_start", "");
                SetSettingInTransaction(liveDb, tx, "recent_history_frozen_at", "");
                SetSettingInTransaction(liveDb, tx, "history_coverage_start", "");
                VerifyRepairPrefix(stage, cancel);
                cancel.ThrowIfCancellationRequested(); tx.Commit();
            }
            stage.Applied = true;
            return new TokenRaderSingleSourceRepairResult { Applied = true, TokenRows = stage.TokenRows,
                ToolRows = stage.ToolRows, UnresolvedTokenRows = stage.UnresolvedTokenRows, IndexRevision = revision };
        }
        catch (OperationCanceledException) { throw; }
        catch (TokenRaderRepairException) { throw; }
        catch { throw RepairRefusal("repair_commit_failed"); }
    }

    private static long FindRepairFrozenEnd(Stream source, CancellationToken cancel)
    {
        long end = source.Length; byte[] block = new byte[65536];
        while (end > 0L)
        {
            cancel.ThrowIfCancellationRequested(); long start = Math.Max(0L, end - block.Length);
            source.Seek(start, SeekOrigin.Begin); int requested = (int)(end - start), received = 0;
            while (received < requested)
            {
                int count = source.Read(block, received, requested - received);
                if (count <= 0) throw RepairRefusal(); received += count;
            }
            for (int i = received - 1; i >= 0; i--)
                if (block[i] == '\n' || block[i] == '\r') return start + i + 1L;
            end = start;
        }
        throw RepairRefusal();
    }
    private static string RepairDatabasePath(SQLiteConnection live, SQLiteTransaction tx)
    {
        string livePath = null;
        using (var cmd = live.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "PRAGMA database_list";
            using (var reader = cmd.ExecuteReader()) while (reader.Read())
                if (reader.GetString(1) == "main") livePath = reader.GetString(2);
        }
        if (string.IsNullOrEmpty(livePath) || livePath == ":memory:") throw RepairRefusal("repair_live_db_location_invalid");
        return System.IO.Path.GetFullPath(livePath);
    }
    private static string RepairPrivateRoot(SQLiteConnection live)
    {
        string livePath = RepairDatabasePath(live, null);
        if ((File.GetAttributes(System.IO.Path.GetFullPath(livePath)) & FileAttributes.ReparsePoint) != 0)
            throw RepairRefusal("repair_backup_target_invalid");
        var directory = new DirectoryInfo(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(livePath)));
        string found = null;
        for (; directory != null; directory = directory.Parent)
        {
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) throw RepairRefusal("repair_backup_target_invalid");
            if (directory.Name.Equals("private", StringComparison.OrdinalIgnoreCase) && directory.Parent != null &&
                directory.Parent.Name.Equals("data", StringComparison.OrdinalIgnoreCase))
                found = directory.FullName.TrimEnd(System.IO.Path.DirectorySeparatorChar) + System.IO.Path.DirectorySeparatorChar;
        }
        if (found == null) throw RepairRefusal("repair_backup_target_invalid"); return found;
    }
    private static void RejectRepairReparseParents(string path)
    {
        for (var directory = new DirectoryInfo(path); directory != null; directory = directory.Parent)
            if (directory.Exists && (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw RepairRefusal("repair_backup_target_invalid");
    }
    private static void ValidateRepairAssociations(SQLiteConnection live, SQLiteTransaction tx, TokenRaderVerifiedSourceStage stage)
    {
        string newSession, oldSession;
        using (var cmd = stage.Db.CreateCommand())
        {
            cmd.CommandText = "SELECT session_id FROM file_metadata WHERE path COLLATE BINARY=@path";
            cmd.Parameters.AddWithValue("@path", stage.Path); newSession = Convert.ToString(cmd.ExecuteScalar(), CultureInfo.InvariantCulture);
        }
        using (var cmd = live.CreateCommand())
        {
            cmd.Transaction = tx; cmd.CommandText = "SELECT session_id FROM file_metadata WHERE path COLLATE BINARY=@path";
            cmd.Parameters.AddWithValue("@path", stage.Path); oldSession = Convert.ToString(cmd.ExecuteScalar(), CultureInfo.InvariantCulture);
        }
        foreach (string table in new[] { "token_records", "tool_records", "recent_lineage_evidence", "file_metadata" })
        using (var cmd = live.CreateCommand())
        {
            cmd.Transaction = tx;
            cmd.CommandText = "SELECT COUNT(*) FROM " + table + " WHERE COALESCE(" + RepairPathColumn(table) + ",'') COLLATE BINARY<>@path AND " +
                "((session_id=@new AND @new<>'') OR (session_id=@old AND @old<>''))";
            if (table != "recent_lineage_evidence") cmd.CommandText += " OR (COALESCE(" + RepairPathColumn(table) + ",'') COLLATE BINARY<>@path AND ((root_session_id=@new AND @new<>'') OR (root_session_id=@old AND @old<>'')))";
            cmd.Parameters.AddWithValue("@path", stage.Path); cmd.Parameters.AddWithValue("@new", newSession);
            cmd.Parameters.AddWithValue("@old", oldSession);
            if (Convert.ToInt64(cmd.ExecuteScalar(), CultureInfo.InvariantCulture) != 0L) throw RepairRefusal("repair_cross_source_association");
        }
    }

    private static byte[] ReadRepairHeader(Stream source, long end, CancellationToken cancel)
    {
        source.Seek(0L, SeekOrigin.Begin);
        using (var bytes = new MemoryStream())
        {
            while (source.Position < end && bytes.Length <= 1024L * 1024L)
            {
                if ((bytes.Length & 65535L) == 0L) cancel.ThrowIfCancellationRequested();
                int b = source.ReadByte();
                if (b == '\n' || b == '\r') return bytes.ToArray();
                if (b < 0) break; bytes.WriteByte((byte)b);
            }
        }
        throw RepairRefusal();
    }
    private static void ValidateRepairRelationships(Dictionary<string, string> values, string session)
    {
        foreach (string key in new[] { "payload.parent_thread_id", "payload.parent_session_id", "payload.forked_from_id", "payload.root_session_id", "payload.root_thread_id" })
        { string value; if (values.TryGetValue(key, out value) && !string.IsNullOrEmpty(value) && value != session) throw RepairRefusal("repair_relationship_unverified"); }
    }
    internal sealed class RepairRelationProof
    {
        internal string DatabasePath, Child, Parent;
        internal RepairFileIdentity DatabaseIdentity;
        internal List<List<object[]>> Rows;
    }
    private static RepairRelationProof CaptureRepairRelations(SQLiteConnection live, string path,
        string child, string parent, CancellationToken cancel)
    {
        // Never read parent bodies, token/model records, or copy parent rows into staging.
        RepairPrivateRoot(live);
        string databasePath = RepairDatabasePath(live, null);
        var builder = new SQLiteConnectionStringBuilder { DataSource = databasePath, Version = 3, ReadOnly = true, FailIfMissing = true, Pooling = false };
        using (var read = new SQLiteConnection(builder.ConnectionString))
        using (var identity = new FileStream(databasePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            read.Open();
            using (var command = read.CreateCommand()) { command.CommandText = "PRAGMA query_only=ON;BEGIN"; command.ExecuteNonQuery(); }
            try
            {
                return new RepairRelationProof { DatabasePath = databasePath, DatabaseIdentity = ReadRepairIdentity(identity),
                    Child = child, Parent = parent, Rows = ReadRepairRelations(read, null, path, child, parent, cancel) };
            }
            finally { using (var command = read.CreateCommand()) { command.CommandText = "ROLLBACK"; command.ExecuteNonQuery(); } }
        }
    }
    private static List<object[]> RepairRelationRows(SQLiteConnection db, SQLiteTransaction tx,
        string sql, string path, string child, string parent, CancellationToken cancel)
    {
        var rows = new List<object[]>();
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = tx; cmd.CommandText = sql;
            cmd.Parameters.AddWithValue("@path", path); cmd.Parameters.AddWithValue("@child", child); cmd.Parameters.AddWithValue("@parent", parent);
            using (var reader = cmd.ExecuteReader()) while (reader.Read())
            {
                cancel.ThrowIfCancellationRequested();
                var values = new object[reader.FieldCount]; reader.GetValues(values); rows.Add(values);
            }
        }
        return rows;
    }
    private static string RepairRelationString(object value)
    { return value == DBNull.Value ? "" : Convert.ToString(value, CultureInfo.InvariantCulture); }
    private static bool RepairRelationId(object value, string expected)
    { return string.Equals(RepairRelationString(value), expected, StringComparison.OrdinalIgnoreCase); }
    private static bool RepairTerminalEdge(object value, string parent)
    { return RepairRelationString(value).Length == 0 || RepairRelationId(value, parent); }
    private static List<List<object[]>> ReadRepairRelations(SQLiteConnection db, SQLiteTransaction tx,
        string path, string child, string parent, CancellationToken cancel)
    {
        var result = new List<List<object[]>>();
        string catalogColumns = "path,session_id,parent_thread_id,forked_from_id,root_session_id,length,last_write_ticks,parsed_offset,content_retained";
        var target = RepairRelationRows(db, tx, "SELECT " + catalogColumns + " FROM file_metadata WHERE path COLLATE BINARY=@path", path, child, parent, cancel);
        if (target.Count != 1 || !RepairRelationId(target[0][1], child) ||
            !RepairTerminalEdge(target[0][2], parent) || !RepairTerminalEdge(target[0][3], parent) ||
            !(RepairRelationId(target[0][4], child) || RepairRelationId(target[0][4], parent)))
            throw RepairRefusal("repair_relationship_unverified");
        var candidates = RepairRelationRows(db, tx, "SELECT " + catalogColumns + " FROM file_metadata WHERE session_id COLLATE NOCASE=@parent ORDER BY path COLLATE BINARY LIMIT 33", path, child, parent, cancel);
        if (candidates.Count == 0 || candidates.Count > 32) throw RepairRefusal("repair_relationship_unverified");
        foreach (object[] candidate in candidates)
        {
            if (RepairRelationString(candidate[0]).Length == 0 || !RepairRelationId(candidate[1], parent) ||
                !RepairRelationId(candidate[4], parent) || !RepairTerminalEdge(candidate[2], parent) || !RepairTerminalEdge(candidate[3], parent))
                throw RepairRefusal("repair_relationship_unverified");
            string candidatePath = RepairRelationString(candidate[0]), canonical;
            try { canonical = System.IO.Path.GetFullPath(candidatePath); }
            catch { throw RepairRefusal("repair_relationship_unverified"); }
            if (!System.IO.Path.IsPathRooted(candidatePath) ||
                !string.Equals(candidatePath, canonical, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(canonical, path, StringComparison.OrdinalIgnoreCase))
                throw RepairRefusal("repair_relationship_unverified");
        }
        result.Add(candidates);
        foreach (string table in new[] { "history_gaps", "recent_history_work" })
        {
            var guards = RepairRelationRows(db, tx, "SELECT path,start_offset,end_offset,cursor_offset,blocked_reason FROM " + table +
                " WHERE path IN (SELECT path FROM file_metadata WHERE session_id COLLATE NOCASE=@parent) ORDER BY path COLLATE BINARY,start_offset,end_offset", path, child, parent, cancel);
            foreach (object[] guard in guards) if (RepairRelationString(guard[4]) == "source_replaced") throw RepairRefusal("repair_relationship_unverified");
            result.Add(guards);
        }
        foreach (string table in new[] { "token_records", "tool_records" })
        {
            var bad = RepairRelationRows(db, tx, "SELECT COUNT(*) FROM " + table + " WHERE source_path COLLATE BINARY=@path AND " +
                "(COALESCE(session_id,'') COLLATE NOCASE<>@child OR COALESCE(root_session_id,'') COLLATE NOCASE<>@parent)", path, child, parent, cancel);
            if (Convert.ToInt64(bad[0][0], CultureInfo.InvariantCulture) != 0L) throw RepairRefusal("repair_relationship_unverified");
        }
        foreach (string table in new[] { "token_records", "tool_records", "recent_lineage_evidence", "file_metadata" })
        {
            string column = RepairPathColumn(table);
            string extra = table == "recent_lineage_evidence" ? "" : " OR root_session_id COLLATE NOCASE=@child";
            var count = RepairRelationRows(db, tx, "SELECT COUNT(*) FROM " + table + " WHERE COALESCE(" + column +
                ",'') COLLATE BINARY<>@path AND (session_id COLLATE NOCASE=@child" + extra + ")", path, child, parent, cancel);
            if (Convert.ToInt64(count[0][0], CultureInfo.InvariantCulture) != 0L) throw RepairRefusal("repair_cross_source_association");
            result.Add(count);
        }
        foreach (string table in RepairTables)
        {
            var columns = RepairColumns(db, table); columns.Sort(StringComparer.Ordinal);
            string selected = string.Join(",", columns.ToArray());
            result.Add(RepairRelationRows(db, tx, "SELECT " + selected + " FROM " + table + " WHERE " + RepairPathColumn(table) +
                " COLLATE BINARY=@path ORDER BY " + selected, path, child, parent, cancel));
        }
        result.Add(RepairRelationRows(db, tx, "SELECT key,value FROM index_settings WHERE key='IndexRevision' ORDER BY key", path, child, parent, cancel));
        return result;
    }
    private static void RevalidateRepairRelations(SQLiteConnection live, SQLiteTransaction tx,
        TokenRaderVerifiedSourceStage stage, CancellationToken cancel)
    {
        var proof = stage.Relations;
        string path = RepairDatabasePath(live, tx);
        if (!string.Equals(path, proof.DatabasePath, StringComparison.OrdinalIgnoreCase)) throw RepairRefusal("repair_relation_changed");
        using (var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            if (!proof.DatabaseIdentity.Equals(ReadRepairIdentity(source))) throw RepairRefusal("repair_relation_changed");
        List<List<object[]>> current;
        try { current = ReadRepairRelations(live, tx, stage.Path, proof.Child, proof.Parent, cancel); }
        catch (TokenRaderRepairException) { throw RepairRefusal("repair_relation_changed"); }
        if (current.Count != proof.Rows.Count) throw RepairRefusal("repair_relation_changed");
        for (int set = 0; set < current.Count; set++)
        {
            if (current[set].Count != proof.Rows[set].Count) throw RepairRefusal("repair_relation_changed");
            for (int row = 0; row < current[set].Count; row++)
            {
                cancel.ThrowIfCancellationRequested();
                if (current[set][row].Length != proof.Rows[set][row].Length) throw RepairRefusal("repair_relation_changed");
                for (int column = 0; column < current[set][row].Length; column++)
                    if (!object.Equals(current[set][row][column], proof.Rows[set][row][column])) throw RepairRefusal("repair_relation_changed");
            }
        }
    }
    private static void VerifyRepairPrefix(TokenRaderVerifiedSourceStage stage, CancellationToken cancel)
    {
        // Hash the still-open incarnation AND the current path. Appends are permitted;
        // replacement/shrink or prefix changes are not. No digest is logged or persisted.
        using (var current = new FileStream(stage.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            if (!stage.Identity.Equals(ReadRepairIdentity(current)) ||
                !stage.Identity.Equals(ReadRepairIdentity(stage.Source)) ||
                !RepairDigestEqual(stage.Digest, RepairHashPrefix(stage.Source, stage.End, cancel)) ||
                !RepairDigestEqual(stage.Digest, RepairHashPrefix(current, stage.End, cancel))) throw RepairRefusal("repair_source_changed");
        }
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct RepairFileIdentity
    {
        internal uint Attributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
        internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        public override bool Equals(object other)
        {
            if (!(other is RepairFileIdentity)) return false;
            var value = (RepairFileIdentity)other;
            return Volume == value.Volume && IndexHigh == value.IndexHigh && IndexLow == value.IndexLow;
        }
        public override int GetHashCode() { return (int)(Volume ^ IndexHigh ^ IndexLow); }
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle file, out RepairFileIdentity information);
    private static RepairFileIdentity ReadRepairIdentity(FileStream source)
    {
        RepairFileIdentity identity;
        if (!GetFileInformationByHandle(source.SafeFileHandle, out identity)) throw RepairRefusal("repair_source_identity_unavailable");
        return identity;
    }
    private static byte[] RepairHashPrefix(Stream source, long end, CancellationToken cancel)
    {
        if (source.Length < end) throw RepairRefusal("repair_source_changed");
        source.Seek(0L, SeekOrigin.Begin);
        using (var hash = SHA256.Create())
        {
            byte[] buffer = new byte[65536]; long remaining = end;
            while (remaining > 0L)
            {
                cancel.ThrowIfCancellationRequested();
                int read = source.Read(buffer, 0, (int)Math.Min(remaining, buffer.Length));
                if (read <= 0) throw RepairRefusal("repair_source_changed");
                hash.TransformBlock(buffer, 0, read, buffer, 0); remaining -= read;
            }
            hash.TransformFinalBlock(new byte[0], 0, 0); return hash.Hash;
        }
    }
    private static bool RepairDigestEqual(byte[] left, byte[] right)
    {
        if (left == null || right == null || left.Length != right.Length) return false;
        int different = 0; for (int i = 0; i < left.Length; i++) different |= left[i] ^ right[i];
        return different == 0;
    }
    private sealed class RepairConsumedDigest : IDisposable
    {
        private readonly HashAlgorithm hash = SHA256.Create();
        private readonly byte[] buffer = new byte[65536];
        private readonly CancellationToken cancel;
        private int used;
        public long Count { get; private set; }
        public RepairConsumedDigest(CancellationToken token) { cancel = token; }
        public void Feed(int value)
        {
            buffer[used++] = (byte)value; Count++;
            if (used == buffer.Length) { cancel.ThrowIfCancellationRequested(); hash.TransformBlock(buffer, 0, used, buffer, 0); used = 0; }
        }
        public byte[] Finish() { hash.TransformFinalBlock(buffer, 0, used); return hash.Hash; }
        public void Dispose() { hash.Dispose(); Array.Clear(buffer, 0, buffer.Length); }
    }
    private static long RepairCount(SQLiteConnection db, SQLiteTransaction tx, string table, string path)
    {
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = tx; cmd.CommandText = "SELECT COUNT(*) FROM " + table + " WHERE " + RepairPathColumn(table) + " COLLATE BINARY=@path";
            cmd.Parameters.AddWithValue("@path", path); return Convert.ToInt64(cmd.ExecuteScalar(), CultureInfo.InvariantCulture);
        }
    }
    private static List<string> RepairColumns(SQLiteConnection db, string table)
    {
        var result = new List<string>();
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(" + table + ")";
            using (var reader = cmd.ExecuteReader()) while (reader.Read()) result.Add(reader.GetString(1));
        }
        return result;
    }
    private static void ValidateRepairSchema(SQLiteConnection live, SQLiteConnection staged)
    {
        var allowed = new HashSet<string>(RepairTables, StringComparer.Ordinal);
        allowed.UnionWith(new[] { "index_settings", "usage_history", "usage_history_models", "sqlite_sequence" });
        using (var cmd = live.CreateCommand())
        {
            cmd.CommandText = "SELECT type,name FROM sqlite_master WHERE type IN ('table','trigger','view')";
            using (var reader = cmd.ExecuteReader()) while (reader.Read())
                if (reader.GetString(0) != "table" || !allowed.Contains(reader.GetString(1))) throw RepairRefusal("repair_schema_mismatch");
        }
        foreach (string table in RepairTables)
        {
            var actual = RepairColumnSignatures(live, table); var expected = RepairColumnSignatures(staged, table);
            if (actual.Count != expected.Count) throw RepairRefusal("repair_schema_mismatch");
            foreach (var column in actual) { string wanted; if (!expected.TryGetValue(column.Key, out wanted) || wanted != column.Value) throw RepairRefusal("repair_schema_mismatch"); }
        }
        foreach (string table in allowed)
        {
            using (var cmd = live.CreateCommand())
            {
                cmd.CommandText = "PRAGMA foreign_key_list(" + table + ")";
                using (var reader = cmd.ExecuteReader()) if (reader.Read()) throw RepairRefusal("repair_schema_mismatch");
            }
        }
    }
    private static void RepairCopyRows(SQLiteConnection source, SQLiteTransaction sourceTx,
        SQLiteConnection target, SQLiteTransaction targetTx, string table, string path, bool preserveId, long? revision, CancellationToken cancel)
    {
        var columns = RepairColumns(source, table);
        if (!preserveId && table == "token_records") columns.Remove("id");
        var quoted = new List<string>(); var parameters = new List<string>();
        for (int i = 0; i < columns.Count; i++) { quoted.Add("\"" + columns[i].Replace("\"", "\"\"") + "\""); parameters.Add("@v" + i); }
        string names = string.Join(",", quoted.ToArray());
        using (var read = source.CreateCommand())
        using (var write = target.CreateCommand())
        {
            read.Transaction = sourceTx; write.Transaction = targetTx;
            read.CommandText = "SELECT " + names + " FROM " + table + " WHERE " + RepairPathColumn(table) + " COLLATE BINARY=@path";
            read.Parameters.AddWithValue("@path", path);
            write.CommandText = "INSERT INTO " + table + "(" + names + ") VALUES(" + string.Join(",", parameters.ToArray()) + ")";
            foreach (string parameter in parameters) write.Parameters.Add(new SQLiteParameter(parameter));
            using (var reader = read.ExecuteReader()) while (reader.Read())
            {
                cancel.ThrowIfCancellationRequested();
                for (int i = 0; i < columns.Count; i++)
                    write.Parameters[i].Value = revision.HasValue && columns[i] == "index_revision" ? (object)revision.Value : reader.GetValue(i);
                write.ExecuteNonQuery();
            }
        }
    }
    private static Dictionary<string, string> RepairColumnSignatures(SQLiteConnection db, string table)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        using (var cmd = db.CreateCommand())
        {
            cmd.CommandText = "PRAGMA table_info(" + table + ")";
            using (var reader = cmd.ExecuteReader()) while (reader.Read())
                result.Add(reader.GetString(1), Convert.ToString(reader.GetValue(2), CultureInfo.InvariantCulture) + "|" +
                    Convert.ToString(reader.GetValue(3), CultureInfo.InvariantCulture) + "|" +
                    Convert.ToString(reader.GetValue(4), CultureInfo.InvariantCulture) + "|" + Convert.ToString(reader.GetValue(5), CultureInfo.InvariantCulture));
        }
        return result;
    }
    private static void RepairVerifyRows(SQLiteConnection left, SQLiteTransaction leftTx, SQLiteConnection right,
        SQLiteTransaction rightTx, string table, string path, CancellationToken cancel)
    {
        var names = new List<string>();
        foreach (string column in RepairColumns(left, table)) names.Add("\"" + column.Replace("\"", "\"\"") + "\"");
        string columns = string.Join(",", names.ToArray());
        using (var a = left.CreateCommand()) using (var b = right.CreateCommand())
        {
            a.Transaction = leftTx; b.Transaction = rightTx;
            a.CommandText = b.CommandText = "SELECT " + columns + " FROM " + table + " WHERE " + RepairPathColumn(table) + " COLLATE BINARY=@path ORDER BY " + columns;
            a.Parameters.AddWithValue("@path", path); b.Parameters.AddWithValue("@path", path);
            using (var ar = a.ExecuteReader()) using (var br = b.ExecuteReader())
            {
                while (ar.Read())
                {
                    cancel.ThrowIfCancellationRequested(); if (!br.Read()) throw RepairRefusal("repair_backup_verification_failed");
                    for (int i = 0; i < ar.FieldCount; i++)
                    {
                        object av = ar.GetValue(i), bv = br.GetValue(i);
                        if (av.GetType() != bv.GetType() || !av.Equals(bv))
                            throw RepairRefusal("repair_backup_verification_failed");
                    }
                }
                if (br.Read()) throw RepairRefusal("repair_backup_verification_failed");
            }
        }
    }

    // Bounded, strict grammar check for small records; large records use the existing whole-line scanner.
    // Every decoded object key is unique (including escaped aliases). Values are never persisted.
    private sealed class RepairJsonValidator
    {
        private readonly string text;
        private int position;
        private readonly Dictionary<string, string> selected = new Dictionary<string, string>(StringComparer.Ordinal);
        public RepairJsonValidator(string value) { text = value; }
        public Dictionary<string, string> Validate()
        {
            try
            {
                White(); if (position >= text.Length || text[position] != '{') throw RepairRefusal();
                Value("", 0); White(); if (position != text.Length) throw RepairRefusal(); return selected;
            }
            catch (TokenRaderRepairException error)
            { if (error.Code == "repair_validation_failed") throw RepairRefusal("repair_invalid_json"); throw; }
        }
        private void White() { while (position < text.Length && (text[position] == ' ' || text[position] == '\t' || text[position] == '\r' || text[position] == '\n')) position++; }
        private void Need(char c) { White(); if (position >= text.Length || text[position++] != c) throw RepairRefusal(); }
        private bool Take(char c) { White(); if (position < text.Length && text[position] == c) { position++; return true; } return false; }
        private void Value(string path, int depth)
        {
            if (depth > 64) throw RepairRefusal(); White(); if (position >= text.Length) throw RepairRefusal();
            char c = text[position];
            bool usageValue = IsUsageValue(path);
            if (usageValue && c != '"' && c != 'n' && c != '-' && (c < '0' || c > '9'))
                throw RepairRefusal("repair_usage_invalid");
            if (c == '{')
            {
                position++; var keys = new HashSet<string>(StringComparer.Ordinal);
                if (Take('}')) return;
                do
                {
                    string key = String(); if (key.Length > 256 || keys.Count >= 4096 || !keys.Add(key)) throw RepairRefusal();
                    string segment = key.Replace("\\", "\\\\").Replace(".", "\\.").Replace("[", "\\[").Replace("]", "\\]");
                    Need(':'); Value(path.Length == 0 ? segment : path + "." + segment, depth + 1);
                } while (Take(',')); Need('}'); return;
            }
            if (c == '[')
            {
                position++; if (Take(']')) return;
                do { Value(path + "[]", depth + 1); } while (Take(',')); Need(']'); return;
            }
            if (c == '"')
            {
                bool capture = path == "type" || path == "timestamp" || path == "payload.type" || path == "payload.item.type" || path == "payload.id" || path == "payload.cwd" ||
                    path == "payload.parent_thread_id" || path == "payload.parent_session_id" || path == "payload.forked_from_id" ||
                    path == "payload.root_session_id" || path == "payload.root_thread_id";
                string value = String(capture || usageValue); if (capture) selected[path] = value;
                if (usageValue) ValidateUsageInteger(value);
                return;
            }
            if (c == 't') { Literal("true"); return; } if (c == 'f') { Literal("false"); return; }
            if (c == 'n') { Literal("null"); return; }
            int start = position; Number();
            if (usageValue) ValidateUsageInteger(text.Substring(start, position - start));
        }
        private static bool IsUsageValue(string path)
        {
            const string total = "payload.info.total_token_usage.", last = "payload.info.last_token_usage.";
            string key = path.StartsWith(total, StringComparison.Ordinal) ? path.Substring(total.Length) :
                path.StartsWith(last, StringComparison.Ordinal) ? path.Substring(last.Length) : "";
            return key == "input_tokens" || key == "cached_input_tokens" || key == "output_tokens" ||
                key == "reasoning_output_tokens" || key == "cache_read_tokens" || key == "cached_tokens" ||
                key == "cache_creation_tokens" || key == "cache_creation_input_tokens" ||
                key == "cache_write_tokens" || key == "cache_write_input_tokens";
        }
        private static void ValidateUsageInteger(string value)
        { long number; if (!long.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out number) || number < 0L) throw RepairRefusal("repair_usage_invalid"); }
        private void Literal(string value)
        { if (position + value.Length > text.Length || text.Substring(position, value.Length) != value) throw RepairRefusal(); position += value.Length; }
        private void Number()
        {
            if (Take('-') && position >= text.Length) throw RepairRefusal();
            if (position >= text.Length) throw RepairRefusal();
            if (text[position] == '0') position++;
            else { if (text[position] < '1' || text[position] > '9') throw RepairRefusal(); Digits(); }
            if (position < text.Length && text[position] == '.') { position++; RequiredDigits(); }
            if (position < text.Length && (text[position] == 'e' || text[position] == 'E'))
            { position++; if (position < text.Length && (text[position] == '+' || text[position] == '-')) position++; RequiredDigits(); }
        }
        private void Digits() { while (position < text.Length && text[position] >= '0' && text[position] <= '9') position++; }
        private void RequiredDigits() { int start = position; Digits(); if (start == position) throw RepairRefusal(); }
        private string String(bool capture = true)
        {
            Need('"'); var value = capture ? new StringBuilder() : null; bool highSurrogate = false;
            while (position < text.Length)
            {
                char c = text[position++];
                if (c == '"') { if (highSurrogate) throw RepairRefusal(); return capture ? value.ToString() : null; } if (c < 32) throw RepairRefusal();
                if (c == '\\')
                {
                    if (position >= text.Length) throw RepairRefusal(); c = text[position++];
                    if (c == 'u')
                    {
                        int number = 0;
                        for (int i = 0; i < 4; i++)
                        {
                            if (position >= text.Length) throw RepairRefusal(); char h = text[position++];
                            int digit = h >= '0' && h <= '9' ? h - '0' : h >= 'a' && h <= 'f' ? h - 'a' + 10 : h >= 'A' && h <= 'F' ? h - 'A' + 10 : -1;
                            if (digit < 0) throw RepairRefusal(); number = number * 16 + digit;
                        }
                        c = (char)number;
                    }
                    else if (c == 'b') c = '\b'; else if (c == 'f') c = '\f'; else if (c == 'n') c = '\n';
                    else if (c == 'r') c = '\r'; else if (c == 't') c = '\t';
                    else if (c != '"' && c != '\\' && c != '/') throw RepairRefusal();
                }
                if (highSurrogate) { if (!char.IsLowSurrogate(c)) throw RepairRefusal(); highSurrogate = false; }
                else if (char.IsLowSurrogate(c)) throw RepairRefusal();
                else highSurrogate = char.IsHighSurrogate(c);
                if (capture) { if (value.Length >= 4096) throw RepairRefusal(); value.Append(c); }
            }
            throw RepairRefusal();
        }
    }
}
