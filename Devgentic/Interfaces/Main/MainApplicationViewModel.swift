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
    
    // MARK: - Query History Properties
    @Published private(set) var queryHistory: [String] = []
    private var currentHistoryIndex: Int = -1
    
    enum QueryNavigationDirection {
        case up, down
    }
    
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
        fileProcessorService: FileProcessorService = FileProcessorService(),
        activeStreamManager: ActiveStreamManager,
        chatHistoryViewModel: ChatHistoryViewModel
    ) {
        self.persistenceService = persistenceService
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
            
        backendConfiguration.$selectedProfileID
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] profileID in
                guard let self = self, let conversationID = self.selectedConversationID else { return }
                
                logger.info("Backend profile changed. Updating current conversation \(conversationID.uuidString).")
                self.updateBackendForCurrentConversation(conversationID: conversationID, profileID: profileID)
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
                    // NEW: Unload MLX model whenever the user switches conversation.
                    // This ensures memory is freed immediately upon navigation.
                    let stats = await MLXService.shared.unloadModel()
                    logger.debug("Conversation switch MLX unload stats: \(stats)")
                    
                    // NEW: Unload Ollama model to free VRAM.
                    // This assumes OllamaService has an exposed unloadModel() method that sends keep_alive: 0.
                    await self.ollamaService.unloadModel()
                    
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
        guard let config = backendConfiguration.getRequestConfig() else {
            logger.error("[sendMessage] CRITICAL: Could not get backend request config. Is a profile selected?")
            return
        }

        chatHistoryViewModel.isSending = true
        logger.info("Beginning message send process with profile: \(config.profile.displayName)")
        
        // Add to query history
        if !plainUserQueryFromEditor.isEmpty, queryHistory.last != plainUserQueryFromEditor {
            queryHistory.append(plainUserQueryFromEditor)
        }
        resetQueryHistoryIndex() // Reset index after sending a new message
        
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
        
        chatHistoryViewModel.currentChatMessages.insert(userMessage, at: 0)
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
            updating: nil,
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    self?.streamingMessageID = nil
                    logger.info("Stream completed. Resetting streamingMessageID.")
                }
            }
        )

        self.streamingMessageID = agentMessage.id
        chatHistoryViewModel.currentChatMessages.insert(agentMessage, at: 0)
        logger.debug("Appended agent's streaming message placeholder into UI for real-time updates.")

        Task {
            await chatHistoryViewModel.resetSendingState()
        }
    }
    
    // MARK: - Query History Navigation
    
    func getQueryFromHistory(direction: QueryNavigationDirection) -> String? {
        if queryHistory.isEmpty { return nil }

        if currentHistoryIndex == -1 {
            if direction == .up {
                currentHistoryIndex = queryHistory.count - 1
                return queryHistory[currentHistoryIndex]
            }
            return nil // Can't go down from "new" input state
        }

        if direction == .up {
            if currentHistoryIndex > 0 {
                currentHistoryIndex -= 1
                return queryHistory[currentHistoryIndex]
            }
            return queryHistory[0] // Return the oldest item if already at the top
        } else { // direction == .down
            if currentHistoryIndex < queryHistory.count - 1 {
                currentHistoryIndex += 1
                return queryHistory[currentHistoryIndex]
            } else {
                // Navigated past the most recent query, back to a new input state
                currentHistoryIndex = -1
                return "" // Return empty string to clear the input field
            }
        }
    }

    func resetQueryHistoryIndex() {
        currentHistoryIndex = -1
    }
    
    // MARK: - Response Regeneration
    
    @MainActor
    func regenerateResponse(for agentMessage: ChatMessage) {
        guard let agentResponse = agentMessage.agentResponse, agentResponse.generationAttempts < 5 else {
            logger.warning("Max generation attempts reached for message \(agentMessage.id.uuidString).")
            return
        }

        guard let agentMessageIndex = chatHistoryViewModel.currentChatMessages.firstIndex(of: agentMessage) else {
            logger.error("Could not find agent message in chat history to regenerate.")
            return
        }
        
        let historyForRegeneration = Array(chatHistoryViewModel.currentChatMessages.dropFirst(agentMessageIndex + 1).reversed())
        
        guard let userQueryMessage = chatHistoryViewModel.currentChatMessages[safe: agentMessageIndex + 1],
              userQueryMessage.sender == .user else {
            logger.error("Could not find the preceding user query for regeneration.")
            return
        }
        let userQuery = userQueryMessage.content.textContent ?? ""
        
        let filesForBackend = (userQueryMessage.attachedTextFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? []) +
                              (userQueryMessage.attachedImageFiles?.map { FileSystemItem(id: $0.url, name: $0.name, url: $0.url, isDirectory: false) } ?? [])

        guard let config = backendConfiguration.getRequestConfig() else {
            logger.error("[regenerateResponse] Could not get backend request config. Is a profile selected?")
            return
        }
        
        let newVariant = ResponseMessageVariant(
            content: .markdownText(""),
            backendEntityId: config.profile.id
        )
        agentMessage.agentResponse?.variants.append(newVariant)
        agentMessage.agentResponse?.selectedVariantIndex = (agentMessage.agentResponse?.variants.count ?? 1) - 1
        agentMessage.agentResponse?.generationAttempts += 1
        agentMessage.isStreaming = true

        let streamingMessage = activeStreamManager.startMessageStream(
            withConfig: config,
            conversationID: agentMessage.conversationId,
            userQuery: userQuery,
            history: historyForRegeneration,
            files: filesForBackend,
            updating: agentMessage,
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    self?.streamingMessageID = nil
                    logger.info("Regeneration stream completed for message \(agentMessage.id.uuidString).")
                }
            }
        )
        
        self.streamingMessageID = streamingMessage.id
    }
    
    func cancelStreamingResponse() {
        guard let messageID = streamingMessageID else {
            logger.warning("cancelStreamingResponse called but no streamingMessageID is set.")
            return
        }
        
        logger.info("User requested to cancel streaming for message: \(messageID.uuidString)")
        activeStreamManager.cancelStream(for: messageID)
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
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
        logger.info("Started new conversation with ID \(newConversationID.uuidString).")
    }
    
    // NEW: Function to deselect conversation and return to the welcome screen
    func deselectConversationAndShowWelcome() {
        if showSettings { showSettings = false }
        clearAttachedFiles()
        selectedConversationID = nil
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
        logger.info("Deselected conversation, returning to welcome screen.")
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        if showSettings { showSettings = false }
        
        let profileID = backendConfiguration.selectedProfileID
        
        let newConversation = Conversation(
            id: UUID(),
            messages: [],
            timestamp: Date(),
            backendType: .none,
            backendEntityId: profileID
        )
        persistenceService.addConversation(from: newConversation)
        chatHistoryViewModel.currentChatMessages = []
        selectedConversationID = newConversation.id
        chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
        
        updateBackendForCurrentConversation(conversationID: newConversation.id, profileID: profileID)
        
        return newConversation.id
    }
    
    private func loadBackendStateForSelectedConversation(conversationID: UUID) {
        guard let conversationEntity = persistenceService.getConversation(withId: conversationID) else {
            logger.warning("Could not find conversation entity \(conversationID.uuidString) to load backend state. Resetting.")
            self.backendConfiguration.selectedProfileID = nil
            return
        }

        let conversation = conversationEntity.toConversationStruct()
        
        let profileID = conversation.backendEntityId
        self.backendConfiguration.selectedProfileID = profileID

        logger.info("Loaded backend profile ID \(profileID?.uuidString ?? "nil") for conversation \(conversationID, privacy: .public)")
    }

    private func updateBackendForCurrentConversation(conversationID: UUID, profileID: UUID?) {
        var legacyBackendType: BackendType = .none
        if let id = profileID, let profile = BackendProfileStore.shared.fetchProfiles().first(where: { $0.id == id }) {
            switch profile.profileType {
            case .agent:
                legacyBackendType = .agent
            case .bot:
                if case .bot(let config) = profile.details, config.apiProvider == .ollama {
                    legacyBackendType = .ollama
                } else {
                    legacyBackendType = .remote
                }
            case .workflow:
                legacyBackendType = .none
            }
        }
        
        persistenceService.updateBackendForConversation(
            id: conversationID,
            backendType: legacyBackendType,
            backendEntityId: profileID
        )
        logger.debug("Persisted profile ID \(profileID?.uuidString ?? "nil") for conversation \(conversationID.uuidString).")
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
