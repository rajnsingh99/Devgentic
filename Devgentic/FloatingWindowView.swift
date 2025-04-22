// /Users/alice/Documents/Workspace/mac-projects/Devgentic/Devgentic/FloatingWindowView.swift
//
//  ContentView.swift (Adapted for FloatingWindowView)
//  AgenticDev
//
//  Created by Raj Singh on 19/04/25.
//

import SwiftUI
import AppKit
import os // Import os for logging

// Logger for better debugging
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "FloatingWindowView")

// MARK: - Backend Type Definition
// BackendType enum is now defined in Models/BackendType.swift

// MARK: - Data Model
// Conversation struct is now defined in Models/Conversation.swift

// MARK: - Visual Effect View
// VisualEffectBlur struct is now defined in Views/VisualEffectBlur.swift

// MARK: - Settings Section Definition
// SettingsSection enum is now defined in Models/SettingsSection.swift

// MARK: - UserDefaults Keys (for @AppStorage)
// SettingsKeys struct is now defined in Models/SettingsKeys.swift

// MARK: - Previews (Optional)
struct FloatingWindowView_Previews: PreviewProvider {
    static var previews: some View {
        // Example with some preview data
        FloatingWindowView(
            conversations: [
                Conversation(id: UUID(), messages: ["You: Hello there!", "Agent: Hi! How can I help?"], timestamp: Date()), // Today
                Conversation(id: UUID(), messages: ["You: What is Swift?"], timestamp: Date().addingTimeInterval(-86400)), // Yesterday
                Conversation(id: UUID(), messages: ["You: Old question"], timestamp: Date().addingTimeInterval(-86400 * 3)) // Older
            ],
            selectedConversationID: nil // Start with none selected in preview
        )
        .frame(width: 800, height: 600)
        .previewDisplayName("With Grouped Conversations")

        // Example with no conversations
        FloatingWindowView(conversations: [])
            .frame(width: 800, height: 600)
            .previewDisplayName("No Conversations")

        // Example showing settings panel initially
        FloatingWindowView(conversations: [], showSettingsInitial: true)
             .frame(width: 800, height: 600)
             .previewDisplayName("Settings Open")

        // Example showing context area initially with a file
        FloatingWindowView(conversations: [], showContextAreaInitial: true, activeFilePathInitial: "/Users/alice/Documents/project/main.swift")
             .frame(width: 800, height: 600)
             .previewDisplayName("Context Area Open (File)")

        // Example showing context area initially with nothing
        FloatingWindowView(conversations: [], showContextAreaInitial: true, activeFilePathInitial: nil)
             .frame(width: 800, height: 600)
             .previewDisplayName("Context Area Open (Nothing)")
    }
}


// MARK: - Main View
struct FloatingWindowView: View {
    // --- Focus State ---
    @FocusState private var isInputFocused: Bool

    // --- State Variables (UI State) ---
    @State private var isSidebarCollapsed: Bool = true
    @State private var userInput = ""
    @State var conversations: [Conversation] // Keep as @State if loaded externally/dynamically
    @State var selectedConversationID: UUID?
    @State private var showSettings: Bool
    @State private var isSending: Bool = false
    @State private var selectedSettingsSection: SettingsSection = .general // State for master-detail - Uses SettingsSection
    // --- UPDATED Context State ---
    @State private var showContextArea: Bool
    @State private var activeContextFilePath: String? = nil // Keep this to know *if* context is active
    // -------------------------

    // --- AppStorage for Persistent Settings ---
    // Uses SettingsKeys and BackendType
    @AppStorage(SettingsKeys.selectedBackend) private var selectedBackend: BackendType = .ollama
    @AppStorage(SettingsKeys.windowOpacity) private var windowOpacity: Double = 1.0
    @AppStorage(SettingsKeys.llmModelName) private var llmModelName: String = "gemma:2b"
    @AppStorage(SettingsKeys.agentBaseURL) private var agentBaseURL: String = "http://127.0.0.1:8000"
    @AppStorage(SettingsKeys.agentDelegationStrategy) private var agentDelegationStrategy: String = "send_to_first_available"
    // --------------------------------------

    // --- AI Connection ---
    private let aiConnect = AIConnect() // Ensure AIConnect is defined elsewhere
    // --------------------

    // Initializer (Allow setting initial states for previews) - UPDATED
    init(conversations: [Conversation] = [],
         selectedConversationID: UUID? = nil,
         showSettingsInitial: Bool = false,
         showContextAreaInitial: Bool = false,
         activeFilePathInitial: String? = nil) { // Added active file path initial state
        _conversations = State(initialValue: conversations)
        _selectedConversationID = State(initialValue: selectedConversationID)
        _showSettings = State(initialValue: showSettingsInitial)
        _showContextArea = State(initialValue: showContextAreaInitial) // Initialize context state
        _activeContextFilePath = State(initialValue: activeFilePathInitial) // Initialize active file path
    }


    // MARK: - Computed Properties

    // Computed property to get the messages of the selected conversation
    private var currentChatHistory: [String] {
        guard let selectedID = selectedConversationID,
              let conversation = conversations.first(where: { $0.id == selectedID }) else {
            return []
        }
        return conversation.messages
    }

    // Computed property to get the index of the selected conversation
    // Note: This might become less necessary if logic moves to a ViewModel
    private var selectedConversationIndex: Int? {
        guard let selectedID = selectedConversationID else { return nil }
        return conversations.firstIndex(where: { $0.id == selectedID })
    }

    // --- Grouped Conversations ---
    // This logic might move to a ViewModel later
    private var groupedConversations: [String: [Conversation]] {
        let calendar = Calendar.current
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d, yyyy" // Format for older dates

        // Group conversations using reduce
        let grouped = conversations.reduce(into: [String: [Conversation]]()) { result, conversation in
            let timestamp = conversation.timestamp
            let groupKey: String
            if calendar.isDateInToday(timestamp) {
                groupKey = "Today"
            } else if calendar.isDateInYesterday(timestamp) {
                groupKey = "Yesterday"
            } else {
                groupKey = dateFormatter.string(from: timestamp)
            }
            result[groupKey, default: []].append(conversation)
        }

        // Sort conversations within each group (most recent first)
        return grouped.mapValues { $0.sorted { $0.timestamp > $1.timestamp } }
    }

    // --- Sorted Group Keys ---
    // This logic might move to a ViewModel later
    private var sortedGroupKeys: [String] {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d, yyyy"

        return groupedConversations.keys.sorted { key1, key2 in
            // Define order: Today > Yesterday > Older Dates (most recent first)
            if key1 == "Today" { return true }
            if key2 == "Today" { return false }
            if key1 == "Yesterday" { return true }
            if key2 == "Yesterday" { return false }

            // If both are dates, compare them
            if let date1 = dateFormatter.date(from: key1), let date2 = dateFormatter.date(from: key2) {
                return date1 > date2 // Sort dates descending (most recent first)
            }

            // Fallback (shouldn't happen with defined keys)
            return key1 > key2
        }
    }
    // --------------------------------

    // Computed property for the title in the header
    private var currentConversationTitle: String {
        // Find the conversation by ID to ensure correctness even if array order changes
        guard let conversation = conversations.first(where: { $0.id == selectedConversationID }) else {
             // If no conversation is selected or found, provide a default title
             return conversations.isEmpty ? "Devgentic" : "Select Chat"
        }
        return conversation.displayTitle
    }

    // MARK: - Body
    var body: some View {
        // --- ZStack for Overlay ---
        ZStack {
            // --- Main Content HStack (Chat UI) ---
            HStack(spacing: 0) {
                // --- Left Sidebar (Conversations) ---
                if !isSidebarCollapsed {
                    // Use the extracted ConversationListView
                    ConversationListView(
                        groupedConversations: groupedConversations,
                        sortedGroupKeys: sortedGroupKeys,
                        selectedConversationID: $selectedConversationID,
                        onNewConversation: startNewConversation // Pass action
                    )
                }
                // --- End Left Sidebar ---

                // --- Divider ---
                if !isSidebarCollapsed {
                     Divider().background(Color.white.opacity(0.2)) // Style divider
                }
                // ------------------------------------------------------

                // --- Main Interaction Area (Right Side) ---
                VStack(spacing: 0) {
                    // --- Header ---
                    // Use the extracted ChatHeaderView
                    ChatHeaderView(
                        isSidebarCollapsed: $isSidebarCollapsed,
                        currentConversationTitle: currentConversationTitle,
                        onToggleSidebar: { // Provide closure for action
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSidebarCollapsed.toggle()
                            }
                        },
                        onShowSettings: { // Provide closure for action
                            withAnimation {
                                showSettings.toggle()
                            }
                        }
                    )

                    // --- Chat Message Area (FIXED LOGIC) ---
                    // Always include the ScrollViewReader structure
                    ScrollViewReader { scrollProxy in
                        ChatHistoryView(
                            history: currentChatHistory,
                            isSending: isSending,
                            // Pass true if a conversation is selected, otherwise false.
                            // ChatHistoryView might use this to hide internal elements
                            // if no conversation is actually selected (even though the view is present).
                            hasSelectedConversation: selectedConversationID != nil
                        )
                        // Keep scroll-related logic attached here
                        .onChange(of: currentChatHistory) { _ in
                            if selectedConversationID != nil {
                                scrollToBottom(scrollProxy: scrollProxy, history: currentChatHistory)
                            }
                        }
                        .onChange(of: isSending) { _ in
                             if selectedConversationID != nil && !isSending {
                                 scrollToBottom(scrollProxy: scrollProxy, history: currentChatHistory)
                             }
                        }
                        .onChange(of: selectedConversationID) { newID in
                            if newID != nil {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    scrollToBottom(scrollProxy: scrollProxy, history: currentChatHistory, animated: false)
                                    if !showSettings {
                                        isInputFocused = true
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 5) // Space above input area
                    .frame(maxHeight: .infinity) // Ensure it takes available vertical space
                    .overlay { // <<--- Apply the overlay here
                        // Conditionally show the placeholder text
                        if selectedConversationID == nil && conversations.isEmpty {
                            Text("Type a message or press ⌘N to start a new chat.")
                                .foregroundColor(.gray)
                        }
                    }
                    // --- End Chat Message Area ---


                    // --- Input Area ---
                    // Use the extracted ChatInputAreaView
                    ChatInputAreaView(
                        userInput: $userInput,
                        showContextArea: $showContextArea,
                        activeContextFilePath: $activeContextFilePath,
                        isSending: isSending,
                        showSettings: showSettings,
                        isInputFocused: $isInputFocused, // Pass FocusState binding
                        onSendMessage: sendMessage, // Pass action
                        onToggleContext: toggleContextArea // Pass action
                    )
                    // --- End Input Area ---

                    // Hidden Button for Keyboard Shortcut (Cmd+N)
                    Button(action: startNewConversation) { EmptyView() }
                        .hidden()
                        .keyboardShortcut("n", modifiers: .command)

                } // End Main Interaction VStack
                .background(VisualEffectBlur()) // Use the extracted blur view
                // --- End Main Interaction Area ---
            } // End Main Content HStack
            .allowsHitTesting(!showSettings) // Disable interaction with chat UI when settings are open

            // --- Settings Panel Overlay ---
            if showSettings {
                // Use the extracted SettingsPanelView
                SettingsPanelView(
                    showSettings: $showSettings,
                    selectedSettingsSection: $selectedSettingsSection,
                    windowOpacity: $windowOpacity, // Pass AppStorage binding
                    llmModelName: $llmModelName, // Pass AppStorage binding
                    agentBaseURL: $agentBaseURL, // Pass AppStorage binding
                    agentDelegationStrategy: $agentDelegationStrategy // Pass AppStorage binding
                )
            }
            // --- End Settings Panel Overlay ---

        } // End ZStack
        .opacity(windowOpacity) // Apply overall opacity
        .frame(minWidth: 800, minHeight: 500) // Keep overall window size constraints
        .onAppear {
             // Select the first conversation in the first group if none is selected
             if selectedConversationID == nil,
                let firstKey = sortedGroupKeys.first,
                let firstConv = groupedConversations[firstKey]?.first {
                 selectedConversationID = firstConv.id
             } else if conversations.isEmpty && !showSettings { // Only focus input if settings aren't shown initially
                 // Focus input if there are no conversations at all
                 DispatchQueue.main.async { isInputFocused = true }
             }
         }
    }

    // MARK: - Actions

    func startNewConversation() {
        // If settings are open, close them first
        if showSettings {
            withAnimation { showSettings = false }
        }
        // If context area is open, optionally close it or leave it open
        // if showContextArea {
        //     withAnimation { showContextArea = false; activeContextFilePath = nil } // Clear path if closing context
        // }

        userInput = ""
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        conversations.append(newConversation)
        // Sort conversations to ensure the new one appears correctly if sorting is applied elsewhere
        conversations.sort { $0.timestamp > $1.timestamp }
        selectedConversationID = newConversation.id
        logger.info("Started new conversation with ID: \(newConversation.id.uuidString)")
        // Focus is handled by onChange(of: selectedConversationID)
    }

    // --- sendMessage Function (Remains here for now) ---
    func sendMessage() {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("sendMessage called. Backend: \(selectedBackend.rawValue), isSending: \(isSending), trimmedInput: '\(trimmedInput)'") // Uses BackendType

        guard !isSending else {
            logger.warning("sendMessage aborted: Already sending.")
            return
        }
        guard !trimmedInput.isEmpty else {
            logger.info("sendMessage aborted: Input is empty after trimming.")
            userInput = "" // Clear whitespace input
            return
        }
        // Prevent sending if settings are open
        guard !showSettings else {
             logger.warning("sendMessage aborted: Settings panel is open.")
             return
        }

        // --- Context Integration ---
        var contextPrefix = ""
        if showContextArea, let filePath = activeContextFilePath {
            // In a real scenario, you'd read the file content here
            // let fileContent = readFileContent(at: filePath) ?? "Error reading file"
            // contextPrefix = "Context File: \(filePath)\nContent:\n\(fileContent)\n\nUser Message:\n"
            contextPrefix = "Context File: \(filePath)\n\nUser Message:\n" // Simplified for now
        }
        let messageToSend = contextPrefix + trimmedInput
        // -----------------------------

        if selectedConversationID == nil {
            logger.info("No conversation selected. Starting a new one before sending.")
            startNewConversation()
        }

        // Ensure selectedConversationID is valid after potentially starting a new one
        guard let currentID = selectedConversationID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == currentID }) else {
            logger.error("CRITICAL: Could not find or create conversation (ID: \(String(describing: selectedConversationID))).")
            return
        }

        // Append user message locally (use the original input for display)
        let userMessage = "You: \(trimmedInput)"
        conversations[conversationIndex].messages.append(userMessage)
        conversations[conversationIndex].timestamp = Date() // Update timestamp on new message
        // Re-sort conversations array after updating timestamp to maintain order
        conversations.sort { $0.timestamp > $1.timestamp }
        let messageLog = messageToSend // Capture the full message (with context) for logging/sending
        userInput = "" // Clear input field
        isSending = true

        Task {
            var agentResponse = "Error: Agent response not received."
            var taskError: Error? = nil

            // Determine Backend Configuration
            let targetURL: String
            let targetEndpoint: String
            let payload: [String: Any]

            // Use the @AppStorage variables directly here
            switch selectedBackend { // Uses BackendType
            case .ollama:
                targetURL = "http://127.0.0.1:11434" // Consider making this configurable too
                targetEndpoint = "/api/generate"
                payload = [
                    "model": llmModelName,
                    "prompt": messageToSend, // Send the full message with context
                    "stream": false
                ]
                logger.debug("Configured for Ollama. Model: \(llmModelName)")

            case .agent:
                targetURL = agentBaseURL
                targetEndpoint = "/execute_task"
                payload = [
                    "main_task": messageToSend, // Send the full message with context
                    "strategy": agentDelegationStrategy
                ]
                logger.debug("Configured for Agent. URL: \(targetURL), Strategy: \(agentDelegationStrategy)")
            }

            do {
                logger.debug("Sending task '\(messageLog.prefix(200))...' to \(targetURL)\(targetEndpoint) for conversation \(currentID.uuidString)")

                let responseData = try await aiConnect.postToLocalServer(baseURL: targetURL, endpoint: targetEndpoint, payload: payload)

                // --- Response Handling ---
                // This complex parsing logic should ideally move to the ViewModel or AIConnect
                if selectedBackend == .agent { // Uses BackendType
                    if let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
                       let resultsArray = json["results"] as? [[String: Any]] {
                        if let completedResultDict = resultsArray.first(where: { ($0["status"] as? String) == "completed" }),
                           let resultString = completedResultDict["result"] as? String {
                            agentResponse = resultString.trimmingCharacters(in: .whitespacesAndNewlines)
                            let slaveId = completedResultDict["slave_id"] as? String ?? "unknown"
                            logger.debug("Extracted result from first completed agent (\(slaveId)): \(agentResponse)")
                        } else {
                            let failedCount = resultsArray.filter { ($0["status"] as? String) != "completed" }.count
                            if failedCount > 0 && failedCount == resultsArray.count {
                                if let firstFailure = resultsArray.first, let errorMsg = firstFailure["result"] as? String {
                                     agentResponse = "Agent Error: \(errorMsg)"
                                     logger.warning("All agents failed. First error: \(errorMsg)")
                                } else {
                                     agentResponse = "Error: All agents failed to complete the task."
                                     logger.warning("All agents failed, but couldn't extract specific error message.")
                                }
                            } else if resultsArray.isEmpty {
                                 agentResponse = "Error: Received empty results array from agent."
                                 logger.warning("Agent returned an empty results array.")
                            } else {
                                 agentResponse = "Error: No agent completed the task successfully."
                                 logger.warning("No agent found with 'completed' status in results: \(resultsArray)")
                            }
                        }
                    } else if let textResponse = String(data: responseData, encoding: .utf8) {
                        agentResponse = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                        logger.warning("Received non-standard JSON or plain text from Agent backend: \(agentResponse)")
                    } else {
                        logger.error("Failed to decode Agent response data (neither expected JSON nor UTF-8 text).")
                        agentResponse = "Error: Could not decode server response."
                    }
                } else if selectedBackend == .ollama { // Uses BackendType
                    if let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] {
                        let replyKey = "response" // Common key for Ollama generate
                        if let reply = json[replyKey] as? String {
                            agentResponse = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                            logger.debug("Received Ollama JSON response using key '\(replyKey)': \(agentResponse)")
                        } else {
                            logger.warning("Received Ollama JSON, but key '\(replyKey)' not found or not a string. Keys: \(json.keys)")
                            // Fallback: Try to decode the whole thing as text
                            if let fallbackText = String(data: responseData, encoding: .utf8) {
                                 agentResponse = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                                 logger.warning("Using raw JSON as text fallback for Ollama.")
                            } else {
                                 agentResponse = "Error: Received unreadable JSON from Ollama."
                            }
                        }
                    } else if let textResponse = String(data: responseData, encoding: .utf8) {
                         agentResponse = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                         logger.warning("Expected JSON from Ollama, received text: \(textResponse.prefix(100))...")
                    } else {
                        logger.error("Failed to decode Ollama response data (neither JSON nor UTF-8 text).")
                        agentResponse = "Error: Could not decode server response."
                    }
                }
                // --- End Response Handling ---

            } catch {
                logger.error("Error during API call or decoding: \(error.localizedDescription)")
                taskError = error
                agentResponse = generateErrorMessage(error: error) // Use helper
            }

            // Update UI on Main Actor
            await MainActor.run {
                // Find the index again, as it might have changed due to sorting
                if let updatedIndex = conversations.firstIndex(where: { $0.id == currentID }) {
                    conversations[updatedIndex].messages.append("Agent: \(agentResponse)")
                    conversations[updatedIndex].timestamp = Date() // Update timestamp again for agent response
                    // Re-sort again after agent response to ensure it remains correctly ordered
                    conversations.sort { $0.timestamp > $1.timestamp }
                } else {
                    logger.error("Error: Conversation \(currentID.uuidString) disappeared before agent response could be added.")
                }
                isSending = false
                // Re-focus input only if settings are not open
                if !showSettings {
                    isInputFocused = true
                }
            }
        }
    }
    // --- End sendMessage ---

    // MARK: - Helper Functions

    // Action for the context button toggle
    private func toggleContextArea() {
        withAnimation {
            showContextArea.toggle()
            if showContextArea {
                // --- SIMULATION ---
                // Replace this block with your actual VS Code interaction logic
                let shouldSimulateSuccess = Bool.random() // Randomly simulate success/failure
                if shouldSimulateSuccess {
                    activeContextFilePath = "/Users/Shared/DemoProject/Sources/App/Controllers/UserController.swift" // Example path
                    logger.info("Context button tapped: Showing active file (Simulated).")
                } else {
                    activeContextFilePath = nil // Simulate failure (VS Code not running or no file open)
                    logger.info("Context button tapped: Showing context area (Nothing active - Simulated).")
                }
                // --- END SIMULATION ---
            } else {
                activeContextFilePath = nil // Clear path when hiding
                logger.info("Context button tapped: Hiding context area.")
            }
        }
    }

    // Scroll helper remains here as it uses ScrollViewProxy passed in body
    private func scrollToBottom(scrollProxy: ScrollViewProxy, history: [String], animated: Bool = true) {
         guard !history.isEmpty else { return }
         // ID of the last message or the thinking indicator
         let lastID: AnyHashable = isSending ? "thinkingIndicator" : history.count - 1

         logger.trace("Scrolling to ID \(lastID)")
         if animated {
             withAnimation(.easeOut(duration: 0.2)) {
                 scrollProxy.scrollTo(lastID, anchor: .bottom)
             }
         } else {
             scrollProxy.scrollTo(lastID, anchor: .bottom)
         }
     }

    // Error message generator remains here for now
    private func generateErrorMessage(error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost: return "Error: Could not connect to the server (\(selectedBackend.rawValue)). Check if it's running and the URL/Port is correct." // Uses BackendType
            case .networkConnectionLost: return "Error: Network connection lost."
            case .notConnectedToInternet: return "Error: Not connected to the internet."
            case .badServerResponse:
                // Attempt to get more info from the error if available
                if let responseData = urlError.userInfo["ResponseData"] as? Data,
                   let responseString = String(data: responseData, encoding: .utf8) {
                    return "Error: Bad server response. Server said: \(responseString.prefix(150))"
                }
                return "Error: Received an invalid response from the server."
            case .cannotFindHost: return "Error: Cannot find the server host (\(selectedBackend.rawValue)). Check address/DNS." // Uses BackendType
            case URLError.Code(rawValue: 1): return "Error: Operation not permitted (check Sandbox/Firewall)." // POSIX EPERM
            default:
                logger.warning("Unhandled URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                return "Error: Network request failed (\(urlError.localizedDescription))."
            }
        }
        // Handle other potential error types if necessary
        logger.warning("Unhandled error type: \(type(of: error)) - \(error.localizedDescription)")
        return "Error: \(error.localizedDescription)" // General fallback error
    }

    // --- TODO: Add file reading function if needed by sendMessage ---
    // func readFileContent(at path: String) -> String? { ... }

}

// MARK: - Settings Detail Views & Message View
// These struct definitions are now REMOVED from this file and live in the Views/ folder.
