//
//  UnifiedToolStore.swift
//  Devgentic
//
//  Created by Raj Singh on 28/09/25.
//
//  Refactored on 10/10/25 to fix local tool parameter mapping.
//

import Foundation
import Combine

/// A singleton class that acts as the single source of truth for all tool sources,
/// combining the static, built-in tools with the user's persisted MCP servers.
@MainActor
class UnifiedToolStore: ObservableObject {
    
    // MARK: - Singleton Instance
    static let shared = UnifiedToolStore()
    
    /// The unified, published list of all available tool sources.
    @Published var sources: [ToolSource] = []
    
    private var mcpStore = MCPToolStore.shared
    private var localManager = LocalToolManager.shared
    private var cancellables = Set<AnyCancellable>()
    
    /// Private initializer to set up data observation.
    private init() {
        // Listen for any changes in the persisted MCP tools.
        // When MCPToolStore updates (e.g., a tool is added/deleted),
        // this sink will trigger a refresh of our combined list.
        mcpStore.$sources
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshSources()
            }
            .store(in: &cancellables)
        
        // Perform the initial data load.
        refreshSources()
    }
    
    /// Rebuilds the `sources` array by combining local and MCP tools.
    private func refreshSources() {
        // 1. Fetch all persisted MCP tool sources.
        let mcpSources = mcpStore.sources
        
        // 2. Get all available built-in tools and map them to ToolDefinition.
        // FIXED: This now correctly includes the 'parameters' from the local ExecutableTool,
        // ensuring local tools have their argument schemas available to the agent.
        let localTools = localManager.availableTools().map {
            ToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters)
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
    
    /// A pass-through method to add a new MCP tool.
    func addTool(serverName: String, serverDefinition: ServerDefinition, newTools: [ToolDefinition]) {
        mcpStore.addTool(serverName: serverName, serverDefinition: serverDefinition, newTools: newTools)
    }
    
    /// A pass-through method to update an existing MCP tool.
    func updateTool(id: UUID, serverName: String, serverDefinition: ServerDefinition, newTools: [ToolDefinition]) {
        mcpStore.updateTool(id: id, serverName: serverName, serverDefinition: serverDefinition, newTools: newTools)
    }
    
    /// A pass-through method to delete an MCP tool source.
    /// This ensures that the built-in tools cannot be deleted.
    func deleteTool(toolSource: ToolSource) {
        guard toolSource.type == .mcp else {
            print("Cannot delete the local tool source.")
            return
        }
        mcpStore.deleteTool(toolSource: toolSource)
    }
}
