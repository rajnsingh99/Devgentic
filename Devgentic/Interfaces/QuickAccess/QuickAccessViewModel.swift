// ViewModels/QuickAccessViewModel.swift
import SwiftUI
import Combine
import CoreData
import os
// import Markdown // REMOVED: This was removed to fix a build conflict. See AgentResponseParser.swift for details.

@MainActor
class QuickAccessViewModel: ObservableObject {

    // MARK: - Published Properties
    @Published var messages: [ChatMessage] = []
    @Published var isSending: Bool = false
    
    private let persistenceService = CoreDataPersistenceService.shared
    private let aiConnect = OllamaConnect()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "QuickAccessViewModel")
    
    // MARK: - Properties
    private var targetConversationId: UUID? // The ID of the current Quick Access conversation.
    private var cancellables = Set<AnyCancellable>()
    private let agentParser = AgentResponseParser()

    // MARK: - Initialization
    init() {
        logger.info("QuickAccessViewModel initializing with Core Data integration.")
        setupQuickAccessConversation()
        
        // We'll use NotificationCenter to reload data when significant changes happen elsewhere.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDataDidChange),
            name: .NSManagedObjectContextObjectsDidChange,
            object: persistenceService.viewContext
        )
    }

    // MARK: - Private Setup and Observation
    
    /// Fetches or creates the dedicated Quick Access conversation from Core Data.
    private func setupQuickAccessConversation() {
        let conversation = getOrCreateQuickAccessConversation()
        self.targetConversationId = conversation.id
        self.messages = conversation.toConversationStruct().messages.sorted { $0.timestamp < $1.timestamp }
        logger.info("Quick Access ViewModel setup with conversation ID: \(self.targetConversationId?.uuidString ?? "nil")")
    }

    /// Reloads the conversation data from Core Data when a change is detected.
    @objc private func handleDataDidChange(notification: Notification) {
        // Check if the change is relevant to our current conversation
        guard let updatedObjects = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>,
              let currentId = targetConversationId else { return }

        let isRelevantUpdate = updatedObjects.contains { obj in
            if let conv = obj as? ConversationEntity, conv.id == currentId { return true }
            if let msg = obj as? ChatMessageEntity, msg.conversation?.id == currentId { return true }
            return false
        }
        
        if isRelevantUpdate {
            logger.trace("Relevant data change detected for conversation \(currentId.uuidString). Reloading.")
            if let conversation = persistenceService.getConversation(withId: currentId) {
                let newMessages = conversation.toConversationStruct().messages.sorted { $0.timestamp < $1.timestamp }
                if self.messages != newMessages {
                    self.messages = newMessages
                }
            }
        }
    }

    // MARK: - Core Logic

    func submitQuery(query: String) {
        guard let originalConversationId = self.targetConversationId else {
             logger.error("submitQuery failed: targetConversationId is nil.")
             return
        }
        
        logger.debug("Quick Access submitQuery for conversation ID: \(originalConversationId.uuidString)")
        guard !isSending, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let userMessage = ChatMessage(conversationId: originalConversationId, sender: .user, content: .plainText(query.trimmingCharacters(in: .whitespacesAndNewlines)))
        
        guard let conversationEntity = persistenceService.getConversation(withId: originalConversationId) else {
            logger.error("Cannot send message, conversation entity \(originalConversationId.uuidString) not found.")
            return
        }

        isSending = true

        Task {
            var resultingAgentMessages: [ChatMessage] = []
            let modelName = UserDefaults.standard.string(forKey: GlobalConstants.llmModelName) ?? "gemma:2b"
            let baseURLString = self.aiConnect.baseURL

            do {
                let isConnected = await OllamaConnect.checkOllamaServerStatus(baseURL: baseURLString)
                guard isConnected else {
                    throw URLError(.cannotConnectToHost)
                }

                let payload: [String: Any] = [ "model": modelName, "prompt": query, "stream": false ]
                let responseData = try await self.aiConnect.postToLocalServer(endpoint: "/api/generate", payload: payload)
                let responseText = try self.agentParser.parse(data: responseData)
                let parsedContents = self.agentParser.parseTextToMessageContent(responseText)

                for content in parsedContents {
                    resultingAgentMessages.append(ChatMessage(conversationId: originalConversationId, sender: .agent, content: content))
                }
            } catch {
                let errorText = self.generateSimplifiedErrorMessage(error: error)
                let errorMessageContent = MessageContent.error(title: "Processing Error", details: errorText)
                resultingAgentMessages.append(ChatMessage(conversationId: originalConversationId, sender: .agent, content: errorMessageContent))
            }
            
            self.isSending = false
        }
    }

    /// Starts a new Quick Access conversation session.
    func startNewChatSession() {
        logger.info("Starting new Quick Access chat session request.")
        
        let currentQAConversation = getOrCreateQuickAccessConversation()
        
        if !(currentQAConversation.messages?.allObjects.isEmpty ?? true) {
            let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Quick Access Chat")
            persistenceService.addConversation(from: newConversation)
            UserDefaults.standard.set(newConversation.id.uuidString, forKey: GlobalConstants.quickAccessOverlayConversationId)
            self.targetConversationId = newConversation.id
            self.messages = []
        } else {
            self.targetConversationId = currentQAConversation.id
            self.messages = []
        }
        
        self.isSending = false
        logger.info("Quick Access ViewModel reset for session ID: \(self.targetConversationId?.uuidString ?? "nil")")
    }

    // MARK: - Private Core Data Helpers

    /// Gets the dedicated Quick Access conversation entity from Core Data, creating it if it doesn't exist.
    private func getOrCreateQuickAccessConversation() -> ConversationEntity {
        let defaults = UserDefaults.standard
        let quickAccessKey = GlobalConstants.quickAccessOverlayConversationId

        if let qaIdString = defaults.string(forKey: quickAccessKey),
           let qaId = UUID(uuidString: qaIdString),
           let foundConversation = persistenceService.getConversation(withId: qaId) {
            logger.info("Found existing Quick Access conversation in store with ID: \(qaId.uuidString)")
            return foundConversation
        }

        logger.info("No valid Quick Access conversation found. Creating a new one.")
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Quick Access Chat")
        
        persistenceService.addConversation(from: newConversation)
        
        defaults.set(newConversation.id.uuidString, forKey: quickAccessKey)
        
        return persistenceService.getConversation(withId: newConversation.id)!
    }
    
    // MARK: - Parsing Helpers (REMOVED)
    // The local parsing helpers were removed from this ViewModel.
    // This logic is now fully encapsulated within the `AgentResponseParser` struct.
    private func generateSimplifiedErrorMessage(error: Error) -> String {
        // This helper can remain if it's generic enough.
        return ""
    }
    
    deinit {
        logger.info("QuickAccessViewModel deinitialized.")
        cancellables.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
    }
}
