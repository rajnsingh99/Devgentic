//
//  MainApplicationViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 15/04/25.
//

import SwiftUI
import Combine
import os
import AppKit // For NSApplication, NSAttributedString
import Speech // Import Speech framework for SFSpeechRecognizerAuthorizationStatus
import AVFoundation // Required for AVCaptureDevice

// Logger for the ViewModel
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MainApplicationViewModel")
private let attachedFilesLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainAppViewModel_AttachedFiles")

@MainActor // Ensure UI updates happen on the main thread
class MainApplicationViewModel: ObservableObject {

    // MARK: - Dependencies
    // --- MODIFIED: Use the concrete class type to resolve build error ---
    private let persistenceService = CoreDataPersistenceService.shared
    
    private let fileProcessorService: FileProcessorService
    private let messageAssemblerService: MessageAssemblerService
    private let llmCommunicator: LLMCommunicatorProtocol

    // MARK: - Use the OllamaService singleton
    @ObservedObject var ollamaService = OllamaService.shared
    @ObservedObject var llmIntegrationStore: LLMIntegrationStore
    @ObservedObject var agentStore: AgentStore

    // MARK: - Voice Input Services
    private let audioEngineService: AudioEngineService
    private let speechRecognitionService: NativeSpeechRecognitionService
    
    private var cancellables = Set<AnyCancellable>()
    
    private var prefixForCurrentUtterance: String = ""

    // MARK: - Published State Properties (UI and Core Chat Logic)
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID? {
        didSet {
            // When the conversation changes, refresh the messages.
            refreshChatMessages()
        }
    }
    
    @Published var currentChatMessages: [ChatMessage] = []
    @Published var isSending: Bool = false
    @Published var userInput: String = ""
    @Published var isSidebarCollapsed: Bool = true
    @Published var showSettings: Bool = false
    @Published var showPromptLibrary: Bool = false
    @Published var selectedSettingsSection: SettingsSection = .general {
        didSet {
            OllamaService.shared.clearAllModelActionStatuses()
        }
    }
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil
    @Published var isUserMessagesOnlyFilterActive: Bool = false
    @Published var attachedFiles: [FileSystemItem] = []
    @Published var voiceInputState: VoiceInputState = .idle
    
    var selectedAgentID: UUID? {
        get {
            agentStore.selectedAgentID
        }
        set {
            agentStore.selectedAgentID = newValue
        }
    }

    @AppStorage(SettingsKeys.selectedBackend) var selectedBackend: BackendType = .agent
    @AppStorage(SettingsKeys.windowOpacity) var windowOpacity: Double = 1.0
    @AppStorage(SettingsKeys.agentBaseURL) var agentBaseURL: String = "http://127.0.0.1:8000"
    @AppStorage(SettingsKeys.agentDelegationStrategy) var agentDelegationStrategy: String = "send_to_first_available"
    
    private let groupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yy"
        return formatter
    }()

    // MARK: - Computed Properties

    var currentConversationTitle: String {
            guard let selectedID = selectedConversationID,
                  let conversationEntity = persistenceService.getConversation(withId: selectedID) else {
                return "Devgentic" // Default title remains.
            }
            return conversationEntity.toConversationStruct().displayTitle
    }
    
    // MARK: - Initialization
    init(llmIntegrationStore: LLMIntegrationStore,
         agentStore: AgentStore = AgentStore(),
         audioEngineService: AudioEngineService = AudioEngineService(),
         speechRecognitionService: NativeSpeechRecognitionService = NativeSpeechRecognitionService(),
         fileProcessorService: FileProcessorService = FileProcessorService(),
         messageAssemblerService: MessageAssemblerService? = nil,
         llmCommunicator: LLMCommunicatorProtocol? = nil
    ) {
        self.llmIntegrationStore = llmIntegrationStore
        self.agentStore = agentStore
        self.audioEngineService = audioEngineService
        self.speechRecognitionService = speechRecognitionService
        
        self.fileProcessorService = fileProcessorService
        self.messageAssemblerService = messageAssemblerService ?? MessageAssemblerService(fileProcessorService: self.fileProcessorService)
        
        self.llmCommunicator = llmCommunicator ?? DefaultLLMCommunicator(fileProcessorService: self.fileProcessorService)

        logger.info("MainApplicationViewModel initialized. Loaded \(self.conversations.count) conversations.")
        
        checkVoiceInputPermissionsAndAvailability()
        
        self.speechRecognitionService.$speechRecognizerAvailable
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                self?.handleSpeechRecognizerAvailabilityChange(isAvailable: available)
            }
            .store(in: &cancellables)

        llmIntegrationStore.$selectedIntegrationID
            .combineLatest(llmIntegrationStore.$integrations)
            .compactMap { selectedID, integrations -> LLMIntegrationModel? in
                guard let id = selectedID else { return nil }
                return integrations.first { $0.id == id }
            }
            .filter { $0.providerType == .ollama } // Only react to Ollama profiles for this service
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (newIntegration: LLMIntegrationModel) in
                guard let self = self else { return }
                logger.info("MainApplicationViewModel: Active Ollama integration changed to '\(newIntegration.displayName)'. UpdatinOllamaService.")
                
                let service = OllamaService.shared
                service.ollamaBaseURL = newIntegration.ollamaBaseURL ?? ""
                service.llmModelName = newIntegration.ollamaModelName ?? ""
                
                Task {
                    await service.checkServerStatusAndUpdateModels()
                }
            }
            .store(in: &cancellables)
        
        setupBindings()
    }
 
    convenience init() {
        let fpService = FileProcessorService()
        let maService = MessageAssemblerService(fileProcessorService: fpService)
        let comm = DefaultLLMCommunicator(fileProcessorService: fpService)
        let llmIntegrationStore = LLMIntegrationStore()
        let agentStore = AgentStore()

        self.init(
            llmIntegrationStore: llmIntegrationStore,
            agentStore: agentStore,
            fileProcessorService: fpService,
            messageAssemblerService: maService,
            llmCommunicator: comm
        )
    }


    deinit {
        logger.info("MainApplicationViewModel deinitialized.")
        cancellables.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
        
        if audioEngineService.isRecording || speechRecognitionService.isRecognitionActive {
            Task {
                await self.stopVoiceCaptureAndFinalize(customError: "ViewModel deinitializing")
            }
        }
    }
    
    private func setupBindings() {
        agentStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        llmIntegrationStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Actions / Methods (UI Toggles, Chat Management)
    
    private func refreshChatMessages() {
        guard let selectedID = selectedConversationID,
              let conversationEntity = persistenceService.getConversation(withId: selectedID) else {
            currentChatMessages = []
            return
        }
        
        let messagesToDisplay = (conversationEntity.messages as? Set<ChatMessageEntity> ?? [])
            .map { $0.toChatMessageStruct() }
            .sorted { $0.timestamp < $1.timestamp }

        if isUserMessagesOnlyFilterActive {
            currentChatMessages = messagesToDisplay.filter { $0.sender == .user }
        } else {
            currentChatMessages = messagesToDisplay
        }
        logger.debug("Chat messages refreshed for conversation \(selectedID.uuidString). Count: \(self.currentChatMessages.count)")
    }
    
    func toggleUserMessagesFilter() {
        isUserMessagesOnlyFilterActive.toggle()
        refreshChatMessages()
    }
    
    func startNewConversation() {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        userInput = ""
        clearAttachedFiles()
        createAndSelectNewConversation()
        isUserMessagesOnlyFilterActive = false
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        persistenceService.addConversation(from: newConversation)
        selectedConversationID = newConversation.id
        isUserMessagesOnlyFilterActive = false
        return newConversation.id
    }
    
    // MARK: - Message Sending Logic
    // --- MODIFIED: Refactored to handle all async calls within a single Task ---
    func sendMessage(attributedString: NSAttributedString) {
        // Synchronous pre-checks
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        
        let plainUserQueryFromEditor = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let filesToProcess = self.attachedFiles
        
        guard !isSending else { return }
        guard !plainUserQueryFromEditor.isEmpty || !filesToProcess.isEmpty else {
            if !self.userInput.isEmpty { self.userInput = "" }
            return
        }

        self.isSending = true

        Task {
            // --- ASYNCHRONOUS OPERATIONS START HERE ---
            
            // 1. Validate backend configuration
            if selectedBackend == .agent {
                guard selectedAgentID != nil else {
                    let conversationIDToUse = selectedConversationID ?? createAndSelectNewConversation()
                    let errorMessage = ChatMessage(
                        conversationId: conversationIDToUse,
                        sender: .agent,
                        content: .error(title: "Agent Not Selected", details: "Please select an agent from the input area to use the Agent backend.")
                    )
                    if let targetEntity = persistenceService.getConversation(withId: conversationIDToUse) {
                        await persistenceService.addMessage(errorMessage, to: targetEntity)
                        refreshChatMessages()
                    }
                    self.isSending = false
                    return
                }
            }
            
            if voiceInputState.isSessionActive {
                self.stopVoiceCaptureAndFinalize(customError: nil)
            }

            // 2. Determine the target conversation
            var conversationIDToUse: UUID
            if let currentID = selectedConversationID, persistenceService.getConversation(withId: currentID) != nil {
                conversationIDToUse = currentID
            } else {
                conversationIDToUse = createAndSelectNewConversation()
            }
            
            guard let targetConversationEntity = persistenceService.getConversation(withId: conversationIDToUse) else {
                logger.error("CRITICAL: Could not find conversation object for ID: \(conversationIDToUse.uuidString) before sending user message.")
                isSending = false
                return
            }

            // 3. Save the user's message and refresh UI
            if !plainUserQueryFromEditor.isEmpty {
                let userMessage = ChatMessage(conversationId: conversationIDToUse, sender: .user, content: .plainText(plainUserQueryFromEditor))
                await persistenceService.addMessage(userMessage, to: targetConversationEntity)
                refreshChatMessages()
            }
            
            // 4. Send to backend and get response
            let (agentMessagesForThisTurn, errorMessage) = await assembleAndSend(
                conversationID: conversationIDToUse,
                userQuery: plainUserQueryFromEditor,
                files: filesToProcess
            )

            // 5. Save the agent's response/error and refresh UI
            var allNewMessages = agentMessagesForThisTurn
            if let errorMsg = errorMessage {
                allNewMessages.append(ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: .error(title: "Error", details: errorMsg)))
            }
            
            if !allNewMessages.isEmpty {
                 if let targetEntity = persistenceService.getConversation(withId: conversationIDToUse) {
                    await persistenceService.addMessages(allNewMessages, to: targetEntity)
                    refreshChatMessages()
                }
            }
            
            // 6. Reset UI state
            self.userInput = ""
            self.clearAttachedFiles()
            self.isSending = false
        }
    }
    
    private func assembleAndSend(conversationID: UUID, userQuery: String, files: [FileSystemItem]) async -> ([ChatMessage], String?) {
        do {
            switch selectedBackend {
            case .ollama:
//                let (messages, error) = try await sendToOllama(conversationID: conversationID, userQuery: userQuery, files: files)
                return ([], "")
                
            case .agent:
                let (messages, error) = try await sendToAgent(conversationID: conversationID, userQuery: userQuery, files: files)
                return (messages, error?.localizedDescription)
            }
        } catch {
            let userFriendlyError = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: self.selectedBackend)
            return ([], userFriendlyError)
        }
    }

    // MARK: - Agent Payload Construction and Sending
    private func sendToAgent(conversationID: UUID, userQuery: String, files: [FileSystemItem]) async throws -> ([ChatMessage], Error?) {
        guard let selectedAgent = agentStore.agents.first(where: { $0.id == selectedAgentID }) else {
            throw NSError(domain: "AgentConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "No agent is selected or the selected agent could not be found."])
        }
        
        guard let linkedIntegration = llmIntegrationStore.integrations.first(where: { $0.id == selectedAgent.linkedIntegrationID }) else {
            throw NSError(domain: "AgentConfigError", code: 404, userInfo: [NSLocalizedDescriptionKey: "The selected agent is not linked to a valid LLM integration."])
        }

        guard linkedIntegration.providerType == .ollama,
                let baseUrl = linkedIntegration.ollamaBaseURL,
                let modelName = linkedIntegration.ollamaModelName else {
            throw NSError(domain: "AgentConfigError", code: 400, userInfo: [NSLocalizedDescriptionKey: "The agent's linked LLM integration must be a configured Ollama provider."])
        }

        let llmSettings = OllamaLLMSettings(
            baseUrl: baseUrl,
            modelName: modelName,
            contextWindowSize: linkedIntegration.contextWindowSize ?? 4096
        )

        let rootAgentConfig = AgentConfig(
            agentId: selectedAgent.id.uuidString,
            parentId: nil,
            roleObjective: userQuery,
            tools: selectedAgent.tools.map { $0.id },
            llmSettings: .ollama(llmSettings)
        )

        let fileObjects = files.map { FileObject(uri: $0.url.absoluteString, name: $0.name) }

        let payload = AgentOrchestrationRequest(
            conversationId: conversationID.uuidString,
            files: fileObjects,
            agentConfigs: [rootAgentConfig]
        )
        
        let agentBaseURL = selectedAgent.baseURL
        let backendConfig = BackendConfiguration(url: agentBaseURL, endpoint: "/agent/chat", payload: [:])

        let llmResponse = try await self.llmCommunicator.sendMessage(payload: payload, to: .agent, config: backendConfig)
        let messages = llmResponse.content.map { ChatMessage(conversationId: conversationID, sender: .agent, content: $0) }
        
        return (messages, llmResponse.error)
    }

    private func determineBackendConfiguration() -> BackendConfiguration {
        if let currentIntegration = llmIntegrationStore.currentIntegration,
            currentIntegration.providerType == .ollama,
            self.selectedBackend == .ollama,
            let baseUrl = currentIntegration.ollamaBaseURL {
            
            let advancedOptions: [String: Any] = [
                "temperature": currentIntegration.temperature ?? 0.8,
                "num_ctx": currentIntegration.contextWindowSize ?? 4096
            ]
            let modelName = currentIntegration.ollamaModelName ?? "default_model_name"
            let initialPayload: [String: Any] = ["model": modelName, "stream": false, "options": advancedOptions]
            return BackendConfiguration(url: baseUrl, endpoint: "/api/generate", payload: initialPayload)
        
        } else {
            return BackendConfiguration(url: self.agentBaseURL, endpoint: "/agent/chat", payload: [:])
        }
    }
    
    // MARK: - Voice Input Methods
    private func handleSpeechRecognizerAvailabilityChange(isAvailable: Bool) {
        logger.info("Speech Recognizer availability changed to: \(isAvailable)")
        if !isAvailable {
            if voiceInputState.isSessionActive {
                self.stopVoiceCaptureAndFinalize(customError: "Speech recognizer became unavailable.")
            }
            if voiceInputState.canTransitionToError {
                self.voiceInputState = .speechRecognitionUnavailable
            }
        } else {
            if voiceInputState == .speechRecognitionUnavailable || voiceInputState == .idle {
                 self.checkVoiceInputPermissionsAndAvailability()
            }
        }
    }
    
    func checkVoiceInputPermissionsAndAvailability() {
        self.voiceInputState = .requestingPermissions
        
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            audioEngineService.requestMicrophonePermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.checkSpeechRecognitionPermission() }
                    else { self?.voiceInputState = .permissionsDeniedMic }
                }
            }
        } else if micStatus == .authorized {
            checkSpeechRecognitionPermission()
        } else {
            self.voiceInputState = .permissionsDeniedMic
        }
    }

    private func checkSpeechRecognitionPermission() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            speechRecognitionService.requestSpeechRecognitionPermission { [weak self] status in
                DispatchQueue.main.async { self?.updateStateAfterPermissionRequest(status: status) }
            }
        } else {
            updateStateAfterPermissionRequest(status: speechStatus)
        }
    }
    
    private func updateStateAfterPermissionRequest(status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized:
            self.voiceInputState = speechRecognitionService.speechRecognizerAvailable ? .available : .speechRecognitionUnavailable
        case .denied:
            self.voiceInputState = .permissionsDeniedSpeech
        case .restricted:
            self.voiceInputState = .error("Speech recognition restricted.")
        default:
            self.voiceInputState = .error("Could not determine speech permission.")
        }
    }

    func toggleVoiceInput() {
        switch self.voiceInputState {
        case .idle, .available:
            if userInput.isEmpty { startVoiceCapture() }
        case .recording:
            stopVoiceCaptureAndFinalize(customError: nil)
        case .processing:
             stopVoiceCaptureAndFinalize(customError: nil)
        case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error:
            checkVoiceInputPermissionsAndAvailability()
        case .requestingPermissions:
            break
        }
    }

    private func startVoiceCapture() {
        guard userInput.isEmpty, voiceInputState == .available else {
            checkVoiceInputPermissionsAndAvailability()
            return
        }
        
        self.prefixForCurrentUtterance = self.userInput
        do {
            try audioEngineService.startStreamingAudio { [weak self] (buffer, _) in
                self?.speechRecognitionService.processAudioBuffer(buffer)
            }
            try speechRecognitionService.startRecognition(recognitionHandler: { [weak self] (transcript, isFinal, error) in
                self?.handleRecognitionUpdate(transcript: transcript, isFinal: isFinal, error: error)
            })
            voiceInputState = .recording
        } catch {
            voiceInputState = .error("Start capture error: \(error.localizedDescription.prefix(50))")
            audioEngineService.stopStreamingAudio()
        }
    }
    
    private func handleRecognitionUpdate(transcript: String, isFinal: Bool, error: Error?) {
        DispatchQueue.main.async {
            if let error = error {
                let nsError = error as NSError
                let isCancellationError = nsError.domain == SFSpeechErrorDomain || (nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1107)
                let noSpeechError = nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110
                
                let finalActionErrorString = isCancellationError ? nil : (noSpeechError ? "No speech detected." : "Recognition error: \(error.localizedDescription.prefix(50))")
                self.stopVoiceCaptureAndFinalize(customError: finalActionErrorString)
                return
            }

            let separator = self.prefixForCurrentUtterance.isEmpty || self.prefixForCurrentUtterance.last?.isWhitespace == true ? "" : " "
            self.userInput = self.prefixForCurrentUtterance + separator + transcript
            
            if isFinal {
                self.stopVoiceCaptureAndFinalize(customError: nil)
            }
        }
    }

    private func stopVoiceCaptureAndFinalize(customError: String?) {
        let previousState = self.voiceInputState
        if previousState.isSessionActive {
            audioEngineService.stopStreamingAudio()
            speechRecognitionService.stopRecognition()
        }

        if let explicitError = customError, !explicitError.isEmpty {
            self.voiceInputState = .error(explicitError)
        } else {
            updateStateAfterPermissionRequest(status: SFSpeechRecognizer.authorizationStatus())
        }
        
        logger.info("stopVoiceCaptureAndFinalize: State transitioned from \(previousState.description) to \(self.voiceInputState.description).")
    }


    // MARK: - Conversation Management
    func transferSelectedConversationToOverlay() {
        guard let conversationID = selectedConversationID else { return }
        UserDefaults.standard.set(conversationID.uuidString, forKey: SettingsKeys.quickAccessOverlayConversationId)
        NotificationCenter.default.post(name: SettingsKeys.showQuickAccessPanelNotification, object: nil, userInfo: ["forceExpand": true])
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


    // MARK: - UI Toggles
    func toggleSidebar() { withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() } }
    func toggleSettings() { withAnimation { showSettings.toggle() } }
    func togglePromptLibrary() { withAnimation { showPromptLibrary.toggle() } }
    func toggleContextArea() { withAnimation { showContextArea.toggle() } }

    func requestEditPrompt(_ prompt: Prompt) {
        if !showPromptLibrary { togglePromptLibrary() }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AppNotifications.editPromptRequestedFromBriefView, object: prompt)
        }
    }
    
    // MARK: - Private Helper Methods
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

// MARK: - Error and State Extensions
extension URLError {
    var isConnectionError: Bool {
        return code == .cannotConnectToHost || code == .cannotFindHost || code == .networkConnectionLost
    }
}
