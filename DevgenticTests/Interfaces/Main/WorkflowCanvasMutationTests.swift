//
//  WorkflowCanvasMutationTests.swift
//  DevgenticTests
//
//  Register WF-CV5, WF-CV7, WF-CV10 — the canvas's mutation invariants.
//
//  These guards were all present and correct but ENTIRELY UNTESTED, so a regression in `addEdge`'s
//  ordering or in the cycle predicate would ship silently: the user's first symptom is a workflow
//  that saves fine and then refuses to run forever with `cycleDetected`, or a delete that leaves
//  invisible dangling edges the validation panel is structurally unable to report.
//
//  Also covers the two things added 2026-08-15: the typed edge refusal (previously every rejection
//  was a bare `return false` — no dialog, no log, three causes indistinguishable) and the undo stack
//  (previously the only route back from an accidental delete was Revert, which discards every other
//  unsaved edit too).
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowCanvasMutationTests: XCTestCase {

    private func state() -> WorkflowCanvasState {
        let s = WorkflowCanvasState(profileID: UUID())
        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        return s
    }

    /// Adds `count` code nodes and returns their ids in order.
    @discardableResult
    private func addNodes(_ s: WorkflowCanvasState, _ count: Int) -> [UUID] {
        for i in 0..<count {
            s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "N\(i)")
        }
        return s.nodes.map(\.id)
    }

    // MARK: - addEdge guards (WF-CV5 / WF-CV10)

    func testSelfLoopIsRefused() {
        let s = state()
        let ids = addNodes(s, 1)

        XCTAssertEqual(s.edgeRefusalReason(sourceNodeID: ids[0], targetNodeID: ids[0]), .selfLoop)
        XCTAssertFalse(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[0]))
        XCTAssertTrue(s.edges.isEmpty, "the refusal must not leave a partial edge behind")
        XCTAssertEqual(s.lastEdgeRefusal, .selfLoop, "the reason must be recorded so the canvas can show it")
    }

    func testDuplicateEdgeFromTheSamePortIsRefused() {
        let s = state()
        let ids = addNodes(s, 2)
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1]))

        XCTAssertFalse(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1]))
        XCTAssertEqual(s.lastEdgeRefusal, .duplicate)
        XCTAssertEqual(s.edges.count, 1)
    }

    /// The same pair from a DIFFERENT port is a different connection and must be allowed — this is
    /// the finaliser pattern (default + `error` both reaching one node).
    func testSamePairFromADifferentPortIsAllowed() {
        let s = state()
        let ids = addNodes(s, 2)
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1], sourcePortLabel: nil))

        XCTAssertTrue(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1], sourcePortLabel: "error"))
        XCTAssertEqual(s.edges.count, 2)
        XCTAssertNil(s.lastEdgeRefusal)
    }

    func testEdgeToAMissingNodeIsRefused() {
        let s = state()
        let ids = addNodes(s, 1)

        XCTAssertFalse(s.addEdge(sourceNodeID: ids[0], targetNodeID: UUID()))
        XCTAssertEqual(s.lastEdgeRefusal, .missingNode)
        XCTAssertTrue(s.edges.isEmpty)
    }

    /// ⚠️ The MULTI-HOP back edge — the case the existing executor tests do not reach (they cover
    /// only the trivial self-loop). A→B→C→D then D→A must be refused, or the graph saves fine and
    /// then fails at run time with `cycleDetected` forever.
    func testMultiHopBackEdgeIsRefusedAsACycle() {
        let s = state()
        let ids = addNodes(s, 4)
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1]))
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[1], targetNodeID: ids[2]))
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[2], targetNodeID: ids[3]))

        XCTAssertEqual(s.edgeRefusalReason(sourceNodeID: ids[3], targetNodeID: ids[0]), .wouldCreateCycle)
        XCTAssertFalse(s.addEdge(sourceNodeID: ids[3], targetNodeID: ids[0]))
        XCTAssertEqual(s.edges.count, 3, "the cycle must not be added")
        XCTAssertEqual(s.lastEdgeRefusal, .wouldCreateCycle)
    }

    /// A diamond is NOT a cycle. Without this the cycle guard could be "refuse any second path"
    /// and every test above would still pass.
    func testDiamondIsAllowed() {
        let s = state()
        let ids = addNodes(s, 4)
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1]))
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[2]))
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[1], targetNodeID: ids[3]))

        XCTAssertTrue(s.addEdge(sourceNodeID: ids[2], targetNodeID: ids[3]), "a diamond is a DAG")
        XCTAssertEqual(s.edges.count, 4)
    }

    /// The refusal reason must be a pure query — the drop-target highlight calls it for every
    /// candidate node on every drag frame.
    func testRefusalReasonDoesNotMutate() {
        let s = state()
        let ids = addNodes(s, 2)
        s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1])
        let edgesBefore = s.edges.count

        _ = s.edgeRefusalReason(sourceNodeID: ids[0], targetNodeID: ids[1])
        _ = s.edgeRefusalReason(sourceNodeID: ids[1], targetNodeID: ids[0])

        XCTAssertEqual(s.edges.count, edgesBefore)
        XCTAssertNil(s.lastEdgeRefusal, "a query must not record a refusal — only an attempt does")
    }

    // MARK: - removeNode cascade (WF-CV10)

    func testRemovingANodeTakesEveryConnectedEdge() {
        let s = state()
        let ids = addNodes(s, 3)
        s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1])
        s.addEdge(sourceNodeID: ids[1], targetNodeID: ids[2])
        XCTAssertEqual(s.edges.count, 2)

        s.removeNode(ids[1])

        XCTAssertEqual(s.nodes.count, 2)
        XCTAssertTrue(s.edges.isEmpty, "a dangling edge is invisible to the user and unreportable by validation")
    }

    /// Deleting a node must also drop the inspector bound to it, or the panel stays open editing a
    /// fabricated placeholder and every write is silently discarded.
    func testRemovingANodeClearsItsOpenInspector() {
        let s = state()
        let ids = addNodes(s, 2)
        s.targetConfigNode = s.nodes.first { $0.id == ids[0] }
        XCTAssertNotNil(s.targetConfigNode)

        s.removeNode(ids[0])

        XCTAssertNil(s.targetConfigNode)
    }

    /// …but deleting a DIFFERENT node must leave the open inspector alone.
    func testRemovingAnotherNodeLeavesTheInspectorOpen() {
        let s = state()
        let ids = addNodes(s, 2)
        s.targetConfigNode = s.nodes.first { $0.id == ids[0] }

        s.removeNode(ids[1])

        XCTAssertEqual(s.targetConfigNode?.id, ids[0])
    }

    // MARK: - Undo (WF-CV7)

    func testUndoRestoresADeletedNodeAndItsEdges() {
        let s = state()
        let ids = addNodes(s, 3)
        s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1])
        s.addEdge(sourceNodeID: ids[1], targetNodeID: ids[2])

        s.removeNode(ids[1])
        XCTAssertEqual(s.nodes.count, 2)
        XCTAssertTrue(s.edges.isEmpty)
        XCTAssertTrue(s.canUndo)

        s.undo()

        XCTAssertEqual(s.nodes.count, 3, "the node comes back")
        XCTAssertEqual(s.edges.count, 2, "and so does the wiring it took with it")
    }

    func testUndoOnAnEmptyStackIsANoOp() {
        let s = state()
        addNodes(s, 1)
        // `load` cleared the stack; the add pushed exactly one snapshot.
        s.undo()
        XCTAssertFalse(s.canUndo)
        let nodesAfter = s.nodes.count

        s.undo()

        XCTAssertEqual(s.nodes.count, nodesAfter, "a second undo must not disturb anything")
    }

    /// ⚠️ THE SAFETY INVARIANT. `load(from:)` is how a DIFFERENT profile's graph arrives, so an undo
    /// stack surviving it could splice one workflow's nodes into another's canvas — the same
    /// data-loss shape as WF-CV1.
    func testLoadClearsTheUndoStack() {
        let s = state()
        addNodes(s, 2)
        XCTAssertTrue(s.canUndo)

        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))

        XCTAssertFalse(s.canUndo, "undo must never reach across a layout load")
    }

    /// Undo must leave the canvas marked dirty — it still differs from disk, and claiming otherwise
    /// would let the quit guard wave the user past real unsaved work.
    func testUndoLeavesTheCanvasDirty() {
        let s = state()
        addNodes(s, 1)
        s.undo()

        XCTAssertTrue(s.hasUnsavedChanges)
    }

    /// The stack is bounded — a canvas session is long-lived and whole-graph snapshots are not free.
    func testUndoStackIsBounded() {
        let s = state()
        for _ in 0..<40 { s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "N") }

        var undos = 0
        while s.canUndo { s.undo(); undos += 1 }

        XCTAssertLessThanOrEqual(undos, 25, "the stack must be capped")
        XCTAssertGreaterThan(undos, 1, "…but deep enough to be useful")
    }

    func testClearCanvasIsUndoable() {
        let s = state()
        addNodes(s, 3)
        s.addEdge(sourceNodeID: s.nodes[0].id, targetNodeID: s.nodes[1].id)

        s.clearCanvas()
        XCTAssertTrue(s.nodes.isEmpty)

        s.undo()
        XCTAssertEqual(s.nodes.count, 3)
        XCTAssertEqual(s.edges.count, 1)
    }

    // MARK: - WF-CS6: moves are undoable
    //
    // ⚠️ Moves pushed NO undo snapshot, so ⌘Z after a drag popped the snapshot from before some
    // EARLIER, unrelated edit. `testUndoAfterAMoveRestoresThePosition_NotAnEarlierEdit` is the one
    // that pins the actual user-visible bug; the rest pin the properties that make it correct.
    //
    // ⚠️ The register filed the fix as "push a snapshot on drag START". That is impossible
    // (`pushUndoSnapshot()` is private) and unnecessary: `moveNode` is called ONCE from the
    // gesture's `.onEnded` — the in-flight drag lives in `activeNodeDrag` as a view-space offset —
    // so one push inside the mutator already is one undo step per drag.

    func testMoveNodeIsUndoable() throws {
        let s = state()
        let ids = addNodes(s, 1)
        let origin = s.nodes[0].position
        s.moveNode(ids[0], to: CGPoint(x: 400, y: 300))
        XCTAssertEqual(s.nodes[0].position, CGPoint(x: 400, y: 300))

        s.undo()

        // ⚠️ `XCTUnwrap`, not `s.nodes[0]`. Without the fix the undo pops the ADD instead of the
        // move, leaving the array EMPTY — a subscript would trap and abort the whole suite rather
        // than reporting a failure, hiding every other result in the run.
        let node = try XCTUnwrap(s.nodes.first(where: { $0.id == ids[0] }),
                                 "undo removed the node entirely — it popped the ADD, not the move (WF-CS6)")
        XCTAssertEqual(node.position, origin,
                       "a move must be undoable — before WF-CS6 it pushed nothing at all")
    }

    /// ⚠️ THE USER-VISIBLE BUG. Add a node, drag a different one, press ⌘Z: undo used to pop the
    /// snapshot from before the ADD, so the new node vanished while the dragged node stayed moved —
    /// the opposite of what was asked, and the added node's configuration was lost.
    func testUndoAfterAMoveRestoresThePosition_NotAnEarlierEdit() {
        let s = state()
        let first = addNodes(s, 1)[0]
        let origin = s.nodes[0].position

        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "Added")
        XCTAssertEqual(s.nodes.count, 2)

        s.moveNode(first, to: CGPoint(x: 900, y: 700))
        s.undo()

        XCTAssertEqual(s.nodes.count, 2,
                       "⌘Z after a DRAG must not delete the node added before it — that is the WF-CS6 defect")
        XCTAssertEqual(s.nodes.first(where: { $0.id == first })?.position, origin,
                       "undo must put the dragged node back where it started")
    }

    /// One drag is one undo step. If a future refactor moves the push into the gesture's
    /// `.onChanged`, this goes red — a drag would then bury the rest of the stack.
    func testOneMoveIsOneUndoStep() {
        let s = state()
        let ids = addNodes(s, 1)
        let origin = s.nodes[0].position

        s.moveNode(ids[0], to: CGPoint(x: 500, y: 500))
        s.undo()
        XCTAssertEqual(s.nodes[0].position, origin)

        s.undo()   // the add itself
        XCTAssertTrue(s.nodes.isEmpty, "exactly one step per move — the next undo must reach the ADD")
    }

    /// ⚠️ A drag released where it began, or clamped back to the canvas edge, is not an edit. It
    /// must not burn an undo slot on a step ⌘Z cannot show, nor mark the canvas unsaved and fire
    /// the quit guard for a change that never happened.
    func testAMoveToTheSamePositionPushesNoUndoStep() {
        let s = state()
        let ids = addNodes(s, 1)
        let origin = s.nodes[0].position

        s.moveNode(ids[0], to: origin)      // released where it started, or clamped to the edge

        s.undo()
        XCTAssertTrue(s.nodes.isEmpty, "no step was pushed, so ONE undo must reach the ADD directly")
        XCTAssertFalse(s.canUndo, "the stack must now be empty — the no-op move contributed nothing")
    }

    func testStickyNoteMoveResizeTextAndColourAreAllUndoable() {
        let s = state()
        s.addStickyNote(at: CGPoint(x: 10, y: 10))
        let id = s.annotations[0].id
        let origin = s.annotations[0].position
        let originalSize = s.annotations[0].size

        s.moveStickyNote(id, to: CGPoint(x: 300, y: 200))
        s.undo()
        XCTAssertEqual(s.annotations[0].position, origin, "note move must be undoable")

        s.resizeStickyNote(id, to: CGSize(width: 400, height: 300))
        s.undo()
        XCTAssertEqual(s.annotations[0].size, originalSize, "note resize must be undoable")

        s.updateStickyNoteText(id, text: "documentation the author wrote")
        s.undo()
        XCTAssertEqual(s.annotations[0].text, "", "note text must be undoable")

        s.updateStickyNoteColor(id, color: .blue)
        s.undo()
        XCTAssertNotEqual(s.annotations[0].color, .blue, "note colour must be undoable")
    }

    /// ⚠️ The view's own resize floor is 100×60 but the model's is 120×80, so every release between
    /// those two floors arrives as a genuine change yet resolves to the size the note already had.
    /// Comparing the RAW argument instead of the clamped one would push a snapshot for each.
    func testAResizeClampedToTheFloorPushesNoUndoStep() {
        let s = state()
        s.addStickyNote(at: .zero)                                    // undo step 1
        let id = s.annotations[0].id
        let originalSize = s.annotations[0].size                      // 180×120 by default

        s.resizeStickyNote(id, to: CGSize(width: 120, height: 80))    // a real change → undo step 2
        XCTAssertEqual(s.annotations[0].size, CGSize(width: 120, height: 80))

        // Anything below the model's 120×80 floor clamps to the size the note ALREADY has. The
        // view's own floor is 100×60, so every release between the two floors lands here.
        s.resizeStickyNote(id, to: CGSize(width: 50, height: 40))

        s.undo()
        XCTAssertEqual(s.annotations[0].size, originalSize,
                       "ONE undo must reach the real resize — the clamped no-op must not have pushed a step of its own")
    }

    // MARK: - Accessibility descriptions (WF-CV13)
    //
    // The canvas had NO node-level accessibility: a VoiceOver user got the card's `Text` runs as
    // loose, untraited strings with no selection state and no way to act, while connections — the
    // graph's entire content — were absent from the tree altogether. These pin the substantive part
    // of the fix, the topology readout; the traits and actions themselves need a manual VoiceOver
    // pass, as there is no a11y audit harness in the repo.

    func testNodeDescriptionNamesKindAndConnectionCounts() {
        let s = state()
        let ids = addNodes(s, 3)
        s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1])
        s.addEdge(sourceNodeID: ids[2], targetNodeID: ids[1])

        let middle = s.nodes.first { $0.id == ids[1] }!
        let description = s.accessibilityDescription(for: middle)

        XCTAssertTrue(description.contains("Code node"), "the KIND must be spoken, got: \(description)")
        XCTAssertTrue(description.contains("N1"))
        XCTAssertTrue(description.contains("2 incoming"), "topology is the point, got: \(description)")
        XCTAssertTrue(description.contains("0 outgoing"))
    }

    /// An isolated node must still say so rather than omitting the counts.
    func testUnconnectedNodeStillReportsItsConnections() {
        let s = state()
        let ids = addNodes(s, 1)
        let description = s.accessibilityDescription(for: s.nodes.first { $0.id == ids[0] }!)

        // ⚠️ WF-CU8 split this into two independently-inflected halves, so the wording changed from
        // "0 incoming, 0 outgoing connections" to "0 incoming connections, 0 outgoing connections".
        // Asserting the singular stem matches either plural form, so this pins that the COUNTS are
        // spoken without freezing English plural rules into the test.
        XCTAssertTrue(description.contains("0 incoming connection"), "got: \(description)")
        XCTAssertTrue(description.contains("0 outgoing connection"), "got: \(description)")
    }

    /// ⚠️ WF-CU8 — what IS provable here, and what is not.
    ///
    /// Localization itself is NOT provable in this repo: `Localizable.xcstrings` is `sourceLanguage:
    /// en` with one language and zero translations, so `String(localized:)` returns the key verbatim
    /// and no output assertion can tell a localized build from an unlocalized one. What IS provable
    /// is that each count is pluralized on ITS OWN value. The old code appended an English `"s"`
    /// agreeing with the SUM of both counts, so one-in/one-out read "1 incoming, 1 outgoing
    /// connections" and 1+0 read "0 outgoing connection" — wrong in English before translation even
    /// enters the picture.
    ///
    /// ⚠️ This test is also why the fix does NOT use `^[…](inflect: true)`. That was the designed
    /// approach; this test caught it returning the markup verbatim (`^[2 outgoing connection]
    /// (inflect: true)`), both with and without a matching String Catalog entry. Shipping markup
    /// that may reach a user's ears is worse than an explicit branch.
    func testEachConnectionCountIsPluralizedOnItsOwnValue() {
        let s = state()
        let ids = addNodes(s, 3)
        // N0 → N1, N0 → N2: N0 has exactly one incoming (none) and two outgoing.
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1]))
        XCTAssertTrue(s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[2]))

        let source = s.accessibilityDescription(for: s.nodes.first { $0.id == ids[0] }!)
        let sink = s.accessibilityDescription(for: s.nodes.first { $0.id == ids[1] }!)

        XCTAssertTrue(source.contains("2 outgoing connections"),
                      "a count of 2 must be plural: \(source)")
        XCTAssertTrue(sink.contains("1 incoming connection,"),
                      "a count of 1 must be SINGULAR — the old suffix agreed with the sum of both counts and could not do this per-half: \(sink)")
        XCTAssertFalse(sink.contains("1 incoming connections"),
                       "singular must not carry the plural 's': \(sink)")
        // The sink has 1 in / 0 out — the exact shape the old sum-based suffix got wrong.
        XCTAssertTrue(sink.contains("0 outgoing connections"),
                      "zero is plural in English; the old code said '0 outgoing connection' here: \(sink)")
    }

    // MARK: - WF-CU7: sticky-note accessibility
    //
    // ⚠️ ONLY THE DESCRIPTION IS TESTABLE HERE. The modifier stack itself — the collapsed element,
    // the traits, and the Select / Edit text / Delete note / Make ⟨colour⟩ actions — is SwiftUI view
    // code, and this project has no view-inspection harness, so none of it can be asserted. It needs
    // a manual VoiceOver pass (⌘F5). These tests pin the substantive half: what the note SAYS.

    func testStickyNoteDescriptionNamesItsColourAndSpeaksItsText() {
        let s = state()
        s.addStickyNote(at: .zero)
        let id = s.annotations[0].id
        s.updateStickyNoteText(id, text: "Retries are capped at 3 here")

        let description = s.accessibilityDescription(for: s.annotations[0])
        XCTAssertTrue(description.contains("Yellow"), "the colour is the note's only visual identity: \(description)")
        XCTAssertTrue(description.contains("sticky note"), "it must announce WHAT it is: \(description)")
        XCTAssertTrue(description.contains("Retries are capped at 3 here"),
                      "the text is the note's entire content and must be spoken in full: \(description)")
    }

    /// ⚠️ A new note is born EMPTY, so this is the COMMON case, not an edge case. It must say it is
    /// empty rather than speaking the on-screen placeholder, which names a pointer gesture
    /// ("Double-click to edit…") a VoiceOver user cannot perform and would masquerade as content.
    func testEmptyStickyNoteSaysItIsEmptyRatherThanSpeakingThePlaceholder() {
        let s = state()
        s.addStickyNote(at: .zero)

        let description = s.accessibilityDescription(for: s.annotations[0])
        XCTAssertTrue(description.contains("empty"), "got: \(description)")
        XCTAssertFalse(description.localizedCaseInsensitiveContains("double-click"),
                       "never speak a pointer-only instruction to a VoiceOver user: \(description)")
    }

    /// Whitespace-only text is empty to a listener, even though `text.isEmpty` is false.
    func testWhitespaceOnlyStickyNoteIsTreatedAsEmpty() {
        let s = state()
        s.addStickyNote(at: .zero)
        s.updateStickyNoteText(s.annotations[0].id, text: "   \n  ")

        XCTAssertTrue(s.accessibilityDescription(for: s.annotations[0]).contains("empty"))
    }

    /// ⚠️ `.other` DRAWS as yellow but is a tint written by a NEWER build. Speaking it as "Yellow"
    /// would state something false about persisted data, so it gets its own name.
    func testUnknownStickyColourIsNotSpokenAsTheColourItHappensToDrawAs() {
        XCTAssertEqual(WorkflowCanvasState.accessibilityColorLabel(for: .other("#123456")),
                       "Custom color")
        XCTAssertEqual(WorkflowCanvasState.accessibilityColorLabel(for: .yellow), "Yellow")
    }

    // MARK: - WF-CS9: image generation is not a workflow step
    //
    // ⚠️ PRODUCT DECISION 2026-08-16 (user): imageGen profiles are not listed in the Add Node
    // picker at all — not greyed out, not shown with an explanation. The picker filter is the
    // ergonomic half; the model guard and the validator error are the correctness half, and both
    // must survive, because a layout SAVED BEFORE this change still replays verbatim through
    // `load(from:)` with no migration.

    private func profile(_ name: String, _ type: ProfileType) -> BackendProfileModel {
        let details: ProfileDetails
        switch type {
        case .bot:      details = .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m")))
        case .agent:    details = .agent(AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m")))
        case .workflow: details = .workflow(WorkflowConfig(agentProfileIDs: []))
        case .imageGen: details = .imageGen(ImageGenConfig(
            llmConfig: ProviderConfig(apiProvider: .openAI, modelName: "gpt-image-1")))
        case .code:     details = .code(AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m")))
        }
        return BackendProfileSnapshot(id: UUID(), displayName: name, details: details)
    }

    func testTheNodePickerDoesNotOfferImageGenProfiles() {
        let bot = profile("Writer", .bot)
        let agent = profile("Researcher", .agent)
        let sub = profile("Nested", .workflow)
        let image = profile("Poster Maker", .imageGen)

        let offered = WorkflowProfilePickerView.offeredProfiles(
            from: [bot, agent, sub, image],
            excludingNodeProfileIDs: [],
            workflowProfileID: UUID()
        )

        XCTAssertFalse(offered.contains { $0.id == image.id },
                       "image generation is not a supported workflow step and must not be listed")
        XCTAssertEqual(Set(offered.map(\.id)), Set([bot.id, agent.id, sub.id]),
                       "agents, bots and sub-workflows must still be offered")
    }

    /// ⚠️ The allow-list also closes a hole nobody filed: `.code` profiles are REAL persisted rows
    /// (created the first time the Code interface opens). They passed the old filter, counted
    /// toward the picker's `availableProfiles.isEmpty` gate, and then rendered in NO section —
    /// an empty scroll view with no explanation.
    func testTheNodePickerDoesNotOfferCodeProfilesEither() {
        let code = profile("Code Session", .code)
        let bot = profile("Writer", .bot)

        let offered = WorkflowProfilePickerView.offeredProfiles(
            from: [code, bot], excludingNodeProfileIDs: [], workflowProfileID: UUID())

        XCTAssertEqual(offered.map(\.id), [bot.id],
                       "a .code profile has no section to render in — offering it produced a blank panel")
    }

    func testThePickerStillExcludesTheWorkflowItselfAndProfilesAlreadyOnTheCanvas() {
        let selfID = UUID()
        let onCanvas = profile("Already There", .bot)
        let fresh = profile("Fresh", .bot)
        let itself = BackendProfileSnapshot(id: selfID, displayName: "Me",
                                            details: .workflow(WorkflowConfig(agentProfileIDs: [])))

        let offered = WorkflowProfilePickerView.offeredProfiles(
            from: [itself, onCanvas, fresh],
            excludingNodeProfileIDs: [onCanvas.id],
            workflowProfileID: selfID
        )
        XCTAssertEqual(offered.map(\.id), [fresh.id],
                       "the pre-existing self-reference and duplicate guards must survive the allow-list")
    }

    /// The model-level backstop: even if some future path bypasses the picker, no imageGen node
    /// reaches the canvas.
    func testAddNodeRefusesAnImageGenProfileEvenIfSomethingBypassesThePicker() {
        let s = state()
        s.addNode(from: profile("Poster Maker", .imageGen))
        XCTAssertTrue(s.nodes.isEmpty, "the model must refuse it, not just the picker")

        s.addNode(from: profile("Writer", .bot))
        XCTAssertEqual(s.nodes.count, 1, "supported types must still be added")
    }

    // MARK: - WF-CU9: the inspector must not outlive the canvas
    //
    // ⚠️ ONLY THE STATE HALF IS TESTABLE. The panel itself is an AppKit `NSPanel` behind a
    // `@MainActor` singleton that needs a real window server, and `.onDisappear` is SwiftUI
    // lifecycle this project has no harness to drive. `canvasDidDisappear` exists as a separate
    // method precisely so this much can be pinned; the panel actually vanishing, the ⌘W repair
    // path, and the new Cancel button all need a manual pass.

    func testCanvasTeardownClearsTheOpenInspectorTarget() {
        let s = state()
        let ids = addNodes(s, 1)
        s.targetConfigNode = s.nodes.first { $0.id == ids[0] }
        XCTAssertNotNil(s.targetConfigNode)

        s.canvasDidDisappear(panelWasOnScreen: true)

        XCTAssertNil(s.targetConfigNode,
                     "the state outlives the view, so leaving this set claims an inspector is open with no panel behind it")
    }

    /// ⚠️ THE SUBTLE HALF. `WorkflowNode` is `Hashable` and the panel is driven by a value-compared
    /// `.onChange(of: targetConfigNode)`. If teardown leaves the node set, re-selecting the SAME
    /// node later assigns an equal value, the observer does not fire, and that node's inspector
    /// silently refuses to reopen — a stuck state with no error anywhere.
    func testTheSameNodeCanOpenItsInspectorAgainAfterATeardown() {
        let s = state()
        let ids = addNodes(s, 1)
        let node = s.nodes.first { $0.id == ids[0] }
        s.targetConfigNode = node

        s.canvasDidDisappear(panelWasOnScreen: true)
        s.targetConfigNode = node   // the user clicks the very same node again

        XCTAssertEqual(s.targetConfigNode?.id, ids[0],
                       "re-selecting the same node must be a real change from nil, not a no-op assignment of an equal value")
    }

    /// Teardown with nothing open must be silent — no log, no work.
    func testCanvasTeardownWithNoInspectorOpenIsANoOp() {
        let s = state()
        addNodes(s, 1)
        XCTAssertNil(s.targetConfigNode)

        s.canvasDidDisappear(panelWasOnScreen: false)

        XCTAssertNil(s.targetConfigNode)
        XCTAssertEqual(s.nodes.count, 1, "teardown must not touch the graph")
    }

    /// The run status folds into the node's ONE label — the badge's own element is swallowed by
    /// `children: .ignore`, so if this regressed the run readout would vanish for VoiceOver.
    func testRunStatusIsFoldedIntoTheNodeDescription() {
        let s = state()
        let ids = addNodes(s, 1)
        let node = s.nodes.first { $0.id == ids[0] }!

        let withRun = s.accessibilityDescription(for: node, runStatusLabel: "Not run")
        let withoutRun = s.accessibilityDescription(for: node)

        XCTAssertTrue(withRun.contains("Not run"))
        XCTAssertFalse(withoutRun.contains("Not run"), "no run on screen means no status in the label")
    }

    func testEdgeDescriptionNamesBothEndpointsAndThePort() {
        let s = state()
        let ids = addNodes(s, 2)
        s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1], sourcePortLabel: "error")

        let description = s.accessibilityDescription(for: s.edges[0])

        XCTAssertTrue(description.contains("N0"), "got: \(description)")
        XCTAssertTrue(description.contains("N1"), "got: \(description)")
        XCTAssertTrue(description.contains("error"), "the PORT distinguishes two edges between the same pair")
    }

    func testEdgeDescriptionCarriesTheRunOutcome() {
        let s = state()
        let ids = addNodes(s, 2)
        s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1])

        let fired = s.accessibilityDescription(for: s.edges[0], runStateSuffix: "this branch ran")
        XCTAssertTrue(fired.hasSuffix("this branch ran"))
        XCTAssertFalse(s.accessibilityDescription(for: s.edges[0]).contains("branch"))
    }

    /// A dangling endpoint must degrade to words, never to a raw UUID or a crash.
    func testEdgeDescriptionSurvivesAMissingEndpoint() {
        let s = state()
        let ids = addNodes(s, 2)
        s.addEdge(sourceNodeID: ids[0], targetNodeID: ids[1])
        let edge = s.edges[0]
        s.nodes.removeAll { $0.id == ids[1] }

        let description = s.accessibilityDescription(for: edge)
        XCTAssertTrue(description.contains("unknown node"), "got: \(description)")
    }

    // MARK: - Viewport-aware placement (WF-CV11)
    //
    // `nextAvailablePosition()` was `(60, 80 + count × 120)` — pure node count in unpanned canvas
    // coordinates. Panned away from the origin, Add Node landed the node off-screen (the button
    // looked broken); after a delete, the count collided and a new node could land exactly on top
    // of an existing one.

    /// The transform inversion, stated as numbers. The view applies `scaleEffect(anchor: .center)`
    /// then `.offset`, so the visible centre is `viewport/2 − offset/scale` — if the view's
    /// transform order changes, this test is what notices.
    func testVisibleCenterInvertsPanAndZoom() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)

        XCTAssertEqual(s.visibleCanvasCenter, CGPoint(x: 500, y: 400), "no pan: the centre is the centre")

        s.updateOffset(by: CGSize(width: -500, height: -200))
        XCTAssertEqual(s.visibleCanvasCenter, CGPoint(x: 1000, y: 600), "panning left shows content further right")

        s.updateScale(by: 2.0)
        XCTAssertEqual(s.visibleCanvasCenter, CGPoint(x: 750, y: 500), "zoomed in, the same offset spans half the canvas distance")
    }

    func testVisibleCenterFallsBackBeforeFirstLayout() {
        let s = state()
        XCTAssertEqual(s.visibleCanvasCenter, CGPoint(x: 400, y: 300),
                       "headless / pre-layout must not compute a centre off a zero viewport")
    }

    /// The first node lands centred in the viewport — its envelope's centre AT the visible centre.
    func testFirstNodeIsCentredInTheViewport() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)

        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "First")

        // envelope 220x120 -> top-left = centre - (110, 60)
        XCTAssertEqual(s.nodes[0].position, CGPoint(x: 390, y: 340))
    }

    /// ⚠️ THE FINDING: after panning, a new node must land where the user is LOOKING.
    func testPlacementFollowsThePan() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)
        s.updateOffset(by: CGSize(width: -2000, height: -1000))

        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "Far")

        let node = s.nodes[0]
        // Visible canvas region is [2000, 3000] x [1000, 1800]; the node must be inside it.
        XCTAssertTrue((2000...3000).contains(node.position.x), "landed at x=\(node.position.x) — off-screen")
        XCTAssertTrue((1000...1800).contains(node.position.y), "landed at y=\(node.position.y) — off-screen")
    }

    /// Successive adds must not stack — the second node probes to a free slot.
    func testSuccessiveAddsDoNotOverlap() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)

        for i in 0..<4 {
            s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "N\(i)")
        }

        let frames = s.nodes.map { CGRect(origin: $0.position, size: WorkflowCanvasState.nodeSize(for: $0.kind)) }
        for a in frames.indices {
            for b in frames.indices where a < b {
                XCTAssertFalse(frames[a].intersects(frames[b]),
                               "nodes \(a) and \(b) overlap: \(frames[a]) vs \(frames[b])")
            }
        }
    }

    /// A sticky note is an obstacle too — a new node must not be dropped on top of one.
    func testPlacementAvoidsStickyNotes() {
        let s = state()
        s.viewportSize = CGSize(width: 1000, height: 800)
        // A note square on the ideal first slot.
        s.addStickyNote(at: CGPoint(x: 390, y: 340))

        s.addStructuralNode(kind: .code(CodeNodeConfig()), displayName: "Dodger")

        let node = CGRect(origin: s.nodes[0].position, size: WorkflowCanvasState.nodeSize(for: s.nodes[0].kind))
        let note = CGRect(origin: s.annotations[0].position, size: s.annotations[0].size)
        XCTAssertFalse(node.intersects(note))
    }

    // MARK: - Revert / Discard Changes (WF-CV7 follow-up)
    //
    // Revert (now "Discard Changes") is the DOCUMENT-level escape — back to the last save in one
    // action — as against undo's one-edit-at-a-time. It used to be the only unrecoverable control
    // on the canvas: `load(from:)` clears the undo stack, so tapping it when you meant Undo lost
    // every unsaved edit AND the history that could have rescued them.

    /// The discarded state must be one Undo away.
    func testRevertIsUndoable() {
        let s = state()
        s.markSaved() // baseline: empty canvas
        addNodes(s, 2)
        s.addEdge(sourceNodeID: s.nodes[0].id, targetNodeID: s.nodes[1].id)
        XCTAssertTrue(s.hasUnsavedChanges)

        s.revert()

        XCTAssertTrue(s.nodes.isEmpty, "back to the saved baseline")
        XCTAssertTrue(s.canUndo, "the discarded work must be recoverable")

        s.undo()

        XCTAssertEqual(s.nodes.count, 2, "the unsaved graph comes back")
        XCTAssertEqual(s.edges.count, 1)
        XCTAssertTrue(s.hasUnsavedChanges, "…and it still differs from disk")
    }

    /// A clean canvas has nothing to discard — revert must not arm a no-op Undo.
    func testRevertOnACleanCanvasIsANoOp() {
        let s = state()
        addNodes(s, 1)
        s.markSaved()
        while s.canUndo { s.undo() } // drain history from the setup edits
        // Draining rewound the graph; restore the saved shape then re-baseline.
        s.load(from: WorkflowLayout(nodes: s.nodes, edges: s.edges, annotations: s.annotations))

        s.revert()

        XCTAssertFalse(s.canUndo, "nothing was discarded, so there is nothing to undo")
    }

    /// ⚠️ The cross-profile safety rule is untouched: a plain `load` — how ANOTHER profile's graph
    /// arrives — still clears the stack. Only revert, which is same-profile by construction,
    /// re-arms it.
    func testPlainLoadStillClearsUndoAfterRevertChange() {
        let s = state()
        s.markSaved()
        addNodes(s, 1)
        s.revert()
        XCTAssertTrue(s.canUndo)

        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))

        XCTAssertFalse(s.canUndo, "undo must never reach across a layout load")
    }
}
