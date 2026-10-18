// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TraceExportDTO.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Export/import representation of a fully hydrated trace, serializing the whole rootSpans, spans and
/// events tree. Separate from the GRDB records, whose `CodingKeys` omit hydrated children; enum fields
/// are flattened to `rawValue` strings.
struct TraceExportDTO: Codable, Identifiable, Sendable {
    let traceID: String
    let conversationID: String
    let messageID: String
    let profileID: String
    let profileName: String
    let profileType: String
    let provider: String?
    let modelName: String?
    let startedAt: Date
    let endedAt: Date?
    let status: String
    let errorSummary: String?
    let metadataJSON: String?

    // Build attribution and token/cost accounting columns; all optional, so older bundles decode
    // unchanged.
    let appVersion: String?
    let buildNumber: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let estimatedCostUSD: Double?
    let tokensEstimated: Bool?

    let rootSpans: [SpanExportDTO]

    var id: String { traceID }

    init(_ t: TraceRecord) {
        traceID = t.traceID
        conversationID = t.conversationID
        messageID = t.messageID
        profileID = t.profileID
        profileName = t.profileName
        profileType = t.profileType
        provider = t.provider
        modelName = t.modelName
        startedAt = t.startedAt
        endedAt = t.endedAt
        status = t.status.rawValue
        errorSummary = t.errorSummary
        metadataJSON = t.metadataJSON
        appVersion = t.appVersion
        buildNumber = t.buildNumber
        inputTokens = t.inputTokens
        outputTokens = t.outputTokens
        estimatedCostUSD = t.estimatedCostUSD
        tokensEstimated = t.tokensEstimated
        rootSpans = (t.rootSpans ?? []).map(SpanExportDTO.init)
    }
}

struct SpanExportDTO: Codable, Identifiable, Sendable {
    let spanID: String
    let traceID: String
    let parentSpanID: String?
    let name: String
    let kind: String
    let startedAt: Date
    let endedAt: Date?
    let status: String
    let metadataJSON: String?
    let events: [SpanEvent]
    let children: [SpanExportDTO]

    var id: String { spanID }

    /// Duration in ms, computed from the start/end timestamps (the viewer renders this).
    var durationMs: Int? {
        guard let endedAt else { return nil }
        return Int(endedAt.timeIntervalSince(startedAt) * 1000)
    }

    init(_ s: Span) {
        spanID = s.spanID
        traceID = s.traceID
        parentSpanID = s.parentSpanID
        name = s.name
        kind = s.kind.rawValue
        startedAt = s.startedAt
        endedAt = s.endedAt
        status = s.status.rawValue
        metadataJSON = s.metadataJSON
        events = s.events ?? []
        children = (s.children ?? []).map(SpanExportDTO.init)
    }
}
