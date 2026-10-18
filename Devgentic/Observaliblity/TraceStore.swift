// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TraceStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import GRDB
import os

/// A GRDB-backed SQLite store for persistent trace, span, and event data.
/// Runs in its own `.sqlite` file, fully isolated from the main Core Data store.
final class TraceStore: Sendable {

    // MARK: - Shared singleton

    /// Process-wide singleton shared by the observability actors (TraceRecorder, LogRecorder, MetricsAggregator).
    /// One SQLite connection pool means migrations run once and WAL concurrency works. Nil on init failure; callers
    /// handle it.
    static let shared: TraceStore? = {
        do {
            return try TraceStore()
        } catch {
            // `os.Logger` is unavailable here, so `print` is the last resort; an init failure must never crash the app.
            print("⚠️ TraceStore.shared init failed: \(error.localizedDescription). Observability disabled.")
            return nil
        }
    }()

    private let dbPool: DatabasePool
    /// Absolute path to the SQLite file backing `dbPool`. Stored so disk-size reporting
    /// can also stat the `-wal`/`-shm` sidecars. Points at the standard Application
    /// Support location for the production store, or a unique temp file for `inMemory`.
    private let dbPath: String
    private let logger = Logger(subsystem: DGLogger.subsystem, category: "TraceStore")

    // MARK: - Initialization
    
    // Why: a test run launches the real app, whose launch sweep purges the store `TraceStore.shared` opened;
    // without a redirect that is the developer's real traces.sqlite.
    /// Environment variable that redirects the trace store away from Application Support.
    /// Debug builds only.
    static let storePathOverrideEnvKey = "DEVGENTIC_TRACE_STORE_PATH"

    /// Resolves where `init()` opens the store.
    /// Debug order: explicit env override, XCTest-detected temp path, Application Support. Release builds always use
    /// Application Support.
    static func resolveStoreDirectoryAndPath() throws -> (directory: URL, path: String) {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[storePathOverrideEnvKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return (url.deletingLastPathComponent(), url.path)
        }
        if TestHost.isRunning {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("devgentic-tracestore-testhost", isDirectory: true)
            // One path per PROCESS, not per call: TraceStore.shared and any directly-constructed
            // store in the same test process see the same file, matching production topology.
            let path = dir.appendingPathComponent("traces-\(ProcessInfo.processInfo.processIdentifier).sqlite").path
            return (dir, path)
        }
        #endif
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupportURL.appendingPathComponent("Devgentic", isDirectory: true)
        return (dir, dir.appendingPathComponent("traces.sqlite").path)
    }

    /// Opens (or creates) the trace database at the standard Application Support location
    /// (or the DEBUG-only test redirect — see `resolveStoreDirectoryAndPath`).
    init() throws {
        let fileManager = FileManager.default
        let (dbDirectory, dbPath) = try Self.resolveStoreDirectoryAndPath()

        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        
        var config = Configuration()
        config.prepareDatabase { db in
            // Enable WAL mode for better concurrent read/write performance
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            // Enable foreign keys
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        
        dbPool = try DatabasePool(path: dbPath, configuration: config)
        self.dbPath = dbPath

        try migrator.migrate(dbPool)

        logger.info("TraceStore initialized at: \(dbPath)")
        #if DEBUG
        if TestHost.isRunning,
           ProcessInfo.processInfo.environment[Self.storePathOverrideEnvKey] == nil {
            // This process records telemetry into a throwaway file, so the launch sweep never touches the real traces.sqlite.
            logger.info("[TRACESTORE] XCTest detected with no explicit override — store redirected to \(dbPath); the real Application Support traces.sqlite is untouched by this process.")
        }
        #endif
    }

    /// Absolute path of the SQLite file this store opened. Read-only; exists so tests can
    /// assert the DEBUG redirect actually fired and Settings can surface the location.
    var storagePath: String { dbPath }

    // MARK: - Live observation

    /// A compact fingerprint of everything the Run Report renders for one trace.
    /// Any write that should repaint the report changes this string; the observation
    /// below emits only when it changes.
    struct RunFingerprint: Equatable, Sendable {
        let eventCount: Int
        let spanCount: Int
        let closedSpanCount: Int
        let traceStatus: String?
    }

    /// GRDB `ValueObservation` stream for the Run Report's live view; the panel reloads on each emission.
    /// `removeDuplicates` on the fingerprint filters out writes from other traces, since the tracked region is
    /// table-level.
    func observeRun(traceID: String) -> AsyncValueObservation<RunFingerprint> {
        ValueObservation
            .tracking { db -> RunFingerprint in
                RunFingerprint(
                    eventCount: try SpanEvent.filter(SpanEvent.Columns.traceID == traceID).fetchCount(db),
                    spanCount: try Span.filter(Span.Columns.traceID == traceID).fetchCount(db),
                    closedSpanCount: try Span.filter(Span.Columns.traceID == traceID && Span.Columns.endedAt != nil).fetchCount(db),
                    traceStatus: try String.fetchOne(db, sql: "SELECT status FROM traces WHERE traceID = ?", arguments: [traceID])
                )
            }
            .removeDuplicates()
            .values(in: dbPool)
    }
    
    /// Creates an ephemeral, isolated database for unit tests.
    /// Backed by a unique temp file rather than `:memory:`, because `DatabasePool` requires WAL, which in-memory
    /// databases cannot activate.
    init(inMemory: Bool) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("devgentic-tracestore-test-\(UUID().uuidString).sqlite")
            .path
        dbPool = try DatabasePool(path: tempPath, configuration: config)
        self.dbPath = tempPath
        try migrator.migrate(dbPool)
    }
    
    // MARK: - Schema fingerprint

    /// The live schema as sorted lines — every column, foreign key and index. What
    /// `TraceStoreBaselineSchemaTests` pins the squashed baseline against.
    func schemaFingerprint() throws -> [String] {
        try dbPool.read { db in
            var lines: [String] = []
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name
                """)
            for table in tables {
                for row in try Row.fetchAll(db, sql: #"SELECT name, type, "notnull", IFNULL(dflt_value, '') AS dflt, pk FROM pragma_table_info(?)"#, arguments: [table]) {
                    let name: String = row["name"], type: String = row["type"], dflt: String = row["dflt"]
                    let notNull: Int = row["notnull"], pk: Int = row["pk"]
                    lines.append("col \(table).\(name)|\(type)|\(notNull)|\(dflt)|\(pk)")
                }
                for row in try Row.fetchAll(db, sql: #"SELECT "from" AS f, "table" AS t, "to" AS c, on_delete AS d FROM pragma_foreign_key_list(?)"#, arguments: [table]) {
                    let from: String = row["f"], target: String = row["t"], column: String = row["c"], onDelete: String = row["d"]
                    lines.append("fk \(table).\(from)>\(target).\(column)|\(onDelete)")
                }
            }
            lines += try String.fetchAll(db, sql: "SELECT 'idx ' || sql FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL")
            return lines.sorted()
        }
    }

    // MARK: - Migrations

    // Why: the identifier stays `v1_create_tables` so databases that already applied it open unchanged.
    /// The single baseline schema migration.
    /// Add a new migration for any future schema change; never edit this one.
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            // -- traces --
            try db.create(table: "traces") { t in
                t.primaryKey("traceID", .text)
                t.column("conversationID", .text).notNull()
                t.column("messageID", .text).notNull()
                t.column("profileID", .text).notNull()
                t.column("profileName", .text).notNull()
                t.column("profileType", .text).notNull()
                t.column("provider", .text)
                t.column("modelName", .text)
                t.column("startedAt", .double).notNull()
                t.column("endedAt", .double)
                t.column("status", .text).notNull().defaults(to: "running")
                t.column("errorSummary", .text)
                t.column("metadataJSON", .text)
                t.column("appVersion", .text)
                t.column("buildNumber", .text)
                t.column("inputTokens", .integer)
                t.column("outputTokens", .integer)
                t.column("estimatedCostUSD", .double)
                t.column("tokensEstimated", .boolean)
            }
            try db.create(index: "idx_traces_conversation", on: "traces", columns: ["conversationID"])
            try db.create(index: "idx_traces_message", on: "traces", columns: ["messageID"])

            // -- spans --
            try db.create(table: "spans") { t in
                t.primaryKey("spanID", .text)
                t.column("traceID", .text).notNull()
                    .references("traces", column: "traceID", onDelete: .cascade)
                t.column("parentSpanID", .text)
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("startedAt", .double).notNull()
                t.column("endedAt", .double)
                t.column("status", .text).notNull().defaults(to: "running")
                t.column("metadataJSON", .text)
            }
            try db.create(index: "idx_spans_trace", on: "spans", columns: ["traceID"])
            try db.create(index: "idx_spans_parent", on: "spans", columns: ["parentSpanID"])

            // -- span_events --
            try db.create(table: "span_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("spanID", .text).notNull()
                    .references("spans", column: "spanID", onDelete: .cascade)
                t.column("traceID", .text).notNull()
                t.column("timestamp", .double).notNull()
                t.column("eventType", .text).notNull()
                t.column("content", .text)
                t.column("detailJSON", .text)
                t.column("severity", .text).defaults(to: "info")
                // AgentErrorCategory.rawValue — lets analytics GROUP BY category without parsing
                // detailJSON blobs. Written only in dev mode (TraceRecorder); reads work regardless.
                t.column("errorCategory", .text)
                // Shared by every event about the same underlying incident, so a propagation chain
                // collapses to one root cause via GROUP BY.
                t.column("errorChainID", .text)
                // ExecutionPhase.rawValue — indexed for "show me all .parsing failures".
                t.column("phase", .text)
                // ReAct iteration number; nil outside the cognitive loop.
                t.column("iterationNumber", .integer)
                // For future causal-chain links; nullable and unenforced.
                t.column("causedByEventID", .integer)
                // Intrinsic duration of the event, distinct from the span that wraps it.
                t.column("durationMs", .integer)
            }
            try db.create(index: "idx_events_span", on: "span_events", columns: ["spanID"])
            try db.create(index: "idx_events_trace", on: "span_events", columns: ["traceID"])
            try db.create(index: "idx_events_category", on: "span_events", columns: ["errorCategory"],
                          condition: Column("errorCategory") != nil)
            try db.create(index: "idx_events_chain", on: "span_events", columns: ["errorChainID"],
                          condition: Column("errorChainID") != nil)
            try db.create(index: "idx_events_phase", on: "span_events", columns: ["phase"],
                          condition: Column("phase") != nil)
            try db.create(index: "idx_events_timestamp", on: "span_events", columns: ["timestamp"])

            // -- trace_configs --
            try db.create(table: "trace_configs") { t in
                t.primaryKey("traceID", .text)
                    .references("traces", column: "traceID", onDelete: .cascade)
                t.column("provider", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("profileType", .text).notNull()
                t.column("appVersion", .text).notNull()
                t.column("osVersion", .text).notNull()
                t.column("toolsCount", .integer).notNull().defaults(to: 0)
                t.column("capabilitiesCount", .integer).notNull().defaults(to: 0)
                t.column("instructionsHash", .text)
                t.column("memoryBudgetBytes", .integer)
                t.column("historyStrategy", .text)
                t.column("thinkingEnabled", .boolean).notNull().defaults(to: false)
                t.column("snapshotJSON", .text).notNull()
            }
            try db.create(index: "idx_trace_configs_provider",     on: "trace_configs", columns: ["provider"])
            try db.create(index: "idx_trace_configs_model",        on: "trace_configs", columns: ["modelName"])
            try db.create(index: "idx_trace_configs_profile_type", on: "trace_configs", columns: ["profileType"])
            try db.create(index: "idx_trace_configs_app_version",  on: "trace_configs", columns: ["appVersion"])
            try db.create(index: "idx_trace_configs_instr_hash", on: "trace_configs", columns: ["instructionsHash"],
                          condition: Column("instructionsHash") != nil)

            // -- log_entries --
            try db.create(table: "log_entries") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .double).notNull()
                t.column("level", .text).notNull()
                t.column("subsystem", .text)
                t.column("category", .text)
                t.column("message", .text)
                t.column("traceID", .text)
                t.column("spanID", .text)
                t.column("phase", .text)
                t.column("metadataJSON", .text)
            }
            try db.create(index: "idx_logs_timestamp", on: "log_entries", columns: ["timestamp"])
            try db.create(index: "idx_logs_level",     on: "log_entries", columns: ["level"])
            try db.create(index: "idx_logs_trace", on: "log_entries", columns: ["traceID"],
                          condition: Column("traceID") != nil)

            // -- hitl_audit --
            try db.create(table: "hitl_audit") { t in
                t.primaryKey("operationID", .text)
                t.column("conversationID", .text).notNull()
                t.column("interface", .text).notNull()
                t.column("type", .text).notNull()
                t.column("toolName", .text)
                t.column("nodeName", .text)
                t.column("title", .text).notNull()
                t.column("raisedAt", .double).notNull()
                t.column("resolvedAt", .double)
                t.column("outcome", .text)
                t.column("traceID", .text)
                t.column("spanID", .text)
            }
            try db.create(index: "idx_hitl_audit_conversation", on: "hitl_audit", columns: ["conversationID"])
            try db.create(index: "idx_hitl_audit_raisedAt", on: "hitl_audit", columns: ["raisedAt"])
            try db.create(index: "idx_hitl_audit_trace", on: "hitl_audit", columns: ["traceID"],
                          condition: Column("traceID") != nil)
        }

        return migrator
    }

    // MARK: - HITL Audit (C2)

    /// Inserts the raise-time HITL audit row. Uses `.replace` so a re-raised operationID (the
    /// double-suspension safety path) overwrites rather than throwing on the primary key.
    func insertHITLAudit(_ record: HITLAuditRecord) throws {
        try dbPool.write { db in
            try record.insert(db, onConflict: .replace)
        }
    }

    /// Stamps an existing audit row with its resolution, guarded on `resolvedAt IS NULL` so a late duplicate cannot
    /// overwrite it.
    /// Returns rows changed (0 = the raise row has not landed yet, or it was already resolved), so callers can retry.
    @discardableResult
    func resolveHITLAudit(operationID: String, resolvedAt: Date, outcome: String) throws -> Int {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE hitl_audit SET resolvedAt = ?, outcome = ? WHERE operationID = ? AND resolvedAt IS NULL",
                arguments: [resolvedAt.timeIntervalSince1970, outcome, operationID]
            )
            return db.changesCount
        }
    }

    /// Launch reconcile: any row still pending (`resolvedAt IS NULL`) that was raised before this
    /// launch belongs to a previous session that quit/crashed mid-request — stamp it `interrupted`.
    @discardableResult
    func reconcileOrphanedHITL(before: Date, reason: String) throws -> Int {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE hitl_audit SET resolvedAt = ?, outcome = 'interrupted' WHERE resolvedAt IS NULL AND raisedAt < ?",
                arguments: [before.timeIntervalSince1970, before.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    /// Flips a resumed HITL's outcome from `interrupted` to `resumed`, guarded so only a launch-reconciled row is
    /// rewritten.
    /// Returns rows changed (0 = no matching interrupted row, e.g. it resolved before quit or was purged).
    @discardableResult
    func markHITLAuditResumed(operationID: String) throws -> Int {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE hitl_audit SET outcome = 'resumed' WHERE operationID = ? AND outcome = 'interrupted'",
                arguments: [operationID]
            )
            return db.changesCount
        }
    }

    /// 30-day retention prune, mirroring the trace/log purges.
    @discardableResult
    func purgeHITLAuditOlderThan(_ date: Date) throws -> Int {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM hitl_audit WHERE raisedAt < ?", arguments: [date.timeIntervalSince1970])
            return db.changesCount
        }
    }

    /// Audit rows for one conversation, newest first.
    func fetchHITLAudit(forConversationID conversationID: String) throws -> [HITLAuditRecord] {
        try dbPool.read { db in
            try HITLAuditRecord
                .filter(HITLAuditRecord.Columns.conversationID == conversationID)
                .order(HITLAuditRecord.Columns.raisedAt.desc)
                .fetchAll(db)
        }
    }

    /// Audit rows raised since a cutoff (for the diagnostic export / a future audit view), newest first.
    func fetchHITLAuditSince(_ since: Date, limit: Int = 10_000) throws -> [HITLAuditRecord] {
        try dbPool.read { db in
            try HITLAuditRecord
                .filter(HITLAuditRecord.Columns.raisedAt >= since.timeIntervalSince1970)
                .order(HITLAuditRecord.Columns.raisedAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Write Operations

    /// Inserts a new trace record.
    func insertTrace(_ trace: TraceRecord) throws {
        try dbPool.write { db in
            try trace.insert(db)
        }
    }

    /// Inserts or replaces a config snapshot for a trace; one row per trace, so a second call overwrites.
    /// Uses `save`, which updates on primary-key conflict.
    func saveConfigSnapshot(_ row: TraceConfigRow) throws {
        try dbPool.write { db in
            try row.save(db)
        }
    }

    /// Fetches the config snapshot for a trace, if one exists. Returns nil for traces
    /// that predate the v3 migration or where the snapshot capture was skipped (e.g.,
    /// dev-mode off path that never calls `captureConfigSnapshot`).
    func fetchConfigSnapshot(traceID: String) throws -> TraceConfigRow? {
        try dbPool.read { db in
            try TraceConfigRow.fetchOne(db, key: traceID)
        }
    }

    // MARK: - Log Entries (v4)

    /// Batch-inserts log entries in a single transaction; called from `LogRecorder` on threshold and periodic flushes.
    func insertLogEntries(_ entries: [LogEntry]) throws {
        guard !entries.isEmpty else { return }
        try dbPool.write { db in
            for entry in entries {
                var copy = entry
                try copy.insert(db)
            }
        }
    }

    /// Fetches persisted log entries for a time range, for the diagnostic export bundle and ReportInspector.
    /// `since` is inclusive, `minLevel` drops lower severities (nil = all), `limit` caps rows (default 10k).
    /// - Returns: entries in ascending timestamp order (oldest first).
    func fetchLogEntries(since: Date, minLevel: LogLevel? = nil, limit: Int = 10_000) throws -> [LogEntry] {
        try dbPool.read { db in
            // Compare as epoch seconds: a raw `Date` encodes as TEXT here and never matches the REAL column.
            var query = LogEntry.filter(LogEntry.Columns.timestamp >= since.timeIntervalSince1970)
            if let minLevel {
                // GRDB cannot compare strings by rank, so filter to the set of levels at or above `minLevel`.
                let allowed = LogLevel.allCases.filter { $0 >= minLevel }.map(\.rawValue)
                query = query.filter(allowed.contains(LogEntry.Columns.level))
            }
            // DESC plus limit, then reversed: ascending plus a cap would return the oldest rows and discard the newest.
            return try query
                .order(LogEntry.Columns.timestamp.desc)
                .limit(limit)
                .fetchAll(db)
                .reversed()
        }
    }

    /// Purges log entries older than the given date. Called from the 30-day
    /// purge job on app launch. Returns the number of rows deleted.
    @discardableResult
    func purgeLogEntriesOlderThan(_ date: Date) throws -> Int {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM log_entries WHERE timestamp < ?",
                arguments: [date.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    // MARK: - Metrics Aggregation Queries (Phase E)
    // All queries run live against the canonical trace, span_events and trace_configs tables; no pre-aggregation at
    // single-user scale.

    /// Per-tool reliability stats (success/failure counts, latency percentiles,
    /// failure-category breakdown). Uses the `toolResult` event type + dev-mode-populated
    /// `durationMs` / `errorCategory` columns.
    func toolReliabilityStats(since: Date, until: Date = Date(), profileType: String? = nil) throws -> [ToolReliabilityStats] {
        try dbPool.read { db in
            // The `profileType` filter scopes queries to traces of the chosen profile type; nil means no scope.
            let typeFilter = profileType.map { _ in
                "AND traceID IN (SELECT traceID FROM traces WHERE profileType = ?)"
            } ?? ""
            var baseArgs: [any DatabaseValueConvertible] = [since.timeIntervalSince1970, until.timeIntervalSince1970]
            if let profileType { baseArgs.append(profileType) }

            // Per-tool aggregate counts and average duration, grouped by the structured tool name, never by the display
            // `content` string.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    COALESCE(json_extract(detailJSON, '$.tool_name'), content) AS tool_name,
                    COUNT(*) AS total,
                    SUM(CASE WHEN severity = 'info' THEN 1 ELSE 0 END) AS success_count,
                    SUM(CASE WHEN severity = 'warning' THEN 1 ELSE 0 END) AS failure_count,
                    AVG(CASE WHEN durationMs IS NOT NULL THEN durationMs END) AS avg_duration
                FROM span_events
                WHERE eventType = 'toolResult'
                  AND timestamp >= ? AND timestamp <= ?
                  \(typeFilter)
                GROUP BY tool_name
                ORDER BY total DESC
                """, arguments: StatementArguments(baseArgs))

            var results: [ToolReliabilityStats] = []

            for row in rows {
                guard let toolName: String = row["tool_name"] else { continue }
                let total: Int = row["total"] ?? 0
                let successCount: Int = row["success_count"] ?? 0
                let failureCount: Int = row["failure_count"] ?? 0
                let avgDuration: Double? = row["avg_duration"]

                // 2. Percentiles — one extra pass per tool, ordered by duration.
                // For small windows (<1000 tool calls per tool) this is fast.
                var perToolArgs: [any DatabaseValueConvertible] = [toolName, since.timeIntervalSince1970, until.timeIntervalSince1970]
                if let profileType { perToolArgs.append(profileType) }
                let durations = try Int.fetchAll(db, sql: """
                    SELECT durationMs
                    FROM span_events
                    WHERE eventType = 'toolResult'
                      AND COALESCE(json_extract(detailJSON, '$.tool_name'), content) = ?
                      AND durationMs IS NOT NULL
                      AND timestamp >= ? AND timestamp <= ?
                      \(typeFilter)
                    ORDER BY durationMs ASC
                    """, arguments: StatementArguments(perToolArgs))

                let p50 = percentile(durations, 0.50)
                let p95 = percentile(durations, 0.95)

                // 3. Failure breakdown — categories assigned by emitToolResult +
                // any Phase D-migrated sites (permission, timeout, etc.).
                let breakdownRows = try Row.fetchAll(db, sql: """
                    SELECT errorCategory, COUNT(*) AS cnt
                    FROM span_events
                    WHERE eventType = 'toolResult'
                      AND COALESCE(json_extract(detailJSON, '$.tool_name'), content) = ?
                      AND severity = 'warning'
                      AND errorCategory IS NOT NULL
                      AND timestamp >= ? AND timestamp <= ?
                      \(typeFilter)
                    GROUP BY errorCategory
                    """, arguments: StatementArguments(perToolArgs))

                var breakdown: [AgentErrorCategory: Int] = [:]
                for br in breakdownRows {
                    guard let raw: String = br["errorCategory"],
                          let cat = AgentErrorCategory(rawValue: raw) else { continue }
                    breakdown[cat] = br["cnt"]
                }

                results.append(ToolReliabilityStats(
                    toolName: toolName,
                    totalCalls: total,
                    successCount: successCount,
                    failureCount: failureCount,
                    avgDurationMs: avgDuration.map { Int($0) },
                    p50DurationMs: p50,
                    p95DurationMs: p95,
                    failureBreakdown: breakdown
                ))
            }
            return results
        }
    }

    /// Per-category error and warning frequency.
    func categoryFrequencyStats(since: Date, until: Date = Date(), profileType: String? = nil) throws -> [CategoryFrequencyStats] {
        try dbPool.read { db in
            let typeFilter = profileType.map { _ in
                "AND traceID IN (SELECT traceID FROM traces WHERE profileType = ?)"
            } ?? ""
            var args: [any DatabaseValueConvertible] = [since.timeIntervalSince1970, until.timeIntervalSince1970]
            if let profileType { args.append(profileType) }

            let rows = try Row.fetchAll(db, sql: """
                SELECT errorCategory, COUNT(*) AS cnt
                FROM span_events
                WHERE errorCategory IS NOT NULL
                  AND timestamp >= ? AND timestamp <= ?
                  \(typeFilter)
                GROUP BY errorCategory
                ORDER BY cnt DESC
                """, arguments: StatementArguments(args))

            var results: [CategoryFrequencyStats] = []
            for row in rows {
                guard let raw: String = row["errorCategory"],
                      let cat = AgentErrorCategory(rawValue: raw) else { continue }
                results.append(CategoryFrequencyStats(category: cat, count: row["cnt"] ?? 0))
            }
            return results
        }
    }

    /// Per-(provider, model) outcome rates. Joins `traces` to `trace_configs` so we can
    /// split runs by the model actually used. Outcome classification reads from
    /// `traces.status` which is set at `endTrace(status:error:)`.
    func modelReliabilityStats(since: Date, until: Date = Date(), profileType: String? = nil) throws -> [ModelReliabilityStats] {
        try dbPool.read { db in
            let typeFilter = profileType.map { _ in "AND t.profileType = ?" } ?? ""
            var args: [any DatabaseValueConvertible] = [since.timeIntervalSince1970, until.timeIntervalSince1970]
            if let profileType { args.append(profileType) }

            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    tc.provider AS provider,
                    tc.modelName AS model_name,
                    COUNT(*) AS total,
                    SUM(CASE WHEN t.status = 'completed' THEN 1 ELSE 0 END) AS completed,
                    -- Degraded success is its own status as of 2026-07-19. Counted with
                    -- `completed` in successRate (it IS a success) but surfaced separately
                    -- so a model that keeps limping over the line is visible. Without this
                    -- bucket the new status would fall through every CASE and silently
                    -- deflate the success rate.
                    SUM(CASE WHEN t.status = 'completedWithWarnings' THEN 1 ELSE 0 END) AS completed_with_warnings,
                    SUM(CASE WHEN t.status IN ('error', 'failed') THEN 1 ELSE 0 END) AS failed,
                    SUM(CASE WHEN t.status = 'cancelled' THEN 1 ELSE 0 END) AS cancelled,
                    SUM(CASE WHEN t.status = 'interrupted' THEN 1 ELSE 0 END) AS interrupted,
                    AVG(CASE WHEN t.endedAt IS NOT NULL THEN (t.endedAt - t.startedAt) * 1000 END) AS avg_duration
                FROM trace_configs tc
                JOIN traces t ON t.traceID = tc.traceID
                WHERE t.startedAt >= ? AND t.startedAt <= ?
                  \(typeFilter)
                GROUP BY tc.provider, tc.modelName
                ORDER BY total DESC
                """, arguments: StatementArguments(args))

            return rows.compactMap { row in
                guard let provider: String = row["provider"],
                      let modelName: String = row["model_name"] else { return nil }
                let total: Int = row["total"] ?? 0
                let completed: Int = row["completed"] ?? 0
                let completedWithWarnings: Int = row["completed_with_warnings"] ?? 0
                let failed: Int = row["failed"] ?? 0
                let cancelled: Int = row["cancelled"] ?? 0
                let interrupted: Int = row["interrupted"] ?? 0
                let avgDuration: Double? = row["avg_duration"]
                return ModelReliabilityStats(
                    provider: provider,
                    modelName: modelName,
                    totalRuns: total,
                    completedCount: completed,
                    completedWithWarningsCount: completedWithWarnings,
                    failedCount: failed,
                    cancelledCount: cancelled,
                    // Quit or crash mid-run: not the model's fault, so excluded from the success-rate denominator.
                    interruptedCount: interrupted,
                    avgDurationMs: avgDuration.map { Int($0) }
                )
            }
        }
    }

    /// Circuit breaker trip summary — which safeguard fires most, which tools
    /// trigger it most. CB categories are the 5 `.cb*` cases in AgentErrorCategory.
    func circuitBreakerStatsAggregate(since: Date, until: Date = Date(), profileType: String? = nil) throws -> CircuitBreakerStats {
        try dbPool.read { db in
            let typeFilter = profileType.map { _ in
                "AND traceID IN (SELECT traceID FROM traces WHERE profileType = ?)"
            } ?? ""
            // CB trips by category.
            let cbCategoryRaws: [String] = AgentErrorCategory.allCases
                .filter { $0.rawValue.hasPrefix("cb") }
                .map(\.rawValue)

            // If we ever add non-cb categories starting with "cb", this filter breaks;
            // hardcode explicit list as defense-in-depth.
            let explicitCBs = [
                AgentErrorCategory.cbRepetitiveAction.rawValue,
                AgentErrorCategory.cbConsecutiveFail.rawValue,
                AgentErrorCategory.cbToolRetryLimit.rawValue,
                AgentErrorCategory.cbIdleLimit.rawValue,
                AgentErrorCategory.cbAskUserLimit.rawValue
            ]
            assert(Set(cbCategoryRaws) == Set(explicitCBs), "Phase E: update CB stats query if AgentErrorCategory cb* set changes")

            var categoryArgs: [any DatabaseValueConvertible] = [since.timeIntervalSince1970, until.timeIntervalSince1970]
            if let profileType { categoryArgs.append(profileType) }
            let categoryRows = try Row.fetchAll(db, sql: """
                SELECT errorCategory, COUNT(*) AS cnt
                FROM span_events
                WHERE errorCategory IN (\(cbCategoryRaws.map { "'\($0)'" }.joined(separator: ", ")))
                  AND timestamp >= ? AND timestamp <= ?
                  \(typeFilter)
                GROUP BY errorCategory
                """, arguments: StatementArguments(categoryArgs))

            var tripsByCategory: [AgentErrorCategory: Int] = [:]
            var total = 0
            for row in categoryRows {
                guard let raw: String = row["errorCategory"],
                      let cat = AgentErrorCategory(rawValue: raw) else { continue }
                let cnt: Int = row["cnt"] ?? 0
                tripsByCategory[cat] = cnt
                total += cnt
            }

            // Offending tools — parse `context.tool_name` out of detailJSON. Approximate
            // (LIKE on JSON substring) but cheap and deterministic enough for a dashboard.
            var toolArgs: [any DatabaseValueConvertible] = [since.timeIntervalSince1970, until.timeIntervalSince1970]
            if let profileType { toolArgs.append(profileType) }
            let toolRows = try Row.fetchAll(db, sql: """
                SELECT
                    SUBSTR(detailJSON, INSTR(detailJSON, '"tool_name":"') + 13, 64) AS raw,
                    COUNT(*) AS cnt
                FROM span_events
                WHERE errorCategory IN (\(cbCategoryRaws.map { "'\($0)'" }.joined(separator: ", ")))
                  AND detailJSON LIKE '%"tool_name":%'
                  AND timestamp >= ? AND timestamp <= ?
                  \(typeFilter)
                GROUP BY raw
                ORDER BY cnt DESC
                LIMIT 5
                """, arguments: StatementArguments(toolArgs))

            let topTools: [(tool: String, count: Int)] = toolRows.compactMap { row in
                guard let raw: String = row["raw"], let cnt: Int = row["cnt"] else { return nil }
                // Trim at the first closing quote.
                let name = raw.split(separator: "\"").first.map(String.init) ?? raw
                return (tool: name, count: cnt)
            }

            return CircuitBreakerStats(
                totalTrips: total,
                tripsByCategory: tripsByCategory,
                topOffendingTools: topTools,
                windowStart: since,
                windowEnd: until
            )
        }
    }

    /// Number of traces in the window. Cheap count — used as a header sanity signal
    /// in the dashboard ("X traces analyzed").
    func traceCount(since: Date, until: Date = Date(), profileType: String? = nil) throws -> Int {
        try dbPool.read { db in
            let typeFilter = profileType.map { _ in "AND profileType = ?" } ?? ""
            var args: [any DatabaseValueConvertible] = [since.timeIntervalSince1970, until.timeIntervalSince1970]
            if let profileType { args.append(profileType) }
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*)
                FROM traces
                WHERE startedAt >= ? AND startedAt <= ?
                  \(typeFilter)
                """, arguments: StatementArguments(args)) ?? 0
        }
    }

    /// Per-workflow-node execution stats, rolled up by node display name across `workflowNode` spans in the window.
    /// Duration comes from the span's end minus start; `profileType` additionally constrains via `traces`.
    func workflowNodeStats(since: Date, until: Date = Date(), profileType: String? = nil) throws -> [WorkflowNodeStats] {
        try dbPool.read { db in
            let typeFilter = profileType.map { _ in "AND traceID IN (SELECT traceID FROM traces WHERE profileType = ?)" } ?? ""
            var aggArgs: [any DatabaseValueConvertible] = [since.timeIntervalSince1970, until.timeIntervalSince1970]
            if let profileType { aggArgs.append(profileType) }

            // 1. Per-name aggregate.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    name,
                    COUNT(*) AS total,
                    -- [WF-OB6] The predicate here used to be
                    -- `status IN ('completed', 'completedWithWarnings')`, under a comment claiming
                    -- "spans share TraceStatus". They do not: this column is written only from
                    -- `SpanStatus` (`status.rawValue`, TraceStore.updateSpan), and `SpanStatus` has
                    -- no `completedWithWarnings` case — that value belongs to `TraceStatus`, on the
                    -- `traces` table. The second arm could never match a single row. Removed rather
                    -- than left as decoration, so the next reader does not infer a bucket that does
                    -- not exist.
                    SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) AS completed,
                    SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) AS failed,
                    -- [WF-OB6] Counted so `successRate` can EXCLUDE them from its denominator.
                    -- A Stop and a skip are not verdicts on the node: neither says it works or
                    -- that it is broken, so scoring either one against it is a category error.
                    SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END) AS cancelled,
                    SUM(CASE WHEN status = 'skipped' THEN 1 ELSE 0 END) AS skipped,
                    -- ⚠️ Counted for the same reason, and reachable the moment anyone opens the
                    -- Workflow Activity panel WHILE a workflow is running: the in-flight node's
                    -- span is still `running` and inside the window. `COUNT(*)` sweeps it into
                    -- `total`, and it is in none of the buckets above — so without subtracting it
                    -- too, a node currently executing scores exactly like one that failed. These
                    -- four buckets plus `running` are the complete `SpanStatus` set; the denominator
                    -- below is what makes that exhaustiveness matter.
                    SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END) AS running,
                    AVG(CASE WHEN endedAt IS NOT NULL THEN (endedAt - startedAt) * 1000 END) AS avg_duration
                FROM spans
                WHERE kind = 'workflowNode'
                  AND startedAt >= ? AND startedAt <= ?
                  \(typeFilter)
                GROUP BY name
                ORDER BY total DESC
                """, arguments: StatementArguments(aggArgs))

            var results: [WorkflowNodeStats] = []
            for row in rows {
                guard let name: String = row["name"] else { continue }
                let total: Int = row["total"] ?? 0
                let completed: Int = row["completed"] ?? 0
                let failed: Int = row["failed"] ?? 0
                let cancelled: Int = row["cancelled"] ?? 0
                let skipped: Int = row["skipped"] ?? 0
                let running: Int = row["running"] ?? 0
                let avgDuration: Double? = row["avg_duration"]

                // 2. Per-node-name percentiles — same approach as toolReliabilityStats.
                // Strip the `name = ?` prefix from typeFilter handling by keeping args local.
                var pctArgs: [any DatabaseValueConvertible] = [name, since.timeIntervalSince1970, until.timeIntervalSince1970]
                if let profileType { pctArgs.append(profileType) }
                let durations = try Int.fetchAll(db, sql: """
                    SELECT CAST((endedAt - startedAt) * 1000 AS INTEGER) AS duration_ms
                    FROM spans
                    WHERE kind = 'workflowNode'
                      AND name = ?
                      AND endedAt IS NOT NULL
                      AND startedAt >= ? AND startedAt <= ?
                      \(typeFilter)
                    ORDER BY duration_ms ASC
                    """, arguments: StatementArguments(pctArgs))

                results.append(WorkflowNodeStats(
                    nodeName: name,
                    totalRuns: total,
                    completedCount: completed,
                    failedCount: failed,
                    cancelledCount: cancelled,
                    skippedCount: skipped,
                    runningCount: running,
                    avgDurationMs: avgDuration.map { Int($0) },
                    p50DurationMs: percentile(durations, 0.50),
                    p95DurationMs: percentile(durations, 0.95)
                ))
            }
            return results
        }
    }

    /// Linear-interpolation percentile of a sorted integer array. Returns nil for
    /// empty input. For dashboard presentation — don't use for high-precision analytics.
    private func percentile(_ sorted: [Int], _ p: Double) -> Int? {
        guard !sorted.isEmpty else { return nil }
        if sorted.count == 1 { return sorted[0] }
        let idx = Double(sorted.count - 1) * p
        let low = Int(idx.rounded(.down))
        let high = Int(idx.rounded(.up))
        if low == high { return sorted[low] }
        let fraction = idx - Double(low)
        return Int(Double(sorted[low]) * (1 - fraction) + Double(sorted[high]) * fraction)
    }

    /// Inserts a new span.
    func insertSpan(_ span: Span) throws {
        try dbPool.write { db in
            try span.insert(db)
        }
    }

    /// Inserts the span if no row has its `spanID`; otherwise refreshes `name` and `kind` and keeps lifecycle fields.
    /// Check and write share one transaction.
    /// - Returns: `true` if inserted, `false` if an existing row was refreshed.
    @discardableResult
    func ensureSpan(_ span: Span) throws -> Bool {
        try dbPool.write { db in
            let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM spans WHERE spanID = ?)",
                arguments: [span.spanID]
            ) ?? false
            guard !exists else {
                try db.execute(
                    sql: "UPDATE spans SET name = ?, kind = ? WHERE spanID = ?",
                    arguments: [span.name, span.kind, span.spanID]
                )
                return false
            }
            try span.insert(db)
            return true
        }
    }
    
    /// Inserts a batch of span events in a single transaction.
    func insertEvents(_ events: [SpanEvent]) throws {
        guard !events.isEmpty else { return }
        try dbPool.write { db in
            for event in events {
                try event.insert(db)
            }
        }
    }
    
    // Why: a late real end must be able to correct a trace-end clamp in either arrival order,
    // while a replay or later clamp stays a no-op.
    /// Updates an existing span; the earliest end wins: an open span always writes, a closed one only for a strictly
    /// earlier end.
    /// `metadataJSON`, when non-nil, rides the same guarded write and never blanks existing metadata.
    func updateSpan(spanID: String, endedAt: Date, status: SpanStatus, metadataJSON: String? = nil) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE spans SET endedAt = ?, status = ?, metadataJSON = COALESCE(?, metadataJSON) WHERE spanID = ? AND (endedAt IS NULL OR endedAt > ?)",
                arguments: [endedAt.timeIntervalSince1970, status.rawValue, metadataJSON, spanID, endedAt.timeIntervalSince1970]
            )
        }
    }

    /// Persists per-trace token totals + cost rollup (observability D1). Called once at
    /// trace end with the run's accumulated usage.
    func updateTraceTokens(traceID: String, inputTokens: Int, outputTokens: Int, estimatedCostUSD: Double?, estimated: Bool) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE traces SET inputTokens = ?, outputTokens = ?, estimatedCostUSD = ?, tokensEstimated = ? WHERE traceID = ?",
                arguments: [inputTokens, outputTokens, estimatedCostUSD, estimated, traceID]
            )
        }
    }

    /// Updates an existing trace record on completion/error.
    func updateTrace(traceID: String, endedAt: Date, status: TraceStatus, errorSummary: String? = nil) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE traces SET endedAt = ?, status = ?, errorSummary = ? WHERE traceID = ?",
                arguments: [endedAt.timeIntervalSince1970, status.rawValue, errorSummary, traceID]
            )
        }
    }
    
    // MARK: - Read Operations
    
    /// Fetches a single trace record by its ID.
    func fetchTrace(traceID: String) throws -> TraceRecord? {
        try dbPool.read { db in
            try TraceRecord.fetchOne(db, key: traceID)
        }
    }
    
    /// Fetches the trace for a message; a regenerated or resumed message can own several, so the newest attempt wins.
    func fetchTrace(forMessageID messageID: String) throws -> TraceRecord? {
        try dbPool.read { db in
            try TraceRecord
                .filter(TraceRecord.Columns.messageID == messageID)
                .order(TraceRecord.Columns.startedAt.desc)
                .fetchOne(db)
        }
    }
    
    /// Fetches all trace records for a conversation, ordered by start time.
    func fetchTraces(forConversationID conversationID: String) throws -> [TraceRecord] {
        try dbPool.read { db in
            try TraceRecord
                .filter(TraceRecord.Columns.conversationID == conversationID)
                .order(TraceRecord.Columns.startedAt.asc)
                .fetchAll(db)
        }
    }

    /// Fetches all traces whose start time is within the window. Used by the
    /// diagnostic bundle's `.recent(hours:)` scope to pull a time-bounded slice
    /// across all conversations.
    func fetchTracesSince(_ since: Date) throws -> [TraceRecord] {
        try dbPool.read { db in
            try TraceRecord
                .filter(TraceRecord.Columns.startedAt >= since.timeIntervalSince1970)
                .order(TraceRecord.Columns.startedAt.asc)
                .fetchAll(db)
        }
    }
    
    /// Fetches all spans for a trace, ordered by start time.
    func fetchSpans(forTraceID traceID: String) throws -> [Span] {
        try dbPool.read { db in
            try Span
                .filter(Span.Columns.traceID == traceID)
                .order(Span.Columns.startedAt.asc)
                .fetchAll(db)
        }
    }
    
    /// Fetches all events for a specific span, ordered by timestamp.
    func fetchEvents(forSpanID spanID: String) throws -> [SpanEvent] {
        try dbPool.read { db in
            try SpanEvent
                .filter(SpanEvent.Columns.spanID == spanID)
                .order(SpanEvent.Columns.timestamp.asc)
                .fetchAll(db)
        }
    }
    
    /// Fetches all events for an entire trace, ordered by timestamp.
    func fetchEvents(forTraceID traceID: String) throws -> [SpanEvent] {
        try dbPool.read { db in
            try SpanEvent
                .filter(SpanEvent.Columns.traceID == traceID)
                .order(SpanEvent.Columns.timestamp.asc)
                .fetchAll(db)
        }
    }
    
    /// Fetches a fully-hydrated trace with its span tree and events.
    func fetchFullTrace(traceID: String) throws -> TraceRecord? {
        guard var trace = try fetchTrace(traceID: traceID) else { return nil }
        
        let allSpans = try fetchSpans(forTraceID: traceID)
        let allEvents = try fetchEvents(forTraceID: traceID)
        
        // Group events by spanID
        let eventsBySpan = Dictionary(grouping: allEvents, by: { $0.spanID })
        
        // Hydrate each span with its events
        var hydratedSpans = allSpans.map { span -> Span in
            var s = span
            s.events = eventsBySpan[span.spanID] ?? []
            return s
        }
        
        // Build tree: assign children to parents
        let childrenByParent = Dictionary(grouping: hydratedSpans, by: { $0.parentSpanID ?? "" })
        
        hydratedSpans = hydratedSpans.map { span in
            var s = span
            s.children = childrenByParent[span.spanID]
            return s
        }
        
        // Root spans: those without a parent
        trace.rootSpans = hydratedSpans.filter { $0.parentSpanID == nil }
        
        // Also hydrate root span children recursively
        func attachChildren(to span: inout Span) {
            if let kids = childrenByParent[span.spanID] {
                span.children = kids.map { child in
                    var c = child
                    c.events = eventsBySpan[c.spanID] ?? []
                    attachChildren(to: &c)
                    return c
                }
            }
        }
        
        trace.rootSpans = trace.rootSpans?.map { root in
            var r = root
            attachChildren(to: &r)
            return r
        }
        
        return trace
    }
    
    /// Computes a summary from all events in a trace.
    func computeSummary(forTraceID traceID: String) throws -> TraceSummary {
        let events = try fetchEvents(forTraceID: traceID)
        let trace = try fetchTrace(traceID: traceID)
        
        var summary = TraceSummary()
        
        for event in events {
            switch event.eventType {
            case .llmRequest:
                summary.totalLLMCalls += 1
            case .toolCall:
                summary.totalToolCalls += 1
            case .parseError:
                summary.parseErrors += 1
            case .userInteraction:
                summary.userInteractions += 1
            default:
                break
            }
        }
        
        // Count iterations from spans
        let spans = try fetchSpans(forTraceID: traceID)
        summary.totalIterations = spans.filter { $0.kind == .iteration }.count
        
        if let durationMs = trace?.durationMs {
            summary.totalDurationMs = durationMs
        }
        
        return summary
    }
    
    // MARK: - Maintenance
    
    /// Deletes all traces for a conversation (cascading to spans, events, configs) plus its log entries.
    /// `log_entries.traceID` has no foreign key, so the log rows are deleted explicitly.
    func deleteTraces(forConversationID conversationID: String) throws {
        try dbPool.write { db in
            // Logs first — the subquery needs the trace rows to still exist.
            try db.execute(
                sql: "DELETE FROM log_entries WHERE traceID IN (SELECT traceID FROM traces WHERE conversationID = ?)",
                arguments: [conversationID]
            )
            try db.execute(sql: "DELETE FROM traces WHERE conversationID = ?", arguments: [conversationID])
            // `hitl_audit` has no FK so it survives trace purges, but deleting a conversation also removes its approval
            // history.
            try db.execute(sql: "DELETE FROM hitl_audit WHERE conversationID = ?", arguments: [conversationID])
        }
    }

    /// Purges all traces older than the given date.
    func purgeOlderThan(_ date: Date) throws {
        try dbPool.write { db in
            // Cascade deletes will remove associated spans and events
            try db.execute(
                sql: "DELETE FROM traces WHERE startedAt < ?",
                arguments: [date.timeIntervalSince1970]
            )
        }
    }
    
    /// Returns the total number of stored traces (for diagnostics).
    func traceCount() throws -> Int {
        try dbPool.read { db in
            try TraceRecord.fetchCount(db)
        }
    }

    /// Closes spans still open for a trace, stamping the given end time and status.
    /// Used by `endTrace` for the root span and by orphan reconciliation for spans abandoned by a dead process.
    func closeOpenSpans(traceID: String, endedAt: Date, status: SpanStatus) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE spans SET endedAt = ?, status = ? WHERE traceID = ? AND endedAt IS NULL",
                arguments: [endedAt.timeIntervalSince1970, status.rawValue, traceID]
            )
        }
    }

    /// Reconciles traces left `running` by a previous process to `.interrupted` and closes their open spans.
    /// `before` must be captured at launch before any trace is created, so a live trace is never touched. Returns the
    /// count reconciled.
    @discardableResult
    func reconcileOrphanedTraces(before: Date, reason: String, now: Date = Date()) throws -> Int {
        try dbPool.write { db in
            // Close the orphans' still-open spans first (root + any leaked iteration spans).
            try db.execute(
                sql: """
                    UPDATE spans SET endedAt = ?, status = 'error'
                    WHERE endedAt IS NULL AND traceID IN (
                        SELECT traceID FROM traces WHERE status = 'running' AND startedAt < ?
                    )
                    """,
                arguments: [now.timeIntervalSince1970, before.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                    UPDATE traces SET endedAt = ?, status = 'interrupted',
                        errorSummary = COALESCE(errorSummary, ?)
                    WHERE status = 'running' AND startedAt < ?
                    """,
                arguments: [now.timeIntervalSince1970, reason, before.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    /// Total on-disk footprint of the trace database, including the WAL and shared-memory
    /// sidecars (which can dwarf the main file between checkpoints). For surfacing in
    /// Settings so users can see what diagnostics cost on disk.
    func databaseFileSizeBytes() -> Int64 {
        let fm = FileManager.default
        return [dbPath, dbPath + "-wal", dbPath + "-shm"].reduce(Int64(0)) { total, path in
            let attrs = try? fm.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }
}
