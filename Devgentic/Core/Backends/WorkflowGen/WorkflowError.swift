//
//  WorkflowError.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Error types specific to workflow orchestration.
//

import Foundation

/// Errors that can occur during workflow execution.
enum WorkflowError: LocalizedError, Sendable {
    /// The workflow layout is empty (no nodes defined on the canvas).
    case emptyWorkflow

    /// The workflow DAG contains a cycle (should be prevented by the canvas, but safety check).
    case cycleDetected

    /// A referenced profile could not be found in BackendProfileService.
    case profileNotFound(profileID: UUID, nodeName: String)

    /// A node exceeded its execution timeout.
    case nodeTimeout(nodeID: UUID, profileName: String, timeout: TimeInterval)

    /// A node failed with an inner executor error.
    case nodeExecutionFailed(nodeID: UUID, profileName: String, underlyingError: String)

    /// All upstream dependencies for a node failed, so it cannot execute.
    case allUpstreamsFailed(nodeID: UUID, profileName: String)

    /// Pre-flight validation found configuration errors that must be resolved before execution.
    case validationFailed(errors: [WorkflowValidationIssue], summary: String)

    /// The stored canvas blob could not be decoded, so the run is refused before dispatch (WF-OB4).
    ///
    /// ⚠️ Distinct from `emptyWorkflow` on purpose. `WorkflowLayoutStore.load(for:)` deliberately
    /// returns `.empty` for a missing row AND an unreadable blob, so without this case an
    /// unreadable canvas ran into the `!layout.nodes.isEmpty` guard and the user was told "The
    /// workflow has no nodes. Add profiles to the canvas before running." — both halves false: the
    /// denormalized counts prove nodes exist, and the canvas REFUSES every save while unreadable,
    /// so the suggested remedy was impossible. The counts ride along because they are the evidence
    /// (they live outside the blob, written by the last successful save).
    case layoutUnreadable(nodeCount: Int, edgeCount: Int)

    var errorDescription: String? {
        switch self {
        case .emptyWorkflow:
            return "The workflow has no nodes. Add profiles to the canvas before running."
        case .cycleDetected:
            return "The workflow contains a cycle. Please remove circular connections."
        case .profileNotFound(_, let name):
            return "Profile '\(name)' was not found. It may have been deleted."
        case .nodeTimeout(_, let name, let timeout):
            return "Node '\(name)' exceeded the \(Int(timeout))s timeout."
        case .nodeExecutionFailed(_, let name, let error):
            return "Node '\(name)' failed: \(error)"
        case .allUpstreamsFailed(_, let name):
            return "All upstream nodes for '\(name)' failed. Cannot execute."
        case .validationFailed(_, let summary):
            return "Workflow has configuration errors that must be resolved:\n\(summary)"
        case .layoutUnreadable(let nodes, let edges):
            return "This workflow's saved canvas could not be read by this version of the app. It last held \(nodes) node\(nodes == 1 ? "" : "s") and \(edges) connection\(edges == 1 ? "" : "s") — the data is intact but the run is blocked to protect it. Open the workflow's canvas to review, repair, or discard it."
        }
    }
}
