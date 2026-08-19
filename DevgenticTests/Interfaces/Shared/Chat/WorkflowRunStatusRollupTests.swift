//
//  WorkflowRunStatusRollupTests.swift
//  DevgenticTests
//
//  Regression cover for Workflow_Production_Readiness.md row WF4.
//
//  A node skipped because a Condition or Gate routed the other way never ran and nothing went
//  wrong. The run-status roll-up in `freeze` gated on the RAW `.failed` status, so every
//  conditional workflow reported every successful run as a failure, permanently, in persistence.
//
//  ⚠️ Since 2026-08-15 such a node is recorded `.skipped(reason)` rather than `.failed` with a
//  prose detail, so these tests assert the roll-up over the TYPED status. One legacy case is kept
//  deliberately: records written by older builds still carry the old shape and must still roll up
//  correctly after an upgrade.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowRunStatusRollupTests: XCTestCase {

    private func result(
        _ status: WorkflowNodeResult.Status,
        name: String,
        detail: String
    ) -> WorkflowNodeResult {
        WorkflowNodeResult(
            id: UUID(), nodeID: UUID(), profileName: name,
            status: status, detail: detail,
            startTime: Date(), endTime: Date()
        )
    }

    /// Builds the shape a Condition workflow produces: the taken branch completes, the untaken
    /// branch is recorded `.skipped(.notChosen)` — nothing failed anywhere in this run.
    private func conditionalRunState() -> WorkflowExecutionState {
        let state = WorkflowExecutionState()
        state.isRunning = false
        state.startedAt = Date()
        state.completedAt = Date()
        state.nodeResults = [
            result(.completed, name: "Classifier", detail: "route → bug"),
            result(.completed, name: "BugAgent", detail: "handled"),
            result(.skipped(.notChosen), name: "FeatureAgent", detail: NodeSkipReason.notChosen.displayText),
            result(.completed, name: "Summariser", detail: "done")
        ]
        return state
    }

    private func freeze(_ state: WorkflowExecutionState) -> WorkflowRunRecord {
        WorkflowRunRecord.freeze(
            from: state,
            conversationID: UUID(),
            workflowProfileID: UUID(),
            workflowName: "Conditional Flow",
            userInput: "go",
            timestamp: state.startedAt
        )
    }

    // MARK: - WF4

    /// The branch a Condition did NOT take must not make the run a failure.
    func testUntakenBranchDoesNotFailTheRun() {
        let record = freeze(conditionalRunState())

        XCTAssertEqual(record.status, .completed,
                       "Every node that ran succeeded — an untaken branch is not a run failure")

        // The node itself keeps its recorded shape; only the ROLL-UP changes. Anything else would
        // break the timeline's "Not run" rendering and the history card's failed/not-run split.
        let untaken = record.nodeResults.first { $0.profileName == "FeatureAgent" }
        XCTAssertEqual(untaken?.status, .skipped(.notChosen),
                       "the snapshot carries the CAUSE, not a failure with an explanatory sentence")
        XCTAssertTrue(untaken?.didNotRun == true)
        XCTAssertFalse(untaken?.isGenuineFailure == true)
    }

    /// A node that failed on its own account must still fail the run.
    func testGenuineNodeFailureStillFailsTheRun() {
        let state = conditionalRunState()
        state.nodeResults.append(result(.failed, name: "Publisher", detail: "Model returned an error"))

        let record = freeze(state)

        XCTAssertEqual(record.status, .failed,
                       "A node that genuinely failed must still fail the run")
    }

    /// A workflow-scoped error fails the run even when no individual node did.
    func testWorkflowLevelErrorStillFailsTheRun() {
        let state = conditionalRunState()
        state.workflowError = "Workflow completed but all terminal nodes failed"

        let record = freeze(state)

        XCTAssertEqual(record.status, .failed)
    }

    // MARK: - WF17: a user Stop is Cancelled, not Failed

    /// `handleError(cancelled: true)` sets `workflowError` too, so before this the frozen record
    /// could not tell a deliberate Stop from a crash and reported the user's own action as an
    /// error, permanently.
    func testUserCancelIsRecordedAsCancelledNotFailed() {
        let state = conditionalRunState()
        state.isRunning = true

        state.handleError("Cancelled", cancelled: true)

        XCTAssertTrue(state.wasCancelled)
        XCTAssertEqual(freeze(state).status, .cancelled,
                       "A run the user stopped must not be persisted as Failed")
    }

    /// The control: a genuine workflow error is still `.failed`. Without this the fix could be
    /// passing by calling everything cancelled.
    func testWorkflowErrorWithoutCancelIsStillFailed() {
        let state = conditionalRunState()
        state.handleError("Workflow completed but all terminal nodes failed", cancelled: false)

        XCTAssertFalse(state.wasCancelled)
        XCTAssertEqual(freeze(state).status, .failed)
    }

    /// Cancellation outranks a failed node: pressing Stop while a node was already failing is
    /// still a cancelled RUN, because that is what the user did.
    func testCancelOutranksAFailedNode() {
        let state = conditionalRunState()
        state.nodeResults.append(result(.failed, name: "Publisher", detail: "Model returned an error"))
        state.handleError("Cancelled", cancelled: true)

        XCTAssertEqual(freeze(state).status, .cancelled)
    }

    /// The live view must say Cancelled too — otherwise the run reads "Failed" for the whole
    /// window between pressing Stop and the record freezing.
    func testLiveDisplayDataReportsCancelled() {
        let state = conditionalRunState()
        state.isRunning = true
        state.handleError("Cancelled", cancelled: true)

        XCTAssertEqual(WorkflowRunDisplayData.from(live: state).status, .cancelled)
    }

    /// A live run that has NOT been cancelled keeps `status == nil`, so the view's derived
    /// heuristics still own the live case.
    func testLiveDisplayDataStatusIsNilWhenNotCancelled() {
        let state = conditionalRunState()
        state.isRunning = true

        XCTAssertNil(WorkflowRunDisplayData.from(live: state).status)
    }

    /// A run consisting only of upstream skips after a genuine failure still fails — the genuine
    /// one is present, so this guards against over-correcting into "skips mask real failures".
    func testCascadeAfterGenuineFailureStillFailsTheRun() {
        let state = WorkflowExecutionState()
        state.isRunning = false
        state.startedAt = Date()
        state.completedAt = Date()
        state.nodeResults = [
            result(.completed, name: "A", detail: "ok"),
            result(.failed, name: "B", detail: "Model returned an error"),
            result(.skipped(.upstreamSkipped), name: "C", detail: NodeSkipReason.upstreamSkipped.displayText),
            result(.skipped(.upstreamSkipped), name: "D", detail: NodeSkipReason.upstreamSkipped.displayText)
        ]

        XCTAssertEqual(freeze(state).status, .failed)
    }
}
