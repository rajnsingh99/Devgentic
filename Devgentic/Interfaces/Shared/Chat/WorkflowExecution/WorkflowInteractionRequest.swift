//
//  WorkflowInteractionRequest.swift
//  Devgentic
//
//  Created by Raj Singh on 11/04/26.
//
//  Models a single HITL interaction request within a workflow execution.
//  Unlike ChatMessage.pendingInteraction (single optional), workflows can have
//  multiple concurrent interactions from parallel nodes. Each request carries
//  node identity and context so the user knows which agent is asking.
//

import Foundation

/// A single HITL interaction request raised by a workflow node.
/// Stored in `WorkflowExecutionState.pendingInteractions` keyed by `id` (operationID).
struct WorkflowInteractionRequest: Identifiable, Sendable {

    /// The operationID used by ExecutionSuspensionService for resume correlation.
    let id: UUID

    /// Which workflow node raised the interaction.
    let nodeID: UUID

    /// Display name of the node (e.g., "Security Agent").
    let nodeName: String

    /// The node's kind — used to derive icon and color in the interaction panel.
    let nodeKind: WorkflowNodeKind

    /// What kind of interaction is requested.
    let requestType: RequestType

    /// When the interaction was raised.
    let timestamp: Date

    /// Last few timeline events from this node before it paused (for context).
    let recentTimeline: [TimelineEvent]

    /// Names of upstream nodes that fed into this node (breadcrumb trail).
    let upstreamNodeNames: [String]

    // MARK: - Request Type

    enum RequestType: Sendable {
        /// Workflow Gate node — user must approve/reject to proceed.
        case gate(prompt: String, options: [String])

        /// Agent's ask_user tool — user must answer a question.
        case askUser(question: String)

        /// Agent's sensitive tool — user must approve execution.
        case toolConfirmation(toolName: String, params: String)
    }
}
