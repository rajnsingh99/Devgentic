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

    @ObservedObject var ollamaService: OllamaService
    @ObservedObject var ollamaProfileStore: OllamaProfileStore
    @ObservedObject var agentStore: AgentStore // MARK: New: AgentStore dependency

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
            ollamaService.clearAllModelActionStatuses()
        }
    }
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil
    @Published var isUserMessagesOnlyFilterActive: Bool = false
    @Published var attachedFiles: [FileSystemItem] = []
    @Published var voiceInputState: VoiceInputState = .idle
    
    @Published var selectedAgentID: UUID? {
        didSet {
            // **[MODIFIED]** When the selected agent changes, update the active status in the store.
            agentStore.setActiveAgent(withId: selectedAgentID)
            
            // Save the selected agent ID so it persists across app launches
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
    // MARK: Note: agentBaseURL and agentDelegationStrategy are @AppStorage properties
    // For agent backend, the baseURL will primarily come from the selectedAgentID's Agent object.
    // agentDelegationStrategy is still used as a global setting.
    @AppStorage(SettingsKeys.agentBaseURL) var agentBaseURL: String = "http://127.0.0.1:8000" // Kept for potential fallback/initial value
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
    init(ollamaService: OllamaService,
         ollamaProfileStore: OllamaProfileStore,
         agentStore: AgentStore = AgentStore(), // MARK: New: Initialize AgentStore dependency
         audioEngineService: AudioEngineService = AudioEngineService(),
         speechRecognitionService: NativeSpeechRecognitionService = NativeSpeechRecognitionService(),
         fileProcessorService: FileProcessorService = FileProcessorService(),
         messageAssemblerService: MessageAssemblerService? = nil,
         llmCommunicator: LLMCommunicatorProtocol? = nil
    ) {
        self.ollamaService = ollamaService
        self.ollamaProfileStore = ollamaProfileStore
        self.agentStore = agentStore // MARK: New: Assign AgentStore
        self.audioEngineService = audioEngineService
        self.speechRecognitionService = speechRecognitionService
        
        self.fileProcessorService = fileProcessorService
        self.messageAssemblerService = messageAssemblerService ?? MessageAssemblerService(fileProcessorService: self.fileProcessorService)
        
        self.llmCommunicator = llmCommunicator ?? DefaultLLMCommunicator(fileProcessorService: self.fileProcessorService)

        self.conversations = store.getAllConversations()
        validateSelectedConversation()
        observeConversationStoreChanges()
        
        logger.info("MainApplicationViewModel initialized. Loaded \(self.conversations.count) conversations.")
        
        // Initialize selectedAgentID from UserDefaults or default to first active agent
        if let storedAgentIDString = UserDefaults.standard.string(forKey: SettingsKeys.selectedAgentID),
           let storedAgentUUID = UUID(uuidString: storedAgentIDString),
           agentStore.agents.contains(where: { $0.id == storedAgentUUID }) {
            self.selectedAgentID = storedAgentUUID
            logger.info("Initialized selectedAgentID from UserDefaults: \(storedAgentUUID.uuidString)")
        } else {
            // Default to the first active agent, or just the first agent if no active ones
            self.selectedAgentID = agentStore.agents.first(where: { $0.isActive })?.id ?? agentStore.agents.first?.id
            if let defaultAgentId = self.selectedAgentID {
                logger.info("Initialized selectedAgentID to default/first agent: \(defaultAgentId.uuidString)")
            } else {
                logger.warning("No agents found in AgentStore during MainApplicationViewModel initialization.")
            }
        }
        
        if let currentProfile = ollamaProfileStore.currentProfile {
            self.ollamaService.ollamaBaseURL = currentProfile.baseURL
            self.ollamaService.llmModelName = currentProfile.llmModelName
            logger.info("OllamaService initialized with profile: \(currentProfile.profileName), baseURL: \(currentProfile.baseURL), model: \(currentProfile.llmModelName)")
        } else {
            logger.warning("MainApplicationViewModel initialized without a selected Ollama profile.")
        }

        if selectedBackend == .ollama {
             // Initial check when app starts and Ollama is the selected backend.
             // The sink below will handle subsequent profile changes.
            Task {
                logger.debug("MainApplicationViewModel init: Ollama is selected backend. Triggering initial checkServerStatusAndUpdateModels.")
                await self.ollamaService.checkServerStatusAndUpdateModels()
            }
        }
        
        checkVoiceInputPermissionsAndAvailability()
        
        self.speechRecognitionService.$speechRecognizerAvailable
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] available in
                guard let self = self else { return }
                logger.info("Speech Recognizer availability changed to: \(available) (from sink)")
                if !available {
                    if self.voiceInputState == .recording || self.voiceInputState == .processing {
                        self.stopVoiceCaptureAndFinalize(customError: "Speech recognizer became unavailable.")
                    }
                    if self.voiceInputState != .permissionsDeniedMic && self.voiceInputState != .permissionsDeniedSpeech {
                        self.voiceInputState = .speechRecognitionUnavailable
                    }
                } else {
                    if self.voiceInputState == .speechRecognitionUnavailable || self.voiceInputState == .idle || self.voiceInputState == .error("Speech recognizer became unavailable.") {
                         logger.info("Speech recognizer became available. Re-checking permissions and overall availability.")
                         self.checkVoiceInputPermissionsAndAvailability()
                    }
                }
            }
            .store(in: &cancellables)

        // Observe changes to the selected profile in OllamaProfileStore
        ollamaProfileStore.$selectedProfileID
            .compactMap { $0 }
            // .removeDuplicates() // Consider if needed; @Published usually handles distinct values.
            .sink { [weak self] newSelectedID in
                guard let self = self,
                      let newProfile = self.ollamaProfileStore.profiles.first(where: { $0.id == newSelectedID }) else {
                    logger.warning("MainApplicationViewModel: Sink for selectedProfileID received nil or profile not found for ID: \(newSelectedID.uuidString )")
                    return
                }
                
                let oldOllamaServiceBaseURL = self.ollamaService.ollamaBaseURL
                let oldOllamaServiceModelName = self.ollamaService.llmModelName

                let baseURLChanged = oldOllamaServiceBaseURL != newProfile.baseURL
                let modelNameChanged = oldOllamaServiceModelName != newProfile.llmModelName

                if baseURLChanged {
                    logger.info("MainApplicationViewModel: Selected Ollama profile changed to '\(newProfile.profileName)'. BaseURL changed from '\(oldOllamaServiceBaseURL)' to '\(newProfile.baseURL)'. Updating OllamaService.")
                    self.ollamaService.ollamaBaseURL = newProfile.baseURL
                    self.ollamaService.llmModelName = newProfile.llmModelName // Also update model name with baseURL change

                    if self.selectedBackend == .ollama {
                        Task {
                            logger.debug("MainApplicationViewModel: Triggering checkServerStatusAndUpdateModels due to profile/baseURL change.")
                            await self.ollamaService.checkServerStatusAndUpdateModels()
                        }
                    }
                } else if modelNameChanged {
                    // BaseURL is the same, but model name changed.
                    logger.info("MainApplicationViewModel: Selected Ollama profile '\(newProfile.profileName)'. LLM Model changed from '\(oldOllamaServiceModelName)' to '\(newProfile.llmModelName)'. BaseURL '\(newProfile.baseURL)' remains the same.")
                    self.ollamaService.llmModelName = newProfile.llmModelName
                    // No need for a full server check if the base URL is the same.
                    // The LocalAISettingsView's picker directly binds to the profile's model name.
                    // OllamaService.llmModelName is updated here to keep it in sync for other operations.
                } else {
                    logger.info("MainApplicationViewModel: Selected Ollama profile '\(newProfile.profileName)'. BaseURL and LLM Model are already up-to-date in OllamaService. No refresh triggered by this sink.")
                }
            }
            .store(in: &cancellables)
    }
 
    convenience init() {
        let fpService = FileProcessorService()
        let maService = MessageAssemblerService(fileProcessorService: fpService)
        let comm = DefaultLLMCommunicator(fileProcessorService: fpService)
        let ollamaService = OllamaService()
        let ollamaProfileStore = OllamaProfileStore()
        let agentStore = AgentStore() // MARK: New: Initialize AgentStore for convenience init

        self.init(ollamaService: ollamaService,
                  ollamaProfileStore: ollamaProfileStore,
                  agentStore: agentStore, // MARK: New: Pass AgentStore
                  fileProcessorService: fpService,
                  messageAssemblerService: maService,
                  llmCommunicator: comm)
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
                guard let self = self else { return }
                self.conversations = updatedConversationsFromStore
                self.validateSelectedConversation()
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
        
        logger.debug("""
            sendMessage called. Backend: \(String(describing: self.selectedBackend.rawValue)), isSending: \(self.isSending),
            Plain User Query: \"\(plainUserQueryFromEditor.prefix(50))...\", Attached Files Count: \(filesToProcess.count)
            """)

        guard !isSending else {
            logger.warning("sendMessage aborted: Already sending.")
            return
        }
        guard !plainUserQueryFromEditor.isEmpty || !filesToProcess.isEmpty else {
            logger.info("sendMessage aborted: Input empty and no files attached.")
            if !self.userInput.isEmpty { self.userInput = "" }
            return
        }

        switch self.voiceInputState {
        case .recording, .processing, .error:
            logger.info("sendMessage: Voice input state is \(self.voiceInputState.description). Finalizing session and resetting to available.")
            self.stopVoiceCaptureAndFinalize(customError: nil)
        default:
            logger.info("sendMessage: Voice input state is \(self.voiceInputState.description). No mic finalization action needed by send.")
            break
        }

        var conversationIDToUse: UUID
        if let currentID = selectedConversationID, store.getConversation(withId: currentID) != nil {
            conversationIDToUse = currentID
        } else {
            logger.info("No valid conversation selected or found. Creating a new one for this message.")
            conversationIDToUse = createAndSelectNewConversation()
        }
        
        guard var targetConversationForUserMessage = store.getConversation(withId: conversationIDToUse) else {
            logger.error("CRITICAL: Could not find conversation object for ID: \(conversationIDToUse.uuidString) before sending user message.")
            isSending = false
            return
        }

        if !plainUserQueryFromEditor.isEmpty {
            let userMessageForDisplay = ChatMessage(
                conversationId: conversationIDToUse,
                sender: .user,
                content: .plainText(plainUserQueryFromEditor)
            )
            targetConversationForUserMessage.messages.append(userMessageForDisplay)
            targetConversationForUserMessage.timestamp = Date()
            store.updateConversation(targetConversationForUserMessage)
        } else if filesToProcess.isEmpty {
            logger.info("sendMessage: No text and no files to send. Aborting actual send logic.")
            isSending = false
            if !self.userInput.isEmpty { self.userInput = "" }
            return
        }
        
        self.isSending = true

        Task {
            var agentMessagesForThisTurn: [ChatMessage] = []
            
            let currentOllamaModelName = self.ollamaProfileStore.currentProfile?.llmModelName ?? "gemma:2b"
            var ollamaModelInfo: OllamaModelInfo? = nil
            if !currentOllamaModelName.isEmpty {
                ollamaModelInfo = OllamaModelInfo(name: currentOllamaModelName, displayName: currentOllamaModelName, sizeDescription: "N/A")
            }

            let (messageParts, processingWarnings) = await messageAssemblerService.assembleMessageParts(
                userQuery: plainUserQueryFromEditor,
                attachedFiles: filesToProcess,
                for: self.selectedBackend,
                ollamaModelDetails: ollamaModelInfo,
                maxInlineCharsOllama: self.ollamaProfileStore.currentProfile?.maxInlineChars ?? 5000,
                maxFilesForOllama: self.ollamaProfileStore.currentProfile?.maxAttachedFiles ?? 5,
                textFileStrategy: self.ollamaProfileStore.currentProfile?.textFileInclusionStrategy ?? .preferInlining,
                imageHandlingStrategy: self.ollamaProfileStore.currentProfile?.imageHandlingStrategy ?? .includePathWithWarning,
                binaryFileHandlingStrategy: self.ollamaProfileStore.currentProfile?.binaryFileHandlingStrategy ?? .includePathWithWarning
            )

            if !processingWarnings.isEmpty {
                logger.warning("File processing warnings: \(processingWarnings.joined(separator: "; "))")
                let warningTitle = "File Processing Notice"
                let details = processingWarnings.joined(separator: "\n- ")
                let warningContent = MessageContent.error(title: warningTitle, details: "- " + details)
                let warningMessage = ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: warningContent)
                agentMessagesForThisTurn.append(warningMessage)
            }

            let processableParts = messageParts.filter { part in
                if let fileRep = part.fileRepresentation {
                    if case .unprocessable = fileRep { return false }
                }
                return true
            }

            let hasTextToSend = processableParts.contains { $0.type == .text && !$0.content.isEmpty }
            let hasFilesToSend = processableParts.contains { $0.type == .file }

            if !hasTextToSend && !hasFilesToSend {
                logger.info("No processable content to send to LLM after assembly and filtering.")
            } else {
                if self.selectedBackend == .ollama {
                    // Check server status before sending if Ollama is the backend
                    // The checkServerStatusAndUpdateModels in the sink for selectedProfileID handles initial/profile-switch connection checks.
                    // This is an additional check right before sending.
                    if ollamaService.serverStatus != .connected { // Simplified: if not connected, try to check again.
                        logger.info("Ollama status is \(String(describing: self.ollamaService.serverStatus.rawValue)), re-checking before sending.")
                        await ollamaService.checkServerStatusAndUpdateModels() // This uses the service's current baseURL
                    }

                    if ollamaService.serverStatus != .connected {
                        let errorMsg = "Cannot send message: Ollama server is not connected. Status: \(String(describing: self.ollamaService.serverStatus.rawValue)) at \(self.ollamaService.ollamaBaseURL)"
                        logger.error("\(errorMsg)")
                        let errorMessageContent = MessageContent.error(title: "Connection Error", details: errorMsg)
                        let errorChatMessage = ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: errorMessageContent)
                        agentMessagesForThisTurn.append(errorChatMessage)
                    }
                }
                
                if !agentMessagesForThisTurn.contains(where: { message in
                     if case .error = message.content { return true }
                     return false
                }) {
                    let baseBackendConfig = self.determineBackendConfiguration(message: "")
                    var finalPartsToSend = processableParts
                    if showContextArea, let filePath = activeContextFilePath, !filePath.isEmpty {
                         let contextText = "Context File: \(filePath)\n\nUser Message and Attached Files:\n"
                         finalPartsToSend.insert(.text(contextText), at: 0)
                         logger.debug("Prepended active context file path to message parts: \(filePath)")
                    }

                    do {
                        logger.debug("Calling LLM Communicator for backend: \(self.selectedBackend.rawValue)")
                        
                        let llmResponse = try await self.llmCommunicator.sendMessage(
                            parts: finalPartsToSend,
                            to: self.selectedBackend,
                            config: baseBackendConfig
                        )

                        for contentBlock in llmResponse.content {
                            let agentMessage = ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: contentBlock)
                            agentMessagesForThisTurn.append(agentMessage)
                        }
                        if let commError = llmResponse.error {
                            logger.error("LLMCommunicator reported an error in response: \(commError.localizedDescription)")
                            let errorContent = MessageContent.error(title: "LLM Error", details: commError.localizedDescription)
                            agentMessagesForThisTurn.append(ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: errorContent))
                        }

                    } catch {
                        logger.error("Error from LLMCommunicator.sendMessage: \(error.localizedDescription)")
                        let errorText = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: self.selectedBackend)
                        let errorMessageContent = MessageContent.error(title: "Communication Error", details: errorText)
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
            }

            if !agentMessagesForThisTurn.isEmpty {
                guard var targetConversationForAgentMessages = store.getConversation(withId: conversationIDToUse) else {
                    logger.error("CRITICAL: Could not find conversation for ID: \(conversationIDToUse.uuidString) to add agent messages.")
                    self.isSending = false
                    return
                }
                for msg in agentMessagesForThisTurn { targetConversationForAgentMessages.messages.append(msg) }
                targetConversationForAgentMessages.timestamp = Date()
                store.updateConversation(targetConversationForAgentMessages)
                logger.debug("Appended \(agentMessagesForThisTurn.count) agent/system message(s) to conversation \(conversationIDToUse.uuidString) via store.")
            } else if isSending {
                 logger.warning("sendMessage Task finished but generated no agent/system messages to handle.")
            }
            
            await MainActor.run {
                self.userInput = ""
                self.clearAttachedFiles()
                self.isSending = false
            }
        }
    }


    private func determineBackendConfiguration(message: String) -> BackendConfiguration {
        if let currentProfile = ollamaProfileStore.currentProfile, self.selectedBackend == .ollama {
            let advancedOptions: [String: Any] = [
                "temperature": currentProfile.temperature,
                "top_k": currentProfile.topK,
                "top_p": currentProfile.topP,
                "repeat_penalty": currentProfile.repeatPenalty,
                "num_ctx": currentProfile.contextWindowSize,
                "num_gpu": currentProfile.gpuLayers
            ]
            // Use ollamaService.llmModelName as it's kept in sync with the active profile's model
            let modelName = ollamaService.llmModelName.isEmpty ? "default_model_name" : ollamaService.llmModelName
            let initialPayload: [String: Any] = [
                "model": modelName, "stream": false, "options": advancedOptions
            ]
            // Use ollamaService.ollamaBaseURL as it's kept in sync with the active profile's URL
            return BackendConfiguration(
                url: ollamaService.ollamaBaseURL,
                endpoint: "/api/generate",
                payload: initialPayload
            )
        } else { // BackendType is .agent
            // MARK: New: Use the selected agent's configuration
            var agentConfigItems: [[String: Any]] = []
            if let selectedAgentId = selectedAgentID,
               let selectedAgent = agentStore.agents.first(where: { $0.id == selectedAgentId }) {
                
                var agentConfig: [String: Any] = [
                    "base_url": selectedAgent.baseURL,
                    "tools": selectedAgent.selectedAgentTool == "None" ? [] : [selectedAgent.selectedAgentTool] // Send as array of tools
                ]
                
                if let linkedOllamaProfileID = selectedAgent.linkedOllamaProfileID,
                   let linkedOllamaProfile = ollamaProfileStore.profiles.first(where: { $0.id == linkedOllamaProfileID }) {
                    agentConfig["ollama_url"] = linkedOllamaProfile.baseURL
                    agentConfig["model"] = linkedOllamaProfile.llmModelName
                    logger.debug("Agent configuration will include linked Ollama profile: \(linkedOllamaProfile.profileName) (\(linkedOllamaProfile.llmModelName))")
                } else {
                    logger.debug("Selected agent '\(selectedAgent.name)' has no Ollama profile linked.")
                }
                agentConfigItems.append(agentConfig)
                logger.info("DetermineBackendConfiguration: Using selected agent '\(selectedAgent.name)' config: \(agentConfig)")

                let initialPayload: [String: Any] = [
                    "strategy": self.agentDelegationStrategy,
                    "agent_config": agentConfigItems // Pass as a list as expected by backend model
                ]
                return BackendConfiguration(
                    url: selectedAgent.baseURL, // Use the selected agent's baseURL
                    endpoint: "/chat",
                    payload: initialPayload
                )
            } else {
                // Fallback if no agent is selected or found.
                // This might indicate an issue if the app expects an agent to always be selected.
                logger.warning("No agent selected or found for agent backend. Using default agentBaseURL and delegation strategy.")
                let initialPayload: [String: Any] = [
                    "strategy": self.agentDelegationStrategy
                ]
                return BackendConfiguration(
                    url: self.agentBaseURL, // Fallback to @AppStorage agentBaseURL
                    endpoint: "/chat",
                    payload: initialPayload
                )
            }
        }
    }
    
    // MARK: - Voice Input Methods
    func checkVoiceInputPermissionsAndAvailability() {
        logger.info("Checking voice input permissions and availability...")
        
        if self.voiceInputState != .requestingPermissions {
             self.voiceInputState = .requestingPermissions
        }

        let currentMicStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.debug("Current microphone permission status (synchronous check): \(String(describing: currentMicStatus.rawValue))")
        switch currentMicStatus {
        case .authorized:
            logger.info("Microphone permission is already granted.")
            checkSpeechRecognitionPermission()
        case .denied:
            logger.warning("Microphone permission was previously denied by user or policy.")
            self.voiceInputState = .permissionsDeniedMic
        case .restricted:
            logger.warning("Microphone permission is restricted.")
            self.voiceInputState = .permissionsDeniedMic
        case .notDetermined:
            logger.info("Microphone permission is .notDetermined. Requesting via audioEngineService...")
            audioEngineService.requestMicrophonePermission { [weak self] grantedByRequestCallback in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if grantedByRequestCallback {
                        logger.info("audioEngineService.requestMicrophonePermission callback returned: GRANTED. Re-checking speech permission.")
                        self.checkSpeechRecognitionPermission()
                    } else {
                        logger.warning("Microphone permission denied by user or system (from callback).")
                        self.voiceInputState = .permissionsDeniedMic
                    }
                }
            }
        @unknown default:
            logger.error("Unknown microphone permission status: \(String(describing: currentMicStatus.rawValue))")
            self.voiceInputState = .error("Unknown microphone permission state.")
        }
    }

    private func checkSpeechRecognitionPermission() {
        logger.info("Checking speech recognition permission...")
        let currentSpeechAuthStatus = SFSpeechRecognizer.authorizationStatus()
        logger.debug("Current speech recognition status (synchronous check): \(String(describing: currentSpeechAuthStatus.rawValue))")
        
        switch currentSpeechAuthStatus {
        case .authorized:
            logger.info("Speech recognition permission already authorized.")
            if self.speechRecognitionService.speechRecognizerAvailable {
                logger.info("Speech recognizer is available. Setting state to .available.")
                self.voiceInputState = .available
            } else {
                logger.warning("Speech recognizer is NOT available (e.g. no network for server-based).")
                self.voiceInputState = .speechRecognitionUnavailable
            }
        case .denied:
            logger.warning("Speech recognition permission previously denied.")
            self.voiceInputState = .permissionsDeniedSpeech
        case .restricted:
            logger.warning("Speech recognition permission restricted.")
            self.voiceInputState = .error("Speech recognition restricted.")
        case .notDetermined:
            logger.info("Speech recognition permission .notDetermined. Requesting via speechRecognitionService...")
            speechRecognitionService.requestSpeechRecognitionPermission { [weak self] statusAfterRequestCallback in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    logger.info("Callback from speechRecognitionService.requestSpeechRecognitionPermission. New status: \(String(describing: statusAfterRequestCallback.rawValue))")
                    switch statusAfterRequestCallback {
                    case .authorized:
                        if self.speechRecognitionService.speechRecognizerAvailable {
                            self.voiceInputState = .available
                        } else {
                            self.voiceInputState = .speechRecognitionUnavailable
                        }
                    case .denied:
                        self.voiceInputState = .permissionsDeniedSpeech
                    case .restricted:
                        self.voiceInputState = .error("Speech recognition restricted.")
                    case .notDetermined:
                        self.voiceInputState = .error("Could not determine speech permission after request.")
                    @unknown default:
                        self.voiceInputState = .error("Unknown speech permission state post-request.")
                    }
                }
            }
        @unknown default:
            logger.error("Unknown initial speech recognition authorization status: \(String(describing: currentSpeechAuthStatus.rawValue))")
            self.voiceInputState = .error("Unknown speech permission state.")
        }
    }

    func toggleVoiceInput() {
        logger.info("Toggle voice input button tapped. Current voiceInputState: \(self.voiceInputState.description), UserInput empty: \(self.userInput.isEmpty)")
        switch self.voiceInputState {
        case .idle, .available:
            if userInput.isEmpty {
                logger.info("Attempting to start voice capture (userInput is empty).")
                startVoiceCapture()
            } else {
                logger.info("Voice input attempted but userInput is not empty. Mic activation prevented.")
            }
        case .recording:
            logger.info("Attempting to stop voice capture (from toggle).")
            stopVoiceCaptureAndFinalize(customError: nil)
        case .requestingPermissions:
            logger.info("Voice input busy (requestingPermissions). Ignoring toggle.")
            break
        case .processing:
             logger.info("Voice input busy (processing). User toggled to stop. Finalizing.")
             stopVoiceCaptureAndFinalize(customError: nil)
             break
        case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error:
            logger.info("Permissions issue or error state (\(self.voiceInputState.description)). Re-checking permissions on toggle.")
            checkVoiceInputPermissionsAndAvailability()
        }
    }

    private func startVoiceCapture() {
        logger.info("startVoiceCapture: Entered method.")

        guard userInput.isEmpty else {
            logger.error("startVoiceCapture: Aborted. Attempted to start with non-empty input. UserInput: '\(self.userInput.prefix(50))'")
            if self.voiceInputState == .recording {
                 self.stopVoiceCaptureAndFinalize(customError: "Internal error: Start called with text.")
            } else {
                 checkVoiceInputPermissionsAndAvailability()
            }
            return
        }
        
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        
        guard micStatus == .authorized else {
            logger.error("startVoiceCapture: Aborted. Microphone permission not .authorized (is \(String(describing: micStatus.rawValue))). Re-running checks.")
            checkVoiceInputPermissionsAndAvailability(); return
        }
        guard speechStatus == .authorized else {
            logger.error("startVoiceCapture: Aborted. Speech recognition not .authorized (is \(String(describing: speechStatus.rawValue))). Re-running checks.")
            checkVoiceInputPermissionsAndAvailability(); return
        }
        guard speechRecognitionService.speechRecognizerAvailable else {
            logger.error("startVoiceCapture: Aborted. Speech recognizer not available. Current state: \(self.voiceInputState.description)")
            self.voiceInputState = .speechRecognitionUnavailable
            return
        }

        logger.info("startVoiceCapture: All permissions and availability checks passed, userInput is empty.")
        
        self.prefixForCurrentUtterance = self.userInput
        logger.info("startVoiceCapture: Initialized prefixForCurrentUtterance to '\(self.prefixForCurrentUtterance.prefix(50))'.")

        do {
            logger.info("startVoiceCapture: Attempting to start audio engine...")
            try audioEngineService.startStreamingAudio { [weak self] (buffer, _) in
                self?.speechRecognitionService.processAudioBuffer(buffer)
            }
            logger.info("startVoiceCapture: Audio engine successfully started.")
            logger.info("startVoiceCapture: Attempting to start speech recognition task...")
            try speechRecognitionService.startRecognition(recognitionHandler: { [weak self] (transcriptFromRecognizer, isFinal, error) in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    if let error = error {
                        let nsError = error as NSError
                        logger.error("Speech recognition handler error: Domain: \(nsError.domain), Code: \(nsError.code), Description: \(nsError.localizedDescription)")
                        
                        var isCancellationError = false
                        if nsError.domain == SFSpeechErrorDomain {
                            isCancellationError = true
                        }
                        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1107 { isCancellationError = true }

                        let finalActionErrorString: String?
                        if isCancellationError {
                            logger.info("REC HANDLER: Cancellation error. UserInput: '\(self.userInput.prefix(50))'")
                            finalActionErrorString = nil
                        } else if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                            logger.info("REC HANDLER: No speech detected. UserInput: '\(self.userInput.prefix(50))'")
                            finalActionErrorString = "No speech detected."
                        } else {
                            logger.warning("REC HANDLER: Other error. UserInput: '\(self.userInput.prefix(50))'")
                            finalActionErrorString = "Recognition error: \(error.localizedDescription.prefix(50))"
                        }
                        
                        self.stopVoiceCaptureAndFinalize(customError: finalActionErrorString)
                        return
                    }

                    let currentPrefix = self.prefixForCurrentUtterance
                    let separator = currentPrefix.isEmpty || currentPrefix.last?.isWhitespace == true || currentPrefix.last?.isNewline == true ? "" : " "
                    self.userInput = currentPrefix + separator + transcriptFromRecognizer
                    logger.trace("REC HANDLER: Appending. prefix='\(currentPrefix.prefix(50))', transcript='\(transcriptFromRecognizer.prefix(50))', userInput='\(self.userInput.prefix(50))'")
                    
                    if isFinal {
                        logger.info("REC HANDLER: Final transcript received. userInput='\(self.userInput.prefix(100))'")
                        self.stopVoiceCaptureAndFinalize(customError: nil)
                    }
                }
            })
            logger.info("startVoiceCapture: Speech recognition task successfully started.")
            voiceInputState = .recording
        } catch let audioError as AudioEngineError {
            logger.error("startVoiceCapture: AudioEngineError caught: \(audioError.localizedDescription)")
            voiceInputState = .error("Audio engine error: \(audioError.localizedDescription.prefix(50))")
            audioEngineService.stopStreamingAudio()
        } catch let speechError as SpeechRecognitionError {
            logger.error("startVoiceCapture: SpeechRecognitionError caught: \(speechError.localizedDescription)")
            voiceInputState = .error("Speech setup error: \(speechError.localizedDescription.prefix(50))")
            audioEngineService.stopStreamingAudio()
        } catch {
            logger.error("startVoiceCapture: Generic error caught: \(error.localizedDescription)")
            voiceInputState = .error("Start capture error: \(error.localizedDescription.prefix(50))")
            audioEngineService.stopStreamingAudio()
        }
    }

    private func stopVoiceCaptureAndFinalize(customError: String?) {
        let previousState = self.voiceInputState
        logger.info("stopVoiceCaptureAndFinalize: Entered. Requested Error: \(customError ?? "None"). Current state before action: \(previousState.description)")

        if audioEngineService.isRecording || speechRecognitionService.isRecognitionActive {
            audioEngineService.stopStreamingAudio()
            speechRecognitionService.stopRecognition()
            logger.info("stopVoiceCaptureAndFinalize: Audio and Speech services stop requested/confirmed.")
        } else {
            logger.info("stopVoiceCaptureAndFinalize: Services indicate no active session to stop (or already stopped).")
        }

        var newStateDetermined = false

        if let explicitNewError = customError, !explicitNewError.isEmpty {
            if self.voiceInputState != .error(explicitNewError) {
                self.voiceInputState = .error(explicitNewError)
            }
            newStateDetermined = true
        } else {
            let micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
            let speechPermission = SFSpeechRecognizer.authorizationStatus()
            let recognizerIsActuallyAvailable = speechRecognitionService.speechRecognizerAvailable

            if micPermission != .authorized {
                if self.voiceInputState != .permissionsDeniedMic { self.voiceInputState = .permissionsDeniedMic }
            } else if speechPermission != .authorized {
                if self.voiceInputState != .permissionsDeniedSpeech { self.voiceInputState = .permissionsDeniedSpeech }
            } else if !recognizerIsActuallyAvailable {
                if self.voiceInputState != .speechRecognitionUnavailable { self.voiceInputState = .speechRecognitionUnavailable }
            } else {
                if self.voiceInputState != .available { self.voiceInputState = .available }
            }
            newStateDetermined = true
        }
        
        if !newStateDetermined && previousState == .requestingPermissions {
             logger.warning("stopVoiceCaptureAndFinalize: Was in .requestingPermissions, no explicit error, and no new state determined. Re-checking availability.")
             checkVoiceInputPermissionsAndAvailability()
        }

        if previousState != self.voiceInputState {
            logger.info("stopVoiceCaptureAndFinalize: Completed. State transitioned from \(previousState.description) to \(self.voiceInputState.description). UserInput: '\(self.userInput.prefix(100))'")
        } else {
            logger.info("stopVoiceCaptureAndFinalize: Completed. State remained \(self.voiceInputState.description). UserInput: '\(self.userInput.prefix(100))'")
        }
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
    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() }
        if !isSidebarCollapsed {
            if showSettings { showSettings = false }
            if showPromptLibrary { showPromptLibrary = false }
        }
    }

    func toggleSettings() {
        withAnimation { showSettings.toggle() }
        if showSettings {
            if showPromptLibrary { showPromptLibrary = false }
            if !isSidebarCollapsed { isSidebarCollapsed = true }
        }
    }

    func togglePromptLibrary() {
        withAnimation { showPromptLibrary.toggle() }
        if showPromptLibrary {
            if showSettings { showSettings = false }
            if !isSidebarCollapsed { isSidebarCollapsed = true }
        }
    }

    func toggleContextArea() {
         withAnimation { showContextArea.toggle() }
         if !showContextArea { activeContextFilePath = nil }
    }

    func requestEditPrompt(_ prompt: Prompt) {
        if !showPromptLibrary { togglePromptLibrary() }
        else if showSettings { showSettings = false }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AppNotifications.editPromptRequestedFromBriefView, object: prompt)
        }
    }
    
    // MARK: - Private Helper Methods
    func groupKey(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        else if calendar.isDateInYesterday(date) { return "Yesterday" }
        else { return self.groupDateFormatter.string(from: date) }
    }
    
    @MainActor
    func addAttachedFile(fileItem: FileSystemItem) {
        if !attachedFiles.contains(where: { $0.id == fileItem.id }) {
            attachedFiles.append(fileItem)
            attachedFilesLogger.info("Added attached file: \(fileItem.name) - Path: \(fileItem.url.path)")
        } else {
            attachedFilesLogger.info("File already attached, not adding duplicate: \(fileItem.name)")
        }
    }

    @MainActor
    func addAttachedFiles(fileItems: [FileSystemItem]) {
        var newFilesAddedCount = 0
        for fileItem in fileItems {
            if !attachedFiles.contains(where: { $0.id == fileItem.id }) {
                attachedFiles.append(fileItem)
                newFilesAddedCount += 1
                attachedFilesLogger.info("Added attached file (batch): \(fileItem.name) - Path: \(fileItem.url.path)")
            } else {
                attachedFilesLogger.info("File already attached (batch), not adding duplicate: \(fileItem.name)")
            }
        }
        if newFilesAddedCount > 0 {
            attachedFilesLogger.info("\(newFilesAddedCount) new file(s) added to attached files list.")
        }
    }

    @MainActor
    func removeAttachedFile(fileItem: FileSystemItem) {
        if let index = attachedFiles.firstIndex(where: { $0.id == fileItem.id }) {
            let removedItem = attachedFiles.remove(at: index)
            attachedFilesLogger.info("Removed attached file: \(removedItem.name) - Path: \(removedItem.url.path)")
        } else {
            attachedFilesLogger.warning("Attempted to remove a file that was not found in the attached list: \(fileItem.name)")
        }
    }
    
    @MainActor
    func removeAttachedFile(byId fileId: URL) {
        if let index = attachedFiles.firstIndex(where: { $0.id == fileId }) {
            let removedItem = attachedFiles.remove(at: index)
            attachedFilesLogger.info("Removed attached file by ID: \(removedItem.name) - Path: \(removedItem.url.path)")
        } else {
            attachedFilesLogger.warning("Attempted to remove a file by ID that was not found in the attached list: \(fileId.path)")
        }
    }

    @MainActor
    func clearAttachedFiles() {
        if !attachedFiles.isEmpty {
            let count = attachedFiles.count
            attachedFiles.removeAll()
            attachedFilesLogger.info("Cleared all (\(count)) attached files.")
        } else {
            attachedFilesLogger.info("No attached files to clear.")
        }
    }
}
