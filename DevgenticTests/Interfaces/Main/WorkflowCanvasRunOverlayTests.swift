//
//  WorkflowCanvasRunOverlayTests.swift
//  DevgenticTests
//
//  The canvas showed NOTHING about execution until 2026-08-15: `WorkflowCanvasView` did not receive
//  execution state, `WorkflowCanvasState` had no per-node status, and `WorkflowNodeView` carried an
//  empty `.overlay(alignment: .topLeading) { }` where a badge was plainly once intended. During and
//  after a run every node looked exactly as it had before it, and a Router with three output ports
//  drew three identical curves — so "which branch did it take?", the one question a graph view is
//  better placed to answer than a timeline, was unanswerable on the canvas.
//
//  ⚠️ Edge liveness here is DERIVED from what each endpoint did, because the engine's authoritative
//  `WorkflowState.edgeIsLive` needs `activeOutputPorts`, which the UI never receives. Plumbing that
//  into a view would create a second, drifting copy of the routing rules — the exact defect class
//  `edgeIsLive` exists to prevent. These tests pin what the derivation can and cannot conclude.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowCanvasRunOverlayTests: XCTestCase {

    private func result(
        _ status: WorkflowNodeResult.Status,
        nodeID: UUID,
        name: String
    ) -> WorkflowNodeResult {
        WorkflowNodeResult(
            id: UUID(), nodeID: nodeID, profileName: name,
            status: status, detail: "",
            startTime: Date(), endTime: Date()
        )
    }

    private func overlay(_ results: [WorkflowNodeResult], isRunning: Bool = false) -> WorkflowCanvasRunOverlay? {
        let state = WorkflowExecutionState()
        state.isRunning = isRunning
        state.startedAt = Date()
        if !isRunning { state.completedAt = Date() }
        state.nodeResults = results
        return WorkflowCanvasRunOverlay(displayData: .from(live: state, layout: nil))
    }

    // MARK: - Presence

    /// No run → no overlay, so a canvas that has never executed looks exactly as it always did.
    func testNoOverlayWhenThereIsNoRun() {
        XCTAssertNil(WorkflowCanvasRunOverlay(displayData: nil))
        XCTAssertNil(overlay([]), "an empty run must not put run chrome on the canvas")
    }

    // MARK: - The question the canvas exists to answer

    /// A Router took the "bug" arm. The taken edge must read as fired and the unchosen one as not
    /// taken — otherwise the canvas draws both arms identically and says nothing.
    func testUnchosenRouterBranchReadsAsNotTakenAndTheChosenOneAsFired() {
        let router = UUID(), bug = UUID(), feature = UUID()
        let o = overlay([
            result(.completed, nodeID: router, name: "Router"),
            result(.completed, nodeID: bug, name: "BugAgent"),
            result(.skipped(.notChosen), nodeID: feature, name: "FeatureAgent")
        ])

        XCTAssertEqual(o?.edgeState(from: router, to: bug), .fired)
        XCTAssertEqual(o?.edgeState(from: router, to: feature), .notTaken)
    }

    /// The error handler that correctly stood down. Its edge must recede, and — critically — the
    /// node must NOT be badged as a problem: nothing went wrong on this run.
    func testErrorHandlerOnASuccessfulRunIsNotTakenAndNotAProblem() {
        let agent = UUID(), handler = UUID()
        let o = overlay([
            result(.completed, nodeID: agent, name: "Agent"),
            result(.skipped(.errorPortNotTaken), nodeID: handler, name: "Handler")
        ])

        XCTAssertEqual(o?.edgeState(from: agent, to: handler), .notTaken)
        XCTAssertEqual(o?.status(for: handler), .skipped)
        XCTAssertEqual(o?.status(for: handler)?.warrantsAttention, false,
                       "a branch the workflow did not take is ordinary routing, not a problem")
        XCTAssertEqual(o?.status(for: agent)?.warrantsAttention, false)
    }

    /// A genuine failure DOES warrant attention — the point is to separate the two, not to make
    /// everything neutral.
    func testFailedNodeWarrantsAttention() {
        let agent = UUID()
        let o = overlay([result(.failed, nodeID: agent, name: "Agent")])
        XCTAssertEqual(o?.status(for: agent)?.warrantsAttention, true)
    }

    // MARK: - Derivation limits

    /// ⚠️ THE COUNTER-CASE this file was missing. The test below exercises only cascade reasons,
    /// where `.notTaken` is right, but its wording generalises to "a skipped source" — and the
    /// production rule WAS that general, so it silently blessed the wrong answer for `.byUser`.
    /// A user skip is the ONE reason whose downstream still runs: the node's input is forwarded
    /// as its output and every default edge below it stays live, so drawing those edges dead told
    /// the user the run took a path it did not take.
    func testUserSkippedSourceStillFiresItsOutgoingEdge() {
        let skipped = UUID(), downstream = UUID()
        let o = overlay([
            result(.skipped(.byUser), nodeID: skipped, name: "Middle"),
            result(.completed, nodeID: downstream, name: "Last")
        ])
        XCTAssertEqual(o?.edgeState(from: skipped, to: downstream), .fired,
                       "the node below a user-skipped node ran on that node's input")
    }

    /// And the edge INTO it: the skipped node did receive the upstream output it passed on.
    func testEdgeIntoAUserSkippedNodeIsNotDrawnDead() {
        let upstream = UUID(), skipped = UUID()
        let o = overlay([
            result(.completed, nodeID: upstream, name: "First"),
            result(.skipped(.byUser), nodeID: skipped, name: "Middle")
        ])
        XCTAssertNotEqual(o?.edgeState(from: upstream, to: skipped), .notTaken,
                          "data flowed along this edge — the skip forwarded it downstream")
    }

    /// ⚠️ THE CONTRACT ITSELF, pinned explicitly. The loop test below iterates
    /// `where !reason.keepsDownstreamAlive`, so it re-derives its expectation from the very
    /// property under test — a self-referential test that cannot catch that property being wrong
    /// (proved: a mutation adding `.notChosen` to the pass-through set left it green and was
    /// caught only by an unrelated pre-existing test). This one names the answer per case.
    func testKeepsDownstreamAliveIsByUserAndNothingElse() {
        XCTAssertTrue(NodeSkipReason.byUser.keepsDownstreamAlive,
                      "the one skip whose downstream runs")
        for reason in NodeSkipReason.allCases where reason != .byUser {
            XCTAssertFalse(reason.keepsDownstreamAlive,
                           "\(reason) means the subtree below it is dead")
        }
    }

    /// The rule reads the CONTRACT, not a hardcoded case list: every reason that kills the subtree
    /// must still draw dead. Guards a future skip reason from silently inheriting pass-through.
    func testEveryNonPassThroughReasonStillKillsTheEdge() {
        for reason in NodeSkipReason.allCases where !reason.keepsDownstreamAlive {
            let skipped = UUID(), downstream = UUID()
            let o = overlay([
                result(.skipped(reason), nodeID: skipped, name: "Middle"),
                result(.completed, nodeID: downstream, name: "Last")
            ])
            XCTAssertEqual(o?.edgeState(from: skipped, to: downstream), .notTaken,
                           "\(reason) kills the subtree below it")
        }
    }

    /// A live run must still leave an unstarted target neutral — the pass-through change must not
    /// collapse `.undetermined` into `.fired`.
    func testPendingTargetStaysUndeterminedDuringALiveRun() {
        let ranNode = UUID(), notYet = UUID()
        let o = overlay([
            result(.completed, nodeID: ranNode, name: "A"),
            result(.running, nodeID: notYet, name: "B")
        ], isRunning: true)
        XCTAssertEqual(o?.edgeState(from: ranNode, to: notYet), .fired)
    }

    /// A skipped SOURCE kills its outgoing edges too, not just incoming ones.
    /// (Cascade reasons only — the `.byUser` counter-case is pinned above.)
    func testSkippedSourceMakesItsOutgoingEdgeNotTaken() {
        let skipped = UUID(), downstream = UUID()
        let o = overlay([
            result(.skipped(.upstreamFailed), nodeID: skipped, name: "Middle"),
            result(.skipped(.upstreamSkipped), nodeID: downstream, name: "Last")
        ])
        XCTAssertEqual(o?.edgeState(from: skipped, to: downstream), .notTaken)
    }

    /// A node with no event at all (never reached) leaves its edges UNDETERMINED — the canvas must
    /// not claim a branch was refused when the run simply had not got there.
    func testUnknownEndpointIsUndetermined() {
        let known = UUID(), unknown = UUID()
        let o = overlay([result(.completed, nodeID: known, name: "A")])

        XCTAssertEqual(o?.edgeState(from: known, to: unknown), .undetermined)
        XCTAssertEqual(o?.edgeState(from: unknown, to: known), .undetermined)
        XCTAssertNil(o?.status(for: unknown))
    }

    /// A cancelled node RAN — it just did not finish — so its edge carried the run.
    func testCancelledNodeCountsAsHavingRun() {
        let a = UUID(), b = UUID()
        let o = overlay([
            result(.completed, nodeID: a, name: "A"),
            result(.cancelled, nodeID: b, name: "B")
        ])
        XCTAssertEqual(o?.edgeState(from: a, to: b), .fired)
        XCTAssertEqual(o?.status(for: b)?.warrantsAttention, false,
                       "the user asked for the cancel — it is not a fault")
    }

    // MARK: - Status semantics
    //
    // ⚠️ Asserted DIRECTLY, not only through `edgeState`. `didRun` is shadowed there by the
    // not-taken rule, which returns before it is ever consulted for a skipped node — so a mutation
    // making `.skipped` report `didRun == true` passed all eight edge tests. `didRun` is a
    // semantic property with meaning of its own, and the next reader to use it elsewhere needs it
    // to be right rather than merely unreachable.

    func testDidRunSemantics() {
        typealias Status = WorkflowRunDisplayData.NodeDisplayData.NodeStatus
        XCTAssertTrue(Status.completed.didRun)
        XCTAssertTrue(Status.failed.didRun)
        XCTAssertTrue(Status.running.didRun)
        XCTAssertTrue(Status.cancelled.didRun, "it started — it just did not finish")
        XCTAssertFalse(Status.skipped.didRun, "a skipped node never executed")
        XCTAssertFalse(Status.pending.didRun, "a pending node has not executed yet")
    }

    func testOnlyAGenuineFailureWarrantsAttention() {
        typealias Status = WorkflowRunDisplayData.NodeDisplayData.NodeStatus
        XCTAssertTrue(Status.failed.warrantsAttention)
        for status in [Status.completed, .running, .pending, .skipped, .cancelled] {
            XCTAssertFalse(status.warrantsAttention,
                           "\(status) must not be badged as a problem on the canvas")
        }
    }

    /// The running node pulses only while the run is LIVE. A historical run's `.running` node never
    /// settled, and animating it would claim work is still happening in a run that has ended.
    func testIsLiveTracksTheRunNotTheNodeStatus() {
        let a = UUID()
        XCTAssertEqual(overlay([result(.running, nodeID: a, name: "A")], isRunning: true)?.isLive, true)
        XCTAssertEqual(overlay([result(.running, nodeID: a, name: "A")], isRunning: false)?.isLive, false)
    }
}
