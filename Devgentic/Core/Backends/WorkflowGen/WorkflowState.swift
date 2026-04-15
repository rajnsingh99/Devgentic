//
//  WorkflowState.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Typed workflow execution state. Stores full per-node outputs (not truncated),
//  shared mutable variables, loop counters, and execution log.
//  Context compression is deferred to injection time (ContextCompressor)
//  rather than storage time.
//

import Foundation
import os

private let wfStateLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "WorkflowState")

// MARK: - Node Output

/// Full output from a single node's execution. Unlike NodeResultEnvelope
/// (which carries profile metadata for UI/tracing), NodeOutput focuses on
/// the data a downstream node needs: text, artifacts, status.
struct NodeOutput: Sendable {
    let text: String
    let artifacts: [MediaArtifact]
    let metadata: NodeExecutionMetadata
    let status: NodeExecutionStatus
    let profileName: String
    let profileType: ProfileType
    let sourceProfileID: UUID
}

// MARK: - Workflow State

/// Typed workflow execution state that tracks per-node outputs, shared variables,
/// and loop counters.
///
/// - Stores `NodeOutput` (text + artifacts + metadata) instead of full `NodeResultEnvelope`
/// - `variables` for shared mutable state (Code/Loop nodes can write)
/// - `loopCounters` for iteration tracking
/// - Context compression happens at injection time (per-LLM-node), not storage time
struct WorkflowState: Sendable {

    /// Full per-node outputs keyed by nodeID.
    private(set) var nodeOutputs: [UUID: NodeOutput] = [:]

    /// Shared mutable variables across nodes.
    /// Code nodes and Loop nodes can write to these; any node can read.
    private(set) var variables: [String: String] = [:]

    /// Loop iteration counters keyed by loop node ID.
    private(set) var loopCounters: [UUID: Int] = [:]

    /// Active output ports per node. When set, only edges from these port labels are followed.
    /// Used by condition nodes to selectively activate downstream branches.
    /// Key = nodeID, Value = set of active port labels. Nil/missing = all ports active.
    private(set) var activeOutputPorts: [UUID: Set<String>] = [:]

    /// Chronological execution log for traceability.
    private(set) var executionLog: [WorkflowLogEntry] = []

    // MARK: - Record

    /// Records a node's execution result from a NodeResultEnvelope.
    mutating func recordResult(from envelope: NodeResultEnvelope) {
        let statusLabel: String
        switch envelope.status {
        case .completed: statusLabel = "completed"
        case .failed(let reason): statusLabel = "failed(\(reason.localizedDescription))"
        case .canceled: statusLabel = "canceled"
        case .skipped(let reason): statusLabel = "skipped(\(reason))"
        }
        wfStateLogger.info("Recording result: node=\(envelope.profileName) [\(envelope.nodeID)] status=\(statusLabel) duration=\(String(format: "%.1f", envelope.metadata.duration))s output=\(envelope.output.count) chars")
        wfStateLogger.debug("Node '\(envelope.profileName)' output preview: \(String(envelope.output.prefix(300)))")

        nodeOutputs[envelope.nodeID] = NodeOutput(
            text: envelope.output,
            artifacts: envelope.artifacts,
            metadata: envelope.metadata,
            status: envelope.status,
            profileName: envelope.profileName,
            profileType: envelope.profileType,
            sourceProfileID: envelope.sourceProfileID
        )
        executionLog.append(WorkflowLogEntry(
            timestamp: Date(),
            nodeID: envelope.nodeID,
            profileName: envelope.profileName,
            profileType: envelope.profileType,
            status: envelope.status,
            outputPreview: String(envelope.output.prefix(200)),
            duration: envelope.metadata.duration
        ))
    }

    /// Sets a shared variable (for Code/Loop nodes).
    mutating func setVariable(_ key: String, value: String) {
        wfStateLogger.info("Variable set: '\(key)' = \(String(value.prefix(200))) (\(value.count) chars)")
        variables[key] = value
    }

    /// Increments a loop counter and returns the new value.
    @discardableResult
    mutating func incrementLoopCounter(for nodeID: UUID) -> Int {
        loopCounters[nodeID, default: 0] += 1
        return loopCounters[nodeID]!
    }

    /// Resets a loop counter (when loop exits).
    mutating func resetLoopCounter(for nodeID: UUID) {
        loopCounters.removeValue(forKey: nodeID)
    }

    /// Sets which output ports are active for a node (used by condition nodes).
    /// Only edges from active ports will be followed for downstream execution.
    mutating func setActiveOutputPorts(_ ports: Set<String>, for nodeID: UUID) {
        wfStateLogger.info("Port activation: node=\(nodeID) activePorts=[\(ports.sorted().joined(separator: ", "))]")
        activeOutputPorts[nodeID] = ports
    }

    // MARK: - Query

    /// Returns the full output for a specific node, if available.
    func output(for nodeID: UUID) -> NodeOutput? {
        nodeOutputs[nodeID]
    }

    /// Returns all upstream node outputs for a given node based on edge topology.
    func upstreamOutputs(for nodeID: UUID, edges: [WorkflowEdge]) -> [NodeOutput] {
        let upstreamNodeIDs = edges
            .filter { $0.targetNodeID == nodeID }
            .map(\.sourceNodeID)
        return upstreamNodeIDs.compactMap { nodeOutputs[$0] }
    }

    /// Returns upstream results as NodeResultEnvelope, filtered by active output ports.
    ///
    /// When an upstream node has explicit port activation (e.g., condition routing or error port),
    /// only edges whose `sourcePortLabel` matches an active port are included. This prevents
    /// inactive branch data from leaking into downstream nodes.
    func upstreamResultEnvelopes(for nodeID: UUID, edges: [WorkflowEdge]) -> [NodeResultEnvelope] {
        let incomingEdges = edges.filter { $0.targetNodeID == nodeID }

        let envelopes = incomingEdges.compactMap { edge -> NodeResultEnvelope? in
            let uid = edge.sourceNodeID
            guard let output = nodeOutputs[uid] else { return nil }

            // Port-level filtering: if upstream has explicit active ports,
            // only include results from edges matching an active port.
            if let activePorts = activeOutputPorts[uid] {
                let edgePort = edge.sourcePortLabel ?? ""
                guard activePorts.contains(edgePort) else {
                    wfStateLogger.info("Upstream '\(output.profileName)' filtered out: port '\(edgePort)' not in active ports [\(activePorts.sorted().joined(separator: ", "))]")
                    return nil
                }
            }

            return NodeResultEnvelope(
                taskID: UUID(),
                nodeID: uid,
                sourceProfileID: output.sourceProfileID,
                profileName: output.profileName,
                profileType: output.profileType,
                status: output.status,
                output: output.text,
                artifacts: output.artifacts,
                metadata: output.metadata
            )
        }
        let names = envelopes.map(\.profileName).joined(separator: ", ")
        wfStateLogger.info("Upstream envelopes for node \(nodeID): \(envelopes.count) results from [\(names)]")
        for env in envelopes {
            wfStateLogger.debug("  Upstream '\(env.profileName)': \(env.output.count) chars, preview: \(String(env.output.prefix(200)))")
        }
        return envelopes
    }

    /// Whether a downstream node should execute based on upstream status and port activation.
    /// Checks: (1) upstream completed, has continueAll policy, or edge is an error route,
    /// (2) the connecting edge's port label matches the upstream's active output ports.
    func shouldExecuteNode(_ nodeID: UUID, edges: [WorkflowEdge], nodes: [WorkflowNode]) -> Bool {
        let incomingEdges = edges.filter { $0.targetNodeID == nodeID }
        let nodeName = nodes.first(where: { $0.id == nodeID })?.displayName ?? nodeID.uuidString

        guard !incomingEdges.isEmpty else {
            wfStateLogger.info("Routing: '\(nodeName)' → EXECUTE (entry node, no incoming edges)")
            return true
        }

        let result = incomingEdges.allSatisfy { edge in
            let upstreamID = edge.sourceNodeID

            guard let output = nodeOutputs[upstreamID] else { return false }
            let upstreamNode = nodes.first(where: { $0.id == upstreamID })
            let isCompleted: Bool
            if case .completed = output.status {
                isCompleted = true
            } else {
                isCompleted = false
            }
            let isContinueAll = upstreamNode?.nodeConfig?.onFailure == .continueAll

            // Error routing: if this edge comes from an "error" port and the upstream
            // has activated that port (due to failure), allow execution regardless of status.
            let isErrorRoute = edge.sourcePortLabel == "error"
                && activeOutputPorts[upstreamID]?.contains("error") == true

            guard isCompleted || isContinueAll || isErrorRoute else { return false }

            // Port-level activation check.
            if let activePorts = activeOutputPorts[upstreamID] {
                // Upstream has explicit port activation (condition routing or error port).
                // Skip port filtering only when upstream passed via continueAll and failed.
                if isContinueAll && !isCompleted { return true }
                let edgePort = edge.sourcePortLabel ?? ""
                return activePorts.contains(edgePort)
            }

            // No explicit port activation on upstream.
            // Completed nodes: all edges pass through — no selective routing needed.
            // This also provides backward compatibility for profile nodes whose
            // edges were created with sourcePortLabel="error" (the only port previously).
            // Non-completed (continueAll): only default edges pass; labeled routes
            // like "error" require explicit activation via setActiveOutputPorts.
            if isCompleted {
                return true
            }
            if let label = edge.sourcePortLabel, !label.isEmpty {
                return false // Non-completed: block labeled edges without active port
            }
            return true
        }
        wfStateLogger.info("Routing: '\(nodeName)' → \(result ? "EXECUTE" : "SKIP") (incoming edges: \(incomingEdges.count))")
        return result
    }

    /// Returns outputs from all terminal nodes (nodes with no outgoing edges).
    func terminalOutputs(edges: [WorkflowEdge], allNodeIDs: [UUID]) -> [NodeOutput] {
        let nodesWithOutgoing = Set(edges.map(\.sourceNodeID))
        let terminalNodeIDs = allNodeIDs.filter { !nodesWithOutgoing.contains($0) }
        return terminalNodeIDs.compactMap { nodeOutputs[$0] }
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
