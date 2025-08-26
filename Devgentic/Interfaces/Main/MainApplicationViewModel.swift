//
//  MainApplicationViewModel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import Combine
import os
import AppKit
import AVFoundation


private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MainApplicationViewModel")

@MainActor
class MainApplicationViewModel: ObservableObject {

    // MARK: - Dependencies
    
    let backendConfiguration = BackendConfiguration()
    let explorerViewModel = ExplorerViewModel()
    let insertPromptText = PassthroughSubject<String, Never>()
    
    // Dependencies are now injected and stored.
    private let activeStreamManager: ActiveStreamManager
    private let persistenceService: CoreDataServiceProtocol
    private let fileProcessorService: FileProcessorService
    private let chatHistoryViewModel: ChatHistoryViewModel

    private var cancellables = Set<AnyCancellable>()
    private var conversationLoader: AnyCancellable?
    private var conversationLoadTask: Task<Void, Never>?
    
    private let webSearchAPIKeyDefaultsKey = "webSearchAPIKey"

    // MARK: - Service & Store Observables
    @ObservedObject var ollamaService = OllamaService.shared
    @ObservedObject var llmIntegrationStore: LLMIntegrationStore
    
    // MARK: - Published State Properties
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?
    @Published var isSidebarCollapsed: Bool = true
    @Published var showSettings: Bool = false
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil
    @Published var attachedFiles: [FileSystemItem] = []
    @Published var useStreamingResponse: Bool = true
    @Published var isWebSearchEnabled: Bool = false
    @Published var webSearchAPIKey: String?
    @Published var isWebSearchActive: Bool = false
    
    @Published var streamingMessageID: UUID? = nil
    
    private let groupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yy"
        return formatter
    }()

    // MARK: - Computed Properties
    var currentConversationTitle: String {
        guard let selectedID = selectedConversationID,
              let conversationEntity = persistenceService.getConversation(withId: selectedID) else {
            return "Devgentic"
        }
        return conversationEntity.toConversationStruct().displayTitle
    }
    
    // MARK: - Initialization
    init(
        persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared,
        llmIntegrationStore: LLMIntegrationStore,
        fileProcessorService: FileProcessorService = FileProcessorService(),
        activeStreamManager: ActiveStreamManager,
        chatHistoryViewModel: ChatHistoryViewModel
    ) {
        self.persistenceService = persistenceService
        self.llmIntegrationStore = llmIntegrationStore
        self.fileProcessorService = fileProcessorService
        self.activeStreamManager = activeStreamManager
        self.chatHistoryViewModel = chatHistoryViewModel

        logger.info("MainApplicationViewModel initialized.")
        
        loadSettings()
        setupBindings()
        setupConversationLoader()
        
        self.webSearchAPIKey = UserDefaults.standard.string(forKey: webSearchAPIKeyDefaultsKey)
        self.isWebSearchEnabled = (self.webSearchAPIKey != nil && !self.webSearchAPIKey!.isEmpty)
        self.isWebSearchActive = false
        
        if isWebSearchEnabled {
            logger.info("Web search is enabled (API key found in UserDefaults).")
        } else {
            logger.info("Web search is disabled (API key not found in UserDefaults).")
        }
    }

    deinit {
        logger.info("MainApplicationViewModel deinitialized.")
        cancellables.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
        conversationLoadTask?.cancel()
    }
    
    // MARK: - Settings Management
    private func loadSettings() {
        if UserDefaults.standard.object(forKey: AppSettings.useStreamingResponseKey) == nil {
            UserDefaults.standard.set(true, forKey: AppSettings.useStreamingResponseKey)
        }
        self.useStreamingResponse = UserDefaults.standard.bool(forKey: AppSettings.useStreamingResponseKey)
        logger.info("Loaded 'useStreamingResponse' setting from UserDefaults: \(self.useStreamingResponse)")
    }

    // MARK: - Bindings Setup
    private func setupBindings() {
        
        $useStreamingResponse
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { newValue in
                UserDefaults.standard.set(newValue, forKey: AppSettings.useStreamingResponseKey)
                logger.info("Saved 'useStreamingResponse' setting to UserDefaults: \(newValue)")
            }
            .store(in: &cancellables)
            
        backendConfiguration.$selectedBackend
            .combineLatest(backendConfiguration.$selectedAgentID, backendConfiguration.$selectedIntegrationID)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] backendType, agentID, integrationID in
                guard let self = self, let conversationID = self.selectedConversationID else { return }
                
                logger.info("Backend configuration changed. Updating current conversation \(conversationID.uuidString).")
                self.updateBackendForCurrentConversation(
                    conversationID: conversationID,
                    backendType: backendType,
                    agentID: agentID,
                    integrationID: integrationID
                )
            }
            .store(in: &cancellables)

        backendConfiguration.$selectedIntegrationID
            .removeDuplicates()
            .sink { [weak self] newIntegrationID in
                if self?.llmIntegrationStore.selectedIntegrationID != newIntegrationID {
                    logger.debug("Syncing BackendConfig -> LLMStore. New Integration ID: \(newIntegrationID?.uuidString ?? "nil")")
                    self?.llmIntegrationStore.selectedIntegrationID = newIntegrationID
                }
            }
            .store(in: &cancellables)
            
        llmIntegrationStore.$selectedIntegrationID
            .removeDuplicates()
            .sink { [weak self] newIntegrationID in
                guard let self = self else { return }
                if self.backendConfiguration.selectedIntegrationID != newIntegrationID {
                    logger.debug("Syncing LLMStore -> BackendConfig. New Integration ID: \(newIntegrationID?.uuidString ?? "nil")")
                    self.backendConfiguration.selectedIntegrationID = newIntegrationID
                    
                    if let newId = newIntegrationID, let integration = self.llmIntegrationStore.integrations.first(where: { $0.id == newId }) {
                        let newBackendType: BackendType = integration.providerType == .ollama ? .ollama : .remote
                        if self.backendConfiguration.selectedBackend != newBackendType {
                            self.backendConfiguration.selectedBackend = newBackendType
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func setupConversationLoader() {
        conversationLoader = $selectedConversationID
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] conversationID in
                guard let self = self else { return }
                
                self.isWebSearchActive = false
                logger.debug("Conversation changed. Resetting web search active state to OFF.")
                
                self.conversationLoadTask?.cancel()
                
                self.conversationLoadTask = Task {
                    await self.chatHistoryViewModel.loadConversation(id: conversationID)
                    if let id = conversationID {
                        self.loadBackendStateForSelectedConversation(conversationID: id)
                    }
                }
            }
    }

    // MARK: - Message Sending Logic
    
    func sendMessage(attributedString: NSAttributedString, withConfig config: BackendRequestConfig) {
            if showSettings { showSettings = false }
            
            let plainUserQueryFromEditor = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard !chatHistoryViewModel.isSending else {
                logger.warning("[sendMessage] Message sending already in progress. Ignoring new request.")
                return
            }
            guard !plainUserQueryFromEditor.isEmpty || !attachedFiles.isEmpty else {
                return
            }

            chatHistoryViewModel.isSending = true
            logger.info("Beginning message send process with backend: \(config.backendType.rawValue)")
            
            let conversationIDToUse = selectedConversationID ?? createAndSelectNewConversation()
            
            guard let targetConversationEntity = persistenceService.getConversation(withId: conversationIDToUse) else {
                logger.error("[sendMessage] CRITICAL: Could not find or create conversation entity for ID: \(conversationIDToUse.uuidString)")
                chatHistoryViewModel.isSending = false
                return
            }

            let filesForBackend = self.attachedFiles
            
            let userMessage = createUserMessage(
                conversationID: conversationIDToUse,
                query: plainUserQueryFromEditor,
                files: filesForBackend
            )
            
            // **FIX**: Append new user message to the end of the array.
            chatHistoryViewModel.currentChatMessages.append(userMessage)
            logger.debug("Appended user message into UI.")
            
            Task {
                await persistenceService.addMessage(userMessage, to: targetConversationEntity)
                logger.debug("User message persisted successfully.")
            }

            self.clearAttachedFiles()
            logger.debug("Cleared user input and attachments from UI.")

            let agentMessage = activeStreamManager.startMessageStream(
                withConfig: config,
                conversationID: conversationIDToUse,
                userQuery: plainUserQueryFromEditor,
                history: chatHistoryViewModel.currentChatMessages.reversed(),
                files: filesForBackend,
                updating: nil, // This is a new message, not a regeneration
                onComplete: { [weak self] in
                    // This block is called when the stream finishes or is cancelled.
                    DispatchQueue.main.async {
                        self?.streamingMessageID = nil
                        logger.info("Stream completed. Resetting streamingMessageID.")
                    }
                }
            )

            self.streamingMessageID = agentMessage.id

            // **FIX**: Append new agent message to the end of the array.
            chatHistoryViewModel.currentChatMessages.append(agentMessage)
            logger.debug("Appended agent's streaming message placeholder into UI for real-time updates.")

            Task {
                await chatHistoryViewModel.resetSendingState()
            }
    }
    
    // MARK: - Response Regeneration
    
    @MainActor
    func regenerateResponse(for agentMessage: ChatMessage) {
        // 1. Guard against max attempts (e.g., 5).
        guard let agentResponse = agentMessage.agentResponse, agentResponse.generationAttempts < 5 else {
            logger.warning("Max generation attempts reached for message \(agentMessage.id.uuidString).")
            // Optionally show an alert to the user.
            return
        }

        // 2. Reconstruct the chat history up to the message preceding the agent's response.
        guard let agentMessageIndex = chatHistoryViewModel.currentChatMessages.firstIndex(of: agentMessage) else {
            logger.error("Could not find agent message in chat history to regenerate.")
            return
        }
        
        // History for the backend should be in chronological order (oldest first).
        // Our view model's array is newest first, so we take everything after the agent message and reverse it.
        let historyForRegeneration = Array(chatHistoryViewModel.currentChatMessages.dropFirst(agentMessageIndex + 1).reversed())
        
        // The user query is the message immediately preceding the agent's response.
        guard let userQueryMessage = chatHistoryViewModel.currentChatMessages[safe: agentMessageIndex + 1],
              userQueryMessage.sender == .user else {
            logger.error("Could not find the preceding user query for regeneration.")
            return
        }
        let userQuery = userQueryMessage.content.textContent ?? ""
        
        // **FIXED: Correctly initialize FileSystemItem with all required parameters.**
        let filesForBackend = (userQueryMessage.attachedTextFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? []) +
                              (userQueryMessage.attachedImageFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? [])

        // 3. Get the currently selected backend configuration from the UI.
        let config = backendConfiguration.getRequestConfig()
        let entityId = config.backendType == .agent ? config.agentID : config.integrationID

        // 4. Create a new, empty variant and add it to the message.
        // This will instantly update the UI to show a "Thinking..." state.
        let newVariant = ResponseMessageVariant(
            content: .markdownText(""),
            backendEntityId: entityId
        )
        agentMessage.agentResponse?.variants.append(newVariant)
        agentMessage.agentResponse?.selectedVariantIndex = (agentMessage.agentResponse?.variants.count ?? 1) - 1
        agentMessage.agentResponse?.generationAttempts += 1
        agentMessage.isStreaming = true

        // 5. Call the updated ActiveStreamManager to begin the stream,
        // targeting the existing message for content updates.
        let streamingMessage = activeStreamManager.startMessageStream(
            withConfig: config,
            conversationID: agentMessage.conversationId,
            userQuery: userQuery,
            history: historyForRegeneration,
            files: filesForBackend,
            updating: agentMessage, // Pass the message to update
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    self?.streamingMessageID = nil
                    logger.info("Regeneration stream completed for message \(agentMessage.id.uuidString).")
                }
            }
        )
        
        // Track the streaming message ID to manage the UI state (e.g., show cancel button)
        self.streamingMessageID = streamingMessage.id
    }
    
    /// Cancels the currently active streaming response.
    func cancelStreamingResponse() {
        guard let messageID = streamingMessageID else {
            logger.warning("cancelStreamingResponse called but no streamingMessageID is set.")
            return
        }
        
        logger.info("User requested to cancel streaming for message: \(messageID.uuidString)")
        activeStreamManager.cancelStream(for: messageID)
        // The onComplete handler in `sendMessage` or `regenerateResponse` will set streamingMessageID to nil.
    }
    
    private func createUserMessage(conversationID: UUID, query: String, files: [FileSystemItem]) -> ChatMessage {
        var attachedTextFiles: [AttachedTextFile] = []
        var attachedImageFiles: [AttachedImageFile] = []

        for fileItem in files {
            let mimeType = fileProcessorService.getFileMimeType(for: fileItem.url)
            let fileExtension = fileItem.url.pathExtension
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileItem.url.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

            if fileProcessorService.isTextFile(mimeType: mimeType, url: fileItem.url) {
                if let content = fileProcessorService.readFileContent(for: fileItem.url) {
                    let textFile = AttachedTextFile(name: fileItem.name, url: fileItem.url, fileExtension: fileExtension, content: content, size: fileSize)
                    attachedTextFiles.append(textFile)
                }
            } else if fileProcessorService.isImageFile(mimeType: mimeType, url: fileItem.url) {
                do {
                    _ = fileItem.url.startAccessingSecurityScopedResource()
                    let data = try Data(contentsOf: fileItem.url)
                    fileItem.url.stopAccessingSecurityScopedResource()
                    let imageFile = AttachedImageFile(name: fileItem.name, url: fileItem.url, fileExtension: fileExtension, binaryData: data, size: fileSize)
                    attachedImageFiles.append(imageFile)
                } catch {
                    logger.error("Could not read image data for file: \(fileItem.name)")
                }
            }
        }

        return ChatMessage(
            conversationId: conversationID,
            sender: .user,
            content: .plainText(query),
            attachedTextFiles: attachedTextFiles.isEmpty ? nil : attachedTextFiles,
            attachedImageFiles: attachedImageFiles.isEmpty ? nil : attachedImageFiles
        )
    }
    
    // MARK: - Chat History Management

    func toggleUserMessagesFilter() {
        chatHistoryViewModel.toggleUserMessagesFilter()
    }
    
    func startNewConversation() {
        if showSettings { showSettings = false }
        clearAttachedFiles()
        let newConversationID = createAndSelectNewConversation()
        let config = backendConfiguration.getRequestConfig()
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
        logger.info("Started new conversation with ID \(newConversationID.uuidString). Backend state initialized to \(config.backendType.rawValue).")
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        if showSettings { showSettings = false }
        
        let config = backendConfiguration.getRequestConfig()
        var entityId: UUID?
        switch config.backendType {
        case .agent:
            entityId = config.agentID
        case .ollama, .remote:
            entityId = config.integrationID
        case .none:
            entityId = nil
        }

        let newConversation = Conversation(
            id: UUID(),
            messages: [],
            timestamp: Date(),
            backendType: config.backendType,
            backendEntityId: entityId
        )
        persistenceService.addConversation(from: newConversation)
        chatHistoryViewModel.currentChatMessages = []
        selectedConversationID = newConversation.id
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
        return newConversation.id
    }
    
    private func loadBackendStateForSelectedConversation(conversationID: UUID) {
        guard let conversationEntity = persistenceService.getConversation(withId: conversationID) else {
            logger.warning("Could not find conversation entity \(conversationID.uuidString) to load backend state. Resetting to .none.")
            self.backendConfiguration.selectedBackend = .none
            self.backendConfiguration.selectedAgentID = nil
            self.backendConfiguration.selectedIntegrationID = nil
            return
        }

        let conversation = conversationEntity.toConversationStruct()
        let backendType = conversation.backendType ?? .none
        let backendEntityId = conversation.backendEntityId

        self.backendConfiguration.selectedBackend = backendType
        
        switch backendType {
        case .agent:
            self.backendConfiguration.selectedAgentID = backendEntityId
            self.backendConfiguration.selectedIntegrationID = nil
        case .ollama, .remote:
            self.backendConfiguration.selectedIntegrationID = backendEntityId
            self.backendConfiguration.selectedAgentID = nil
        case .none:
            self.backendConfiguration.selectedAgentID = nil
            self.backendConfiguration.selectedIntegrationID = nil
        }
        logger.info("Loaded backend state for conversation \(conversationID, privacy: .public): \(backendType.rawValue)")
    }

    private func updateBackendForCurrentConversation(conversationID: UUID, backendType: BackendType, agentID: UUID?, integrationID: UUID?) {
        var entityId: UUID?
        switch backendType {
        case .agent:
            entityId = agentID
        case .ollama, .remote:
            entityId = integrationID
        case .none:
            entityId = nil
        }
        
        persistenceService.updateBackendForConversation(
            id: conversationID,
            backendType: backendType,
            backendEntityId: entityId
        )
        logger.debug("Persisted backend type \(backendType.rawValue) and entity ID \(entityId?.uuidString ?? "nil") for conversation \(conversationID.uuidString).")
    }
    
    func transferSelectedConversationToOverlay() {
        guard let conversationID = selectedConversationID else { return }
        UserDefaults.standard.set(conversationID.uuidString, forKey: "quickAccessOverlayConversationId")
        NotificationCenter.default.post(name: NSNotification.Name("showQuickAccessPanel"), object: nil, userInfo: ["forceExpand": true])
        self.selectedConversationID = nil
    }
    
    func togglePinStatus(for conversationId: UUID) {
        logger.debug("Toggling pin status for conversation: \(conversationId.uuidString)")
        persistenceService.togglePinStatus(for: conversationId)
    }
    
    func deleteConversation(conversationID: UUID) {
        persistenceService.deleteConversation(with: conversationID)
        if selectedConversationID == conversationID {
            selectedConversationID = nil
        }
    }
    
    func deleteMultipleConversations(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids { persistenceService.deleteConversation(with: id) }
        if let currentSelected = selectedConversationID, ids.contains(currentSelected) { selectedConversationID = nil }
    }
    
    func renameConversation(conversationID: UUID, newTitle: String) {
        guard let conversationToRename = persistenceService.getConversation(withId: conversationID) else { return }
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        conversationToRename.userDefinedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        persistenceService.saveContext()
    }

    func toggleSidebar() { withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() } }
    func toggleSettings() { withAnimation { showSettings.toggle() } }
    func toggleContextArea() { withAnimation { showContextArea.toggle() } }
    
    func groupKey(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return self.groupDateFormatter.string(from: date)
    }
    
    @MainActor
    func addAttachedFile(fileItem: FileSystemItem) {
        if !attachedFiles.contains(where: { $0.id == fileItem.id }) {
            attachedFiles.append(fileItem)
        }
    }

    @MainActor
    func addAttachedFiles(fileItems: [FileSystemItem]) {
        for fileItem in fileItems {
            if !attachedFiles.contains(where: { $0.id == fileItem.id }) {
                attachedFiles.append(fileItem)
            }
        }
    }

    @MainActor
    func removeAttachedFile(fileItem: FileSystemItem) {
        attachedFiles.removeAll { $0.id == fileItem.id }
    }
    
    @MainActor
    func removeAttachedFile(byId fileId: URL) {
        attachedFiles.removeAll { $0.id == fileId }
    }

    @MainActor
    func clearAttachedFiles() {
        if !attachedFiles.isEmpty {
            attachedFiles.removeAll()
        }
    }
    
    // MARK: - Web Search Configuration (Using UserDefaults)
    
    func toggleWebSearch() {
        guard isWebSearchEnabled else { return }
        isWebSearchActive.toggle()
        logger.info("Web search active state toggled to: \(self.isWebSearchActive)")
    }
    
    func saveAndEnableWebSearch(apiKey: String) {
        UserDefaults.standard.set(apiKey, forKey: webSearchAPIKeyDefaultsKey)
        self.webSearchAPIKey = apiKey
        self.isWebSearchEnabled = true
        self.isWebSearchActive = true
        logger.info("Successfully saved web search API key to UserDefaults and enabled search.")
    }

    func disableAndRemoveWebSearch() {
        UserDefaults.standard.removeObject(forKey: webSearchAPIKeyDefaultsKey)
        self.webSearchAPIKey = nil
        self.isWebSearchEnabled = false
        self.isWebSearchActive = false
        logger.info("Successfully removed web search API key from UserDefaults and disabled search.")
    }
}

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript (safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
