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
    private let persistenceService: CoreDataServiceProtocol
    private let fileProcessorService: FileProcessorService
    private let backendOrchestrationService: BackendOrchestrationService
    private let chatHistoryViewModel: ChatHistoryViewModel

    // MARK: - Service & Store Observables
    @ObservedObject var ollamaService = OllamaService.shared
    @ObservedObject var llmIntegrationStore: LLMIntegrationStore
    @ObservedObject var agentStore: AgentStore
    
    let backendConfiguration = BackendConfiguration()
    let explorerViewModel = ExplorerViewModel()
    let insertPromptText = PassthroughSubject<String, Never>()
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Published State Properties
    @Published var conversations: [Conversation] = []
    
    @Published var selectedConversationID: UUID?
    private var conversationLoader: AnyCancellable?
    private var conversationLoadTask: Task<Void, Never>?

    @Published var isSidebarCollapsed: Bool = true
    @Published var showSettings: Bool = false
    // @Published var showPromptLibrary: Bool = false // REMOVED
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil
    @Published var attachedFiles: [FileSystemItem] = []
    
    @Published var useStreamingResponse: Bool = false {
        didSet {
            logger.info("useStreamingResponse toggled to: \(self.useStreamingResponse)")
        }
    }

    private let webSearchAPIKeyDefaultsKey = "webSearchAPIKey"

    @Published var isWebSearchEnabled: Bool = false
    @Published var webSearchAPIKey: String?
    @Published var isWebSearchActive: Bool = false
    
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
    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared,
         llmIntegrationStore: LLMIntegrationStore,
         agentStore: AgentStore = AgentStore(),
         fileProcessorService: FileProcessorService = FileProcessorService(),
         chatHistoryViewModel: ChatHistoryViewModel
    ) {
        self.persistenceService = persistenceService
        self.llmIntegrationStore = llmIntegrationStore
        self.agentStore = agentStore
        self.fileProcessorService = fileProcessorService
        self.chatHistoryViewModel = chatHistoryViewModel
        
        self.backendOrchestrationService = BackendOrchestrationService(
            agentStore: agentStore,
            llmIntegrationStore: llmIntegrationStore,
            fileProcessorService: fileProcessorService
        )

        logger.info("MainApplicationViewModel initialized.")
        
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
 
    convenience init() {
        let fpService = FileProcessorService()
        let llmStore = LLMIntegrationStore()
        let agStore = AgentStore()
        let chatHistoryVM = ChatHistoryViewModel()

        self.init(
            llmIntegrationStore: llmStore,
            agentStore: agStore,
            fileProcessorService: fpService,
            chatHistoryViewModel: chatHistoryVM
        )
    }

    deinit {
        logger.info("MainApplicationViewModel deinitialized.")
        cancellables.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
        conversationLoadTask?.cancel()
    }

    // MARK: - Bindings Setup
    private func setupBindings() {
        // This publisher updates the backend settings for the *currently active conversation*
        // whenever the user makes a change in the UI (e.g., via the ChatInputAreaView popup).
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

        // --- FIX: TWO-WAY SYNC FOR INTEGRATION SELECTION ---

        // 1. When the UI's backend configuration changes, update the global default in the store.
        //    This ensures that selecting a model in the chat input updates the "active" checkmark in the sidebar.
        backendConfiguration.$selectedIntegrationID
            .removeDuplicates()
            .sink { [weak self] newIntegrationID in
                if self?.llmIntegrationStore.selectedIntegrationID != newIntegrationID {
                    logger.debug("Syncing BackendConfig -> LLMStore. New Integration ID: \(newIntegrationID?.uuidString ?? "nil")")
                    self?.llmIntegrationStore.selectedIntegrationID = newIntegrationID
                }
            }
            .store(in: &cancellables)
            
        // 2. When the global default in the store changes (e.g., from the main Settings screen), update the UI's backend configuration.
        //    This ensures that changing the selection in the settings is reflected in the chat input area.
        llmIntegrationStore.$selectedIntegrationID
            .removeDuplicates()
            .sink { [weak self] newIntegrationID in
                guard let self = self else { return }
                if self.backendConfiguration.selectedIntegrationID != newIntegrationID {
                    logger.debug("Syncing LLMStore -> BackendConfig. New Integration ID: \(newIntegrationID?.uuidString ?? "nil")")
                    self.backendConfiguration.selectedIntegrationID = newIntegrationID
                    
                    // If an integration is selected, we must also update the backend *type* to match it.
                    // This ensures the correct UI (e.g., Ollama vs. Remote) is shown.
                    // If an agent was active, this will correctly switch the backend type away from .agent.
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
        // if showPromptLibrary { showPromptLibrary = false } // REMOVED
        
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

        // --- UPDATED: Create a local copy of files to send to the backend ---
        // This prevents a race condition where the UI is cleared before the backend task runs.
        let filesForBackend = self.attachedFiles
        
        let userMessage = createUserMessage(
            conversationID: conversationIDToUse,
            query: plainUserQueryFromEditor,
            files: filesForBackend // Use the local copy to create the message object
        )
        
        Task {
            await persistenceService.addMessage(userMessage, to: targetConversationEntity)
            logger.debug("User message persisted successfully.")
        }
        chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)
        logger.debug("User message inserted into UI.")
        
        // --- UPDATED: Clear the UI attachments immediately after making the local copy ---
        self.clearAttachedFiles()
        logger.debug("Cleared user input and attachments from UI.")

        if useStreamingResponse {
            let agentMessage = ChatMessage(
                conversationId: conversationIDToUse,
                sender: .agent,
                content: .markdownText(""),
                isStreaming: true
            )
            logger.info("Created initial empty agent message with ID \(agentMessage.id.uuidString) to begin streaming.")

            chatHistoryViewModel.streamingMessage = agentMessage
            logger.debug("Set active streaming message.")

            chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
            logger.debug("Inserted streaming agent message into UI.")

            chatHistoryViewModel.streamingTriggerID = agentMessage.id
            logger.info("Set streaming trigger ID to placeholder message ID \(agentMessage.id.uuidString).")

            let streamingTask = Task {
                do {
                    let historyForBackend = chatHistoryViewModel.currentChatMessages.filter { message in
                        if case .error = message.content { return false }
                        return true
                    }.reversed().map { $0 }

                    // --- UPDATED: Pass the local copy of files to the backend ---
                    let stream = streamResponse(
                        withConfig: config,
                        conversationID: conversationIDToUse,
                        userQuery: plainUserQueryFromEditor,
                        history: historyForBackend,
                        files: filesForBackend
                    )
                    for try await token in stream {
                        chatHistoryViewModel.appendTokenToStreamingMessage(token)
                    }
                    await chatHistoryViewModel.finalizeResponse(conversationID: conversationIDToUse, error: nil)
                } catch {
                    logger.error("Streaming failed: \(error.localizedDescription)")
                    await chatHistoryViewModel.finalizeResponse(conversationID: conversationIDToUse, error: error)
                }
            }
            chatHistoryViewModel.setStreamingTask(streamingTask)
        } else {
            Task {
                let thinkingAgentMessage = ChatMessage(
                    conversationId: conversationIDToUse,
                    sender: .agent,
                    content: .markdownText(""),
                    isStreaming: true
                )
                chatHistoryViewModel.oneShotThinkingMessage = thinkingAgentMessage
                chatHistoryViewModel.currentChatMessages.insert(thinkingAgentMessage, at: 0)
                logger.debug("Inserted one-shot thinking placeholder message into UI.")

                do {
                    let historyForBackend = chatHistoryViewModel.currentChatMessages.filter { message in
                        if case .error = message.content { return false }
                        return true
                    }.reversed().map { $0 }

                    // --- UPDATED: Pass the local copy of files to the backend ---
                    let (messages, errorMessage) = await backendOrchestrationService.sendMessage(
                        withConfig: config,
                        conversationID: conversationIDToUse,
                        userQuery: plainUserQueryFromEditor,
                        files: filesForBackend
                    )

                    if var placeholder = chatHistoryViewModel.oneShotThinkingMessage,
                       let index = chatHistoryViewModel.currentChatMessages.firstIndex(where: { $0.id == placeholder.id }) {
                        
                        if let errorMessage = errorMessage {
                            placeholder.content = .error(title: "Request Error", details: errorMessage)
                        } else if let agentMessage = messages.first {
                            placeholder.content = agentMessage.content
                        }
                        placeholder.isStreaming = false
                        chatHistoryViewModel.currentChatMessages[index] = placeholder
                        await persistenceService.addMessage(placeholder, to: targetConversationEntity)
                    } else {
                        if let errorMessage = errorMessage {
                            let errorContent = MessageContent.error(title: "Request Error", details: errorMessage)
                            let agentMessage = ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: errorContent)
                            chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
                            await persistenceService.addMessage(agentMessage, to: targetConversationEntity)
                        } else if let agentMessage = messages.first {
                            chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
                            await persistenceService.addMessage(agentMessage, to: targetConversationEntity)
                        }
                    }
                    await chatHistoryViewModel.resetSendingState()
                } catch {
                    logger.error("One-shot request failed: \(error.localizedDescription)")
                    if var placeholder = chatHistoryViewModel.oneShotThinkingMessage,
                       let index = chatHistoryViewModel.currentChatMessages.firstIndex(where: { $0.id == placeholder.id }) {
                        placeholder.content = .error(title: "Request Error", details: error.localizedDescription)
                        placeholder.isStreaming = false
                        chatHistoryViewModel.currentChatMessages[index] = placeholder
                        await persistenceService.addMessage(placeholder, to: targetConversationEntity)
                    } else {
                        let errorContent = MessageContent.error(title: "Request Error", details: error.localizedDescription)
                        let agentMessage = ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: errorContent)
                        chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
                        await persistenceService.addMessage(agentMessage, to: targetConversationEntity)
                    }
                    await chatHistoryViewModel.resetSendingState()
                }
            }
        }
    }
    
    func streamResponse(withConfig config: BackendRequestConfig, conversationID: UUID, userQuery: String, history: [ChatMessage], files: [FileSystemItem]) -> AsyncThrowingStream<String, Error> {
        let context = TraceContext()
        logger.info("🚀 [streamResponse] Providing stream to consumer. History count: \(history.count). traceID: \(context.traceID)")
        return backendOrchestrationService.streamMessage(
            withConfig: config,
            conversationID: conversationID,
            userQuery: userQuery,
            history: history,
            files: files,
            context: context
        )
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
        // if showPromptLibrary { showPromptLibrary = false } // REMOVED
        clearAttachedFiles()
        let newConversationID = createAndSelectNewConversation()
        let config = backendConfiguration.getRequestConfig()
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
        logger.info("Started new conversation with ID \(newConversationID.uuidString). Backend state initialized to \(config.backendType.rawValue).")
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        if showSettings { showSettings = false }
        // if showPromptLibrary { showPromptLibrary = false } // REMOVED
        
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
        logger.info("Loaded backend state for conversation \(conversationID.uuidString, privacy: .public): \(backendType.rawValue)")
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
    // func togglePromptLibrary() { withAnimation { showPromptLibrary.toggle() } } // REMOVED
    func toggleContextArea() { withAnimation { showContextArea.toggle() } }

    // func requestEditPrompt(_ prompt: Prompt) { // REMOVED
    //     if !showPromptLibrary { togglePromptLibrary() }
    //     DispatchQueue.main.async {
    //         NotificationCenter.default.post(name: NSNotification.Name("editPromptRequestedFromBriefView"), object: prompt)
    //     }
    // }
    
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
    
    /// Toggles the active state of web search if an API key is enabled.
    func toggleWebSearch() {
        guard isWebSearchEnabled else { return }
        isWebSearchActive.toggle()
        logger.info("Web search active state toggled to: \(self.isWebSearchActive)")
    }
    
    /// Saves the provided API key to UserDefaults and updates the application state.
    /// - Parameter apiKey: The Google Search API key to save.
    func saveAndEnableWebSearch(apiKey: String) {
        UserDefaults.standard.set(apiKey, forKey: webSearchAPIKeyDefaultsKey)
        self.webSearchAPIKey = apiKey
        self.isWebSearchEnabled = true
        self.isWebSearchActive = true // Also activate it immediately
        logger.info("Successfully saved web search API key to UserDefaults and enabled search.")
    }

    /// Removes the web search API key from UserDefaults and disables the feature.
    func disableAndRemoveWebSearch() {
        UserDefaults.standard.removeObject(forKey: webSearchAPIKeyDefaultsKey)
        self.webSearchAPIKey = nil
        self.isWebSearchEnabled = false
        self.isWebSearchActive = false // Deactivate it as well
        logger.info("Successfully removed web search API key from UserDefaults and disabled search.")
    }
}
