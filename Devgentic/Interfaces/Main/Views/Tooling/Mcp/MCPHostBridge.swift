// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPHostBridge.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import MCP

private let logger = DGLogger(category: "MCPHostBridge")

// MARK: - What the client service needs from the host

/// Where a freshly composed tool list goes.
/// Satisfied by `MCPToolStore` in the app (SwiftData + UI projection) and by a recording stub.
/// The client service composes the list and does not care where it lands.
@MainActor
protocol MCPToolListSink: AnyObject, Sendable {
    /// Overwrites the persisted tool list for one source. Called on connect and on every
    /// (debounced) `tools/list_changed`.
    func replaceTools(forSourceID sourceID: UUID, with newTools: [ToolDefinition])
}

/// Reads the configured MCP servers. Kept separate from `MCPToolListSink` even though `MCPToolStore` satisfies both:
/// `MCPClientService` gets only the sink, while `MCPConnectionCoordinator`, which decides which servers to connect,
/// gets both.
@MainActor
protocol MCPSourceStore: AnyObject, Sendable {
    /// Every configured MCP server. Excludes the built-in tool catalogue, which has nothing
    /// to connect to.
    var sources: [ToolSource] { get }
}

/// Services `sampling/createMessage`, a server asking the host to run an LLM call.
/// Satisfied by `MCPSamplingBroker`, which needs `AgentConnect` for the provider config and the InteractionCenter
/// for the per-request approval.
@MainActor
protocol MCPSamplingRequestHandling: AnyObject, Sendable {
    func handle(
        parameters: CreateSamplingMessage.Parameters,
        sourceID: UUID,
        serverLabel: String
    ) async throws -> CreateSamplingMessage.Result
}

/// Services `elicitation/create` — a server asking the USER a question mid-tool-call.
///
/// Satisfied by `MCPElicitationBroker`, which needs the InteractionCenter to show it.
@MainActor
protocol MCPElicitationRequestHandling: AnyObject, Sendable {
    func handle(
        parameters: CreateElicitation.Parameters,
        sourceID: UUID,
        serverLabel: String
    ) async throws -> CreateElicitation.Result
}

// MARK: - The bridge

/// Holds the host implementations `MCPClientService` calls out to.
/// A plain holder: three slots, filled once at launch, read on the MainActor.
@MainActor
enum MCPHostBridge {

    private(set) static var toolListSink: (any MCPToolListSink)?
    private(set) static var sourceStore: (any MCPSourceStore)?
    private(set) static var samplingHandler: (any MCPSamplingRequestHandling)?
    private(set) static var elicitationHandler: (any MCPElicitationRequestHandling)?

    /// Installs the host implementations. Idempotent — installing twice replaces, and the
    /// second install is logged, since in the app it would mean launch ran twice.
    static func install(
        toolListSink: (any MCPToolListSink)?,
        sourceStore: (any MCPSourceStore)?,
        samplingHandler: (any MCPSamplingRequestHandling)?,
        elicitationHandler: (any MCPElicitationRequestHandling)?
    ) {
        let wasInstalled = Self.toolListSink != nil
            || Self.sourceStore != nil
            || Self.samplingHandler != nil
            || Self.elicitationHandler != nil

        Self.toolListSink = toolListSink
        Self.sourceStore = sourceStore
        Self.samplingHandler = samplingHandler
        Self.elicitationHandler = elicitationHandler

        logger.info("""
            [MCP-BRIDGE] Host implementations \(wasInstalled ? "REPLACED" : "installed") — \
            toolListSink:\(toolListSink != nil) sourceStore:\(sourceStore != nil) \
            sampling:\(samplingHandler != nil) elicitation:\(elicitationHandler != nil).
            """)
    }

    /// Clears every slot. Test-support only; the app installs once and never uninstalls.
    static func reset() {
        toolListSink = nil
        sourceStore = nil
        samplingHandler = nil
        elicitationHandler = nil
        logger.info("[MCP-BRIDGE] Host implementations cleared.")
    }

    // MARK: - Accessors that state the consequence of being unwired

    /// The tool-list sink, or nil with a log line saying what the user will see instead.
    static func requireToolListSink(context: String) -> (any MCPToolListSink)? {
        guard let sink = toolListSink else {
            logger.error("""
                [MCP-BRIDGE] ⚠️ No tool-list sink is installed (\(context)) — the freshly \
                composed tool list is DISCARDED. Persistence and the Tool Library keep whatever \
                they last saw, so a server that gained or lost tools will look unchanged and the \
                agent will be offered a stale set. In the app this means \
                `MCPHostBridge.installAppImplementations()` never ran.
                """)
            return nil
        }
        return sink
    }

    /// The configured MCP servers, or an empty list with a log line saying why.
    /// Empty rather than nil so callers need no `?? []`; the log line keeps an empty result from being mistaken for
    /// "the user has no servers configured".
    static func configuredSources(context: String) -> [ToolSource] {
        guard let store = sourceStore else {
            logger.error("""
                [MCP-BRIDGE] ⚠️ No source store is installed (\(context)) — treating the user's \
                MCP servers as if NONE were configured. Nothing will connect, the composer \
                banner will hide itself, and the agent gets no MCP tools at all. In the app this \
                means `MCPHostBridge.installAppImplementations()` never ran.
                """)
            return []
        }
        return store.sources
    }
}
