// Services/CoreDataPersistenceService.swift
import Foundation
import CoreData
import os

// MARK: - Core Data Service Protocol
/// Defines the interface for the Core Data persistence layer.
/// This makes it easier to mock for testing purposes.
protocol CoreDataServiceProtocol {
    func getConversation(withId id: UUID) -> ConversationEntity?
    func saveContext()
    func addConversation(from conversation: Conversation)
    func deleteConversation(with id: UUID)
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
