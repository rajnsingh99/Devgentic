// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TraceExportDTOTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class TraceExportDTOTests: XCTestCase {

    /// Builds an in-memory hydrated trace: root span (1 event) → child span (1 error event).
    private func hydratedTrace() -> TraceRecord {
        let traceID = "trace-1"
        let rootEvent = SpanEvent(spanID: "span-root", traceID: traceID,
                                  eventType: .toolCall, content: "called read_file", severity: .info)
        let childEvent = SpanEvent(spanID: "span-child", traceID: traceID,
                                   eventType: .error, content: "boom", severity: .error)

        var child = Span(spanID: "span-child", traceID: traceID, parentSpanID: "span-root",
                         name: "iteration_1", kind: .iteration)
        child.events = [childEvent]

        var root = Span(spanID: "span-root", traceID: traceID, name: "root", kind: .workflow)
        root.events = [rootEvent]
        root.children = [child]

        var trace = TraceRecord(traceID: traceID, conversationID: "c", messageID: "m",
                                profileID: "p", profileName: "Test", profileType: "Agent",
                                status: .completed)
        trace.rootSpans = [root]
        return trace
    }

    func testTraceRecordEncodesHollow_butDTOEncodesFullTree() throws {
        let trace = hydratedTrace()

        // Baseline — the GRDB struct drops the nested tree at encode time (the bug).
        let rawJSON = String(data: try JSONEncoder().encode(trace), encoding: .utf8)!
        XCTAssertFalse(rawJSON.contains("span-root"), "TraceRecord must NOT serialize its spans (CodingKeys exclusion)")

        // DTO — full tree present.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let dtoJSON = String(data: try encoder.encode(TraceExportDTO(trace)), encoding: .utf8)!
        XCTAssertTrue(dtoJSON.contains("span-root"), "DTO serializes the root span")
        XCTAssertTrue(dtoJSON.contains("span-child"), "DTO serializes nested child spans")
        XCTAssertTrue(dtoJSON.contains("called read_file"), "DTO serializes span events")
        XCTAssertTrue(dtoJSON.contains("boom"), "DTO serializes nested-span events")
    }

    func testDTORoundTrips() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(TraceExportDTO(hydratedTrace()))
        let decoded = try decoder.decode(TraceExportDTO.self, from: data)

        XCTAssertEqual(decoded.traceID, "trace-1")
        XCTAssertEqual(decoded.status, TraceStatus.completed.rawValue)
        XCTAssertEqual(decoded.rootSpans.count, 1)
        let root = try XCTUnwrap(decoded.rootSpans.first)
        XCTAssertEqual(root.events.count, 1)
        XCTAssertEqual(root.events.first?.content, "called read_file")
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.children.first?.events.first?.content, "boom")
        XCTAssertEqual(root.children.first?.events.first?.severity, .error)
    }
}
