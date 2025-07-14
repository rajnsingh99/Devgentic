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
    func addConversation(from conversation: Conversation)
    func addMessage(_ message: ChatMessage, to conversation: ConversationEntity) async
    func addMessages(_ messages: [ChatMessage], to conversation: ConversationEntity) async
    func getConversation(withId id: UUID) -> ConversationEntity?
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String)
    func deleteConversation(with id: UUID)
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?)

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
    
    // RAG Services
    private let embeddingService = EmbeddingService.shared
    private let vectorStoreService = VectorStoreService.shared
    private let textChunker = TextChunker()

    lazy var persistentContainer: NSPersistentContainer = {
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

    // MARK: - Conversation Methods
    
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

    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("Attempted to update thread ID for a conversation that does not exist: \(conversationId.uuidString)")
            return
        }
        
        conversation.openAIThreadID = threadId
        
        logger.info("Updating conversation \(conversationId.uuidString) with new OpenAI thread ID.")
        saveContext()
    }

    func addConversation(from conversation: Conversation) {
        let newConversation = ConversationEntity(context: viewContext)
        newConversation.id = conversation.id
        newConversation.timestamp = conversation.timestamp
        newConversation.userDefinedTitle = conversation.userDefinedTitle
        newConversation.openAIThreadID = conversation.openAIThreadID
        newConversation.backendType = conversation.backendType?.rawValue
        newConversation.backendEntityId = conversation.backendEntityId

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
                
                // --- Save Attached Text Files ---
                if let textFiles = message.attachedTextFiles {
                    let textFileEntities = textFiles.map { textFile -> AttachedTextFileEntity in
                        let entity = AttachedTextFileEntity(context: context)
                        entity.id = textFile.id
                        entity.name = textFile.name
                        entity.url = textFile.url.absoluteString
                        entity.fileExtension = textFile.fileExtension
                        entity.content = textFile.content
                        entity.size = textFile.size
                        return entity
                    }
                    newMessageEntity.addToAttachedTextFiles(NSSet(array: textFileEntities))
                }

                // --- Save Attached Image Files ---
                if let imageFiles = message.attachedImageFiles {
                    let imageFileEntities = imageFiles.map { imageFile -> AttachedImageFileEntity in
                        let entity = AttachedImageFileEntity(context: context)
                        entity.id = imageFile.id
                        entity.name = imageFile.name
                        entity.url = imageFile.url.absoluteString
                        entity.fileExtension = imageFile.fileExtension
                        entity.content = imageFile.binaryData
                        entity.size = imageFile.size
                        return entity
                    }
                    newMessageEntity.addToAttachedImageFiles(NSSet(array: imageFileEntities))
                }

                conversation.addToMessages(newMessageEntity)
                
                // ** RAG INTEGRATION: Index message content **
                Task {
                    await self.indexMessageForRAG(message)
                }
            }
            conversation.timestamp = Date()
            self.saveContext()
        }
        logger.debug("Finished async addMessages for \(messages.count) messages.")
    }
    
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {
        guard let conversation = getConversation(withId: id) else {
            logger.warning("Attempted to update backend for a conversation that does not exist: \(id.uuidString)")
            return
        }
        
        conversation.backendType = backendType?.rawValue
        conversation.backendEntityId = backendEntityId
        
        logger.info("Updating conversation \(id.uuidString) with backend type: \(backendType?.rawValue ?? "none")")
        saveContext()
    }
    
    // MARK: - RAG Indexing
    
    /// Chunks, embeds, and indexes the textual content of a message for RAG.
    private func indexMessageForRAG(_ message: ChatMessage) async {
        var textToProcess = ""
        
        // Aggregate all text content from the message
        if let textContent = message.content.textContent {
            textToProcess += textContent + "\n"
        }
        
        if let attachedFiles = message.attachedTextFiles {
            for file in attachedFiles {
                textToProcess += "\n--- Start of file: \(file.name) ---\n"
                textToProcess += file.content
                textToProcess += "\n--- End of file: \(file.name) ---\n"
            }
        }
        
        guard !textToProcess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return // No text to index
        }
        
        // 1. Chunk the text
        let chunks = textChunker.chunk(text: textToProcess)
        var chunkEntities: [ChunkEntity] = []
        
        // 2. Embed and create entities for each chunk
        for chunkText in chunks {
            if let embedding = await embeddingService.generateEmbedding(for: chunkText) {
                let chunkEntity = ChunkEntity(
                    sourceMessageID: message.id,
                    content: chunkText,
                    embedding: embedding,
                    timestamp: message.timestamp
                )
                chunkEntities.append(chunkEntity)
            }
        }
        
        // 3. Save to vector store
        if !chunkEntities.isEmpty {
            vectorStoreService.add(chunks: chunkEntities)
            logger.info("Indexed \(chunkEntities.count) chunks for message \(message.id.uuidString).")
        }
    }

    
    // MARK: - Agent Profile Methods
    
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
    
    // MARK: - LLM Integration Methods
    
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

    func addLLMIntegration(from model: LLMIntegrationModel) {
        let newIntegration = LLMIntegrationEntity(context: viewContext)
        newIntegration.id = model.id
        newIntegration.displayName = model.displayName
        newIntegration.providerType = model.providerType.rawValue
        newIntegration.lastSelected = model.lastSelected
        
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

    func updateLLMIntegration(entity: LLMIntegrationEntity, with model: LLMIntegrationModel) {
        entity.displayName = model.displayName
        entity.lastSelected = model.lastSelected
        
        if entity.providerType != model.providerType.rawValue {
            if let ollamaConfig = entity.ollamaConfig { viewContext.delete(ollamaConfig); entity.ollamaConfig = nil }
            if let remoteConfig = entity.remoteConfig { viewContext.delete(remoteConfig); entity.remoteConfig = nil }
            
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

// MARK: - NSManagedObject Subclass Extensions

extension ConversationEntity {
    func toConversationStruct() -> Conversation {
        let messagesArray = (self.messages as? Set<ChatMessageEntity> ?? []).map { $0.toChatMessageStruct() }
        let backendType = self.backendType.flatMap { BackendType(rawValue: $0) }
        
        return Conversation(
            id: self.id ?? UUID(),
            messages: messagesArray.sorted(by: { $0.timestamp < $1.timestamp }),
            timestamp: self.timestamp ?? Date(),
            userDefinedTitle: self.userDefinedTitle,
            openAIThreadID: self.openAIThreadID,
            backendType: backendType,
            backendEntityId: self.backendEntityId
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
        
        // --- Load Attached Text Files ---
        let textFileEntities = self.attachedTextFiles as? Set<AttachedTextFileEntity> ?? []
        let attachedTextFiles = textFileEntities.compactMap { $0.toAttachedTextFileStruct() }

        // --- Load Attached Image Files ---
        let imageFileEntities = self.attachedImageFiles as? Set<AttachedImageFileEntity> ?? []
        let attachedImageFiles = imageFileEntities.compactMap { $0.toAttachedImageFileStruct() }
        
        return ChatMessage(
            id: self.id ?? UUID(),
            conversationId: self.conversationId ?? UUID(),
            timestamp: self.timestamp ?? Date(),
            sender: SenderRole(rawValue: self.senderType ?? "user") ?? .user,
            content: content,
            attachedTextFiles: attachedTextFiles.isEmpty ? nil : attachedTextFiles,
            attachedImageFiles: attachedImageFiles.isEmpty ? nil : attachedImageFiles
        )
    }
}

// MARK: - Attached File Entity Extensions

extension AttachedTextFileEntity {
    func toAttachedTextFileStruct() -> AttachedTextFile? {
        guard let name = self.name,
              let urlString = self.url, let url = URL(string: urlString),
              let fileExtension = self.fileExtension,
              let content = self.content else {
            return nil
        }
        return AttachedTextFile(
            id: self.id ?? UUID(),
            name: name,
            url: url,
            fileExtension: fileExtension,
            content: content,
            size: self.size
        )
    }
}

extension AttachedImageFileEntity {
    func toAttachedImageFileStruct() -> AttachedImageFile? {
        guard let name = self.name,
              let urlString = self.url, let url = URL(string: urlString),
              let fileExtension = self.fileExtension,
              let binaryData = self.content else {
            return nil
        }
        return AttachedImageFile(
            id: self.id ?? UUID(),
            name: name,
            url: url,
            fileExtension: fileExtension,
            binaryData: binaryData,
            size: self.size
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

extension LLMIntegrationEntity {
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

extension OllamaConfigEntity {
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
