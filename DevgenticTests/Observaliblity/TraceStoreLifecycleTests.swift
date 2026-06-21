//
//  TraceStoreLifecycleTests.swift
//  DevgenticTests
//
//  Regression coverage for the A2/A3 retention + lifecycle work:
//   • reconcileOrphanedTraces — stamp prior-session zombies, never touch live traces (Gap #13)
//   • closeOpenSpans          — close the root span without re-stamping already-closed spans (Gap #13)
//   • modelReliabilityStats   — `.failed` buckets with errors; `.cancelled` counted explicitly
//                               so running zombies stop masquerading as cancelled (Gap #1)
//

import XCTest
@testable import devgentic

final class TraceStoreLifecycleTests: XCTestCase {

    private var store: TraceStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try TraceStore(inMemory: true)
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func insertTrace(
        id: String = UUID().uuidString,
        status: TraceStatus,
        startedAt: Date,
        provider: String = "anthropic",
        modelName: String = "claude",
        conversationID: String = UUID().uuidString
    ) throws -> String {
        try store.insertTrace(TraceRecord(
            traceID: id,
            conversationID: conversationID,
            messageID: UUID().uuidString,
            profileID: UUID().uuidString,
            profileName: "Test",
            profileType: "Agent",
            provider: provider,
            modelName: modelName,
            startedAt: startedAt,
            status: status
        ))
        return id
    }

    private func makeOpenSpan(traceID: String, name: String = "root") -> Span {
        Span(spanID: UUID().uuidString, traceID: traceID, name: name, kind: .workflow)
    }

    // MARK: - reconcileOrphanedTraces (Gap #13)

    func testReconcile_stampsPriorRunningTraceAsInterrupted_andClosesItsSpans() throws {
        let launch = Date()
        let traceID = try insertTrace(status: .running, startedAt: launch.addingTimeInterval(-60))
        try store.insertSpan(makeOpenSpan(traceID: traceID))

        let count = try store.reconcileOrphanedTraces(before: launch, reason: "Interrupted")

        XCTAssertEqual(count, 1)
        let trace = try XCTUnwrap(store.fetchTrace(traceID: traceID))
        XCTAssertEqual(trace.status, .interrupted)
        XCTAssertNotNil(trace.endedAt, "A reconciled trace must be closed")
        XCTAssertEqual(trace.errorSummary, "Interrupted")

        let span = try XCTUnwrap(store.fetchSpans(forTraceID: traceID).first)
        XCTAssertEqual(span.status, .error, "An orphaned open span should be closed as .error")
        XCTAssertNotNil(span.endedAt)
    }

    func testReconcile_doesNotTouchLiveTracesStartedAfterCutoff() throws {
        // The live-trace safety guarantee: a running trace that started AFTER the launch
        // cutoff belongs to the current process and must be left untouched.
        let launch = Date()
        let liveID = try insertTrace(status: .running, startedAt: launch.addingTimeInterval(60))

        let count = try store.reconcileOrphanedTraces(before: launch, reason: "Interrupted")

        XCTAssertEqual(count, 0)
        let trace = try XCTUnwrap(store.fetchTrace(traceID: liveID))
        XCTAssertEqual(trace.status, .running, "A live trace must remain running")
        XCTAssertNil(trace.endedAt)
    }

    func testReconcile_leavesAlreadyTerminalTracesAlone() throws {
        let launch = Date()
        let doneID = try insertTrace(status: .completed, startedAt: launch.addingTimeInterval(-60))

        let count = try store.reconcileOrphanedTraces(before: launch, reason: "Interrupted")

        XCTAssertEqual(count, 0)
        XCTAssertEqual(try store.fetchTrace(traceID: doneID)?.status, .completed)
    }

    // MARK: - purgeOlderThan (Gap #5 — relies on the date-storage fix)

    func testPurgeOlderThan_deletesAgedTraces_keepsRecent() throws {
        // This silently deleted nothing before the GRDB date-strategy fix: `startedAt`
        // was stored as TEXT, and `startedAt < <Double cutoff>` is always false in SQLite.
        let now = Date()
        let oldID = try insertTrace(status: .completed, startedAt: now.addingTimeInterval(-40 * 24 * 3600))
        let newID = try insertTrace(status: .completed, startedAt: now.addingTimeInterval(-1 * 24 * 3600))

        try store.purgeOlderThan(now.addingTimeInterval(-30 * 24 * 3600))

        XCTAssertNil(try store.fetchTrace(traceID: oldID), "A 40-day-old trace should be purged")
        XCTAssertNotNil(try store.fetchTrace(traceID: newID), "A 1-day-old trace should be kept")
    }

    // MARK: - closeOpenSpans (Gap #13 root-span honesty)

    func testCloseOpenSpans_closesOnlyOpenSpans_withoutRestampingClosedOnes() throws {
        let traceID = try insertTrace(status: .running, startedAt: Date())
        // One open span (the root, never ended) and one already-completed iteration span.
        let openSpan = makeOpenSpan(traceID: traceID)
        try store.insertSpan(openSpan)
        let closedSpanID = UUID().uuidString
        try store.insertSpan(Span(spanID: closedSpanID, traceID: traceID, name: "iteration_1", kind: .iteration))
        let earlierEnd = Date(timeIntervalSinceNow: -10)
        try store.updateSpan(spanID: closedSpanID, endedAt: earlierEnd, status: .completed)

        try store.closeOpenSpans(traceID: traceID, endedAt: Date(), status: .completed)

        let byID = Dictionary(uniqueKeysWithValues: try store.fetchSpans(forTraceID: traceID).map { ($0.spanID, $0) })
        XCTAssertEqual(byID[openSpan.spanID]?.status, .completed)
        XCTAssertNotNil(byID[openSpan.spanID]?.endedAt, "The previously-open root span is now closed")
        XCTAssertEqual(byID[closedSpanID]?.endedAt?.timeIntervalSince1970 ?? 0,
                       earlierEnd.timeIntervalSince1970, accuracy: 0.01,
                       "An already-closed span must not be re-stamped")
    }

    // MARK: - modelReliabilityStats bucketing (Gap #1 stats correctness)

    func testModelReliabilityStats_bucketsFailedWithErrors_andCountsCancelledExplicitly() throws {
        let now = Date()
        // Same (provider, model) so they aggregate into a single row.
        try insertConfiguredTrace(status: .completed, startedAt: now)
        try insertConfiguredTrace(status: .error, startedAt: now)
        try insertConfiguredTrace(status: .failed, startedAt: now)
        try insertConfiguredTrace(status: .cancelled, startedAt: now)
        try insertConfiguredTrace(status: .interrupted, startedAt: now) // app died mid-run — not the model's fault
        try insertConfiguredTrace(status: .running, startedAt: now)   // zombie — must NOT count as cancelled

        let stats = try store.modelReliabilityStats(since: now.addingTimeInterval(-3600),
                                                    until: now.addingTimeInterval(60))
        let row = try XCTUnwrap(stats.first { $0.provider == "anthropic" && $0.modelName == "claude" })

        XCTAssertEqual(row.totalRuns, 6)
        XCTAssertEqual(row.completedCount, 1)
        XCTAssertEqual(row.failedCount, 2, "`.error` and `.failed` both count as failures")
        XCTAssertEqual(row.cancelledCount, 1, "Only genuine `.cancelled`; the running zombie must NOT inflate this")
        XCTAssertEqual(row.interruptedCount, 1, "App-death runs get their own bucket (audit #6)")
        XCTAssertEqual(row.successRate, 1.0 / 5.0, accuracy: 0.0001,
                       "Interrupted runs are excluded from the success-rate denominator")
    }

    // MARK: - deleteTraces removes log entries too (audit #4)

    func testDeleteTraces_alsoDeletesConversationLogEntries() throws {
        let now = Date()
        let convA = UUID().uuidString
        let traceA = try insertTrace(status: .completed, startedAt: now, conversationID: convA)
        let traceB = try insertTrace(status: .completed, startedAt: now)  // different conversation
        try store.insertLogEntries([
            LogEntry(timestamp: now, level: .error, subsystem: "t", category: "t", message: "from A", traceID: traceA),
            LogEntry(timestamp: now, level: .error, subsystem: "t", category: "t", message: "from B", traceID: traceB)
        ])

        try store.deleteTraces(forConversationID: convA)

        let remaining = try store.fetchLogEntries(since: now.addingTimeInterval(-60))
        XCTAssertEqual(remaining.count, 1, "Conversation A's log entries must die with its traces")
        XCTAssertEqual(remaining.first?.message, "from B")
        XCTAssertNil(try store.fetchTrace(traceID: traceA))
        XCTAssertNotNil(try store.fetchTrace(traceID: traceB))
    }

    // MARK: - updateSpan is end-once (audit #10)

    func testUpdateSpan_doesNotRestampAClosedSpan() throws {
        let traceID = try insertTrace(status: .running, startedAt: Date())
        let span = makeOpenSpan(traceID: traceID)
        try store.insertSpan(span)

        try store.updateSpan(spanID: span.spanID, endedAt: Date(), status: .completed)
        // A late fire-and-forget endSpan (defer Task) must not flip the recorded status.
        try store.updateSpan(spanID: span.spanID, endedAt: Date(), status: .error)

        let row = try XCTUnwrap(store.fetchSpans(forTraceID: traceID).first)
        XCTAssertEqual(row.status, .completed, "First close wins; spans end exactly once")
    }

    /// `modelReliabilityStats` JOINs `trace_configs`, so each trace needs a config row.
    private func insertConfiguredTrace(status: TraceStatus, startedAt: Date) throws {
        let id = try insertTrace(status: status, startedAt: startedAt)
        try store.saveConfigSnapshot(TraceConfigRow(
            traceID: id,
            provider: "anthropic",
            modelName: "claude",
            profileType: "Agent",
            appVersion: "1.0",
            osVersion: "15.0",
            toolsCount: 0,
            capabilitiesCount: 0,
            instructionsHash: nil,
            memoryBudgetBytes: nil,
            historyStrategy: nil,
            thinkingEnabled: false,
            snapshotJSON: "{}"
        ))
    }
}
