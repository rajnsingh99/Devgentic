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
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?
    @Published var isSending: Bool = false
    @Published var userInput: String = ""
    @Published var isSidebarCollapsed: Bool = true
    @Published var showSettings: Bool = false
    @Published var selectedSettingsSection: SettingsSection = .general {
        didSet {
            if selectedSettingsSection == .localAI && selectedBackend == .ollama {
                Task {
                    await checkOllamaServerStatus()
                }
            } else {
                 self.ollamaServerStatus = .unknown
                 self.localOllamaModels = []
                 self.modelLoadingError = nil
                 self.clearModelActionStatus()
            }
        }
    }
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil

    // --- NEW: State for filtering messages ---
    @Published var isUserMessagesOnlyFilterActive: Bool = false
    // -----------------------------------------

    // --- Settings Properties (loaded/saved via @AppStorage) ---
    @AppStorage(SettingsKeys.selectedBackend) var selectedBackend: BackendType = .ollama
    @AppStorage(SettingsKeys.windowOpacity) var windowOpacity: Double = 1.0
    @AppStorage(SettingsKeys.llmModelName) var llmModelName: String = "gemma:2b" // Default model
    @AppStorage(SettingsKeys.agentBaseURL) var agentBaseURL: String = "http://127.0.0.1:8000"
    @AppStorage(SettingsKeys.agentDelegationStrategy) var agentDelegationStrategy: String = "send_to_first_available"
    @AppStorage(SettingsKeys.ollamaTemperature) var ollamaTemperature: Double = 0.8
    @AppStorage(SettingsKeys.ollamaTopK) var ollamaTopK: Int = 40
    @AppStorage(SettingsKeys.ollamaTopP) var ollamaTopP: Double = 0.9
    @AppStorage(SettingsKeys.ollamaRepeatPenalty) var ollamaRepeatPenalty: Double = 1.1
    @AppStorage(SettingsKeys.ollamaContextWindowSize) var ollamaContextWindowSize: Int = 4096
    @AppStorage(SettingsKeys.ollamaGpuLayers) var ollamaGpuLayers: Int = -1

    @Published var localOllamaModels: [String] = []
    @Published var isLoadingModels: Bool = false
    @Published var modelLoadingError: String? = nil
    @Published var modelToPull: String = ""
    @Published var isPullingModel: Bool = false
    @Published var pullStatusMessage: String = ""
    @Published var modelPullError: String? = nil
    @Published var pullProgress: Double = 0.0
    @Published var pullStage: String = ""
    @Published var pullTotalBytes: Int64? = nil
    @Published var pullCompletedBytes: Int64? = nil
    @Published var isRemovingModel: Bool = false
    @Published var removingModelName: String? = nil
    @Published var modelRemoveError: String? = nil
    @Published var ollamaServerStatus: OllamaServerStatus = .unknown


    // MARK: - Dependencies
    private let aiConnect = AIConnect()
    private let groupDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    // MARK: - Computed Properties (Derived State)

    // --- UPDATED: currentChatMessages now respects the filter ---
    var currentChatMessages: [ChatMessage] {
        guard let selectedID = selectedConversationID,
              let conversation = conversations.first(where: { $0.id == selectedID }) else {
            return []
        }
        
        if isUserMessagesOnlyFilterActive {
            // Filter to show only user messages
            return conversation.messages.filter { $0.sender == .user }
        } else {
            // Show all messages
            return conversation.messages
        }
    }
    // -----------------------------------------------------------

    var currentConversationTitle: String {
        guard let conversation = conversations.first(where: { $0.id == selectedConversationID }) else {
            return conversations.isEmpty ? "Devgentic" : "Select Chat"
        }
        return conversation.displayTitle
    }

    var groupedConversations: [String: [Conversation]] {
        let grouped = conversations.reduce(into: [String: [Conversation]]()) { result, conversation in
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
    init() {
        self.conversations = PersistenceService.loadConversations()
        selectInitialConversation()
        logger.info("MainApplicationViewModel initialized. Loaded \(self.conversations.count) conversations.")
    }

    private func selectInitialConversation() {
        sortConversations()
        if selectedConversationID == nil || !conversations.contains(where: { $0.id == selectedConversationID }) {
            selectedConversationID = conversations.first?.id
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

    // --- NEW: Method to toggle the message filter ---
    func toggleUserMessagesFilter() {
        isUserMessagesOnlyFilterActive.toggle()
        logger.info("User messages filter toggled. Active: \(self.isUserMessagesOnlyFilterActive)")
    }
    // -----------------------------------------------
    
    func startNewConversation() {
        if showSettings { showSettings = false }
        userInput = ""
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        conversations.append(newConversation)
        sortConversations()
        selectedConversationID = newConversation.id
        logger.info("Started new conversation with ID: \(newConversation.id.uuidString)")
        PersistenceService.saveConversations(self.conversations)
        logger.debug("Saved conversations after starting new one.")
        isUserMessagesOnlyFilterActive = false // Reset filter for new conversation
    }

    @discardableResult
    func createAndSelectNewConversation() -> UUID {
        if showSettings { showSettings = false }
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        conversations.append(newConversation)
        sortConversations()
        selectedConversationID = newConversation.id
        logger.info("Created and selected new conversation with ID: \(newConversation.id.uuidString)")
        PersistenceService.saveConversations(self.conversations)
        logger.debug("Saved conversations after creating new one.")
        isUserMessagesOnlyFilterActive = false // Reset filter
        return newConversation.id
    }

    func sendMessage() {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("sendMessage called. Backend: \(self.selectedBackend.rawValue), isSending: \(self.isSending), trimmedInput: \(trimmedInput)")

        guard !isSending else { logger.warning("sendMessage aborted: Already sending."); return }
        guard !trimmedInput.isEmpty else { logger.info("sendMessage aborted: Input empty."); userInput = ""; return }

        var conversationIDToUse: UUID
        if let currentID = selectedConversationID {
            conversationIDToUse = currentID
            logger.debug("Sending message to existing conversation: \(conversationIDToUse.uuidString)")
        } else {
            logger.info("No conversation selected. Creating new one before sending.")
            conversationIDToUse = createAndSelectNewConversation()
        }

        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationIDToUse }) else {
            logger.error("CRITICAL: Could not find conversation index for ID: \(conversationIDToUse.uuidString)")
            return
        }

        var contextPrefix = ""
        if showContextArea, let filePath = activeContextFilePath {
            contextPrefix = "Context File: \(filePath)\n\nUser Message:\n"
        }
        let messageToSendToBackend = contextPrefix + trimmedInput

        let userMessage = ChatMessage(
            conversationId: conversationIDToUse,
            sender: .user,
            content: .plainText(trimmedInput)
        )
        conversations[conversationIndex].messages.append(userMessage)
        conversations[conversationIndex].timestamp = Date()
        sortConversations()
        
        // If filter is active, temporarily turn it off to show the user's new message and agent's response
        // It will be re-applied by the user if they wish.
        if isUserMessagesOnlyFilterActive {
            // isUserMessagesOnlyFilterActive = false // Consider if this is desired UX
            // logger.info("Temporarily deactivated user messages filter to show new exchange.")
        }


        let messageLogForBackend = messageToSendToBackend
        userInput = ""
        isSending = true

        Task {
            var resultingMessages: [ChatMessage] = []
            
            if selectedBackend == .ollama {
                 if ollamaServerStatus != .connected && ollamaServerStatus != .checking {
                      await checkOllamaServerStatus()
                 }
                guard ollamaServerStatus == .connected else {
                    let errorMsg = "Cannot send message: Ollama server is not connected."
                    logger.error("\(errorMsg)")
                    let errorMessage = ChatMessage( conversationId: conversationIDToUse, sender: .agent, content: .error(title: "Connection Error", details: errorMsg) )
                    self.handleAgentResponse(message: errorMessage)
                    self.isSending = false
                    PersistenceService.saveConversations(self.conversations)
                    return
                }
            }

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
                        conversationId: conversationIDToUse,
                        sender: .agent,
                        content: content
                    )
                    resultingMessages.append(agentMessage)
                }

            } catch {
                logger.error("Error during API call or parsing: \(error.localizedDescription)")
                let errorText = self.generateErrorMessage(error: error)
                let errorMessage = ChatMessage(
                    conversationId: conversationIDToUse,
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

            var messageHandled = false
            for resultMessage in resultingMessages {
                 self.handleAgentResponse(message: resultMessage)
                 messageHandled = true
            }

            if messageHandled {
                 PersistenceService.saveConversations(self.conversations)
                 logger.debug("Saved conversations after processing agent response.")
            }

            self.isSending = false
            if !messageHandled {
                 logger.warning("sendMessage Task finished but generated no messages to handle.")
            }
        }
    }

    private func handleAgentResponse(message: ChatMessage) {
        if let updatedIndex = self.conversations.firstIndex(where: { $0.id == message.conversationId }) {
            self.conversations[updatedIndex].messages.append(message)
            self.conversations[updatedIndex].timestamp = Date()
            self.sortConversations()
            logger.debug("Appended message ID \(message.id.uuidString) (Sender: \(String(describing: message.sender))) to conversation \(message.conversationId.uuidString)")
        } else {
            logger.error("Error: Conversation \(message.conversationId.uuidString) disappeared before message (ID: \(message.id.uuidString)) could be added.")
        }
    }

    func toggleSidebar() { withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() } }
    func toggleSettings() { withAnimation { showSettings.toggle() } }
    func toggleContextArea() {
         withAnimation { showContextArea.toggle() }
         if showContextArea { logger.info("Context toggled: Showing (Simulated).") }
         else { activeContextFilePath = nil; logger.info("Context toggled: Hiding.") }
    }

    func checkOllamaServerStatus() async {
        guard selectedBackend == .ollama && ollamaServerStatus != .checking else {
             if selectedBackend != .ollama { self.ollamaServerStatus = .unknown }
             return
         }
        self.ollamaServerStatus = .checking
        let ollamaBaseURL = "http://localhost:11434"
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
        guard !isRemovingModel else { self.modelPullError = "Cannot pull model: Another model is currently being removed."; return }
        guard selectedBackend == .ollama else { self.modelPullError = "Cannot pull models when Ollama is not the selected backend."; return }
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
            }
        }
        isPullingModel = false
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if modelPullError == nil { self.modelToPull = "" }
        self.pullStatusMessage = ""; self.pullStage = ""; self.pullProgress = 0.0
    }

    func removeModelAction(name modelName: String) async {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else { self.modelRemoveError = "Model name cannot be empty for removal."; return }
        guard trimmedModelName != self.llmModelName else { self.modelRemoveError = "Cannot remove the currently active model."; return }
        guard self.localOllamaModels.contains(trimmedModelName) else { self.modelRemoveError = "Model '\(trimmedModelName)' not found in local list."; return }
        guard !isRemovingModel else { logger.warning("Already removing a model."); return }
        guard !isPullingModel else { self.modelRemoveError = "Cannot remove model: Another model is currently being pulled."; return }
        guard selectedBackend == .ollama else { self.modelRemoveError = "Cannot remove models when Ollama is not the selected backend."; return }
        guard ollamaServerStatus == .connected else {
             let errorMsg = "Cannot remove model: Ollama server is not connected."
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
            }
        }
        isRemovingModel = false
    }

    private func parseAgentResponseString(_ responseText: String) -> [MessageContent] {
            logger.debug("Parsing agent response string (length: \(responseText.count))...")
            var contentBlocks: [MessageContent] = []
            let document = Document(parsing: responseText)

            for block in document.children {
                processMarkdownBlock(block, into: &contentBlocks)
            }

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
                 let codeContent = codeBlock.code.trimmingCharacters(in: .whitespacesAndNewlines)
                 if !codeContent.isEmpty {
                     logger.trace("Found Code Block, language: \(codeBlock.language ?? "nil")")
                     contentBlocks.append(.codeBlock(language: codeBlock.language, code: codeContent))
                 } else { logger.trace("Skipping empty Code Block.") }

            case let paragraph as Paragraph:
                if let imageNode = paragraph.children.first as? Markdown.Image {
                    var iterator = paragraph.children.dropFirst().makeIterator()
                    if iterator.next() == nil {
                        logger.trace("Found Paragraph containing only an Image (using iterator check).")
                        processImageNode(imageNode, into: &contentBlocks)
                    } else {
                        appendAsMarkdown(paragraph, into: &contentBlocks)
                    }
                } else {
                    appendAsMarkdown(paragraph, into: &contentBlocks)
                }

            case let imageNode as Markdown.Image:
                 logger.trace("Found direct Image Node (unexpected?).")
                 processImageNode(imageNode, into: &contentBlocks)

            case let blockquote as BlockQuote:
                 let quoteContent = blockquote.format().trimmingCharacters(in: .whitespacesAndNewlines)
                 if !quoteContent.isEmpty { logger.trace("Found Block Quote."); contentBlocks.append(.markdownText(quoteContent)) }
                 else { logger.trace("Skipping empty Block Quote.") }

            default:
                appendAsMarkdown(block, into: &contentBlocks)
            }
        }

    private func processImageNode(_ imageNode: Markdown.Image, into contentBlocks: inout [MessageContent]) {
        let urlString = imageNode.source
        let altText = imageNode.plainText

        if let urlString = urlString, !urlString.isEmpty {
            let url = URL(string: urlString)
            logger.trace("Found Image Node, url: \(urlString), alt: \(altText)")
            contentBlocks.append(.image(url: url, alt: altText))
        } else {
            logger.warning("Skipping Image Node with missing or empty source.")
        }
    }

    private func appendAsMarkdown(_ block: Markup, into contentBlocks: inout [MessageContent]) {
         let markdownContent = block.format().trimmingCharacters(in: .whitespacesAndNewlines)
         if !markdownContent.isEmpty {
             logger.trace("Found block (\(type(of: block))), treating as Markdown.")
             contentBlocks.append(.markdownText(markdownContent))
         } else {
             logger.trace("Skipping empty block (\(type(of: block))).")
         }
     }

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
                 let statusString = httpStatusCode.map { " (\($0))" } ?? ""
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
            logger.info("Attempting to delete single conversation with ID: \(conversationID.uuidString)")
            deleteMultipleConversations(ids: [conversationID])
    }

    func deleteMultipleConversations(ids: Set<UUID>) {
        guard !ids.isEmpty else {
            logger.info("deleteMultipleConversations called with empty ID set.")
            return
        }
        logger.info("Attempting to delete \(ids.count) conversations.")

        let initialCount = conversations.count
        let selectionBeforeDelete = selectedConversationID

        conversations.removeAll { ids.contains($0.id) }

        let countAfterDelete = conversations.count
        let numDeleted = initialCount - countAfterDelete
        logger.info("Deleted \(numDeleted) conversations.")

        if let currentSelection = selectionBeforeDelete, ids.contains(currentSelection) {
            logger.debug("Selected conversation (\(currentSelection.uuidString)) was deleted.")
            selectedConversationID = conversations.first?.id
            if let newSelection = selectedConversationID {
                logger.debug("New selection set to first remaining conversation: \(newSelection.uuidString)")
            } else {
                logger.debug("No conversations remain, selection cleared.")
            }
        } else {
             logger.debug("Selected conversation was not among those deleted, selection remains: \(String(describing: selectionBeforeDelete))")
        }

        if numDeleted > 0 {
            PersistenceService.saveConversations(self.conversations)
            logger.debug("Saved conversations after deleting multiple.")
        }
    }

    func deleteConversationsInGroup(groupKey: String) {
        logger.info("Attempting to delete all conversations in group: \(groupKey)")
        let idsToDelete = conversations.filter { self.groupKey(for: $0.timestamp) == groupKey }.map { $0.id }

        if idsToDelete.isEmpty {
            logger.warning("No conversations found for group key '\(groupKey)'. Nothing to delete.")
            return
        }
        logger.debug("Found \(idsToDelete.count) conversations to delete in group '\(groupKey)'.")
        deleteMultipleConversations(ids: Set(idsToDelete))
    }
    
    func renameConversation(conversationID: UUID, newTitle: String) {
            logger.info("Attempting to rename conversation ID \(conversationID.uuidString) to '\(newTitle)'")
            guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else {
                logger.error("Failed to rename: Conversation ID \(conversationID.uuidString) not found.")
                return
            }
            let trimmedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            conversations[index].userDefinedTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
            logger.info("Successfully updated title for conversation \(conversationID.uuidString). New title: '\(self.conversations[index].userDefinedTitle ?? "nil (reverted to default)")'")
            PersistenceService.saveConversations(self.conversations)
            logger.debug("Saved conversations after renaming one.")
            objectWillChange.send()
        }

    func groupKey(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return self.groupDateFormatter.string(from: date)
        }
    }
}
