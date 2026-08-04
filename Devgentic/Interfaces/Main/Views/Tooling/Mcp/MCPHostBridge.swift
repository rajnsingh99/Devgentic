//
//  MCPHostBridge.swift
//  Devgentic
//
//  Created 2026-08-02 — the seam between `MCPClientService` and the rest of the app.
//
//  `MCPClientService` is the only part of the MCP subsystem that reached OUT of it. Three
//  call sites did all the reaching:
//
//      MCPToolStore.shared.replaceTools(…)     → SwiftData
//      MCPSamplingBroker.shared.handle(…)      → AgentConnect + HITL
//      MCPElicitationBroker.shared.handle(…)   → InteractionCenter + HITL
//
//  Everything else in `Mcp/` is Foundation + the MCP SDK. Those three lines were therefore
//  the entire reason the connect path could not be exercised outside a running app — which
//  is why no test had ever spawned a real server. Routing them through this bridge makes
//  the dependency one-directional and injectable: `MCPHarness/` installs no-op
//  implementations and drives the REAL connect path against real child processes.
//
//  ⚠️ This is a seam, not an abstraction layer. It declares exactly what the client service
//  needs from the host and nothing more. Conformances live with the concrete types
//  (`MCPToolStore`, the two brokers); the app installs them once at launch via
//  `MCPHostBridge.installAppImplementations()` in `AppDelegate.applicationDidFinishLaunching`.
//
//  ⚠️ A missing implementation is never silent. Each accessor logs what was dropped and what
//  the user will observe as a result, because "nothing happened and nothing said why" is the
//  exact failure mode this subsystem's logging standard exists to prevent.
//

import Foundation
import MCP

private let logger = DGLogger(category: "MCPHostBridge")

// MARK: - What the client service needs from the host

/// Where a freshly composed tool list goes.
///
/// Satisfied by `MCPToolStore` in the app (SwiftData + UI projection) and by a recording
/// stub in `MCPHarness`. The client service composes the list; it does not care where it
/// lands.
@MainActor
protocol MCPToolListSink: AnyObject, Sendable {
    /// Replaces the persisted tool list for one source. Called on connect and on every
    /// (debounced) `tools/list_changed`.
    func replaceTools(forSourceID sourceID: UUID, with newTools: [ToolDefinition])
}

/// Reads the configured MCP servers.
///
/// Deliberately SEPARATE from `MCPToolListSink` even though `MCPToolStore` satisfies both.
/// `MCPClientService` gets the sink and nothing else — it composes tool lists, it has no
/// business enumerating the user's servers. `MCPConnectionCoordinator`, whose entire job is
/// deciding *which* servers to connect and when, gets both. Merging the two protocols would
/// hand the client service a capability it does not need and cannot be trusted not to grow
/// into.
@MainActor
protocol MCPSourceStore: AnyObject, Sendable {
    /// Every configured MCP server. Excludes the built-in tool catalogue, which has nothing
    /// to connect to.
    var sources: [ToolSource] { get }
}

/// Services `sampling/createMessage` — a server asking the host to run an LLM call.
///
/// Satisfied by `MCPSamplingBroker`, which needs `AgentConnect` for the provider config and
/// the InteractionCenter for the per-request approval.
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
///
/// Deliberately a plain holder rather than a container or a resolver: three slots, filled
/// once at launch, read on the MainActor. Anything more would be architecture for its own
/// sake.
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

    /// The configured MCP servers, or an EMPTY list with a log line saying why.
    ///
    /// Empty rather than nil: every caller iterates the result, so returning nil would only
    /// move the same `?? []` to each of them. What must not happen is an empty list being
    /// mistaken for "the user has no servers configured" — hence the log line.
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
