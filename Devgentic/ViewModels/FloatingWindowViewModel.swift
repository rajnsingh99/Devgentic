// ViewModels/FloatingWindowViewModel.swift
import SwiftUI
import Combine // Needed for ObservableObject and @Published
import os     // For logging

// Logger for the ViewModel
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "FloatingWindowViewModel")

@MainActor // Ensure UI updates happen on the main thread
class FloatingWindowViewModel: ObservableObject {

    // MARK: - Published State Properties
    // ... (rest of properties remain the same) ...
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: UUID?
    @Published var isSending: Bool = false
    @Published var userInput: String = ""
    @Published var isSidebarCollapsed: Bool = true
    @Published var showSettings: Bool = false
    @Published var selectedSettingsSection: SettingsSection = .general
    @Published var showContextArea: Bool = false
    @Published var activeContextFilePath: String? = nil
    @Published var selectedBackend: BackendType = .ollama {
        didSet { UserDefaults.standard.set(selectedBackend.rawValue, forKey: SettingsKeys.selectedBackend) }
    }
    @Published var windowOpacity: Double = 1.0 {
        didSet { UserDefaults.standard.set(windowOpacity, forKey: SettingsKeys.windowOpacity) }
    }
    @Published var llmModelName: String = "gemma:2b" {
        didSet { UserDefaults.standard.set(llmModelName, forKey: SettingsKeys.llmModelName) }
    }
    @Published var agentBaseURL: String = "http://127.0.0.1:8000" {
        didSet { UserDefaults.standard.set(agentBaseURL, forKey: SettingsKeys.agentBaseURL) }
    }
    @Published var agentDelegationStrategy: String = "send_to_first_available" {
        didSet { UserDefaults.standard.set(agentDelegationStrategy, forKey: SettingsKeys.agentDelegationStrategy) }
    }


    // MARK: - Dependencies
    private let aiConnect = AIConnect()

    // MARK: - Computed Properties (Derived State)
    // ... (rest of computed properties remain the same) ...
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
        // Grouping logic moved here
        let calendar = Calendar.current
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d, yyyy"

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
        // Sorting logic moved here
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d, yyyy"

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
    // ... (init remains the same) ...
    init(initialConversations: [Conversation] = []) {
        // Load initial state (e.g., from persistence or defaults)
        self.conversations = initialConversations // Load passed-in or persisted conversations
        loadSettings()
        selectInitialConversation()

        // TODO: Load conversations from a persistent store (e.g., Core Data, UserDefaults, File)
        logger.info("FloatingWindowViewModel initialized.")
    }

    private func loadSettings() {
        // Load settings from UserDefaults
        if let rawBackend = UserDefaults.standard.string(forKey: SettingsKeys.selectedBackend),
           let backend = BackendType(rawValue: rawBackend) {
            self.selectedBackend = backend
        }
        // Ensure opacity isn't loaded as 0 (default for Double if key missing)
        let loadedOpacity = UserDefaults.standard.double(forKey: SettingsKeys.windowOpacity)
        self.windowOpacity = (loadedOpacity == 0) ? 1.0 : loadedOpacity

        self.llmModelName = UserDefaults.standard.string(forKey: SettingsKeys.llmModelName) ?? "gemma:2b"
        self.agentBaseURL = UserDefaults.standard.string(forKey: SettingsKeys.agentBaseURL) ?? "http://127.0.0.1:8000"
        self.agentDelegationStrategy = UserDefaults.standard.string(forKey: SettingsKeys.agentDelegationStrategy) ?? "send_to_first_available"
        logger.debug("Loaded settings from UserDefaults.")
    }

    private func selectInitialConversation() {
        // Select the first conversation if none is selected initially
        // Ensure sorting happens before selection if loading from persistence
        sortConversations() // Sort based on loaded timestamps
        if selectedConversationID == nil,
           let firstKey = sortedGroupKeys.first,
           let firstConv = groupedConversations[firstKey]?.first {
            selectedConversationID = firstConv.id
            logger.debug("Selected initial conversation: \(firstConv.id.uuidString)")
        }
    }


    // MARK: - Actions / Methods (Logic moved from View)

    func startNewConversation() {
        // Close settings if open
        if showSettings {
            showSettings = false // No animation needed here, View handles it if desired
        }

        userInput = "" // Clear input
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        conversations.append(newConversation)
        sortConversations() // Ensure correct order
        selectedConversationID = newConversation.id
        logger.info("Started new conversation with ID: \(newConversation.id.uuidString)")
        // Focus logic will need to be handled in the View via .onChange or similar
    }

    func sendMessage() {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // No need for self here, accessing local constants/variables
        logger.debug("sendMessage called. Backend: \(self.selectedBackend.rawValue), isSending: \(self.isSending), trimmedInput: '\(trimmedInput)'")

        // Accessing instance properties requires self here if inside a closure, but these guards are not closures
        guard !isSending else { logger.warning("sendMessage aborted: Already sending."); return }
        guard !trimmedInput.isEmpty else { logger.info("sendMessage aborted: Input empty."); userInput = ""; return }
        guard !showSettings else { logger.warning("sendMessage aborted: Settings open."); return }

        // --- Context Integration ---
        var contextPrefix = ""
        // Accessing instance properties requires self here if inside a closure, but this if block is not a closure
        if showContextArea, let filePath = activeContextFilePath {
            contextPrefix = "Context File: \(filePath)\n\nUser Message:\n" // Simplified
        }
        let messageToSend = contextPrefix + trimmedInput
        // -----------------------------

        // Accessing instance properties requires self here if inside a closure, but this if block is not a closure
        if selectedConversationID == nil {
            logger.info("No conversation selected. Starting new one.")
            startNewConversation() // Calling instance method
        }

        // Need to capture currentID locally *before* the async Task
        guard let currentID = selectedConversationID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == currentID }) else {
            logger.error("CRITICAL: Could not find or create conversation (ID: \(String(describing: self.selectedConversationID))).")
            return
        }

        // Append user message locally
        let userMessage = "You: \(trimmedInput)"
        conversations[conversationIndex].messages.append(userMessage)
        conversations[conversationIndex].timestamp = Date() // Update timestamp
        sortConversations() // Calling instance method

        let messageLog = messageToSend // Capture for logging/sending
        userInput = "" // Clear input field - modifying instance property
        isSending = true // Modifying instance property - THIS IS THE ONE THE ERROR LIKELY POINTED TO INITIALLY

        // --- Refactored Network Call ---
        // Start of the Task closure - references inside need 'self.'
        Task {
            // Call instance method - needs self.
            let backendConfig = self.determineBackendConfiguration(message: messageLog)
            var agentResponse: String

            do {
                logger.debug("Sending task '\(messageLog.prefix(200))...' to \(backendConfig.url)\(backendConfig.endpoint) for conversation \(currentID.uuidString)")
                // Access instance property aiConnect - needs self.
                let responseData = try await self.aiConnect.postToLocalServer(
                    baseURL: backendConfig.url,
                    endpoint: backendConfig.endpoint,
                    payload: backendConfig.payload
                )
                // Call instance method - needs self. Access instance property selectedBackend - needs self.
                agentResponse = self.parseResponse(data: responseData, for: self.selectedBackend)
            } catch {
                logger.error("Error during API call or parsing: \(error.localizedDescription)")
                // Call instance method - needs self.
                agentResponse = self.generateErrorMessage(error: error)
            }

            // Update UI (already on @MainActor)
            // Call instance method - needs self.
            self.handleAgentResponse(response: agentResponse, conversationID: currentID)
            // Note: handleAgentResponse modifies self.isSending internally
        }
        // --- End Refactored Network Call ---
    }

    func toggleSidebar() {
        isSidebarCollapsed.toggle()
    }

    func toggleSettings() {
        showSettings.toggle()
    }

    func toggleContextArea() {
        showContextArea.toggle()
        if showContextArea {
            // --- SIMULATION ---
            let shouldSimulateSuccess = Bool.random()
            if shouldSimulateSuccess {
                activeContextFilePath = "/Users/Shared/DemoProject/Sources/App/Controllers/UserController.swift"
                logger.info("Context toggled: Showing active file (Simulated).")
            } else {
                activeContextFilePath = nil
                logger.info("Context toggled: Showing context area (Nothing active - Simulated).")
            }
            // --- END SIMULATION ---
        } else {
            activeContextFilePath = nil // Clear path when hiding
            logger.info("Context toggled: Hiding context area.")
        }
    }

    // MARK: - Private Helper Functions

    private func sortConversations() {
        conversations.sort { $0.timestamp > $1.timestamp }
    }

    // --- Refactored sendMessage Helpers ---

    private struct BackendConfiguration {
        let url: String
        let endpoint: String
        let payload: [String: Any]
    }

    // This method is called *from* the Task closure, so references inside it implicitly capture self.
    // While not strictly required by the compiler *here*, adding self. can improve clarity.
    private func determineBackendConfiguration(message: String) -> BackendConfiguration {
        switch self.selectedBackend { // Explicit self added for clarity
        case .ollama:
            return BackendConfiguration(
                url: "http://127.0.0.1:11434",
                endpoint: "/api/generate",
                payload: [
                    "model": self.llmModelName, // Explicit self added for clarity
                    "prompt": message,
                    "stream": false
                ]
            )
        case .agent:
            return BackendConfiguration(
                url: self.agentBaseURL, // Explicit self added for clarity
                endpoint: "/execute_task",
                payload: [
                    "main_task": message,
                    "strategy": self.agentDelegationStrategy // Explicit self added for clarity
                ]
            )
        }
    }

    // This method is called *from* the Task closure. Explicit self added for clarity.
    private func parseResponse(data: Data, for backend: BackendType) -> String {
        do {
            switch backend {
            case .agent:
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let resultsArray = json["results"] as? [[String: Any]] else {
                    logger.warning("Agent response was not the expected JSON structure.")
                    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode non-JSON Agent response."
                }
                // ... rest of agent parsing logic ...
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
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    logger.warning("Ollama response was not JSON.")
                    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode non-JSON Ollama response."
                }
                // ... rest of ollama parsing logic ...
                 if let reply = json["response"] as? String {
                    logger.debug("Parsed Ollama response.")
                    return reply.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    logger.warning("Ollama JSON response missing 'response' key.")
                    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode Ollama JSON response."
                }
            }
        } catch {
            logger.error("Failed to parse JSON response: \(error.localizedDescription)")
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Error: Could not decode server response (\(error.localizedDescription))."
        }
    }

    // This method is called *from* the Task closure. Explicit self added.
    private func handleAgentResponse(response: String, conversationID: UUID) {
        // Find index again in case array changed
        if let updatedIndex = self.conversations.firstIndex(where: { $0.id == conversationID }) { // Added self.
            self.conversations[updatedIndex].messages.append("Agent: \(response)") // Added self.
            self.conversations[updatedIndex].timestamp = Date() // Added self.
            self.sortConversations() // Added self.
        } else {
            logger.error("Error: Conversation \(conversationID.uuidString) disappeared before agent response could be added.")
        }
        self.isSending = false // Added self.
    }

    // --- End Refactored sendMessage Helpers ---

    // This method is called *from* the Task closure. Explicit self added for clarity.
    private func generateErrorMessage(error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            // Accessing selectedBackend requires self.
            case .cannotConnectToHost: return "Error: Could not connect to the server (\(self.selectedBackend.rawValue)). Check if it's running and the URL/Port is correct."
            case .networkConnectionLost: return "Error: Network connection lost."
            case .notConnectedToInternet: return "Error: Not connected to the internet."
            case .badServerResponse:
                let serverMsg = urlError.userInfo[NSLocalizedDescriptionKey] as? String ?? "Unknown server error"
                return "Error: Bad server response. (\(serverMsg.prefix(150)))"
            // Accessing selectedBackend requires self.
            case .cannotFindHost: return "Error: Cannot find the server host (\(self.selectedBackend.rawValue)). Check address/DNS."
            case URLError.Code(rawValue: 1): return "Error: Operation not permitted (check Sandbox/Firewall)." // POSIX EPERM
            default:
                logger.warning("Unhandled URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                return "Error: Network request failed (\(urlError.localizedDescription))."
            }
        }
        logger.warning("Unhandled error type: \(type(of: error)) - \(error.localizedDescription)")
        return "Error: \(error.localizedDescription)"
    }

    // --- TODO: Implement File Reading ---
    // func readFileContent(at path: String) -> String? { ... }

    // --- TODO: Implement Persistence ---
    // func saveConversations() { ... }
    // func loadConversations() { ... }
}
