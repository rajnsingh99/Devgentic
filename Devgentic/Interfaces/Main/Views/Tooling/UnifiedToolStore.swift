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

/// A singleton class that acts as the single source of truth for all tool sources,
/// combining the static, built-in tools with the user's persisted MCP servers.
@Observable @MainActor
final class UnifiedToolStore {

    // MARK: - Singleton Instance
    static let shared = UnifiedToolStore()

    /// The unified list of all available tool sources.
    var sources: [ToolSource] = []

    private let mcpStore = MCPToolStore.shared
    private let localManager = LocalToolManager.shared

    /// Observation task that watches MCPToolStore for changes.
    private var observationTask: Task<Void, Never>?

    /// Private initializer to set up data observation.
    private init() {
        // Perform the initial data load.
        refreshSources()

        // Observe MCPToolStore changes via @Observable tracking.
        // When mcpStore.sources changes, re-read triggers refreshSources().
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let _ = withObservationTracking {
                    self.mcpStore.sources
                } onChange: {
                    Task { @MainActor [weak self] in
                        self?.refreshSources()
                    }
                }
                // Yield to allow the onChange callback to fire before looping.
                try? await Task.sleep(for: .milliseconds(50))
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
                serverDefinition: source.serverDefinition
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
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            type: .local,
            serverName: "Built-in Tools",
            tools: localTools.sorted { $0.name < $1.name },
            serverDefinition: nil
        )
        
        // 4. Combine the lists, ensuring "Built-in Tools" always appears first,
        // and publish the result to the UI.
        self.sources = [localSource] + mcpSources
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

    /// A pass-through method to delete an MCP tool source.
    /// This ensures that the built-in tools cannot be deleted.
    func deleteTool(toolSource: ToolSource) {
        guard toolSource.type == .mcp else {
            print("Cannot delete the local tool source.")
            return
        }
        mcpStore.deleteTool(toolSource: toolSource)
        refreshSources()
    }
}
