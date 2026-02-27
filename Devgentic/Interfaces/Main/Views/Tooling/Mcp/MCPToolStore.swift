//
//  MCPToolStore.swift
//  Devgentic
//
//  Created by Raj Singh on 28/09/25.
//
//  Updated for Phase 1: Mapped requiresConfirmation boolean from CoreData
//

import Foundation
import CoreData
import Combine

/// Manages all Core Data operations for MCP tools (ToolItemEntity and MCPToolEntity).
/// This class acts as a single source of truth for tool data and publishes changes to the UI.
@MainActor
class MCPToolStore: ObservableObject {
    
    // MARK: - Singleton Instance
    static let shared = MCPToolStore()

    /// Published array of tool sources that the UI can observe for changes.
    @Published var sources: [ToolSource] = []
    
    private let persistenceService: CoreDataServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    /// Private initializer to enforce singleton pattern and set up the data pipeline.
    /// - Parameter persistenceService: The Core Data service for database operations.
    private init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
        fetchTools()
    }

    // MARK: - Public CRUD Methods

    /// Adds a new tool source and its associated tools to Core Data.
    /// - Parameters:
    ///   - serverName: The name of the server providing the tools.
    ///   - serverDefinition: The configuration containing connection details.
    ///   - newTools: An array of `ToolDefinition` structs to be saved.
    func addTool(serverName: String, serverDefinition: ServerDefinition, newTools: [ToolDefinition]) {
        let context = (persistenceService as! CoreDataPersistenceService).viewContext
        
        // Create the parent ToolItemEntity
        let newToolItemEntity = ToolItemEntity(context: context)
        newToolItemEntity.id = UUID()
        newToolItemEntity.serverName = serverName
        
        // Encode the entire ServerDefinition object into a single Data attribute.
        newToolItemEntity.mcpConfig = try? JSONEncoder().encode(serverDefinition)
        
        // Create and associate each MCPToolEntity
        for tool in newTools {
            createAndAttachToolEntity(tool, to: newToolItemEntity, context: context)
        }
        
        persistenceService.saveContext()
        fetchTools() // Refresh the published list
    }
    
    /// Updates an existing tool source configuration and its tools.
    /// - Parameters:
    ///   - id: The UUID of the existing tool source to update.
    ///   - serverName: The new name of the server.
    ///   - serverDefinition: The new configuration details.
    ///   - newTools: The fresh list of tools discovered from the server.
    func updateTool(id: UUID, serverName: String, serverDefinition: ServerDefinition, newTools: [ToolDefinition]) {
        let context = (persistenceService as! CoreDataPersistenceService).viewContext
        let fetchRequest: NSFetchRequest<ToolItemEntity> = ToolItemEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            if let entityToUpdate = try context.fetch(fetchRequest).first {
                // 1. Update basic properties
                entityToUpdate.serverName = serverName
                entityToUpdate.mcpConfig = try? JSONEncoder().encode(serverDefinition)
                
                // 2. Clear existing tools to ensure synchronization
                // (e.g., if the server removed a tool or renamed it)
                if let existingTools = entityToUpdate.tools as? Set<MCPToolEntity> {
                    for tool in existingTools {
                        context.delete(tool)
                    }
                }
                
                // 3. Add the fresh set of tools
                for tool in newTools {
                    createAndAttachToolEntity(tool, to: entityToUpdate, context: context)
                }
                
                persistenceService.saveContext()
                fetchTools() // Refresh the published list
            } else {
                print("MCPToolStore: Tool source with ID \(id) not found for update.")
            }
        } catch {
            print("MCPToolStore: Failed to fetch tool item for update: \(error.localizedDescription)")
        }
    }

    /// Deletes a specific tool source from Core Data.
    /// - Parameter toolSource: The `ToolSource` to be deleted.
    func deleteTool(toolSource: ToolSource) {
        let context = (persistenceService as! CoreDataPersistenceService).viewContext
        let fetchRequest: NSFetchRequest<ToolItemEntity> = ToolItemEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", toolSource.id as CVarArg)
        
        do {
            if let entityToDelete = try context.fetch(fetchRequest).first {
                context.delete(entityToDelete)
                persistenceService.saveContext()
                fetchTools() // Refresh the published list
            }
        } catch {
            print("Failed to fetch tool item for deletion: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Helper Methods
    
    private func createAndAttachToolEntity(_ tool: ToolDefinition, to parent: ToolItemEntity, context: NSManagedObjectContext) {
        let newMCPToolEntity = MCPToolEntity(context: context)
        newMCPToolEntity.name = tool.name
        newMCPToolEntity.toolDescription = tool.description
        newMCPToolEntity.requiresConfirmation = tool.requiresConfirmation
        newMCPToolEntity.parametersData = try? JSONEncoder().encode(tool.parameters)

        // MCP v0.11.0 fields
        newMCPToolEntity.title = tool.title
        newMCPToolEntity.iconsData = tool.icons.flatMap { try? JSONEncoder().encode($0) }
        newMCPToolEntity.annotationsData = tool.annotations.flatMap { try? JSONEncoder().encode($0) }

        parent.addToTools(newMCPToolEntity)
    }

    /// Fetches all tool items from Core Data and updates the published `sources` array.
    private func fetchTools() {
        let context = (persistenceService as! CoreDataPersistenceService).viewContext
        let request: NSFetchRequest<ToolItemEntity> = ToolItemEntity.fetchRequest()
        
        // Sort by server name for a consistent order
        request.sortDescriptors = [NSSortDescriptor(keyPath: \ToolItemEntity.serverName, ascending: true)]
        
        do {
            let results = try context.fetch(request)
            // Map the Core Data entities to the UI model structs
            self.sources = results.map { $0.toToolSourceStruct() }
        } catch {
            print("Failed to fetch tools: \(error.localizedDescription)")
            self.sources = []
        }
    }
}


// MARK: - Core Data Entity Extension

// This extension provides a convenient way to convert the Core Data managed object
// into the simple struct that the SwiftUI views use.
extension ToolItemEntity {
    
    /// Converts a `ToolItemEntity` managed object into a `ToolSource` struct.
    /// - Returns: A `ToolSource` struct representing the data.
    func toToolSourceStruct() -> ToolSource {
        // Safely unwrap the related MCPToolEntity set and convert each to a ToolDefinition struct
        let toolSet = self.tools as? Set<MCPToolEntity> ?? []
        let mappedTools = toolSet.map { mcpToolEntity -> ToolDefinition in
            // Decode parameters from Data, providing a default if it fails or is nil.
            var parameters: ToolParameters
            if let data = mcpToolEntity.parametersData {
                do {
                    parameters = try JSONDecoder().decode(ToolParameters.self, from: data)
                } catch {
                    print("Failed to decode parameters for tool \(mcpToolEntity.name ?? "Unknown"): \(error). Using default.")
                    parameters = ToolParameters(type: "object", properties: [:], required: [])
                }
            } else {
                parameters = ToolParameters(type: "object", properties: [:], required: [])
            }

            // Hydrate v0.11.0 fields
            var icons: [ToolIcon]? = nil
            if let data = mcpToolEntity.iconsData {
                icons = try? JSONDecoder().decode([ToolIcon].self, from: data)
            }

            var annotations: ToolAnnotations? = nil
            if let data = mcpToolEntity.annotationsData {
                annotations = try? JSONDecoder().decode(ToolAnnotations.self, from: data)
            }

            return ToolDefinition(
                name: mcpToolEntity.name ?? "Unknown",
                description: mcpToolEntity.toolDescription ?? "",
                parameters: parameters,
                requiresConfirmation: mcpToolEntity.requiresConfirmation,
                title: mcpToolEntity.title,
                icons: icons,
                annotations: annotations
            )
        }.sorted { $0.name < $1.name }
        
        // Decode the ServerDefinition from the stored Data.
        var serverDefinition: ServerDefinition?
        if let data = self.mcpConfig {
            serverDefinition = try? JSONDecoder().decode(ServerDefinition.self, from: data)
        }
        
        return ToolSource(
            id: self.id ?? UUID(),
            type: .mcp, // All persisted items are MCP tools
            serverName: self.serverName ?? "Unnamed Server",
            tools: mappedTools,
            serverDefinition: serverDefinition
        )
    }
}
