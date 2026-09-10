// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WorkflowRunSettlingTests.swift
//  DevgenticTests
//
//  Regression cover for the workflow-run settling fixes of 2026-08-10
//  (Chat_Production_Readiness.md rows CH20, CH21).
//
//  The workflow-side twin of [TL-1]: nothing ever closed a workflow node or its nested tool
//  rows when a run was stopped or threw, so the frozen record claimed work was still running.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowRunSettlingTests: XCTestCase {

    private let nodeA = UUID()
    private let nodeB = UUID()

    private func executingRow(_ name: String = "execute_shell") -> TimelineEvent {
        .toolExecution(ToolExecutionData(id: UUID(), name: name, params: "{}",
                                         output: nil, isSuccess: nil, isExecuting: true))
    }

    private func runningState() -> WorkflowExecutionState {
        let state = WorkflowExecutionState()
        state.isRunning = true
        state.startedAt = Date()
        state.nodeResults = [
            WorkflowNodeResult(id: UUID(), nodeID: nodeA, profileName: "Fetcher",
                               status: .completed, detail: "done", startTime: Date(), endTime: Date()),
            WorkflowNodeResult(id: UUID(), nodeID: nodeB, profileName: "Writer",
                               status: .running, detail: "Working…", startTime: Date())
        ]
        state.nodeTimelines[nodeB] = [executingRow()]
        return state
    }

    private func freeze(_ state: WorkflowExecutionState) -> WorkflowRunRecord {
        WorkflowRunRecord.freeze(
            from: state,
            conversationID: UUID(),
            workflowProfileID: UUID(),
            workflowName: "Test Flow",
            userInput: "go",
            timestamp: state.startedAt
        )
    }

    // MARK: - CH20

    /// Stop mid-run. `handleError` used to set only `workflowError`/`isRunning`/`completedAt`,
    /// so `freeze` copied `.running` verbatim and the historical run rendered the node with a
    /// live accent spine badged "Running…" forever.
    func testCancelSettlesRunningNodeAndClosesToolRows() {
        let state = runningState()

        state.handleError("Cancelled", cancelled: true)

        let running = state.nodeResults.filter { $0.status == .running }
        XCTAssertTrue(running.isEmpty, "no node may remain running once the run has ended")

        guard let settled = state.nodeResults.first(where: { $0.nodeID == nodeB }) else {
            return XCTFail("node B missing")
        }
        // ⚠️ `.cancelled`, not `.failed` — changed 2026-08-15, and the old assertion pinned the
        // defect: a run the user stopped persisted its in-flight node as a genuine failure, so the
        // history card showed a red "1 failed" capsule beside the amber "Cancelled" pill for the
        // same run, reporting the user's own action back to them as a fault.
        XCTAssertEqual(settled.status, .cancelled)
        XCTAssertTrue(settled.detail.contains("Cancelled before the node finished."),
                      "the node must record WHY it stopped, got: \(settled.detail)")
        XCTAssertNotNil(settled.endTime, "a settled node must have an end time")

        // CH21: the node's own tool rows are closed by the same pass.
        guard case .toolExecution(let row)? = state.nodeTimelines[nodeB]?.first else {
            return XCTFail("node B timeline missing")
        }
        XCTAssertFalse(row.isExecuting, "a persisted tool row must never claim to still be executing")
        XCTAssertEqual(row.failureCategory, .cancelled)
        XCTAssertEqual(row.output, "Cancelled before the tool finished.")
    }

    /// A thrown failure uses the interrupted wording, not the cancelled one.
    func testThrownFailureUsesInterruptedWording() {
        let state = runningState()

        state.handleError("Provider exploded")

        guard let settled = state.nodeResults.first(where: { $0.nodeID == nodeB }) else {
            return XCTFail("node B missing")
        }
        XCTAssertTrue(settled.detail.contains("Interrupted before the node finished."))
        guard case .toolExecution(let row)? = state.nodeTimelines[nodeB]?.first else {
            return XCTFail("node B timeline missing")
        }
        XCTAssertNil(row.failureCategory, "failure of the RUN doesn't mean the tool was cancelled")
        XCTAssertEqual(row.output, "Interrupted before the tool finished.")
    }

    /// Control: nodes that genuinely finished are left exactly as they were.
    func testSettledNodesAreUntouched() {
        let state = runningState()
        state.handleError("Cancelled", cancelled: true)

        guard let completed = state.nodeResults.first(where: { $0.nodeID == nodeA }) else {
            return XCTFail("node A missing")
        }
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.detail, "done", "a finished node's detail must not be rewritten")
    }

    // MARK: - freeze is the last gate

    /// Even if the live state was never settled, the record that becomes permanent must not
    /// carry a `.running` node — and the run's roll-up status must reflect it.
    func testFreezeDefensivelySettlesRunningNode() {
        let state = runningState()   // deliberately NOT calling handleError
        state.completedAt = Date()

        let record = freeze(state)

        guard let snapshot = record.nodeResults.first(where: { $0.nodeID == nodeB }) else {
            return XCTFail("node B snapshot missing")
        }
        XCTAssertEqual(snapshot.status, .failed, "freeze must not persist a running node")
        XCTAssertTrue(snapshot.detail.contains("Interrupted before the node finished."))
        XCTAssertEqual(record.status, .failed,
                       "the roll-up must be derived from the settled snapshots, not the live results")

        guard case .toolExecution(let row)? = snapshot.nodeTimeline?.first else {
            return XCTFail("persisted node timeline missing")
        }
        XCTAssertFalse(row.isExecuting)
    }

    // MARK: - WF-RU10: a node's OWN failure closes its OWN live tool rows

    /// ⚠️ THE FILED BUG. `handleNodeFailed` is reached when the ENGINE reports a node failure
    /// (e.g. a compute-budget timeout mid-tool) — a path that routes to an activated `error` port
    /// and lets the RUN CONTINUE. `settleInFlightWork` (which correctly writes back) only fires
    /// from `handleError`, which this path never reaches; `freeze()`'s own close acts on a
    /// Dictionary-subscript COPY of `nodeTimelines` and never writes back either. Before this fix,
    /// the LIVE `nodeTimelines` — what `AgentTimelineView` renders while `executionState` is still
    /// attached — stayed open for the rest of the session, an indefinite spinner on a node that
    /// had already failed.
    func testNodeFailureClosesItsOwnLiveDanglingToolRows() {
        let state = runningState()

        state.handleNodeFailed(nodeID: nodeB, profileName: "Writer", error: "compute budget exceeded")

        guard case .toolExecution(let row)? = state.nodeTimelines[nodeB]?.first else {
            return XCTFail("node B's LIVE timeline must have its dangling row closed in place")
        }
        XCTAssertFalse(row.isExecuting,
                       "the row must stop claiming to execute the moment its node fails — not only once persisted")
        XCTAssertEqual(row.output, "Interrupted before the tool finished.")
    }

    /// The run then completes normally (the failure's error port was handled) — pinning that the
    /// close happens WITHOUT any run-level settle ever running, which is exactly the case
    /// `handleError`/`settleInFlightWork` cannot reach.
    func testNodeFailureFollowedByANormalRunCompletionKeepsTheRowClosed() {
        let state = runningState()

        state.handleNodeFailed(nodeID: nodeB, profileName: "Writer", error: "compute budget exceeded")
        // The run keeps going — an error-port handler answers — and ends via the NORMAL path, not
        // `handleError`. `settleInFlightWork` is never called.
        state.handleFinalOutput("recovered by the error handler")

        guard case .toolExecution(let row)? = state.nodeTimelines[nodeB]?.first else {
            return XCTFail("node B's timeline missing")
        }
        XCTAssertFalse(row.isExecuting, "the earlier failure's close must not be undone by a clean finish")
    }

    /// Control: a node with NO in-flight tool row (already settled, or never had one) must not
    /// crash or fabricate a timeline entry.
    func testNodeFailureWithNoLiveTimelineIsANoOp() {
        let state = WorkflowExecutionState()
        state.nodeResults = [
            WorkflowNodeResult(id: UUID(), nodeID: nodeA, profileName: "Fetcher",
                               status: .running, detail: "", startTime: Date())
        ]

        state.handleNodeFailed(nodeID: nodeA, profileName: "Fetcher", error: "boom")

        XCTAssertNil(state.nodeTimelines[nodeA], "no timeline existed — the close must not invent one")
        XCTAssertEqual(state.nodeResults.first?.status, .failed)
    }

    /// Control: a row that already finished on its own (a normal tool completion, not a dangling
    /// one) must not have its real output overwritten by the failure close.
    func testNodeFailureDoesNotTouchAnAlreadyClosedRow() {
        let state = runningState()
        state.nodeTimelines[nodeB] = [.toolExecution(ToolExecutionData(
            id: UUID(), name: "execute_shell", params: "{}",
            output: "actual tool output", isSuccess: true, isExecuting: false))]

        state.handleNodeFailed(nodeID: nodeB, profileName: "Writer", error: "downstream error")

        guard case .toolExecution(let row)? = state.nodeTimelines[nodeB]?.first else {
            return XCTFail("node B's timeline missing")
        }
        XCTAssertEqual(row.output, "actual tool output",
                       "a row that finished on its own must keep its real output, not the synthetic close text")
        XCTAssertEqual(row.isSuccess, true)
    }

    /// Control: a clean run still freezes as completed with its nodes intact.
    func testCleanRunFreezesAsCompleted() {
        let state = WorkflowExecutionState()
        state.startedAt = Date()
        state.completedAt = Date()
        state.nodeResults = [
            WorkflowNodeResult(id: UUID(), nodeID: nodeA, profileName: "Fetcher",
                               status: .completed, detail: "done", startTime: Date(), endTime: Date())
        ]
        state.finalOutput = "all good"

        let record = freeze(state)

        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.nodeResults.first?.status, .completed)
        XCTAssertEqual(record.nodeResults.first?.detail, "done")
    }

    // MARK: - The shared closer

    /// CH21 extracted the chat walk into `DanglingToolRowCloser` so both sides use one
    /// implementation. Its nested-card behaviour must survive the move.
    func testSharedCloserStillWalksNestedCards() {
        var plan = PlanRunData(phase: .executing, steps: [
            PlanStepData(id: "step_1", title: "Deep", status: .running)
        ])
        plan.steps[0].events = [executingRow("write_file")]
        var events: [TimelineEvent] = [executingRow("fs_read"), .planExecution(plan)]

        let closed = DanglingToolRowCloser.close(&events, outcome: .cancelled)

        XCTAssertEqual(closed, 2, "top-level row plus the one nested in the plan step")
    }
}
