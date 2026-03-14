//
//  WorkflowMemoryStrategy.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Workflow-level result tracking and upstream context resolution.
//  Each WorkflowExecutor run maintains one instance to collect node results
//  and resolve upstream dependencies for context injection.
//

import Foundation

/// Tracks execution results across all nodes in a workflow run.
/// Used by `WorkflowExecutor` to resolve upstream context for each node.
struct WorkflowMemoryStrategy: Sendable {

    /// Completed node results keyed by nodeID.
    private var nodeResults: [UUID: NodeResultEnvelope] = [:]

    /// Chronological execution log for traceability.
    private(set) var executionLog: [WorkflowLogEntry] = []

    // MARK: - Record

    /// Records a completed node result.
    mutating func recordNodeResult(_ result: NodeResultEnvelope) {
        nodeResults[result.nodeID] = result
        executionLog.append(WorkflowLogEntry(
            timestamp: Date(),
            nodeID: result.nodeID,
            profileName: result.profileName,
            profileType: result.profileType,
            status: result.status,
            outputPreview: String(result.output.prefix(200)),
            duration: result.metadata.duration
        ))
    }

    // MARK: - Query

    /// Returns all completed upstream results for a given node based on the edge topology.
    /// - Parameters:
    ///   - nodeID: The target node to look up upstream results for.
    ///   - edges: All edges in the workflow layout.
    /// - Returns: Array of `NodeResultEnvelope` from all direct upstream nodes.
    func upstreamResults(for nodeID: UUID, edges: [WorkflowEdge]) -> [NodeResultEnvelope] {
        let upstreamNodeIDs = edges
            .filter { $0.targetNodeID == nodeID }
            .map(\.sourceNodeID)
        return upstreamNodeIDs.compactMap { nodeResults[$0] }
    }

    /// Returns the result for a specific node, if available.
    func result(for nodeID: UUID) -> NodeResultEnvelope? {
        nodeResults[nodeID]
    }

    /// Returns all terminal node results (nodes with no outgoing edges).
    func terminalResults(edges: [WorkflowEdge], allNodeIDs: [UUID]) -> [NodeResultEnvelope] {
        let nodesWithOutgoing = Set(edges.map(\.sourceNodeID))
        let terminalNodeIDs = allNodeIDs.filter { !nodesWithOutgoing.contains($0) }
        return terminalNodeIDs.compactMap { nodeResults[$0] }
    }

    /// Whether all upstream nodes for a given node completed successfully.
    func allUpstreamsSucceeded(for nodeID: UUID, edges: [WorkflowEdge]) -> Bool {
        let upstreamNodeIDs = edges
            .filter { $0.targetNodeID == nodeID }
            .map(\.sourceNodeID)

        // If there are no upstream nodes, it's an entry node — always allowed
        guard !upstreamNodeIDs.isEmpty else { return true }

        return upstreamNodeIDs.allSatisfy { upstreamID in
            if let result = nodeResults[upstreamID], case .completed = result.status {
                return true
            }
            return false
        }
    }
}

// MARK: - Workflow Log Entry

/// A single entry in the workflow execution log.
struct WorkflowLogEntry: Sendable {
    let timestamp: Date
    let nodeID: UUID
    let profileName: String
    let profileType: ProfileType
    let status: NodeExecutionStatus
    let outputPreview: String
    let duration: TimeInterval
}
