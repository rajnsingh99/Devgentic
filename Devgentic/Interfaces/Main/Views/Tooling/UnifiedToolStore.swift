//
//  UnifiedToolStore.swift
//  Devgentic
//
//  Created by Raj Singh on 28/09/25.
//
//  Refactored on 10/10/25 to fix local tool parameter mapping.
//  Updated for Phase 5: Map categories for UI hierarchical grouping.
//

import Foundation

private let logger = DGLogger(category: "UnifiedToolStore")

/// A singleton class that acts as the single source of truth for all tool sources,
/// combining the static, built-in tools with the user's persisted MCP servers.
@Observable @MainActor
final class UnifiedToolStore {

    // MARK: - Singleton Instance
    static let shared = UnifiedToolStore()

    /// The unified list of all available tool sources.
    var sources: [ToolSource] = []

    /// Incremented on every rebuild of `sources` (register INS-12). See `refreshSources()`.
    private(set) var catalogGeneration: Int = 0

    private let mcpStore = MCPToolStore.shared
    private let localManager = LocalToolManager.shared

    /// Private initializer to set up data observation.
    private init() {
        // Perform the initial data load.
        refreshSources()
        observeMCPStore()
    }

    /// Watches `MCPToolStore.sources` and rebuilds on change.
    ///
    /// `withObservationTracking` fires its `onChange` exactly once, so it has to be
    /// re-armed after every change. This used to be done by re-registering inside a
    /// `while !Task.isCancelled` loop with a 50 ms sleep — a 20 Hz poll that ran forever
    /// on the MainActor in a singleton that is never deallocated, and that registered a
    /// fresh one-shot observer on every tick regardless of whether anything had changed.
    /// Re-arming from within `onChange` gives the same liveness with no timer, no wakeups
    /// while idle, and exactly one live observer at a time.
    private func observeMCPStore() {
        withObservationTracking {
            _ = mcpStore.sources
        } onChange: {
            // `onChange` fires before the mutation is visible, so hop to the next main-actor
            // turn to read the settled value, then re-arm for the following change.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshSources()
                self.observeMCPStore()
            }
        }
    }
    
    /// Rebuilds the `sources` array by combining local and MCP tools.
    private func refreshSources() {
        // 1. Fetch all persisted MCP tool sources and intelligently map their categories.
        // For MCP tools fetched from servers, we default their category to the Server's Name to group them automatically.
        let mcpSources = mcpStore.sources.map { source in
            let mappedTools = source.tools.map { tool -> ToolDefinition in
                let resolvedCategory = tool.category.isEmpty ? source.serverName : tool.category
                return ToolDefinition(
                    name: tool.name,
                    description: tool.description,
                    category: resolvedCategory,
                    parameters: tool.parameters,
                    requiresConfirmation: tool.requiresConfirmation,
                    title: tool.title,
                    icons: tool.icons,
                    annotations: tool.annotations
                )
            }
            
            return ToolSource(
                id: source.id,
                type: source.type,
                serverName: source.serverName,
                tools: mappedTools,
                serverDefinition: source.serverDefinition,
                // Must be carried explicitly: `isEnabled` defaults to `true`, so omitting it
                // here would silently re-enable every server the user had switched off.
                isEnabled: source.isEnabled
            )
        }
        
        // 2. Get all available built-in tools and map them to ToolDefinition.
        // FIXED: This now correctly includes the 'parameters' from the local ExecutableTool,
        // ensuring local tools have their argument schemas available to the agent.
        // NEW: Maps the logical category tag for hierarchical UI grouping.
        let localTools = localManager.availableTools().map {
            ToolDefinition(
                name: $0.name,
                description: $0.description,
                category: $0.category,
                parameters: $0.parameters,
                requiresConfirmation: $0.requiresConfirmation
            )
        }
        
        // 3. Create a single, static ToolSource to represent all built-in tools.
        // We use a fixed, well-known UUID to uniquely identify this group.
        let localSource = ToolSource(
            id: ToolSource.builtInSourceID,
            type: .local,
            serverName: "Built-in Tools",
            tools: localTools.sorted { $0.name < $1.name },
            serverDefinition: nil
        )
        
        // 4. Combine the lists, ensuring "Built-in Tools" always appears first,
        // and publish the result to the UI.
        self.sources = [localSource] + mcpSources
        // [INS-12] Bumped on every rebuild, so a surface that CACHES a decision derived from the
        // catalogue can tell the catalogue moved. The workflow canvas's validator reads
        // `sources` for its tool-availability arm but runs only on graph edits, undo and load —
        // so disabling an MCP server with a canvas open left "Workflow Ready" standing over a run
        // that would now fail. A monotonic counter rather than notifications, for the same reason
        // `WorkflowLayoutStore.writeGeneration` is one: a redundant bump is harmless, a missed one
        // is not. This is the single funnel — add/update/delete/setEnabled and the MCP observation
        // tracker all land here.
        catalogGeneration &+= 1
    }
    
    // MARK: - CRUD Pass-through Methods
    
    /// A pass-through method to add a new MCP tool. Returns the new source ID
    /// (or nil on failure) so callers can clean up any pending temp-ID state.
    @discardableResult
    func addTool(
        serverName: String,
        serverDefinition: ServerDefinition,
        secrets: MCPRuntimeSecrets,
        newTools: [ToolDefinition]
    ) -> UUID? {
        let newID = mcpStore.addTool(
            serverName: serverName,
            serverDefinition: serverDefinition,
            secrets: secrets,
            newTools: newTools
        )
        refreshSources()
        return newID
    }

    /// A pass-through method to update an existing MCP tool.
    func updateTool(
        id: UUID,
        serverName: String,
        serverDefinition: ServerDefinition,
        secrets: MCPRuntimeSecrets,
        newTools: [ToolDefinition]
    ) {
        mcpStore.updateTool(
            id: id,
            serverName: serverName,
            serverDefinition: serverDefinition,
            secrets: secrets,
            newTools: newTools
        )
        refreshSources()
    }

    /// Enables or disables an MCP server without touching its configuration or secrets.
    func setEnabled(_ enabled: Bool, sourceID: UUID) {
        mcpStore.setEnabled(enabled, sourceID: sourceID)
        refreshSources()
    }

    /// Is this server name already used by a different source? Used by the Add/Edit form so
    /// a RENAME is checked for duplicates the same way an add always was.
    func isServerNameTaken(_ serverName: String, excluding sourceID: UUID? = nil) -> Bool {
        mcpStore.isServerNameTaken(serverName, excluding: sourceID)
    }

    /// A pass-through method to delete an MCP tool source.
    /// This ensures that the built-in tools cannot be deleted.
    func deleteTool(toolSource: ToolSource) {
        guard toolSource.type == .mcp else {
            // `print` never reaches LogRecorder's ring buffer, so this refusal was
            // invisible in a shipped build and absent from any bug report.
            logger.error("""
                [MCP-STORE] Refused to delete tool source '\(toolSource.serverName)' \
                (\(toolSource.id)): it is the built-in catalogue, not an MCP server. \
                Nothing was deleted and the caller was not told.
                """)
            return
        }
        mcpStore.deleteTool(toolSource: toolSource)
        refreshSources()
    }
}
