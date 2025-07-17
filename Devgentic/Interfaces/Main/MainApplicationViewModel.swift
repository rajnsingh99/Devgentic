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
    @ObservedObject var agentStore: AgentStore
    
    let explorerViewModel = ExplorerViewModel()

    // MARK: - Voice Input Services
    private let audioEngineService: AudioEngineService
    private let speechRecognitionService: NativeSpeechRecognitionService
    
    private var cancellables = Set<AnyCancellable>()
    
    private var prefixForCurrentUtterance: String = ""

    // MARK: - Published State Properties
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID? {
        didSet {
            // When conversation changes, cancel any ongoing stream.
            if oldValue != selectedConversationID {
                cancelStreaming()
            }
            refreshChatMessages()
            loadBackendStateForSelectedConversation()
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
    
    // This property will now act as a "trigger" for the View's .task modifier.
    @Published var streamingTriggerID: UUID? = nil
    private var streamingTask: Task<Void, Never>?

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
         audioEngineService: AudioEngineService = AudioEngineService(),
         speechRecognitionService: NativeSpeechRecognitionService = NativeSpeechRecognitionService(),
         fileProcessorService: FileProcessorService = FileProcessorService()
    ) {
        self.persistenceService = persistenceService
        self.llmIntegrationStore = llmIntegrationStore
        self.agentStore = agentStore
        self.audioEngineService = audioEngineService
        self.speechRecognitionService = speechRecognitionService
        self.fileProcessorService = fileProcessorService
        
        self.backendOrchestrationService = BackendOrchestrationService(
            agentStore: agentStore,
            llmIntegrationStore: llmIntegrationStore,
            fileProcessorService: fileProcessorService
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
        streamingTask?.cancel()
    }
    
    private func setupBindings() {
        // ... (existing bindings are fine) ...
    }
    
    // MARK: - Message Sending Logic (Refactored for Streaming)
    
    func sendMessage(attributedString: NSAttributedString) {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        
        let plainUserQueryFromEditor = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !isSending else {
            logger.warning("[sendMessage] Message sending already in progress. Ignoring new request.")
            return
        }
        guard !plainUserQueryFromEditor.isEmpty || !attachedFiles.isEmpty else {
            if !self.userInput.isEmpty { self.userInput = "" }
            return
        }

        self.isSending = true
        
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
        }
        currentChatMessages.append(userMessage)
        
        // This is the crucial change. We set a unique ID to trigger the .task in the View.
        self.streamingTriggerID = userMessage.id
    }
    
    /// This function is now called by the View's task to get the data stream.
    func streamResponse(conversationID: UUID, userQuery: String, files: [FileSystemItem]) -> AsyncThrowingStream<String, Error> {
        let context = TraceContext()
        logger.info("🚀 [streamResponse] Providing stream to consumer. traceID: \(context.traceID)")
        return backendOrchestrationService.streamMessage(
            conversationID: conversationID,
            userQuery: userQuery,
            files: files,
            context: context
        )
    }

    /// This function is called by the View's task when streaming is complete.
    func finalizeStreaming(conversationID: UUID, fullText: String, error: Error?) {
        let finalContent: MessageContent = if let error = error {
            .error(title: "Streaming Error", details: error.localizedDescription)
        } else {
            .markdownText(fullText)
        }
        
        let finalMessage = ChatMessage(
            conversationId: conversationID,
            sender: .agent,
            content: finalContent
        )

        if let targetEntity = persistenceService.getConversation(withId: conversationID) {
            Task {
                await persistenceService.addMessage(finalMessage, to: targetEntity)
            }
        }
        currentChatMessages.append(finalMessage)
        
        resetSendingState()
    }
    
    private func resetSendingState() {
        self.userInput = ""
        self.clearAttachedFiles()
        self.isSending = false
        self.streamingTriggerID = nil // Reset the trigger
        logger.info("✅ [Request Finished] Sending state has been reset.")
    }

    func cancelStreaming() {
        if streamingTriggerID != nil {
            logger.info("Streaming cancelled by user.")
            resetSendingState()
        }
    }
    
    private func createUserMessage(conversationID: UUID, query: String, files: [FileSystemItem]) -> ChatMessage {
        // ... (this function remains the same) ...
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
    
    // MARK: - Other methods (unchanged)
    
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
            return
        }

        let conversation = conversationEntity.toConversationStruct()
        let backendType = conversation.backendType ?? .none
        let backendEntityId = conversation.backendEntityId

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
        logger.info("Loaded backend state for conversation \(conversationID.uuidString): \(backendType.rawValue)")
    }

    private func updateBackendForCurrentConversation() {
        guard let conversationID = selectedConversationID else { return }

        var entityId: UUID?
        switch selectedBackend {
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
    }
    
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
