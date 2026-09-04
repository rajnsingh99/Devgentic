//
//  WorkflowCanvasRunOverlay.swift
//  Devgentic
//
//  Projects a run's per-node outcome onto the CANVAS.
//
//  Until 2026-08-15 the canvas showed nothing about execution: `WorkflowCanvasView` did not even
//  receive execution state, `WorkflowCanvasState` had no per-node status field, and
//  `WorkflowNodeView` carried an empty `.overlay(alignment: .topLeading) { }` where a badge was
//  clearly once intended. During and after a run every node looked exactly as it had before it —
//  the user could not see which node was executing, which finished, which failed, or which never
//  ran. Worse, a Router with three output ports drew three identical curves, so the one question
//  the canvas is uniquely able to answer — WHICH BRANCH DID IT TAKE? — was unanswerable there.
//
//  ⚠️ Edge liveness is DERIVED, not reported. The engine's authoritative answer lives in
//  `WorkflowState.edgeIsLive`, which needs `activeOutputPorts` — run state the UI never receives.
//  Rather than plumb the engine's internals into a view (and create a second, drifting copy of the
//  routing rules — the defect class `edgeIsLive` itself exists to prevent), this reasons only from
//  what each ENDPOINT did, which the run record already carries. See `edgeState(from:to:)` for
//  exactly what that can and cannot conclude.
//

import Foundation

struct WorkflowCanvasRunOverlay: Equatable {

    typealias NodeStatus = WorkflowRunDisplayData.NodeDisplayData.NodeStatus

    /// How an edge behaved on this run.
    enum EdgeState: Equatable {
        /// Nothing can be concluded yet — an endpoint has not reached a terminal state.
        case undetermined
        /// Both endpoints ran, so this connection carried the run.
        case fired
        /// An endpoint did not run, so this connection was not taken.
        case notTaken
    }

    /// Per-node outcome, keyed by canvas node id. Missing = the node produced no event at all
    /// (never reached), which reads as `.undetermined` rather than as anything having gone wrong.
    private let nodeStatus: [UUID: NodeStatus]

    /// Why each skipped node did not run. Absent for every node that is not `.skipped`, and for
    /// records written before the reason reached the display layer — both read as "dead branch",
    /// which is the pre-existing behaviour and the safe direction.
    private let skipReason: [UUID: NodeSkipReason]

    /// True while the run is still executing — drives the pulsing treatment on the running node.
    let isLive: Bool

    /// Builds an overlay from whatever the run screen is already displaying.
    ///
    /// Returns `nil` when there is no run to show, so "no run selected" stays visually identical to
    /// the canvas before this existed — a builder who has never executed anything sees no run
    /// chrome at all.
    init?(displayData: WorkflowRunDisplayData?) {
        guard let displayData, !displayData.nodeResults.isEmpty else { return nil }
        self.nodeStatus = Dictionary(
            displayData.nodeResults.map { ($0.nodeID, $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        // The flat `NodeStatus` cannot say WHY a node was skipped, and one reason behaves the
        // opposite of the rest — see `carriedTheRun`.
        self.skipReason = Dictionary(
            displayData.nodeResults.compactMap { row in row.skipReason.map { (row.nodeID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        self.isLive = displayData.isRunning
    }

    func status(for nodeID: UUID) -> NodeStatus? { nodeStatus[nodeID] }

    /// Did the run flow THROUGH this node, whether or not the node itself executed?
    ///
    /// ⚠️ A user skip is a PASS-THROUGH, not a dead branch: it is the one skip reason whose
    /// downstream still runs — the node's input is forwarded as its output and every default edge
    /// below it stays live (`NodeSkipReason.keepsDownstreamAlive`, and that type's own doc comment
    /// warns that matchers assuming "skipped ⇒ downstream never ran" must handle it separately).
    /// Three engine sites already did; this overlay did not, so skipping a node mid-pipeline drew
    /// BOTH its edges dead even though the node below it ran on this node's input.
    private func carriedTheRun(_ nodeID: UUID) -> Bool {
        guard let status = nodeStatus[nodeID] else { return false }
        if status == .skipped { return skipReason[nodeID]?.keepsDownstreamAlive ?? false }
        return status.didRun
    }

    /// Whether the run decided anything about the branch through this node. Unknown reason ⇒ true,
    /// preserving the older behaviour for any skip whose reason did not survive decoding.
    private func branchWasDecided(_ nodeID: UUID) -> Bool {
        skipReason[nodeID]?.decidedTheBranch ?? true
    }

    /// Whether this edge carried the run.
    ///
    /// The rule, and its limits:
    ///
    /// - **Either endpoint did not run → `.notTaken`.** Sound in both directions. A skipped target
    ///   was not fed by this edge, and a skipped source fed nothing.
    /// - **Both endpoints ran → `.fired`.** ⚠️ An APPROXIMATION where a node has several live
    ///   upstreams: it proves the target ran, not that it ran *because of this particular edge*.
    ///   The case it can over-report is a fan-in where two upstreams both completed but only one
    ///   port was wired through — rare, and the failure mode is a highlighted edge rather than a
    ///   wrong verdict. Every case the user actually asks about (which Router arm fired, did the
    ///   error handler run) is decided by the first rule, which is exact.
    /// - **Anything else → `.undetermined`**, drawn exactly as it is today.
    func edgeState(from sourceID: UUID, to targetID: UUID) -> EdgeState {
        guard let source = nodeStatus[sourceID], let target = nodeStatus[targetID] else {
            return .undetermined
        }
        // A skip only kills the edge when the branch below it is genuinely dead AND the run
        // actually decided something about it. A `.notReached` node is neither: the run ended
        // before it, so its edges stay neutral — see `decidedTheBranch` (CF-29).
        if (source == .skipped && !carriedTheRun(sourceID) && branchWasDecided(sourceID))
            || (target == .skipped && !carriedTheRun(targetID) && branchWasDecided(targetID)) { return .notTaken }
        // `.undetermined` is still reachable and still important: a target that has not started
        // yet (`.pending`) must stay neutral during a live run rather than claim the edge fired.
        if carriedTheRun(sourceID) && carriedTheRun(targetID) { return .fired }
        return .undetermined
    }
}

extension WorkflowCanvasRunOverlay {

    /// Whether a node's run badge should PULSE (register CVV-4).
    ///
    /// Only the node executing RIGHT NOW, on a run that is still going. A historical run's
    /// `.running` node is a node that never settled — animating it would claim work is still
    /// happening in a run that has ended.
    ///
    /// ⚠️ `nonisolated static` and pure (WF-UI5) because this rule is the fix. It used to live in a
    /// `View`'s private computed property, read exactly once from `.onAppear` — and the badge is
    /// inserted when the CANVAS is, not when the node starts, because
    /// `WorkflowRunDisplayData.buildNodesFromLayout` pre-populates a `.pending` placeholder for
    /// every layout node. So `.onAppear` always fired while the answer was still false, the guard
    /// dropped the arming, and nothing re-ran it when the node actually started.
    nonisolated static func badgeShouldPulse(status: NodeStatus?, isLive: Bool) -> Bool {
        isLive && status == .running
    }
}

extension WorkflowRunDisplayData.NodeDisplayData.NodeStatus {

    /// Whether the node actually executed. `.cancelled` counts — it started, it just did not finish.
    var didRun: Bool {
        switch self {
        // `.unknown` = finished under a NEWER build — it ran; we just cannot classify how.
        case .completed, .failed, .running, .cancelled, .unknown: return true
        case .pending, .skipped: return false
        }
    }

    /// Whether this outcome deserves the user's attention on the canvas. A node that did not run
    /// because the workflow branched elsewhere is ordinary routing, not a problem — badging it in
    /// the failure colour is exactly the conflation the node state model was rebuilt to remove.
    var warrantsAttention: Bool {
        self == .failed
    }
}
