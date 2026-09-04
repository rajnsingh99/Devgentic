//
//  WorkflowRunFreezeShapeTests.swift
//  DevgenticTests
//
//  Register `Chat_Production_Readiness_Fresh.md` — CF-29, CF-31 and CF-32.
//
//  CF-29: `freeze` mapped `state.nodeResults` alone, so every node the run never reached was
//  dropped from the record and the surviving rows kept event-arrival order. `WorkflowDedicatedView`
//  swaps the live factory for the record factory the instant `finalize()` replaces the mirror row,
//  so on a Stop at step 2 of 6 the four "Waiting" rows the user was looking at vanished at that
//  instant and the run became a 2-row pipeline forever.
//
//  CF-31: `handleNodeSkipped` stores the skip SENTENCE as a user-skipped node's `detail`, while the
//  engine forwards that node's own INPUT downstream. Both factories derived a node's input preview
//  from `upstreamResults.map(\.detail)`, so the node that is RUNNING previewed the one string it is
//  guaranteed not to have received.
//
//  CF-32: the live orphan log fired on every body pass — i.e. on every streamed workflow event.
//
//  ⚠️ CF-29 and CF-31 both live on the seam between the two factories, and this repo's recorded
//  failure mode on that seam is fixing one adapter and leaving the other. Every behavioural claim
//  below is asserted on BOTH wherever both are reachable.
//
//  ⚠️ Cold-read round 3 added the third reader of that seam: the CANVAS. CF-29's synthesized rows
//  reached `WorkflowCanvasRunOverlay` — which had only ever seen the ABSENCE of a row for an
//  unreached node — and made it draw "this branch was not taken" over a run the user had merely
//  stopped. The overlay-side tests hand-build their fixtures; the two tests here walk the real
//  path (`freeze` → `from(record:)` → overlay), which is the shape that actually regressed.
//  CF-31's round-3 finding is the other half: the two factories agreed on the TEXT of a node's
//  input preview but not on the order or multiplicity of the upstream list it is joined from,
//  which only a FAN-IN can show — so the parity claim is now pinned on one.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowRunFreezeShapeTests: XCTestCase {

    // MARK: - Fixtures

    private func node(_ name: String) -> WorkflowNode {
        WorkflowNode(kind: .code(CodeNodeConfig()), position: .zero, displayName: name)
    }

    /// A straight-line layout, so `topologicalSort()` has exactly one answer to give.
    private func chain(_ nodes: [WorkflowNode]) -> WorkflowLayout {
        var edges: [WorkflowEdge] = []
        for (upstream, downstream) in zip(nodes, nodes.dropFirst()) {
            edges.append(WorkflowEdge(sourceNodeID: upstream.id, targetNodeID: downstream.id))
        }
        return WorkflowLayout(nodes: nodes, edges: edges, annotations: [])
    }

    private func result(_ node: WorkflowNode,
                        _ status: WorkflowNodeResult.Status,
                        detail: String) -> WorkflowNodeResult {
        WorkflowNodeResult(id: UUID(), nodeID: node.id, profileName: node.displayName,
                           status: status, detail: detail,
                           startTime: Date(), endTime: Date())
    }

    private func state(userInput: String = "go",
                       results: [WorkflowNodeResult]) -> WorkflowExecutionState {
        let s = WorkflowExecutionState()
        s.userInput = userInput
        s.startedAt = Date()
        s.completedAt = Date()
        s.nodeResults = results
        return s
    }

    private func freeze(_ s: WorkflowExecutionState, layout: WorkflowLayout?) -> WorkflowRunRecord {
        WorkflowRunRecord.freeze(
            from: s, conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "Shape Flow", userInput: s.userInput,
            timestamp: s.startedAt, layout: layout)
    }

    // MARK: - CF-29: the pipeline shape survives the freeze

    /// Stop at step 2 of 6. The four rows the user is looking at must still be there afterwards.
    func testFreezeFillsInEveryLayoutNodeTheRunNeverReached() {
        let nodes = (1...6).map { node("N\($0)") }
        let s = state(results: [
            result(nodes[0], .completed, detail: "one"),
            result(nodes[1], .cancelled, detail: "Cancelled before the node finished.")
        ])
        s.wasCancelled = true

        let record = freeze(s, layout: chain(nodes))

        XCTAssertEqual(record.nodeResults.count, 6,
                       "the graph that ran had six nodes; the record must still describe six")
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.nodeResults.map(\.profileName),
                       ["N1", "N2", "N3", "N4", "N5", "N6"])

        for filled in record.nodeResults.suffix(4) {
            XCTAssertEqual(filled.status, .skipped(.notReached))
            XCTAssertEqual(filled.detail, NodeSkipReason.notReached.displayText)
            XCTAssertTrue(filled.didNotRun)
            XCTAssertFalse(filled.isGenuineFailure,
                           "⚠️ a filled-in row must NEVER read as a failure — the history card's "
                           + "red 'N failed' badge, the run roll-up and the dedicated view's "
                           + "auto-focus all key off exactly this property")
            XCTAssertEqual(filled.duration, 0)
            XCTAssertEqual(filled.ranBeforeSkip, false,
                           "it never started, so it cannot have run before the skip — and nil "
                           + "would send the display to its legacy duration/timeline heuristic")
        }
    }

    /// ⚠️ THE COUNT THAT MUST NOT MOVE. One node genuinely broke; three did not run. Filling the
    /// pipeline back in must leave the failure count, the run status and the pill exactly alone.
    func testFillingInUnreachedNodesDoesNotInflateTheFailureCount() {
        let nodes = (1...4).map { node("N\($0)") }
        let s = state(results: [
            result(nodes[0], .completed, detail: "ok"),
            result(nodes[1], .failed, detail: "boom")
        ])
        s.workflowError = "boom"

        let record = freeze(s, layout: chain(nodes))

        XCTAssertEqual(record.nodeResults.count, 4)
        XCTAssertEqual(record.nodeResults.filter(\.isGenuineFailure).count, 1,
                       "exactly one node failed on its own account")
        XCTAssertEqual(record.nodeResults.filter(\.didNotRun).count, 2)
        XCTAssertEqual(record.status, .failed)

        let data = WorkflowRunDisplayData.from(record: record)
        XCTAssertEqual(data.pillVerdict, .failed)
        XCTAssertTrue(data.hasGenuineFailure)
        XCTAssertEqual(data.totalNodes, 4,
                       "the denominator is the graph's, not however many nodes happened to start")
    }

    /// ⚠️ ORDER, not just membership. `state.nodeResults` is event-ARRIVAL order, which reorders
    /// freely across a parallel level, while the live view walks `layout.topologicalSort()`. A
    /// record kept in arrival order made rows swap position the moment the run finalized.
    func testFreezeOrdersSnapshotsTopologicallyNotByArrival() {
        let a = node("A"), b = node("B"), c = node("C")
        let s = state(results: [
            result(c, .completed, detail: "third"),
            result(a, .completed, detail: "first"),
            result(b, .completed, detail: "second")
        ])

        let record = freeze(s, layout: chain([a, b, c]))

        XCTAssertEqual(record.nodeResults.map(\.profileName), ["A", "B", "C"])
        XCTAssertEqual(record.nodeResults.map(\.detail), ["first", "second", "third"])
    }

    /// The control: with no layout snapshot there is nothing to reconstruct FROM, so the record
    /// keeps arrival order over the started nodes only. This pins that the fill is layout-gated
    /// and cannot invent rows out of nowhere.
    func testFreezeWithoutALayoutKeepsArrivalOrderAndAddsNothing() {
        let a = node("A"), b = node("B")
        let s = state(results: [result(b, .completed, detail: "b"),
                                result(a, .completed, detail: "a")])

        let record = freeze(s, layout: nil)

        XCTAssertEqual(record.nodeResults.map(\.profileName), ["B", "A"])
    }

    /// A result whose node has LEFT the layout is appended, never dropped — the same policy the
    /// live path and `from(record:)` already state. Deleting the node a run is executing must not
    /// delete the evidence that it executed.
    func testAResultOutsideTheLayoutIsAppendedNotDropped() {
        let a = node("A")
        let s = state(results: [
            result(a, .completed, detail: "a"),
            WorkflowNodeResult(id: UUID(), nodeID: UUID(), profileName: "Deleted Mid-Run",
                               status: .completed, detail: "still ran",
                               startTime: Date(), endTime: Date())
        ])

        let record = freeze(s, layout: chain([a]))

        XCTAssertEqual(record.nodeResults.map(\.profileName), ["A", "Deleted Mid-Run"])
        XCTAssertEqual(record.nodeResults.last?.detail, "still ran")
    }

    // MARK: - CF-29: what the filled-in rows must NOT make the canvas claim

    /// ⚠️ THE PRODUCTION SHAPE, and the reason the overlay's own suite could not catch this.
    /// `WorkflowCanvasRunOverlayTests.testUnknownEndpointIsUndetermined` pins that "the canvas must
    /// not claim a branch was refused when the run simply had not got there" — but it hand-builds
    /// an overlay with a node MISSING from the run, and after CF-29 a run frozen with a layout can
    /// no longer produce one: every unreached node now arrives as a real `.skipped` row instead.
    /// This walks the path production actually takes.
    func testTheCanvasStaysNeutralAboutEveryNodeAStoppedRunNeverReached() throws {
        let nodes = (1...4).map { node("N\($0)") }
        let s = state(results: [
            result(nodes[0], .completed, detail: "one"),
            result(nodes[1], .completed, detail: "two")
        ])
        s.wasCancelled = true

        let record = freeze(s, layout: chain(nodes))
        let overlay = try XCTUnwrap(WorkflowCanvasRunOverlay(displayData: .from(record: record)))

        XCTAssertEqual(overlay.edgeState(from: nodes[0].id, to: nodes[1].id), .fired,
                       "the two nodes that did run are still joined by a live edge")
        XCTAssertEqual(overlay.edgeState(from: nodes[1].id, to: nodes[2].id), .undetermined,
                       "⚠️ the run STOPPED at N2 — it did not REFUSE the branch below it. Drawn as "
                       + "`.notTaken` this edge fades to 0.28 and announces 'this branch was not "
                       + "taken' to VoiceOver: a claim about routing that never happened")
        XCTAssertEqual(overlay.edgeState(from: nodes[2].id, to: nodes[3].id), .undetermined,
                       "and an edge between two unreached nodes decides nothing either")
    }

    /// ⚠️ THE CONTROL, and the mutant the fix above could most easily become. Neutralising
    /// `.notReached` must not neutralise the one verdict the overlay exists to draw: a branch the
    /// run genuinely did not choose still reads `.notTaken`, or a Router's unfired arm becomes
    /// indistinguishable from the arm that carried the run.
    func testAGenuinelyUnchosenBranchStillReadsAsNotTakenOnTheCanvas() throws {
        let router = node("Router"), arm = node("Unchosen Arm")
        let s = state(results: [
            result(router, .completed, detail: "routed to the other port"),
            result(arm, .skipped(.notChosen), detail: NodeSkipReason.notChosen.displayText)
        ])

        let record = freeze(s, layout: chain([router, arm]))
        let overlay = try XCTUnwrap(WorkflowCanvasRunOverlay(displayData: .from(record: record)))

        XCTAssertEqual(overlay.edgeState(from: router.id, to: arm.id), .notTaken)
    }

    // MARK: - CF-31: what a user-skipped node actually forwards

    /// A → B(skipped by you) → C. The engine forwards **A's output** down that edge, while B's own
    /// `detail` is the skip sentence. C previewed the sentence.
    func testDownstreamOfAUserSkipPreviewsTheForwardedTextNotTheSkipSentence() throws {
        let a = node("Fetcher"), b = node("Summariser"), c = node("Writer")
        let layout = chain([a, b, c])
        let s = state(results: [
            result(a, .completed, detail: "ALPHA"),
            result(b, .skipped(.byUser), detail: NodeSkipReason.byUser.displayText),
            result(c, .running, detail: "Running...")
        ])

        let live = WorkflowRunDisplayData.from(live: s, layout: layout)
        let liveWriter = try XCTUnwrap(live.nodeResults.first { $0.nodeID == c.id })
        XCTAssertEqual(liveWriter.input, "ALPHA")
        XCTAssertFalse(liveWriter.input?.contains("Skipped by you") ?? false,
                       "the skip sentence is the one string this node definitely did not receive")

        let frozen = try XCTUnwrap(freeze(s, layout: layout).nodeResults.first { $0.nodeID == c.id })
        XCTAssertEqual(frozen.input, "ALPHA",
                       "⚠️ TWIN-PATH: the persisted preview must say what the live one said")
    }

    /// A skipped ENTRY node has no upstream envelopes, so the engine forwards the run's own query
    /// ("forwarding '' there would hand downstream a blank task").
    func testASkippedEntryNodeForwardsTheRunsOwnInput() {
        let b = node("Summariser"), c = node("Writer")
        let layout = chain([b, c])
        let s = state(userInput: "summarise this", results: [
            result(b, .skipped(.byUser), detail: NodeSkipReason.byUser.displayText),
            result(c, .running, detail: "Running...")
        ])

        let live = WorkflowRunDisplayData.from(live: s, layout: layout)
        XCTAssertEqual(live.nodeResults.first { $0.nodeID == c.id }?.input, "summarise this")

        let record = freeze(s, layout: layout)
        XCTAssertEqual(record.nodeResults.first { $0.nodeID == c.id }?.input, "summarise this")
    }

    /// Chained skips compose in the engine — each pass-through feeds the next — so the preview has
    /// to walk back the same way rather than stopping at the first skip.
    func testChainedUserSkipsResolveBackToTheLastNodeThatActuallyRan() {
        let a = node("A"), b = node("B"), c = node("C"), d = node("D")
        let s = state(results: [
            result(a, .completed, detail: "ALPHA"),
            result(b, .skipped(.byUser), detail: NodeSkipReason.byUser.displayText),
            result(c, .skipped(.byUser), detail: NodeSkipReason.byUser.displayText),
            result(d, .running, detail: "Running...")
        ])

        let live = WorkflowRunDisplayData.from(live: s, layout: chain([a, b, c, d]))
        XCTAssertEqual(live.nodeResults.first { $0.nodeID == d.id }?.input, "ALPHA")
    }

    /// ⚠️ THE CONTROL, and the mutant this fix could most easily become. Only `.byUser` keeps its
    /// downstream alive (`NodeSkipReason.keepsDownstreamAlive`); for every other reason the subtree
    /// below is dead, and its detail — the explanation of why nothing ran — is exactly what belongs
    /// in the row below. Resolving ALL skips would erase that explanation.
    func testANonUserSkipStillPreviewsItsOwnExplanation() {
        let a = node("Router"), b = node("Branch")
        let s = state(results: [
            result(a, .skipped(.notChosen), detail: NodeSkipReason.notChosen.displayText),
            result(b, .completed, detail: "ran anyway")
        ])

        let live = WorkflowRunDisplayData.from(live: s, layout: chain([a, b]))
        XCTAssertEqual(live.nodeResults.first { $0.nodeID == b.id }?.input,
                       NodeSkipReason.notChosen.displayText)
    }

    /// The resolver walks EDGES, not a topological order, so a corrupt cyclic layout must
    /// terminate rather than recurse forever. It falls back to the skipped node's own detail.
    func testInputContributionTerminatesOnACyclicLayout() {
        let x = UUID(), y = UUID()
        let rx = WorkflowNodeResult(id: UUID(), nodeID: x, profileName: "X",
                                    status: .skipped(.byUser), detail: "X sentence",
                                    startTime: Date(), endTime: Date())
        let ry = WorkflowNodeResult(id: UUID(), nodeID: y, profileName: "Y",
                                    status: .skipped(.byUser), detail: "Y sentence",
                                    startTime: Date(), endTime: Date())
        let edges = [WorkflowEdge(sourceNodeID: x, targetNodeID: y),
                     WorkflowEdge(sourceNodeID: y, targetNodeID: x)]

        let text = WorkflowExecutionState.upstreamInputContribution(
            of: rx, resultsByNodeID: [x: rx, y: ry], edges: edges, userInput: "seed")

        XCTAssertEqual(text, "X sentence",
                       "the cycle guard stops at the node already on the walk and uses its detail")
    }

    /// Every status but `.skipped(.byUser)` resolves to `detail` unchanged — stated directly on the
    /// resolver so the rule cannot drift out of the two factories that call it.
    func testInputContributionIsPlainDetailForEveryOtherStatus() {
        let id = UUID()
        let statuses: [WorkflowNodeResult.Status] = [
            .completed, .failed, .running, .cancelled,
            .skipped(.notChosen), .skipped(.upstreamFailed), .skipped(.notReached)
        ]
        for status in statuses {
            let r = WorkflowNodeResult(id: UUID(), nodeID: id, profileName: "N",
                                       status: status, detail: "DETAIL",
                                       startTime: Date(), endTime: Date())
            XCTAssertEqual(
                WorkflowExecutionState.upstreamInputContribution(
                    of: r, resultsByNodeID: [id: r], edges: [], userInput: "seed"),
                "DETAIL",
                "status \(status) must contribute its own detail")
        }
    }

    // MARK: - CF-31: the two factories build the SAME upstream list, not just the same text

    /// ⚠️ ORDER, which only a FAN-IN can expose. `freeze` used to collect a node's upstreams as a
    /// `Set` of edge sources and then filter `state.nodeResults` — event-ARRIVAL order — while the
    /// live factory walks the EDGES in declaration order. Identical on a chain, which is all the
    /// existing CF-31 tests cover; on a parallel level the joined preview and the label naming
    /// where it came from both reordered the instant `finalize()` swapped the live factory for the
    /// record factory. Arrival order below is deliberately the REVERSE of edge order — exactly
    /// what a parallel level produces when the second branch finishes first.
    func testAFanInNodesInputPreviewIsBuiltInEdgeOrderOnBothSidesOfTheFreeze() throws {
        let a = node("Alpha"), b = node("Bravo"), d = node("Delta")
        let layout = WorkflowLayout(
            nodes: [a, b, d],
            edges: [WorkflowEdge(sourceNodeID: a.id, targetNodeID: d.id),
                    WorkflowEdge(sourceNodeID: b.id, targetNodeID: d.id)],
            annotations: [])
        let s = state(results: [
            result(b, .completed, detail: "BRAVO OUTPUT"),   // finished FIRST
            result(a, .completed, detail: "ALPHA OUTPUT"),
            result(d, .running, detail: "Running...")
        ])

        let live = try XCTUnwrap(WorkflowRunDisplayData.from(live: s, layout: layout)
            .nodeResults.first { $0.nodeID == d.id })
        XCTAssertEqual(live.input, "ALPHA OUTPUT\n\nBRAVO OUTPUT")
        XCTAssertEqual(live.inputSourceLabel, "Alpha, Bravo")

        let frozen = try XCTUnwrap(freeze(s, layout: layout).nodeResults.first { $0.nodeID == d.id })
        XCTAssertEqual(frozen.input, live.input,
                       "⚠️ TWIN-PATH: the record used to join these in arrival order, so the frozen "
                       + "preview opened with 'BRAVO OUTPUT' where the live one opened with 'ALPHA'")
        XCTAssertEqual(frozen.inputSourceLabel, live.inputSourceLabel,
                       "and the label naming the sources flipped with it")
    }

    /// The other half of the same divergence: an upstream wired into TWO ports of one target is one
    /// contribution per EDGE on the live path and — through a `Set` — one in total in the record.
    /// The literal pins today's live behaviour; the claim being pinned is that the record MATCHES
    /// it, so a future change to either factory has to change both.
    func testAnUpstreamWiredIntoTwoPortsContributesIdenticallyOnBothSides() throws {
        let cond = node("Condition"), sink = node("Sink")
        let layout = WorkflowLayout(
            nodes: [cond, sink],
            edges: [WorkflowEdge(sourceNodeID: cond.id, targetNodeID: sink.id, sourcePortLabel: "True"),
                    WorkflowEdge(sourceNodeID: cond.id, targetNodeID: sink.id, sourcePortLabel: "False")],
            annotations: [])
        let s = state(results: [
            result(cond, .completed, detail: "VERDICT"),
            result(sink, .running, detail: "Running...")
        ])

        let live = try XCTUnwrap(WorkflowRunDisplayData.from(live: s, layout: layout)
            .nodeResults.first { $0.nodeID == sink.id })
        let frozen = try XCTUnwrap(freeze(s, layout: layout)
            .nodeResults.first { $0.nodeID == sink.id })

        XCTAssertEqual(live.input, "VERDICT\n\nVERDICT")
        XCTAssertEqual(frozen.input, live.input,
                       "⚠️ the record used to collapse the two edges and persist a single 'VERDICT'")
        XCTAssertEqual(frozen.inputSourceLabel, live.inputSourceLabel)
    }

    // MARK: - CF-32: the orphan log fires once, not per body pass

    /// `WorkflowDedicatedView.displayData` rebuilds the whole run model on EVERY body pass, and the
    /// view re-evaluates on every streamed workflow event, so an unconditional log produced dozens
    /// of identical lines per second for the rest of the run.
    func testTheOrphanLogFiresOnceForAGivenRunAndOrphanSet() {
        let run = UUID(), first = UUID(), second = UUID()
        let signature = WorkflowRunDisplayData.orphanLogSignature(runID: run, orphanNodeIDs: [first])

        XCTAssertTrue(WorkflowRunDisplayData.shouldLogOrphans(signature: signature))
        XCTAssertFalse(WorkflowRunDisplayData.shouldLogOrphans(signature: signature),
                       "⚠️ the second identical evaluation is the whole row — it must be silent")
        XCTAssertFalse(WorkflowRunDisplayData.shouldLogOrphans(signature: signature))

        // A SECOND node leaving the layout is new information and must still be reported.
        let grown = WorkflowRunDisplayData.orphanLogSignature(runID: run,
                                                             orphanNodeIDs: [first, second])
        XCTAssertTrue(WorkflowRunDisplayData.shouldLogOrphans(signature: grown))
    }

    /// The signature must not change just because `nodeResults` reordered — arrival order is not
    /// stable across a parallel level, and a signature that flipped with it would log on every
    /// frame again, which is the defect.
    func testTheOrphanSignatureIsStableUnderReorderingAndScopedToTheRun() {
        let run = UUID(), a = UUID(), b = UUID()
        XCTAssertEqual(WorkflowRunDisplayData.orphanLogSignature(runID: run, orphanNodeIDs: [a, b]),
                       WorkflowRunDisplayData.orphanLogSignature(runID: run, orphanNodeIDs: [b, a]))
        XCTAssertNotEqual(WorkflowRunDisplayData.orphanLogSignature(runID: run, orphanNodeIDs: [a]),
                          WorkflowRunDisplayData.orphanLogSignature(runID: UUID(), orphanNodeIDs: [a]))
    }
}
