//
//  WorkflowRoutingGateTests.swift
//  DevgenticTests
//
//  Pins the routing model after the 2026-08-12 simplification (user's design decision).
//
//  The per-node failure policy is GONE. `skipDependents` never had a runtime read — it was the
//  fall-through; `continueAll` and `stopWorkflow` are decode-only. Failure routing is now
//  expressed on the CANVAS:
//
//    • error port unwired → the branch stops
//    • error port wired   → the downstream runs and receives the failure
//    • a failure NEVER cancels a parallel branch — those are independent by construction
//
//  The invariant these tests exist to protect: the ROUTING gate (`shouldExecuteNode`) and the
//  DATA gate (`upstreamResultEnvelopes`) are both pure port checks with no exemptions, so they
//  agree by construction. Every historical disagreement between them was a bug (WF13).
//

import XCTest
@testable import devgentic

final class WorkflowRoutingGateTests: XCTestCase {

    private let upstreamID = UUID()
    private let downstreamID = UUID()

    private func envelope(_ status: NodeExecutionStatus, output: String = "partial output") -> NodeResultEnvelope {
        NodeResultEnvelope(
            taskID: UUID(), nodeID: upstreamID, sourceProfileID: UUID(),
            profileName: "Fetcher", profileType: .bot,
            status: status, output: output, artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: output)
        )
    }

    /// Failure/skip activate `["error"]`; success activates nothing.
    private func state(_ status: NodeExecutionStatus, activatesErrorPort: Bool) -> WorkflowState {
        var state = WorkflowState()
        state.recordResult(from: envelope(status))
        if activatesErrorPort { state.setActiveOutputPorts(["error"], for: upstreamID) }
        return state
    }

    /// `policy` is deliberately settable so these tests prove a STORED policy changes nothing.
    private func nodes(policy: NodeFailurePolicy? = nil) -> [WorkflowNode] {
        var upstream = WorkflowNode(id: upstreamID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Fetcher")
        if let policy { upstream.nodeConfig = WorkflowNodeConfig(onFailure: policy) }
        let downstream = WorkflowNode(id: downstreamID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Summarizer")
        return [upstream, downstream]
    }

    private func edge(_ label: String?) -> WorkflowEdge {
        WorkflowEdge(sourceNodeID: upstreamID, targetNodeID: downstreamID, sourcePortLabel: label)
    }

    /// Asserts both gates give the same verdict — the invariant, checked on every case below.
    private func assertGatesAgree(
        _ state: WorkflowState, _ nodes: [WorkflowNode], _ edges: [WorkflowEdge],
        runs: Bool, receivesData: Bool,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(state.shouldExecuteNode(downstreamID, edges: edges, nodes: nodes), runs,
                       "routing: \(message)", file: file, line: line)
        XCTAssertEqual(!state.upstreamResultEnvelopes(for: downstreamID, edges: edges).isEmpty, receivesData,
                       "data: \(message)", file: file, line: line)
    }

    // MARK: - Failure routing is wiring

    func testFailedUpstream_NoErrorEdge_BranchStops() {
        assertGatesAgree(state(.failed(.modelError(provider: "t", error: "boom")), activatesErrorPort: true),
                         nodes(), [edge(nil)],
                         runs: false, receivesData: false,
                         "an unwired error port stops the branch")
    }

    func testFailedUpstream_ErrorEdge_RunsWithData() {
        assertGatesAgree(state(.failed(.modelError(provider: "t", error: "boom")), activatesErrorPort: true),
                         nodes(), [edge("error")],
                         runs: true, receivesData: true,
                         "a wired error port runs the handler WITH the failed envelope")
    }

    func testCompletedUpstream_DefaultEdge_RunsWithData() {
        assertGatesAgree(state(.completed, activatesErrorPort: false),
                         nodes(), [edge(nil)],
                         runs: true, receivesData: true,
                         "the happy path")
    }

    /// The failure-exclusivity rule: an error handler must never fire on success.
    ///
    /// ⚠️ `receivesData: false` is deliberate and changed on 2026-08-12. The data gate used to be a
    /// pure port filter that let a completed upstream through on EVERY edge, so a node wired to
    /// both this upstream's `error` port and some other live branch would have been handed the
    /// success payload down the error edge. Now both gates share `edgeIsLive`, so an edge that
    /// didn't fire carries nothing.
    func testCompletedUpstream_ErrorEdge_NeverFires() {
        assertGatesAgree(state(.completed, activatesErrorPort: false),
                         nodes(), [edge("error")],
                         runs: false, receivesData: false,
                         "an error edge must not fire on success")
    }

    /// A cascade skip also activates `["error"]`, so recovery chains don't dead-end (P0-6).
    func testSkippedUpstream_ErrorEdge_StillRuns() {
        assertGatesAgree(state(.skipped(reason: .upstreamFailed), activatesErrorPort: true),
                         nodes(), [edge("error")],
                         runs: true, receivesData: true,
                         "a skip propagates as a failure signal")
    }

    // MARK: - Retired policies change nothing

    func testStoredContinueAllPolicyChangesNothing() {
        for policy in [NodeFailurePolicy.continueAll, .stopWorkflow, .skipDependents] {
            assertGatesAgree(state(.failed(.modelError(provider: "t", error: "boom")), activatesErrorPort: true),
                             nodes(policy: policy), [edge(nil)],
                             runs: false, receivesData: false,
                             "stored policy '\(policy.rawValue)' must be ignored")
        }
    }

    func testStoredPolicyDoesNotResurrectLabeledPorts() {
        // A gate option that was never chosen must stay dead regardless of stored policy.
        var state = WorkflowState()
        state.recordResult(from: envelope(.failed(.modelError(provider: "t", error: "boom"))))
        state.setActiveOutputPorts(["error"], for: upstreamID)

        assertGatesAgree(state, nodes(policy: .continueAll), [edge("Approve")],
                         runs: false, receivesData: false,
                         "an unchosen option port must never fire")
    }

    // MARK: - Cancellation

    /// ⚠️ This is the case the liveness guard exists for. `.failed` and cascade-`.skipped` both
    /// activate `["error"]`, so the port check below the guard would reject them on its own.
    /// `.canceled` activates NOTHING — without the guard it would fall through to the
    /// default-edge allow and a cancelled node would look exactly like a success downstream.
    func testCanceledUpstream_DefaultEdge_BranchStops() {
        let s = state(.canceled, activatesErrorPort: false)
        XCTAssertFalse(s.shouldExecuteNode(downstreamID, edges: [edge(nil)], nodes: nodes()),
                       "a cancelled upstream must not read as success")
    }

    /// A cancelled node has no `error` port either — recovery handlers do not fire on cancellation.
    func testCanceledUpstream_ErrorEdge_DoesNotRunHandler() {
        let s = state(.canceled, activatesErrorPort: false)
        XCTAssertFalse(s.shouldExecuteNode(downstreamID, edges: [edge("error")], nodes: nodes()),
                       "cancellation is not a failure to recover from")
    }

    /// ⚠️ REGRESSION PIN (found 2026-08-12 while mutation-checking the gate simplification).
    /// The data gate is a pure port filter, and `.canceled` activates no ports — so a cancelled
    /// branch's envelope used to ride along into any node that ran for another reason.
    ///
    /// Restructured 2026-08-13 for the graph-derived join: two INDEPENDENT branches are now both
    /// required, so a cancelled one would simply skip the node and the leak would be unobservable.
    /// The two upstreams are therefore made mutually exclusive (different ports of one router), the
    /// shape where a dead branch really is excused and the node really does run.
    func testCanceledUpstream_DoesNotLeakIntoAMergeThatRuns() {
        let routerID = UUID(), liveID = UUID()
        var s = WorkflowState()
        s.recordResult(from: envelope(.canceled, output: "half-written answer"))
        s.recordResult(from: NodeResultEnvelope(
            taskID: UUID(), nodeID: liveID, sourceProfileID: UUID(),
            profileName: "Healthy", profileType: .bot,
            status: .completed, output: "real answer", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "real answer")))

        let router = WorkflowNode(id: routerID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Router")
        let cancelled = WorkflowNode(id: upstreamID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Fetcher")
        let healthy = WorkflowNode(id: liveID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Healthy")
        let merge = WorkflowNode(id: downstreamID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Merge")

        let edges = [
            WorkflowEdge(sourceNodeID: routerID, targetNodeID: upstreamID, sourcePortLabel: "True"),
            WorkflowEdge(sourceNodeID: routerID, targetNodeID: liveID, sourcePortLabel: "False"),
            edge(nil),
            WorkflowEdge(sourceNodeID: liveID, targetNodeID: downstreamID)
        ]

        XCTAssertTrue(s.shouldExecuteNode(downstreamID, edges: edges, nodes: [router, cancelled, healthy, merge]),
                      "the cancelled branch is an unchosen alternative, so the live one carries the merge")

        let received = s.upstreamResultEnvelopes(for: downstreamID, edges: edges)
        XCTAssertEqual(received.map(\.profileName), ["Healthy"],
                       "the cancelled branch must not contribute data to the node that runs")
    }

    // MARK: - The derived join

    /// Two INDEPENDENT branches are both required — the fail-safe half of the derived rule.
    func testIndependentBranches_AreAllRequired() {
        let otherID = UUID()
        var s = WorkflowState()
        s.recordResult(from: envelope(.canceled))
        s.recordResult(from: NodeResultEnvelope(
            taskID: UUID(), nodeID: otherID, sourceProfileID: UUID(),
            profileName: "Healthy", profileType: .bot, status: .completed,
            output: "ok", artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "ok")))

        let dead = WorkflowNode(id: upstreamID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Fetcher")
        let healthy = WorkflowNode(id: otherID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Healthy")
        let merge = WorkflowNode(id: downstreamID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Merge")
        let edges = [edge(nil), WorkflowEdge(sourceNodeID: otherID, targetNodeID: downstreamID)]

        XCTAssertFalse(s.shouldExecuteNode(downstreamID, edges: edges, nodes: [dead, healthy, merge]),
                       "nothing is exclusive here, so the dead branch is REQUIRED — no silent partial input")
    }

    /// A stored `joinMode` from a pre-2026-08-13 layout must change nothing.
    func testStoredJoinModeIsIgnored() {
        for stored in [JoinMode.all, .any] {
            let otherID = UUID()
            var s = WorkflowState()
            s.recordResult(from: envelope(.failed(.modelError(provider: "t", error: "boom"))))
            s.setActiveOutputPorts(["error"], for: upstreamID)
            s.recordResult(from: NodeResultEnvelope(
                taskID: UUID(), nodeID: otherID, sourceProfileID: UUID(),
                profileName: "Healthy", profileType: .bot, status: .completed,
                output: "ok", artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "ok")))

            let dead = WorkflowNode(id: upstreamID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Fetcher")
            let healthy = WorkflowNode(id: otherID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Healthy")
            var merge = WorkflowNode(id: downstreamID, kind: .code(CodeNodeConfig()), position: .zero, displayName: "Merge")
            merge.nodeConfig = WorkflowNodeConfig(joinMode: stored)
            let edges = [edge(nil), WorkflowEdge(sourceNodeID: otherID, targetNodeID: downstreamID)]

            XCTAssertFalse(s.shouldExecuteNode(downstreamID, edges: edges, nodes: [dead, healthy, merge]),
                           "stored joinMode '\(stored.rawValue)' must not change the derived verdict")
        }
    }

    // MARK: - Join semantics survive    // MARK: - Join semantics survive

    /// Default + error double-wiring: the node runs on either outcome, and the dedup delivers
    /// exactly one envelope.
    func testDoubleWiredNode_RunsOnFailure_AndDeliversOnce() {
        let s = state(.failed(.modelError(provider: "t", error: "boom")), activatesErrorPort: true)
        let edges = [edge(nil), edge("error")]

        XCTAssertTrue(s.shouldExecuteNode(downstreamID, edges: edges, nodes: nodes()))
        XCTAssertEqual(s.upstreamResultEnvelopes(for: downstreamID, edges: edges).count, 1,
                       "one envelope per upstream, even when two edges pass")
    }

    func testDoubleWiredNode_RunsOnSuccess() {
        let s = state(.completed, activatesErrorPort: false)
        XCTAssertTrue(s.shouldExecuteNode(downstreamID, edges: [edge(nil), edge("error")], nodes: nodes()),
                      "the finalizer pattern: runs whichever way the upstream went")
    }
}
