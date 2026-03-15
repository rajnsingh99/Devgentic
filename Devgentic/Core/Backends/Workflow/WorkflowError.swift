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
        }
    }
}
