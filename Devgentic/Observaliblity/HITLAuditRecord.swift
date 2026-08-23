//
//  HITLAuditRecord.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import GRDB

/// A durable, cross-restart audit record of one HITL request and its resolution.
///
/// [HITL/C2] Unlike the C1 `userInteraction` trace span (emitted only ON resolve), this row is
/// written at RAISE — so a request still pending when the app quits or crashes survives as a row
/// with no `resolvedAt`, which the launch reconcile pass stamps `interrupted`. Lives in the
/// observability store (`traces.sqlite`) alongside traces/spans/logs.
///
/// Privacy: stores the structural facts (which interface/node/tool, when, how it resolved, how long
/// the user took) — NOT verbatim question text or argument values, mirroring the banner-log policy.
struct HITLAuditRecord: Codable, Identifiable, Sendable {
    var id: String { operationID }      // operationID is the natural unique key

    let operationID: String
    let conversationID: String
    let interface: String               // chat | code | workflow | scheduled
    let type: String                    // permission | clarification | plan_review | gate
    let toolName: String?               // present for permission/gate
    let nodeName: String?               // present for workflow nodes
    let title: String                   // generic attribution title (no verbatim content)
    let raisedAt: Date
    var resolvedAt: Date?               // nil while pending; set on resolve / interrupted reconcile
    var outcome: String?                // approved/denied/answered/skipped/rejected/cancelled/interrupted

    // v8 join keys (Run-Report Phase 5) — nullable, still no FK: rows must keep
    // surviving trace purge and process death. nil on pre-v8 rows, which the Run
    // Report matches by conversation + time window instead.
    var traceID: String?
    var spanID: String?

    init(
        operationID: String,
        conversationID: String,
        interface: String,
        type: String,
        toolName: String?,
        nodeName: String?,
        title: String,
        raisedAt: Date = Date(),
        resolvedAt: Date? = nil,
        outcome: String? = nil,
        traceID: String? = nil,
        spanID: String? = nil
    ) {
        self.operationID = operationID
        self.conversationID = conversationID
        self.interface = interface
        self.type = type
        self.toolName = toolName
        self.nodeName = nodeName
        self.title = title
        self.raisedAt = raisedAt
        self.resolvedAt = resolvedAt
        self.outcome = outcome
        self.traceID = traceID
        self.spanID = spanID
    }
}

extension HITLAuditRecord: FetchableRecord, PersistableRecord {
    static var databaseTableName: String { "hitl_audit" }

    // Persist Date columns as REAL seconds-since-1970 (matching the `.double` columns) so the
    // 30-day `purgeHITLAuditOlderThan` and the `reconcileOrphanedHITL` (raisedAt < ?) comparisons
    // actually match. See `LogEntry`/`TraceRecord` for the full rationale.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    enum Columns: String, ColumnExpression {
        case operationID, conversationID, interface, type, toolName, nodeName, title
        case raisedAt, resolvedAt, outcome, traceID, spanID
    }
}
