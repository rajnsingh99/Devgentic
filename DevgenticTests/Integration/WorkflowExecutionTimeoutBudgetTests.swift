// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowExecutionTimeoutBudgetTests.swift
//  DevgenticTests
//
//  WF-EX9 — end-to-end regression guard for the retry-loop restructuring in
//  `executeStructuralNodeBounded`: ONE `withComputeTimeout` now wraps the WHOLE retry loop, so the
//  compute-timeout sentinel's clock is cumulative across every attempt instead of being re-armed
//  fresh inside the loop on each one. Previously a node configured "0.3s timeout, 2 retries" (3
//  attempts, `limit` = 0.9s — already sized for the whole run) got a FRESH full 0.9s window on
//  EVERY attempt, so real worst-case exposure was `outerAttempts × limit` (≈2.7s here), not
//  `limit` (0.9s) — the quadratic-in-retries shape WF-EX9 describes.
//
//  Isolated into its own file rather than appended to WorkflowExecutorIntegrationTests.swift — this
//  session's own established trap: `-only-testing:Class/Method` has silently returned zero test
//  cases for newly-added methods in that (very large, repeatedly-edited) file before. `makeInnerBotWorkflow`
//  is private there, so this file duplicates its ~6 lines inline rather than reaching across files.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowExecutionTimeoutBudgetTests: XCTestCase {

    private var mockProvider: MockWorkflowStreamProvider!
    private var traceContext: TraceContext!
    private var innerBuilders: [InnerWorkflowBuilder] = []

    override func setUp() {
        super.setUp()
        mockProvider = MockWorkflowStreamProvider()
        traceContext = TestTraceContext.make()
        innerBuilders = []
    }

    override func tearDown() {
        for builder in innerBuilders { builder.cleanup() }
        innerBuilders = []
        super.tearDown()
    }

    private func execute(_ scenario: WorkflowTestScenario, userInput: String = "Test input") async throws -> [AgentStreamEvent] {
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let stream = executor.executeWorkflow(
            userInput: userInput,
            conversationID: UUID(),
            traceContext: traceContext,
            onTraceUpdate: { _ in },
            layout: scenario.layout,
            profileMap: scenario.profileMap,
            streamProvider: mockProvider
        )
        return try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: nil)
    }

    /// ⚠️ THE REGRESSION GUARD for WF-EX9. A sub-workflow node configured with a short `hardTimeout`
    /// and several retries, whose child is ALWAYS slower than a single attempt's share of that
    /// budget, must fail once the CUMULATIVE budget is spent — not after each attempt gets its own
    /// fresh full-sized window.
    ///
    /// Measured against the bug this guards: `hardTimeout = 0.3s`, `maxNodeRetries = 2` ⇒
    /// `outerAttempts = 3`, `limit = 3 × 0.3s = 0.9s` (already sized for the WHOLE run — that part
    /// was never the bug). The child bot always takes 1s, so every individual attempt would exceed
    /// even a full fresh 0.9s window. Under the old per-attempt re-arming, all 3 attempts would each
    /// run to their own ~0.9s timeout before failing and retrying — ~2.7s total, 3 start events.
    /// Fixed: the ONE cumulative 0.9s sentinel fires during the FIRST attempt, ending the whole
    /// retry sequence immediately — ~0.9s total, exactly 1 start event, no room for a second attempt
    /// to ever begin.
    func testSubWorkflowRetry_DoesNotReArmTheTimeoutPerAttempt() async throws {
        let scenario = WorkflowTestScenario()
        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Always Slow Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let nested = scenario.addSubWorkflowNode(name: "Slow Retry Nested", workflowProfileID: inner.workflowProfileID)

        var cfg = WorkflowNodeConfig()
        cfg.hardTimeout = 0.3
        cfg.maxNodeRetries = 2
        cfg.retryDelay = 0
        scenario.setNodeConfig(cfg, for: nested)

        // Always 1s — well past a single attempt's 0.3s share, and past the WHOLE 0.9s cumulative
        // budget too, so the sentinel is guaranteed to fire mid-first-attempt either way.
        mockProvider.scriptDelayedStream(for: inner.profileID(for: innerBot)!, events: [.content("late")], milliseconds: 1000)

        let started = Date()
        let events = try await execute(scenario)
        let elapsed = Date().timeIntervalSince(started)

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events).first { $0.nodeID == nested }
        XCTAssertNotNil(failed, "the node must still fail once its cumulative budget is spent")
        XCTAssertTrue(failed?.error.localizedCaseInsensitiveContains("timeout") == true,
                      "the failure must BE the timeout — got: \(failed?.error ?? "<none>")")

        // The deterministic assertion: exactly ONE attempt ever started. Under the old re-arming
        // bug all 3 configured attempts would each get their own start event.
        let starts = WorkflowStreamCollector.nodeStartedEvents(from: events).filter { $0.nodeID == nested }
        XCTAssertEqual(starts.count, 1,
                       "only the first attempt should ever start — the cumulative budget is spent before a retry could begin, got \(starts.count) start(s)")

        // ⚠️ THE REGRESSION GUARD for the double-terminal-event bug an adversarial audit found in
        // this exact scenario: `executeStructuralNode` is non-throwing and does not bail out early on
        // its own cancellation, so when the cumulative sentinel wins the race, the "losing" attempt
        // still runs to a real result and — without the `Task.isCancelled` check in
        // `executeStructuralNodeBounded` — would ALSO call `emitStructuralTerminalEvent` for itself,
        // moments before (or after) the outer `catch` block emits its own terminal event for the same
        // node. Measured pre-fix: `.workflowNodeFailed` (from the catch) PLUS `.workflowNodeCancelled`
        // (from the losing attempt reaching the emitter) — 2 terminal events for 1 node, 1 run,
        // violating the file's own WF-EX4 "exactly one terminal event" invariant. Counts across ALL
        // FOUR terminal kinds, not just the ones this particular scenario happens to produce, so a
        // regression that shifts which SPECIFIC kind double-fires is still caught.
        let allTerminalEventsForNode =
            WorkflowStreamCollector.nodeCompletedEvents(from: events).filter { $0.nodeID == nested }.count
            + WorkflowStreamCollector.nodeFailedEvents(from: events).filter { $0.nodeID == nested }.count
            + WorkflowStreamCollector.nodeCancelledEvents(from: events).filter { $0.nodeID == nested }.count
            + WorkflowStreamCollector.nodeSkippedEvents(from: events).filter { $0.nodeID == nested }.count
        XCTAssertEqual(allTerminalEventsForNode, 1,
                       "exactly ONE terminal event (of any kind) must fire for this node — got \(allTerminalEventsForNode). A losing attempt that reaches its own result after the cumulative sentinel already won must not ALSO emit a terminal event.")

        // The corroborating wall-clock signal — loose margin, timing assertions are inherently
        // noisy, but 3 attempts at ~0.9s each (~2.7s) vs 1 attempt cut short at ~0.9s is a wide gap.
        XCTAssertLessThan(elapsed, 1.8,
                          "node took \(elapsed)s — old bug: ~2.7s (3 attempts × 0.9s each, re-armed); fixed: ~0.9s (one cumulative budget)")
    }

    /// ⚠️ Post-review correction: this is NOT a WF-EX9 discriminator — a fast, non-timeout failure
    /// never throws out of `executeStructuralNode` (it's RETURNED as a `.failed` envelope), so this
    /// scenario never touches the sentinel or the restructured `catch` blocks at all; it would pass
    /// identically against the pre-fix, per-attempt-rearmed code. It exists as a plain "did the
    /// WF-EX9 refactor accidentally break ordinary non-timeout retries" non-regression check — the
    /// returned-envelope retry-or-terminate branch sat inside the loop in both code shapes, and this
    /// confirms moving the surrounding closure boundary didn't disturb it.
    func testSubWorkflowRetry_QuickFailuresStillRetryNormally() async throws {
        let scenario = WorkflowTestScenario()
        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Flaky Bot")
        inner.save()
        innerBuilders.append(inner)
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let nested = scenario.addSubWorkflowNode(name: "Quick Retry Nested", workflowProfileID: inner.workflowProfileID)

        var cfg = WorkflowNodeConfig()
        cfg.hardTimeout = 5.0
        cfg.maxNodeRetries = 2
        cfg.retryDelay = 0
        scenario.setNodeConfig(cfg, for: nested)

        // Fails immediately, every attempt — no timeout involved at all.
        mockProvider.scriptError(for: inner.profileID(for: innerBot)!, error: NSError(domain: "test", code: 1))

        let events = try await execute(scenario)

        let starts = WorkflowStreamCollector.nodeStartedEvents(from: events).filter { $0.nodeID == nested }
        XCTAssertEqual(starts.count, 3, "3 quick, non-timeout failures must still exhaust all configured attempts — got \(starts.count)")

        let failures = WorkflowStreamCollector.nodeFailedEvents(from: events).filter { $0.nodeID == nested }
        XCTAssertEqual(failures.count, 1, "still exactly one terminal failure event, at the end — got \(failures.count)")
    }
}
