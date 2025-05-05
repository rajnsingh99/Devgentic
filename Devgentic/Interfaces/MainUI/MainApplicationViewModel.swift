// ViewModels/MainApplicationViewModel.swift
import SwiftUI
import Combine // Needed for ObservableObject and @Published
import os     // For logging
import Markdown // For parsing agent responses (assuming already added)


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
    // --- Initialize conversations by LOADING them ---
    @Published var conversations: [Conversation] = [] // Initial value set in init
    // ----------------------------------------------
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

    // Returns the [ChatMessage] for the currently selected conversation
    var currentChatMessages: [ChatMessage] {
        guard let selectedID = selectedConversationID,
              let conversation = conversations.first(where: { $0.id == selectedID }) else {
            return []
        }
        return conversation.messages
    }

    // Uses the updated Conversation struct's displayTitle
    var currentConversationTitle: String {
        guard let conversation = conversations.first(where: { $0.id == selectedConversationID }) else {
            return conversations.isEmpty ? "Devgentic" : "Select Chat"
        }
        return conversation.displayTitle // Uses the adapted displayTitle
    }

    // Grouping/Sorting logic remains the same
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


    // MARK: - Initialization (Loads from PersistenceService)
    init() {
        // --- Load conversations on initialization ---
        self.conversations = PersistenceService.loadConversations()
        // ------------------------------------------
        selectInitialConversation() // Select first conversation after loading
        logger.info("MainApplicationViewModel initialized. Loaded \(self.conversations.count) conversations.")
        // Note: loadSettings() removed as @AppStorage handles settings persistence automatically.
    }

    private func selectInitialConversation() {
        // Sort is handled by loadConversations now, but sorting again doesn't hurt
        sortConversations()
        if selectedConversationID == nil || !conversations.contains(where: { $0.id == selectedConversationID }) {
             // Select first conversation if nothing valid is selected
            selectedConversationID = conversations.first?.id // Directly get ID of first sorted convo
            if let id = selectedConversationID {
                logger.debug("Selected initial/first conversation: \(id.uuidString)")
            } else {
                 logger.debug("No conversations available to select initially.")
             }
        } else {
            logger.debug("Keeping existing selectedConversationID: \(String(describing: self.selectedConversationID))")
        }
    }


    // MARK: - Actions / Methods

    // --- UPDATED: Save after creating ---
    func startNewConversation() {
        if showSettings { showSettings = false }
        userInput = ""
        // Create Conversation with an empty [ChatMessage] array
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        conversations.append(newConversation)
        sortConversations() // Sort after adding
        selectedConversationID = newConversation.id
        logger.info("Started new conversation with ID: \(newConversation.id.uuidString)")
        // --- SAVE Conversations ---
        PersistenceService.saveConversations(self.conversations)
        logger.debug("Saved conversations after starting new one.")
        // ------------------------
    }
    
    // MARK: - Actions / Methods

        // Renamed for clarity, now only creates the object and selects it. Saving happens elsewhere.
        // Returns the ID of the newly created conversation.
        @discardableResult // Indicate the return value isn't always needed
        func createAndSelectNewConversation() -> UUID {
            if showSettings { showSettings = false } // Close settings if open
            // userInput = "" // Don't clear user input here, might be needed for first message

            // Create Conversation with an empty [ChatMessage] array
            let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
            conversations.append(newConversation)
            sortConversations() // Sort after adding
            selectedConversationID = newConversation.id // Select the new conversation
            logger.info("Created and selected new conversation with ID: \(newConversation.id.uuidString)")
            // --- SAVE Conversations --- (Save immediately upon creation)
            PersistenceService.saveConversations(self.conversations)
            logger.debug("Saved conversations after creating new one.")
            // ------------------------
            return newConversation.id // Return the ID
        }

    // --- *** UPDATED sendMessage Logic *** ---
    func sendMessage() {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("sendMessage called. Backend: \(self.selectedBackend.rawValue), isSending: \(self.isSending), trimmedInput: \(trimmedInput)")

        guard !isSending else { logger.warning("sendMessage aborted: Already sending."); return }
        guard !trimmedInput.isEmpty else { logger.info("sendMessage aborted: Input empty."); userInput = ""; return }
        // Allow sending even if settings are technically open, as layout might change
        // guard !showSettings else { logger.warning("sendMessage aborted: Settings open."); return }

        // --- NEW: Create conversation IF needed ---
        var conversationIDToUse: UUID
        if let currentID = selectedConversationID {
            // Use existing selected conversation ID
            conversationIDToUse = currentID
            logger.debug("Sending message to existing conversation: \(conversationIDToUse.uuidString)")
        } else {
            // No conversation selected, create a new one NOW
            logger.info("No conversation selected. Creating new one before sending.")
            conversationIDToUse = createAndSelectNewConversation() // Creates, selects, and saves
            // selectedConversationID is now set
        }
        // --- END NEW ---

        // Safely get the index for the conversation (should always exist now)
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationIDToUse }) else {
            logger.error("CRITICAL: Could not find conversation index for ID: \(conversationIDToUse.uuidString) even after creation check.")
            return // Exit if index somehow not found
        }

        // Context Integration - Prepare the prompt string for the backend
        var contextPrefix = ""
        if showContextArea, let filePath = activeContextFilePath {
            contextPrefix = "Context File: \(filePath)\n\nUser Message:\n"
        }
        let messageToSendToBackend = contextPrefix + trimmedInput

        // Create and Append User ChatMessage
        let userMessage = ChatMessage(
            conversationId: conversationIDToUse, // Use the determined ID
            sender: .user,
            content: .plainText(trimmedInput)
        )
        conversations[conversationIndex].messages.append(userMessage)
        conversations[conversationIndex].timestamp = Date() // Update timestamp
        sortConversations()
        // Note: Saving happens after agent response

        // Prepare for backend call
        let messageLogForBackend = messageToSendToBackend
        userInput = "" // Clear input field
        isSending = true

        // Perform Network Call Asynchronously
        Task {
            var resultingMessages: [ChatMessage] = []
            // Removed earlyExit flag

            // Check server status before sending (Ollama specific)
            if selectedBackend == .ollama {
                 if ollamaServerStatus != .connected && ollamaServerStatus != .checking {
                      await checkOllamaServerStatus()
                 }
                // --- MODIFIED GUARD ---
                guard ollamaServerStatus == .connected else {
                    let errorMsg = "Cannot send message: Ollama server is not connected."
                    logger.error("\(errorMsg)")
                    let errorMessage = ChatMessage( conversationId: conversationIDToUse, sender: .agent, content: .error(title: "Connection Error", details: errorMsg) )
                    self.handleAgentResponse(message: errorMessage) // Add error to UI
                    self.isSending = false                           // Reset sending state
                    PersistenceService.saveConversations(self.conversations) // Save state with error
                    return // *** EXIT Task immediately ***
                }
                // --- END MODIFIED GUARD ---
            }

            // Proceed with API call (no need for !earlyExit check)
            let backendConfig = self.determineBackendConfiguration(message: messageLogForBackend)
            do {
                logger.debug("Sending task '\(messageLogForBackend.prefix(200))' to \(backendConfig.url)\(backendConfig.endpoint) for conversation \(conversationIDToUse.uuidString)")
                let responseData = try await self.aiConnect.postToLocalServer(
                    endpoint: backendConfig.endpoint,
                    payload: backendConfig.payload
                )
                let responseText = self.parseResponse(data: responseData, for: self.selectedBackend)
                let parsedContents = self.parseAgentResponseString(responseText)

                for content in parsedContents {
                    let agentMessage = ChatMessage(
                        conversationId: conversationIDToUse, // Use the determined ID
                        sender: .agent,
                        content: content
                    )
                    resultingMessages.append(agentMessage)
                }

            } catch {
                logger.error("Error during API call or parsing: \(error.localizedDescription)")
                let errorText = self.generateErrorMessage(error: error)
                let errorMessage = ChatMessage(
                    conversationId: conversationIDToUse, // Use the determined ID
                    sender: .agent,
                    content: .error(title: "Processing Error", details: errorText)
                )
                resultingMessages.append(errorMessage)
                 if selectedBackend == .ollama {
                     if let urlError = error as? URLError, (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                          self.ollamaServerStatus = .disconnected
                     }
                 }
            }

            // Handle potentially MULTIPLE agent/error messages
            var messageHandled = false
            for resultMessage in resultingMessages {
                 self.handleAgentResponse(message: resultMessage) // Append each message
                 messageHandled = true
            }

            // Save conversations *after* all messages from this response/error are appended
            if messageHandled {
                 PersistenceService.saveConversations(self.conversations)
                 logger.debug("Saved conversations after processing agent response.")
            }

            // Manage sending state
            self.isSending = false // Always set sending to false when task completes
            if !messageHandled { // Simplified check (no earlyExit needed)
                 logger.warning("sendMessage Task finished but generated no messages to handle.")
            }
        } // End Task
    }

    // Handles appending a single message to the correct conversation
    // Does NOT manage isSending flag or saving.
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

    // --- UI Toggles ---
    func toggleSidebar() { withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() } }
    func toggleSettings() { withAnimation { showSettings.toggle() } }
    func toggleContextArea() {
         withAnimation { showContextArea.toggle() }
         if showContextArea { logger.info("Context toggled: Showing (Simulated).") }
         else { activeContextFilePath = nil; logger.info("Context toggled: Hiding.") }
    }

    // MARK: - Ollama Server Status (Full Implementation)
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

    // MARK: - Local AI Model Management Actions (Full Implementations)
    func loadLocalOllamaModels() async {
        guard selectedBackend == .ollama else { return }
        guard !isPullingModel && !isRemovingModel else { return }
        guard ollamaServerStatus == .connected else { self.localOllamaModels = []; return }

        isLoadingModels = true
        modelLoadingError = nil
        let ollamaBaseURL = "http://localhost:11434"
        logger.info("Loading local Ollama models from \(ollamaBaseURL)...")
        do {
            let models = try await AIConnect.fetchLocalOllamaModels(baseURL: ollamaBaseURL)
            self.localOllamaModels = models.sorted()
            self.modelLoadingError = nil
            logger.info("Loaded \(models.count) local Ollama models.")
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

    func pullModelAction(name modelName: String) async {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else { self.modelPullError = "Model name cannot be empty."; return }
        guard !isPullingModel else { logger.warning("Already pulling a model."); return }
        guard !isRemovingModel else { logger.warning("Attempted to pull model while another model is being removed."); self.modelPullError = "Cannot pull model: Another model is currently being removed."; return }
        guard selectedBackend == .ollama else { logger.warning("Attempted to pull model but backend is not Ollama."); self.modelPullError = "Cannot pull models when Ollama is not the selected backend."; return }
        guard ollamaServerStatus == .connected else {
             let errorMsg = "Cannot pull model: Ollama server is not connected."
             logger.warning("\(errorMsg)")
             self.modelPullError = errorMsg
             return
         }

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
                    logger.debug("Pull progress: Status=\(progress.status), Completed=\(progress.completed ?? -1), Total=\(progress.total ?? -1), Percentage=\(progress.percentage ?? -1)")
                }
            }
            self.pullStatusMessage = "Successfully pulled \(trimmedModelName)."
            self.modelPullError = nil; self.pullProgress = 1.0; self.pullStage = "Complete"
            logger.info("Model \(trimmedModelName) pulled successfully (streaming finished).")
            Task { await loadLocalOllamaModels() }
        } catch {
            let errorMessage = self.generateErrorMessage(error: error)
            self.pullStatusMessage = "Failed to pull \(trimmedModelName)."
            self.modelPullError = "Pull failed: \(errorMessage)"
            self.pullProgress = 0.0; self.pullStage = "Error"
            logger.error("Failed to pull model \(trimmedModelName): \(error.localizedDescription)")
            if let urlError = error as? URLError, (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                 self.ollamaServerStatus = .disconnected
                 logger.error("Setting server status to disconnected due to model pull network error.")
            }
        }
        isPullingModel = false
        try? await Task.sleep(nanoseconds: 2_000_000_000) // Delay before clearing status
        if modelPullError == nil { self.modelToPull = "" }
        self.pullStatusMessage = ""; self.pullStage = ""; self.pullProgress = 0.0
    }

    func removeModelAction(name modelName: String) async {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else { self.modelRemoveError = "Model name cannot be empty for removal."; return }
        guard trimmedModelName != self.llmModelName else { logger.warning("Attempted to remove the currently selected model '\(trimmedModelName)'."); self.modelRemoveError = "Cannot remove the currently active model."; return }
        guard self.localOllamaModels.contains(trimmedModelName) else { logger.warning("Attempted to remove model '\(trimmedModelName)' which is not in the local list."); self.modelRemoveError = "Model '\(trimmedModelName)' not found in local list."; return }
        guard !isRemovingModel else { logger.warning("Already removing a model."); return }
        guard !isPullingModel else { logger.warning("Attempted to remove model while another model is being pulled."); self.modelRemoveError = "Cannot remove model: Another model is currently being pulled."; return }
        guard selectedBackend == .ollama else { logger.warning("Attempted to remove model but backend is not Ollama."); self.modelRemoveError = "Cannot remove models when Ollama is not the selected backend."; return }
        guard ollamaServerStatus == .connected else {
             let errorMsg = "Cannot remove model: Ollama server is not connected."
             logger.warning("\(errorMsg)")
             self.modelRemoveError = errorMsg
             return
         }

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
                 logger.error("Setting server status to disconnected due to model removal network error.")
            }
        }
        isRemovingModel = false
        // Optionally clear status after delay
    }

    // MARK: - Agent Response Parsing Helper
    /// Parses the raw text response from the agent into distinct content blocks.
    /// Handles Markdown, Code Blocks, and extracts Image nodes.
    /// - Parameter responseText: The raw String response from the AI backend.
    /// - Returns: An array of MessageContent blocks.
    private func parseAgentResponseString(_ responseText: String) -> [MessageContent] {
            logger.debug("Parsing agent response string (length: \(responseText.count))...")
            var contentBlocks: [MessageContent] = []
            // Ensure Markdown library is imported at the top of the file: import Markdown
            let document = Document(parsing: responseText)

            for block in document.children {
                // Process each top-level block from the parsed document
                processMarkdownBlock(block, into: &contentBlocks)
            }

            // Handle edge case: If parsing yields nothing but the original text wasn't empty,
            // return the original text as plain text to avoid losing it.
            if contentBlocks.isEmpty && !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                 logger.warning("Markdown parsing resulted in no content blocks, returning original text as plain.")
                 return [.plainText(responseText)]
             }

            logger.info("Parsed response into \(contentBlocks.count) content blocks.")
            return contentBlocks
    }

    private func processMarkdownBlock(_ block: Markup, into contentBlocks: inout [MessageContent]) {
            switch block {
            case let codeBlock as CodeBlock:
                // ... (code block handling remains the same) ...
                 let codeContent = codeBlock.code.trimmingCharacters(in: .whitespacesAndNewlines)
                 if !codeContent.isEmpty {
                     logger.trace("Found Code Block, language: \(codeBlock.language ?? "nil")")
                     contentBlocks.append(.codeBlock(language: codeBlock.language, code: codeContent))
                 } else { logger.trace("Skipping empty Code Block.") }

            // <<< START CORRECTED IMAGE HANDLING (Iterator Check) >>>
            case let paragraph as Paragraph:
                // Check if the first child is an Image
                if let imageNode = paragraph.children.first as? Markdown.Image {
                    // Now check if the sequence *after* the first element is empty
                    var iterator = paragraph.children.dropFirst().makeIterator()
                    if iterator.next() == nil {
                        // If next() is nil immediately, the sequence after the first element was empty.
                        // This means the paragraph contained exactly one child, which is the imageNode.
                        logger.trace("Found Paragraph containing only an Image (using iterator check).")
                        processImageNode(imageNode, into: &contentBlocks)
                    } else {
                        // There were more elements after the first one. Treat as regular markdown.
                        appendAsMarkdown(paragraph, into: &contentBlocks)
                    }
                } else {
                    // The first child wasn't an image (or the paragraph was empty). Treat as regular markdown.
                    appendAsMarkdown(paragraph, into: &contentBlocks)
                }
            // <<< END CORRECTED IMAGE HANDLING (Iterator Check) >>>

            case let imageNode as Markdown.Image:
                 // Handle image nodes that might appear directly
                 logger.trace("Found direct Image Node (unexpected?).")
                 processImageNode(imageNode, into: &contentBlocks)

            case let blockquote as BlockQuote:
                // ... (blockquote handling remains the same) ...
                 let quoteContent = blockquote.format().trimmingCharacters(in: .whitespacesAndNewlines)
                 if !quoteContent.isEmpty { logger.trace("Found Block Quote."); contentBlocks.append(.markdownText(quoteContent)) }
                 else { logger.trace("Skipping empty Block Quote.") }

            default:
                // Default: Format block back to markdown text
                appendAsMarkdown(block, into: &contentBlocks)
            }
        }

    // Helper to extract info from an Image node
    private func processImageNode(_ imageNode: Markdown.Image, into contentBlocks: inout [MessageContent]) {
        let urlString = imageNode.source
        let altText = imageNode.plainText // Collect alt text from children

        if let urlString = urlString, !urlString.isEmpty {
            let url = URL(string: urlString) // URL init is failable
            logger.trace("Found Image Node, url: \(urlString), alt: \(altText)")
            contentBlocks.append(.image(url: url, alt: altText)) // Add as image block
            // Note: If URL(string:) fails, url will be nil, handled by ImageView
        } else {
            logger.warning("Skipping Image Node with missing or empty source.")
        }
    }

    // Helper to format a block as markdown and add it
    private func appendAsMarkdown(_ block: Markup, into contentBlocks: inout [MessageContent]) {
         let markdownContent = block.format().trimmingCharacters(in: .whitespacesAndNewlines)
         if !markdownContent.isEmpty {
             logger.trace("Found block (\(type(of: block))), treating as Markdown.")
             contentBlocks.append(.markdownText(markdownContent))
         } else {
             logger.trace("Skipping empty block (\(type(of: block))).")
         }
     }

    // MARK: - Private Helper Functions
    private func sortConversations() { conversations.sort { $0.timestamp > $1.timestamp } }
    private struct BackendConfiguration { let url: String; let endpoint: String; let payload: [String: Any] }
    private func determineBackendConfiguration(message: String) -> BackendConfiguration {
        switch self.selectedBackend {
        case .ollama:
            let advancedOptions: [String: Any] = [
                "temperature": self.ollamaTemperature, "top_k": self.ollamaTopK,
                "top_p": self.ollamaTopP, "repeat_penalty": self.ollamaRepeatPenalty,
                "num_ctx": self.ollamaContextWindowSize, "num_gpu": self.ollamaGpuLayers
            ]
            return BackendConfiguration( url: "http://127.0.0.1:11434", endpoint: "/api/generate",
                payload: [ "model": self.llmModelName, "prompt": message, "stream": false, "options": advancedOptions ]
            )
        case .agent:
            return BackendConfiguration( url: self.agentBaseURL, endpoint: "/execute_task",
                payload: [ "main_task": message, "strategy": self.agentDelegationStrategy ]
            )
        }
    }

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
                      if let rawResponse = String(data: data, encoding: .utf8) { logger.warning("Ollama JSON response: \(rawResponse)") }
                     return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode non-JSON Ollama response."
                 }
                 logger.debug("Parsed Ollama response.")
                 return reply.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logger.error("Failed to parse JSON response: \(error.localizedDescription)")
             if let rawResponse = String(data: data, encoding: .utf8) { logger.error("Raw data that failed to parse: \(rawResponse)") }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode server response (\(error.localizedDescription))."
        }
    }

    // Removing the duplicate handleAgentResponse function that used [String]
    // private func handleAgentResponse(response: String, conversationID: UUID) { ... }

    private func generateErrorMessage(error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost: return "Error: Could not connect to the server (\(self.selectedBackend.rawValue)). Check if it's running and the URL/Port is correct."
            case .networkConnectionLost: return "Error: Network connection lost."
            case .notConnectedToInternet: return "Error: Not connected to the internet."
            case .badServerResponse:
                 let httpStatusCode = urlError.userInfo["HTTPStatusCode"] as? Int
                 let responseData = urlError.userInfo["ResponseData"] as? Data
                 let responseBody = responseData.flatMap { String(data: $0, encoding: .utf8) } ?? "No response body"
                 let statusString = httpStatusCode.map { " (\($0))" } ?? "" // Corrected
                 if let data = responseData, let ollamaError = parseOllamaErrorResponse(data: data) { return "Ollama Error\(statusString): \(ollamaError)" }
                 return "Error: Bad server response\(statusString). \(responseBody.prefix(150))"
            case .cannotFindHost: return "Error: Cannot find the server host (\(self.selectedBackend.rawValue)). Check address/DNS."
            case URLError.Code(rawValue: 1): return "Error: Operation not permitted (check Sandbox/Firewall)."
             case .cancelled: return "Request cancelled."
            default: logger.warning("Unhandled URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)"); return "Error: Network request failed (\(urlError.localizedDescription))."
            }
        }
        logger.warning("Unhandled error type: \(type(of: error)) - \(error.localizedDescription)")
        return "Error: \(error.localizedDescription)"
    }

    private func parseOllamaErrorResponse(data: Data) -> String? {
         guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String else { return nil }
         return error.trimmingCharacters(in: .whitespacesAndNewlines)
     }

    // Removing outdated TODO comments for Persistence
    // --- TODO: Implement File Reading ---
    // func readFileContent(at path: String) -> String? { ... }
    // --- TODO: Implement Persistence ---
    // func saveConversations() { ... }
    // func loadConversations() { ... }

    // MARK: - State Reset / Cleanup
     func clearModelActionStatus() {
         pullStatusMessage = ""; modelPullError = nil; pullProgress = 0.0; pullStage = ""
         pullTotalBytes = nil; pullCompletedBytes = nil; modelRemoveError = nil; removingModelName = nil
     }
     func clearPullStatus() {
         pullStatusMessage = ""; modelPullError = nil; pullProgress = 0.0; pullStage = ""
         pullTotalBytes = nil; pullCompletedBytes = nil
     }
      func clearRemoveStatus() {
          modelRemoveError = nil; removingModelName = nil
      }
    
    func deleteConversation(conversationID: UUID) {
        logger.info("Attempting to delete conversation with ID: \(conversationID.uuidString)")
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
            logger.error("Failed to delete: Conversation ID \(conversationID.uuidString) not found.")
            return
        }

        let conversationWasSelected = (selectedConversationID == conversationID)
        let countBeforeDelete = conversations.count

        // Remove the conversation
        conversations.remove(at: index)
        logger.info("Successfully removed conversation at index \(index).")

        // Handle selection after deletion
        if conversationWasSelected {
            if conversations.isEmpty {
                // No conversations left, deselect
                selectedConversationID = nil
                logger.debug("No conversations left after delete, selection cleared.")
                // Optional: Automatically start a new one?
                // startNewConversation()
            } else if index < conversations.count {
                // Select the conversation that took the deleted one's place (index is valid)
                selectedConversationID = conversations[index].id
                logger.debug("Selected conversation at index \(index) after delete: \(self.conversations[index].id.uuidString)")
            } else {
                // Deleted the last item, select the new last item
                selectedConversationID = conversations.last?.id
                logger.debug("Deleted the last conversation, selecting new last: \(String(describing: self.conversations.last?.id.uuidString))")
            }
        } else {
            logger.debug("Deleted conversation was not selected, selection remains: \(String(describing: self.selectedConversationID))")
        }

        // Persist the changes
        PersistenceService.saveConversations(self.conversations)
        logger.debug("Saved conversations after deleting one.")

        // Ensure sorting is maintained if needed (shouldn't change order unless sorting key removed)
        // sortConversations() // Likely not needed unless deletion affects sorting criteria
    }
    
    // >>> START: Added Code Block (Part B) <<<
        /// Renames the specified conversation with a user-defined title.
        /// - Parameters:
        ///   - conversationID: The ID of the conversation to rename.
        ///   - newTitle: The new title string. If empty or whitespace, the custom title is removed.
        func renameConversation(conversationID: UUID, newTitle: String) {
            logger.info("Attempting to rename conversation ID \(conversationID.uuidString) to '\(newTitle)'")
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
                logger.error("Failed to rename: Conversation ID \(conversationID.uuidString) not found.")
                return
            }

            let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)

            // Update the title. Set to nil if the new title is empty/whitespace
            // This allows users to clear a custom title and revert to the default generated one.
            conversations[index].userDefinedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle

            // Optional: Update timestamp? Usually not needed for rename.
            // conversations[index].timestamp = Date()

            // Optional: Re-sort? Only if sorting depends on displayTitle, which is unlikely.
            // sortConversations()

            logger.info("Successfully updated title for conversation \(conversationID.uuidString). New title: '\(self.conversations[index].userDefinedTitle ?? "nil (reverted to default)")'")

            // Persist the changes
            PersistenceService.saveConversations(self.conversations)
            logger.debug("Saved conversations after renaming one.")

            // Trigger UI update manually if needed (sometimes necessary for nested properties)
            // This forces views observing the 'conversations' array to redraw, even if only a property inside changed.
            objectWillChange.send()
        }
}
