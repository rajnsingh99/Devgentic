//
//  SpanEvent.swift
//  Devgentic
//
//  Created by Antigravity on 19/03/26.
//

import Foundation
import GRDB

// MARK: - Span Event Type

/// All observable event types within a span.
/// Extensible — add new cases freely; GRDB stores as raw String.
enum SpanEventType: String, Codable, Sendable, DatabaseValueConvertible {
    case thought
    case llmRequest
    case llmResponse
    case toolCall
    case toolResult
    case parseAttempt
    case parseError
    case stateChange
    case memoryOp
    case userInteraction
    case error
    case metric
}

/// Severity levels for span events.
enum SpanEventSeverity: String, Codable, Sendable, DatabaseValueConvertible {
    case debug
    case info
    case warning
    case error
}

// MARK: - SpanEvent (Row-level log record)

/// A single observable event within a span.
/// This is the universal log record — each row in `span_events`.
struct SpanEvent: Codable, Identifiable, Sendable {
    var id: Int64?  // Auto-assigned by DB (AUTOINCREMENT)
    let spanID: String
    let traceID: String
    let timestamp: Date
    let eventType: SpanEventType
    let content: String?
    let detailJSON: String?   // Serialized JSON string for flexible structured data
    let severity: SpanEventSeverity
    
    init(
        id: Int64? = nil,
        spanID: String,
        traceID: String,
        timestamp: Date = Date(),
        eventType: SpanEventType,
        content: String? = nil,
        detailJSON: String? = nil,
        severity: SpanEventSeverity = .info
    ) {
        self.id = id
        self.spanID = spanID
        self.traceID = traceID
        self.timestamp = timestamp
        self.eventType = eventType
        self.content = content
        self.detailJSON = detailJSON
        self.severity = severity
    }
}

// MARK: GRDB Conformance

extension SpanEvent: FetchableRecord, PersistableRecord, MutablePersistableRecord {
    static var databaseTableName: String { "span_events" }
    
    enum Columns: String, ColumnExpression {
        case id, spanID, traceID, timestamp, eventType, content, detailJSON, severity
    }
    
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Span Kind & Status

enum SpanKind: String, Codable, Sendable, DatabaseValueConvertible {
    case llmCall
    case toolExecution
    case iteration
    case subtask
    case workflow
}

enum SpanStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case running
    case completed
    case error
}

// MARK: - Span (Logical operation unit)

/// A logical operation unit within a trace.
/// Each row in `spans`. E.g., "react_iteration_1", "tool:read_file".
struct Span: Codable, Identifiable, Sendable {
    let spanID: String
    let traceID: String
    let parentSpanID: String?
    let name: String
    let kind: SpanKind
    let startedAt: Date
    var endedAt: Date?
    var status: SpanStatus
    var metadataJSON: String?
    
    // Hydrated at query time (not stored in DB)
    var events: [SpanEvent]?
    var children: [Span]?
    
    var id: String { spanID }
    
    /// Computed duration in milliseconds.
    var durationMs: Int? {
        guard let end = endedAt else { return nil }
        return Int(end.timeIntervalSince(startedAt) * 1000)
    }
    
    init(
        spanID: String,
        traceID: String,
        parentSpanID: String? = nil,
        name: String,
        kind: SpanKind,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: SpanStatus = .running,
        metadataJSON: String? = nil
    ) {
        self.spanID = spanID
        self.traceID = traceID
        self.parentSpanID = parentSpanID
        self.name = name
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.metadataJSON = metadataJSON
    }
    
    // Exclude hydrated fields from DB coding
    enum CodingKeys: String, CodingKey {
        case spanID, traceID, parentSpanID, name, kind, startedAt, endedAt, status, metadataJSON
    }
}

// MARK: GRDB Conformance

extension Span: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "spans" }
    
    enum Columns: String, ColumnExpression {
        case spanID, traceID, parentSpanID, name, kind, startedAt, endedAt, status, metadataJSON
    }
}

// MARK: - Trace Status

enum TraceStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case running
    case completed
    case error
}

// MARK: - TraceRecord (Top-level envelope)

/// The persistent top-level record for a complete request → response cycle.
/// Each row in `traces`.
struct TraceRecord: Codable, Identifiable, Sendable {
    let traceID: String
    let conversationID: String
    let messageID: String
    let profileID: String
    let profileName: String
    let profileType: String
    let provider: String?
    let modelName: String?
    let startedAt: Date
    var endedAt: Date?
    var status: TraceStatus
    var errorSummary: String?
    var metadataJSON: String?
    
    // Hydrated at query time (not stored in DB)
    var rootSpans: [Span]?
    
    var id: String { traceID }
    
    /// Computed duration in milliseconds.
    var durationMs: Int? {
        guard let end = endedAt else { return nil }
        return Int(end.timeIntervalSince(startedAt) * 1000)
    }

    init(
        traceID: String,
        conversationID: String,
        messageID: String,
        profileID: String,
        profileName: String,
        profileType: String,
        provider: String? = nil,
        modelName: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: TraceStatus = .running,
        errorSummary: String? = nil,
        metadataJSON: String? = nil
    ) {
        self.traceID = traceID
        self.conversationID = conversationID
        self.messageID = messageID
        self.profileID = profileID
        self.profileName = profileName
        self.profileType = profileType
        self.provider = provider
        self.modelName = modelName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.errorSummary = errorSummary
        self.metadataJSON = metadataJSON
    }
    
    // Exclude hydrated fields from DB coding
    enum CodingKeys: String, CodingKey {
        case traceID, conversationID, messageID, profileID, profileName, profileType
        case provider, modelName, startedAt, endedAt, status, errorSummary, metadataJSON
    }
}

// MARK: GRDB Conformance

extension TraceRecord: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "traces" }
    
    enum Columns: String, ColumnExpression {
        case traceID, conversationID, messageID, profileID, profileName, profileType
        case provider, modelName, startedAt, endedAt, status, errorSummary, metadataJSON
    }
}

// MARK: - TraceSummary (Computed, not stored)

/// Aggregated statistics for a trace or set of spans.
/// Computed from queries, never persisted directly.
struct TraceSummary: Sendable {
    var totalIterations: Int = 0
    var totalLLMCalls: Int = 0
    var totalToolCalls: Int = 0
    var parseErrors: Int = 0
    var hallucinatedTools: Int = 0
    var userInteractions: Int = 0
    var totalDurationMs: Int = 0
}
