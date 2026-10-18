// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowStreamProvider.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "WorkflowStreamProvider")

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
        toolGuidanceContext: String?,
        userPayload: Payload?,
        resumeState: TimelineReconstruction?,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>

    /// Workflow-aware streaming that bypasses RAG, history and compaction, using the same generator and
    /// parser as the agent or bot path. Per-node workflow context rides `SemanticContext.workflowContext`,
    /// so every dialect inherits it.
    func streamWorkflowNodeResponse(
        for profile: BackendProfileModel,
        workflowContext: WorkflowExecutionContext,
        conversationID: UUID,
        traceContext: TraceContext,
        onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?
    ) -> AsyncThrowingStream<AgentStreamEvent, Error>

    /// Resolves a persisted tool reference (native or MCP) to an invokable `AgentTool`, or nil if it cannot
    /// be resolved. Used by Action nodes to call a tool directly with no LLM; the default returns nil so
    /// mocks need not implement it.
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
        // One channel: the node's input, whatever its origin; the executor settles upstream text at the graph.
        return streamAgentResponse(
            for: profile,
            userInput: workflowContext.input,
            chatHistory: [],
            conversationID: conversationID,
            ragContext: nil,
            attachmentContext: nil,
            knowledgeBaseContext: nil,
            toolGuidanceContext: nil,
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
        // Resolves by source, never by name, with no cross-source fallback: Action nodes bypass the mediator.
        // A name-first lookup could run Devgentic's unsandboxed tool instead of the chosen MCP server's.
        let isBuiltIn = tool.sourceId == ToolSource.builtInSourceID
        let sources = await UnifiedToolStore.shared.sources

        // Confirmation is re-derived live; the stored node value is a stale snapshot and is only logged.
        // Unknown to `UnifiedToolStore` fails closed (ask); a per-node control would need override-if-set.
        let liveDefinition = sources
            .first { $0.id == tool.sourceId }?
            .tools.first { $0.name == tool.name }
        let effectiveConfirmation = liveDefinition?.requiresConfirmation ?? true

        if effectiveConfirmation != tool.requiresConfirmation {
            logger.notice("[TOOLRESOLVE] Action tool '\(tool.name)': stored requiresConfirmation=\(tool.requiresConfirmation) is STALE — the live definition says \(effectiveConfirmation)\(liveDefinition == nil ? " (no live definition found; failing closed)" : ""). CONSEQUENCE: the live value is used for this run and the node's stored value is left untouched on disk\(effectiveConfirmation ? "; this node WILL now raise a confirmation banner it previously skipped" : "; this tool no longer asks").  [conv \(conversationID)]")
        }

        if isBuiltIn {
            guard let native = resolveNativeTool(
                toolName: tool.name,
                conversationID: conversationID,
                requiresConfirmation: effectiveConfirmation,
                timeout: tool.timeout,
                timeoutMessage: tool.timeoutMessage
            ) else {
                logger.error("[TOOLRESOLVE] Action tool '\(tool.name)' NOT RESOLVED — declared built-in but `NativeToolCatalog` does not know the name. CONSEQUENCE: the Action node fails and routes to its error port; it is NOT silently substituted with a same-named MCP tool. [conv \(conversationID)]")
                return nil
            }
            return native
        }

        // Skips a disabled server before resolving, so switching a server off cannot hand its names to a local
        // implementation.
        if let source = sources.first(where: { $0.id == tool.sourceId }), !source.isEnabled {
            logger.error("[TOOLRESOLVE] Action tool '\(tool.name)' skipped — server '\(source.serverName)' (\(source.id)) is DISABLED by the user. CONSEQUENCE: the Action node fails rather than running a same-named local tool; re-enable the server to run this node. [conv \(conversationID)]")
            return nil
        }

        // `resolveMCPTool` reads `toolConfig.requiresConfirmation`, so it gets the live value; only this
        // in-memory copy changes.
        var liveTool = tool
        liveTool.requiresConfirmation = effectiveConfirmation

        guard let mcp = resolveMCPTool(toolConfig: liveTool, availableSources: sources, conversationID: conversationID) else {
            logger.error("[TOOLRESOLVE] Action tool '\(tool.name)' NOT RESOLVED from MCP source \(tool.sourceId). CONSEQUENCE: the Action node fails and routes to its error port. It is deliberately NOT resolved against `NativeToolCatalog` by name — a local tool that happens to share the name is a different tool with different limits. [conv \(conversationID)]")
            return nil
        }
        return mcp
    }
}
