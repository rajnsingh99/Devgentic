// ViewModels/MainApplicationViewModel.swift
import SwiftUI
import Combine
import os
import AppKit // For NSApplication, NSAttributedString
import Speech // Import Speech framework for SFSpeechRecognizerAuthorizationStatus
import AVFoundation // Required for AVCaptureDevice

// Logger for the ViewModel
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MainApplicationViewModel")
private let attachedFilesLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainAppViewModel_AttachedFiles")

// Assuming SettingsSection, BackendType, SettingsKeys, Conversation,
// ChatMessage, MessageContent, ConversationStore, AppDelegate, OllamaService,
// AIConnect, AgentResponseHandler, ErrorHandling are defined elsewhere.

@MainActor // Ensure UI updates happen on the main thread
class MainApplicationViewModel: ObservableObject {

    // MARK: - Dependencies
    private let store = ConversationStore.shared
    private let aiConnect = AIConnect()
    private let responseHandler = AgentResponseHandler()
    
    @ObservedObject var ollamaService: OllamaService

    // MARK: - Voice Input Services
    private let audioEngineService: AudioEngineService
    private let speechRecognitionService: NativeSpeechRecognitionService
    
    private var cancellables = Set<AnyCancellable>()

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
    @Published var attachedFiles: [FileSystemItem] = []
    

    // MARK: - Voice Input State
    enum VoiceInputState: Equatable {
        case idle
        case requestingPermissions
        case permissionsDeniedMic
        case permissionsDeniedSpeech
        case speechRecognitionUnavailable
        case available
        case recording
        case processing
        case error(String)
        
        // Custom description for logging purposes
        var description: String {
            switch self {
            case .idle: return "idle"
            case .requestingPermissions: return "requestingPermissions"
            case .permissionsDeniedMic: return "permissionsDeniedMic"
            case .permissionsDeniedSpeech: return "permissionsDeniedSpeech"
            case .speechRecognitionUnavailable: return "speechRecognitionUnavailable"
            case .available: return "available"
            case .recording: return "recording"
            case .processing: return "processing"
            case .error(let msg): return "error(\(msg.prefix(30)))" // Truncate error for brevity in logs
            }
        }
    }
    @Published var voiceInputState: VoiceInputState = .idle
    private var textInEditorBeforeVoiceInput: String = ""

    // --- Settings Properties ---
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
         audioEngineService: AudioEngineService = AudioEngineService(),
         speechRecognitionService: NativeSpeechRecognitionService = NativeSpeechRecognitionService()) {
        self.ollamaService = ollamaService
        self.audioEngineService = audioEngineService
        self.speechRecognitionService = speechRecognitionService
        
        self.conversations = store.getAllConversations()
        validateSelectedConversation()
        observeConversationStoreChanges()
        
        logger.info("MainApplicationViewModel initialized. Loaded \(self.conversations.count) conversations.")
        if selectedBackend == .ollama {
            Task { await self.ollamaService.checkServerStatusAndUpdateModels() }
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
                    self.voiceInputState = .speechRecognitionUnavailable
                } else {
                    if self.voiceInputState == .speechRecognitionUnavailable || self.voiceInputState == .idle {
                         logger.info("Speech recognizer became available. Re-checking permissions and overall availability.")
                         self.checkVoiceInputPermissionsAndAvailability()
                    }
                }
            }
            .store(in: &cancellables)
    }

    convenience init() {
        self.init(ollamaService: OllamaService())
    }

    deinit {
        logger.info("MainApplicationViewModel deinitialized.")
        cancellables.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
        
        if audioEngineService.isRecording {
            Task { [weak self] in
                await self?.stopVoiceCaptureAndFinalize(customError: "ViewModel deinitializing")
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
        
        let plainUserInputFromEditor = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("sendMessage called. Backend: \(String(describing: self.selectedBackend.rawValue)), isSending: \(self.isSending), attributedInput (plain): \"\(plainUserInputFromEditor.prefix(50))...\"")

        guard !isSending else { logger.warning("sendMessage aborted: Already sending."); return }
        guard !plainUserInputFromEditor.isEmpty else {
            logger.info("sendMessage aborted: Input (from attributedString) empty.")
            if !self.userInput.isEmpty { self.userInput = "" }
            return
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

        var plainTextForLLM = ""
        var attachedFileContents: [String] = []
        
        attributedString.enumerateAttributes(in: NSRange(location: 0, length: attributedString.length), options: []) { urlValue, range, stop in
            let segmentString = attributedString.attributedSubstring(from: range).string

            if let fileURL = urlValue as? URL {
                plainTextForLLM += segmentString
                logger.debug("Found file tag: \(segmentString) for URL: \(fileURL.path)")

                let didStartAccess = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess {
                        fileURL.stopAccessingSecurityScopedResource()
                        logger.trace("Stopped security-scoped access for \(fileURL.lastPathComponent)")
                    }
                }

                if didStartAccess {
                    logger.trace("Started security-scoped access for \(fileURL.lastPathComponent)")
                    do {
                        let content = try String(contentsOf: fileURL, encoding: .utf8)
                        let fileContext = """
                        --- Content of file: \(fileURL.lastPathComponent) ---
                        \(content)
                        --- End of file: \(fileURL.lastPathComponent) ---
                        """
                        attachedFileContents.append(fileContext)
                        logger.debug("Successfully read and appended content for file: \(fileURL.lastPathComponent)")
                    } catch {
                        logger.error("Error reading file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                        attachedFileContents.append("--- Error reading file: \(fileURL.lastPathComponent): \(error.localizedDescription) ---")
                    }
                } else {
                    logger.error("Could not start security-scoped access for file: \(fileURL.lastPathComponent)")
                    attachedFileContents.append("--- Could not access file: \(fileURL.lastPathComponent) ---")
                }
            } else {
                plainTextForLLM += segmentString
            }
        }

        var messageToSendToBackend = plainTextForLLM
        if !attachedFileContents.isEmpty {
            messageToSendToBackend += "\n\n" + attachedFileContents.joined(separator: "\n\n")
        }
        
        var finalMessageWithContextPrefix = messageToSendToBackend
        if showContextArea, let filePath = activeContextFilePath, !filePath.isEmpty {
            finalMessageWithContextPrefix = "Context File: \(filePath)\n\nUser Message and Attached Files:\n" + messageToSendToBackend
            logger.debug("Prepended active context file path: \(filePath)")
        }

        let userMessageForDisplay = ChatMessage(
            conversationId: conversationIDToUse,
            sender: .user,
            content: .plainText(plainUserInputFromEditor)
        )
        
        targetConversationForUserMessage.messages.append(userMessageForDisplay)
        targetConversationForUserMessage.timestamp = Date()
        store.updateConversation(targetConversationForUserMessage)

        self.userInput = ""
        isSending = true

        Task {
            var agentMessagesForThisTurn: [ChatMessage] = []
            
            if selectedBackend == .ollama {
                 if ollamaService.serverStatus != .connected && ollamaService.serverStatus != .checking {
                      logger.info("Ollama status is \(String(describing: self.ollamaService.serverStatus.rawValue)), re-checking before sending.")
                      await ollamaService.checkServerStatusAndUpdateModels()
                 }
                 if ollamaService.serverStatus != .connected {
                    let errorMsg = "Cannot send message: Ollama server is not connected. Status: \(String(describing: self.ollamaService.serverStatus.rawValue))"
                    logger.error("\(errorMsg)")
                    let errorMessageContent = MessageContent.error(title: "Connection Error", details: errorMsg)
                    let errorChatMessage = ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: errorMessageContent)
                    agentMessagesForThisTurn.append(errorChatMessage)
                 }
            }

            if agentMessagesForThisTurn.isEmpty {
                let backendConfig = self.determineBackendConfiguration(message: finalMessageWithContextPrefix)
                do {
                    logger.debug("Sending task to \(backendConfig.url)\(backendConfig.endpoint). Message (first 200 chars): '\(finalMessageWithContextPrefix.prefix(200))'")
                    
                    let responseData = try await self.aiConnect.postToLocalServer(endpoint: backendConfig.endpoint, payload: backendConfig.payload)
                    let responseText = try responseHandler.parseInitialResponse(data: responseData, for: self.selectedBackend)
                    let parsedContents = responseHandler.parseTextToMessageContent(responseText)

                    for content in parsedContents {
                        let agentMessage = ChatMessage(conversationId: conversationIDToUse, sender: .agent, content: content)
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
                guard var targetConversationForAgentMessages = store.getConversation(withId: conversationIDToUse) else {
                    logger.error("CRITICAL: Could not find conversation for ID: \(conversationIDToUse.uuidString) to add agent messages.")
                    self.isSending = false
                    return
                }
                for msg in agentMessagesForThisTurn { targetConversationForAgentMessages.messages.append(msg) }
                targetConversationForAgentMessages.timestamp = Date()
                store.updateConversation(targetConversationForAgentMessages)
                logger.debug("Appended \(agentMessagesForThisTurn.count) agent message(s) to conversation \(conversationIDToUse.uuidString) via store.")
            } else if isSending {
                 logger.warning("sendMessage Task finished but generated no agent messages to handle.")
            }
            
            self.isSending = false
        }
    }

    // MARK: - Voice Input Methods
    func checkVoiceInputPermissionsAndAvailability() {
        logger.info("Checking voice input permissions and availability...")
        self.voiceInputState = .requestingPermissions

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
                if grantedByRequestCallback {
                    logger.info("audioEngineService.requestMicrophonePermission callback returned: \(grantedByRequestCallback). Re-checking speech permission.")
                    self.checkSpeechRecognitionPermission()
                } else {
                    logger.warning("Microphone permission denied by user or system (from callback).")
                    self.voiceInputState = .permissionsDeniedMic
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
                logger.warning("Speech recognizer is NOT available.")
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
            if self.voiceInputState != .requestingPermissions { self.voiceInputState = .requestingPermissions }
            
            speechRecognitionService.requestSpeechRecognitionPermission { [weak self] statusAfterRequestCallback in
                guard let self = self else { return }
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
        @unknown default:
            logger.error("Unknown initial speech recognition authorization status: \(String(describing: currentSpeechAuthStatus.rawValue))")
            self.voiceInputState = .error("Unknown speech permission state.")
        }
    }

    func toggleVoiceInput() {
        logger.info("Toggle voice input button tapped. Current voiceInputState: \(self.voiceInputState.description)")
        
        switch self.voiceInputState {
        case .idle, .available:
            logger.info("Attempting to start voice capture.")
            startVoiceCapture()
        case .recording:
            logger.info("Attempting to stop voice capture.")
            stopVoiceCaptureAndFinalize(customError: nil)
        case .requestingPermissions, .processing:
            logger.info("Voice input busy (\(self.voiceInputState.description)). Ignoring toggle.")
            break
        case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error:
            logger.info("Permissions issue or error state (\(self.voiceInputState.description)). Re-checking permissions.")
            checkVoiceInputPermissionsAndAvailability()
        }
    }

    private func startVoiceCapture() {
        logger.info("startVoiceCapture: Entered method.")
        
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()

        guard micStatus == .authorized else {
            logger.error("startVoiceCapture: Aborted. Microphone permission not .authorized (is \(String(describing: micStatus.rawValue))).")
            checkVoiceInputPermissionsAndAvailability()
            return
        }
        guard speechStatus == .authorized else {
            logger.error("startVoiceCapture: Aborted. Speech recognition not .authorized (is \(String(describing: speechStatus.rawValue))).")
            checkVoiceInputPermissionsAndAvailability()
            return
        }
        guard speechRecognitionService.speechRecognizerAvailable else {
            logger.error("startVoiceCapture: Aborted. Speech recognizer not available.")
            self.voiceInputState = .speechRecognitionUnavailable
            return
        }
        
        logger.info("startVoiceCapture: All permissions and availability checks passed.")
        textInEditorBeforeVoiceInput = userInput
        logger.info("startVoiceCapture: Stored textInEditorBeforeVoiceInput: '\(self.textInEditorBeforeVoiceInput.prefix(30))'")

        do {
            logger.info("startVoiceCapture: Attempting to start audio engine...")
            try audioEngineService.startStreamingAudio { [weak self] (buffer, _) in
                self?.speechRecognitionService.processAudioBuffer(buffer)
            }
            logger.info("startVoiceCapture: Audio engine successfully started.")

            logger.info("startVoiceCapture: Attempting to start speech recognition task...")
            try speechRecognitionService.startRecognition(recognitionHandler: { [weak self] (transcriptFromRecognizer, isFinal, error) in
                guard let self = self else { return }
                
                let prefix = self.textInEditorBeforeVoiceInput
                let separator = prefix.isEmpty || prefix.last == " " ? "" : " "

                if let error = error {
                    let nsError = error as NSError
                    logger.error("Speech recognition handler error: Domain: \(nsError.domain), Code: \(nsError.code), Description: \(nsError.localizedDescription)")

                    // MODIFICATION: Adjusted isCancellationError check for macOS 14+ SFSpeechError.Code
                    // The specific SFSpeechError.Code members for cancellation might not be available.
                    // We rely on the domain and potentially the description or other codes.
                    var isCancellationError = false
                    if #available(macOS 14, *) { // Check for SFSpeechErrorDomain if available
                        if nsError.domain == SFSpeechErrorDomain {
                             // For macOS 14+, SFSpeechError.Code doesn't have explicit cancel codes.
                             // A common pattern for cancellation is code 203 with "cancel" in description.
                             // Or if the task is simply finalized by the system/user action without a specific "error".
                            if (nsError.code == 203 && nsError.localizedDescription.lowercased().contains("cancel")) {
                                isCancellationError = true
                            }
                            // Add other SFSpeechErrorDomain codes that might signify a benign stop if necessary
                        }
                    }
                    // kAFAssistantErrorDomain is another source for user cancellation.
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1107 { // User cancelled
                        isCancellationError = true
                    }
                                               
                    if isCancellationError {
                        logger.info("Recognition task was cancelled (likely intentional stop or end of audio). Treating as clean stop.")
                        if !transcriptFromRecognizer.isEmpty {
                            self.userInput = prefix + separator + transcriptFromRecognizer
                        } else {
                            self.userInput = prefix
                        }
                        self.stopVoiceCaptureAndFinalize(customError: nil)
                    } else if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        logger.info("No speech detected (kAFAssistantErrorDomain code 1110).")
                        self.userInput = prefix
                        self.stopVoiceCaptureAndFinalize(customError: "No speech detected.")
                    } else {
                        // For other errors, preserve original text and show error.
                        self.userInput = prefix
                        self.stopVoiceCaptureAndFinalize(customError: "Recognition error: \(error.localizedDescription.prefix(50))")
                    }
                    return
                }

                // No error, proceed with transcript update
                if !transcriptFromRecognizer.isEmpty {
                    self.userInput = prefix + separator + transcriptFromRecognizer
                } else {
                    // If no error, but transcript is empty (e.g., silence leading to a non-final result)
                    // keep the userInput as the prefix. Don't append an empty string.
                    if isFinal { // If it's final and transcript is empty, userInput should be what it was before.
                        self.userInput = prefix
                    }
                }
                logger.trace("Transcript update. isFinal: \(isFinal), userInput: '\(self.userInput.prefix(100))'")

                if isFinal {
                    // This block is reached if error was nil and isFinal is true.
                    logger.info("Final transcript (natural end without error). userInput: '\(self.userInput.prefix(100))'")
                    self.stopVoiceCaptureAndFinalize(customError: nil)
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
        logger.info("stopVoiceCaptureAndFinalize: Entered. Error: \(customError ?? "None"). Current state: \(self.voiceInputState.description)")
        
        guard voiceInputState == .recording || voiceInputState == .processing || audioEngineService.isRecording else {
            logger.info("stopVoiceCaptureAndFinalize: Not in recording/processing state or audio engine not active. No action needed or already stopping. Current state: \(self.voiceInputState.description), audioEngine.isRecording: \(String(describing: self.audioEngineService.isRecording))")
            if let err = customError, !err.isEmpty {
                if case .error(let existingError) = voiceInputState {
                    if existingError != err { self.voiceInputState = .error(err) }
                } else if self.voiceInputState != .available {
                     self.voiceInputState = .error(err)
                }
            } else if voiceInputState != .available && voiceInputState != .idle && voiceInputState != .requestingPermissions {
                var shouldSetToAvailable = true
                if case .error(let currentErr) = voiceInputState {
                    if !currentErr.isEmpty { shouldSetToAvailable = false }
                }
                if shouldSetToAvailable { self.voiceInputState = .available }
            }
            return
        }

        audioEngineService.stopStreamingAudio()
        logger.info("stopVoiceCaptureAndFinalize: Audio engine stopped.")
        speechRecognitionService.stopRecognition()
        logger.info("stopVoiceCaptureAndFinalize: Speech recognition service stop requested.")

        if let err = customError, !err.isEmpty {
            voiceInputState = .error(err)
            logger.info("stopVoiceCaptureAndFinalize: State set to .error: \(err)")
        } else {
            if voiceInputState == .recording || voiceInputState == .processing {
                voiceInputState = .available
                logger.info("stopVoiceCaptureAndFinalize: State set to .available after clean stop.")
            }
        }
        logger.info("stopVoiceCaptureAndFinalize: Completed. Final userInput: '\(self.userInput.prefix(100))'")
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
    private struct BackendConfiguration { let url: String; let endpoint: String; let payload: [String: Any] }
    private func determineBackendConfiguration(message: String) -> BackendConfiguration {
        switch self.selectedBackend {
        case .ollama:
            let advancedOptions: [String: Any] = [
                "temperature": self.ollamaTemperature, "top_k": self.ollamaTopK,
                "top_p": self.ollamaTopP, "repeat_penalty": self.ollamaRepeatPenalty,
                "num_ctx": self.ollamaContextWindowSize, "num_gpu": self.ollamaGpuLayers
            ]
            let modelName = ollamaService.llmModelName.isEmpty ? "default_model_name" : ollamaService.llmModelName
            return BackendConfiguration(
                url: "http://127.0.0.1:11434",
                endpoint: "/api/generate",
                payload: [
                    "model": modelName, "prompt": message, "stream": false, "options": advancedOptions
                ]
            )
        case .agent:
            return BackendConfiguration(
                url: self.agentBaseURL,
                endpoint: "/execute_task",
                payload: [ "main_task": message, "strategy": self.agentDelegationStrategy ]
            )
        }
    }
    
    func groupKey(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        else if calendar.isDateInYesterday(date) { return "Yesterday" }
        else { return self.groupDateFormatter.string(from: date) }
    }
    
    /// Adds a single file to the `attachedFiles` list.
        /// - Parameter fileItem: The `FileSystemItem` to add.
        /// - Note: This implementation prevents adding duplicate files based on their URL (id).
        @MainActor
        func addAttachedFile(fileItem: FileSystemItem) {
            if !attachedFiles.contains(where: { $0.id == fileItem.id }) {
                attachedFiles.append(fileItem)
                attachedFilesLogger.info("Added attached file: \(fileItem.name) - Path: \(fileItem.url.path)")
            } else {
                attachedFilesLogger.info("File already attached, not adding duplicate: \(fileItem.name)")
            }
        }

        /// Adds multiple files to the `attachedFiles` list.
        /// - Parameter fileItems: An array of `FileSystemItem`s to add.
        /// - Note: This implementation prevents adding duplicate files based on their URL (id).
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

        /// Removes a specific file from the `attachedFiles` list.
        /// - Parameter fileItem: The `FileSystemItem` to remove.
        @MainActor
        func removeAttachedFile(fileItem: FileSystemItem) {
            if let index = attachedFiles.firstIndex(where: { $0.id == fileItem.id }) {
                let removedItem = attachedFiles.remove(at: index)
                attachedFilesLogger.info("Removed attached file: \(removedItem.name) - Path: \(removedItem.url.path)")
            } else {
                attachedFilesLogger.warning("Attempted to remove a file that was not found in the attached list: \(fileItem.name)")
            }
        }
        
        /// Removes a specific file from the `attachedFiles` list by its ID (URL).
        /// - Parameter fileId: The URL (ID) of the `FileSystemItem` to remove.
        @MainActor
        func removeAttachedFile(byId fileId: URL) {
            if let index = attachedFiles.firstIndex(where: { $0.id == fileId }) {
                let removedItem = attachedFiles.remove(at: index)
                attachedFilesLogger.info("Removed attached file by ID: \(removedItem.name) - Path: \(removedItem.url.path)")
            } else {
                attachedFilesLogger.warning("Attempted to remove a file by ID that was not found in the attached list: \(fileId.path)")
            }
        }


        /// Clears all files from the `attachedFiles` list.
        @MainActor
        func clearAttachedFiles() {
            if !attachedFiles.isEmpty {
                attachedFiles.removeAll()
                attachedFilesLogger.info("Cleared all (\(self.attachedFiles.count)) attached files.")
            } else {
                attachedFilesLogger.info("No attached files to clear.")
            }
        }
}
