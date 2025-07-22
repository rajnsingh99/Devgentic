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
import Speech
import AVFoundation


private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MainApplicationViewModel")

@MainActor
class MainApplicationViewModel: ObservableObject {

    // MARK: - Dependencies
    private let persistenceService: CoreDataServiceProtocol
    private let fileProcessorService: FileProcessorService
    private let backendOrchestrationService: BackendOrchestrationService

    // MARK: - Service & Store Observables
    @ObservedObject var ollamaService = OllamaService.shared
    @ObservedObject var llmIntegrationStore: LLMIntegrationStore
    @ObservedObject var agentStore = AgentStore() // Initialize here

    let explorerViewModel = ExplorerViewModel()

    // --- ADDED: Publisher to send text from prompts to the input area ---
    let insertPromptText = PassthroughSubject<String, Never>()
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Published State Properties
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID? {
        didSet {
            logger.debug("selectedConversationID didSet: Old ID \(oldValue?.uuidString ?? "nil"), New ID \(self.selectedConversationID?.uuidString ?? "nil")")
            if oldValue != selectedConversationID {
                cancelStreaming()
                Task {
                    await loadConversation()
                }
            } else if selectedConversationID != nil {
                Task {
                    await loadConversation()
                }
            }
            // Always load backend state when conversation changes
            loadBackendStateForSelectedConversation()
        }
    }
    
    @Published var currentChatMessages: [ChatMessage] = []
    @Published var isSending: Bool = false
    @Published var isSidebarCollapsed: Bool = true
    @Published var showSettings: Bool = false
    @Published var showPromptLibrary: Bool = false
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil
    @Published var isUserMessagesOnlyFilterActive: Bool = false
    @Published var attachedFiles: [FileSystemItem] = []
    @Published var selectedBackend: BackendType = .none // This property drives the UI backend selection
    
    @Published var isInitiallyLoadingConversation = false
    
    // --- Pagination State ---
    @Published var isLoadingPage = false
    @Published var canLoadMorePages = true
    private let initialPageSize = 20
    private let subsequentPageSize = 10
    
    @Published var streamingMessage: ChatMessage? = nil
    @Published var streamingTriggerID: UUID? = nil
    
    private var streamingTask: Task<Void, Never>?

    // --- State for Code Viewer Panel ---
    @Published var isCodeViewerVisible: Bool = false
    @Published var codeViewerContent: (language: String?, code: String)? = nil

    var selectedAgentID: UUID? {
        get { agentStore.selectedAgentID }
        set { agentStore.selectedAgentID = newValue }
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
    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared,
         llmIntegrationStore: LLMIntegrationStore,
         agentStore: AgentStore = AgentStore(),
         fileProcessorService: FileProcessorService = FileProcessorService()
    ) {
        self.persistenceService = persistenceService
        self.llmIntegrationStore = llmIntegrationStore
        self.agentStore = agentStore
        self.fileProcessorService = fileProcessorService
        
        self.backendOrchestrationService = BackendOrchestrationService(
            agentStore: agentStore,
            llmIntegrationStore: llmIntegrationStore,
            fileProcessorService: fileProcessorService
        )

        logger.info("MainApplicationViewModel initialized.")
        
        setupBindings()
    }
 
    convenience init() {
        let fpService = FileProcessorService()
        let llmStore = LLMIntegrationStore()
        let agStore = AgentStore()

        self.init(
            llmIntegrationStore: llmStore,
            agentStore: agStore,
            fileProcessorService: fpService
        )
    }

    deinit {
        logger.info("MainApplicationViewModel deinitialized.")
        cancellables.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
        streamingTask?.cancel()
    }
    
    // MARK: - Bindings Setup
    private func setupBindings() {
        // Observe changes to selectedBackend and related IDs to persist the choice
        // This ensures that when a user selects a backend via the UI (e.g., BackendSelectorPopup),
        // that selection is saved to the currently active conversation in Core Data.
        $selectedBackend
            .combineLatest(agentStore.$selectedAgentID, llmIntegrationStore.$selectedIntegrationID)
            .sink { [weak self] newBackendType, newAgentID, newIntegrationID in
                guard let self = self else { return }
                // Only update persistence if a conversation is actually selected
                // and if the values have genuinely changed from the last persisted state
                // to avoid unnecessary saves.
                if let conversationID = self.selectedConversationID {
                    let currentConversation = self.persistenceService.getConversation(withId: conversationID)?.toConversationStruct()
                    let currentPersistedBackendType = currentConversation?.backendType
                    let currentPersistedBackendEntityId = currentConversation?.backendEntityId

                    var effectiveBackendEntityId: UUID?
                    switch newBackendType {
                    case .agent:
                        effectiveBackendEntityId = newAgentID
                    case .ollama, .remote:
                        effectiveBackendEntityId = newIntegrationID
                    case .none:
                        effectiveBackendEntityId = nil
                    }

                    // Only save if there's an actual change in backend type or entity ID
                    if newBackendType != currentPersistedBackendType || effectiveBackendEntityId != currentPersistedBackendEntityId {
                        self.updateBackendForCurrentConversation()
                        logger.info("Backend selection changed to \(newBackendType.rawValue) with entity ID \(effectiveBackendEntityId?.uuidString ?? "nil"). Persisting to conversation \(conversationID.uuidString).")
                    }
                }
            }
            .store(in: &cancellables)

        // Observe changes to currentAgent and currentIntegration in their respective stores.
        // This is important because these stores might update their 'current' selections
        // independently (e.g., when loading all agents/integrations), and we need to
        // reflect that in the main view model's selectedBackend.
        agentStore.$selectedAgentID
            .combineLatest(llmIntegrationStore.$selectedIntegrationID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agentID, integrationID in
                guard let self = self else { return }
                
                let agent = self.agentStore.currentAgent
                let integration = self.llmIntegrationStore.currentIntegration

                // If an agent is selected, ensure selectedBackend reflects it
                if let agent = agent {
                    if self.selectedBackend != .agent || self.agentStore.selectedAgentID != agent.id {
                        self.selectedBackend = .agent
                        self.agentStore.selectedAgentID = agent.id
                        self.llmIntegrationStore.selectedIntegrationID = nil
                    }
                }
                // If an LLM integration is selected, ensure selectedBackend reflects it
                else if let integration = integration {
                    let newBackendType: BackendType = (integration.providerType == .ollama) ? .ollama : .remote
                    if self.selectedBackend != newBackendType || self.llmIntegrationStore.selectedIntegrationID != integration.id {
                        self.selectedBackend = newBackendType
                        self.llmIntegrationStore.selectedIntegrationID = integration.id
                        self.agentStore.selectedAgentID = nil
                    }
                }
                // If neither is selected, ensure selectedBackend is .none
                else {
                    if self.selectedBackend != .none {
                        self.selectedBackend = .none
                        self.agentStore.selectedAgentID = nil
                        self.llmIntegrationStore.selectedIntegrationID = nil
                    }
                }
                // The combineLatest above will trigger updateBackendForCurrentConversation if selectedBackend changes.
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Code Viewer Panel Control
    
    func showCodeInViewer(language: String?, code: String) {
        codeViewerContent = (language, code)
        withAnimation(.snappy()) {
            isCodeViewerVisible = true
        }
    }

    func hideCodeViewer() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isCodeViewerVisible = false
            codeViewerContent = nil
        }
    }

    // MARK: - Message Sending Logic
    
    func sendMessage(attributedString: NSAttributedString) {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        
        let plainUserQueryFromEditor = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !isSending else {
            logger.warning("[sendMessage] Message sending already in progress. Ignoring new request.")
            return
        }
        guard !plainUserQueryFromEditor.isEmpty || !attachedFiles.isEmpty else {
            return
        }

        self.isSending = true
        logger.info("Beginning message send process.")
        
        // Ensure a conversation is selected or create a new one
        let conversationIDToUse = selectedConversationID ?? createAndSelectNewConversation()
        
        guard let targetConversationEntity = persistenceService.getConversation(withId: conversationIDToUse) else {
            logger.error("[sendMessage] CRITICAL: Could not find or create conversation entity for ID: \(conversationIDToUse.uuidString)")
            isSending = false
            return
        }

        let userMessage = createUserMessage(
            conversationID: conversationIDToUse,
            query: plainUserQueryFromEditor,
            files: attachedFiles
        )
        
        Task {
            await persistenceService.addMessage(userMessage, to: targetConversationEntity)
            logger.debug("User message persisted successfully.")
        }
        currentChatMessages.insert(userMessage, at: 0)
        logger.debug("User message inserted into UI.")
        
        // ANTICIPATORY SCROLL: This is the placeholder for the incoming AI response.
        let agentMessage = ChatMessage(
            conversationId: conversationIDToUse,
            sender: .agent,
            content: .markdownText(""),
            isStreaming: true
        )
        logger.info("Created initial empty agent message with ID \(agentMessage.id.uuidString) to begin streaming.")

        self.streamingMessage = agentMessage
        logger.debug("Set active streaming message.")

        self.currentChatMessages.insert(agentMessage, at: 0)
        logger.debug("Inserted streaming agent message into UI.")

        self.clearAttachedFiles()
        logger.debug("Cleared user input and attachments.")

        // ANTICIPATORY SCROLL: The trigger is now the ID of the placeholder message.
        // This tells the view to scroll to the top of this placeholder, creating space.
        self.streamingTriggerID = agentMessage.id
        logger.info("Set streaming trigger ID to placeholder message ID \(agentMessage.id.uuidString).")

        // Start streaming response
        streamingTask = Task {
            do {
                // FIX: Filter out messages with content of type .error from history
                // Convert ReversedCollection to Array by adding .map { $0 }
                let historyForBackend = currentChatMessages.filter { message in
                    // Assuming ChatMessage.Content has an .error case, and SenderRole does not.
                    if case .error = message.content { return false }
                    return true
                }.reversed().map { $0 } // Convert to Array<ChatMessage>

                let stream = streamResponse(
                    conversationID: conversationIDToUse,
                    userQuery: plainUserQueryFromEditor, // Use original query for stream response
                    history: historyForBackend,
                    files: attachedFiles // Pass attached files for RAG
                )
                for try await token in stream {
                    await appendTokenToStreamingMessage(token)
                }
                await finalizeStreaming(conversationID: conversationIDToUse, error: nil)
            } catch {
                logger.error("Streaming failed: \(error.localizedDescription)")
                await finalizeStreaming(conversationID: conversationIDToUse, error: error)
            }
        }
    }
    
    func streamResponse(conversationID: UUID, userQuery: String, history: [ChatMessage], files: [FileSystemItem]) -> AsyncThrowingStream<String, Error> {
        let context = TraceContext()
        logger.info("🚀 [streamResponse] Providing stream to consumer. History count: \(history.count). traceID: \(context.traceID)")
        return backendOrchestrationService.streamMessage(
            conversationID: conversationID,
            userQuery: userQuery,
            history: history,
            files: files,
            context: context
        )
    }

    func appendTokenToStreamingMessage(_ token: String) async {
        guard var message = self.streamingMessage else {
            logger.warning("appendTokenToStreamingMessage called but streamingMessage is nil.")
            return
        }

        if var currentText = message.content.textContent {
            currentText += token
            message.content = .markdownText(currentText)
        }

        self.streamingMessage = message
        
        if let index = self.currentChatMessages.firstIndex(where: { $0.id == message.id }) {
            self.currentChatMessages[index] = message
            logger.trace("Appended token and updated message in UI array.")
        } else {
            logger.warning("Could not find streaming message in currentChatMessages to update UI.")
        }
    }
    
    func finalizeStreaming(conversationID: UUID, error: Error?) async {
        logger.info("Finalizing stream for conversation \(conversationID.uuidString).")
        guard var finalMessage = self.streamingMessage else {
            logger.warning("finalizeStreaming called but no streaming message was found. Resetting state.")
            await resetSendingState()
            return
        }

        finalMessage.isStreaming = false
        logger.debug("Marked message \(finalMessage.id.uuidString) as no longer streaming.")

        if let error = error {
            logger.error("Finalizing stream with error: \(error.localizedDescription)")
            finalMessage.content = .error(title: "Streaming Error", details: error.localizedDescription)
        } else {
            logger.info("Stream finalized successfully with full text.")
        }

        if let index = self.currentChatMessages.firstIndex(where: { $0.id == finalMessage.id }) {
            self.currentChatMessages[index] = finalMessage
            logger.debug("Updated final message in currentChatMessages array.")
        }

        if let targetEntity = persistenceService.getConversation(withId: conversationID) {
            await persistenceService.addMessage(finalMessage, to: targetEntity)
            logger.info("Persisted final message \(finalMessage.id.uuidString).")
        } else {
            logger.error("Could not find conversation entity \(conversationID.uuidString) to persist final message.")
        }

        await resetSendingState()
    }
    
    func resetSendingState() async {
        self.clearAttachedFiles()
        self.isSending = false
        self.streamingTriggerID = nil
        self.streamingMessage = nil
        logger.info("✅ [Request Finished] Sending state has been reset.")
    }

    func cancelStreaming() {
        if streamingTriggerID != nil {
            logger.info("Streaming cancelled by user.")
            streamingTask?.cancel() // Cancel the ongoing streaming task
            Task {
                await resetSendingState()
            }
        }
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
    
    // MARK: - Paginated Message Loading
    
    func loadConversation() async {
        guard let selectedID = selectedConversationID else {
            currentChatMessages = []
            return
        }
        
        logger.debug("Loading initial page for conversation \(selectedID.uuidString, privacy: .public).")
        
        isInitiallyLoadingConversation = true
        currentChatMessages = []
        canLoadMorePages = true
        
        let messages = await persistenceService.fetchMessages(for: selectedID, offset: 0, limit: initialPageSize)
        
        self.currentChatMessages = messages

        if messages.count < initialPageSize {
            self.canLoadMorePages = false
        }
        
        if isUserMessagesOnlyFilterActive {
            applyUserMessagesFilter()
        }
        
        self.isInitiallyLoadingConversation = false
    }

    func loadMoreMessages() async {
        guard !isLoadingPage, canLoadMorePages, let selectedID = selectedConversationID else {
            return
        }
        
        isLoadingPage = true
        
        let offset = currentChatMessages.count
        logger.debug("Loading page with offset \(offset) for conversation \(selectedID.uuidString, privacy: .public).")
        
        let olderMessages = await persistenceService.fetchMessages(for: selectedID, offset: offset, limit: subsequentPageSize)
        
        if olderMessages.isEmpty {
            canLoadMorePages = false
        } else {
            self.currentChatMessages.append(contentsOf: olderMessages)
            
            if isUserMessagesOnlyFilterActive {
                applyUserMessagesFilter()
            }
        }
        
        isLoadingPage = false
    }

    
    func toggleUserMessagesFilter() {
        isUserMessagesOnlyFilterActive.toggle()
        Task {
            await loadConversation()
        }
    }
    
    private func applyUserMessagesFilter() {
        if isUserMessagesOnlyFilterActive {
            currentChatMessages = currentChatMessages.filter { $0.sender == .user }
        }
    }
    
    func startNewConversation() {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        clearAttachedFiles()
        let newConversationID = createAndSelectNewConversation()
        // Ensure that selectedBackend reflects the initial .none state immediately for the new conversation.
        // This reinforces the initial state before any user interaction for backend selection.
        self.selectedBackend = .none
        self.agentStore.selectedAgentID = nil
        self.llmIntegrationStore.selectedIntegrationID = nil
        isUserMessagesOnlyFilterActive = false
        logger.info("Started new conversation with ID \(newConversationID.uuidString). Backend state initialized to .none.")
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date(), backendType: .none, backendEntityId: nil)
        persistenceService.addConversation(from: newConversation)
        selectedConversationID = newConversation.id
        isUserMessagesOnlyFilterActive = false
        return newConversation.id
    }
    
    private func loadBackendStateForSelectedConversation() {
        guard let conversationID = selectedConversationID,
              let conversationEntity = persistenceService.getConversation(withId: conversationID) else {
            self.selectedBackend = .none
            self.agentStore.selectedAgentID = nil
            self.llmIntegrationStore.selectedIntegrationID = nil
            logger.info("No conversation selected or found. Resetting backend state to .none.")
            return
        }

        let conversation = conversationEntity.toConversationStruct()
        let backendType = conversation.backendType ?? .none
        let backendEntityId = conversation.backendEntityId

        // Update the @Published properties based on the loaded conversation's backend
        self.selectedBackend = backendType
        
        switch backendType {
        case .agent:
            self.agentStore.selectedAgentID = backendEntityId
            self.llmIntegrationStore.selectedIntegrationID = nil
        case .ollama, .remote:
            self.llmIntegrationStore.selectedIntegrationID = backendEntityId
            self.agentStore.selectedAgentID = nil
        case .none:
            self.agentStore.selectedAgentID = nil
            self.llmIntegrationStore.selectedIntegrationID = nil
        }
        logger.info("Loaded backend state for conversation \(conversationID.uuidString, privacy: .public): \(backendType.rawValue)")
    }

    private func updateBackendForCurrentConversation() {
        guard let conversationID = selectedConversationID else {
            logger.warning("Attempted to update backend for current conversation, but no conversation is selected.")
            return
        }

        var entityId: UUID?
        switch self.selectedBackend {
        case .agent:
            entityId = agentStore.selectedAgentID
        case .ollama, .remote:
            entityId = llmIntegrationStore.selectedIntegrationID
        case .none:
            entityId = nil
        }
        
        persistenceService.updateBackendForConversation(
            id: conversationID,
            backendType: selectedBackend,
            backendEntityId: entityId
        )
        logger.debug("Persisted backend type \(self.selectedBackend.rawValue) and entity ID \(entityId?.uuidString ?? "nil") for conversation \(conversationID.uuidString).")
    }
    
    func transferSelectedConversationToOverlay() {
        guard let conversationID = selectedConversationID else { return }
        UserDefaults.standard.set(conversationID.uuidString, forKey: "quickAccessOverlayConversationId")
        NotificationCenter.default.post(name: NSNotification.Name("showQuickAccessPanel"), object: nil, userInfo: ["forceExpand": true])
        self.selectedConversationID = nil
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
    func togglePromptLibrary() { withAnimation { showPromptLibrary.toggle() } }
    func toggleContextArea() { withAnimation { showContextArea.toggle() } }

    func requestEditPrompt(_ prompt: Prompt) {
        if !showPromptLibrary { togglePromptLibrary() }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("editPromptRequestedFromBriefView"), object: prompt)
        }
    }
    
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
}
