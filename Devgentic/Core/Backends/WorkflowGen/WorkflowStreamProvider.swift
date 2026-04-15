//
//  WorkflowStreamProvider.swift
//  Devgentic
//
//  Created by Raj Singh on 12/04/26.
//
//  Protocol abstraction over AgentConnect.streamAgentResponse() for
//  dependency injection in WorkflowExecutor. Enables integration
//  testing with mock stream providers.
//

import Foundation

/// Provides an async stream of agent events for a given profile.
/// Production: `AgentConnect` conforms to this.
/// Tests: `MockWorkflowStreamProvider` scripts deterministic responses.
protocol WorkflowStreamProvider: Sendable {
    /// Chat-oriented streaming — used by standalone agent/bot interactions.
    func streamAgentResponse(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String?,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>

    /// Workflow-aware streaming — bypasses RAG, history, and compaction.
    /// Uses `WorkflowCognitiveGenerator` to produce clean task+input prompts.
    func streamWorkflowNodeResponse(
        for profile: BackendProfileModel,
        workflowContext: WorkflowExecutionContext,
        conversationID: UUID,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>
}

// MARK: - Default Backward-Compatible Bridge

extension WorkflowStreamProvider {
    /// Default implementation that bridges to the existing `streamAgentResponse`.
    /// Allows mocks/tests to work without implementing the new method until updated.
    func streamWorkflowNodeResponse(
        for profile: BackendProfileModel,
        workflowContext: WorkflowExecutionContext,
        conversationID: UUID,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        // Compose userInput from workflow context (first node uses task, downstream uses upstream)
        let composedInput = workflowContext.isFirstNode
            ? workflowContext.taskDescription
            : workflowContext.upstreamInput
        return streamAgentResponse(
            for: profile,
            userInput: composedInput,
            chatHistory: [],
            conversationID: conversationID,
            ragContext: nil,
            traceContext: traceContext,
            onTraceUpdate: onTraceUpdate
        )
    }
}

// MARK: - AgentConnect Conformance

/// AgentConnect already implements the exact method signature.
/// This retroactive conformance enables it as the production stream provider.
extension AgentConnect: WorkflowStreamProvider {}
