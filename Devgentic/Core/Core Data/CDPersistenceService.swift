//
//  CDPersistenceService.swift
//  Devgentic
//
//  Created by Raj Singh on 20/06/25.
//

import Foundation
import CoreData
import os

// MARK: - Core Data Service Protocol
protocol CoreDataServiceProtocol {
    // Conversation Methods
    func addMessage(_ message: ChatMessage, to conversation: ConversationEntity) async
    func addMessages(_ messages: [ChatMessage], to conversation: ConversationEntity) async
    func getConversation(withId id: UUID) -> ConversationEntity?
    func deleteConversation(with id: UUID)

    // Agent Profile Methods
    func getAgentProfile(withId id: UUID) -> AgentProfileEntity?
    func fetchAgentProfiles() -> [AgentProfileEntity]
    func addAgentProfile(from model: AgentProfileModel, in context: NSManagedObjectContext)
    func updateAgentProfile(entity: AgentProfileEntity, with model: AgentProfileModel)
    func deleteAgentProfile(with id: UUID)
    
    // LLM Integration Methods
    func getLLMIntegration(withId id: UUID) -> LLMIntegrationEntity?
    func fetchLLMIntegrations() -> [LLMIntegrationEntity]
    func addLLMIntegration(from model: LLMIntegrationModel)
    func updateLLMIntegration(entity: LLMIntegrationEntity, with model: LLMIntegrationModel)
    func deleteLLMIntegration(with id: UUID)
    
    func saveContext()
}


// MARK: - Core Data Persistence Service
class CoreDataPersistenceService: CoreDataServiceProtocol {

    // MARK: - Singleton Instance
    static let shared = CoreDataPersistenceService()

    // MARK: - Private Properties
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "CoreDataPersistenceService")

    lazy var persistentContainer: NSPersistentContainer = {
        // --- MODIFIED: The container name should match your .xcdatamodeld file ---
        let container = NSPersistentContainer(name: "DevgenticDB")
        
        container.loadPersistentStores { (storeDescription, error) in
            if let error = error as NSError? {
                self.logger.critical("Unresolved error \(error), \(error.userInfo)")
                fatalError("Unresolved error \(error), \(error.userInfo)")
            } else {
                self.logger.info("Core Data store loaded successfully at: \(storeDescription.url?.path ?? "N/A")")
            }
        }
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
        
        return container
    }()

    /// The main managed object context, running on the main queue.
    var viewContext: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    // MARK: - Initialization
    /// Private initializer to enforce the singleton pattern.
    private init() {}

    // MARK: - Core Data Saving Support
    func saveContext() {
        if viewContext.hasChanges {
            do {
                try viewContext.save()
                logger.debug("Successfully saved Core Data context.")
            } catch {
                let nserror = error as NSError
                logger.error("Unresolved error during context save: \(nserror), \(nserror.userInfo)")
            }
        }
    }

    // MARK: - Public CRUD Operations (Conversations, Messages, Agents)
    // ... (Existing methods for Conversations, Messages, and AgentProfiles remain unchanged) ...
    func getConversation(withId id: UUID) -> ConversationEntity? {
        let fetchRequest: NSFetchRequest<ConversationEntity> = ConversationEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            let results = try viewContext.fetch(fetchRequest)
            return results.first
        } catch {
            logger.error("Failed to fetch conversation with ID \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    func addConversation(from conversation: Conversation) {
        let newConversation = ConversationEntity(context: viewContext)
        newConversation.id = conversation.id
        newConversation.timestamp = conversation.timestamp
        newConversation.userDefinedTitle = conversation.userDefinedTitle

        for message in conversation.messages {
            let newMessage = ChatMessageEntity(context: viewContext)
            newMessage.id = message.id
            newMessage.timestamp = message.timestamp
            newMessage.senderType = message.sender.rawValue
            newMessage.conversationId = message.conversationId
            
            mapMessageContent(from: message.content, to: newMessage)

            newConversation.addToMessages(newMessage)
        }
        
        logger.info("Adding new conversation with ID \(conversation.id.uuidString) to the context.")
        saveContext()
    }

    func deleteConversation(with id: UUID) {
        if let conversationToDelete = getConversation(withId: id) {
            viewContext.delete(conversationToDelete)
            logger.info("Deleting conversation with ID \(id.uuidString) from the context.")
            saveContext()
        } else {
            logger.warning("Tried to delete a conversation with ID \(id.uuidString), but it was not found.")
        }
    }

    func addMessage(_ message: ChatMessage, to conversation: ConversationEntity) async {
        await addMessages([message], to: conversation)
    }

    func addMessages(_ messages: [ChatMessage], to conversation: ConversationEntity) async {
        let context = conversation.managedObjectContext ?? self.viewContext
        
        await context.perform {
            for message in messages {
                let newMessageEntity = ChatMessageEntity(context: context)
                newMessageEntity.id = message.id
                newMessageEntity.timestamp = message.timestamp
                newMessageEntity.senderType = message.sender.rawValue
                newMessageEntity.conversationId = message.conversationId
                self.mapMessageContent(from: message.content, to: newMessageEntity)
                conversation.addToMessages(newMessageEntity)
            }
            conversation.timestamp = Date()
            self.saveContext()
        }
        logger.debug("Finished async addMessages for \(messages.count) messages.")
    }
    
    func getAgentProfile(withId id: UUID) -> AgentProfileEntity? {
            let request: NSFetchRequest<AgentProfileEntity> = AgentProfileEntity.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            do {
                return try viewContext.fetch(request).first
            } catch {
                logger.error("Failed to fetch AgentProfile with ID \(id.uuidString): \(error.localizedDescription)")
                return nil
            }
        }

    func fetchAgentProfiles() -> [AgentProfileEntity] {
        let request: NSFetchRequest<AgentProfileEntity> = AgentProfileEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        do {
            return try viewContext.fetch(request)
        } catch {
            logger.error("Failed to fetch all AgentProfiles: \(error.localizedDescription)")
            return []
        }
    }
    
    func addAgentProfile(from model: AgentProfileModel, in context: NSManagedObjectContext) {
        let newAgent = AgentProfileEntity(context: context)
        updateAgentProfile(entity: newAgent, with: model)
        logger.info("Adding new Agent Profile '\(model.name)' to context.")
        saveContext()
    }

    func updateAgentProfile(entity: AgentProfileEntity, with model: AgentProfileModel) {
        let context = entity.managedObjectContext ?? viewContext
        entity.id = model.id
        entity.name = model.name
        entity.role = model.role
        entity.baseURL = model.baseURL
        entity.linkedIntegrationID = model.linkedIntegrationID
        
        let currentSelectedTools = entity.mutableSetValue(forKey: "tools")
        currentSelectedTools.removeAllObjects()

        for selectedToolModel in model.tools {
            let newSelectedToolEntity = SelectedToolEntity(context: context)
            newSelectedToolEntity.id = UUID()
            newSelectedToolEntity.toolName = selectedToolModel.toolName
            newSelectedToolEntity.displayName = selectedToolModel.displayName
            currentSelectedTools.add(newSelectedToolEntity)
        }

        logger.trace("Updating attributes for Agent Profile: \(model.name)")
        saveContext()
    }

    func deleteAgentProfile(with id: UUID) {
        if let agentToDelete = getAgentProfile(withId: id) {
            viewContext.delete(agentToDelete)
            logger.info("Deleting Agent Profile with ID \(id.uuidString) from context.")
            saveContext()
        }
    }
    
    // MARK: - LLM Integration Methods (Refactored)
    
    func getLLMIntegration(withId id: UUID) -> LLMIntegrationEntity? {
        let request: NSFetchRequest<LLMIntegrationEntity> = LLMIntegrationEntity.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        do {
            return try viewContext.fetch(request).first
        } catch {
            logger.error("Failed to fetch LLMIntegrationEntity with ID \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    func fetchLLMIntegrations() -> [LLMIntegrationEntity] {
        let request: NSFetchRequest<LLMIntegrationEntity> = LLMIntegrationEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "displayName", ascending: true)]
        do {
            return try viewContext.fetch(request)
        } catch {
            logger.error("Failed to fetch all LLMIntegrationEntity objects: \(error.localizedDescription)")
            return []
        }
    }

    // --- REFACTORED ---
    /// Creates a new `LLMIntegrationEntity` and its corresponding config entity from a model struct.
    func addLLMIntegration(from model: LLMIntegrationModel) {
        let newIntegration = LLMIntegrationEntity(context: viewContext)
        newIntegration.id = model.id
        newIntegration.displayName = model.displayName
        newIntegration.providerType = model.providerType.rawValue
        newIntegration.lastSelected = model.lastSelected
        
        // Create and link the appropriate config entity
        switch model.providerType {
        case .ollama:
            if let configModel = model.ollamaConfig {
                let ollamaConfigEntity = OllamaConfigEntity(context: viewContext)
                ollamaConfigEntity.baseURL = configModel.baseURL
                ollamaConfigEntity.modelName = configModel.modelName
                ollamaConfigEntity.temperature = configModel.temperature ?? 0.8
                ollamaConfigEntity.contextWindowSize = Int64(configModel.contextWindowSize ?? 4096)
                newIntegration.ollamaConfig = ollamaConfigEntity
            }
        case .remote:
            if let configModel = model.remoteConfig {
                let remoteConfigEntity = RemoteConfigEntity(context: viewContext)
                remoteConfigEntity.provider = configModel.provider.rawValue
                remoteConfigEntity.apiKey = configModel.apiKey
                remoteConfigEntity.modelName = configModel.modelName
                remoteConfigEntity.temperature = configModel.temperature ?? 0.8
                remoteConfigEntity.contextWindowSize = Int64(configModel.contextWindowSize ?? 4096)
                newIntegration.remoteConfig = remoteConfigEntity
            }
        }
        
        logger.info("Adding new LLM Integration '\(model.displayName)' with \(model.providerType.rawValue) config.")
        saveContext()
    }

    // --- REFACTORED ---
    /// Updates an existing `LLMIntegrationEntity` with data from a model struct, handling config changes.
    func updateLLMIntegration(entity: LLMIntegrationEntity, with model: LLMIntegrationModel) {
        entity.displayName = model.displayName
        entity.lastSelected = model.lastSelected
        
        // If provider type changed, delete old config and create new one
        if entity.providerType != model.providerType.rawValue {
            // Delete existing configs
            if let ollamaConfig = entity.ollamaConfig {
                viewContext.delete(ollamaConfig)
                entity.ollamaConfig = nil
            }
            if let remoteConfig = entity.remoteConfig {
                viewContext.delete(remoteConfig)
                entity.remoteConfig = nil
            }
            
            // Create and link the new config
            entity.providerType = model.providerType.rawValue
            switch model.providerType {
            case .ollama:
                if let configModel = model.ollamaConfig {
                    let newConfig = OllamaConfigEntity(context: viewContext)
                    newConfig.baseURL = configModel.baseURL
                    newConfig.modelName = configModel.modelName
                    newConfig.temperature = configModel.temperature ?? 0.8
                    newConfig.contextWindowSize = Int64(configModel.contextWindowSize ?? 4096)
                    entity.ollamaConfig = newConfig
                }
            case .remote:
                 if let configModel = model.remoteConfig {
                    let newConfig = RemoteConfigEntity(context: viewContext)
                    newConfig.provider = configModel.provider.rawValue
                    newConfig.apiKey = configModel.apiKey
                    newConfig.modelName = configModel.modelName
                    newConfig.temperature = configModel.temperature ?? 0.8
                    newConfig.contextWindowSize = Int64(configModel.contextWindowSize ?? 4096)
                    entity.remoteConfig = newConfig
                }
            }
        } else {
            // Provider type is the same, just update the existing config
            switch model.providerType {
            case .ollama:
                if let configModel = model.ollamaConfig, let configEntity = entity.ollamaConfig {
                    configEntity.baseURL = configModel.baseURL
                    configEntity.modelName = configModel.modelName
                    configEntity.temperature = configModel.temperature ?? 0.8
                    configEntity.contextWindowSize = Int64(configModel.contextWindowSize ?? 4096)
                }
            case .remote:
                if let configModel = model.remoteConfig, let configEntity = entity.remoteConfig {
                    configEntity.provider = configModel.provider.rawValue
                    configEntity.apiKey = configModel.apiKey
                    configEntity.modelName = configModel.modelName
                    configEntity.temperature = configModel.temperature ?? 0.8
                    configEntity.contextWindowSize = Int64(configModel.contextWindowSize ?? 4096)
                }
            }
        }

        logger.trace("Updating attributes for LLM Integration: \(model.displayName)")
        saveContext()
    }

    func deleteLLMIntegration(with id: UUID) {
        if let integrationToDelete = getLLMIntegration(withId: id) {
            viewContext.delete(integrationToDelete)
            logger.info("Deleting LLM Integration with ID \(id.uuidString) from context.")
            saveContext()
        }
    }

    // MARK: - Private Helper Methods
    func mapMessageContent(from content: MessageContent, to managedObject: ChatMessageEntity) {
        // ... (This method remains unchanged) ...
        managedObject.text_content = nil
        managedObject.code_language = nil
        managedObject.code_content = nil
        managedObject.error_title = nil
        managedObject.error_details = nil
        managedObject.image_url = nil

        switch content {
        case .plainText(let text):
            managedObject.messageType = "plainText"
            managedObject.text_content = text
        case .markdownText(let text):
            managedObject.messageType = "markdownText"
            managedObject.text_content = text
        case .codeBlock(let language, let code):
            managedObject.messageType = "codeBlock"
            managedObject.code_language = language
            managedObject.code_content = code
        case .error(let title, let details):
            managedObject.messageType = "error"
            managedObject.error_title = title
            managedObject.error_details = details
        case .image(let url, _):
            managedObject.messageType = "image"
            managedObject.image_url = url?.absoluteString
        }
    }
}

// MARK: - NSManagedObject Subclass Extensions (Refactored)

// ... (Extensions for ConversationEntity, ChatMessageEntity, AgentProfileEntity, SelectedToolEntity remain unchanged) ...
extension ConversationEntity {
    func toConversationStruct() -> Conversation {
        let messagesArray = (self.messages as? Set<ChatMessageEntity> ?? []).map { $0.toChatMessageStruct() }
        
        return Conversation(
            id: self.id ?? UUID(),
            messages: messagesArray.sorted(by: { $0.timestamp < $1.timestamp }),
            timestamp: self.timestamp ?? Date(),
            userDefinedTitle: self.userDefinedTitle
        )
    }
}

extension ChatMessageEntity {
    func toChatMessageStruct() -> ChatMessage {
        var content: MessageContent = .error(title: "Unknown Content", details: "Could not decode message content from Core Data.")
        
        switch self.messageType {
        case "plainText":
            content = .plainText(self.text_content ?? "")
        case "markdownText":
            content = .markdownText(self.text_content ?? "")
        case "codeBlock":
            content = .codeBlock(language: self.code_language, code: self.code_content ?? "")
        case "error":
            content = .error(title: self.error_title, details: self.error_details ?? "")
        case "image":
            let url = self.image_url.flatMap { URL(string: $0) }
            content = .image(url: url, alt: nil)
        default:
            break
        }
        
        return ChatMessage(
            id: self.id ?? UUID(),
            conversationId: self.conversationId ?? UUID(),
            timestamp: self.timestamp ?? Date(),
            sender: SenderRole(rawValue: self.senderType ?? "user") ?? .user,
            content: content
        )
    }
}

extension AgentProfileEntity {
    func toAgentProfileModel() -> AgentProfileModel {
        let selectedToolsSet = self.tools as? Set<SelectedToolEntity> ?? []
        let selectedToolsArray = selectedToolsSet.map { $0.toSelectedToolModel() }
        
        return AgentProfileModel(
            id: self.id ?? UUID(),
            name: self.name ?? "Unnamed Agent",
            role: self.role ?? "",
            baseURL: self.baseURL ?? "",
            linkedIntegrationID: self.linkedIntegrationID,
            tools: selectedToolsArray
        )
    }
}


extension SelectedToolEntity {
    func toSelectedToolModel() -> SelectedTool {
        return SelectedTool(
            toolName: self.toolName ?? "unknown_tool",
            displayName: self.displayName ?? "Unknown Tool"
        )
    }
}

// --- REFACTORED ---
extension LLMIntegrationEntity {
    /// Converts a Core Data entity and its related config entity back to a plain Swift struct.
    func toLLMIntegrationModel() -> LLMIntegrationModel {
        let providerType = ProviderType(rawValue: self.providerType ?? "ollama") ?? .ollama
        var ollamaConfig: OllamaConfigModel? = nil
        var remoteConfig: RemoteConfigModel? = nil
        
        if providerType == .ollama, let configEntity = self.ollamaConfig {
            ollamaConfig = configEntity.toOllamaConfigModel()
        } else if providerType == .remote, let configEntity = self.remoteConfig {
            remoteConfig = configEntity.toRemoteConfigModel()
        }
        
        return LLMIntegrationModel(
            id: self.id ?? UUID(),
            displayName: self.displayName ?? "Unnamed Integration",
            providerType: providerType,
            lastSelected: self.lastSelected,
            ollamaConfig: ollamaConfig,
            remoteConfig: remoteConfig
        )
    }
}

// --- NEW: Extensions for new config entities ---
extension OllamaConfigEntity {
    /// Converts the Core Data entity to its corresponding Swift model.
    func toOllamaConfigModel() -> OllamaConfigModel {
        return OllamaConfigModel(
            baseURL: self.baseURL ?? "",
            modelName: self.modelName ?? "",
            temperature: self.temperature,
            contextWindowSize: Int(self.contextWindowSize)
        )
    }
}

extension RemoteConfigEntity {
    /// Converts the Core Data entity to its corresponding Swift model.
    func toRemoteConfigModel() -> RemoteConfigModel {
        return RemoteConfigModel(
            provider: RemoteProvider(rawValue: self.provider ?? "openAI") ?? .openAI,
            apiKey: self.apiKey ?? "",
            modelName: self.modelName ?? "",
            temperature: self.temperature,
            contextWindowSize: Int(self.contextWindowSize)
        )
    }
}
