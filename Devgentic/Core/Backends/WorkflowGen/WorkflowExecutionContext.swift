//
//  WorkflowExecutionContext.swift
//  Devgentic
//
//  Created by Claude on 13/04/26.
//
//  In-memory value type carrying workflow-specific execution metadata through
//  the AgentConnect → Executor → Generator pipeline. Enables the agent flow
//  to distinguish workflow node execution from normal chat, allowing targeted
//  prompt construction that eliminates RAG, history, and competing directives.
//
//  Never serialized — exists only during a single node's execution lifetime.
//

import Foundation

/// Workflow-specific execution context passed from `WorkflowExecutor` through
/// `AgentConnect` to the `WorkflowCognitiveGenerator`.
///
/// Carries the two inputs a workflow node needs:
/// - `taskDescription`: WHAT to do (per-node directive, merged with user query for first nodes)
/// - `upstreamInput`: WITH what data (clean text from upstream nodes)
struct WorkflowExecutionContext: Sendable {

    /// Per-node task description from `WorkflowNodeConfig.taskDescription`.
    /// For first nodes, the original user query (if any) is merged into this field
    /// by `WorkflowExecutor.executeNode()` so there is a single directive.
    let taskDescription: String

    /// Clean compiled upstream text from `ContextCompressor.compileForWorkflow()`.
    /// Contains raw output from completed predecessor nodes, separated by `---`.
    /// Empty string when there are no upstream results (first node).
    let upstreamInput: String

    /// True if this node has no incoming edges (entry point of the DAG).
    /// First nodes receive "Execute your task." as user message.
    /// Downstream nodes receive `<input>[upstreamInput]</input>`.
    let isFirstNode: Bool

    /// Node display name for logging and tracing.
    let nodeName: String
}
