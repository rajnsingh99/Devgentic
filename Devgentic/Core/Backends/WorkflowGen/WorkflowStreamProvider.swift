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
    /// `attachmentContext` / `knowledgeBaseContext` carry current-turn file text and
    /// profile knowledge payloads as separate prompt vehicles (2026-07 redesign).
    func streamAgentResponse(
        for profile: BackendProfileModel,
        userInput: String,
        chatHistory: [ChatMessage],
        conversationID: UUID,
        ragContext: String?,
        attachmentContext: String?,
        knowledgeBaseContext: String?,
        userPayload: Payload?,
        resumeState: TimelineReconstruction?,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>

    /// Workflow-aware streaming — bypasses RAG, history, and compaction.
    /// Uses the same generator/parser the agent or bot path would; per-node
    /// workflow context is threaded through `SemanticContext.workflowContext`
    /// so every dialect inherits workflow behavior automatically.
    func streamWorkflowNodeResponse(
        for profile: BackendProfileModel,
        workflowContext: WorkflowExecutionContext,
        conversationID: UUID,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>

    /// Resolves a persisted tool reference (native or MCP) to an invokable,
    /// type-erased `AgentTool` — or nil if it can't be resolved (tool removed,
    /// MCP server offline). Used by **Action nodes** to call a tool directly and
    /// deterministically, with no LLM in the loop. A default returns nil so mocks
    /// don't have to implement it.
    func resolveWorkflowTool(_ tool: Tool, conversationID: UUID) async -> AgentTool?
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
            attachmentContext: nil,
            knowledgeBaseContext: nil,
            userPayload: nil,
            resumeState: nil,
            traceContext: traceContext,
            onTraceUpdate: onTraceUpdate
        )
    }

    /// Default: no tool resolution (mocks/tests). Production `AgentConnect` overrides.
    func resolveWorkflowTool(_ tool: Tool, conversationID: UUID) async -> AgentTool? {
        nil
    }
}

// MARK: - AgentConnect Conformance

/// AgentConnect already implements the streaming signatures; this adds the
/// production tool-resolution path for Action nodes, reusing the same native/MCP
/// resolution the agent pipeline uses.
extension AgentConnect: WorkflowStreamProvider {
    func resolveWorkflowTool(_ tool: Tool, conversationID: UUID) async -> AgentTool? {
        // Native first (fixed-source built-in tools), then MCP (server-backed).
        //
        // `requiresConfirmation` is forwarded from the node's own tool configuration, but note
        // it is INERT on this path: the flag is read by `ToolExecutionMediator`, and Action
        // nodes bypass the mediator entirely. The Action branch of `WorkflowExecutor` performs
        // its own confirmation check against this same flag before running the tool.
        //
        // It was hardcoded `false` here until 2026-07-31, with the rationale "workflow actions
        // are pre-approved at design time; gate genuinely risky ones behind a Gate node". That
        // holds for the SHAPE of the call — the author chose the tool and wrote the argument
        // templates — but not for the values, which resolve from upstream (and therefore from
        // model output) at run time. A tool the user configured to ask now asks here too.
        if let native = resolveNativeTool(
            toolName: tool.name,
            conversationID: conversationID,
            requiresConfirmation: tool.requiresConfirmation,
            timeout: tool.timeout,
            timeoutMessage: tool.timeoutMessage
        ) {
            return native
        }
        let sources = await UnifiedToolStore.shared.sources
        return resolveMCPTool(toolConfig: tool, availableSources: sources)
    }
}
