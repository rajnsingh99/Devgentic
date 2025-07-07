//
//  MainApplicationViewModel.swift
//  Devgentic
//
//  Created by Raj Singh
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
    private let persistenceService = CoreDataPersistenceService.shared
    private let fileProcessorService: FileProcessorService
    private let backendOrchestrationService: BackendOrchestrationService

    // MARK: - Service & Store Observables
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
            refreshChatMessages()
        }
    }
    
    @Published var currentChatMessages: [ChatMessage] = []
    @Published var isSending: Bool = false
    @Published var userInput: String = ""
    @Published var isSidebarCollapsed: Bool = true
    @Published var showSettings: Bool = false
    @Published var showPromptLibrary: Bool = false
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil
    @Published var isUserMessagesOnlyFilterActive: Bool = false
    @Published var attachedFiles: [FileSystemItem] = []
    @Published var voiceInputState: VoiceInputState = .idle
    @Published var selectedBackend: BackendType = .none
    
    // This computed property remains for convenience, forwarding to the agentStore.
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
    init(llmIntegrationStore: LLMIntegrationStore,
         agentStore: AgentStore = AgentStore(),
         audioEngineService: AudioEngineService = AudioEngineService(),
         speechRecognitionService: NativeSpeechRecognitionService = NativeSpeechRecognitionService(),
         fileProcessorService: FileProcessorService = FileProcessorService()
    ) {
        self.llmIntegrationStore = llmIntegrationStore
        self.agentStore = agentStore
        self.audioEngineService = audioEngineService
        self.speechRecognitionService = speechRecognitionService
        self.fileProcessorService = fileProcessorService
        
        self.backendOrchestrationService = BackendOrchestrationService(
            agentStore: agentStore,
            llmIntegrationStore: llmIntegrationStore
        )

        logger.info("MainApplicationViewModel initialized.")
        
        checkVoiceInputPermissionsAndAvailability()
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
        
        if audioEngineService.isRecording || speechRecognitionService.isRecognitionActive {
            Task {
                await self.stopVoiceCaptureAndFinalize(customError: "ViewModel deinitializing")
            }
        }
    }
    
    private func setupBindings() {
        agentStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
            
        llmIntegrationStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        
        speechRecognitionService.$speechRecognizerAvailable
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
            .filter { $0.providerType == .ollama }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (newIntegration: LLMIntegrationModel) in
                guard let self = self else { return }
                logger.info("Active Ollama integration changed to '\(newIntegration.displayName)'. Updating OllamaService.")
                
                let service = OllamaService.shared
                service.ollamaBaseURL = newIntegration.ollamaConfig?.baseURL ?? ""
                service.llmModelName = newIntegration.ollamaConfig?.modelName ?? ""
                
                Task {
                    await service.checkServerStatusAndUpdateModels()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Message Sending Logic
    
    /// The primary entry point for sending a message from the UI.
    func sendMessage(attributedString: NSAttributedString) {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        
        let plainUserQueryFromEditor = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let filesToProcess = self.attachedFiles
        
        guard !isSending else {
            logger.warning("Message sending already in progress. Ignoring new request.")
            return
        }
        guard !plainUserQueryFromEditor.isEmpty || !filesToProcess.isEmpty else {
            if !self.userInput.isEmpty { self.userInput = "" }
            return
        }

        self.isSending = true

        Task {
            if voiceInputState.isSessionActive {
                await self.stopVoiceCaptureAndFinalize(customError: nil)
            }

            // 1. Determine the target conversation, creating one if necessary.
            let conversationIDToUse = selectedConversationID ?? createAndSelectNewConversation()
            
            guard let targetConversationEntity = persistenceService.getConversation(withId: conversationIDToUse) else {
                logger.error("CRITICAL: Could not find or create conversation entity for ID: \(conversationIDToUse.uuidString)")
                isSending = false
                return
            }

            // 2. Save the user's message immediately for responsive UI.
            if !plainUserQueryFromEditor.isEmpty {
                let userMessage = ChatMessage(conversationId: conversationIDToUse, sender: .user, content: .plainText(plainUserQueryFromEditor))
                await persistenceService.addMessage(userMessage, to: targetConversationEntity)
                refreshChatMessages()
            }
            
            // 3. Call backed to get llm response
            let (responseMessages, errorMessage) = await backendOrchestrationService.sendMessage(
                conversationID: conversationIDToUse,
                userQuery: plainUserQueryFromEditor,
                files: filesToProcess
            )

            // 4. Save the backend's response or error message.
            var allNewMessages = responseMessages
            if let errorStr = errorMessage {
                let errorContent = MessageContent.error(title: "Backend Error", details: errorStr)
                allNewMessages.append(ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: errorContent))
            }
            
            if !allNewMessages.isEmpty {
                 if let targetEntity = persistenceService.getConversation(withId: conversationIDToUse) {
                    await persistenceService.addMessages(allNewMessages, to: targetEntity)
                    refreshChatMessages()
                }
            }
            
            // 5. Reset UI state.
            self.userInput = ""
            self.clearAttachedFiles()
            self.isSending = false
        }
    }
    
    // MARK: - Conversation & UI Management (largely unchanged)
    
    private func refreshChatMessages() {
        guard let selectedID = selectedConversationID,
              let conversationEntity = persistenceService.getConversation(withId: selectedID) else {
            currentChatMessages = []
            return
        }
        
        let messagesToDisplay = (conversationEntity.messages as? Set<ChatMessageEntity> ?? [])
            .map { $0.toChatMessageStruct() }
            .sorted { $0.timestamp < $1.timestamp }

        currentChatMessages = isUserMessagesOnlyFilterActive ? messagesToDisplay.filter { $0.sender == .user } : messagesToDisplay
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
    
    // MARK: - Voice Input Methods (unchanged)
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

    // MARK: - Other Management Methods (unchanged)
    func transferSelectedConversationToOverlay() {
        guard let conversationID = selectedConversationID else { return }
        UserDefaults.standard.set(conversationID.uuidString, forKey: GlobalConstants.quickAccessOverlayConversationId)
        NotificationCenter.default.post(name: GlobalConstants.showQuickAccessPanelNotification, object: nil, userInfo: ["forceExpand": true])
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
            NotificationCenter.default.post(name: AppNotifications.editPromptRequestedFromBriefView, object: prompt)
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
