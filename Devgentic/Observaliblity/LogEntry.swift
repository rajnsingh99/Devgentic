//
//  LogEntry.swift
//  Devgentic
//
//  The in-app log record. Every `DGLogger` call produces one of these (dev mode on),
//  routed through `LogRecorder` to the ring buffer and ultimately to the `log_entries`
//  SQLite table.
//
//  Why a separate log record when we already have SpanEvent?
//    - SpanEvents are structured observations tied to a span (thoughts, tool calls,
//      LLM requests). They're the "what the agent did" view.
//    - LogEntries are free-text operational chatter ("Loaded profile X", "Rate limit
//      bucket created", "Model reload failed"). They're the "what the app did" view.
//    - Merging them would pollute SpanEvent with ~449 operational messages per run.
//      Keeping them separate lets ReportInspector show two distinct views.
//

import Foundation
import GRDB

// MARK: - LogLevel

/// Five-level log severity, aligned with `os.Logger` levels.
enum LogLevel: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible, Comparable {
    case debug, info, notice, warning, error

    /// Numeric severity for ordering/filter comparisons. Debug lowest, error highest.
    var rank: Int {
        switch self {
        case .debug:   return 0
        case .info:    return 1
        case .notice:  return 2
        case .warning: return 3
        case .error:   return 4
        }
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - LogEntry

/// A single record captured by `DGLogger` (dev mode on). Rides the in-memory ring
/// buffer and persists to `log_entries` on flush. All string fields are sanitized
/// via `TelemetrySanitizer.sanitizeFull(level: .standard)` before storage.
struct LogEntry: Codable, Identifiable, Sendable {
    var id: Int64?               // assigned by SQLite (AUTOINCREMENT)
    let timestamp: Date
    let level: LogLevel
    let subsystem: String        // usually the app bundle ID
    let category: String         // `DGLogger.category` — the "what layer" label
    let message: String          // sanitized log message
    let traceID: String?         // auto-populated from LogContext task-local, if any
    let spanID: String?          // likewise
    let phase: ExecutionPhase?   // likewise
    let metadataJSON: String?    // arbitrary k-v payload, JSON-serialized + sanitized

    init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        level: LogLevel,
        subsystem: String,
        category: String,
        message: String,
        traceID: String? = nil,
        spanID: String? = nil,
        phase: ExecutionPhase? = nil,
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
        self.traceID = traceID
        self.spanID = spanID
        self.phase = phase
        self.metadataJSON = metadataJSON
    }
}

// MARK: - GRDB

extension LogEntry: FetchableRecord, PersistableRecord, MutablePersistableRecord {
    static var databaseTableName: String { "log_entries" }

    enum Columns: String, ColumnExpression {
        case id, timestamp, level, subsystem, category, message
        case traceID, spanID, phase, metadataJSON
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
