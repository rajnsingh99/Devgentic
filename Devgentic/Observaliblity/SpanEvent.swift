// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
///
/// Columns added in migration v2 (`errorCategory`, `errorChainID`, `phase`,
/// `iterationNumber`, `causedByEventID`, `durationMs`) are all nullable. Writes
/// are dev-mode-gated in `TraceRecorder` — legacy call sites continue to pass
/// nil and stay backward-compatible.
struct SpanEvent: Codable, Identifiable, Sendable {
    var id: Int64?  // Auto-assigned by DB (AUTOINCREMENT)
    let spanID: String
    let traceID: String
    let timestamp: Date
    let eventType: SpanEventType
    let content: String?
    let detailJSON: String?   // Serialized JSON string for flexible structured data
    let severity: SpanEventSeverity

    // MARK: - v2 observability columns (all nullable, dev-mode-gated writes)

    /// Canonical failure classification. `AgentErrorCategory.rawValue`.
    /// Nil for non-error events (thoughts, LLM requests, successful tool results).
    let errorCategory: AgentErrorCategory?

    /// UUID shared across every SpanEvent emitted about the same underlying
    /// incident, so analytics can collapse propagation duplicates.
    /// Nil for events not part of an error chain.
    let errorChainID: UUID?

    /// Coarse execution phase. Redundant with `errorCategory.phase` but indexed
    /// for dashboard queries. `ExecutionPhase.rawValue`.
    let phase: ExecutionPhase?

    /// ReAct iteration number if this event was emitted inside the cognitive loop.
    /// Nil for pre-loop (trace init, plan generation) or post-loop (synthesis) events.
    let iterationNumber: Int?

    /// ID of the event that causally triggered this one. Enables cause→effect
    /// linking in the Report Inspector. Not enforced as a DB foreign key —
    /// tolerates out-of-order event writes.
    let causedByEventID: Int64?

    /// Intrinsic duration of the event (LLM response time, tool latency).
    /// Distinct from the enclosing span's wall-clock duration.
    let durationMs: Int?

    init(
        id: Int64? = nil,
        spanID: String,
        traceID: String,
        timestamp: Date = Date(),
        eventType: SpanEventType,
        content: String? = nil,
        detailJSON: String? = nil,
        severity: SpanEventSeverity = .info,
        errorCategory: AgentErrorCategory? = nil,
        errorChainID: UUID? = nil,
        phase: ExecutionPhase? = nil,
        iterationNumber: Int? = nil,
        causedByEventID: Int64? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.spanID = spanID
        self.traceID = traceID
        self.timestamp = timestamp
        self.eventType = eventType
        self.content = content
        self.detailJSON = detailJSON
        self.severity = severity
        self.errorCategory = errorCategory
        self.errorChainID = errorChainID
        self.phase = phase
        self.iterationNumber = iterationNumber
        self.causedByEventID = causedByEventID
        self.durationMs = durationMs
    }
}

// MARK: GRDB Conformance

extension SpanEvent: FetchableRecord, PersistableRecord, MutablePersistableRecord {
    static var databaseTableName: String { "span_events" }

    // Persist `timestamp` as REAL seconds-since-1970 (matching the `.double` column) so the
    // metrics time-window filters on `span_events.timestamp` actually match. See `TraceRecord`
    // for the full rationale; GRDB 7 spells these as `(for column:)` functions.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    enum Columns: String, ColumnExpression {
        case id, spanID, traceID, timestamp, eventType, content, detailJSON, severity
        case errorCategory, errorChainID, phase, iterationNumber, causedByEventID, durationMs
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
    case workflow       // top-level workflow run span
    case workflowNode   // per-node span inside a workflow run; parent of inner agent iteration spans
}

enum SpanStatus: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
    case running
    case completed
    case error
    /// The user (or the engine's routing) deliberately skipped this work — not a
    /// failure. Added 2026-08-22 (Run-Report Phase 5): skips used to close spans
    /// GREEN (`.completed`), making a skipped node indistinguishable from one that
    /// ran. Stored as rawValue TEXT, so no DB migration — but a PRE-Phase-5 build
    /// reading a trace containing one of these rows fails the enum decode for that
    /// trace (accepted: the trace store is 30-day ephemeral diagnostics, and the
    /// rows age out).
    case skipped
    /// The user stopped the run while this span was open. Distinct from `.error`
    /// (nothing went wrong) and from `.skipped` (nothing was chosen against).
    case cancelled

    /// The span status a finished workflow node's outcome closes with.
    ///
    /// [WF-OB6] Extracted as a pure function for the same reason `WorkflowRetryPolicy` was: this
    /// mapping lived inline in TWO places that disagreed with each other, and neither had a test
    /// surface. The profile path spelled out four arms; the structural path used a two-way
    /// `completed ? .completed : .error` ternary that collapsed cancel AND skip into `.error` —
    /// so a Stop on an Action/Condition/Code/Gate/sub-workflow node was persisted as a node
    /// FAILURE and docked its success rate in the Workflow Activity panel.
    ///
    /// EXHAUSTIVE on purpose: a new `NodeExecutionStatus` case must fail to compile here rather
    /// than silently inherit "error", which is precisely how cancellation got mis-tagged.
    static func forNodeOutcome(_ status: NodeExecutionStatus) -> SpanStatus {
        switch status {
        case .completed: .completed
        case .failed:    .error
        // A Stop is not a failure. Nothing went wrong; the user asked it to end.
        case .canceled:  .cancelled
        // The node never ran, so it can be neither a success nor a failure.
        case .skipped:   .skipped
        }
    }
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

    // Store/read Date columns as REAL seconds-since-1970, matching the `.double` schema
    // columns and the raw-SQL Double writes in `updateSpan`/`closeOpenSpans`. Without an
    // explicit strategy, GRDB's Codable bridge defaults to a TEXT date string, which a
    // `.double`-affinity column keeps as text — and SQLite sorts TEXT above REAL, so every
    // numeric `startedAt`/`endedAt` comparison (duration math, reconciliation) silently
    // never matches. (GRDB 7 spells these as `(for column:)` functions, not properties —
    // a `var` of the same name compiles but is silently ignored.)
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    enum Columns: String, ColumnExpression {
        case spanID, traceID, parentSpanID, name, kind, startedAt, endedAt, status, metadataJSON
    }
}

// MARK: - Trace Status

enum TraceStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case running
    case completed
    /// Degraded success: the run produced a usable answer but something went wrong on
    /// the way (a failed tool call, a circuit-breaker abort, iteration exhaustion).
    /// Distinct from `.completed` so the trace store stops recording "1 of 5 tool calls
    /// failed" as a clean run — the message chip already said `completedWithWarnings`
    /// while the trace said `completed`, and the row carried an `error` summary next to
    /// a success status. Counted WITH `.completed` in every success-rate rollup (it IS
    /// a success), just visible separately.
    /// NB: rows written before 2026-07-19 stored this as `completed`; historical stats
    /// are unchanged, and this case only appears on runs from this build forward.
    case completedWithWarnings
    /// A graceful terminal failure — the run reached a failure outcome without an
    /// exception propagating to the stream boundary (circuit-breaker abort, parse/
    /// iteration exhaustion, workflow all-terminals-failed, ImageGen failure).
    case failed
    /// An exception propagated to the stream boundary (`finalizeMessage` received a
    /// thrown error). Distinct from `.failed`, which is a clean give-up.
    case error
    /// The run was cancelled by the user or its task was cancelled.
    case cancelled
    /// The owning process died mid-run (graceful quit or crash) before `endTrace` ran;
    /// stamped by the startup reconciliation pass, never by the run itself.
    case interrupted
}

extension TraceStatus {
    /// Derives the persisted trace status from how a run actually ended. A thrown error
    /// reaching the stream boundary always wins (it is the most severe signal); otherwise
    /// the executor-reported terminal outcome decides. Centralized here so the mapping can
    /// be unit-tested independently of `ActiveStreamManager.finalizeMessage`, its sole
    /// production caller.
    static func resolve(thrownError: Bool, terminalOutcome: ExecutionOutcome?) -> TraceStatus {
        if thrownError { return .error }
        switch terminalOutcome {
        case .completed: return .completed
        // Degraded success gets its OWN status. The previous mapping to `.completed`
        // assumed the early-stop was "already on the span as a classified agent-error
        // event (circuit-breaker / exhaustion)" — but this outcome also carries plain
        // tool failures ("1 of 5 tool call(s) failed"), which have no such span event,
        // so those runs were indistinguishable from clean ones in the trace store.
        case .completedWithWarnings: return .completedWithWarnings
        case .failed:    return .failed
        // No timeout TraceStatus yet; the span's error text carries the limit.
        case .timedOut:  return .failed
        case .cancelled: return .cancelled
        case .none:      return .completed
        }
    }
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

    // v5: release attribution (stamped at beginTrace) + token accounting (set at endTrace).
    var appVersion: String?
    var buildNumber: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var estimatedCostUSD: Double?
    var tokensEstimated: Bool?

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
        metadataJSON: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        estimatedCostUSD: Double? = nil,
        tokensEstimated: Bool? = nil
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
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.tokensEstimated = tokensEstimated
    }

    // Exclude hydrated fields from DB coding
    enum CodingKeys: String, CodingKey {
        case traceID, conversationID, messageID, profileID, profileName, profileType
        case provider, modelName, startedAt, endedAt, status, errorSummary, metadataJSON
        case appVersion, buildNumber, inputTokens, outputTokens, estimatedCostUSD, tokensEstimated
    }
}

// MARK: GRDB Conformance

extension TraceRecord: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "traces" }

    // See `Span`'s note: persist Date columns as REAL seconds-since-1970 so the schema's
    // `.double` `startedAt`/`endedAt` columns actually hold numbers. Otherwise `purgeOlderThan`,
    // `reconcileOrphanedTraces`, the reliability time-window filters, and duration math all
    // compare a TEXT date against a Double and silently match nothing. (GRDB 7 spells
    // these as `(for column:)` functions, not properties.)
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    enum Columns: String, ColumnExpression {
        case traceID, conversationID, messageID, profileID, profileName, profileType
        case provider, modelName, startedAt, endedAt, status, errorSummary, metadataJSON
        case appVersion, buildNumber, inputTokens, outputTokens, estimatedCostUSD, tokensEstimated
    }
}

// MARK: - TraceSummary (Computed, not stored)

/// Aggregated statistics for a trace or set of spans.
/// Computed from queries, never persisted directly.
struct TraceSummary: Codable, Sendable {
    var totalIterations: Int = 0
    var totalLLMCalls: Int = 0
    var totalToolCalls: Int = 0
    var parseErrors: Int = 0
    var hallucinatedTools: Int = 0
    var userInteractions: Int = 0
    var totalDurationMs: Int = 0
}
