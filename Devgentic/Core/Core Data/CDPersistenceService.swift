// Services/CoreDataPersistenceService.swift
import Foundation
import CoreData
import os

// MARK: - Core Data Service Protocol
protocol CoreDataServiceProtocol {
    // Conversation Methods
    func getConversation(withId id: UUID) -> ConversationEntity?
    func deleteConversation(with id: UUID)

    // Ollama Profile Methods
    func getOllamaProfile(withId id: UUID) -> OllamaProfileEntity?
    func deleteOllamaProfile(with id: UUID)
    func addOllamaProfile(from model: OllamaProfileModel)
    func updateOllamaProfile(entity: OllamaProfileEntity, with model: OllamaProfileModel)

    func saveContext()
}


// MARK: - Core Data Persistence Service
class CoreDataPersistenceService: CoreDataServiceProtocol {

    // MARK: - Singleton Instance
    static let shared = CoreDataPersistenceService()

    // MARK: - Private Properties
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "CoreDataPersistenceService")

    // --- FIX: 'private' removed to make it internally accessible ---
    /// The persistent container for the Core Data stack.
    /// This needs to be accessible within the module to inject its context into the SwiftUI environment.
    lazy var persistentContainer: NSPersistentContainer = {
    // -------------------------------------------------------------
        // The name "ChatModel" must match the name of your .xcdatamodeld file.
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

    // MARK: - Public CRUD Operations

    /// Fetches a single conversation by its UUID.
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

    /// Creates and adds a new conversation and its messages from your Codable `Conversation` struct.
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

    /// Deletes a conversation by its UUID.
    func deleteConversation(with id: UUID) {
        if let conversationToDelete = getConversation(withId: id) {
            viewContext.delete(conversationToDelete)
            logger.info("Deleting conversation with ID \(id.uuidString) from the context.")
            saveContext()
        } else {
            logger.warning("Tried to delete a conversation with ID \(id.uuidString), but it was not found.")
        }
    }

    // MARK: - Message Handling
    
    /// Adds a single message to a conversation entity and saves the context.
    func addMessage(_ message: ChatMessage, to conversation: ConversationEntity) {
        addMessages([message], to: conversation)
    }

    /// Adds an array of messages to a conversation entity and saves the context.
    func addMessages(_ messages: [ChatMessage], to conversation: ConversationEntity) {
        let context = conversation.managedObjectContext ?? self.viewContext
        
        context.perform {
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
    }
    
    // MARK: - Ollama Profile CRUD Operations (NEW)
        
        /// Fetches a single Ollama profile by its UUID.
    func getOllamaProfile(withId id: UUID) -> OllamaProfileEntity? {
        let fetchRequest: NSFetchRequest<OllamaProfileEntity> = OllamaProfileEntity.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            return try viewContext.fetch(fetchRequest).first
        } catch {
            logger.error("Failed to fetch Ollama profile with ID \(id.uuidString): \(error.localizedDescription)")
            return nil
        }
    }
    /// Creates a new `OllamaProfileEntity` from an `OllamaProfileModel` struct.
    func addOllamaProfile(from model: OllamaProfileModel) {
        let newProfile = OllamaProfileEntity(context: viewContext)
        updateOllamaProfile(entity: newProfile, with: model)
        logger.info("Adding new Ollama profile '\(model.profileName)' to context.")
        saveContext()
    }
    
    /// Updates an existing `OllamaProfileEntity` with data from an `OllamaProfileModel`.
    func updateOllamaProfile(entity: OllamaProfileEntity, with model: OllamaProfileModel) {
        entity.id = model.id
        entity.profileName = model.profileName
        entity.baseURL = model.baseURL
        entity.llmModelName = model.llmModelName
        entity.temperature = model.temperature
        entity.topK = Int64(model.topK)
        entity.topP = model.topP
        entity.repeatPenalty = model.repeatPenalty
        entity.contextWindowSize = Int64(model.contextWindowSize)
        entity.gpuLayers = Int64(model.gpuLayers)
        entity.maxInlineChars = Int64(model.maxInlineChars)
        entity.maxAttachedFiles = Int64(model.maxAttachedFiles)
        entity.textFileInclusionStrategy = model.textFileInclusionStrategy.rawValue
        entity.imageHandlingStrategy = model.imageHandlingStrategy.rawValue
        entity.binaryFileHandlingStrategy = model.binaryFileHandlingStrategy.rawValue
        
        logger.trace("Updating attributes for Ollama profile: \(model.profileName)")
        saveContext()
    }
    /// Deletes an Ollama profile by its UUID.
    func deleteOllamaProfile(with id: UUID) {
        if let profileToDelete = getOllamaProfile(withId: id) {
            viewContext.delete(profileToDelete)
            logger.info("Deleting Ollama profile with ID \(id.uuidString) from context.")
            saveContext()
        } else {
            logger.warning("Tried to delete an Ollama profile with ID \(id.uuidString), but it was not found.")
        }
    }


    // MARK: - Private Helper Methods
    
    /// Maps the `MessageContent` enum to the attributes of a `ChatMessageEntity` managed object.
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

extension OllamaProfileEntity {
    /// Converts a Core Data entity back to a plain Swift struct.
    func toOllamaProfileModel() -> OllamaProfileModel {
        return OllamaProfileModel(
            id: self.id ?? UUID(),
            profileName: self.profileName ?? "Unnamed Profile",
            baseURL: self.baseURL ?? "",
            llmModelName: self.llmModelName ?? "",
            temperature: self.temperature,
            topK: Int(self.topK),
            topP: self.topP,
            repeatPenalty: self.repeatPenalty,
            contextWindowSize: Int(self.contextWindowSize),
            gpuLayers: Int(self.gpuLayers),
            maxInlineChars: Int(self.maxInlineChars),
            maxAttachedFiles: Int(self.maxAttachedFiles),
            textFileInclusionStrategy: TextFileInclusionStrategy(rawValue: self.textFileInclusionStrategy ?? "") ?? .preferInlining,
            imageHandlingStrategy: OllamaImageHandlingStrategy(rawValue: self.imageHandlingStrategy ?? "") ?? .doNotInclude,
            binaryFileHandlingStrategy: OllamaBinaryFileHandlingStrategy(rawValue: self.binaryFileHandlingStrategy ?? "") ?? .doNotInclude
        )
    }
}
