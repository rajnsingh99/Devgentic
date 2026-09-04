//
//  WorkflowProfileSwitchSelectionTests.swift
//  DevgenticTests
//
//  Register `Chat_Production_Readiness_Fresh.md` CF-54: switching the workflow profile kept the
//  previous workflow's node selection, so the next run opened from the new workflow's history
//  had every row collapsed and no Final Outcome panel. The view is NOT re-created on a profile
//  switch (no `.id(profileID)` at the construction site), so its `@State` survives while
//  `runHistory` re-filters; the fix gives `.onChange(of: workflowProfileID)` the same reset the
//  conversation handler has and then re-runs the live-run auto-select.
//
//  ⚠️ What is NOT covered here: the `.onChange` handler itself and the `@State` writes it makes
//  are unreachable from a unit test. What IS pinned is the decision that handler's auto-select
//  consumes — `WorkflowDedicatedView.liveRunAutoSelection` — and in particular the PROFILE
//  conjunct: after a switch from A to B, a run of A still live in this conversation must not be
//  selected into B's view, whose profile-filtered history cannot resolve its id (the same rule
//  `showsLiveRunItem`'s caller applies, XUI-3). Before this fix `autoSelectLiveRunIfNeeded` had
//  no profile conjunct at all.
//

import XCTest
@testable import devgentic

final class WorkflowProfileSwitchSelectionTests: XCTestCase {

    private let thisWorkflow = UUID()
    private let otherWorkflow = UUID()

    /// After the reset the selection is nil; this workflow's own live run comes up.
    func testNothingSelectedAndOwnRunLiveSelectsIt() {
        let runID = UUID()
        XCTAssertEqual(
            WorkflowDedicatedView.liveRunAutoSelection(
                currentSelection: nil, liveRunID: runID, liveRunIsRunning: true,
                liveRunProfileID: thisWorkflow, viewProfileID: thisWorkflow),
            .select(runID))
    }

    /// ⚠️ THE CF-54 PROFILE PIN. The user expanded a node of A, switched the picker to B while A's
    /// run is still streaming in this conversation. A's record id cannot resolve in B's filtered
    /// history — selecting it would blank the screen under a non-nil selection that then blocks
    /// every later auto-select.
    func testAnotherWorkflowsLiveRunIsNeverSelected() {
        let runID = UUID()
        XCTAssertEqual(
            WorkflowDedicatedView.liveRunAutoSelection(
                currentSelection: nil, liveRunID: runID, liveRunIsRunning: true,
                liveRunProfileID: otherWorkflow, viewProfileID: thisWorkflow),
            .liveRunBelongsToAnotherWorkflow(runID),
            "a live run of a DIFFERENT workflow must be reported, not selected")
    }

    /// A live state with no profile stamp cannot claim this view either — `begin` always stamps
    /// one, so a nil here is a malformed state, read the way the run picker's conjunct reads it.
    func testALiveRunWithNoProfileIsTreatedAsAnotherWorkflows() {
        let runID = UUID()
        XCTAssertEqual(
            WorkflowDedicatedView.liveRunAutoSelection(
                currentSelection: nil, liveRunID: runID, liveRunIsRunning: true,
                liveRunProfileID: nil, viewProfileID: thisWorkflow),
            .liveRunBelongsToAnotherWorkflow(runID))
    }

    /// An existing selection is the user's choice (an explicit back press, a historical row) and
    /// is never overridden — even by this workflow's own live run.
    func testAnExistingSelectionIsKept() {
        XCTAssertEqual(
            WorkflowDedicatedView.liveRunAutoSelection(
                currentSelection: UUID(), liveRunID: UUID(), liveRunIsRunning: true,
                liveRunProfileID: thisWorkflow, viewProfileID: thisWorkflow),
            .keep)
    }

    /// Nothing running — the history list is the right screen, whatever profile the slot's state
    /// carries. Covers both a settled state and the pristine registered-but-not-started one
    /// (`isRunning` is false for both until `handleNodeStarted`).
    func testNoLiveRunKeepsTheEmptySelection() {
        XCTAssertEqual(
            WorkflowDedicatedView.liveRunAutoSelection(
                currentSelection: nil, liveRunID: UUID(), liveRunIsRunning: false,
                liveRunProfileID: thisWorkflow, viewProfileID: thisWorkflow),
            .keep)
        XCTAssertEqual(
            WorkflowDedicatedView.liveRunAutoSelection(
                currentSelection: nil, liveRunID: UUID(), liveRunIsRunning: false,
                liveRunProfileID: otherWorkflow, viewProfileID: thisWorkflow),
            .keep, "not running — there is nothing to warn about either")
    }

    /// A running state with no record id has nothing addressable to select (the `begin` guard
    /// logs this shape; it is not expected in production).
    func testALiveRunWithoutARecordIDKeepsTheSelection() {
        XCTAssertEqual(
            WorkflowDedicatedView.liveRunAutoSelection(
                currentSelection: nil, liveRunID: nil, liveRunIsRunning: true,
                liveRunProfileID: thisWorkflow, viewProfileID: thisWorkflow),
            .keep)
    }
}
