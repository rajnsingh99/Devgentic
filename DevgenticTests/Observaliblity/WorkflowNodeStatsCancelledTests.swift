// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowNodeStatsCancelledTests.swift
//  DevgenticTests
//
//  [WF-OB6] A Stop is not a node failure.
//
//  Until 2026-08-27 a user-cancelled node closed its span `.error`, and
//  `workflowNodeStats` counts `status = 'error'` as `failedCount`. So a user who stopped a
//  workflow three times while iterating on a prompt permanently docked those nodes' success
//  rate in the Workflow Activity panel — precisely the signal that panel exists to surface.
//
//  ⚠️ WHY THE DENOMINATOR ASSERTIONS BELOW ARE THE POINT. Re-tagging the span alone is a
//  HALF-FIX that still reads wrong: `totalRuns` is `COUNT(*)`, so moving a run out of
//  `failedCount` while leaving it in the denominator STILL pushes the rate down. A test that
//  asserted only on `Span.status` would pass against that half-fix. Every test here therefore
//  asserts `successRate`, not just the buckets.
//
//  These run against an in-memory `TraceStore` rather than the shared singleton on purpose:
//  `workflowNodeStats` rolls up `GROUP BY name` over a time window across the WHOLE store, so a
//  singleton-backed test is contaminated by any other test in the bundle that writes a
//  `workflowNode` span.
//

import XCTest
@testable import devgentic

final class WorkflowNodeStatsCancelledTests: XCTestCase {

    private var store: TraceStore!
    private var traceID: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TraceStore(inMemory: true)
        traceID = UUID().uuidString
        // `spans.traceID` carries an FK to `traces`, so a parent row must exist or the span
        // insert is silently rejected and every assertion below reads zero.
        try store.insertTrace(TraceRecord(
            traceID: traceID,
            conversationID: UUID().uuidString,
            messageID: UUID().uuidString,
            profileID: UUID().uuidString,
            profileName: "Test Workflow",
            profileType: "Workflow"
        ))
    }

    override func tearDown() {
        store = nil
        traceID = nil
        super.tearDown()
    }

    /// Writes one closed `workflowNode` span for `nodeName` with the given terminal status,
    /// mirroring what `WorkflowExecutor` does per node attempt (begin → end).
    private func writeNodeSpan(_ nodeName: String, status: SpanStatus) throws {
        let start = Date()
        try store.insertSpan(Span(
            spanID: UUID().uuidString,
            traceID: traceID,
            name: "node:\(nodeName)",
            kind: .workflowNode,
            startedAt: start,
            endedAt: start.addingTimeInterval(1),
            status: status
        ))
    }

    private func stats(for nodeName: String) throws -> WorkflowNodeStats? {
        try store.workflowNodeStats(since: Date().addingTimeInterval(-600))
            .first { $0.nodeName == "node:\(nodeName)" }
    }

    // MARK: - The filed defect

    /// THE ROW. Two clean runs and one Stop must read 100%, not 67% — and the Stop must not be
    /// counted as a failure.
    func testCancelledNodeIsNotCountedAsAFailure() throws {
        try writeNodeSpan("Writer", status: .completed)
        try writeNodeSpan("Writer", status: .completed)
        try writeNodeSpan("Writer", status: .cancelled)

        let s = try XCTUnwrap(stats(for: "Writer"))

        XCTAssertEqual(s.failedCount, 0, "a Stop is not a failure")
        XCTAssertEqual(s.cancelledCount, 1)
        XCTAssertEqual(s.completedCount, 2)
        XCTAssertEqual(s.totalRuns, 3, "totalRuns stays an honest count of how often the node ran")
        XCTAssertEqual(try XCTUnwrap(s.successRate), 1.0, accuracy: 0.0001,
                       "the denominator must exclude the Stop — otherwise re-tagging the span alone still reads 67%")
    }

    /// A skipped node never ran, so it can be neither a success nor a failure. Same denominator
    /// rule as a cancel, and it was swallowed by the same `else { .error }` ternary on the
    /// structural path.
    func testSkippedNodeIsNotCountedAsAFailure() throws {
        try writeNodeSpan("Router", status: .completed)
        try writeNodeSpan("Router", status: .skipped)

        let s = try XCTUnwrap(stats(for: "Router"))

        XCTAssertEqual(s.failedCount, 0)
        XCTAssertEqual(s.skippedCount, 1)
        XCTAssertEqual(s.totalRuns, 2)
        XCTAssertEqual(try XCTUnwrap(s.successRate), 1.0, accuracy: 0.0001)
    }

    /// The control: a REAL failure must still count. Guards against a fix that makes the panel
    /// green by simply not counting anything.
    func testGenuineFailureStillCountsAgainstTheNode() throws {
        try writeNodeSpan("Fetcher", status: .completed)
        try writeNodeSpan("Fetcher", status: .error)

        let s = try XCTUnwrap(stats(for: "Fetcher"))

        XCTAssertEqual(s.failedCount, 1)
        XCTAssertEqual(s.cancelledCount, 0)
        XCTAssertEqual(try XCTUnwrap(s.successRate), 0.5, accuracy: 0.0001,
                       "a real failure still halves the rate — cancels are excluded, failures are not")
    }

    /// A node whose every run was stopped has NO rate to report — `nil`, rendered "—".
    ///
    /// ⚠️ `nil` rather than `0` is load-bearing, and an earlier draft of this fix got it wrong:
    /// returning 0 makes the Trends table paint a RED "0%", which says "this node is broken" about
    /// a node the user simply never let finish. That is this row's own defect (a Stop reading as
    /// brokenness) reappearing at a different number, and a test asserting `0.0` would have
    /// enshrined it.
    func testNodeWithOnlyCancelledRunsHasNoRateToReport() throws {
        try writeNodeSpan("NeverFinished", status: .cancelled)
        try writeNodeSpan("NeverFinished", status: .cancelled)

        let s = try XCTUnwrap(stats(for: "NeverFinished"))

        XCTAssertEqual(s.totalRuns, 2, "the runs happened and are still reported")
        XCTAssertEqual(s.cancelledCount, 2)
        XCTAssertEqual(s.attributableRuns, 0)
        XCTAssertNil(s.successRate,
                     "no verdict means no rate — not 0%, which renders red as though it failed")
    }

    /// The mixed case the row's own failure scenario describes: a node that mostly works, stopped
    /// a few times during prompt iteration, with one genuine failure.
    func testMixedOutcomesScoreOnlyTheAttributableRuns() throws {
        try writeNodeSpan("Summarize", status: .completed)
        try writeNodeSpan("Summarize", status: .completed)
        try writeNodeSpan("Summarize", status: .completed)
        try writeNodeSpan("Summarize", status: .error)
        try writeNodeSpan("Summarize", status: .cancelled)
        try writeNodeSpan("Summarize", status: .cancelled)

        let s = try XCTUnwrap(stats(for: "Summarize"))

        XCTAssertEqual(s.totalRuns, 6)
        XCTAssertEqual(s.completedCount, 3)
        XCTAssertEqual(s.failedCount, 1)
        XCTAssertEqual(s.cancelledCount, 2)
        XCTAssertEqual(try XCTUnwrap(s.successRate), 0.75, accuracy: 0.0001,
                       "3 completed of 4 attributable (6 runs − 2 Stops) = 75%, not 3/6 = 50%")
    }

    /// A node executing RIGHT NOW must not be scored as a failure.
    ///
    /// ⚠️ Reachable by simply opening the Workflow Activity panel during a run: the in-flight
    /// node's span is still `running` and inside the query window. `COUNT(*)` sweeps it into
    /// `totalRuns`, and it is in none of the completed/error buckets — so before this was
    /// subtracted too, watching your own workflow run made its nodes look like they were failing.
    /// This is the case the first draft of the fix missed while claiming the buckets were exhaustive.
    func testRunningNodeIsNotScoredAsAFailure() throws {
        try writeNodeSpan("InFlight", status: .completed)
        // An open span: no endedAt, still `running` — what the executor writes at beginSpan.
        let start = Date()
        try store.insertSpan(Span(
            spanID: UUID().uuidString,
            traceID: traceID,
            name: "node:InFlight",
            kind: .workflowNode,
            startedAt: start,
            endedAt: nil,
            status: .running
        ))

        let s = try XCTUnwrap(stats(for: "InFlight"))

        XCTAssertEqual(s.totalRuns, 2, "the in-flight run is genuinely a run")
        XCTAssertEqual(s.runningCount, 1)
        XCTAssertEqual(s.failedCount, 0)
        XCTAssertEqual(s.attributableRuns, 1, "only the finished run has reached a verdict")
        XCTAssertEqual(try XCTUnwrap(s.successRate), 1.0, accuracy: 0.0001,
                       "watching a workflow run must not make its nodes look broken")
    }

    // MARK: - The write side: SpanStatus.forNodeOutcome

    /// The mapping the executor now shares between the profile and structural paths. Before this
    /// was extracted the two disagreed — the structural path used a two-way ternary that reported
    /// cancel and skip as `.error`, which is the write half of this row's defect. Unit-testable
    /// because it is pure; the structural call site itself is a fire-and-forget `Task` inside a
    /// `defer`, which no deterministic test can observe without polling.
    func testCancelledOutcomeMapsToCancelledNotError() {
        XCTAssertEqual(SpanStatus.forNodeOutcome(.canceled), .cancelled,
                       "a Stop must never close a span `.error` — that is what counted it as a failure")
    }

    func testSkippedOutcomeMapsToSkippedNotError() {
        XCTAssertEqual(SpanStatus.forNodeOutcome(.skipped(reason: .byUser)), .skipped)
    }

    func testCompletedAndFailedOutcomesAreUnchanged() {
        XCTAssertEqual(SpanStatus.forNodeOutcome(.completed), .completed)
        XCTAssertEqual(SpanStatus.forNodeOutcome(.failed(.modelError(provider: "test", error: "boom"))), .error,
                       "a genuine failure must still be red")
    }

    /// The `completedWithWarnings` arm removed from `workflowNodeStats` was DEAD SQL, and this is
    /// the cheapest possible proof: the value is not a `SpanStatus` at all. `spans.status` is only
    /// ever written from a typed `SpanStatus` (`status.rawValue`, `TraceStore.updateSpan`), so no
    /// span row can carry it — it belongs to `TraceStatus`, on the `traces` table. Pinned so nobody
    /// reinstates the arm believing it ever matched anything.
    func testCompletedWithWarningsIsNotASpanStatus() {
        XCTAssertNil(SpanStatus(rawValue: "completedWithWarnings"),
                     "if this ever becomes a SpanStatus, workflowNodeStats must decide which bucket it belongs in")
        XCTAssertNotNil(TraceStatus(rawValue: "completedWithWarnings"),
                        "it is a TraceStatus — the two enums were conflated, which is what made the SQL look alive")
        // ⚠️ FIVE statuses can reach a span row, and `workflowNodeStats` buckets exactly these
        // five (completed / error / cancelled / skipped / running). An earlier draft asserted this
        // set under the claim that four buckets were "provably exhaustive" — which the assertion
        // itself disproved, and the missing fifth (`running`) silently scored every in-flight node
        // as a failure. If a case is ever added here, that query must grow a bucket for it or the
        // denominator quietly mis-scores it.
        XCTAssertEqual(
            Set(SpanStatus.allCases.map(\.rawValue)),
            Set(["running", "completed", "error", "skipped", "cancelled"]),
            "a new SpanStatus needs a matching bucket in workflowNodeStats — see attributableRuns"
        )
    }
}
