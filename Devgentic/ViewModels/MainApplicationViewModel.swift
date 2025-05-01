// ViewModels/MainApplicationViewModel.swift
import SwiftUI
import Combine // Needed for ObservableObject and @Published
import os     // For logging

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
    // ... (Existing properties remain the same) ...
    @Published var conversations: [Conversation] = []
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
    // ... (Computed properties remain the same) ...
    var currentChatHistory: [String] {
        guard let selectedID = selectedConversationID,
              let conversation = conversations.first(where: { $0.id == selectedID }) else {
            return []
        }
        return conversation.messages
    }

    var currentConversationTitle: String {
        guard let conversation = conversations.first(where: { $0.id == selectedConversationID }) else {
            return conversations.isEmpty ? "Devgentic" : "Select Chat"
        }
        return conversation.displayTitle
    }

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
        self.conversations = initialConversations
        selectInitialConversation()
        logger.info("MainApplicationViewModel initialized.")
    }

    // loadSettings is now redundant for persistence due to @AppStorage
    private func loadSettings() {
         logger.debug("loadSettings called (persistence handled by @AppStorage).")
    }


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

    func startNewConversation() {
        if showSettings { showSettings = false }
        userInput = ""
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        conversations.append(newConversation)
        sortConversations()
        selectedConversationID = newConversation.id
        logger.info("Started new conversation with ID: \(newConversation.id.uuidString)")
    }

    func sendMessage() {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("sendMessage called. Backend: \(self.selectedBackend.rawValue), isSending: \(self.isSending), trimmedInput: \(trimmedInput)")

        guard !isSending else { logger.warning("sendMessage aborted: Already sending."); return }
        guard !trimmedInput.isEmpty else { logger.info("sendMessage aborted: Input empty."); userInput = ""; return }
        guard !showSettings else { logger.warning("sendMessage aborted: Settings open."); return }

        // --- Context Integration ---
        var contextPrefix = ""
        if showContextArea, let filePath = activeContextFilePath {
            contextPrefix = "Context File: \(filePath)\n\nUser Message:\n" // Simplified
        }
        let messageToSend = contextPrefix + trimmedInput
        // -----------------------------

        if selectedConversationID == nil {
            logger.info("No conversation selected. Starting new one.")
            startNewConversation()
        }

        guard let currentID = selectedConversationID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == currentID }) else {
            logger.error("CRITICAL: Could not find or create conversation (ID: \(String(describing: self.selectedConversationID))).")
            return
        }

        // Append user message locally
        let userMessage = "You: \(trimmedInput)"
        conversations[conversationIndex].messages.append(userMessage)
        conversations[conversationIndex].timestamp = Date()
        sortConversations()

        let messageLog = messageToSend
        userInput = ""
        isSending = true

        // --- Refactored Network Call ---
        Task {
            // Check server status before sending message if backend is Ollama
            if selectedBackend == .ollama {
                 // Only check status here if it's not already connected or checking
                 if ollamaServerStatus != .connected && ollamaServerStatus != .checking {
                      await checkOllamaServerStatus() // Update status
                 }
                 guard ollamaServerStatus == .connected else {
                     let errorMsg = "Cannot send message: Ollama server is not connected."
                     logger.error("\(errorMsg)")
                     self.handleAgentResponse(response: "Error: \(errorMsg)", conversationID: currentID)
                     return // Stop if server not connected
                 }
            }


            let backendConfig = self.determineBackendConfiguration(message: messageLog)
            var agentResponse: String

            do {
                logger.debug("Sending task '\(messageLog.prefix(200))' to \(backendConfig.url)\(backendConfig.endpoint) for conversation \(currentID.uuidString)")
                 let responseData = try await self.aiConnect.postToLocalServer(
                     endpoint: backendConfig.endpoint,
                     payload: backendConfig.payload
                 )
                agentResponse = self.parseResponse(data: responseData, for: self.selectedBackend)
            } catch {
                logger.error("Error during API call or parsing: \(error.localizedDescription)")
                // If a network error occurs during sendMessage for Ollama, update status
                 if selectedBackend == .ollama {
                     // Assuming disconnected on network error during call,
                     // but could be more nuanced depending on error type.
                     if let urlError = error as? URLError, (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                          self.ollamaServerStatus = .disconnected
                          logger.error("Setting server status to disconnected due to sendMessage network error.")
                     } else {
                         // Other errors might not mean disconnected, keep current status
                          logger.error("sendMessage received non-network error, keeping current server status.")
                     }
                 }
                agentResponse = self.generateErrorMessage(error: error)
            }

            self.handleAgentResponse(response: agentResponse, conversationID: currentID)
        }
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSidebarCollapsed.toggle()
        }
    }

    func toggleSettings() {
         withAnimation {
            showSettings.toggle()
        }
    }

    func toggleContextArea() {
         withAnimation {
            showContextArea.toggle()
        }
        if showContextArea {
            logger.info("Context toggled: Showing active file (Simulated).")
        } else {
            logger.info("Context toggled: Hiding context area.")
        }
    }

    // MARK: - Ollama Server Status

    /// Checks the connection status of the Ollama server.
    func checkOllamaServerStatus() async {
        // Only check if backend is Ollama and we are not already checking
        guard selectedBackend == .ollama && ollamaServerStatus != .checking else {
             if selectedBackend != .ollama { self.ollamaServerStatus = .unknown }
             return
         }

        self.ollamaServerStatus = .checking
        let ollamaBaseURL = "http://localhost:11434" // TODO: Make configurable

        let isConnected = await AIConnect.checkOllamaServerStatus(baseURL: ollamaBaseURL)

        if isConnected {
            self.ollamaServerStatus = .connected
            // Automatically load models if connected and on Local AI settings tab
             // Only load models if on the Local AI tab
             if selectedSettingsSection == .localAI {
                 await loadLocalOllamaModels()
             }

        } else {
            self.ollamaServerStatus = .disconnected
             self.localOllamaModels = [] // Clear models if disconnected
             self.modelLoadingError = "Cannot connect to Ollama server." // Set a general loading error
             logger.error("Ollama server status check failed: Server not reachable.")
        }
    }


    // MARK: - Local AI Model Management Actions

    /// Fetches the list of local Ollama models asynchronously.
    func loadLocalOllamaModels() async {
        // Only load if the Local AI backend is selected
        guard selectedBackend == .ollama else {
            logger.debug("Skipping loadLocalOllamaModels: Backend is not Ollama.")
            return
        }

        // Don't start loading if a pull or remove is in progress to avoid race conditions
         guard !isPullingModel && !isRemovingModel else {
             logger.debug("Skipping loadLocalOllamaModels: Model action in progress.")
             return
         }

        // Only load models if the server is connected
         guard ollamaServerStatus == .connected else {
              logger.debug("Skipping loadLocalOllamaModels: Ollama server is not connected.")
              // modelLoadingError is already set in checkOllamaServerStatus if disconnected
              self.localOllamaModels = [] // Ensure list is clear
              return
          }


        isLoadingModels = true
        modelLoadingError = nil // Clear previous errors (from loading)

        let ollamaBaseURL = "http://localhost:11434" // TODO: Make configurable

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
            self.modelLoadingError = "Failed to load models: \(errorMessage)" // Specific loading error
            logger.error("Failed to load local Ollama models: \(error.localizedDescription)")
            // If loading fails due to network, update server status
             if let urlError = error as? URLError, (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                 self.ollamaServerStatus = .disconnected
                 logger.error("Setting server status to disconnected due to model loading network error.")
             }
        }

        isLoadingModels = false
    }

    /// Initiates the process of pulling a new Ollama model.
    /// - Parameter modelName: The name of the model to pull.
    func pullModelAction(name modelName: String) async {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            self.modelPullError = "Model name cannot be empty."
            return
        }
         guard !isPullingModel else { logger.warning("Already pulling a model."); return }
         guard !isRemovingModel else { logger.warning("Attempted to pull model while another model is being removed."); self.modelPullError = "Cannot pull model: Another model is currently being removed."; return }
         guard selectedBackend == .ollama else { logger.warning("Attempted to pull model but backend is not Ollama."); self.modelPullError = "Cannot pull models when Ollama is not the selected backend."; return }
         // Check server status before initiating pull
         guard ollamaServerStatus == .connected else {
              let errorMsg = "Cannot pull model: Ollama server is not connected."
              logger.warning("\(errorMsg)")
              self.modelPullError = errorMsg
              return
          }


        isPullingModel = true
        self.pullStatusMessage = "Starting pull for \(trimmedModelName)..."
        modelPullError = nil
        pullProgress = 0.0
        pullStage = "Starting..."
        pullTotalBytes = nil
        pullCompletedBytes = nil


        let ollamaBaseURL = "http://localhost:11434" // TODO: Make configurable

        logger.info("Attempting to pull model: \(trimmedModelName) with streaming.")

        do {
            try await AIConnect.pullOllamaModel(name: trimmedModelName, baseURL: ollamaBaseURL) { progress in
                Task { @MainActor in
                    self.pullStage = progress.status
                    self.pullTotalBytes = progress.total
                    self.pullCompletedBytes = progress.completed
                    self.pullProgress = progress.percentage ?? 0.0

                     if let percentage = progress.percentage {
                         let percentString = String(format: "%.0f%%", percentage * 100)
                          self.pullStatusMessage = "\(progress.status.capitalized): \(percentString)"
                     } else if !progress.status.isEmpty {
                          self.pullStatusMessage = progress.status.capitalized
                     } else {
                         self.pullStatusMessage = "In progress..."
                     }

                    if let streamedError = progress.error {
                         self.modelPullError = "Stream Error: \(streamedError)"
                         logger.error("Received streamed error during pull: \(streamedError). Attempting to cancel pull task.")
                     }

                    logger.debug("Pull progress: Status=\(progress.status), Completed=\(progress.completed ?? -1), Total=\(progress.total ?? -1), Percentage=\(progress.percentage ?? -1)")
                }
            }

            self.pullStatusMessage = "Successfully pulled \(trimmedModelName)."
            self.modelPullError = nil
            self.pullProgress = 1.0
            self.pullStage = "Complete"
            logger.info("Model \(trimmedModelName) pulled successfully (streaming finished).")

            Task { await loadLocalOllamaModels() }

        } catch {
            let errorMessage = self.generateErrorMessage(error: error)
            self.pullStatusMessage = "Failed to pull \(trimmedModelName)."
            self.modelPullError = "Pull failed: \(errorMessage)"
            self.pullProgress = 0.0
            self.pullStage = "Error"
            logger.error("Failed to pull model \(trimmedModelName): \(error.localizedDescription)")
             if let urlError = error as? URLError, (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                 self.ollamaServerStatus = .disconnected
                 logger.error("Setting server status to disconnected due to model pull network error.")
             }
        }

        isPullingModel = false

         try? await Task.sleep(nanoseconds: 2_000_000_000)
         if modelPullError == nil {
              self.modelToPull = ""
         }
         self.pullStatusMessage = ""
         self.pullStage = ""
         self.pullProgress = 0.0

    }

    /// Initiates the process of removing a local Ollama model.
    /// - Parameter modelName: The name of the model to remove.
    func removeModelAction(name modelName: String) async {
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            self.modelRemoveError = "Model name cannot be empty for removal."
            return
        }
         guard trimmedModelName != self.llmModelName else { logger.warning("Attempted to remove the currently selected model '\(trimmedModelName)'."); self.modelRemoveError = "Cannot remove the currently active model."; return }
         guard self.localOllamaModels.contains(trimmedModelName) else { logger.warning("Attempted to remove model '\(trimmedModelName)' which is not in the local list."); self.modelRemoveError = "Model '\(trimmedModelName)' not found in local list."; return }
         guard !isRemovingModel else { logger.warning("Already removing a model."); return }
         guard !isPullingModel else { logger.warning("Attempted to remove model while another model is being pulled."); self.modelRemoveError = "Cannot remove model: Another model is currently being pulled."; return }
         guard selectedBackend == .ollama else { logger.warning("Attempted to remove model but backend is not Ollama."); self.modelRemoveError = "Cannot remove models when Ollama is not the selected backend."; return }
         // Check server status before initiating removal
         guard ollamaServerStatus == .connected else {
              let errorMsg = "Cannot remove model: Ollama server is not connected."
              logger.warning("\(errorMsg)")
              self.modelRemoveError = errorMsg
              return
          }


        isRemovingModel = true
        removingModelName = trimmedModelName
        modelRemoveError = nil

        let ollamaBaseURL = "http://localhost:11434" // TODO: Make configurable

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

         // Optional: Clear the removal status/error after a delay on success
    }


    // MARK: - Private Helper Functions

    private func sortConversations() {
        conversations.sort { $0.timestamp > $1.timestamp }
    }

    private struct BackendConfiguration {
        let url: String
        let endpoint: String
        let payload: [String: Any]
    }

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
                    "stream": false,
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

    private func handleAgentResponse(response: String, conversationID: UUID) {
        if let updatedIndex = self.conversations.firstIndex(where: { $0.id == conversationID }) {
            self.conversations[updatedIndex].messages.append("Agent: \(response)")
            self.conversations[updatedIndex].timestamp = Date()
            self.sortConversations()
        } else {
            logger.error("Error: Conversation \(conversationID.uuidString) disappeared before agent response could be added.")
        }
        self.isSending = false
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
                 let statusString = httpStatusCode.map { " (\($0))" } ?? "" // Corrected

                 if let data = responseData, let ollamaError = parseOllamaErrorResponse(data: data) {
                     return "Ollama Error\(statusString): \(ollamaError)"
                 }

                return "Error: Bad server response\(statusString). \(responseBody.prefix(150))"

            case .cannotFindHost: return "Error: Cannot find the server host (\(self.selectedBackend.rawValue)). Check address/DNS."
            case URLError.Code(rawValue: 1): return "Error: Operation not permitted (check Sandbox/Firewall)."
             case .cancelled: return "Request cancelled."
            default:
                logger.warning("Unhandled URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                return "Error: Network request failed (\(urlError.localizedDescription))."
            }
        }
        logger.warning("Unhandled error type: \(type(of: error)) - \(error.localizedDescription)")
        return "Error: \(error.localizedDescription)"
    }

    private func parseOllamaErrorResponse(data: Data) -> String? {
         guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? String else {
             return nil
         }
         return error.trimmingCharacters(in: .whitespacesAndNewlines)
     }


    // --- TODO: Implement File Reading ---
    // func readFileContent(at path: String) -> String? { ... }

    // --- TODO: Implement Persistence ---
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
