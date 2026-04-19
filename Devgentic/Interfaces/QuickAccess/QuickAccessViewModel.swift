// ViewModels/QuickAccessViewModel.swift
import SwiftUI
import Combine
import SwiftData
import os
// import Markdown // REMOVED: This was removed to fix a build conflict. See AgentResponseParser.swift for details.

@Observable @MainActor
class QuickAccessViewModel {

    // MARK: - Observable State
    var messages: [ChatMessage] = []
    var isSending: Bool = false

    @ObservationIgnored private let persistenceService = ChatPersistenceStore.shared
    @ObservationIgnored private let aiConnect = OllamaConnect()
    @ObservationIgnored private let logger = DGLogger(category: "QuickAccessViewModel")

    // MARK: - Properties
    @ObservationIgnored private var targetConversationId: UUID?

    // MARK: - Initialization
    init() {
        logger.info("QuickAccessViewModel initializing with SwiftData integration.")
        setupQuickAccessConversation()

        // We'll use NotificationCenter to reload data when significant changes happen elsewhere.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDataDidChange),
            name: ModelContext.didSave,
            object: nil
        )
    }

    // MARK: - Private Setup and Observation
    
    /// Fetches or creates the dedicated Quick Access conversation from SwiftData.
    private func setupQuickAccessConversation() {
        let conversationSD = getOrCreateQuickAccessConversation()
        self.targetConversationId = conversationSD.id
        self.messages = conversationSD.toStruct().messages.sorted { $0.timestamp < $1.timestamp }
        logger.info("Quick Access ViewModel setup with conversation ID: \(self.targetConversationId?.uuidString ?? "nil")")
    }

    /// Reloads the conversation data from SwiftData when a change is detected.
    @objc private func handleDataDidChange(notification: Notification) {
        guard let currentId = targetConversationId else { return }

        // Reload conversation data on any SwiftData save
        logger.trace("Data change detected — reloading conversation \(currentId.uuidString).")
        if let conversationSD = persistenceService.getConversation(withId: currentId) {
            let newMessages = conversationSD.toStruct().messages.sorted { $0.timestamp < $1.timestamp }
            if self.messages != newMessages {
                self.messages = newMessages
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
        
        guard let conversationSD = persistenceService.getConversation(withId: originalConversationId) else {
            logger.error("Cannot send message, conversation \(originalConversationId.uuidString) not found.")
            return
        }

        isSending = true

        Task {
            var resultingAgentMessages: [ChatMessage] = []
            let modelName = UserDefaults.standard.string(forKey: GlobalConstants.llmModelName) ?? "gemma:2b"
            let baseURLString = "self.aiConnect.baseURL"

            do {
                let isConnected = await OllamaConnect.checkOllamaServerStatus(baseURL: baseURLString)
                guard isConnected else {
                    throw URLError(.cannotConnectToHost)
                }

                let payload: [String: Any] = [ "model": modelName, "prompt": query, "stream": false ]
//                let responseData = try await self.aiConnect.postToLocalServer(endpoint: "/api/generate", payload: payload)
//                let responseText = try self.agentParser.parse(data: responseData)
                let parsedContents = "self.agentParser.parseTextToMessageContent()"

//                for content in parsedContents {
//                    resultingAgentMessages.append(ChatMessage(conversationId: originalConversationId, sender: .agent, content: content))
//                }
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

        if !currentQAConversation.messages.isEmpty {
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

    // MARK: - Private SwiftData Helpers

    /// Gets the dedicated Quick Access conversation from SwiftData, creating it if it doesn't exist.
    private func getOrCreateQuickAccessConversation() -> ConversationSD {
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
        NotificationCenter.default.removeObserver(self)
    }
}
