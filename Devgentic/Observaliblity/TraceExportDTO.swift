// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  TraceExportDTO.swift
//  Devgentic
//
//  Export/import representation of a fully-hydrated trace.
//
//  The GRDB-backed `TraceRecord`/`Span` deliberately EXCLUDE their hydrated children
//  (`rootSpans`/`events`/`children`) from `CodingKeys`, because that same Codable
//  conformance drives DB row mapping and the tables have no such columns. As a result
//  JSON-encoding a `TraceRecord` drops every span and event — the exported `trace.json`
//  was hollow (observability Gap #2).
//
//  These DTOs are a SEPARATE Codable surface that DOES serialize the full
//  rootSpans → spans → events tree. `BundleExporter.writeTrace` encodes them; the
//  in-app bundle viewer (`BundleViewer`) decodes them. Enum-typed fields are flattened
//  to their `rawValue` strings for forward-compatible, human-readable JSON.
//

import Foundation

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

    // v5 columns (build attribution + token/cost accounting). These were silently
    // DROPPED from every export until 2026-08-22 — the DTO predates the migration
    // and nobody extended it, so bundles carried no version or spend data. All
    // optional, so old bundles decode unchanged in the viewer.
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
