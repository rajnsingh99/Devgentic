// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UnifiedToolStore.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// Watches `MCPToolStore.sources` and rebuilds on change. `withObservationTracking` fires `onChange` once, so it is
    /// re-armed from within `onChange`: no timer, no wakeups while idle, and exactly one live observer.
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
        
        // Maps the available built-in tools to `ToolDefinition`, including each tool's `parameters` schema and its logical
        // category tag for hierarchical UI grouping.
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
        // Bumped on every rebuild so a surface that caches a decision derived from the catalogue (such as the workflow
        // canvas validator) can tell it changed. A monotonic counter, since a missed bump is worse than a redundant one.
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
