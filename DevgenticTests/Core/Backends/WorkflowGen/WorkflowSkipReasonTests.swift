// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowSkipReasonTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class WorkflowSkipReasonTests: XCTestCase {

    private let upstreamID = UUID()
    private let downstreamID = UUID()

    private func envelope(_ status: NodeExecutionStatus, id: UUID, name: String, output: String = "answer") -> NodeResultEnvelope {
        NodeResultEnvelope(
            taskID: UUID(), nodeID: id, sourceProfileID: UUID(),
            profileName: name, profileType: .bot,
            status: status, output: output, artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: output)
        )
    }

    private func node(_ id: UUID, _ name: String) -> WorkflowNode {
        WorkflowNode(id: id, kind: .code(CodeNodeConfig()), position: .zero, displayName: name)
    }

    private func edge(_ from: UUID, _ to: UUID, port: String?) -> WorkflowEdge {
        WorkflowEdge(sourceNodeID: from, targetNodeID: to, sourcePortLabel: port)
    }

    // MARK: - Skip reason derivation

    /// The happy path that used to lie loudest: the upstream SUCCEEDED, so its error handler stands
    /// down. Nothing failed, and the reason must not claim otherwise.
    func testErrorHandlerOnASuccessfulUpstreamReportsErrorPortNotTaken() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "Fetcher"))

        let decision = state.runDecision(
            for: downstreamID,
            edges: [edge(upstreamID, downstreamID, port: WorkflowEdge.errorPortLabel)],
            nodes: [node(upstreamID, "Fetcher"), node(downstreamID, "Handler")]
        )

        XCTAssertEqual(decision, .skip(.errorPortNotTaken))
        if case .skip(let reason) = decision {
            XCTAssertFalse(reason.indicatesProblem, "nothing went wrong on this run")
        }
    }

    /// A Router that activated a different port. Ordinary branching, not a failure.
    func testUnchosenRouterBranchReportsNotChosen() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "Router"))
        state.setActiveOutputPorts(["bug"], for: upstreamID)

        let decision = state.runDecision(
            for: downstreamID,
            edges: [edge(upstreamID, downstreamID, port: "feature")],
            nodes: [node(upstreamID, "Router"), node(downstreamID, "FeatureAgent")]
        )

        XCTAssertEqual(decision, .skip(.notChosen))
        if case .skip(let reason) = decision {
            XCTAssertFalse(reason.indicatesProblem, "the Router routing is not a problem")
        }
    }

    /// A genuine upstream failure must still be reported as one — the point is to separate the
    /// causes, not to relabel every skip as benign.
    func testFailedUpstreamReportsUpstreamFailed() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.failed(.modelError(provider: "x", error: "boom")), id: upstreamID, name: "Fetcher"))
        state.setActiveOutputPorts(["error"], for: upstreamID)

        let decision = state.runDecision(
            for: downstreamID,
            edges: [edge(upstreamID, downstreamID, port: nil)],
            nodes: [node(upstreamID, "Fetcher"), node(downstreamID, "Summarizer")]
        )

        XCTAssertEqual(decision, .skip(.upstreamFailed))
        if case .skip(let reason) = decision {
            XCTAssertTrue(reason.indicatesProblem, "this one IS worth the user's attention")
        }
    }

    /// A cascade: the upstream itself never ran.
    func testSkippedUpstreamCascadesAsUpstreamSkipped() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.skipped(reason: .notChosen), id: upstreamID, name: "FeatureAgent"))
        state.setActiveOutputPorts(["error"], for: upstreamID)

        let decision = state.runDecision(
            for: downstreamID,
            edges: [edge(upstreamID, downstreamID, port: nil)],
            nodes: [node(upstreamID, "FeatureAgent"), node(downstreamID, "Summarizer")]
        )

        XCTAssertEqual(decision, .skip(.upstreamSkipped))
    }

    /// An upstream with no recorded result at all — the run ended before it.
    func testUpstreamWithNoResultReportsNotReached() {
        let state = WorkflowState()

        let decision = state.runDecision(
            for: downstreamID,
            edges: [edge(upstreamID, downstreamID, port: nil)],
            nodes: [node(upstreamID, "Fetcher"), node(downstreamID, "Summarizer")]
        )

        XCTAssertEqual(decision, .skip(.notReached))
    }

    /// When branches disagree, the most alarming cause wins — a node fed by both a crashed branch
    /// and an unchosen one must report the crash, not the routing.
    func testMostAlarmingCauseWinsAcrossBranches() {
        let routerID = UUID()
        let failedID = UUID()
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: routerID, name: "Router"))
        state.setActiveOutputPorts(["other"], for: routerID)
        state.recordResult(from: envelope(.failed(.modelError(provider: "x", error: "boom")), id: failedID, name: "Fetcher"))
        state.setActiveOutputPorts(["error"], for: failedID)

        let decision = state.runDecision(
            for: downstreamID,
            edges: [edge(routerID, downstreamID, port: "mine"), edge(failedID, downstreamID, port: nil)],
            nodes: [node(routerID, "Router"), node(failedID, "Fetcher"), node(downstreamID, "Merge")]
        )

        XCTAssertEqual(decision, .skip(.upstreamFailed),
                       "reporting 'the workflow branched a different way' would hide a real crash")
    }

    /// `shouldExecuteNode` must remain a faithful wrapper — the two must never become separate
    /// answers to the same question.
    func testShouldExecuteNodeAgreesWithRunDecision() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "Fetcher"))
        let nodes = [node(upstreamID, "Fetcher"), node(downstreamID, "Next")]

        for port in [nil, WorkflowEdge.errorPortLabel] {
            let edges = [edge(upstreamID, downstreamID, port: port)]
            let runs = state.shouldExecuteNode(downstreamID, edges: edges, nodes: nodes)
            let decision = state.runDecision(for: downstreamID, edges: edges, nodes: nodes)
            XCTAssertEqual(runs, decision == .run, "the wrapper disagreed with the predicate for port \(port ?? "default")")
        }
    }

    // MARK: - Terminality over LIVE edges (WF-EX1)

    /// The defect, exactly: `A` succeeds and its error handler correctly does not run. `A` is the
    /// end of the only path that ran, so its output IS the answer.
    func testSuccessfulNodeWithAnUntakenErrorEdgeIsATerminal() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "Agent A", output: "the real answer"))
        state.recordResult(from: envelope(.skipped(reason: .errorPortNotTaken), id: downstreamID, name: "Handler", output: ""))

        let terminals = state.terminalOutputs(
            edges: [edge(upstreamID, downstreamID, port: WorkflowEdge.errorPortLabel)],
            allNodeIDs: [upstreamID, downstreamID]
        )

        XCTAssertTrue(terminals.contains { $0.profileName == "Agent A" },
                      "the node that produced the answer must be a terminal — its error edge never fired")
        let successful = terminals.filter { if case .completed = $0.status { return true }; return false }
        XCTAssertEqual(successful.count, 1, "the run has exactly one successful terminal, so it succeeded")
        XCTAssertEqual(successful.first?.text, "the real answer")
    }

    /// The control: when the error handler DID run, the upstream is no longer a terminal — the path
    /// continued through it. Without this, the fix would just make every node a terminal.
    func testNodeWhoseErrorEdgeDidFireIsNotATerminal() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.failed(.modelError(provider: "x", error: "boom")), id: upstreamID, name: "Agent A"))
        state.setActiveOutputPorts(["error"], for: upstreamID)
        state.recordResult(from: envelope(.completed, id: downstreamID, name: "Handler", output: "recovered"))

        let terminals = state.terminalOutputs(
            edges: [edge(upstreamID, downstreamID, port: WorkflowEdge.errorPortLabel)],
            allNodeIDs: [upstreamID, downstreamID]
        )

        XCTAssertFalse(terminals.contains { $0.profileName == "Agent A" },
                       "the error branch fired, so A is not where the path ended")
        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals.first?.text, "recovered")
    }

    /// An ordinary chain must be unaffected: only the last node is a terminal.
    func testPlainChainStillHasOneTerminal() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "First", output: "a"))
        state.recordResult(from: envelope(.completed, id: downstreamID, name: "Second", output: "b"))

        let terminals = state.terminalOutputs(
            edges: [edge(upstreamID, downstreamID, port: nil)],
            allNodeIDs: [upstreamID, downstreamID]
        )

        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals.first?.profileName, "Second")
    }

    // MARK: - Terminality requires a downstream that actually RAN (WF-EX1 follow-on)

    /// The fan-in that dropped finished work. R1/R2/R3 feed one Synthesizer; R3 fails, so the join
    /// correctly skips the Synthesizer. R1 and R2 fired LIVE edges into it — but nothing consumed
    /// them, so their answers are still the end of the only paths that ran.
    func testCompletedUpstreamsOfASkippedJoinAreTerminals() {
        let r1 = UUID(), r2 = UUID(), r3 = UUID(), join = UUID()
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: r1, name: "R1", output: "first finding"))
        state.recordResult(from: envelope(.completed, id: r2, name: "R2", output: "second finding"))
        state.recordResult(from: envelope(.failed(.modelError(provider: "x", error: "boom")), id: r3, name: "R3", output: ""))
        state.setActiveOutputPorts(["error"], for: r3)
        state.recordResult(from: envelope(.skipped(reason: .upstreamFailed), id: join, name: "Synthesizer", output: ""))

        let terminals = state.terminalOutputs(
            edges: [edge(r1, join, port: nil), edge(r2, join, port: nil), edge(r3, join, port: nil)],
            allNodeIDs: [r1, r2, r3, join]
        )

        let answering = terminals.filter { if case .completed = $0.status { return true }; return false }
        XCTAssertEqual(Set(answering.map(\.profileName)), ["R1", "R2"],
                       "both finished agents must reach the answer — the run used to report a bare failure and discard them")
        XCTAssertTrue(terminals.contains { $0.profileName == "R3" },
                      "the failed branch is still a terminal, so the failure is still reported")
    }

    /// The SILENT variant, and the reason this is severity-one: nothing fails, so the run reports
    /// success — and used to present the Router's pass-through as the whole answer while the real
    /// work went unmentioned.
    func testCompletedUpstreamOfAnUnchosenBranchIsATerminal() {
        let worker = UUID(), router = UUID(), join = UUID()
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: worker, name: "Worker", output: "the real answer"))
        state.recordResult(from: envelope(.completed, id: router, name: "Router", output: "routing note"))
        state.setActiveOutputPorts(["no"], for: router)
        state.recordResult(from: envelope(.skipped(reason: .notChosen), id: join, name: "Merge", output: ""))

        let terminals = state.terminalOutputs(
            edges: [edge(worker, join, port: nil), edge(router, join, port: "yes")],
            allNodeIDs: [worker, router, join]
        )

        XCTAssertTrue(terminals.contains { $0.text == "the real answer" },
                      "the worker's output must reach the answer; the run reports COMPLETED either way")
    }

    /// The guard against over-correcting: a user-skipped node DID consume its input and forwards it
    /// as its own output, so the upstream must NOT also become a terminal — that would print the
    /// same content twice.
    func testUserSkippedDownstreamStillConsumesItsUpstream() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "First", output: "a"))
        state.recordResult(from: envelope(.skipped(reason: .byUser), id: downstreamID, name: "Second", output: "a"))

        let terminals = state.terminalOutputs(
            edges: [edge(upstreamID, downstreamID, port: nil)],
            allNodeIDs: [upstreamID, downstreamID]
        )

        XCTAssertEqual(terminals.count, 1)
        XCTAssertEqual(terminals.first?.profileName, "Second",
                       "the user-skipped node carries the forwarded text; its upstream must not double-print it")
    }

    /// A downstream that FAILED still ran, so its upstream is not a terminal — the failure is the
    /// end of that path and is what the run should report.
    func testFailedDownstreamStillConsumesItsUpstream() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "First", output: "a"))
        state.recordResult(from: envelope(.failed(.modelError(provider: "x", error: "boom")), id: downstreamID, name: "Second", output: ""))

        let terminals = state.terminalOutputs(
            edges: [edge(upstreamID, downstreamID, port: nil)],
            allNodeIDs: [upstreamID, downstreamID]
        )

        XCTAssertFalse(terminals.contains { $0.profileName == "First" },
                       "the downstream ran and failed; the path ended there, not at its upstream")
    }

    // MARK: - Run verdict

    /// A run where nothing failed must report no failures, however its branches ended.
    func testFailedNodeSummariesIsEmptyWhenOnlySkipsOccurred() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "Router"))
        state.recordResult(from: envelope(.skipped(reason: .notChosen), id: downstreamID, name: "FeatureAgent"))

        XCTAssertTrue(state.failedNodeSummaries().isEmpty,
                      "an unchosen branch is not a failure, and the run verdict is derived from this")
    }

    /// …and a real failure must be named, including when it is mid-graph rather than terminal.
    func testFailedNodeSummariesNamesTheFailingNode() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.failed(.modelError(provider: "x", error: "boom")), id: upstreamID, name: "Fetcher"))
        state.recordResult(from: envelope(.skipped(reason: .upstreamFailed), id: downstreamID, name: "Summarizer"))

        let summaries = state.failedNodeSummaries()
        XCTAssertEqual(summaries.count, 1, "only the node that actually failed counts")
        XCTAssertTrue(summaries[0].contains("Fetcher"),
                      "the CAUSE must be named — reporting only terminals described the symptom")
    }

    // MARK: - WF-EX2: the `error` signal only travels down a branch a FAILURE killed
    //
    // A skip used to activate `error` unconditionally, so an error handler wired to a node that was
    // merely routed past fired on a run where nothing failed — while the run still reported success.
    // These pin both halves: the spurious activation is gone, and the genuine recovery chain (P0-6)
    // still works, at depth.
    //
    // ⚠️ The driver's rule is reproduced here exactly: record the skip, then set `["error"]` ONLY
    // when `upstreamSignalledError` is true. If that pairing changes in `WorkflowExecutor`, these
    // tests stop describing production — they are a model of it, not a call into it.
    private func applySkip(_ state: inout WorkflowState, id: UUID, name: String,
                           reason: NodeSkipReason, edges: [WorkflowEdge]) {
        let propagates = state.upstreamSignalledError(for: id, edges: edges)
        state.recordResult(from: envelope(.skipped(reason: reason), id: id, name: name, output: ""))
        if propagates {
            state.setActiveOutputPorts([WorkflowEdge.errorPortLabel], for: id)
        }
    }

    /// THE DEFECT. `A --error--> Handler --error--> Notify`, and A SUCCEEDS. Handler correctly stands
    /// down; it must not then tell Notify that Handler failed.
    func testStoodDownErrorHandlerDoesNotFireItsOwnErrorBranch() {
        let notifyID = UUID()
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "Fetcher"))

        let edges = [
            edge(upstreamID, downstreamID, port: WorkflowEdge.errorPortLabel),
            edge(downstreamID, notifyID, port: WorkflowEdge.errorPortLabel),
        ]
        XCTAssertFalse(state.upstreamSignalledError(for: downstreamID, edges: edges),
                       "a SUCCESSFUL upstream activates no error port, so nothing may propagate")
        applySkip(&state, id: downstreamID, name: "Handler", reason: .errorPortNotTaken, edges: edges)

        XCTAssertFalse(state.edgeIsLive(edges[1]),
                       "Notify must NOT run — nothing in this workflow failed")
        XCTAssertEqual(state.runDecision(for: notifyID, edges: edges,
                                         nodes: [node(upstreamID, "Fetcher"), node(downstreamID, "Handler"), node(notifyID, "Notify")]),
                       .skip(.upstreamSkipped))
    }

    /// P0-6 must survive: when something genuinely FAILED, the recovery chain still fires through a
    /// skipped intermediate node.
    func testFailureStillPropagatesThroughASkippedNodeToItsErrorBranch() {
        let recoveryID = UUID()
        var state = WorkflowState()
        state.recordResult(from: envelope(.failed(.modelError(provider: "x", error: "boom")), id: upstreamID, name: "Fetcher"))
        state.setActiveOutputPorts([WorkflowEdge.errorPortLabel], for: upstreamID)   // what the driver does on failure

        let edges = [
            edge(upstreamID, downstreamID, port: nil),
            edge(downstreamID, recoveryID, port: WorkflowEdge.errorPortLabel),
        ]
        XCTAssertTrue(state.upstreamSignalledError(for: downstreamID, edges: edges),
                      "a FAILED upstream must keep the error signal alive down the dead branch")
        applySkip(&state, id: downstreamID, name: "Summarizer", reason: .upstreamFailed, edges: edges)

        XCTAssertTrue(state.edgeIsLive(edges[1]),
                      "the recovery branch must still run — this is the P0-6 dead-end this fix must not reintroduce")
    }

    /// ⚠️ THE HOP-2 CASE, and the reason this is not gated on `NodeSkipReason.indicatesProblem`.
    /// A cascade from a Router decision is reported as `.upstreamSkipped`, whose `indicatesProblem`
    /// is TRUE — so a reason-based gate would fix the first hop and re-activate `error` on the
    /// second. Keying off the upstream's ports instead stays correct all the way down.
    func testRoutingCascadeDoesNotResurrectTheErrorPortTwoHopsDown() {
        let midID = UUID(), tailID = UUID()
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "Router"))
        state.setActiveOutputPorts(["approve"], for: upstreamID)                     // Router chose the OTHER port

        let edges = [
            edge(upstreamID, downstreamID, port: "reject"),
            edge(downstreamID, midID, port: nil),
            edge(midID, tailID, port: WorkflowEdge.errorPortLabel),
        ]
        applySkip(&state, id: downstreamID, name: "RejectBranch", reason: .notChosen, edges: edges)

        let midReason = state.runDecision(for: midID, edges: edges,
                                          nodes: [node(upstreamID, "Router"), node(downstreamID, "RejectBranch"),
                                                  node(midID, "Mid"), node(tailID, "Tail")])
        XCTAssertEqual(midReason, .skip(.upstreamSkipped))
        if case .skip(let r) = midReason {
            XCTAssertTrue(r.indicatesProblem,
                          "precondition: this label DOES report a problem, which is exactly why it is the wrong gate")
        }
        applySkip(&state, id: midID, name: "Mid", reason: .upstreamSkipped, edges: edges)

        XCTAssertFalse(state.upstreamSignalledError(for: midID, edges: edges),
                       "nothing failed anywhere on this run")
        XCTAssertFalse(state.edgeIsLive(edges[2]),
                       "Tail must stay dead two hops below an unchosen Router branch")
    }

    /// A cancelled upstream activates no ports, so it does not start a recovery chain either —
    /// Stop is a teardown, not a failure to handle.
    func testCancelledUpstreamDoesNotPropagateAnErrorSignal() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.canceled, id: upstreamID, name: "Fetcher"))

        let edges = [edge(upstreamID, downstreamID, port: WorkflowEdge.errorPortLabel)]
        XCTAssertFalse(state.upstreamSignalledError(for: downstreamID, edges: edges))
    }

    // MARK: - WF-EX1: why an EMPTY port label must never be activated

    /// ⚠️ THIS PINS THE HAZARD, NOT THE FIX — and it asserts the CURRENT behaviour of `edgeIsLive`
    /// on purpose, so the cost of activating `""` stays visible to whoever reads that method next.
    ///
    /// `edgeIsLive` resolves an edge's port as `edge.sourcePortLabel ?? ""`. So an active port set of
    /// `[""]` does not merely fail to match anything — it matches every UNLABELLED edge out of the
    /// node. That is why WF-EX1 was worse than a dead branch: a Router whose AI Classifier returned
    /// an unreadable reply resolved `""`, and the run then travelled down the default edge exactly as
    /// if a rule had matched, while reporting success.
    ///
    /// The fix is upstream of here — nothing may put `""` into `activeOutputPorts` — and
    /// `WorkflowExecutor` now discards an empty resolved label before activating it. If this test
    /// ever starts failing because `edgeIsLive` stopped treating `""` as the default port, that
    /// guard can be revisited; until then it is load-bearing.
    func testAnEmptyActivePortWouldMakeUnlabelledEdgesLive() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "Router"))
        state.setActiveOutputPorts([""], for: upstreamID)

        let defaultEdge = edge(upstreamID, downstreamID, port: nil)
        XCTAssertTrue(state.edgeIsLive(defaultEdge),
                      "an empty active port collides with the default port — this is the harm WF-EX1's guard prevents")

        let namedEdge = edge(upstreamID, UUID(), port: "Urgent")
        XCTAssertFalse(state.edgeIsLive(namedEdge),
                       "…while every genuinely-labelled branch stays dead, so the run silently takes the wrong one")
    }

    /// The correct shape for comparison: a real label activates exactly its own branch.
    func testANamedActivePortActivatesOnlyItsOwnBranch() {
        var state = WorkflowState()
        state.recordResult(from: envelope(.completed, id: upstreamID, name: "Router"))
        state.setActiveOutputPorts(["Urgent"], for: upstreamID)

        XCTAssertTrue(state.edgeIsLive(edge(upstreamID, downstreamID, port: "Urgent")))
        XCTAssertFalse(state.edgeIsLive(edge(upstreamID, UUID(), port: nil)),
                       "the default edge must NOT fire when the Router made an explicit choice")
    }
}
