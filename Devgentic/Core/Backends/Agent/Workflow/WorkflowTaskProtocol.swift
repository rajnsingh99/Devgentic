//
//  WorkflowTaskProtocol.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  In-process A2A-inspired protocol types for inter-node communication.
//  These types flow between the WorkflowExecutor (orchestrator) and inner executors (nodes).
//

import Foundation

// MARK: - Task Envelope (Orchestrator → Node)

/// The payload sent from the WorkflowExecutor to an inner node's executor.
/// Contains the original query, upstream results, and execution constraints.
struct WorkflowTaskEnvelope: Sendable {
    /// Unique identifier for this task execution.
    let taskID: UUID

    /// The canvas node this task maps to.
    let nodeID: UUID

    /// The BackendProfileModel being executed at this node.
    let sourceProfileID: UUID

    /// The original user query (or a rewritten sub-query for downstream nodes).
    let query: String

    /// Results from all direct upstream nodes (injected as context).
    let upstreamContext: [NodeResultEnvelope]

    /// Execution constraints (timeouts, iteration caps).
    let constraints: ExecutionConstraints

    init(
        taskID: UUID = UUID(),
        nodeID: UUID,
        sourceProfileID: UUID,
        query: String,
        upstreamContext: [NodeResultEnvelope] = [],
        constraints: ExecutionConstraints = .default
    ) {
        self.taskID = taskID
        self.nodeID = nodeID
        self.sourceProfileID = sourceProfileID
        self.query = query
        self.upstreamContext = upstreamContext
        self.constraints = constraints
    }
}

// MARK: - Result Envelope (Node → Orchestrator)

/// The result returned from an inner node's executor back to the WorkflowExecutor.
/// Contains the synthesized output, artifacts, and execution metadata.
struct NodeResultEnvelope: Sendable {
    /// Unique identifier matching the originating task.
    let taskID: UUID

    /// The canvas node that produced this result.
    let nodeID: UUID

    /// The BackendProfileModel that was executed.
    let sourceProfileID: UUID

    /// Display name of the profile (for context injection readability).
    let profileName: String

    /// Whether this was a Bot or Agent.
    let profileType: ProfileType

    /// Terminal execution status.
    let status: NodeExecutionStatus

    /// The synthesized text response from the inner executor.
    let output: String

    /// Tool results produced during execution (for traceability).
    let artifacts: [ToolOutput]

    /// Execution metadata (timing, token usage, tools invoked).
    let metadata: NodeExecutionMetadata
}

// MARK: - Node Execution Status

/// Terminal states for a single node's execution within a workflow.
enum NodeExecutionStatus: Sendable {
    /// Node completed successfully.
    case completed

    /// Node encountered an unrecoverable error.
    case failed(String)

    /// Node was canceled (user or timeout).
    case canceled

    /// Node was skipped because an upstream dependency failed.
    case skipped(reason: String)
}

// MARK: - Execution Constraints

/// Per-node execution limits enforced by the WorkflowExecutor.
struct ExecutionConstraints: Sendable {
    /// Maximum wall-clock time for this node (seconds). Default: 120s.
    let maxDuration: TimeInterval

    /// Optional override for the inner executor's max iteration count.
    let maxIterations: Int?

    static let `default` = ExecutionConstraints(maxDuration: 120, maxIterations: nil)

    init(maxDuration: TimeInterval = 120, maxIterations: Int? = nil) {
        self.maxDuration = maxDuration
        self.maxIterations = maxIterations
    }
}

// MARK: - Node Execution Metadata

/// Telemetry data collected during a single node's execution.
struct NodeExecutionMetadata: Sendable {
    /// When this node started executing.
    let startTime: Date

    /// When this node finished executing.
    let endTime: Date

    /// Number of reasoning iterations consumed (for agent nodes).
    let iterationsUsed: Int

    /// Names of tools invoked during execution.
    let toolsInvoked: [String]

    /// Estimated token count for the output.
    let tokenEstimate: Int

    /// Computed duration in seconds.
    var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }

    /// Convenience initializer with defaults for simple bot nodes.
    static func simple(start: Date, end: Date, output: String) -> NodeExecutionMetadata {
        NodeExecutionMetadata(
            startTime: start,
            endTime: end,
            iterationsUsed: 1,
            toolsInvoked: [],
            tokenEstimate: output.count / 4
        )
    }
}
