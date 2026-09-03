//
//  WorkflowCanvasGeometryTests.swift
//  DevgenticTests
//
//  Register `Workflow_Production_Readiness_Fresh.md`, canvas cluster — `CVC-5` (selection outliving
//  its graph), `CVC-8` (one sticky-note resize floor) and `CVC-9` (reveal the offending node).
//
//  ⚠️ THE DRAG FLOOR IS GONE (owner decision, 2026-09-02). `CVC-6` narrowed a `max(0, …)` and
//  `CVC-10` made the preview honour it; both are now superseded — a node may be dragged to ANY
//  coordinate. The tests that pinned the floor were REPLACED, not deleted, by tests that pin its
//  absence, and `CVC-10`'s property (preview ≡ commit) outlives the rule it was written for and is
//  asserted through the real seams. ⚠️ The sticky-note RESIZE floor (`CVC-8`) is a SIZE floor and
//  is unaffected — do not remove it while tidying.
//
//  Every one of these was a DECISION buried where a test could not reach it — inside a
//  `DragGesture` closure, inside a SwiftUI view's private computed property, or inside a
//  `@MainActor` method's side effects. Each fix extracted the decision first (WF-UI5 doctrine) and
//  this file is what makes that extraction worth anything: the rules are truth-tabled directly,
//  including their boundaries, so a later "simplification" that re-inlines one of them goes red.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowCanvasGeometryTests: XCTestCase {

    private func state() -> WorkflowCanvasState {
        let s = WorkflowCanvasState(profileID: UUID())
        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        return s
    }

    private func node(at position: CGPoint) -> WorkflowNode {
        WorkflowNode(kind: .code(CodeNodeConfig()), position: position, displayName: "N")
    }

    // MARK: - CVC-5 — selection must not outlive the graph it described

    func testSelectionSurvivesAReloadThatStillContainsIt() {
        let n = node(at: CGPoint(x: 10, y: 10))
        let layout = WorkflowLayout(nodes: [n], edges: [], annotations: [])

        let surviving = WorkflowCanvasState.survivingSelection(
            node: n.id, edge: nil, annotation: nil, in: layout
        )

        XCTAssertEqual(surviving.node, n.id,
                       "a plain same-workflow reload re-reads the SAME ids — clearing outright "
                       + "would drop the user's selection on every benign remount")
    }

    func testSelectionIsDroppedWhenTheLoadedGraphDoesNotContainIt() {
        let stale = UUID()
        let layout = WorkflowLayout(nodes: [node(at: .zero)], edges: [], annotations: [])

        let surviving = WorkflowCanvasState.survivingSelection(
            node: stale, edge: nil, annotation: nil, in: layout
        )

        XCTAssertNil(surviving.node)
    }

    /// Each of the three ids is judged on its OWN membership — a surviving node must not carry a
    /// dead edge selection through with it.
    ///
    /// ⚠️ BOTH DIRECTIONS FOR ALL THREE ARMS. Testing each arm only one way left two one-token
    /// mutations green: making the EDGE arm unconditional reproduced CVC-5 for edge selections
    /// (`removeEdge` has no membership guard either, so the phantom Delete still dirties a
    /// disk-identical canvas), and pointing the ANNOTATION arm at `layout.nodes` silently dropped a
    /// sticky-note selection on every benign remount — the exact anti-goal the rule's doc names.
    func testEachSelectionKindIsJudgedIndependently() {
        let n = node(at: .zero)
        let m = node(at: CGPoint(x: 400, y: 0))
        let edge = WorkflowEdge(sourceNodeID: n.id, targetNodeID: m.id)
        let note = StickyNote(position: .zero)

        // Roles: node present, edge present, note ABSENT.
        let a = WorkflowCanvasState.survivingSelection(
            node: n.id, edge: edge.id, annotation: note.id,
            in: WorkflowLayout(nodes: [n, m], edges: [edge], annotations: [])
        )
        XCTAssertEqual(a.node, n.id)
        XCTAssertEqual(a.edge, edge.id, "edge KEEP")
        XCTAssertNil(a.annotation, "the note is not in this layout")

        // Roles SWAPPED: node absent, edge ABSENT, note present.
        let b = WorkflowCanvasState.survivingSelection(
            node: n.id, edge: edge.id, annotation: note.id,
            in: WorkflowLayout(nodes: [m], edges: [], annotations: [note])
        )
        XCTAssertNil(b.node, "the node is not in this layout")
        XCTAssertNil(b.edge, "edge DROP — the arm must not be unconditional")
        XCTAssertEqual(b.annotation, note.id, "annotation KEEP — the arm must test annotations")
    }

    /// The end-to-end shape: Revert lands on `load(from:)`, and a selection left pointing at the
    /// discarded node must not survive it.
    func testRevertWithdrawsASelectionThatTheSavedGraphDoesNotContain() {
        let s = state()
        s.markSaved()                                   // baseline: empty canvas
        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "N")
        let added = s.nodes[0].id
        s.select(nodeID: added)
        XCTAssertEqual(s.selectedNodeID, added)

        s.revert()

        XCTAssertNil(s.selectedNodeID,
                     "the node is gone, so the Delete pill must go with it — a press would delete "
                     + "nothing while dirtying a disk-identical canvas and burning Revert's one ⌘Z")
    }

    /// The counterpart that stops the fix from being an unconditional clear: reloading the SAME
    /// graph keeps the selection.
    func testAReloadOfTheSameGraphKeepsTheSelection() {
        let s = state()
        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "N")
        let added = s.nodes[0].id
        s.select(nodeID: added)

        s.load(from: WorkflowLayout(nodes: s.nodes, edges: s.edges, annotations: s.annotations))

        XCTAssertEqual(s.selectedNodeID, added)
    }

    /// The stale selection's real cost was a dirty canvas, not a cosmetic pill. Pin the whole
    /// consequence chain: after the fix, a Delete press on a freshly reverted canvas cannot happen,
    /// so the canvas stays clean and Revert keeps its one-⌘Z recovery.
    func testAStaleSelectionCanNoLongerDirtyAFreshlyLoadedCanvas() {
        let s = state()
        s.markSaved()
        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "N")
        s.select(nodeID: s.nodes[0].id)
        s.revert()
        XCTAssertFalse(s.hasUnsavedChanges)

        s.deleteSelected()

        XCTAssertFalse(s.hasUnsavedChanges,
                       "there is no selection to delete, so nothing may mark the canvas unsaved")
        XCTAssertTrue(s.canUndo, "and Revert's recovery step must still be the FIRST ⌘Z")
        s.undo()
        XCTAssertEqual(s.nodes.count, 1, "one ⌘Z brings the discarded work back")
    }

    // MARK: - The drag has NO floor (owner decision 2026-09-02, superseding CVC-6 / CVC-10)

    /// ⚠️⚠️ THE RULE, and it replaces four tests that pinned the opposite. A node may be dragged to
    /// ANY coordinate on either axis. The clamp these tests used to protect was residue — a flat
    /// `max(0, …)` in `moveNode` that `CVC-6` narrowed rather than questioned — and it contradicted
    /// the canvas three ways: panning is unbounded, `nextAvailablePosition` already PLACES nodes at
    /// negative coordinates, and being origin-conditional made it a one-way door that a node at
    /// x ≥ 0 could never pass. Reported from the field as "the canvas is infinite but this node
    /// won't go left any more".
    func testADragCommitsWhereverItLandsIncludingNegativeSpace() {
        let committed = WorkflowCanvasState.committedDragPosition(
            origin: CGPoint(x: 40, y: 300), translation: CGSize(width: -200, height: -400)
        )

        XCTAssertEqual(committed, CGPoint(x: -160, y: -100),
                       "⚠️ do NOT restore a max(0, …) here — this is the whole point of the change")
    }

    /// The axes are independent and neither is special. Stated as a grid so a floor reintroduced on
    /// ONE axis, or for one sign of origin, cannot slip through.
    func testNoOriginAndNoAxisIsTreatedSpecially() {
        for originX in [CGFloat(-310), -1, 0, 1, 40] {
            for delta in stride(from: CGFloat(-400), through: 400, by: 50) {
                let origin = CGPoint(x: originX, y: originX)
                let committed = WorkflowCanvasState.committedDragPosition(
                    origin: origin, translation: CGSize(width: delta, height: delta))

                XCTAssertEqual(committed, CGPoint(x: originX + delta, y: originX + delta),
                               "origin \(originX), delta \(delta)")
            }
        }
    }

    /// ⚠️ CVC-6's ORIGINAL DEFECT, still pinned: a flat `max(0, …)` rewrote an axis the drag never
    /// touched, teleporting a node at x = −310 by 310pt sideways on a purely vertical drag. Removing
    /// the floor makes that unrepresentable, and this test is what would catch it coming back in any
    /// form.
    func testAVerticalDragNeverMovesANodeHorizontally() {
        let committed = WorkflowCanvasState.committedDragPosition(
            origin: CGPoint(x: -310, y: 340), translation: CGSize(width: 0, height: 100)
        )

        XCTAssertEqual(committed.x, -310)
        XCTAssertEqual(committed.y, 440)
    }

    /// ⚠️ CVC-10's PROPERTY, which outlives the floor it was written for: the preview the user sees
    /// and the position the model commits must be the same point, for every origin and every
    /// translation. It is asserted through the REAL seams — the state accessor the four consumers
    /// read, and the commit function the gesture calls — so a bound applied to one and not the
    /// other fails here regardless of how either is implemented.
    func testThePreviewAndTheCommitAgreeForEveryOriginAndTranslation() {
        for originX in [CGFloat(-310), 0, 40] {
            for delta in stride(from: CGFloat(-400), through: 400, by: 50) {
                let s = state()
                let n = node(at: CGPoint(x: originX, y: originX))
                s.load(from: WorkflowLayout(nodes: [n], edges: [], annotations: []))
                let translation = CGSize(width: delta, height: delta)
                s.activeNodeDrag = (nodeID: n.id, offset: translation)

                let previewed = s.nodeDragOffset(for: n.id)
                let committed = WorkflowCanvasState.committedDragPosition(
                    origin: n.position, translation: translation)

                XCTAssertEqual(
                    CGPoint(x: n.position.x + previewed.width, y: n.position.y + previewed.height),
                    committed,
                    "origin \(originX), delta \(delta): the card must be DRAWN where it will LAND")
            }
        }
    }

    /// Sticky notes drive the same accessor with an annotation id, and must get the same answer —
    /// the arm a nodes-only implementation would miss.
    func testAStickyNoteGetsTheSameUnboundedPreview() {
        let s = state()
        s.addStickyNote(at: CGPoint(x: 30, y: 30))
        let id = s.annotations[0].id
        s.activeNodeDrag = (nodeID: id, offset: CGSize(width: -90, height: -90))

        XCTAssertEqual(s.nodeDragOffset(for: id), CGSize(width: -90, height: -90))
    }

    func testANodeThatIsNotBeingDraggedHasNoOffset() {
        let s = state()
        let n = node(at: .zero)
        s.load(from: WorkflowLayout(nodes: [n], edges: [], annotations: []))
        s.activeNodeDrag = (nodeID: UUID(), offset: CGSize(width: 40, height: 40))

        XCTAssertEqual(s.nodeDragOffset(for: n.id), .zero)
    }

    /// The premise the whole thing rests on: the app ALREADY places nodes at negative coordinates,
    /// so refusing to let the user drag one there was the inconsistency.
    func testPlacementOnAPannedCanvasCanYieldANegativeOrigin() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)
        s.addOffset(delta: CGSize(width: 700, height: 0))

        let placed = s.nextAvailablePosition()

        XCTAssertLessThan(placed.x, 0,
                          "WF-CV11 places a new node where the user is LOOKING; panning past the "
                          + "canvas origin is unbounded, so that point is legitimately negative")
    }

    // MARK: - CVC-8 — one sticky-note floor

    func testTheResizeFloorIsSharedByThePreviewAndTheModel() {
        let previewed = StickyNote.resizedSize(
            from: CGSize(width: 180, height: 120), translation: CGSize(width: -70, height: -50)
        )

        XCTAssertEqual(previewed, StickyNote.minimumSize,
                       "the preview must not draw a size the model will refuse")
    }

    /// ⚠️ The RAW size goes in and the answer is NAMED. Feeding `resizedSize`'s own output back into
    /// `resizeStickyNote` compared the subject with itself: `resizedSize` had already clamped, so
    /// the assertion held for every possible floor — including the retired 100×60 the row was filed
    /// against — and the value the comment claimed to test (110×70) was never actually produced.
    func testASizeInsideTheRetiredPreviewBandIsClampedToTheRealFloor() {
        let s = state()
        s.addStickyNote(at: CGPoint(x: 0, y: 0))
        let id = s.annotations[0].id

        // 110×70 — inside the retired 100×60 preview floor, below the real 120×80 model floor.
        s.resizeStickyNote(id, to: CGSize(width: 110, height: 70))

        XCTAssertEqual(s.annotations[0].size, CGSize(width: 120, height: 80))
    }

    /// The property the row is actually about — but stated so it can FAIL. Feeding `resizedSize`'s
    /// own output into `resizeStickyNote` proves only idempotence, and holds for every floor value;
    /// that was the first attempt and it was vacuous. Here the preview is computed by the shared
    /// function while the expected commit is computed from LITERAL floors, so a floor change on
    /// either side breaks it.
    func testThePreviewAndTheCommittedSizeAgreeForEveryTranslation() {
        for delta in stride(from: CGFloat(-200), through: 200, by: 25) {
            let s = state()
            s.addStickyNote(at: .zero)
            let id = s.annotations[0].id
            let base = s.annotations[0].size          // the 180×120 default

            let previewed = StickyNote.resizedSize(
                from: base, translation: CGSize(width: delta, height: delta)
            )
            s.resizeStickyNote(id, to: previewed)

            let expected = CGSize(width: max(120, 180 + delta), height: max(80, 120 + delta))
            XCTAssertEqual(previewed, expected,
                           "delta \(delta): the drag must PREVIEW the 120×80-floored size")
            XCTAssertEqual(s.annotations[0].size, expected,
                           "delta \(delta): …and the note must keep exactly that size")
        }
    }

    /// End-to-end coverage for the OTHER two arms of the prune — `survivingSelection` is truth-tabled
    /// directly, but its impure caller was only ever exercised for `selectedNodeID`, so an edge or
    /// annotation selection surviving a load had no test anywhere.
    func testRevertWithdrawsAStaleEdgeSelection() {
        let s = state()
        s.markSaved()                                   // baseline: empty canvas
        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "A")
        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "B")
        XCTAssertTrue(s.addEdge(sourceNodeID: s.nodes[0].id, targetNodeID: s.nodes[1].id))
        s.select(edgeID: s.edges[0].id)

        s.revert()

        XCTAssertNil(s.selectedEdgeID,
                     "the edge is gone, so the Delete pill must go with it — `removeEdge` has no "
                     + "membership guard either, so a press would dirty a disk-identical canvas")
    }

    func testRevertWithdrawsAStaleAnnotationSelection() {
        let s = state()
        s.markSaved()
        s.addStickyNote(at: CGPoint(x: 10, y: 10))      // `addStickyNote` also selects it
        XCTAssertNotNil(s.selectedAnnotationID)

        s.revert()

        XCTAssertNil(s.selectedAnnotationID)
    }

    /// …and the KEEP direction end to end, so the prune cannot become an unconditional clear.
    func testAReloadOfTheSameGraphKeepsAnEdgeAndAnnotationSelection() {
        let s = state()
        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "A")
        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "B")
        XCTAssertTrue(s.addEdge(sourceNodeID: s.nodes[0].id, targetNodeID: s.nodes[1].id))
        s.addStickyNote(at: CGPoint(x: 10, y: 10))
        let edgeID = s.edges[0].id
        let noteID = s.annotations[0].id

        s.select(edgeID: edgeID)
        s.load(from: WorkflowLayout(nodes: s.nodes, edges: s.edges, annotations: s.annotations))
        XCTAssertEqual(s.selectedEdgeID, edgeID)

        s.select(annotationID: noteID)
        s.load(from: WorkflowLayout(nodes: s.nodes, edges: s.edges, annotations: s.annotations))
        XCTAssertEqual(s.selectedAnnotationID, noteID)
    }

    /// The model boundary must keep clamping, because a sub-floor size can still arrive from a
    /// decoded layout — `StickyNote.init(from:)` has no clamp.
    func testTheModelStillClampsASubFloorSizeFromAnyOtherCaller() {
        let s = state()
        s.addStickyNote(at: .zero)
        let id = s.annotations[0].id

        s.resizeStickyNote(id, to: CGSize(width: 10, height: 10))

        XCTAssertEqual(s.annotations[0].size, StickyNote.minimumSize)
    }

    /// Unifying on the HIGHER floor must not change any committed size: `max(120, max(100, x))`
    /// was always `max(120, x)`. Pin it so nobody "simplifies" the floor downward.
    func testUnifyingTheFloorChangedNoCommittedSize() {
        for delta in stride(from: CGFloat(-200), through: 200, by: 10) {
            let base = CGSize(width: 180, height: 120)
            let unified = StickyNote.resizedSize(
                from: base, translation: CGSize(width: delta, height: delta)
            )
            let legacyPreview = CGSize(width: max(100, base.width + delta),
                                       height: max(60, base.height + delta))
            let legacyCommitted = CGSize(width: max(120, legacyPreview.width),
                                         height: max(80, legacyPreview.height))
            XCTAssertEqual(unified, legacyCommitted, "delta \(delta)")
        }
    }

    // MARK: - CVC-9 — reveal the offending node

    /// The algebra, verified by round-trip rather than by restating it: installing the returned
    /// offset must put the requested point exactly at `visibleCanvasCenter`.
    func testOffsetToCentreRoundTripsThroughVisibleCanvasCenter() throws {
        let target = CGPoint(x: -420, y: 1310)

        for (scale, startOffset) in [(CGFloat(1.0), CGSize.zero),
                                     (CGFloat(0.4), CGSize(width: -300, height: 120)),
                                     (CGFloat(2.0), CGSize(width: 640, height: -75))] {
            let s = state()
            s.viewportSize = CGSize(width: 1000, height: 800)
            s.canvasScale = scale
            s.addOffset(delta: startOffset)

            let computed = try XCTUnwrap(s.offsetToCentre(on: target))
            s.addOffset(delta: CGSize(width: computed.width - s.canvasOffset.width,
                                      height: computed.height - s.canvasOffset.height))

            XCTAssertEqual(s.visibleCanvasCenter.x, target.x, accuracy: 0.001, "scale \(scale)")
            XCTAssertEqual(s.visibleCanvasCenter.y, target.y, accuracy: 0.001, "scale \(scale)")
        }
    }

    /// ⚠️ Must NOT inherit `visibleCanvasCenter`'s (400, 300) fallback: that would compute a pan off
    /// a zero viewport and then PERSIST it, mis-framing the canvas once real layout arrives.
    func testOffsetToCentreRefusesBeforeFirstLayout() {
        let s = state()
        s.viewportSize = .zero

        XCTAssertNil(s.offsetToCentre(on: CGPoint(x: 100, y: 100)))
    }

    func testRevealMovesTheCanvasToAnOffScreenNode() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)
        s.load(from: WorkflowLayout(
            nodes: [node(at: CGPoint(x: 5000, y: 4000))], edges: [], annotations: []
        ))
        let id = s.nodes[0].id

        XCTAssertTrue(s.revealNode(id))

        XCTAssertTrue(s.visibleCanvasRect.contains(
            CGRect(origin: CGPoint(x: 5000, y: 4000),
                   size: WorkflowCanvasState.nodeSize(for: s.nodes[0].kind))
        ), "the node must end up wholly on screen")
    }

    /// Conditional, not unconditional — walking a list of issues on a small graph must not re-frame
    /// the canvas on every tap.
    func testRevealIsANoOpForANodeAlreadyComfortablyOnScreen() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)
        s.load(from: WorkflowLayout(
            nodes: [node(at: CGPoint(x: 400, y: 350))], edges: [], annotations: []
        ))
        let before = s.canvasOffset

        XCTAssertFalse(s.revealNode(s.nodes[0].id))

        XCTAssertEqual(s.canvasOffset, before, "the frame must not move")
    }

    /// The margin is the whole reason a "technically inside the frame" node still reveals: the
    /// canvas is `.clipped()`, so a node flush to the edge has its ports and selection ring sliced
    /// off.
    ///
    /// ⚠️ ABSOLUTE coordinates, deliberately. Deriving the probe points FROM `revealMargin` pins
    /// only the relationship, and a mutation that set the margin to 0 sailed through such a test —
    /// exactly the silent radius inflation (`edgeDragAbortRadius` 24 → 50) the constant's own doc
    /// cites as its reason to be named. With the viewport at 0…1000 × 0…800, scale 1 and no pan, a
    /// node origin of x = 10 must reveal and x = 40 must not, which brackets the margin in
    /// (10, 40] from behaviour alone.
    func testRevealMarginBoundaryIsPinnedByAbsolutePosition() {
        for (originX, expectMove) in [(CGFloat(10), true), (CGFloat(40), false)] {
            let s = state()
            s.viewportSize = CGSize(width: 1000, height: 800)
            s.load(from: WorkflowLayout(
                nodes: [node(at: CGPoint(x: originX, y: 400))], edges: [], annotations: []
            ))
            XCTAssertEqual(s.revealNode(s.nodes[0].id), expectMove,
                           "a node origin at x=\(originX) in a 1000×800 viewport at scale 1")
        }
    }

    /// ⚠️ The SAME boundary on the Y axis. Probing only X left `insetBy(dx: inset, dy: 0)` green:
    /// a node flush to the bottom of the pane — ports and selection ring sliced off by the canvas
    /// `.clipped()`, which is the entire reason the margin exists — was judged comfortably visible.
    /// A code node is 220×100, so y = 10 straddles the top inset and y = 40 clears it.
    func testRevealMarginAppliesToTheVerticalAxisToo() {
        for (originY, expectMove) in [(CGFloat(10), true), (CGFloat(40), false)] {
            let s = state()
            s.viewportSize = CGSize(width: 1000, height: 800)
            s.load(from: WorkflowLayout(
                nodes: [node(at: CGPoint(x: 400, y: originY))], edges: [], annotations: []
            ))
            XCTAssertEqual(s.revealNode(s.nodes[0].id), expectMove,
                           "a node origin at y=\(originY) in a 1000×800 viewport at scale 1")
        }
    }

    /// ⚠️ The WHOLE node must be inside, not just its origin. Every other probe puts the node's far
    /// edge well inside the viewport, so `contains(rect)` → `contains(rect.origin)` was a free
    /// mutation — and it would have left CVC-9's symptom in place for every node overhanging the
    /// right or bottom edge, which is the common way a node ends up half off-screen.
    func testRevealAccountsForTheWholeNodeNotJustItsOrigin() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)
        // Origin (900, 400) is comfortably inside; the card is 220 wide, so 120pt hangs off the
        // right edge of a 1000pt viewport.
        s.load(from: WorkflowLayout(
            nodes: [node(at: CGPoint(x: 900, y: 400))], edges: [], annotations: []
        ))

        XCTAssertTrue(s.revealNode(s.nodes[0].id),
                      "the node's origin is on screen but the card is not — it must still reveal")
    }

    /// ⚠️ The node's SIZE must come from its KIND. Every other reveal probe uses a `.code` node
    /// (220×100), so `Self.nodeSize(for: node.kind)` was pinned for exactly one kind and could have
    /// been replaced by a constant. A `.trigger` is 120×50 — half the width — so at the same origin
    /// it clears the right edge that the code node overhangs.
    func testRevealSizesTheNodeByItsKind() {
        for (kind, expectMove) in [(WorkflowNodeKind.code(CodeNodeConfig()), true),
                                   (WorkflowNodeKind.trigger(TriggerNodeConfig()), false)] {
            let s = state()
            s.viewportSize = CGSize(width: 1000, height: 800)
            s.load(from: WorkflowLayout(
                nodes: [WorkflowNode(kind: kind, position: CGPoint(x: 830, y: 400), displayName: "N")],
                edges: [], annotations: []
            ))
            let size = WorkflowCanvasState.nodeSize(for: kind)

            XCTAssertEqual(s.revealNode(s.nodes[0].id), expectMove,
                           "a \(size.width)×\(size.height) node at x=830 in a 1000pt viewport")
        }
    }

    /// The SEMANTICS the absolute test cannot state: the margin is measured in SCREEN points, so it
    /// must be converted to canvas points before it is compared with a canvas-space rect.
    ///
    /// ⚠️ Both directions, deliberately. A one-sided "it reveals" assertion cannot see a missing
    /// `/ canvasScale`, because dropping the divisor only ever makes the inset LARGER and the
    /// reveal MORE eager — the assertion passes either way. The pair below brackets it: at scale 2
    /// the viewport spans 250…750 in canvas points, and 24 screen points is 12 canvas points, so
    /// x = 256 must reveal (it is inside the 12pt margin) while x = 268 must not (it clears 12 but
    /// not the undivided 24).
    func testRevealMarginIsConvertedFromScreenPointsToCanvasPoints() {
        for (originX, expectMove) in [(CGFloat(256), true), (CGFloat(268), false)] {
            let s = state()
            s.viewportSize = CGSize(width: 1000, height: 800)
            s.canvasScale = 2.0
            s.load(from: WorkflowLayout(
                nodes: [node(at: CGPoint(x: originX, y: 400))], edges: [], annotations: []
            ))

            XCTAssertEqual(s.revealNode(s.nodes[0].id), expectMove,
                           "a node origin at x=\(originX) at scale 2 — the visible canvas rect is "
                           + "250…750 and the margin is 24 screen points, i.e. 12 canvas points")
        }
    }

    /// A reveal must leave the pan anchor consistent, or the very next one-finger drag snaps the
    /// canvas back by the reveal's whole distance.
    func testRevealKeepsThePanAnchorInSync() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)
        s.load(from: WorkflowLayout(
            nodes: [node(at: CGPoint(x: 5000, y: 0))], edges: [], annotations: []
        ))
        s.revealNode(s.nodes[0].id)
        let afterReveal = s.canvasOffset

        s.updateOffset(by: CGSize(width: 10, height: 0))

        XCTAssertEqual(s.canvasOffset.width, afterReveal.width + 10, accuracy: 0.001,
                       "a following pan must continue from where the reveal left the canvas")
    }

    func testRevealOfAnAbsentNodeChangesNothing() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)
        let before = s.canvasOffset

        XCTAssertFalse(s.revealNode(UUID()))

        XCTAssertEqual(s.canvasOffset, before)
    }

    func testRevealBeforeFirstLayoutChangesNothing() {
        let s = state()
        s.viewportSize = .zero
        s.load(from: WorkflowLayout(
            nodes: [node(at: CGPoint(x: 5000, y: 0))], edges: [], annotations: []
        ))

        XCTAssertFalse(s.revealNode(s.nodes[0].id))

        XCTAssertEqual(s.canvasOffset, .zero)
    }
}
