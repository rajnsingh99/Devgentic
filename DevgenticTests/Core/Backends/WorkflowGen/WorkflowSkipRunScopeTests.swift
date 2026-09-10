// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowSkipRunScopeTests.swift
//  DevgenticTests
//
//  Regression cover for Workflow_Production_Readiness.md row WF-CC14 (filed 2026-08-23).
//
//  `WorkflowNodeSkipStore` was conversation-keyed on the one-root-run-per-conversation invariant
//  (§0.5), which nothing enforces on the inbound start paths — a scheduled or ChatOps run can
//  start a second root run in a conversation whose first run is still live, and a scheduled
//  re-run of the SAME workflow has IDENTICAL node IDs. Under conversation keying that meant:
//    (a) run 2's start-clear silently discarded the user's pending skip requests for run 1;
//    (b) run 2 could CONSUME a request the user aimed at run 1, skipping a node in an unattended
//        run they never touched — a silently wrong scheduled result;
//    (c) run 2's racer registration for node N collided with run 1's LIVE waiter for the same
//        key, overwriting (leaking) the continuation.
//  The store is now keyed by run token (`WorkflowRunScope.token`); these tests pin the isolation.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowSkipRunScopeTests: XCTestCase {

    private let conv = UUID()
    private let node = UUID()

    override func tearDown() {
        WorkflowNodeSkipStore.shared.clear(conversationID: conv, reason: "test teardown")
        super.tearDown()
    }

    /// [Found on adversarial audit] A raw `try await someTask.value` on a
    /// `CheckedContinuation`-backed waiter has no bound: if a future regression in run-token
    /// keying (exactly the class of defect this suite exists to catch) ever fails to resume the
    /// right waiter, the await hangs the test HOST instead of failing red. Mirrors the pattern
    /// already established elsewhere this session for the same subsystem.
    private func awaitBounded<T: Sendable>(_ task: Task<T, Error>, seconds: TimeInterval = 5) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            guard let first = try await group.next(), let result = first else {
                group.cancelAll()
                task.cancel()
                XCTFail("waiter did not resolve within \(seconds)s — the store failed to resume it")
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    /// Harms (a)+(b) in one scenario: the user marks a node of run 1; run 2 (the scheduler)
    /// starts in the same conversation. Run 2 must neither discard nor consume run 1's request —
    /// and run 1, still running, must still be able to consume it.
    func testConcurrentRunCanNeitherDiscardNorConsumeAnotherRunsRequest() {
        let store = WorkflowNodeSkipStore.shared
        let run1 = UUID(), run2 = UUID()

        store.beginRun(conversationID: conv, runToken: run1)
        store.toggle(nodeID: node, conversationID: conv)          // user targets run 1's node

        store.beginRun(conversationID: conv, runToken: run2)      // scheduler fires into the conv

        XCTAssertFalse(store.consume(nodeID: node, conversationID: conv, runToken: run2),
                       "run 2 must not consume a request the user aimed at run 1 — that skips a node in an unattended run they never touched")
        XCTAssertTrue(store.consume(nodeID: node, conversationID: conv, runToken: run1),
                      "run 1 still owns its request — the node the user asked to skip must skip")

        store.endRun(conversationID: conv, runToken: run1, reason: "test")
        store.endRun(conversationID: conv, runToken: run2, reason: "test")
    }

    /// A superseded run's LATE end must not wipe the successor's requests — under conversation
    /// keying, run 1 finishing after run 2 started cleared run 2's namespace.
    func testSupersededRunsLateEndDoesNotWipeSuccessorsRequests() {
        let store = WorkflowNodeSkipStore.shared
        let run1 = UUID(), run2 = UUID()

        store.beginRun(conversationID: conv, runToken: run1)
        store.beginRun(conversationID: conv, runToken: run2)
        store.toggle(nodeID: node, conversationID: conv)          // lands in run 2 (the active run)

        store.endRun(conversationID: conv, runToken: run1, reason: "test")   // run 1 ends late

        XCTAssertTrue(store.isRequested(nodeID: node, conversationID: conv),
                      "run 1's end must not clear run 2's request")
        XCTAssertTrue(store.consume(nodeID: node, conversationID: conv, runToken: run2))
        store.endRun(conversationID: conv, runToken: run2, reason: "test")
    }

    /// A superseded run's late end must not evict the successor's ownership either — a toggle
    /// after run 1's end must still land in run 2's namespace.
    func testSupersededRunsLateEndDoesNotReleaseSuccessorsOwnership() {
        let store = WorkflowNodeSkipStore.shared
        let run1 = UUID(), run2 = UUID()

        store.beginRun(conversationID: conv, runToken: run1)
        store.beginRun(conversationID: conv, runToken: run2)
        store.endRun(conversationID: conv, runToken: run1, reason: "test")

        store.toggle(nodeID: node, conversationID: conv)
        XCTAssertTrue(store.consume(nodeID: node, conversationID: conv, runToken: run2),
                      "ownership must survive the superseded run's release")
        store.endRun(conversationID: conv, runToken: run2, reason: "test")
    }

    /// The pre-run seam: a toggle landing before any run owns the conversation is STAGED and
    /// adopted by the next `beginRun` — the integration-test shape "request already present when
    /// dispatch reaches the node".
    func testStagedRequestIsAdoptedByTheNextRun() {
        let store = WorkflowNodeSkipStore.shared
        let run1 = UUID()

        store.toggle(nodeID: node, conversationID: conv)          // no run live — staged
        XCTAssertTrue(store.isRequested(nodeID: node, conversationID: conv),
                      "a staged request drives the button label like a live one")

        store.beginRun(conversationID: conv, runToken: run1)
        XCTAssertTrue(store.consume(nodeID: node, conversationID: conv, runToken: run1),
                      "beginRun must adopt the staged request")
        store.endRun(conversationID: conv, runToken: run1, reason: "test")
    }

    /// Harm (c): two runs of the same workflow racing on the SAME node ID. Run 2's waiter must
    /// get its own key — firing the active run's skip resolves run 2's waiter only, and run 1's
    /// waiter must survive to resolve through its own group-cancel, not leak.
    func testRunningSkipWaiterKeysAreRunScoped() async throws {
        let store = WorkflowNodeSkipStore.shared
        let run1 = UUID(), run2 = UUID()

        store.beginRun(conversationID: conv, runToken: run1)
        let waiter1 = Task { @MainActor in
            try await store.awaitRunningSkip(nodeID: node, conversationID: conv, runToken: run1)
        }
        try await Task.sleep(for: .milliseconds(50))              // let waiter1 register

        store.beginRun(conversationID: conv, runToken: run2)      // second run, same node ID
        let waiter2 = Task { @MainActor in
            try await store.awaitRunningSkip(nodeID: node, conversationID: conv, runToken: run2)
        }
        try await Task.sleep(for: .milliseconds(50))              // let waiter2 register

        // The UI fires a running-skip — it targets the ACTIVE run (run 2).
        store.requestRunningSkip(nodeID: node, conversationID: conv)

        try await awaitBounded(waiter2)                             // run 2's waiter fires
        XCTAssertTrue(store.runningSkipFired(nodeID: node, conversationID: conv, runToken: run2))
        XCTAssertFalse(store.runningSkipFired(nodeID: node, conversationID: conv, runToken: run1),
                       "run 1 must not be credited with a firing aimed at run 2")

        // Run 1's waiter is still parked (not leaked, not fired) — its node finishing cancels it.
        waiter1.cancel()
        do {
            try await waiter1.value
            XCTFail("run 1's waiter must resolve by cancellation, not by run 2's firing")
        } catch is CancellationError { /* expected */ }

        store.endRun(conversationID: conv, runToken: run1, reason: "test")
        store.endRun(conversationID: conv, runToken: run2, reason: "test")
    }
}
