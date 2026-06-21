//
//  TraceStore.swift
//  Devgentic
//
//  Created by Antigravity on 19/03/26.
//

import Foundation
import GRDB
import os

/// A GRDB-backed SQLite store for persistent trace, span, and event data.
/// Runs in its own `.sqlite` file, fully isolated from the main Core Data store.
final class TraceStore: Sendable {

    // MARK: - Shared singleton

    /// Process-wide singleton. Multiple observability actors (TraceRecorder,
    /// LogRecorder, MetricsAggregator) share this single SQLite connection pool
    /// so migrations run exactly once and WAL concurrency works as expected.
    /// Returns nil on init failure — callers must handle the nil case gracefully
    /// (they all do, via `guard let store else { return }`).
    static let shared: TraceStore? = {
        do {
            return try TraceStore()
        } catch {
            // Can't use os.Logger directly here — use print as last resort.
            // A TraceStore init failure is catastrophic for observability but
            // must never crash the app.
            print("⚠️ TraceStore.shared init failed: \(error.localizedDescription). Observability disabled.")
            return nil
        }
    }()

    private let dbPool: DatabasePool
    /// Absolute path to the SQLite file backing `dbPool`. Stored so disk-size reporting
    /// can also stat the `-wal`/`-shm` sidecars. Points at the standard Application
    /// Support location for the production store, or a unique temp file for `inMemory`.
    private let dbPath: String
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic", category: "TraceStore")

    // MARK: - Initialization
    
    /// Opens (or creates) the trace database at the standard Application Support location.
    init() throws {
        let fileManager = FileManager.default
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbDirectory = appSupportURL.appendingPathComponent("Devgentic", isDirectory: true)
        
        try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)
        
        let dbPath = dbDirectory.appendingPathComponent("traces.sqlite").path
        
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
    }
    
    /// For unit testing: create an ephemeral, isolated database.
    /// Backed by a unique temp file rather than `:memory:` — `DatabasePool`
    /// requires WAL journaling, which SQLite cannot activate on an in-memory
    /// database ("SQLite error 1: could not activate WAL Mode at path: :memory:").
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
    
    // MARK: - Migrations
    
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        
        // v1: Initial schema
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
            }
            
            try db.create(index: "idx_events_span", on: "span_events", columns: ["spanID"])
            try db.create(index: "idx_events_trace", on: "span_events", columns: ["traceID"])
        }

        // v2: Observability expansion — richer span-event columns for the canonical
        // error taxonomy. All columns nullable so legacy rows continue to load.
        // Writes to these columns are dev-mode-gated in TraceRecorder; reads work
        // regardless. This migration is safe to run on databases already populated
        // with v1 data.
        migrator.registerMigration("v2_expand_span_events") { db in
            try db.alter(table: "span_events") { t in
                // AgentErrorCategory.rawValue — lets analytics GROUP BY category
                // without parsing detailJSON blobs.
                t.add(column: "errorCategory", .text)
                // UUID shared across every SpanEvent emitted about the same underlying
                // incident, so propagation chains collapse to a single "root cause"
                // via GROUP BY. Populated only when a ClassifiedAgentError is being
                // emitted (other event types pass nil).
                t.add(column: "errorChainID", .text)
                // ExecutionPhase.rawValue — redundant with category.phase but indexed
                // for fast dashboard queries ("show me all .parsing failures").
                t.add(column: "phase", .text)
                // ReAct iteration number. Nil for events outside the cognitive loop.
                t.add(column: "iterationNumber", .integer)
                // For future causal-chain links — points at the event that triggered this
                // one. Nullable FK; not enforced to keep propagation ordering flexible.
                t.add(column: "causedByEventID", .integer)
                // Intrinsic duration of the event (e.g., LLM response time, tool latency).
                // Distinct from span.endedAt - span.startedAt (which wraps the operation).
                t.add(column: "durationMs", .integer)
            }

            // Indices for the dashboard queries we expect to hammer:
            //  - "show all errors of category X" (`idx_events_category`)
            //  - "collapse this trace to N root causes" (`idx_events_chain`)
            //  - "latency distribution for phase=tooling" (`idx_events_phase`)
            try db.create(index: "idx_events_category",
                          on: "span_events",
                          columns: ["errorCategory"],
                          condition: Column("errorCategory") != nil)
            try db.create(index: "idx_events_chain",
                          on: "span_events",
                          columns: ["errorChainID"],
                          condition: Column("errorChainID") != nil)
            try db.create(index: "idx_events_phase",
                          on: "span_events",
                          columns: ["phase"],
                          condition: Column("phase") != nil)
        }

        // v3: Per-trace configuration snapshot — one row per trace capturing the full
        // effective request config (profile, model, tools, capabilities, retry policy,
        // memory budget, hardware, feature flags). The #1 thing missing for offline
        // bug reproduction.
        //
        // Indexed columns support common dashboard queries (GROUP BY provider, model,
        // app version). The full TraceConfigSnapshot lives in `snapshotJSON`, so new
        // non-indexed fields can be added without schema changes.
        migrator.registerMigration("v3_create_trace_configs") { db in
            try db.create(table: "trace_configs") { t in
                t.primaryKey("traceID", .text)
                    .references("traces", column: "traceID", onDelete: .cascade)

                // Indexed identity / environment columns.
                t.column("provider", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("profileType", .text).notNull()
                t.column("appVersion", .text).notNull()
                t.column("osVersion", .text).notNull()

                // Indexed config-summary columns.
                t.column("toolsCount", .integer).notNull().defaults(to: 0)
                t.column("capabilitiesCount", .integer).notNull().defaults(to: 0)
                t.column("instructionsHash", .text)
                t.column("memoryBudgetBytes", .integer)
                t.column("historyStrategy", .text)
                t.column("thinkingEnabled", .boolean).notNull().defaults(to: false)

                // Full sanitized snapshot. Extensible without schema changes.
                t.column("snapshotJSON", .text).notNull()
            }

            try db.create(index: "idx_trace_configs_provider",     on: "trace_configs", columns: ["provider"])
            try db.create(index: "idx_trace_configs_model",        on: "trace_configs", columns: ["modelName"])
            try db.create(index: "idx_trace_configs_profile_type", on: "trace_configs", columns: ["profileType"])
            try db.create(index: "idx_trace_configs_app_version",  on: "trace_configs", columns: ["appVersion"])
            try db.create(index: "idx_trace_configs_instr_hash",
                          on: "trace_configs",
                          columns: ["instructionsHash"],
                          condition: Column("instructionsHash") != nil)
        }

        // v4: In-app log ring buffer persistence. DGLogger calls the LogRecorder
        // actor, which periodically flushes its in-memory buffer into this table.
        // Enables the "last N hours of logs" panel in diagnostic export bundles —
        // previously impossible because os.Logger only writes to the system log.
        //
        // Indexed on timestamp (for time-range queries), level (for severity
        // filters), and traceID (for correlating logs to a specific run).
        migrator.registerMigration("v4_create_log_entries") { db in
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
            try db.create(index: "idx_logs_trace",
                          on: "log_entries",
                          columns: ["traceID"],
                          condition: Column("traceID") != nil)
        }

        // v5: release attribution + token accounting + the missing span-events timestamp
        // index. All additive/nullable — safe on populated v1–v4 databases.
        migrator.registerMigration("v5_version_tokens_event_index") { db in
            try db.alter(table: "traces") { t in
                // §12.3 — build attribution on the trace itself. Config snapshots are
                // captured only on the chat path, so headless/scheduler/sub-agent traces
                // had no version anchor; these are stamped in `beginTrace`.
                t.add(column: "appVersion", .text)
                t.add(column: "buildNumber", .text)
                // D1 — per-trace token totals + cost rollup, set at `endTrace`.
                t.add(column: "inputTokens", .integer)
                t.add(column: "outputTokens", .integer)
                t.add(column: "estimatedCostUSD", .double)
                t.add(column: "tokensEstimated", .boolean)
            }
            // #17 — span_events is filtered by timestamp in every metrics query but had no
            // index (v4 added one only for log_entries).
            try db.create(index: "idx_events_timestamp", on: "span_events", columns: ["timestamp"])
        }

        // v6: normalize legacy TEXT dates. Rows written before the GRDB date-strategy fix
        // stored "YYYY-MM-DD HH:MM:SS.SSS" TEXT in these REAL columns. SQLite sorts TEXT
        // above REAL, so such rows were IMMORTAL — `startedAt < cutoff` (purge, reconcile)
        // never matched, while `startedAt >= since` (recent-bundle windows) ALWAYS matched,
        // surfacing 1970-decoded garbage forever (audit #7). Convert parseable values to
        // epoch seconds; drop the unsalvageable rest.
        migrator.registerMigration("v6_normalize_legacy_text_dates") { db in
            let targets: [(table: String, column: String, nullable: Bool)] = [
                ("traces", "startedAt", false), ("traces", "endedAt", true),
                ("spans", "startedAt", false), ("spans", "endedAt", true),
                ("span_events", "timestamp", false),
                ("log_entries", "timestamp", false)
            ]
            for t in targets {
                try db.execute(sql: """
                    UPDATE \(t.table) SET \(t.column) = CAST(strftime('%s', \(t.column)) AS REAL)
                    WHERE typeof(\(t.column)) = 'text' AND strftime('%s', \(t.column)) IS NOT NULL
                    """)
                if t.nullable {
                    try db.execute(sql: "UPDATE \(t.table) SET \(t.column) = NULL WHERE typeof(\(t.column)) = 'text'")
                }
            }
            // Unparseable text in NOT NULL date columns = unsalvageable garbage rows.
            try db.execute(sql: "DELETE FROM traces WHERE typeof(startedAt) = 'text'")   // cascades
            try db.execute(sql: "DELETE FROM spans WHERE typeof(startedAt) = 'text'")    // cascades events
            try db.execute(sql: "DELETE FROM span_events WHERE typeof(timestamp) = 'text'")
            try db.execute(sql: "DELETE FROM log_entries WHERE typeof(timestamp) = 'text'")
        }

        return migrator
    }

    // MARK: - Write Operations

    /// Inserts a new trace record.
    func insertTrace(_ trace: TraceRecord) throws {
        try dbPool.write { db in
            try trace.insert(db)
        }
    }

    /// Inserts or replaces a config snapshot for a trace. One row per trace — if
    /// `captureConfigSnapshot` is ever called twice with the same traceID (shouldn't
    /// happen in practice), the second call overwrites. `insert` with
    /// `.replace` conflict policy isn't available here, so we use `save` which falls
    /// back to update-on-primary-key-conflict.
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

    /// Batch-inserts log entries in a single transaction. Called from `LogRecorder`
    /// on threshold and periodic flushes. Using `insertedCopy` so auto-assigned
    /// IDs can be read back if callers care (we don't, currently — caller drops
    /// the entries post-insert).
    func insertLogEntries(_ entries: [LogEntry]) throws {
        guard !entries.isEmpty else { return }
        try dbPool.write { db in
            for entry in entries {
                var copy = entry
                try copy.insert(db)
            }
        }
    }

    /// Fetches persisted log entries for a time range. Primarily consumed by the
    /// diagnostic export bundle and ReportInspector.
    /// - Parameters:
    ///   - since: lower-bound timestamp (inclusive)
    ///   - minLevel: drop entries below this severity (nil = all levels)
    ///   - limit: row cap (default 10k, tune via `LogRecorder.persistedRecent`)
    /// - Returns: entries in ascending timestamp order (oldest first).
    func fetchLogEntries(since: Date, minLevel: LogLevel? = nil, limit: Int = 10_000) throws -> [LogEntry] {
        try dbPool.read { db in
            // Compare as epoch seconds: a raw `Date` in a query-interface expression encodes
            // as a TEXT datetime (the record-level date strategy does NOT apply here), and
            // TEXT never matches the REAL column — the filter silently returned nothing.
            var query = LogEntry.filter(LogEntry.Columns.timestamp >= since.timeIntervalSince1970)
            if let minLevel {
                // Level comparison: include entries whose LogLevel ordinal is >= minLevel.
                // GRDB can't compare strings by rank natively, so we filter to the set
                // of levels that satisfy the criterion.
                let allowed = LogLevel.allCases.filter { $0 >= minLevel }.map(\.rawValue)
                query = query.filter(allowed.contains(LogEntry.Columns.level))
            }
            return try query
                .order(LogEntry.Columns.timestamp.asc)
                .limit(limit)
                .fetchAll(db)
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
    //
    // All queries operate on the canonical trace + span_events + trace_configs tables.
    // No separate pre-aggregation: at single-user scale (30-day retention) live queries
    // run in single-digit ms against the indexed columns we added in v2/v3/v4.
    // If profiling ever shows slowdowns, add rolling-counter tables here without
    // changing the MetricsAggregator / TrendsView API above.

    /// Per-tool reliability stats (success/failure counts, latency percentiles,
    /// failure-category breakdown). Uses the `toolResult` event type + dev-mode-populated
    /// `durationMs` / `errorCategory` columns.
    func toolReliabilityStats(since: Date, until: Date = Date(), profileType: String? = nil) throws -> [ToolReliabilityStats] {
        try dbPool.read { db in
            // P1-15 profileType filter: scope to the subset of traces matching the
            // user's chosen profile type (Bot / Agent / Workflow / Code / ImageGen)
            // by constraining `traceID IN (matching traces)`. Nil filter = no scope,
            // queries behave as before.
            let typeFilter = profileType.map { _ in
                "AND traceID IN (SELECT traceID FROM traces WHERE profileType = ?)"
            } ?? ""
            var baseArgs: [any DatabaseValueConvertible] = [since.timeIntervalSince1970, until.timeIntervalSince1970]
            if let profileType { baseArgs.append(profileType) }

            // 1. Per-tool aggregate counts + avg duration.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    content AS tool_name,
                    COUNT(*) AS total,
                    SUM(CASE WHEN severity = 'info' THEN 1 ELSE 0 END) AS success_count,
                    SUM(CASE WHEN severity = 'warning' THEN 1 ELSE 0 END) AS failure_count,
                    AVG(CASE WHEN durationMs IS NOT NULL THEN durationMs END) AS avg_duration
                FROM span_events
                WHERE eventType = 'toolResult'
                  AND timestamp >= ? AND timestamp <= ?
                  \(typeFilter)
                GROUP BY content
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
                      AND content = ?
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
                      AND content = ?
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

    /// Per-category error/warning frequency. Populated by Phase D sites + Phase 1 warnings.
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
                let failed: Int = row["failed"] ?? 0
                let cancelled: Int = row["cancelled"] ?? 0
                let interrupted: Int = row["interrupted"] ?? 0
                let avgDuration: Double? = row["avg_duration"]
                return ModelReliabilityStats(
                    provider: provider,
                    modelName: modelName,
                    totalRuns: total,
                    completedCount: completed,
                    failedCount: failed,
                    cancelledCount: cancelled,
                    // App-quit/crash mid-run — not the model's fault; excluded from the
                    // success-rate denominator (audit #6). Any remaining leftover (total
                    // minus the four buckets) is still-running traces from THIS session.
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

    /// Per-workflow-node execution stats — rolled up by node display name across
    /// every `workflowNode`-kind span in the window. Duration comes from the
    /// span's `(endedAt - startedAt)` and status from the span's terminal state.
    /// Drives the "Workflow Activity" panel in TrendsView. Profile-type filter is
    /// implicit here (only `workflowNode` spans are queried, which only exist on
    /// workflow traces); the `profileType` argument is accepted for API
    /// consistency but additionally constrains via `traces` for safety.
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
                    SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) AS completed,
                    SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) AS failed,
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

    /// Inserts the span when no row with its `spanID` exists; when a row already
    /// exists, refreshes its descriptive identity (`name`, `kind`) while preserving
    /// its lifecycle fields (`startedAt`, `endedAt`, `status`, `metadataJSON`).
    /// Lets a later, better-informed caller (e.g. the workflow executor naming the
    /// root span `workflow:<id>`) improve on a generic placeholder (`beginTrace`'s
    /// auto-created "root") without clobbering timing or completion state.
    /// Check + write run in one transaction, so concurrent callers can't double-insert.
    /// - Returns: `true` if the span was inserted, `false` if an existing row was refreshed.
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
    
    /// Updates an existing span (e.g., setting endedAt, status). Only-if-open: spans end
    /// exactly once — late fire-and-forget `endSpan` tasks (defer blocks) must not re-stamp
    /// a span that `closeOpenSpans` already closed at trace end (audit #10).
    func updateSpan(spanID: String, endedAt: Date, status: SpanStatus) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE spans SET endedAt = ?, status = ? WHERE spanID = ? AND endedAt IS NULL",
                arguments: [endedAt.timeIntervalSince1970, status.rawValue, spanID]
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
    
    /// Fetches the trace record associated with a specific message.
    func fetchTrace(forMessageID messageID: String) throws -> TraceRecord? {
        try dbPool.read { db in
            try TraceRecord
                .filter(TraceRecord.Columns.messageID == messageID)
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
    
    /// Deletes all traces for a conversation (FK cascades to spans/events/configs), plus
    /// the conversation's log entries — `log_entries.traceID` has NO foreign key, so without
    /// the explicit DELETE those content-bearing rows would outlive the conversation by up
    /// to 30 days (audit #4). Called when the user deletes a conversation (§12.5).
    func deleteTraces(forConversationID conversationID: String) throws {
        try dbPool.write { db in
            // Logs first — the subquery needs the trace rows to still exist.
            try db.execute(
                sql: "DELETE FROM log_entries WHERE traceID IN (SELECT traceID FROM traces WHERE conversationID = ?)",
                arguments: [conversationID]
            )
            try db.execute(sql: "DELETE FROM traces WHERE conversationID = ?", arguments: [conversationID])
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

    /// Closes any spans still open (`endedAt IS NULL`) for a trace, stamping the given
    /// end time and status. Used by `endTrace` to close the root span (which no executor
    /// ends on the chat path) and by orphan reconciliation to close spans abandoned by a
    /// dead process — without this they linger `running` forever (Gap #13).
    func closeOpenSpans(traceID: String, endedAt: Date, status: SpanStatus) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE spans SET endedAt = ?, status = ? WHERE traceID = ? AND endedAt IS NULL",
                arguments: [endedAt.timeIntervalSince1970, status.rawValue, traceID]
            )
        }
    }

    /// Reconciles traces left `running` by a previous process (the app quit or crashed
    /// mid-run, so `endTrace` never ran) to `.interrupted`, and closes their open spans.
    /// Otherwise such traces linger `running` forever and pollute reliability stats (Gap #13).
    ///
    /// `before` MUST be a timestamp captured at launch, *before* this process creates any
    /// trace: only traces that started earlier are touched, so a live trace from the
    /// current process can never be clobbered. Returns the number of traces reconciled.
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
