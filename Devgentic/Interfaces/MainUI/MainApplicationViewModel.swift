//
//  MainApplicationViewModel
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
    private let store = ConversationStore.shared
    
    private let fileProcessorService: FileProcessorService
    private let messageAssemblerService: MessageAssemblerService
    private let llmCommunicator: LLMCommunicatorProtocol

    // MARK: - Use the OllamaService singleton
    @ObservedObject var ollamaService = OllamaService.shared
    @ObservedObject var ollamaProfileStore: OllamaProfileStore
    @ObservedObject var agentStore: AgentStore

    // MARK: - Voice Input Services
    private let audioEngineService: AudioEngineService
    private let speechRecognitionService: NativeSpeechRecognitionService
    
    private var cancellables = Set<AnyCancellable>()
    
    private var prefixForCurrentUtterance: String = ""

    // MARK: - Published State Properties (UI and Core Chat Logic)
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?
    @Published var isSending: Bool = false
    @Published var userInput: String = ""
    @Published var isSidebarCollapsed: Bool = true
    @Published var showSettings: Bool = false
    @Published var showPromptLibrary: Bool = false
    @Published var selectedSettingsSection: SettingsSection = .general {
        didSet {
            // Use the shared instance to clear statuses
            OllamaService.shared.clearAllModelActionStatuses()
        }
    }
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil
    @Published var isUserMessagesOnlyFilterActive: Bool = false
    @Published var attachedFiles: [FileSystemItem] = []
    @Published var voiceInputState: VoiceInputState = .idle
    
    @Published var selectedAgentID: UUID? {
        didSet {
            agentStore.setActiveAgent(withId: selectedAgentID)
            if let agentId = selectedAgentID {
                UserDefaults.standard.set(agentId.uuidString, forKey: SettingsKeys.selectedAgentID)
                logger.info("Selected Agent ID set to: \(agentId.uuidString)")
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKeys.selectedAgentID)
                logger.info("Selected Agent ID cleared.")
            }
        }
    }

    // --- Settings Properties ---
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
    init(ollamaProfileStore: OllamaProfileStore,
         agentStore: AgentStore = AgentStore(),
         audioEngineService: AudioEngineService = AudioEngineService(),
         speechRecognitionService: NativeSpeechRecognitionService = NativeSpeechRecognitionService(),
         fileProcessorService: FileProcessorService = FileProcessorService(),
         messageAssemblerService: MessageAssemblerService? = nil,
         llmCommunicator: LLMCommunicatorProtocol? = nil
    ) {
        self.ollamaProfileStore = ollamaProfileStore
        self.agentStore = agentStore
        self.audioEngineService = audioEngineService
        self.speechRecognitionService = speechRecognitionService
        
        self.fileProcessorService = fileProcessorService
        self.messageAssemblerService = messageAssemblerService ?? MessageAssemblerService(fileProcessorService: self.fileProcessorService)
        
        self.llmCommunicator = llmCommunicator ?? DefaultLLMCommunicator(fileProcessorService: self.fileProcessorService)

        self.conversations = store.getAllConversations()
        validateSelectedConversation()
        observeConversationStoreChanges()
        
        logger.info("MainApplicationViewModel initialized. Loaded \(self.conversations.count) conversations.")
        
        if let storedAgentIDString = UserDefaults.standard.string(forKey: SettingsKeys.selectedAgentID),
           let storedAgentUUID = UUID(uuidString: storedAgentIDString),
           agentStore.agents.contains(where: { $0.id == storedAgentUUID }) {
            self.selectedAgentID = storedAgentUUID
        } else {
            self.selectedAgentID = agentStore.agents.first(where: { $0.isActive })?.id ?? agentStore.agents.first?.id
        }
        
        checkVoiceInputPermissionsAndAvailability()
        
        self.speechRecognitionService.$speechRecognizerAvailable
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                self?.handleSpeechRecognizerAvailabilityChange(isAvailable: available)
            }
            .store(in: &cancellables)

        // MARK: - Corrected: Centralized logic to sync OllamaService on profile change
        ollamaProfileStore.$selectedProfileID
            .combineLatest(ollamaProfileStore.$profiles)
            .compactMap { selectedID, profiles -> OllamaProfileModel? in // Explicit return type
                guard let id = selectedID else { return nil }
                return profiles.first { $0.id == id }
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            // MARK: - Corrected: Added explicit type annotation to fix inference errors
            .sink { [weak self] (newProfile: OllamaProfileModel) in
                guard let self = self else { return }
                logger.info("MainApplicationViewModel: Active profile changed to '\(newProfile.profileName)'. Updating OllamaService.")
                
                let service = OllamaService.shared
                service.ollamaBaseURL = newProfile.baseURL
                service.llmModelName = newProfile.llmModelName
                
                Task {
                    await service.checkServerStatusAndUpdateModels()
                }
            }
            .store(in: &cancellables)
    }
 
    convenience init() {
        let fpService = FileProcessorService()
        let maService = MessageAssemblerService(fileProcessorService: fpService)
        let comm = DefaultLLMCommunicator(fileProcessorService: fpService)
        let ollamaProfileStore = OllamaProfileStore()
        let agentStore = AgentStore()

        self.init(
            ollamaProfileStore: ollamaProfileStore,
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

    private func observeConversationStoreChanges() {
        store.$conversations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updatedConversationsFromStore in
                self?.conversations = updatedConversationsFromStore
                self?.validateSelectedConversation()
            }
            .store(in: &cancellables)
    }
    
    private func validateSelectedConversation() {
        if let currentSelectedID = selectedConversationID {
            if !conversations.contains(where: { $0.id == currentSelectedID }) {
                selectedConversationID = conversations.first?.id
            }
        } else if !conversations.isEmpty {
            selectedConversationID = conversations.first?.id
        }
    }
    
    // MARK: - Actions / Methods (UI Toggles, Chat Management)
    func toggleUserMessagesFilter() {
        isUserMessagesOnlyFilterActive.toggle()
    }
    
    func startNewConversation() {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        userInput = ""
        clearAttachedFiles()
        
        let currentConversations = store.getAllConversations()
        if let mostRecentConv = currentConversations.first(where: {$0.messages.isEmpty}) {
            selectedConversationID = mostRecentConv.id
        } else {
            _ = createAndSelectNewConversation()
        }
        isUserMessagesOnlyFilterActive = false
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        store.addConversation(newConversation)
        selectedConversationID = newConversation.id
        isUserMessagesOnlyFilterActive = false
        return newConversation.id
    }

    // MARK: - Message Sending Logic
    func sendMessage(attributedString: NSAttributedString) {
        if showSettings { showSettings = false }
        if showPromptLibrary { showPromptLibrary = false }
        
        let plainUserQueryFromEditor = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let filesToProcess = self.attachedFiles
        
        guard !isSending else { return }
        guard !plainUserQueryFromEditor.isEmpty || !filesToProcess.isEmpty else {
            if !self.userInput.isEmpty { self.userInput = "" }
            return
        }

        if voiceInputState.isSessionActive {
            self.stopVoiceCaptureAndFinalize(customError: nil)
        }

        var conversationIDToUse: UUID
        if let currentID = selectedConversationID, store.getConversation(withId: currentID) != nil {
            conversationIDToUse = currentID
        } else {
            conversationIDToUse = createAndSelectNewConversation()
        }
        
        guard var targetConversationForUserMessage = store.getConversation(withId: conversationIDToUse) else {
            logger.error("CRITICAL: Could not find conversation object for ID: \(conversationIDToUse.uuidString) before sending user message.")
            isSending = false
            return
        }

        if !plainUserQueryFromEditor.isEmpty {
            let userMessageForDisplay = ChatMessage(conversationId: conversationIDToUse, sender: .user, content: .plainText(plainUserQueryFromEditor))
            targetConversationForUserMessage.messages.append(userMessageForDisplay)
            targetConversationForUserMessage.timestamp = Date()
            store.updateConversation(targetConversationForUserMessage)
        }
        
        self.isSending = true

        Task {
            let agentMessagesForThisTurn = await assembleAndSend(
                conversationID: conversationIDToUse,
                userQuery: plainUserQueryFromEditor,
                files: filesToProcess
            )

            if !agentMessagesForThisTurn.isEmpty {
                guard var targetConversation = store.getConversation(withId: conversationIDToUse) else {
                    self.isSending = false
                    return
                }
                targetConversation.messages.append(contentsOf: agentMessagesForThisTurn)
                targetConversation.timestamp = Date()
                store.updateConversation(targetConversation)
            }
            
            self.userInput = ""
            self.clearAttachedFiles()
            self.isSending = false
        }
    }
    
    private func assembleAndSend(conversationID: UUID, userQuery: String, files: [FileSystemItem]) async -> [ChatMessage] {
        var generatedMessages: [ChatMessage] = []
        
        let currentOllamaProfile = self.ollamaProfileStore.currentProfile
        
        let (messageParts, processingWarnings) = await messageAssemblerService.assembleMessageParts(
            userQuery: userQuery,
            attachedFiles: files,
            for: self.selectedBackend,
            ollamaModelDetails: OllamaModelInfo(name: currentOllamaProfile?.llmModelName ?? "", displayName: "", sizeDescription: ""),
            maxInlineCharsOllama: currentOllamaProfile?.maxInlineChars ?? 5000,
            maxFilesForOllama: currentOllamaProfile?.maxAttachedFiles ?? 5,
            textFileStrategy: currentOllamaProfile?.textFileInclusionStrategy ?? .preferInlining,
            imageHandlingStrategy: currentOllamaProfile?.imageHandlingStrategy ?? .includePathWithWarning,
            binaryFileHandlingStrategy: currentOllamaProfile?.binaryFileHandlingStrategy ?? .includePathWithWarning
        )

        if !processingWarnings.isEmpty {
            let warningContent = MessageContent.error(title: "File Processing Notice", details: "- " + processingWarnings.joined(separator: "\n- "))
            generatedMessages.append(ChatMessage(conversationId: conversationID, sender: .agent, content: warningContent))
        }

        // MARK: - Corrected: Use pattern matching to filter parts
        let processableParts = messageParts.filter { part in
            if let fileRep = part.fileRepresentation {
                if case .unprocessable = fileRep {
                    return false
                }
            }
            return true
        }

        // MARK: - Corrected: Check for .file case correctly
        if !processableParts.contains(where: { !$0.content.isEmpty || $0.type == .file }) {
            logger.info("No processable content to send to LLM.")
            return generatedMessages
        }
        
        if self.selectedBackend == .ollama {
            if ollamaService.serverStatus != .connected {
                let errorMsg = "Cannot send message: Ollama server is not connected. Status: \(ollamaService.serverStatus.description) at \(ollamaService.ollamaBaseURL)"
                let errorContent = MessageContent.error(title: "Connection Error", details: errorMsg)
                generatedMessages.append(ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent))
                return generatedMessages
            }
        }
        
        let baseBackendConfig = self.determineBackendConfiguration()
        var finalPartsToSend = processableParts
        if showContextArea, let filePath = activeContextFilePath, !filePath.isEmpty {
             finalPartsToSend.insert(.text("Context File: \(filePath)\n\n"), at: 0)
        }

        do {
            let llmResponse = try await self.llmCommunicator.sendMessage(parts: finalPartsToSend, to: self.selectedBackend, config: baseBackendConfig)
            generatedMessages.append(contentsOf: llmResponse.content.map { ChatMessage(conversationId: conversationID, sender: .agent, content: $0) })
            if let commError = llmResponse.error {
                let errorContent = MessageContent.error(title: "LLM Error", details: commError.localizedDescription)
                generatedMessages.append(ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent))
            }
        } catch {
            let errorText = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: self.selectedBackend)
            let errorContent = MessageContent.error(title: "Communication Error", details: errorText)
            generatedMessages.append(ChatMessage(conversationId: conversationID, sender: .agent, content: errorContent))
            if selectedBackend == .ollama, (error as? URLError)?.isConnectionError == true {
                ollamaService.serverStatus = .disconnected
            }
        }
        
        return generatedMessages
    }


    private func determineBackendConfiguration() -> BackendConfiguration {
        if let currentProfile = ollamaProfileStore.currentProfile, self.selectedBackend == .ollama {
            let advancedOptions: [String: Any] = [
                "temperature": currentProfile.temperature, "top_k": currentProfile.topK,
                "top_p": currentProfile.topP, "repeat_penalty": currentProfile.repeatPenalty,
                "num_ctx": currentProfile.contextWindowSize, "num_gpu": currentProfile.gpuLayers
            ]
            let modelName = ollamaService.llmModelName.isEmpty ? "default_model_name" : ollamaService.llmModelName
            let initialPayload: [String: Any] = ["model": modelName, "stream": false, "options": advancedOptions]
            return BackendConfiguration(url: ollamaService.ollamaBaseURL, endpoint: "/api/generate", payload: initialPayload)
        
        } else { // BackendType is .agent
            var agentConfigItems: [[String: Any]] = []
            if let selectedAgentId = selectedAgentID,
               let selectedAgent = agentStore.agents.first(where: { $0.id == selectedAgentId }) {
                
                var agentConfig: [String: Any] = [
                    "base_url": selectedAgent.baseURL,
                    "tools": selectedAgent.selectedAgentTool == "None" ? [] : [selectedAgent.selectedAgentTool]
                ]
                
                if let linkedOllamaProfileID = selectedAgent.linkedOllamaProfileID,
                   let linkedOllamaProfile = ollamaProfileStore.profiles.first(where: { $0.id == linkedOllamaProfileID }) {
                    agentConfig["ollama_url"] = linkedOllamaProfile.baseURL
                    agentConfig["model"] = linkedOllamaProfile.llmModelName
                }
                agentConfigItems.append(agentConfig)

                let initialPayload: [String: Any] = ["strategy": self.agentDelegationStrategy, "agent_config": agentConfigItems]
                return BackendConfiguration(url: selectedAgent.baseURL, endpoint: "/chat", payload: initialPayload)
            } else {
                let initialPayload: [String: Any] = ["strategy": self.agentDelegationStrategy]
                return BackendConfiguration(url: self.agentBaseURL, endpoint: "/chat", payload: initialPayload)
            }
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
        store.deleteConversation(withId: conversationID)
        if selectedConversationID == conversationID {
            selectedConversationID = conversations.first(where: { $0.id != conversationID })?.id
        }
    }

    func deleteMultipleConversations(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        store.deleteConversations(withIds: ids)
        if let currentSelected = selectedConversationID, ids.contains(currentSelected) {
            selectedConversationID = conversations.first(where: { !ids.contains($0.id) })?.id
        }
    }
    
    func deleteConversationsInGroup(groupKey: String) {
        let idsToDelete = Set(self.conversations.filter { self.groupKey(for: $0.timestamp) == groupKey }.map { $0.id })
        if idsToDelete.isEmpty { return }
        deleteMultipleConversations(ids: idsToDelete)
    }
    
    func renameConversation(conversationID: UUID, newTitle: String) {
        guard var conversationToRename = store.getConversation(withId: conversationID) else { return }
        let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        conversationToRename.userDefinedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
        store.updateConversation(conversationToRename)
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

extension VoiceInputState {
    var isSessionActive: Bool {
        switch self {
        case .recording, .processing:
            return true
        default:
            return false
        }
    }
    
    var canTransitionToError: Bool {
        switch self {
        case .permissionsDeniedMic, .permissionsDeniedSpeech:
            return false
        default:
            return true
        }
    }
}
