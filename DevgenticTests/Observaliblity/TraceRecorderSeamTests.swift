// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TraceRecorderSeamTests.swift
//  devgenticTests
//
//  First-ever tests for TraceRecorder, enabled by the Phase-1 injection seam
//  (`TraceRecorder(store:)`). Every test drives a REAL recorder actor against a
//  hermetic `TraceStore(inMemory:)` — no mocks of the thing under test.
//
//  Covers the Phase-1 truth fixes:
//    • call-site timestamps (`at:` defaults evaluated at the call site)
//    • earliest-wins span ends (real end corrects endTrace's clamp, either order)
//    • beginTrace persists the resolved model name → non-NULL estimatedCostUSD
//    • fetchTrace(forMessageID:) returns the NEWEST attempt deterministically
//

import XCTest
@testable import devgentic

final class TraceRecorderSeamTests: XCTestCase {

    private var store: TraceStore!
    private var recorder: TraceRecorder!

    override func setUpWithError() throws {
        store = try TraceStore(inMemory: true)
        recorder = TraceRecorder(store: store)
    }

    // MARK: - Helpers

    private func makeProfile() -> ProfileInfo {
        ProfileInfo(id: UUID(), name: "Seam Test", type: .agent, provider: .anthropic)
    }

    private func makeContext() -> TraceContext {
        TraceContext(subAgentName: "seam-test", provider: .anthropic)
    }

    /// Begins a trace through the recorder and returns its root context.
    @discardableResult
    private func beginTrace(modelName: String? = nil) async -> TraceContext {
        let ctx = makeContext()
        await recorder.beginTrace(
            context: ctx,
            conversationID: UUID(),
            messageID: UUID(),
            modelName: modelName
        )
        return ctx
    }

    // MARK: - Injection seam

    func testRecorderWritesThroughInjectedStore() async throws {
        let ctx = await beginTrace()
        let row = try store.fetchTrace(traceID: ctx.traceID)
        XCTAssertNotNil(row, "beginTrace through an injected store must land in THAT store")
        XCTAssertEqual(row?.status, .running)
        // The auto-created root span satisfies the FK for trace-level events.
        let spans = try store.fetchSpans(forTraceID: ctx.traceID)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.name, "root")
    }

    // MARK: - Call-site timestamps

    func testBeginAndEndSpanPersistExplicitDates() async throws {
        let ctx = await beginTrace()
        let child = ctx.newSpan()
        let began = Date(timeIntervalSince1970: 1_000_000)
        let ended = Date(timeIntervalSince1970: 1_000_010)

        await recorder.beginSpan(context: child, name: "unit", kind: .iteration, at: began)
        await recorder.endSpan(spanID: child.spanID, status: .completed, at: ended)

        let span = try store.fetchSpans(forTraceID: ctx.traceID).first { $0.spanID == child.spanID }
        XCTAssertEqual(span?.startedAt.timeIntervalSince1970 ?? 0, began.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(span?.endedAt?.timeIntervalSince1970 ?? 0, ended.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(span?.status, .completed)
    }

    func testEmitPersistsCallSiteTimestamp() async throws {
        let ctx = await beginTrace()
        let child = ctx.newSpan()
        await recorder.beginSpan(context: child, name: "unit", kind: .iteration)

        let callSite = Date(timeIntervalSince1970: 2_000_000)
        await recorder.emitToolResult(span: child, name: "read_file", success: true, output: "ok", durationMs: 42, at: callSite)
        await recorder.endTrace(traceID: ctx.traceID, status: .completed) // forces flush

        let events = try store.fetchEvents(forSpanID: child.spanID)
        let tool = events.first { $0.eventType == .toolResult }
        XCTAssertNotNil(tool)
        XCTAssertEqual(tool?.timestamp.timeIntervalSince1970 ?? 0, callSite.timeIntervalSince1970, accuracy: 0.001,
                       "the persisted event time must be the caller's clock, not actor-arrival time")
    }

    // MARK: - Earliest-wins span ends (the clamp fix)

    /// The race this fixes: a fire-and-forget `endSpan` (from a defer) loses to
    /// `endTrace`'s `closeOpenSpans` clamp. The real, EARLIER end must correct the
    /// clamped row when it finally lands.
    func testRealEndCorrectsClampAfterEndTrace() async throws {
        let ctx = await beginTrace()
        let child = ctx.newSpan()
        let began = Date(timeIntervalSince1970: 3_000_000)
        await recorder.beginSpan(context: child, name: "iteration_1", kind: .iteration, at: began)

        // endTrace wins the race: clamps the still-open span to the trace end.
        await recorder.endTrace(traceID: ctx.traceID, status: .completed)
        let clamped = try store.fetchSpans(forTraceID: ctx.traceID).first { $0.spanID == child.spanID }
        XCTAssertNotNil(clamped?.endedAt, "clamp must have closed the span")

        // The deferred real end arrives late, with the REAL (earlier) time.
        let realEnd = began.addingTimeInterval(1)
        await recorder.endSpan(spanID: child.spanID, status: .completed, at: realEnd)

        let corrected = try store.fetchSpans(forTraceID: ctx.traceID).first { $0.spanID == child.spanID }
        XCTAssertEqual(corrected?.endedAt?.timeIntervalSince1970 ?? 0, realEnd.timeIntervalSince1970, accuracy: 0.001,
                       "an earlier real end must overwrite the trace-end clamp")
    }

    func testLaterClampDoesNotOverwriteRealEnd() async throws {
        let ctx = await beginTrace()
        let child = ctx.newSpan()
        let began = Date(timeIntervalSince1970: 4_000_000)
        let realEnd = began.addingTimeInterval(2)
        await recorder.beginSpan(context: child, name: "iteration_1", kind: .iteration, at: began)
        await recorder.endSpan(spanID: child.spanID, status: .completed, at: realEnd)

        // endTrace arrives later; its clamp must skip the already-closed span.
        await recorder.endTrace(traceID: ctx.traceID, status: .error)

        let span = try store.fetchSpans(forTraceID: ctx.traceID).first { $0.spanID == child.spanID }
        XCTAssertEqual(span?.endedAt?.timeIntervalSince1970 ?? 0, realEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(span?.status, .completed, "a real completion must not be repainted by a later error clamp")
    }

    func testDuplicateEndSpanReplayIsNoOp() async throws {
        let ctx = await beginTrace()
        let child = ctx.newSpan()
        let realEnd = Date(timeIntervalSince1970: 5_000_000)
        await recorder.beginSpan(context: child, name: "unit", kind: .iteration)
        await recorder.endSpan(spanID: child.spanID, status: .completed, at: realEnd)
        // Same time, different status — NOT strictly earlier, must not rewrite.
        await recorder.endSpan(spanID: child.spanID, status: .error, at: realEnd)

        let span = try store.fetchSpans(forTraceID: ctx.traceID).first { $0.spanID == child.spanID }
        XCTAssertEqual(span?.status, .completed, "a same-time replay must not flip a closed span's status")
    }

    // MARK: - Model name → cost (the always-NULL-cost fix)

    func testBeginTraceWithModelNameYieldsNonNilCost() async throws {
        let ctx = await beginTrace(modelName: "claude-sonnet-4")
        await recorder.recordTokenUsage(
            traceID: ctx.traceID,
            usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 100_000, isEstimated: false)
        )
        let row = try store.fetchTrace(traceID: ctx.traceID)
        XCTAssertEqual(row?.modelName, "claude-sonnet-4")
        XCTAssertEqual(row?.inputTokens, 1_000_000)
        let cost = try XCTUnwrap(row?.estimatedCostUSD, "a priced model must produce a cost")
        // claude-sonnet pricing: 1M in @ $3 + 0.1M out @ $15/1M = 3.0 + 1.5
        XCTAssertEqual(cost, 4.5, accuracy: 0.01)
        XCTAssertEqual(row?.tokensEstimated, false)
    }

    func testBeginTraceWithoutModelNameLeavesCostNilButKeepsTokens() async throws {
        let ctx = await beginTrace(modelName: nil) // e.g. a workflow run
        await recorder.recordTokenUsage(
            traceID: ctx.traceID,
            usage: TokenUsage(inputTokens: 500, outputTokens: 100, isEstimated: true)
        )
        let row = try store.fetchTrace(traceID: ctx.traceID)
        XCTAssertNil(row?.estimatedCostUSD, "no model → no price attribution, honestly nil")
        XCTAssertEqual(row?.inputTokens, 500)
        XCTAssertEqual(row?.tokensEstimated, true)
    }

    // MARK: - Honest clamp mapping (Phase 5)

    /// A user Stop clamps still-open spans as `.cancelled` — nothing went wrong — and
    /// degraded success clamps them `.completed` (the failed step already carries its
    /// own error span/event).
    func testEndTraceClampMapsCancelledAndWarningsHonestly() async throws {
        let cancelled = await beginTrace()
        let cSpan = cancelled.newSpan()
        await recorder.beginSpan(context: cSpan, name: "open", kind: .iteration)
        await recorder.endTrace(traceID: cancelled.traceID, status: .cancelled)
        let cRow = try store.fetchSpans(forTraceID: cancelled.traceID).first { $0.spanID == cSpan.spanID }
        XCTAssertEqual(cRow?.status, .cancelled, "a Stop is not an error")

        let degraded = await beginTrace()
        let dSpan = degraded.newSpan()
        await recorder.beginSpan(context: dSpan, name: "open", kind: .iteration)
        await recorder.endTrace(traceID: degraded.traceID, status: .completedWithWarnings)
        let dRow = try store.fetchSpans(forTraceID: degraded.traceID).first { $0.spanID == dSpan.spanID }
        XCTAssertEqual(dRow?.status, .completed, "degraded success is still success at span level")
    }

    // MARK: - Newest-attempt lookup (Redo determinism)

    func testFetchTraceForMessageIDReturnsNewestAttempt() throws {
        let messageID = UUID().uuidString
        func insert(startedAt: TimeInterval, traceID: String) throws {
            try store.insertTrace(TraceRecord(
                traceID: traceID,
                conversationID: "c",
                messageID: messageID,
                profileID: "p", profileName: "P", profileType: "Agent",
                startedAt: Date(timeIntervalSince1970: startedAt),
                status: .completed
            ))
        }
        try insert(startedAt: 100, traceID: "attempt-1")
        try insert(startedAt: 300, traceID: "attempt-3")
        try insert(startedAt: 200, traceID: "attempt-2")

        let row = try store.fetchTrace(forMessageID: messageID)
        XCTAssertEqual(row?.traceID, "attempt-3", "a regenerated message must resolve to its NEWEST run")
    }
}
