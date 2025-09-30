//
//  UnifiedToolExecutor.swift
//  Devgentic
//
//  Created by Raj Singh on 28/09/25.
//

import Foundation
import Combine

/// A singleton class that acts as the brain for tool execution routing.
///
/// This executor maintains a complete registry of all available tool names
/// and maps them to their parent `ToolSource`. When a request to execute a
/// tool comes in, this class can quickly identify if the tool is local or
// belongs to a specific MCP server. It observes the `UnifiedToolStore` to
/// automatically stay in sync with any changes to the available tools.
@MainActor
class UnifiedToolExecutor {
    
    /// The shared singleton instance.
    static let shared = UnifiedToolExecutor()
    
    /// A private dictionary mapping a tool's unique name (e.g., "brave_search")
    /// to the `ToolSource` that provides it.
    private var toolRegistry: [String: ToolSource] = [:]
    
    private var cancellables = Set<AnyCancellable>()

    /// Private initializer to set up the subscription to the unified tool store.
    private init() {
        // Subscribe to any changes in the sources from the UnifiedToolStore.
        // This ensures our registry is always up-to-date when tools are
        // added or removed.
        UnifiedToolStore.shared.$sources
            .sink { [weak self] sources in
                // When the sources change, rebuild our internal registry.
                self?.buildRegistry(from: sources)
            }
            .store(in: &cancellables)
    }

    /// Rebuilds the internal tool-to-source mapping from the latest list of sources.
    /// - Parameter sources: The complete list of `ToolSource` from the `UnifiedToolStore`.
    private func buildRegistry(from sources: [ToolSource]) {
        var newRegistry: [String: ToolSource] = [:]
        
        // Iterate over each source (e.g., "Built-in Tools", "Brave Search Server")
        for source in sources {
            // Iterate over each tool within that source
            for tool in source.tools {
                // Create a mapping from the tool's name to its parent source.
                newRegistry[tool.name] = source
            }
        }
        
        // Atomically update the main registry.
        self.toolRegistry = newRegistry
        
        // Optional: Add a log for debugging to confirm the registry is updated.
        print("UnifiedToolExecutor: Registry rebuilt. Contains \(self.toolRegistry.count) unique tools.")
    }
    
    /// The main public entry point for executing any tool, local or remote.
    /// - Parameters:
    ///   - name: The unique name of the tool to execute.
    ///   - arguments: A dictionary of arguments for the tool.
    /// - Returns: A string containing the tool's output or an error message.
    func execute(name: String, arguments: [String: Any]) async -> String {
        // Step 1: Look up the tool in our central registry.
        guard let source = toolRegistry[name] else {
            return "Error: Tool '\(name)' not found in the unified tool registry."
        }
        
        // Step 2: Route the execution based on the source type.
        switch source.type {
        case .local:
            // If it's a local tool, delegate to the LocalToolManager.
            return await LocalToolManager.shared.execute(name: name, arguments: arguments)
            
        case .mcp:
            // If it's an MCP tool, delegate to the on-demand MCPConnectionManager.
            return await MCPConnectionManager.shared.execute(
                toolName: name,
                arguments: arguments,
                source: source
            )
        }
    }
}

