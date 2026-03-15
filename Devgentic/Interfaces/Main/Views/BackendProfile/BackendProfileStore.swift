//
//  BackendProfileStore.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//  Updated on 10/09/25 to persist new Agent properties.
//  Updated on 28/01/26 to persist AgentArchitecture safely.
//

import Foundation
import CoreData
import os

// MARK: - Backend Profile Store Protocol
protocol BackendProfileStoreProtocol {
    /// Fetches all stored backend profiles as the unified model type.
    func fetchProfiles() -> [BackendProfileModel]
    
    /// Saves or updates a profile using the unified model type.
    func saveProfile(_ profile: BackendProfileModel)
    
    /// Deletes a profile with the specified ID.
    func deleteProfile(withId id: UUID)
    
    /// Commits changes to the persistent store.
    func saveContext()
}

// MARK: - Core Data Backend Profile Store
class BackendProfileStore: BackendProfileStoreProtocol {

    // MARK: - Singleton Instance
    static let shared = BackendProfileStore()

    // MARK: - Private Properties
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "BackendProfileStore")
    
    private var persistentContainer: NSPersistentContainer {
        CoreDataPersistenceService.shared.persistentContainer
    }

    private var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }
    
    // MARK: - Initialization
    private init() {}

    // MARK: - Public API
    
    /// Fetches all stored backend profiles and converts them to `BackendProfileModel`.
    func fetchProfiles() -> [BackendProfileModel] {
        let request: NSFetchRequest<BackendProfileEntity> = BackendProfileEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "lastSelected", ascending: false)]
        
        do {
            let entities = try viewContext.fetch(request)
            return entities.compactMap { $0.toBackendProfile() }
        } catch {
            logger.error("Failed to fetch Backend Profiles: \(error.localizedDescription)")
            return []
        }
    }

    /// Saves or updates a profile using the unified `BackendProfileModel`.
    func saveProfile(_ profile: BackendProfileModel) {
        let context = viewContext
        
        let request: NSFetchRequest<BackendProfileEntity> = BackendProfileEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", profile.id as NSUUID)
        
        let entity = (try? context.fetch(request).first) ?? BackendProfileEntity(context: context)
        
        configure(entity: entity, with: profile, in: context)
        
        logger.info("Saving profile '\(profile.displayName)' (ID: \(profile.id.uuidString))")
        saveContext()
    }

    /// Deletes a profile with the specified ID.
    func deleteProfile(withId id: UUID) {
        let request: NSFetchRequest<BackendProfileEntity> = BackendProfileEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        
        do {
            if let entityToDelete = try viewContext.fetch(request).first {
                viewContext.delete(entityToDelete)
                logger.info("Deleting profile with ID \(id.uuidString).")
                saveContext()
            }
        } catch {
            logger.error("Failed to delete profile with ID \(id.uuidString): \(error.localizedDescription)")
        }
    }

    func saveContext() {
        CoreDataPersistenceService.shared.saveContext()
    }
    
    // MARK: - Private Configuration Logic
    
    /// The core logic for mapping a `BackendProfileModel` to Core Data entities.
    private func configure(entity: BackendProfileEntity, with profile: BackendProfileModel, in context: NSManagedObjectContext) {
        // 1. Configure common properties
        entity.id = profile.id
        entity.displayName = profile.displayName
        entity.lastSelected = profile.lastSelected
        entity.profileType = profile.profileType.rawValue

        // 2. Switch on the details to handle type-specific configuration
        switch profile.details {
        case .bot(let llmConfig, let instructions):
            let botEntity = entity.botConfig ?? BotConfigEntity(context: context)
            botEntity.llmConfig = encode(llmConfig)
            botEntity.instructions = instructions
            entity.botConfig = botEntity
            // Clean up other potential relationships
            entity.agentConfig = nil
            entity.workflowConfig = nil
            entity.imageGenConfig = nil
            
        case .agent(let llmConfig, let architecture, let tools, let description, let instructions, let knowledgeSources):
            let agentEntity = entity.agentConfig ?? AgentConfigEntity(context: context)
            agentEntity.llmConfig = encode(llmConfig)
            agentEntity.tools = encode(tools)
            
            // Persist the agent properties
            agentEntity.agentDescription = description
            agentEntity.instructions = instructions
            agentEntity.knowledgeSources = encode(knowledgeSources)
            
            // IMPORTANT: Crash Prevention
            // We check if the entity description actually has the key "agentArchitecture" before setting it.
            // This prevents NSUnknownKeyException if the Core Data model hasn't been updated yet.
            if agentEntity.entity.attributesByName.keys.contains("agentArchitecture") {
                agentEntity.setValue(architecture.rawValue, forKey: "agentArchitecture")
            } else {
                logger.warning("AgentConfigEntity missing 'agentArchitecture' attribute. Skipping save for this property.")
            }
            
            entity.agentConfig = agentEntity
            // Clean up other potential relationships
            entity.botConfig = nil
            entity.workflowConfig = nil
            entity.imageGenConfig = nil

        case .workflow(let agents):
            let workflowEntity = entity.workflowConfig ?? WorkflowConfigEntity(context: context)
            workflowEntity.agents = encode(agents)
            entity.workflowConfig = workflowEntity
            // Clean up other potential relationships
            entity.botConfig = nil
            entity.agentConfig = nil
            entity.imageGenConfig = nil

        case .imageGen(let llmConfig, let negativePrompt, let defaultAspectRatio, let advancedSettings):
            let imageGenEntity = entity.imageGenConfig ?? ImageGenConfigEntity(context: context)
            imageGenEntity.llmConfig = encode(llmConfig)
            imageGenEntity.negativePrompt = negativePrompt
            imageGenEntity.defaultAspectRatio = defaultAspectRatio?.rawValue
            imageGenEntity.advancedSettings = encode(advancedSettings)
            entity.imageGenConfig = imageGenEntity
            // Clean up other potential relationships
            entity.botConfig = nil
            entity.agentConfig = nil
            entity.workflowConfig = nil
        }
    }
    
    /// A generic helper to encode any `Codable` value to `Data`.
    private func encode<T: Codable>(_ value: T?) -> Data? {
        guard let value = value else { return nil }
        return try? JSONEncoder().encode(value)
    }
}

// MARK: - Core Data Entity Extensions
extension BackendProfileEntity {
    
    /// Converts a `BackendProfileEntity` back into the unified `BackendProfileModel`.
    func toBackendProfile() -> BackendProfileModel? {
        guard let typeString = self.profileType,
              let type = ProfileType(rawValue: typeString),
              let id = self.id,
              let displayName = self.displayName else {
            return nil
        }
        
        let details: ProfileDetails
        
        switch type {
        case .bot:
            guard let botDetails = createBotDetails() else { return nil }
            details = botDetails
        case .agent:
            guard let agentDetails = createAgentDetails() else { return nil }
            details = agentDetails
        case .workflow:
            guard let workflowDetails = createWorkflowDetails() else { return nil }
            details = workflowDetails
        case .imageGen:
            guard let imageGenDetails = createImageGenDetails() else { return nil }
            details = imageGenDetails
        }
        
        return BackendProfileModel(
            id: id,
            displayName: displayName,
            lastSelected: self.lastSelected,
            details: details
        )
    }
    
    // MARK: - Detail Creation Helpers
    
    private func createBotDetails() -> ProfileDetails? {
        guard let configEntity = self.botConfig,
              let configData = configEntity.llmConfig,
              let llmConfig: ProviderConfig = decode(from: configData) else {
            return nil
        }
        let instructions = configEntity.instructions
        return .bot(llmConfig: llmConfig, instructions: instructions)
    }
    
    private func createAgentDetails() -> ProfileDetails? {
        guard let configEntity = self.agentConfig,
              let llmConfigData = configEntity.llmConfig,
              let toolsData = configEntity.tools,
              let llmConfig: ProviderConfig = decode(from: llmConfigData),
              let tools: [Tool] = decode(from: toolsData) else {
            return nil
        }
        
        // Load the persisted agent properties
        let description = configEntity.agentDescription
        let instructions = configEntity.instructions
        let knowledgeSources: [KnowledgeSource]? = decode(from: configEntity.knowledgeSources)
        
        // Load architecture SAFELY
        var architecture: AgentArchitecture = .reAct
        
        // Check if the attribute exists in the model to avoid NSUnknownKeyException
        if configEntity.entity.attributesByName.keys.contains("agentArchitecture") {
            if let archString = configEntity.value(forKey: "agentArchitecture") as? String {
                architecture = AgentArchitecture(rawValue: archString) ?? .reAct
            }
        }
        
        return .agent(
            llmConfig: llmConfig,
            architecture: architecture,
            tools: tools,
            description: description,
            instructions: instructions,
            knowledgeSources: knowledgeSources
        )
    }
    
    private func createImageGenDetails() -> ProfileDetails? {
        guard let configEntity = self.imageGenConfig,
              let configData = configEntity.llmConfig,
              let llmConfig: ProviderConfig = decode(from: configData) else {
            return nil
        }
        let negativePrompt = configEntity.negativePrompt
        let aspectRatio = configEntity.defaultAspectRatio.flatMap { ImageAspectRatio(rawValue: $0) }
        let advancedSettings: [String: JSONValue]? = decode(from: configEntity.advancedSettings)
        return .imageGen(llmConfig: llmConfig, negativePrompt: negativePrompt, defaultAspectRatio: aspectRatio, advancedSettings: advancedSettings)
    }

    private func createWorkflowDetails() -> ProfileDetails? {
        guard let configEntity = self.workflowConfig,
              let agentsData = configEntity.agents,
              let agents: [BackendProfileModel] = decode(from: agentsData) else {
            return nil
        }
        return .workflow(agents: agents)
    }
    
    /// A generic helper to decode `Data` back into any `Decodable` type.
    private func decode<T: Decodable>(from data: Data?) -> T? {
        guard let data = data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
