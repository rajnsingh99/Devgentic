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
}
