// ViewModels/MainApplicationViewModel.swift
import SwiftUI
import Combine // Needed for ObservableObject and @Published
import os     // For logging
import Markdown // <-- IMPORT swift-markdown


// Logger for the ViewModel
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainApplicationViewModel")

// MARK: - Enums

/// Represents the connection status of the Ollama server.
enum OllamaServerStatus: String, CaseIterable {
    case unknown      // Initial state
    case checking     // Currently attempting to connect
    case connected    // Successfully connected
    case disconnected // Connection failed or server not found
    case error        // An error occurred during status check (less common, but possible)

    /// A user-friendly description of the status.
    var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .checking: return "Checking Status..."
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .error: return "Error Checking Status" // Or a more specific error message if available
        }
    }

    /// System image name for the status icon.
    var systemImageName: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .checking: return "arrow.triangle.2.circlepath" // Spinner-like icon
        case .connected: return "checkmark.circle.fill"
        case .disconnected: return "xmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    /// Color associated with the status.
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .checking: return .blue
        case .connected: return .green
        case .disconnected: return .red
        case .error: return .orange // Or .red depending on severity
        }
    }
}


@MainActor // Ensure UI updates happen on the main thread
class MainApplicationViewModel: ObservableObject {

    // MARK: - Published State Properties
    // --- Using ChatMessage Data Model ---
    @Published var conversations: [Conversation] = []
    // ------------------------------------
    @Published var selectedConversationID: UUID?
    @Published var isSending: Bool = false
    @Published var userInput: String = ""
    @Published var isSidebarCollapsed: Bool = true
    @Published var showSettings: Bool = false
    @Published var selectedSettingsSection: SettingsSection = .general {
        didSet {
            // When the Local AI settings section is selected and the backend is Ollama,
            // first check the server status, then load models if connected.
            if selectedSettingsSection == .localAI && selectedBackend == .ollama {
                Task {
                    await checkOllamaServerStatus() // Check status first
                    // loadLocalOllamaModels will be called internally if status is connected
                }
            } else {
                // Reset Ollama status if not on the Local AI tab
                 self.ollamaServerStatus = .unknown
                 self.localOllamaModels = [] // Clear models if not on the tab
                 self.modelLoadingError = nil // Clear model loading error
                 self.clearModelActionStatus() // Clear any pending model action status
            }
        }
    }
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil

    // --- Settings Properties (loaded/saved via @AppStorage) ---
    @AppStorage(SettingsKeys.selectedBackend) var selectedBackend: BackendType = .ollama
    @AppStorage(SettingsKeys.windowOpacity) var windowOpacity: Double = 1.0
    @AppStorage(SettingsKeys.llmModelName) var llmModelName: String = "gemma:2b"
    @AppStorage(SettingsKeys.agentBaseURL) var agentBaseURL: String = "http://127.0.0.1:8000"
    @AppStorage(SettingsKeys.agentDelegationStrategy) var agentDelegationStrategy: String = "send_to_first_available"

    // --- @AppStorage Properties for Ollama Advanced Parameters ---
    @AppStorage(SettingsKeys.ollamaTemperature) var ollamaTemperature: Double = 0.8
    @AppStorage(SettingsKeys.ollamaTopK) var ollamaTopK: Int = 40
    @AppStorage(SettingsKeys.ollamaTopP) var ollamaTopP: Double = 0.9
    @AppStorage(SettingsKeys.ollamaRepeatPenalty) var ollamaRepeatPenalty: Double = 1.1
    @AppStorage(SettingsKeys.ollamaContextWindowSize) var ollamaContextWindowSize: Int = 4096
    @AppStorage(SettingsKeys.ollamaGpuLayers) var ollamaGpuLayers: Int = -1

    // --- Existing Published Properties for Local AI Model Management (Fetching) ---
    @Published var localOllamaModels: [String] = []
    @Published var isLoadingModels: Bool = false
    @Published var modelLoadingError: String? = nil

    // --- Existing Published Properties for Local AI Model Pulling ---
    @Published var modelToPull: String = ""
    @Published var isPullingModel: Bool = false
    @Published var pullStatusMessage: String = ""
    @Published var modelPullError: String? = nil

    // --- Existing Published Properties for Streaming Pull Progress ---
    @Published var pullProgress: Double = 0.0
    @Published var pullStage: String = ""
    @Published var pullTotalBytes: Int64? = nil
    @Published var pullCompletedBytes: Int64? = nil

    // --- Published Properties for Local AI Model Removal ---
    @Published var isRemovingModel: Bool = false
    @Published var removingModelName: String? = nil
    @Published var modelRemoveError: String? = nil

    // --- New Published Property for Ollama Server Status ---
    @Published var ollamaServerStatus: OllamaServerStatus = .unknown


    // MARK: - Dependencies
    private let aiConnect = AIConnect()

    // MARK: - Computed Properties (Derived State)

    // --- UPDATED to use ChatMessage ---
    // Renamed from currentChatHistory
    var currentChatMessages: [ChatMessage] {
        guard let selectedID = selectedConversationID,
              let conversation = conversations.first(where: { $0.id == selectedID }) else {
            return []
        }
        // Directly return the ChatMessage array from the conversation
        return conversation.messages
    }
    // ---------------------------------

    // currentConversationTitle uses the updated Conversation struct's displayTitle
    var currentConversationTitle: String {
        guard let conversation = conversations.first(where: { $0.id == selectedConversationID }) else {
            return conversations.isEmpty ? "Devgentic" : "Select Chat"
        }
        return conversation.displayTitle // Uses the adapted displayTitle
    }

    // groupedConversations & sortedGroupKeys work on the [Conversation] array, no changes needed
    var groupedConversations: [String: [Conversation]] {
        let calendar = Calendar.current
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d,yyyy"

        let grouped = conversations.reduce(into: [String: [Conversation]]()) { result, conversation in
            let timestamp = conversation.timestamp
            let groupKey: String
            if calendar.isDateInToday(timestamp) { groupKey = "Today" }
            else if calendar.isDateInYesterday(timestamp) { groupKey = "Yesterday" }
            else { groupKey = dateFormatter.string(from: timestamp) }
            result[groupKey, default: []].append(conversation)
        }
        return grouped.mapValues { $0.sorted { $0.timestamp > $1.timestamp } }
    }

    var sortedGroupKeys: [String] {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d,yyyy"

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
    init(initialConversations: [Conversation] = []) {
        // Ensure initialConversations (if provided) conform to the new structure
        self.conversations = initialConversations
        selectInitialConversation()
        logger.info("MainApplicationViewModel initialized.")
    }

    // selectInitialConversation works on the [Conversation] array, no changes needed
    private func selectInitialConversation() {
        sortConversations()
        if selectedConversationID == nil,
           let firstKey = sortedGroupKeys.first,
           let firstConv = groupedConversations[firstKey]?.first {
            selectedConversationID = firstConv.id
            logger.debug("Selected initial conversation: \(firstConv.id.uuidString)")
        }
    }


    // MARK: - Actions / Methods

    // --- UPDATED to use ChatMessage ---
    func startNewConversation() {
        if showSettings { showSettings = false }
        userInput = ""
        // Create Conversation with an empty [ChatMessage] array
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        conversations.append(newConversation)
        sortConversations() // Sort after adding
        selectedConversationID = newConversation.id
        logger.info("Started new conversation with ID: \(newConversation.id.uuidString)")
    }

    // --- UPDATED with Markdown Parsing Logic ---
    func sendMessage() {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("sendMessage called. Backend: \(self.selectedBackend.rawValue), isSending: \(self.isSending), trimmedInput: \(trimmedInput)")

        guard !isSending else { logger.warning("sendMessage aborted: Already sending."); return }
        guard !trimmedInput.isEmpty else { logger.info("sendMessage aborted: Input empty."); userInput = ""; return }
        guard !showSettings else { logger.warning("sendMessage aborted: Settings open."); return }

        // Context Integration - Prepare the prompt string for the backend
        var contextPrefix = ""
        if showContextArea, let filePath = activeContextFilePath {
            contextPrefix = "Context File: \(filePath)\n\nUser Message:\n"
        }
        let messageToSendToBackend = contextPrefix + trimmedInput

        // Ensure a conversation is selected or created
        if selectedConversationID == nil {
            logger.info("No conversation selected. Starting new one before sending.")
            startNewConversation()
        }

        // Safely get current conversation ID and index
        guard let currentID = selectedConversationID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == currentID }) else {
            logger.error("CRITICAL: Could not find valid conversation (ID: \(String(describing: self.selectedConversationID))) after attempting creation.")
            return
        }

        // Create and Append User ChatMessage (as .plainText)
        let userMessage = ChatMessage(
            conversationId: currentID,
            sender: .user,
            content: .plainText(trimmedInput) // User input as plain text
        )
        conversations[conversationIndex].messages.append(userMessage)
        conversations[conversationIndex].timestamp = Date()
        sortConversations()

        // Prepare for backend call
        let messageLogForBackend = messageToSendToBackend
        userInput = "" // Clear input field
        isSending = true

        // Perform Network Call Asynchronously
        Task {
            // Check server status before sending
            if selectedBackend == .ollama {
                 if ollamaServerStatus != .connected && ollamaServerStatus != .checking {
                      await checkOllamaServerStatus()
                 }
                 guard ollamaServerStatus == .connected else {
                     let errorMsg = "Cannot send message: Ollama server is not connected."
                     logger.error("\(errorMsg)")
                     let errorMessage = ChatMessage( conversationId: currentID, sender: .agent, content: .plainText("Error: \(errorMsg)") )
                     self.handleAgentResponse(message: errorMessage) // Use the single message handler
                     self.isSending = false // Explicitly set sending false on early exit
                     return
                 }
            }

            let backendConfig = self.determineBackendConfiguration(message: messageLogForBackend)
            var resultingMessages: [ChatMessage] = [] // Prepare for multiple messages

            do {
                logger.debug("Sending task '\(messageLogForBackend.prefix(200))' to \(backendConfig.url)\(backendConfig.endpoint) for conversation \(currentID.uuidString)")
                let responseData = try await self.aiConnect.postToLocalServer(
                    endpoint: backendConfig.endpoint,
                    payload: backendConfig.payload
                )
                // Get the raw response string
                let responseText = self.parseResponse(data: responseData, for: self.selectedBackend)

                // --- PARSE the response string into content blocks ---
                let parsedContents = self.parseAgentResponseString(responseText)
                // ----------------------------------------------------

                // --- Create ChatMessage for each parsed content block ---
                for content in parsedContents {
                    let agentMessage = ChatMessage(
                        conversationId: currentID, // Use ID captured before Task
                        sender: .agent,
                        content: content // Use the parsed content type
                    )
                    resultingMessages.append(agentMessage)
                }
                // -------------------------------------------------------

            } catch {
                logger.error("Error during API call or parsing: \(error.localizedDescription)")
                let errorText = self.generateErrorMessage(error: error)
                // --- Create .error content ---
                let errorMessage = ChatMessage(
                    conversationId: currentID,
                    sender: .agent,
                    content: .error(title: "Processing Error", details: errorText) // <-- USE .error
                )
                resultingMessages.append(errorMessage)
                 // Update Ollama status on network error
                 if selectedBackend == .ollama {
                     if let urlError = error as? URLError, (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                          self.ollamaServerStatus = .disconnected
                     }
                 }
            }

            // --- Handle potentially MULTIPLE agent messages ---
            var messageHandled = false
            for agentMessage in resultingMessages {
                 self.handleAgentResponse(message: agentMessage) // Call handler for each message
                 messageHandled = true
            }
            // Ensure sending is false only after handling ALL messages *or* if an error occurred *before* sending
            if messageHandled || !self.isSending /* Check if already false due to early exit */ {
                self.isSending = false
            } else {
                // If NO messages were generated (e.g., empty response parsed to nothing)
                // and no early exit occurred, still need to set isSending false.
                self.isSending = false
                logger.warning("sendMessage Task finished but generated no messages to handle.")
            }
            // ------------------------------------------------
        }
    }
    // --- END UPDATED sendMessage ---


    // Handles appending a single message to the correct conversation
    // IMPORTANT: Does NOT manage the isSending flag anymore.
    private func handleAgentResponse(message: ChatMessage) {
        if let updatedIndex = self.conversations.firstIndex(where: { $0.id == message.conversationId }) {
            self.conversations[updatedIndex].messages.append(message)
            self.conversations[updatedIndex].timestamp = Date() // Update timestamp for latest activity
            self.sortConversations()
            // Use String(describing:) for safe enum logging
            logger.debug("Appended message ID \(message.id.uuidString) (Sender: \(String(describing: message.sender))) to conversation \(message.conversationId.uuidString)")
        } else {
            logger.error("Error: Conversation \(message.conversationId.uuidString) disappeared before message (ID: \(message.id.uuidString)) could be added.")
        }
    }

    // --- UI Toggles (No Changes Needed) ---
    func toggleSidebar() { withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() } }
    func toggleSettings() { withAnimation { showSettings.toggle() } }
    func toggleContextArea() {
         withAnimation {
            showContextArea.toggle()
        }
        if showContextArea {
            // Simulate fetching context - Logic remains placeholder for now
            // activeContextFilePath = "/Users/alice/Documents/project/file.swift"
            logger.info("Context toggled: Showing active file (Simulated).")
        } else {
            activeContextFilePath = nil
            logger.info("Context toggled: Hiding context area.")
        }
    }

    // MARK: - Ollama Server Status (Full Implementation)
    /// Checks the connection status of the Ollama server.
    func checkOllamaServerStatus() async {
        guard selectedBackend == .ollama && ollamaServerStatus != .checking else {
             if selectedBackend != .ollama { self.ollamaServerStatus = .unknown }
             return
         }
        self.ollamaServerStatus = .checking
        let ollamaBaseURL = "http://localhost:11434" // TODO: Make configurable
        let isConnected = await AIConnect.checkOllamaServerStatus(baseURL: ollamaBaseURL)
        if isConnected {
            self.ollamaServerStatus = .connected
            if selectedSettingsSection == .localAI { await loadLocalOllamaModels() }
        } else {
            self.ollamaServerStatus = .disconnected
            self.localOllamaModels = []
            self.modelLoadingError = "Cannot connect to Ollama server."
            logger.error("Ollama server status check failed: Server not reachable.")
        }
    }

    // MARK: - Local AI Model Management Actions (Full Implementation)
    /// Fetches the list of local Ollama models asynchronously.
    func loadLocalOllamaModels() async {
         guard selectedBackend == .ollama else { return }
         guard !isPullingModel && !isRemovingModel else { return }
         guard ollamaServerStatus == .connected else { self.localOllamaModels = []; return }

        isLoadingModels = true
        modelLoadingError = nil
        let ollamaBaseURL = "http://localhost:11434"
        logger.info("Attempting to load local Ollama models from \(ollamaBaseURL)...")
        do {
            let models = try await AIConnect.fetchLocalOllamaModels(baseURL: ollamaBaseURL)
            self.localOllamaModels = models.sorted()
            self.modelLoadingError = nil
            logger.info("Successfully loaded \(models.count) local Ollama models.")
            if !models.contains(self.llmModelName) && !models.isEmpty {
                 logger.warning("Current model '\(self.llmModelName)' not found in fetched list. Setting llmModelName to the first model.")
                 self.llmModelName = models.first!
            } else if models.isEmpty {
                 self.llmModelName = ""
                 logger.warning("Local model list is empty. Clearing selected llmModelName.")
            }
        } catch {
            let errorMessage = self.generateErrorMessage(error: error)
            self.localOllamaModels = []
            self.modelLoadingError = "Failed to load models: \(errorMessage)"
            logger.error("Failed to load local Ollama models: \(error.localizedDescription)")
            if let urlError = error as? URLError, (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                 self.ollamaServerStatus = .disconnected
            }
        }
        isLoadingModels = false
    }

    /// Initiates the process of pulling a new Ollama model.
    func pullModelAction(name modelName: String) async {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else { self.modelPullError = "Model name cannot be empty."; return }
        guard !isPullingModel else { return }
        guard !isRemovingModel else { self.modelPullError = "Cannot pull model: Another model is currently being removed."; return }
        guard selectedBackend == .ollama else { self.modelPullError = "Cannot pull models when Ollama is not the selected backend."; return }
        guard ollamaServerStatus == .connected else { self.modelPullError = "Cannot pull model: Ollama server is not connected."; return }

        isPullingModel = true
        self.pullStatusMessage = "Starting pull for \(trimmedModelName)..."
        modelPullError = nil
        pullProgress = 0.0; pullStage = "Starting..."; pullTotalBytes = nil; pullCompletedBytes = nil

        let ollamaBaseURL = "http://localhost:11434"
        logger.info("Attempting to pull model: \(trimmedModelName) with streaming.")
        do {
            try await AIConnect.pullOllamaModel(name: trimmedModelName, baseURL: ollamaBaseURL) { progress in
                Task { @MainActor in
                    self.pullStage = progress.status
                    self.pullTotalBytes = progress.total
                    self.pullCompletedBytes = progress.completed
                    self.pullProgress = progress.percentage ?? 0.0
                    if let percentage = progress.percentage { self.pullStatusMessage = "\(progress.status.capitalized): \(String(format: "%.0f%%", percentage * 100))" }
                    else if !progress.status.isEmpty { self.pullStatusMessage = progress.status.capitalized }
                    else { self.pullStatusMessage = "In progress..." }
                    if let streamedError = progress.error { self.modelPullError = "Stream Error: \(streamedError)"; logger.error("Received streamed error during pull: \(streamedError).") }
                }
            }
            self.pullStatusMessage = "Successfully pulled \(trimmedModelName)."
            self.modelPullError = nil; self.pullProgress = 1.0; self.pullStage = "Complete"
            logger.info("Model \(trimmedModelName) pulled successfully.")
            Task { await loadLocalOllamaModels() }
        } catch {
            let errorMessage = self.generateErrorMessage(error: error)
            self.pullStatusMessage = "Failed to pull \(trimmedModelName)."
            self.modelPullError = "Pull failed: \(errorMessage)"
            self.pullProgress = 0.0; self.pullStage = "Error"
            logger.error("Failed to pull model \(trimmedModelName): \(error.localizedDescription)")
            if let urlError = error as? URLError, (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                 self.ollamaServerStatus = .disconnected
            }
        }
        isPullingModel = false
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if modelPullError == nil { self.modelToPull = "" }
        self.pullStatusMessage = ""; self.pullStage = ""; self.pullProgress = 0.0
    }

    /// Initiates the process of removing a local Ollama model.
    func removeModelAction(name modelName: String) async {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else { self.modelRemoveError = "Model name cannot be empty for removal."; return }
        guard trimmedModelName != self.llmModelName else { self.modelRemoveError = "Cannot remove the currently active model."; return }
        guard self.localOllamaModels.contains(trimmedModelName) else { self.modelRemoveError = "Model '\(trimmedModelName)' not found."; return }
        guard !isRemovingModel else { return }
        guard !isPullingModel else { self.modelRemoveError = "Cannot remove model: Another model is currently being pulled."; return }
        guard selectedBackend == .ollama else { self.modelRemoveError = "Cannot remove models when Ollama is not the selected backend."; return }
        guard ollamaServerStatus == .connected else { self.modelRemoveError = "Cannot remove model: Ollama server is not connected."; return }

        isRemovingModel = true
        removingModelName = trimmedModelName
        modelRemoveError = nil
        let ollamaBaseURL = "http://localhost:11434"
        logger.info("Attempting to remove model: \(trimmedModelName)")
        do {
            try await AIConnect.removeOllamaModel(name: trimmedModelName, baseURL: ollamaBaseURL)
            logger.info("Model \(trimmedModelName) removed successfully.")
            Task { await loadLocalOllamaModels() }
            self.removingModelName = nil
        } catch {
            let errorMessage = self.generateErrorMessage(error: error)
            self.modelRemoveError = "Removal failed: \(errorMessage)"
            logger.error("Failed to remove model \(trimmedModelName): \(error.localizedDescription)")
             if let urlError = error as? URLError, (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                 self.ollamaServerStatus = .disconnected
            }
        }
        isRemovingModel = false
    }


    // MARK: - Agent Response Parsing Helper (NEW)

    /// Parses a raw response string from the agent into distinct content blocks.
    /// Uses swift-markdown to identify code blocks vs other text (treated as markdown).
    /// - Parameter responseText: The raw string received from the backend.
    /// - Returns: An array of MessageContent enums representing the parsed blocks.
    private func parseAgentResponseString(_ responseText: String) -> [MessageContent] {
        logger.debug("Parsing agent response string...")
        var contentBlocks: [MessageContent] = []
        // Use default parsing options unless specific directives are needed
        let document = Document(parsing: responseText)

        // Iterate through the top-level blocks of the Markdown document
        for block in document.children {
            switch block {
            case let codeBlock as CodeBlock:
                let codeContent = codeBlock.code.trimmingCharacters(in: .whitespacesAndNewlines)
                // Only add if content exists after trimming
                if !codeContent.isEmpty {
                    logger.trace("Found Code Block, language: \(codeBlock.language ?? "nil")")
                    contentBlocks.append(.codeBlock(language: codeBlock.language, code: codeContent))
                } else {
                    logger.trace("Skipping empty Code Block.")
                }

            case let blockquote as BlockQuote:
                 // Format preserves the blockquote markers '>'
                 let quoteContent = blockquote.format().trimmingCharacters(in: .whitespacesAndNewlines)
                 if !quoteContent.isEmpty {
                      logger.trace("Found Block Quote.")
                      contentBlocks.append(.markdownText(quoteContent))
                 } else {
                      logger.trace("Skipping empty Block Quote.")
                 }

            // Handle other block types (Paragraph, Heading, List, etc.) as Markdown text
            default:
                // Format the block back into its Markdown string representation
                // This preserves list markers, heading syntax, etc. for MarkdownUI
                let markdownContent = block.format().trimmingCharacters(in: .whitespacesAndNewlines)
                if !markdownContent.isEmpty {
                    logger.trace("Found other block type (\(type(of: block))), treating as Markdown.")
                    contentBlocks.append(.markdownText(markdownContent))
                } else {
                     logger.trace("Skipping empty block of type (\(type(of: block))).")
                }
            }
        }

        // Fallback if parsing resulted in no blocks from a non-empty string
        if contentBlocks.isEmpty && !responseText.isEmpty {
             logger.warning("Markdown parsing resulted in no content blocks, returning original text as plain.")
             return [.plainText(responseText)]
         }

        logger.info("Parsed response into \(contentBlocks.count) content blocks.")
        return contentBlocks
    }


    // MARK: - Private Helper Functions (Full Implementations)

    private func sortConversations() {
        conversations.sort { $0.timestamp > $1.timestamp }
    }

    private struct BackendConfiguration {
        let url: String
        let endpoint: String
        let payload: [String: Any]
    }

    // determineBackendConfiguration uses local settings
    private func determineBackendConfiguration(message: String) -> BackendConfiguration {
        switch self.selectedBackend {
        case .ollama:
            let advancedOptions: [String: Any] = [
                "temperature": self.ollamaTemperature,
                "top_k": self.ollamaTopK,
                "top_p": self.ollamaTopP,
                "repeat_penalty": self.ollamaRepeatPenalty,
                "num_ctx": self.ollamaContextWindowSize,
                "num_gpu": self.ollamaGpuLayers
            ]

            return BackendConfiguration(
                url: "http://127.0.0.1:11434", // TODO: Make configurable
                endpoint: "/api/generate",
                payload: [
                    "model": self.llmModelName,
                    "prompt": message,
                    "stream": false, // Streaming handled separately if needed
                    "options": advancedOptions
                ]
            )
        case .agent:
            return BackendConfiguration(
                url: self.agentBaseURL,
                endpoint: "/execute_task",
                payload: [
                    "main_task": message,
                    "strategy": self.agentDelegationStrategy
                ]
            )
        }
    }

    // parseResponse parses API data into String
    private func parseResponse(data: Data, for backend: BackendType) -> String {
         do {
            switch backend {
            case .agent:
                 guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let resultsArray = json["results"] as? [[String: Any]] else {
                     logger.warning("Agent response was not the expected JSON structure.")
                     return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode non-JSON Agent response."
                 }
                 if let completed = resultsArray.first(where: { ($0["status"] as? String) == "completed" }),
                   let result = completed["result"] as? String {
                     logger.debug("Parsed completed agent result.")
                     return result.trimmingCharacters(in: .whitespacesAndNewlines)
                 } else if !resultsArray.isEmpty && resultsArray.allSatisfy({ ($0["status"] as? String) != "completed" }) {
                     let firstError = resultsArray.first?["result"] as? String ?? "Unknown agent error"
                     logger.warning("All agents failed. First error: \(firstError)")
                     return "Agent Error: \(firstError)"
                 } else if resultsArray.isEmpty {
                      logger.warning("Agent returned empty results array.")
                      return "Error: Received empty results array from agent."
                 } else {
                      logger.warning("No agent completed successfully in results: \(resultsArray)")
                      return "Error: No agent completed the task successfully."
                 }

            case .ollama:
                 guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let reply = json["response"] as? String else {
                     logger.warning("Ollama response was not JSON or missing 'response' key.")
                      if let rawResponse = String(data: data, encoding: .utf8) {
                          logger.warning("Ollama JSON response: \(rawResponse)")
                      }
                     return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode non-JSON Ollama response."
                 }
                 logger.debug("Parsed Ollama response.")
                 return reply.trimmingCharacters(in: .whitespacesAndNewlines)

            }
        } catch {
            logger.error("Failed to parse JSON response: \(error.localizedDescription)")
             if let rawResponse = String(data: data, encoding: .utf8) {
                 logger.error("Raw data that failed to parse: \(rawResponse)")
             }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode server response (\(error.localizedDescription))."
        }
    }

    // generateErrorMessage creates String from Error
    private func generateErrorMessage(error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost: return "Could not connect to the server (\(self.selectedBackend.rawValue)). Check if it's running and the URL/Port is correct."
            case .networkConnectionLost: return "Network connection lost."
            case .notConnectedToInternet: return "Not connected to the internet."
            case .badServerResponse:
                 let httpStatusCode = urlError.userInfo["HTTPStatusCode"] as? Int
                 let responseData = urlError.userInfo["ResponseData"] as? Data
                 let responseBody = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                 let statusString = httpStatusCode.map { " (\($0))" } ?? ""

                 if let data = responseData, let ollamaError = parseOllamaErrorResponse(data: data) {
                     return "Ollama Error\(statusString): \(ollamaError)"
                 }

                return "Bad server response\(statusString). \(responseBody.prefix(150))"

            case .cannotFindHost: return "Cannot find the server host (\(self.selectedBackend.rawValue)). Check address/DNS."
            case URLError.Code(rawValue: 1): return "Operation not permitted (check Sandbox/Firewall)." // Common macOS error code
             case .cancelled: return "Request cancelled."
            default:
                logger.warning("Unhandled URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                return "Network request failed (\(urlError.localizedDescription))."
            }
        }
        logger.warning("Unhandled error type: \(type(of: error)) - \(error.localizedDescription)")
        return "Error: \(error.localizedDescription)"
    }

    // parseOllamaErrorResponse creates String from Ollama error data
    private func parseOllamaErrorResponse(data: Data) -> String? {
         guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String else {
             return nil
         }
         return error.trimmingCharacters(in: .whitespacesAndNewlines)
     }


    // --- TODO: Implement File Reading / Persistence ---
    // func readFileContent(at path: String) -> String? { ... }
    // func saveConversations() { ... }
    // func loadConversations() { ... }

    // MARK: - State Reset / Cleanup
     func clearModelActionStatus() {
         pullStatusMessage = ""
         modelPullError = nil
         pullProgress = 0.0
         pullStage = ""
         pullTotalBytes = nil
         pullCompletedBytes = nil
         modelRemoveError = nil
         removingModelName = nil
     }

     func clearPullStatus() {
         pullStatusMessage = ""
         modelPullError = nil
         pullProgress = 0.0
         pullStage = ""
         pullTotalBytes = nil
         pullCompletedBytes = nil
     }

      func clearRemoveStatus() {
          modelRemoveError = nil
          removingModelName = nil
      }
}
