// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LogEntry.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Persist `timestamp` as REAL seconds-since-1970 (matching the `.double` column) so the
    // 30-day `purgeLogEntriesOlderThan` (timestamp < ?) actually deletes. See `TraceRecord`
    // for the full rationale; GRDB 7 spells these as `(for column:)` functions.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    enum Columns: String, ColumnExpression {
        case id, timestamp, level, subsystem, category, message
        case traceID, spanID, phase, metadataJSON
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
