//
//  MCPToolStore.swift
//  Devgentic
//
//  Created by Raj Singh on 28/09/25.
//
//  Migrated to SwiftData on 26/03/26.
//

import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MCPToolStore")

/// Manages all SwiftData operations for MCP tools (MCPToolItem and MCPToolDefinitionModel).
/// This class acts as a single source of truth for tool data and publishes changes to the UI.
@Observable @MainActor
final class MCPToolStore {

    // MARK: - Singleton Instance
    static let shared = MCPToolStore()

    /// Array of tool sources that the UI can observe for changes.
    var sources: [ToolSource] = []

    /// The shared model container, configured once at app startup.
    private(set) var modelContainer: ModelContainer?

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    /// Call this once from the App init to inject the container.
    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
        fetchTools()
    }

    /// Private initializer to enforce singleton pattern.
    private init() {}

    // MARK: - Public CRUD Methods

    /// Adds a new tool source and its associated tools.
    func addTool(serverName: String, serverDefinition: ServerDefinition, newTools: [ToolDefinition]) {
        guard let context = mainContext else { return }

        let item = MCPToolItem(
            id: UUID(),
            serverName: serverName,
            mcpConfigData: try? JSONEncoder().encode(serverDefinition)
        )

        for tool in newTools {
            let child = createToolDefinitionModel(from: tool)
            item.tools.append(child)
        }

        context.insert(item)
        saveContext()
        fetchTools()
    }

    /// Updates an existing tool source configuration and its tools.
    func updateTool(id: UUID, serverName: String, serverDefinition: ServerDefinition, newTools: [ToolDefinition]) {
        guard let context = mainContext else { return }

        let targetID = id
        let predicate = #Predicate<MCPToolItem> { $0.id == targetID }
        var descriptor = FetchDescriptor<MCPToolItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            guard let item = try context.fetch(descriptor).first else {
                logger.warning("MCPToolStore: Tool source with ID \(id) not found for update.")
                return
            }

            // Update basic properties
            item.serverName = serverName
            item.mcpConfigData = try? JSONEncoder().encode(serverDefinition)

            // Clear existing tools (cascade doesn't auto-delete in-memory; delete explicitly)
            for existingTool in item.tools {
                context.delete(existingTool)
            }
            item.tools.removeAll()

            // Add fresh set
            for tool in newTools {
                let child = createToolDefinitionModel(from: tool)
                item.tools.append(child)
            }

            saveContext()
            fetchTools()
        } catch {
            logger.error("MCPToolStore: Failed to fetch tool item for update: \(error.localizedDescription)")
        }
    }

    /// Deletes a specific tool source.
    func deleteTool(toolSource: ToolSource) {
        guard let context = mainContext else { return }

        let targetID = toolSource.id
        let predicate = #Predicate<MCPToolItem> { $0.id == targetID }
        var descriptor = FetchDescriptor<MCPToolItem>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let item = try context.fetch(descriptor).first {
                context.delete(item) // Cascade deletes children
                saveContext()
                fetchTools()
            }
        } catch {
            logger.error("Failed to fetch tool item for deletion: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helper Methods

    private func createToolDefinitionModel(from tool: ToolDefinition) -> MCPToolDefinitionModel {
        MCPToolDefinitionModel(
            name: tool.name,
            toolDescription: tool.description,
            requiresConfirmation: tool.requiresConfirmation,
            parametersData: try? JSONEncoder().encode(tool.parameters),
            title: tool.title,
            iconsData: tool.icons.flatMap { try? JSONEncoder().encode($0) },
            annotationsData: tool.annotations.flatMap { try? JSONEncoder().encode($0) }
        )
    }

    /// Fetches all tool items and updates the published `sources` array.
    private func fetchTools() {
        guard let context = mainContext else { return }

        do {
            let descriptor = FetchDescriptor<MCPToolItem>(
                sortBy: [SortDescriptor(\.serverName, order: .forward)]
            )
            let results = try context.fetch(descriptor)
            self.sources = results.map { $0.toToolSource() }
        } catch {
            logger.error("Failed to fetch tools: \(error.localizedDescription)")
            self.sources = []
        }
    }

    private func saveContext() {
        guard let context = mainContext else { return }
        do {
            try context.save()
        } catch {
            logger.error("Failed to save SwiftData context: \(error.localizedDescription)")
        }
    }
}
