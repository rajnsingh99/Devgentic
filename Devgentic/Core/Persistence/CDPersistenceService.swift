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
    
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage]
    
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String)
    func deleteConversation(with id: UUID)
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?)
    func togglePinStatus(for conversationId: UUID) // New method for pinning
    
    func saveContext()
}


// MARK: - Core Data Persistence Service
class CoreDataPersistenceService: CoreDataServiceProtocol {

    // MARK: - Singleton Instance
    static let shared = CoreDataPersistenceService()

    // MARK: - Private Properties
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "CoreDataPersistenceService")

    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "DevgenticDB")
        
        AgentResponseTransformer.register()
        
        // Register the transformer for the 'tags' attribute in PromptEntity and 'thoughts' in ChatMessageEntity
        ValueTransformer.setValueTransformer(StringArrayTransformer(), forName: NSValueTransformerName("StringArrayTransformer"))
        
        // Register the transformer for the 'generationType' attributes
        ValueTransformer.setValueTransformer(GenerationTypeArrayTransformer(), forName: NSValueTransformerName("GenerationTypeArrayTransformer"))
        
        // Register the transformer for the 'artifacts' attribute
        ValueTransformer.setValueTransformer(ToolOutputArrayTransformer(), forName: NSValueTransformerName("ToolOutputArrayTransformer"))
        
        AgentThoughtArrayTransformer.register()
        TimelineEventArrayTransformer.register()
        
        // Enable lightweight migration for schema changes (e.g., new optional attributes)
        if let description = container.persistentStoreDescriptions.first {
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }

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
    
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        return await viewContext.perform {
            let request: NSFetchRequest<ChatMessageEntity> = ChatMessageEntity.fetchRequest()
            
            request.predicate = NSPredicate(format: "conversationId == %@", conversationId as CVarArg)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            request.fetchLimit = limit
            request.fetchOffset = offset
            
            do {
                let entities = try self.viewContext.fetch(request)
                let chatMessages = entities.map { $0.toChatMessageStruct() }

                self.logger.debug("Fetched \(chatMessages.count) messages for conversation \(conversationId.uuidString) (offset: \(offset), limit: \(limit)):")
                
                return chatMessages
            } catch {
                self.logger.error("Failed to fetch messages for conversation \(conversationId.uuidString) with offset \(offset) and limit \(limit): \(error.localizedDescription)")
                return []
            }
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
        newConversation.isPinned = conversation.isPinned // Set isPinned
        newConversation.openAIThreadID = conversation.openAIThreadID
        newConversation.backendType = conversation.backendType?.rawValue
        newConversation.backendEntityId = conversation.backendEntityId

        for message in conversation.messages {
            let newMessage = ChatMessageEntity(context: viewContext)
            newMessage.id = message.id
            newMessage.timestamp = message.timestamp
            newMessage.senderType = message.sender.rawValue
            newMessage.conversationId = message.conversationId
            newMessage.traceID = message.traceID
            mapMessageContent(from: message.content, to: newMessage)
            
            // **FIX:** Use KVC to set transformable attributes
            newMessage.setValue(message.agentResponse, forKey: "agentResponse")
            newMessage.setValue(message.timelineEvents, forKey: "timelineEvents")
            
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
                let fetchRequest: NSFetchRequest<ChatMessageEntity> = ChatMessageEntity.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "id == %@", message.id as CVarArg)
                
                let existingEntity = try? context.fetch(fetchRequest).first
                let entityToUpdate = existingEntity ?? ChatMessageEntity(context: context)
                
                entityToUpdate.id = message.id
                entityToUpdate.timestamp = message.timestamp
                entityToUpdate.senderType = message.sender.rawValue
                entityToUpdate.conversationId = message.conversationId
                entityToUpdate.traceID = message.traceID
                
                if let currentAgentContent = message.currentAgentContent {
                    self.mapMessageContent(from: currentAgentContent, to: entityToUpdate)
                } else {
                    self.mapMessageContent(from: message.content, to: entityToUpdate)
                }
                
                // **FIX:** Use KVC to set transformable attributes
                entityToUpdate.setValue(message.agentResponse, forKey: "agentResponse")
                entityToUpdate.setValue(message.timelineEvents, forKey: "timelineEvents")
                
                self.logger.info("Saving message \(message.id.uuidString) with \(message.timelineEvents.count) timeline events.")
                
                if let textFiles = message.attachedTextFiles {
                    let textFileEntities = textFiles.map { textFile -> AttachedTextFileEntity in
                        let entity = AttachedTextFileEntity(context: context)
                        entity.id = textFile.id; entity.name = textFile.name; entity.url = textFile.url.absoluteString; entity.fileExtension = textFile.fileExtension; entity.content = textFile.content; entity.size = textFile.size
                        return entity
                    }
                    entityToUpdate.mutableSetValue(forKey: "attachedTextFiles").removeAllObjects()
                    entityToUpdate.addToAttachedTextFiles(NSSet(array: textFileEntities))
                }

                if let imageFiles = message.attachedImageFiles {
                    let imageFileEntities = imageFiles.map { imageFile -> AttachedImageFileEntity in
                        let entity = AttachedImageFileEntity(context: context)
                        entity.id = imageFile.id; entity.name = imageFile.name; entity.url = imageFile.url.absoluteString; entity.fileExtension = imageFile.fileExtension; entity.content = imageFile.binaryData; entity.size = imageFile.size
                        return entity
                    }
                    entityToUpdate.mutableSetValue(forKey: "attachedImageFiles").removeAllObjects()
                    entityToUpdate.addToAttachedImageFiles(NSSet(array: imageFileEntities))
                }

                if existingEntity == nil {
                    conversation.addToMessages(entityToUpdate)
                }
            }
            conversation.timestamp = Date()
            self.saveContext()
        }
        logger.debug("Finished robust async addMessages (upsert) for \(messages.count) messages.")
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
    
    func togglePinStatus(for conversationId: UUID) {
        guard let conversation = getConversation(withId: conversationId) else {
            logger.warning("Attempted to toggle pin for a conversation that does not exist: \(conversationId.uuidString)")
            return
        }
        conversation.isPinned.toggle()
        logger.info("Toggled pin status for conversation \(conversationId.uuidString) to \(conversation.isPinned).")
        saveContext()
    }
    
    
    // MARK: - Private Helper Methods
    func mapMessageContent(from content: MessageContent, to managedObject: ChatMessageEntity) {
        managedObject.text_content = nil
        managedObject.code_language = nil
        managedObject.code_content = nil
        managedObject.error_title = nil
        managedObject.error_details = nil
        managedObject.image_url = nil
        managedObject.image_data = nil

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
        case .image(let url, _, let imageData):
            managedObject.messageType = "image"
            managedObject.image_url = url?.absoluteString
            managedObject.image_data = imageData
        case .mediaArtifact(let artifact):
            managedObject.messageType = "mediaArtifact"
            managedObject.text_content = artifact.label ?? artifact.kind.rawValue
        }
    }
}


// MARK: - Entity Extensions

extension ConversationEntity {
    func toConversationStruct() -> Conversation {
        let messagesArray = (self.messages as? Set<ChatMessageEntity> ?? []).map { $0.toChatMessageStruct() }
        let backendType = self.backendType.flatMap { BackendType(rawValue: $0) }
        
        return Conversation(
            id: self.id ?? UUID(),
            messages: messagesArray.sorted(by: { $0.timestamp < $1.timestamp }),
            timestamp: self.timestamp ?? Date(),
            userDefinedTitle: self.userDefinedTitle,
            isPinned: self.isPinned,
            openAIThreadID: self.openAIThreadID,
            backendType: backendType,
            backendEntityId: self.backendEntityId
        )
    }
}

extension ChatMessageEntity {
    // **FIX:** Add logger to the extension's scope.
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatMessageEntity")

    func toChatMessageStruct() -> ChatMessage {
        let messageId = self.id ?? UUID()
        
        var finalContent: MessageContent
        var finalAgentResponse: AgentResponse?

        // **FIX:** Use KVC to retrieve the transformable attribute to bypass static type checks.
        if let agentResponse = self.value(forKey: "agentResponse") as? AgentResponse, !agentResponse.variants.isEmpty {
            finalAgentResponse = agentResponse
            if agentResponse.variants.indices.contains(agentResponse.selectedVariantIndex) {
                finalContent = agentResponse.variants[agentResponse.selectedVariantIndex].content
            } else {
                Self.logger.warning("Selected variant index \(agentResponse.selectedVariantIndex) is out of bounds. Using first variant.")
                finalContent = agentResponse.variants.first!.content
            }
        } else {
            // Fallback for older messages or decoding failures.
            switch self.messageType {
            case "plainText": finalContent = .plainText(self.text_content ?? "")
            case "markdownText": finalContent = .markdownText(self.text_content ?? "")
            case "codeBlock": finalContent = .codeBlock(language: self.code_language, code: self.code_content ?? "")
            case "error": finalContent = .error(title: self.error_title, details: self.error_details ?? "")
            case "image":
                let url = self.image_url.flatMap { URL(string: $0) }
                finalContent = .image(url: url, alt: nil, imageData: self.image_data)
            default:
                finalContent = .error(title: "Unknown Content", details: "Could not decode message content.")
            }
            
            if self.senderType == SenderRole.agent.rawValue {
                let initialVariant = ResponseMessageVariant(content: finalContent, backendEntityId: nil)
                finalAgentResponse = AgentResponse(variants: [initialVariant])
            }
        }
        
        let textFileEntities = self.attachedTextFiles as? Set<AttachedTextFileEntity> ?? []
        let attachedTextFiles = textFileEntities.compactMap { $0.toAttachedTextFileStruct() }

        let imageFileEntities = self.attachedImageFiles as? Set<AttachedImageFileEntity> ?? []
        let attachedImageFiles = imageFileEntities.compactMap { $0.toAttachedImageFileStruct() }
        
        let chatMessage = ChatMessage(
            id: messageId,
            conversationId: self.conversationId ?? UUID(),
            timestamp: self.timestamp ?? Date(),
            sender: SenderRole(rawValue: self.senderType ?? "user") ?? .user,
            content: finalContent,
            attachedTextFiles: attachedTextFiles.isEmpty ? nil : attachedTextFiles,
            attachedImageFiles: attachedImageFiles.isEmpty ? nil : attachedImageFiles
        )
        
        chatMessage.traceID = self.traceID
        chatMessage.agentResponse = finalAgentResponse
        
        if let timelineEvents = self.value(forKey: "timelineEvents") as? [TimelineEvent] {
            chatMessage.timelineEvents = timelineEvents
        }
        
        return chatMessage
    }
}

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

extension PromptEntity {
    func toPromptStruct() -> DevPrompt {
        return DevPrompt(
            id: self.id ?? UUID(),
            title: self.title ?? "Untitled Prompt",
            text: self.text ?? "",
            category: self.category ?? "General",
            createdAt: self.createdAt ?? Date(),
            lastUsedAt: self.lastUsedAt,
            isUserDefined: self.isUserDefined,
            tags: self.tags as? [String]
        )
    }
}

// MARK: - Value Transformers

@objc(StringArrayTransformer)
final class StringArrayTransformer: NSSecureUnarchiveFromDataTransformer {
    override static var allowedTopLevelClasses: [AnyClass] {
        [NSArray.self, NSString.self]
    }

    static func register() {
        let transformer = StringArrayTransformer()
        ValueTransformer.setValueTransformer(transformer, forName: NSValueTransformerName(rawValue: "StringArrayTransformer"))
    }
}

@objc(GenerationTypeArrayTransformer)
final class GenerationTypeArrayTransformer: NSSecureUnarchiveFromDataTransformer {
    override static var allowedTopLevelClasses: [AnyClass] {
        [NSArray.self, NSString.self]
    }

    static func register() {
        let transformer = GenerationTypeArrayTransformer()
        ValueTransformer.setValueTransformer(transformer, forName: NSValueTransformerName(rawValue: "GenerationTypeArrayTransformer"))
    }
}

@objc(AgentResponseTransformer)
final class AgentResponseTransformer: ValueTransformer {

    override class func transformedValueClass() -> AnyClass {
        return NSData.self
    }

    override class func allowsReverseTransformation() -> Bool {
        return true
    }

    override func transformedValue(_ value: Any?) -> Any? {
        guard let agentResponse = value as? AgentResponse else { return nil }
        do {
            let data = try JSONEncoder().encode(agentResponse)
            return data as NSData
        } catch {
            print("Failed to encode AgentResponse: \(error)")
            return nil
        }
    }

    override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let data = value as? Data else { return nil }
        do {
            let agentResponse = try JSONDecoder().decode(AgentResponse.self, from: data)
            return agentResponse
        } catch {
            print("Failed to decode AgentResponse: \(error)")
            return nil
        }
    }

    static func register() {
        let transformer = AgentResponseTransformer()
        ValueTransformer.setValueTransformer(transformer, forName: NSValueTransformerName(rawValue: "AgentResponseTransformer"))
    }
}

// NEW: Tool Output Transformer
@objc(ToolOutputArrayTransformer)
final class ToolOutputArrayTransformer: ValueTransformer {

    override class func transformedValueClass() -> AnyClass {
        return NSData.self
    }

    override class func allowsReverseTransformation() -> Bool {
        return true
    }

    override func transformedValue(_ value: Any?) -> Any? {
        guard let artifacts = value as? [ToolOutput] else { return nil }
        do {
            let data = try JSONEncoder().encode(artifacts)
            return data as NSData
        } catch {
            print("Failed to encode [ToolOutput]: \(error)")
            return nil
        }
    }

    override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let data = value as? Data else { return nil }
        do {
            let artifacts = try JSONDecoder().decode([ToolOutput].self, from: data)
            return artifacts
        } catch {
            print("Failed to decode [ToolOutput]: \(error)")
            return nil
        }
    }
}

// NEW: Agent Thought Transformer
@objc(AgentThoughtArrayTransformer)
final class AgentThoughtArrayTransformer: ValueTransformer {

    override class func transformedValueClass() -> AnyClass {
        return NSData.self
    }

    override class func allowsReverseTransformation() -> Bool {
        return true
    }

    override func transformedValue(_ value: Any?) -> Any? {
        guard let thoughts = value as? [AgentThought] else { return nil }
        do {
            let data = try JSONEncoder().encode(thoughts)
            return data as NSData
        } catch {
            print("Failed to encode [AgentThought]: \(error)")
            return nil
        }
    }

    override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let data = value as? Data else { return nil }
        do {
            let thoughts = try JSONDecoder().decode([AgentThought].self, from: data)
            return thoughts
        } catch {
            print("Failed to decode [AgentThought]: \(error)")
            return nil
        }
    }
    
    static func register() {
        let transformer = AgentThoughtArrayTransformer()
        ValueTransformer.setValueTransformer(transformer, forName: NSValueTransformerName(rawValue: "AgentThoughtArrayTransformer"))
    }
}

// NEW: Timeline Event Transformer
@objc(TimelineEventArrayTransformer)
final class TimelineEventArrayTransformer: ValueTransformer {

    override class func transformedValueClass() -> AnyClass {
        return NSData.self
    }

    override class func allowsReverseTransformation() -> Bool {
        return true
    }

    override func transformedValue(_ value: Any?) -> Any? {
        guard let events = value as? [TimelineEvent] else { return nil }
        do {
            let data = try JSONEncoder().encode(events)
            return data as NSData
        } catch {
            print("Failed to encode [TimelineEvent]: \(error)")
            return nil
        }
    }

    override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let data = value as? Data else { return nil }
        do {
            let events = try JSONDecoder().decode([TimelineEvent].self, from: data)
            return events
        } catch {
            print("Failed to decode [TimelineEvent]: \(error)")
            return nil
        }
    }
    
    static func register() {
        let transformer = TimelineEventArrayTransformer()
        ValueTransformer.setValueTransformer(transformer, forName: NSValueTransformerName(rawValue: "TimelineEventArrayTransformer"))
    }
}
