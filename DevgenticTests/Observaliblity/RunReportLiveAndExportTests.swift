// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RunReportLiveAndExportTests.swift
//  devgenticTests
//
//  Run-Report Phase 4: the live observation stream, flush-on-open, deep search,
//  and the two export fixes (conversation-scope hydration; v5 fields in the DTO).
//

import XCTest
@testable import devgentic

final class RunReportLiveAndExportTests: XCTestCase {

    // MARK: - Live observation

    /// A write to the observed trace must wake the stream with a changed fingerprint.
    func testObservationEmitsOnNewEvent() async throws {
        let store = try TraceStore(inMemory: true)
        let recorder = TraceRecorder(store: store)
        let ctx = TraceContext(subAgentName: "live-test", provider: .anthropic)
        await recorder.beginTrace(context: ctx, conversationID: UUID(), messageID: UUID(), modelName: nil)

        var iterator = store.observeRun(traceID: ctx.traceID).makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.eventCount, 0)
        XCTAssertEqual(initial?.spanCount, 1) // the auto-created root
        XCTAssertEqual(initial?.traceStatus, "running")

        // Write an event and flush — the stream must emit an updated fingerprint.
        await recorder.emitToolResult(span: ctx, name: "read_file", success: true, output: "ok", durationMs: 10)
        await recorder.flushNow()

        let updated = try await withTimeout(seconds: 5) { try await iterator.next() }
        XCTAssertEqual(updated??.eventCount, 1, "the live view must see the new event")
    }

    /// Ending the trace must wake the stream too — that's how the panel learns the
    /// verdict flipped from Running to a terminal state.
    func testObservationEmitsOnTraceEnd() async throws {
        let store = try TraceStore(inMemory: true)
        let recorder = TraceRecorder(store: store)
        let ctx = TraceContext(subAgentName: "live-end-test", provider: .anthropic)
        await recorder.beginTrace(context: ctx, conversationID: UUID(), messageID: UUID(), modelName: nil)

        var iterator = store.observeRun(traceID: ctx.traceID).makeAsyncIterator()
        _ = try await iterator.next() // initial

        await recorder.endTrace(traceID: ctx.traceID, status: .completed)

        // endTrace runs TWO write transactions (trace update, then closeOpenSpans),
        // so the terminal state can arrive across two ticks — collect until BOTH
        // conditions hold rather than asserting them on whichever tick lands first.
        let terminal = try await withTimeout(seconds: 5) { () -> TraceStore.RunFingerprint? in
            while let fp = try await iterator.next() {
                if fp.traceStatus == "completed" && fp.closedSpanCount == 1 { return fp }
            }
            return nil
        }
        XCTAssertNotNil(terminal ?? nil,
                        "the observation must eventually show status=completed AND the clamped root span")
    }

    /// flushNow drains the buffer without waiting for the 1s loop — the reason the
    /// panel can trust its first paint.
    func testFlushNowMakesBufferedEventsReadable() async throws {
        let store = try TraceStore(inMemory: true)
        let recorder = TraceRecorder(store: store)
        let ctx = TraceContext(subAgentName: "flush-test", provider: .anthropic)
        await recorder.beginTrace(context: ctx, conversationID: UUID(), messageID: UUID(), modelName: nil)

        await recorder.emitToolResult(span: ctx, name: "a", success: true, output: "x", durationMs: 1)
        // No endTrace, no 1s wait — just the explicit drain.
        await recorder.flushNow()

        let events = try store.fetchEvents(forTraceID: ctx.traceID)
        XCTAssertEqual(events.filter { $0.eventType == .toolResult }.count, 1)
    }

    // MARK: - Search

    func testSearchMatchesTitleCaseInsensitively() {
        let row = makeRow(title: "read_file · README.md", meta: "", detailCode: nil)
        XCTAssertTrue(RunReportProjection.rowMatches(row, query: "readme"))
        XCTAssertFalse(RunReportProjection.rowMatches(row, query: "nonexistent"))
    }

    func testSearchReachesInspectorPayload() {
        // The visible title is truncated — the full path lives only in the detail.
        let row = makeRow(title: "write_file · …", meta: "",
                          detailCode: "{\"path\":\"/deep/nested/SecretConfig.swift\"}")
        XCTAssertTrue(RunReportProjection.rowMatches(row, query: "secretconfig"),
                      "search must reach tool args, not just the truncated title")
    }

    func testEmptyQueryMatchesEverything() {
        let row = makeRow(title: "anything", meta: "", detailCode: nil)
        XCTAssertTrue(RunReportProjection.rowMatches(row, query: ""))
        XCTAssertTrue(RunReportProjection.rowMatches(row, query: "   "))
    }

    // MARK: - Export: conversation-scope hydration (the hollow-bundle fix)

    func testConversationScopeExportsHydratedTraces() async throws {
        // Uses the SHARED recorder/store (XCTest-redirected) because BundleExporter
        // reads through the singletons.
        let conversationID = UUID()
        let ctx = TraceContext(subAgentName: "export-test", provider: .anthropic)
        await TraceRecorder.shared.beginTrace(
            context: ctx, conversationID: conversationID, messageID: UUID(), modelName: nil)
        await TraceRecorder.shared.emitToolResult(span: ctx, name: "read_file", success: true, output: "data", durationMs: 5)
        await TraceRecorder.shared.endTrace(traceID: ctx.traceID, status: .completed)

        let traces = try await BundleExporter.fetchTraces(for: .conversation(id: conversationID))
        let exported = try XCTUnwrap(traces.first { $0.traceID == ctx.traceID })
        let roots = try XCTUnwrap(exported.rootSpans, "conversation scope must HYDRATE — header rows made trace.json hollow")
        XCTAssertFalse(roots.isEmpty)
        let allEvents = roots.flatMap { $0.events ?? [] }
        XCTAssertTrue(allEvents.contains { $0.eventType == .toolResult },
                      "the hydrated tree must carry the run's events")
    }

    // MARK: - Export: v5 fields in the DTO

    func testExportDTOCarriesV5Fields() throws {
        var record = TraceRecord(
            traceID: "t-v5", conversationID: "c", messageID: "m",
            profileID: "p", profileName: "P", profileType: "Agent",
            startedAt: Date(timeIntervalSince1970: 1000),
            status: .completed,
            appVersion: "1.2", buildNumber: "345",
            inputTokens: 23_800, outputTokens: 96,
            estimatedCostUSD: 0.09, tokensEstimated: false
        )
        record.rootSpans = []
        let dto = TraceExportDTO(record)
        XCTAssertEqual(dto.appVersion, "1.2")
        XCTAssertEqual(dto.inputTokens, 23_800)
        XCTAssertEqual(dto.estimatedCostUSD ?? 0, 0.09, accuracy: 0.0001)

        // And they survive encoding — the bundle is what analysts actually read.
        let data = try JSONEncoder().encode(dto)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"buildNumber\":\"345\""))
        XCTAssertTrue(json.contains("\"outputTokens\":96"))
    }

    // MARK: - Helpers

    private func makeRow(title: String, meta: String, detailCode: String?) -> RunReportRow {
        RunReportRow(
            id: "r", kind: .tool, timestamp: Date(), title: title, meta: meta,
            duration: "", isProblem: false, isNotable: true, isIndented: false,
            detail: RunReportDetail(
                title: "t", subtitle: "s",
                sections: detailCode.map { [.init(label: "ARGUMENTS", body: .code($0))] } ?? []))
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
