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
    
    private let dbPool: DatabasePool
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
        
        try migrator.migrate(dbPool)
        
        logger.info("TraceStore initialized at: \(dbPath)")
    }
    
    /// For unit testing: create an in-memory database.
    init(inMemory: Bool) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        dbPool = try DatabasePool(path: ":memory:", configuration: config)
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
        
        return migrator
    }
    
    // MARK: - Write Operations
    
    /// Inserts a new trace record.
    func insertTrace(_ trace: TraceRecord) throws {
        try dbPool.write { db in
            try trace.insert(db)
        }
    }
    
    /// Inserts a new span.
    func insertSpan(_ span: Span) throws {
        try dbPool.write { db in
            try span.insert(db)
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
    
    /// Updates an existing span (e.g., setting endedAt, status).
    func updateSpan(spanID: String, endedAt: Date, status: SpanStatus) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE spans SET endedAt = ?, status = ? WHERE spanID = ?",
                arguments: [endedAt.timeIntervalSince1970, status.rawValue, spanID]
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
}
