// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowCanvasRunOverlay.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Projects a run's per-node outcome onto the canvas, including which branch of a Router was taken.
/// Edge liveness is derived from what each endpoint did, not from engine routing state the UI never receives.
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
    /// Returns nil when there is no run to show, so "no run selected" shows no run chrome at all.
    init?(displayData: WorkflowRunDisplayData?) {
        guard let displayData, !displayData.nodeResults.isEmpty else { return nil }
        self.nodeStatus = Dictionary(
            displayData.nodeResults.map { ($0.nodeID, $0.status) },
            uniquingKeysWith: { first, _ in first }
        )
        // The flat `NodeStatus` cannot say why a node was skipped, and one reason behaves unlike the rest (see `carriedTheRun`).
        self.skipReason = Dictionary(
            displayData.nodeResults.compactMap { row in row.skipReason.map { (row.nodeID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        self.isLive = displayData.isRunning
    }

    func status(for nodeID: UUID) -> NodeStatus? { nodeStatus[nodeID] }

    /// Returns whether the run flowed through this node, whether or not the node itself executed.
    /// A user skip is a pass-through: input is forwarded and downstream edges stay live (`keepsDownstreamAlive`).
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

    /// Returns whether this edge carried the run, reasoning only from what each endpoint did.
    /// Either endpoint did not run: `.notTaken` (exact). Both ran: `.fired`, which over-reports only for some fan-ins.
    /// Anything else is `.undetermined`, drawn neutrally.
    func edgeState(from sourceID: UUID, to targetID: UUID) -> EdgeState {
        guard let source = nodeStatus[sourceID], let target = nodeStatus[targetID] else {
            return .undetermined
        }
        // A skip kills the edge only when the branch below it is genuinely dead and the run decided something about it;
        // a `.notReached` node is neither, so its edges stay neutral (see `decidedTheBranch`).
        if (source == .skipped && !carriedTheRun(sourceID) && branchWasDecided(sourceID))
            || (target == .skipped && !carriedTheRun(targetID) && branchWasDecided(targetID)) { return .notTaken }
        // `.undetermined` is still reachable and still important: a target that has not started
        // yet (`.pending`) must stay neutral during a live run rather than claim the edge fired.
        if carriedTheRun(sourceID) && carriedTheRun(targetID) { return .fired }
        return .undetermined
    }
}

extension WorkflowCanvasRunOverlay {

    // Why: `nonisolated static` and pure so the rule is testable; read once from `.onAppear` it was always false at arming time.
    /// Returns whether a node's run badge pulses: only the node executing now, on a run still in progress.
    /// A historical run's `.running` node never settled, so animating it would claim work is still happening.
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
