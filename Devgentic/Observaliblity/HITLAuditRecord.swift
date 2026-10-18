// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HITLAuditRecord.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import GRDB

/// A durable, cross-restart audit record of one HITL request and its resolution, stored in the observability store
/// (`traces.sqlite`). Written at raise, so a request pending at quit or crash survives with no `resolvedAt` and is
/// stamped `interrupted` at launch. It stores structural facts only, never question text or argument values.
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

    // Join keys, nullable and without a foreign key so rows survive trace purge and process death; nil on older rows,
    // which the Run Report matches by conversation and time window.
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

    // Persists Date columns as REAL seconds-since-1970 (matching the `.double` columns) so the 30-day purge and
    // orphan-reconcile comparisons match. See `LogEntry`/`TraceRecord`.
    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    enum Columns: String, ColumnExpression {
        case operationID, conversationID, interface, type, toolName, nodeName, title
        case raisedAt, resolvedAt, outcome, traceID, spanID
    }
}
