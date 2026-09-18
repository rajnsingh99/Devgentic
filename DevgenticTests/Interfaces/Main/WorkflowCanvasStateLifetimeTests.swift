// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowCanvasStateLifetimeTests.swift
//  DevgenticTests
//
//  Regression cover for Workflow_Production_Readiness.md row WF9.
//
//  `WorkflowDedicatedView` flips from Canvas to Execution automatically when a run starts, which
//  tears the canvas subtree down. While `WorkflowCanvasState` lived in that view's `@State`, the
//  flip destroyed every unsaved node, edge and task description — silently, with no prompt and no
//  dirty indicator — on the most natural action there is: running the workflow you were editing.
//
//  The state is now owned by `MainApplicationViewModel` (keyed by workflow profile) and injected,
//  so it outlives the view. That makes `.onAppear` fire on a canvas that is already mid-edit,
//  which is what `acceptsDiskReload` guards.
//
//  ⚠️ The ownership half is NOT covered here: constructing a `MainApplicationViewModel` claims
//  `HITLPresenter` globally and loads settings, so building one in a unit test would leak state
//  across the suite. What is covered is the rule that made reuse safe — without it, keeping the
//  state alive would simply move the data loss to the return trip.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowCanvasStateLifetimeTests: XCTestCase {

    private func dirtyState() -> WorkflowCanvasState {
        let state = WorkflowCanvasState(profileID: UUID())
        state.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        state.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "Unsaved Transform")
        return state
    }

    // MARK: - WF9

    /// A canvas with unsaved edits must refuse a reload from disk.
    func testDirtyCanvasRefusesDiskReload() {
        let state = dirtyState()

        XCTAssertTrue(state.hasUnsavedChanges, "Precondition: the edit marked the canvas dirty")
        XCTAssertFalse(state.acceptsDiskReload,
                       "A canvas re-appearing mid-edit must not be replaced from the stored layout")
    }

    /// A freshly created canvas must still load normally — otherwise the guard would leave every
    /// canvas permanently empty.
    func testFreshCanvasAcceptsDiskReload() {
        let state = WorkflowCanvasState(profileID: UUID())

        XCTAssertTrue(state.acceptsDiskReload)
    }

    /// A saved canvas accepts reloads again.
    func testCanvasAcceptsDiskReloadAgainOnceClean() {
        let state = dirtyState()
        state.markSaved()

        XCTAssertTrue(state.acceptsDiskReload)
    }

    /// This is WHAT the guard prevents: `load(from:)` replaces the canvas wholesale and clears the
    /// dirty flag. Pinned so the cost of reloading over a live edit stays visible.
    func testLoadReplacesEverythingAndClearsDirtyState() {
        let state = dirtyState()
        XCTAssertEqual(state.nodes.count, 1)

        state.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))

        XCTAssertTrue(state.nodes.isEmpty, "load() is wholesale — the in-progress edit is gone")
        XCTAssertFalse(state.hasUnsavedChanges, "…and the dirty flag it would have been protected by is cleared")
    }

    // MARK: - Cross-profile write refusal (register WF-CV1)
    //
    // `WorkflowCanvasView` used to freeze an INJECTED `WorkflowCanvasState` into `@State` via
    // `State(wrappedValue:)`, which SwiftUI honours only on the first materialisation of a view
    // identity. That identity outlives a profile change — `chatArea` stays mounted and
    // `WorkflowDedicatedView` re-renders in place — so after switching workflow in the composer
    // picker the canvas still held workflow A's state while `profile` had become B. Pressing Save
    // then wrote A's nodes to B's id, and because `WorkflowLayoutStore.save` is an in-place
    // whole-blob upsert with no history, B's saved graph was destroyed with no undo.
    //
    // The view now resolves the injected state per render, so the two ids cannot drift. These pin
    // the last line of defence: the state refuses to hand a layout to a profile it does not own.

    /// The destructive direction: a state for workflow A must not produce a layout for workflow B.
    func testStateRefusesToProduceLayoutForADifferentProfile() {
        let ownerID = UUID()
        let otherID = UUID()
        let state = WorkflowCanvasState(profileID: ownerID)
        state.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        state.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "Workflow A's node")

        XCTAssertNil(state.layout(forProfile: otherID),
                     "A canvas holding workflow A's graph must refuse to be written under workflow B's id — "
                     + "the store upsert has no history, so that write destroys B's saved graph")
    }

    /// The non-destructive direction — the refusal must not block the ordinary save, or every
    /// canvas becomes unsaveable.
    func testStateProducesLayoutForItsOwnProfile() {
        let ownerID = UUID()
        let state = WorkflowCanvasState(profileID: ownerID)
        state.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        state.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "Its own node")

        let layout = state.layout(forProfile: ownerID)

        XCTAssertNotNil(layout, "A canvas must still save under the profile it belongs to")
        XCTAssertEqual(layout?.nodes.count, 1, "…and carry the edit it was holding")
    }

    /// A refusal must leave the work intact. If the guard cleared or mutated anything, it would be
    /// trading one silent loss for another.
    func testRefusedLayoutLeavesTheCanvasUntouched() {
        let state = dirtyState()
        let nodeCountBefore = state.nodes.count

        // ⚠️ Assert the refusal itself first. Without this the rest is vacuous — if the guard
        // regressed and the layout were handed over, "nothing was mutated" would still hold and
        // this test would pass against the very defect it exists for (confirmed by mutation).
        XCTAssertNil(state.layout(forProfile: UUID()), "Precondition: the write is refused")

        XCTAssertEqual(state.nodes.count, nodeCountBefore, "The refused write must not disturb the graph")
        XCTAssertTrue(state.hasUnsavedChanges,
                      "…and the canvas must stay dirty, so the edits are still offered at the next exit point")
    }

    // MARK: - WF-CU4: the newer-version notice is scoped to the profile that produced it
    //
    // Same failure CLASS as WF9 above, one layer up: this host re-renders IN PLACE on a profile
    // switch (no `.id()` at the mount site), so view `@State` outlives the workflow it describes.
    // `newerVersionNotice` had exactly one writer and no path back to nil, so after one refused
    // save the "read-only — update Devgentic" banner followed the user onto every workflow they
    // opened next, for the rest of the session.

    private let noticeText = "This workflow was saved by a newer version of Devgentic."

    /// ⚠️ THE FILED BUG. A notice produced by workflow A must not render while workflow B is on
    /// screen — B is perfectly writable, and the banner claims otherwise.
    func testNoticeFromAnotherProfileIsNotRendered() {
        let workflowA = UUID(), workflowB = UUID()
        let stored = WorkflowCanvasView.ProfileScopedNotice(profileID: workflowA, message: noticeText)

        XCTAssertNil(
            WorkflowCanvasView.ProfileScopedNotice.message(for: stored, displayedProfileID: workflowB),
            "a notice belonging to workflow A must not appear over workflow B"
        )
    }

    /// The control that keeps the fix honest: on its OWN workflow the notice must still show.
    /// Scoping that suppressed everything would "fix" the lie by deleting a true warning — the
    /// user would edit a read-only workflow with no idea their saves are being refused.
    func testNoticeStillRendersOnTheProfileThatProducedIt() {
        let workflowA = UUID()
        let stored = WorkflowCanvasView.ProfileScopedNotice(profileID: workflowA, message: noticeText)

        XCTAssertEqual(
            WorkflowCanvasView.ProfileScopedNotice.message(for: stored, displayedProfileID: workflowA),
            noticeText
        )
    }

    /// No notice stored → nothing rendered, on any profile.
    func testNoNoticeRendersNothing() {
        XCTAssertNil(
            WorkflowCanvasView.ProfileScopedNotice.message(for: nil, displayedProfileID: UUID())
        )
    }

    /// ⚠️ Returning to the ORIGINAL workflow must bring the notice back. This is what distinguishes
    /// profile-SCOPING from clearing-on-switch: a clear would have destroyed the notice on the way
    /// out, so coming back to a workflow that is still read-only would show nothing until the user
    /// attempted another save and watched it fail.
    func testNoticeReappearsWhenReturningToItsOwnProfile() {
        let workflowA = UUID(), workflowB = UUID()
        let stored = WorkflowCanvasView.ProfileScopedNotice(profileID: workflowA, message: noticeText)

        // A → B → A, the stored value untouched throughout.
        XCTAssertEqual(WorkflowCanvasView.ProfileScopedNotice.message(for: stored, displayedProfileID: workflowA), noticeText)
        XCTAssertNil(WorkflowCanvasView.ProfileScopedNotice.message(for: stored, displayedProfileID: workflowB))
        XCTAssertEqual(WorkflowCanvasView.ProfileScopedNotice.message(for: stored, displayedProfileID: workflowA), noticeText,
                       "the notice must survive the round trip — it describes A, and A is still read-only")
    }

    // MARK: - The unreadable-canvas overlay is scoped the same way
    //
    // Same class again, and the most dangerous instance of it: this overlay carries the one control
    // in the app that deliberately destroys a graph, and that control acts on the DISPLAYED profile.
    // The overlay was left unscoped on the argument that `loadLayout()` recomputes it — untrue on
    // the `acceptsDiskReload` early-return path, so opening an unreadable workflow A and then
    // switching to a workflow B holding unsaved edits kept A's overlay, and its "Discard and Start
    // Over" button pointed at B.

    private func unreadableInfo(_ profileID: UUID) -> WorkflowCanvasView.UnreadableLayoutInfo {
        WorkflowCanvasView.UnreadableLayoutInfo(
            profileID: profileID, nodeCount: 7, edgeCount: 6, annotationCount: 1
        )
    }

    /// ⚠️ THE FILED BUG. An overlay describing workflow A must not render over workflow B — B is
    /// readable, and the Discard button under that overlay would wipe B's saved graph.
    func testUnreadableOverlayFromAnotherProfileIsNotRendered() {
        let workflowA = UUID(), workflowB = UUID()

        XCTAssertNil(
            WorkflowCanvasView.UnreadableLayoutInfo.active(unreadableInfo(workflowA), displayedProfileID: workflowB),
            "an overlay belonging to workflow A must not appear over workflow B — its Discard button targets whatever is displayed"
        )
    }

    /// The control that keeps the fix honest: on its OWN workflow the overlay must still show.
    /// Suppressing it everywhere would hide a real read failure and hand the user the empty-canvas
    /// invitation instead, inviting them to rebuild a graph whose every save is refused.
    func testUnreadableOverlayStillRendersOnTheProfileThatProducedIt() {
        let workflowA = UUID()

        let active = WorkflowCanvasView.UnreadableLayoutInfo.active(unreadableInfo(workflowA), displayedProfileID: workflowA)
        XCTAssertEqual(active, unreadableInfo(workflowA))
        XCTAssertTrue(active?.heldContent == true, "the out-of-blob counts still describe what was lost")
    }

    /// No overlay stored → nothing rendered, on any profile.
    func testNoUnreadableOverlayRendersNothing() {
        XCTAssertNil(
            WorkflowCanvasView.UnreadableLayoutInfo.active(nil, displayedProfileID: UUID())
        )
    }

    /// Returning to the unreadable workflow must bring the overlay back — scoping, not clearing.
    /// A clear-on-switch would leave the user on a genuinely unreadable canvas with no explanation
    /// and no way to repair it.
    func testUnreadableOverlayReappearsWhenReturningToItsOwnProfile() {
        let workflowA = UUID(), workflowB = UUID()
        let stored = unreadableInfo(workflowA)

        XCTAssertNotNil(WorkflowCanvasView.UnreadableLayoutInfo.active(stored, displayedProfileID: workflowA))
        XCTAssertNil(WorkflowCanvasView.UnreadableLayoutInfo.active(stored, displayedProfileID: workflowB))
        XCTAssertNotNil(WorkflowCanvasView.UnreadableLayoutInfo.active(stored, displayedProfileID: workflowA),
                        "the overlay must survive the round trip — A's stored layout is still undecodable")
    }
}
