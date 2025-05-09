// ViewModels/MainApplicationViewModel.swift
import SwiftUI
import Combine
import os
import AppKit // For NSApplication

// Logger for the ViewModel
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MainApplicationViewModel")

// Assuming SettingsSection, BackendType, SettingsKeys, Conversation,
// ChatMessage, MessageContent, ConversationStore, AppDelegate are defined elsewhere.
// OllamaServerStatus is now in its own file.

@MainActor // Ensure UI updates happen on the main thread
class MainApplicationViewModel: ObservableObject {

    // MARK: - Dependencies
    private let store = ConversationStore.shared
    private let aiConnect = AIConnect()
    private let responseHandler = AgentResponseHandler()
    
    @ObservedObject var ollamaService: OllamaService

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Published State Properties (UI and Core Chat Logic)
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?
    @Published var isSending: Bool = false
    @Published var userInput: String = ""
    @Published var isSidebarCollapsed: Bool = true // This refers to the VSCodifiedSidebar's content pane
    @Published var showSettings: Bool = false
    
    // MARK: - New State for Prompt Library Panel
    @Published var showPromptLibrary: Bool = false

    @Published var selectedSettingsSection: SettingsSection = .general {
        didSet {
            if selectedSettingsSection == .localAI && selectedBackend == .ollama {
                Task { await ollamaService.checkServerStatusAndUpdateModels() }
            } else if selectedSettingsSection != .localAI {
                ollamaService.clearAllModelActionStatuses()
            }
        }
    }
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil
    @Published var isUserMessagesOnlyFilterActive: Bool = false

    // --- Settings Properties (loaded/saved via @AppStorage) ---
    @AppStorage(SettingsKeys.selectedBackend) var selectedBackend: BackendType = .ollama
    @AppStorage(SettingsKeys.windowOpacity) var windowOpacity: Double = 1.0
    @AppStorage(SettingsKeys.agentBaseURL) var agentBaseURL: String = "http://127.0.0.1:8000"
    @AppStorage(SettingsKeys.agentDelegationStrategy) var agentDelegationStrategy: String = "send_to_first_available"
    
    @AppStorage(SettingsKeys.ollamaTemperature) var ollamaTemperature: Double = 0.8
    @AppStorage(SettingsKeys.ollamaTopK) var ollamaTopK: Int = 40
    @AppStorage(SettingsKeys.ollamaTopP) var ollamaTopP: Double = 0.9
    @AppStorage(SettingsKeys.ollamaRepeatPenalty) var ollamaRepeatPenalty: Double = 1.1
    @AppStorage(SettingsKeys.ollamaContextWindowSize) var ollamaContextWindowSize: Int = 4096
    @AppStorage(SettingsKeys.ollamaGpuLayers) var ollamaGpuLayers: Int = -1


    // Group Date Formatter
    private let groupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy" // Corrected format
        return formatter
    }()

    // MARK: - Computed Properties
    var currentChatMessages: [ChatMessage] {
        guard let selectedID = selectedConversationID,
              let conversation = self.conversations.first(where: { $0.id == selectedID }) else {
            return []
        }
        let messagesToDisplay = conversation.messages.sorted { $0.timestamp < $1.timestamp }
        if isUserMessagesOnlyFilterActive {
            return messagesToDisplay.filter { $0.sender == .user }
        } else {
            return messagesToDisplay
        }
    }

    var currentConversationTitle: String {
        guard let conversation = self.conversations.first(where: { $0.id == selectedConversationID }) else {
            return self.conversations.isEmpty ? "Devgentic" : "Select Chat"
        }
        return conversation.displayTitle
    }

    var groupedConversations: [String: [Conversation]] {
        let grouped = self.conversations.reduce(into: [String: [Conversation]]()) { result, conversation in
            let groupKey = self.groupKey(for: conversation.timestamp)
            result[groupKey, default: []].append(conversation)
        }
        return grouped.mapValues { $0.sorted { $0.timestamp > $1.timestamp } }
    }

    var sortedGroupKeys: [String] {
        let dateFormatter = self.groupDateFormatter
        return groupedConversations.keys.sorted { key1, key2 in
            if key1 == "Today" { return true }
            if key2 == "Today" { return false }
            if key1 == "Yesterday" { return true }
            if key2 == "Yesterday" { return false }
            if let date1 = dateFormatter.date(from: key1), let date2 = dateFormatter.date(from: key2) {
                return date1 > date2
            }
            return key1 > key2
        }
    }

    // MARK: - Initialization
    init(ollamaService: OllamaService) {
        self.ollamaService = ollamaService
        self.conversations = store.getAllConversations()
        validateSelectedConversation()
        observeConversationStoreChanges()

        logger.info("MainApplicationViewModel initialized with injected OllamaService. Synced with ConversationStore. Loaded \(self.conversations.count) conversations.")
        
        if selectedBackend == .ollama {
            Task {
                await self.ollamaService.checkServerStatusAndUpdateModels()
            }
        }
    }

    convenience init() {
        self.init(ollamaService: OllamaService())
        logger.info("MainApplicationViewModel initialized with default OllamaService.")
    }

    deinit {
        logger.info("MainApplicationViewModel deinitialized.")
        cancellables.forEach { $0.cancel() }
    }

    private func observeConversationStoreChanges() {
        store.$conversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedConversationsFromStore in
                guard let self = self else { return }
                logger.info("ConversationStore reported changes. Updating MainApplicationViewModel's conversations.")
                self.conversations = updatedConversationsFromStore
                self.validateSelectedConversation()
            }
            .store(in: &cancellables)
    }
    
    private func validateSelectedConversation() {
        if let currentSelectedID = selectedConversationID {
            if !conversations.contains(where: { $0.id == currentSelectedID }) {
                logger.warning("Previously selected conversation \(currentSelectedID.uuidString) no longer exists. Selecting first available.")
                selectedConversationID = conversations.first?.id
            }
        } else {
            selectedConversationID = conversations.first?.id
        }
        if let id = selectedConversationID {
             logger.debug("Validated selection. Current selected ID: \(id.uuidString)")
        } else {
            logger.debug("Validated selection. No conversation selected (list might be empty).")
        }
    }
    
    // MARK: - Actions / Methods (UI Toggles, Chat Management)

    func toggleUserMessagesFilter() {
        isUserMessagesOnlyFilterActive.toggle()
        logger.info("User messages filter toggled. Active: \(self.isUserMessagesOnlyFilterActive)")
    }
    
    func startNewConversation() {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false } // Close prompt library if open
        userInput = ""
        
        let currentConversations = store.getAllConversations()
        if let mostRecentConv = currentConversations.first, mostRecentConv.messages.isEmpty {
            logger.info("Found existing empty conversation (\(mostRecentConv.id.uuidString)). Selecting it instead of creating a new one.")
            selectedConversationID = mostRecentConv.id
            isUserMessagesOnlyFilterActive = false
            return
        }

        logger.info("No suitable empty conversation found. Creating a new one.")
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        store.addConversation(newConversation)
        selectedConversationID = newConversation.id
        logger.info("Started new conversation with ID: \(newConversation.id.uuidString) via store.")
        isUserMessagesOnlyFilterActive = false
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false } // Close prompt library if open
        
        let currentConversations = store.getAllConversations()
        if let mostRecentConv = currentConversations.first, mostRecentConv.messages.isEmpty {
            logger.info("Found existing empty conversation (\(mostRecentConv.id.uuidString)) during createAndSelect. Selecting it.")
            selectedConversationID = mostRecentConv.id
            isUserMessagesOnlyFilterActive = false
            return mostRecentConv.id
        }

        logger.info("No suitable empty conversation found during createAndSelect. Creating a new one.")
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        store.addConversation(newConversation)
        selectedConversationID = newConversation.id
        logger.info("Created and selected new conversation with ID: \(newConversation.id.uuidString) via store.")
        isUserMessagesOnlyFilterActive = false
        return newConversation.id
    }

    // MARK: - Message Sending Logic
    func sendMessage() {
        // ... (existing sendMessage logic) ...
        // Ensure panels are closed if open when sending a message
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("sendMessage called. Backend: \(self.selectedBackend.rawValue), isSending: \(self.isSending), userInput: \"\(trimmedInput.prefix(50))...\"")

        guard !isSending else { logger.warning("sendMessage aborted: Already sending."); return }
        guard !trimmedInput.isEmpty else { logger.info("sendMessage aborted: Input empty."); userInput = ""; return }

        var conversationIDToUse: UUID
        if let currentID = selectedConversationID {
            conversationIDToUse = currentID
        } else {
            logger.info("No conversation selected. Creating a new one for this message.")
            conversationIDToUse = createAndSelectNewConversation()
        }

        guard var targetConversationForUserMessage = self.conversations.first(where: { $0.id == conversationIDToUse }) else {
            logger.error("CRITICAL: Could not find conversation object for ID: \(conversationIDToUse.uuidString) before sending user message.")
            isSending = false
            return
        }

        var contextPrefix = ""
        if showContextArea, let filePath = activeContextFilePath {
            contextPrefix = "Context File: \(filePath)\n\nUser Message:\n"
        }
        let messageToSendToBackend = contextPrefix + trimmedInput

        let userMessage = ChatMessage(
            conversationId: conversationIDToUse,
            sender: .user,
            content: .plainText(trimmedInput)
        )
        
        targetConversationForUserMessage.messages.append(userMessage)
        targetConversationForUserMessage.timestamp = Date()
        store.updateConversation(targetConversationForUserMessage)

        let messageLogForBackend = messageToSendToBackend
        userInput = ""
        isSending = true

        Task {
            var agentMessagesForThisTurn: [ChatMessage] = []
            
            if selectedBackend == .ollama {
                 if ollamaService.serverStatus != .connected && ollamaService.serverStatus != .checking {
                      logger.info("Ollama status is \(self.ollamaService.serverStatus.rawValue), re-checking before sending.")
                      await ollamaService.checkServerStatusAndUpdateModels()
                 }
                 if ollamaService.serverStatus != .connected {
                    let errorMsg = "Cannot send message: Ollama server is not connected. Status: \(self.ollamaService.serverStatus.rawValue)"
                    logger.error("\(errorMsg)")
                    let errorMessageContent = MessageContent.error(title: "Connection Error", details: errorMsg)
                    let errorChatMessage = ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: errorMessageContent)
                    agentMessagesForThisTurn.append(errorChatMessage)
                 }
            }

            if agentMessagesForThisTurn.isEmpty {
                let backendConfig = self.determineBackendConfiguration(message: messageLogForBackend)
                do {
                    logger.debug("Sending task '\(messageLogForBackend.prefix(200))' to \(backendConfig.url)\(backendConfig.endpoint) for conversation \(conversationIDToUse.uuidString)")
                    
                    let responseData = try await self.aiConnect.postToLocalServer(endpoint: backendConfig.endpoint, payload: backendConfig.payload)
                    
                    let responseText = try responseHandler.parseInitialResponse(data: responseData, for: self.selectedBackend)
                    let parsedContents = responseHandler.parseTextToMessageContent(responseText)

                    for content in parsedContents {
                        let agentMessage = ChatMessage(
                            conversationId: conversationIDToUse,
                            sender: .agent,
                            content: content
                        )
                        agentMessagesForThisTurn.append(agentMessage)
                    }

                } catch {
                    logger.error("Error during API call or parsing: \(error.localizedDescription)")
                    let errorText = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: self.selectedBackend)
                    let errorMessageContent = MessageContent.error(title: "Processing Error", details: errorText)
                    let errorChatMessage = ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: errorMessageContent)
                    agentMessagesForThisTurn.append(errorChatMessage)
                    
                     if selectedBackend == .ollama {
                         if let urlError = error as? URLError,
                            (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                             ollamaService.serverStatus = .disconnected
                         }
                     }
                }
            }

            if !agentMessagesForThisTurn.isEmpty {
                guard var targetConversationForAgentMessages = self.conversations.first(where: { $0.id == conversationIDToUse }) else {
                    logger.error("CRITICAL: Could not find conversation for ID: \(conversationIDToUse.uuidString) to add agent messages.")
                    self.isSending = false
                    return
                }
                
                for msg in agentMessagesForThisTurn {
                    targetConversationForAgentMessages.messages.append(msg)
                }
                targetConversationForAgentMessages.timestamp = Date()
                
                store.updateConversation(targetConversationForAgentMessages)
                logger.debug("Appended \(agentMessagesForThisTurn.count) agent message(s) to conversation \(conversationIDToUse.uuidString) via store.")
            } else {
                logger.warning("sendMessage Task finished but generated no agent messages to handle.")
            }
            
            self.isSending = false
        }
    }


    // MARK: - Conversation Management (Delete, Rename, Transfer)
    func transferSelectedConversationToOverlay() {
        guard let conversationID = selectedConversationID else {
            logger.warning("Transfer to overlay requested, but no conversation is selected.")
            return
        }
        logger.info("Attempting to transfer conversation \(conversationID.uuidString) to Quick Access overlay.")
        UserDefaults.standard.set(conversationID.uuidString, forKey: SettingsKeys.quickAccessOverlayConversationId)
        let userInfo = ["forceExpand": true]
        NotificationCenter.default.post(name: SettingsKeys.showQuickAccessPanelNotification, object: nil, userInfo: userInfo)
        self.selectedConversationID = nil
    }
    
    func deleteConversation(conversationID: UUID) {
        logger.info("Attempting to delete single conversation with ID: \(conversationID.uuidString) via store.")
        store.deleteConversation(withId: conversationID)
    }

    func deleteMultipleConversations(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        logger.info("Attempting to delete \(ids.count) conversations via store.")
        store.deleteConversations(withIds: ids)
    }
    
    func deleteConversationsInGroup(groupKey: String) {
        logger.info("Attempting to delete all conversations in group: \(groupKey) via store.")
        let idsToDelete = self.conversations.filter { self.groupKey(for: $0.timestamp) == groupKey }.map { $0.id }
        if idsToDelete.isEmpty {
            logger.warning("No conversations found for group key '\(groupKey)'. Nothing to delete.")
            return
        }
        store.deleteConversations(withIds: Set(idsToDelete))
    }
    
    func renameConversation(conversationID: UUID, newTitle: String) {
        logger.info("Attempting to rename conversation ID \(conversationID.uuidString) to '\(newTitle)' via store.")
        guard var conversationToRename = store.getConversation(withId: conversationID) else {
            logger.error("Failed to rename: Conversation ID \(conversationID.uuidString) not found in store.")
            return
        }
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        conversationToRename.userDefinedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        store.updateConversation(conversationToRename)
    }

    // MARK: - UI Toggles
    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSidebarCollapsed.toggle()
            // If opening sidebar, ensure panels are closed
            if !isSidebarCollapsed {
                if showSettings { showSettings = false }
                if showPromptLibrary { showPromptLibrary = false }
            }
        }
    }

    func toggleSettings() {
        withAnimation {
            let becomingVisible = !showSettings
            showSettings.toggle()
            if becomingVisible {
                if showPromptLibrary { showPromptLibrary = false } // Close other panel
                if !isSidebarCollapsed { isSidebarCollapsed = true } // Collapse sidebar pane
            }
        }
    }

    // MARK: - New Toggle for Prompt Library
    func togglePromptLibrary() {
        withAnimation {
            let becomingVisible = !showPromptLibrary
            showPromptLibrary.toggle()
            if becomingVisible {
                if showSettings { showSettings = false } // Close other panel
                if !isSidebarCollapsed { isSidebarCollapsed = true } // Collapse sidebar pane
            }
        }
        logger.info("Prompt Library panel toggled. Showing: \(self.showPromptLibrary)")
    }

    func toggleContextArea() {
         withAnimation { showContextArea.toggle() }
         if !showContextArea { activeContextFilePath = nil }
         logger.info("Context area toggled. Showing: \(self.showContextArea). Path: \(self.activeContextFilePath ?? "nil")")
    }

    // MARK: - Private Helper Methods

    private struct BackendConfiguration { let url: String; let endpoint: String; let payload: [String: Any] }
    private func determineBackendConfiguration(message: String) -> BackendConfiguration {
        switch self.selectedBackend {
        case .ollama:
            let advancedOptions: [String: Any] = [
                "temperature": self.ollamaTemperature, "top_k": self.ollamaTopK,
                "top_p": self.ollamaTopP, "repeat_penalty": self.ollamaRepeatPenalty,
                "num_ctx": self.ollamaContextWindowSize, "num_gpu": self.ollamaGpuLayers
            ]
            return BackendConfiguration(
                url: "http://127.0.0.1:11434",
                endpoint: "/api/generate",
                payload: [
                    "model": ollamaService.llmModelName,
                    "prompt": message,
                    "stream": false,
                    "options": advancedOptions
                ]
            )
        case .agent:
            return BackendConfiguration(
                url: self.agentBaseURL,
                endpoint: "/execute_task",
                payload: [
                    "main_task": message,
                    "strategy": self.agentDelegationStrategy
                ]
            )
        }
    }
    
    func groupKey(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return self.groupDateFormatter.string(from: date)
        }
    }
}
