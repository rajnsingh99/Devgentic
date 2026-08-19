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
        self.isLive = displayData.isRunning
    }

    func status(for nodeID: UUID) -> NodeStatus? { nodeStatus[nodeID] }

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
        if source == .skipped || target == .skipped { return .notTaken }
        if source.didRun && target.didRun { return .fired }
        return .undetermined
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
