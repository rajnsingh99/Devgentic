// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunStatusRollupTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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

    // MARK: - The Stop path as the app actually reaches it (2026-08-23)

    /// ⚠️ THE GAP `testUserCancelIsRecordedAsCancelledNotFailed` LEFT OPEN. That test calls
    /// `handleError(cancelled: true)` directly — it proves `freeze`'s mapping and nothing about
    /// whether the app ever makes that call. It did not: a workflow Stop does not throw
    /// `CancellationError` (the executor ends its cancel arm with `continuation.finish()`, and a
    /// cancelled AsyncThrowingStream terminates rather than throws), so the consume loop exited
    /// NORMALLY into the success branch and the record froze `.failed`. `handleStreamEnd` is the
    /// seam the consumer now goes through, so this drives the real entry point.
    func testStreamEndWhileCancelledPersistsCancelled() throws {
        let state = conditionalRunState()
        state.isRunning = true
        state.nodeResults.append(result(.running, name: "Agent 3", detail: "Running..."))

        state.handleStreamEnd(finalText: "partial answer", cancelled: true)

        XCTAssertTrue(state.wasCancelled, "the stream ending on a cancelled task IS the stop signal")
        let record = freeze(state)
        XCTAssertEqual(record.status, .cancelled,
                       "the run the user stopped must not persist as Failed")
        let node = try XCTUnwrap(record.nodeResults.first { $0.profileName == "Agent 3" })
        XCTAssertEqual(node.status, .cancelled, "an interrupted node is cancelled, not failed")
        XCTAssertFalse(node.isGenuineFailure,
                       "a stopped node must not feed the 'N failed' badge or the failure roll-up")
        XCTAssertTrue(node.detail.contains("Cancelled before the node finished."),
                      "wording must say cancelled, not 'Interrupted' — got: \(node.detail)")
    }

    /// A Stop must not cost the user the output the run had already produced. The buggy path
    /// called `handleFinalOutput`, so it DID keep the text (while lying about the status); the
    /// fix must not trade one for the other.
    func testStreamEndWhileCancelledKeepsPartialOutput() {
        let state = conditionalRunState()
        state.isRunning = true

        state.handleStreamEnd(finalText: "the half-written essay", cancelled: true)

        XCTAssertEqual(freeze(state).finalOutput, "the half-written essay")
    }

    /// The control: a normal stream end is untouched by the new seam.
    func testStreamEndWithoutCancelIsUnchanged() {
        let state = conditionalRunState()
        state.isRunning = true

        state.handleStreamEnd(finalText: "done", cancelled: false)

        XCTAssertFalse(state.wasCancelled)
        XCTAssertEqual(freeze(state).status, .completed)
        XCTAssertEqual(freeze(state).finalOutput, "done")
    }

    /// [WF-RU1] A run whose FAILURE was settled (`handleError`, called by ActiveStreamManager
    /// when the engine's terminal outcome is `.failed`) must not have the failure text
    /// re-narrated as its answer at stream end: `finalText` on that path is the `.error` card's
    /// textContent. Before the fix, `finalOutput` froze as "Execution Failed: The workflow
    /// failed…" while `record.error` froze nil — the Final Outcome panel rendered the failure as
    /// ordinary markdown with a Copy chip and VoiceOver spoke it as "Output: …".
    func testStreamEndAfterRunFailureDoesNotLaunderTheErrorIntoFinalOutput() {
        let state = conditionalRunState()
        state.isRunning = true

        state.handleError("Node A: connection refused")
        state.handleStreamEnd(finalText: "Execution Failed: The workflow failed.\n\nNode A: connection refused", cancelled: false)

        XCTAssertEqual(state.finalOutput, "", "the failure text is not the run's answer")
        let record = freeze(state)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.error, "Node A: connection refused",
                       "the failure must reach record.error — the history card and Final Outcome panel key on it")
        XCTAssertEqual(record.finalOutput, "")
    }

    /// `freeze`'s force-settle is the LAST gate, reached only when `settleInFlightWork` did not
    /// run (the buffered-event race). Its default used to be `.failed` unconditionally, which
    /// re-created the whole defect one layer down: a `.failed` node satisfies `isGenuineFailure`,
    /// which rolls the RUN up as `.failed` even though `wasCancelled` said otherwise.
    func testFreezeBackstopSettlesRunningNodeAsCancelledWhenStopped() throws {
        let state = conditionalRunState()
        // Latch the cancel WITHOUT running settleInFlightWork, so the node reaches freeze `.running`.
        state.wasCancelled = true
        state.nodeResults.append(result(.running, name: "Agent 3", detail: "Running..."))

        let record = freeze(state)

        let node = try XCTUnwrap(record.nodeResults.first { $0.profileName == "Agent 3" })
        XCTAssertEqual(node.status, .cancelled)
        XCTAssertFalse(node.isGenuineFailure)
        XCTAssertEqual(record.status, .cancelled,
                       "the backstop must not manufacture a failure that overturns wasCancelled")
    }

    /// The control for the backstop: without a cancel, an unsettled node is still a failure.
    func testFreezeBackstopStillFailsRunningNodeWhenNotStopped() throws {
        let state = conditionalRunState()
        state.nodeResults.append(result(.running, name: "Agent 3", detail: "Running..."))

        let record = freeze(state)

        let node = try XCTUnwrap(record.nodeResults.first { $0.profileName == "Agent 3" })
        XCTAssertEqual(node.status, .failed)
        XCTAssertTrue(node.detail.contains("Interrupted before the node finished."))
        XCTAssertEqual(record.status, .failed)
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

    // MARK: - WF-RU4: a node failure the engine still routed to a successful terminal

    /// The engine's root-level completion gate already treats "a successful terminal exists" as
    /// non-failure for the chat bubble; `completedDespiteNodeFailure` carries that same verdict
    /// across to the persisted record so the two surfaces agree, instead of the workflow-side
    /// roll-up unconditionally reporting `.failed` whenever ANY node genuinely failed.
    func testGenuineFailureWithSuccessfulTerminalRecordsCompletedWithWarnings() {
        let state = conditionalRunState()
        state.nodeResults.append(result(.failed, name: "Publisher", detail: "Model returned an error"))
        state.completedDespiteNodeFailure = true

        XCTAssertEqual(freeze(state).status, .completedWithWarnings,
                       "a node genuinely failed but the run still reached a successful terminal")
    }

    /// The control: without the engine's signal, the exact same failed node still rolls up as
    /// plain `.failed` — the flag only ever UPGRADES the verdict, never on its own downgrades one.
    func testGenuineFailureWithoutEngineSignalStillRecordsFailed() {
        let state = conditionalRunState()
        state.nodeResults.append(result(.failed, name: "Publisher", detail: "Model returned an error"))
        XCTAssertFalse(state.completedDespiteNodeFailure, "default must be false — the safe, pre-fix behaviour")

        XCTAssertEqual(freeze(state).status, .failed)
    }

    /// `completedDespiteNodeFailure` must never MANUFACTURE a failure-flavoured status out of a
    /// clean run — it only upgrades an already-`.failed` verdict. A run with no genuine failure at
    /// all must stay plain `.completed` even if the flag is (nonsensically) set.
    func testEngineSignalWithNoGenuineFailureStaysPlainCompleted() {
        let state = conditionalRunState()
        state.completedDespiteNodeFailure = true

        XCTAssertEqual(freeze(state).status, .completed,
                       "no node failed — the flag has nothing to upgrade")
    }

    /// Cancellation still outranks everything, including this new signal — a user Stop must not
    /// be reported as a degraded success.
    func testCancelOutranksCompletedDespiteNodeFailure() {
        let state = conditionalRunState()
        state.nodeResults.append(result(.failed, name: "Publisher", detail: "Model returned an error"))
        state.completedDespiteNodeFailure = true
        state.handleError("Cancelled", cancelled: true)

        XCTAssertEqual(freeze(state).status, .cancelled)
    }
}
