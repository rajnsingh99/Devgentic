// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
        // ⚠️ ONE CHANNEL (2026-08-29) — the node's input, whatever its origin. This used to branch
        // on `isFirstNode` between a per-node task and the upstream text; the executor now settles
        // that at the graph, so there is nothing to compose.
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
        // Resolve by SOURCE, never by name.
        //
        // ⚠️ This used to try `resolveNativeTool(toolName:)` FIRST and fall through to MCP only
        // when the name missed — the tool-shadowing bug the agent path fixed in
        // `resolveExecutableTools` and this twin never received. MCP servers choose their own
        // tool names, so an Action node bound to a sandboxed filesystem server's `write_file`
        // silently ran Devgentic's own UNSANDBOXED `write_file` instead, with a path resolved
        // from upstream MODEL output. The sandbox the user chose by picking that server was
        // replaced by an implementation with no such limit, and the arguments matched closely
        // enough that nothing on screen showed the swap. It also defeated the server-disable
        // switch: turning a server OFF made its colliding names fall through to the local
        // implementation rather than stopping the call.
        //
        // This path is stricter than the agent path in one respect, deliberately: there is NO
        // cross-source fallback. An Action node invokes `AgentTool.run` directly — bypassing
        // `ToolExecutionMediator` — with arguments derived from model output, so "the server no
        // longer offers this name, run the local one instead" is not a safe degradation here.
        // The caller already fails the node with an accurate message ("removed, disabled, or
        // MCP server offline") and routes it to the error port.
        //
        let isBuiltIn = tool.sourceId == ToolSource.builtInSourceID
        let sources = await UnifiedToolStore.shared.sources

        // ⚠️ Confirmation is re-derived LIVE, and the node's stored value is IGNORED — never
        // rewritten, only logged when the two disagree.
        //
        // The stored `Tool.requiresConfirmation` is a snapshot taken when the tool was picked in
        // `ActionNodeInspectorView.selectTool`, and until 2026-07-31 that seed was hardcoded
        // `false`. Every Action node saved before then carries `false` regardless of what the
        // tool actually is, so `execute_shell` / `write_file` / `delete_file` ran unattended with
        // model-derived arguments, forever, with no banner and no migration to repair it.
        //
        // Re-deriving does NOT override a user preference here, which is the reason it is safe:
        // `ActionNodeInspectorView` exposes no Ask/Auto control, so the stored value on this path
        // is never a choice the user made — it is a stale cache of the catalogue default. (The
        // Tool Library's per-tool Ask/Auto toggle applies to a PROFILE's tool list, a different
        // object; nothing in it reaches an Action node's embedded `Tool`.) Were a per-node control
        // ever added, this must become "override if set, live default otherwise" rather than an
        // unconditional re-derivation — the standing rule is that a configured preference wins.
        //
        // `UnifiedToolStore` is the right authority for both arms: its built-in source carries
        // `LocalToolManager`'s computed default, and its MCP sources carry each server's current
        // `ToolDefinition`. Unknown to it ⇒ FAIL CLOSED (ask).
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

        // Skip a disabled server BEFORE resolving. Returning nil from `resolveMCPTool` was not
        // enough while a native fallback existed: switching a server off quietly handed its
        // colliding names to the local implementation — the shadowing bug in reverse, reachable
        // by a toggle.
        if let source = sources.first(where: { $0.id == tool.sourceId }), !source.isEnabled {
            logger.error("[TOOLRESOLVE] Action tool '\(tool.name)' skipped — server '\(source.serverName)' (\(source.id)) is DISABLED by the user. CONSEQUENCE: the Action node fails rather than running a same-named local tool; re-enable the server to run this node. [conv \(conversationID)]")
            return nil
        }

        // `resolveMCPTool` reads `toolConfig.requiresConfirmation`, so hand it the live value
        // rather than the node's stale snapshot. Only this in-memory copy changes; the layout on
        // disk is untouched.
        var liveTool = tool
        liveTool.requiresConfirmation = effectiveConfirmation

        guard let mcp = resolveMCPTool(toolConfig: liveTool, availableSources: sources, conversationID: conversationID) else {
            logger.error("[TOOLRESOLVE] Action tool '\(tool.name)' NOT RESOLVED from MCP source \(tool.sourceId). CONSEQUENCE: the Action node fails and routes to its error port. It is deliberately NOT resolved against `NativeToolCatalog` by name — a local tool that happens to share the name is a different tool with different limits. [conv \(conversationID)]")
            return nil
        }
        return mcp
    }
}
