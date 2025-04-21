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
// Define the possible AI backend types
enum BackendType: String, CaseIterable, Identifiable {
    case ollama = "Ollama"
    case agent = "Agent"

    var id: String { self.rawValue }
}


// MARK: - Data Model
struct Conversation: Identifiable, Equatable {
    let id: UUID
    var messages: [String]
    var timestamp: Date // To help sort or display

    // Helper to get a display title (e.g., first user message)
    var displayTitle: String {
        // Find the first message starting with "You: "
        if let firstUserMessage = messages.first(where: { $0.starts(with: "You:") }) {
            let content = firstUserMessage.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
            // Limit title length for display
            let maxLength = 30
            return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
        }
        // Fallback if no user message yet or only agent messages
        if let firstMessage = messages.first {
            let content = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            // Limit title length for display
            let maxLength = 30
            // Include "Agent:" prefix if it's the first message
            if content.starts(with: "Agent:") {
                 return String(content.prefix(maxLength + 7)) + (content.count > (maxLength + 7) ? "..." : "") // Account for "Agent: "
            } else {
                 return String(content.prefix(maxLength)) + (content.count > maxLength ? "..." : "")
            }
        }
        return "New Chat"
    }
}

// MARK: - Visual Effect View
struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

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
        .frame(width: 800, height: 500)
        .previewDisplayName("With Grouped Conversations")

        // Example with no conversations
        FloatingWindowView(conversations: [])
            .frame(width: 800, height: 500)
            .previewDisplayName("No Conversations")

        // Example with Agent backend selected in preview
        FloatingWindowView(conversations: [], selectedBackend: .agent)
            .frame(width: 800, height: 500)
            .previewDisplayName("Agent Backend Selected")
    }
}


// MARK: - Main View
struct FloatingWindowView: View {
    // --- Focus State ---
    @FocusState private var isInputFocused: Bool

    // --- State Variables ---
    @State private var isSidebarCollapsed: Bool = true
    @State private var userInput = ""
    @State var conversations: [Conversation]
    @State var selectedConversationID: UUID?
    @State private var showSettings: Bool = false
    @State private var windowOpacity: Double = 1.0
    @State private var isSending: Bool = false
    @State private var llmModelName: String = "gemma:2b" // Default Ollama model

    // --- NEW State for Backend Selection ---
    @State private var selectedBackend: BackendType // Initialized in init
    @State private var agentBaseURL: String = "http://127.0.0.1:8000" // Default Agent URL
    @State private var agentDelegationStrategy: String = "send_to_first_available" // Default Agent strategy
    // --------------------------------------

    // --- AI Connection ---
    // Initialize without base URL, assuming AIConnect is modified to accept it dynamically
    private let aiConnect = AIConnect() // Ensure AIConnect is defined elsewhere
    // --------------------

    // Initializer for previews or external data loading
    // Added selectedBackend parameter
    init(conversations: [Conversation] = [], selectedConversationID: UUID? = nil, selectedBackend: BackendType = .ollama) {
        _conversations = State(initialValue: conversations)
        _selectedConversationID = State(initialValue: selectedConversationID)
        _selectedBackend = State(initialValue: selectedBackend) // Initialize backend state
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
    private var selectedConversationIndex: Int? {
        guard let selectedID = selectedConversationID else { return nil }
        return conversations.firstIndex(where: { $0.id == selectedID })
    }

    // --- Grouped Conversations ---
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
        guard let index = selectedConversationIndex else {
            return conversations.isEmpty ? "Devgentic" : "Select Chat"
        }
        // Use the original conversation array for title lookup based on ID
        return conversations[index].displayTitle
    }

    // MARK: - Body
    var body: some View {
        HStack(spacing: 0) {
            // --- Left Sidebar (Collapsible) ---
            if !isSidebarCollapsed {
                ZStack {
                    Color.black.opacity(0.25)
                    VStack(alignment: .leading, spacing: 0) {
                        // Header with New Chat Button
                        HStack {
                            Text("Conversations")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)
                            Spacer()
                            Button(action: startNewConversation) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding()

                        Divider().background(Color.white.opacity(0.2))

                        // --- UPDATED: List of Conversations (Adjusted DisclosureGroup Style) ---
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(sortedGroupKeys, id: \.self) { groupKey in
                                    let isGroupSelected = groupedConversations[groupKey]?.contains(where: { $0.id == selectedConversationID }) ?? false

                                    DisclosureGroup(
                                        content: {
                                            // Content remains the same
                                            if let conversationsInGroup = groupedConversations[groupKey] {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    ForEach(conversationsInGroup) { conversation in
                                                        HStack {
                                                            Text(conversation.displayTitle)
                                                                .foregroundColor(selectedConversationID == conversation.id ? .cyan : .white)
                                                                .padding(.horizontal, 8)
                                                                .padding(.vertical, 6)
                                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                                .lineLimit(1)
                                                                .truncationMode(.tail)
                                                        }
                                                        .background(selectedConversationID == conversation.id ? Color.blue.opacity(0.4) : Color.clear)
                                                        .cornerRadius(5)
                                                        .contentShape(Rectangle())
                                                        .onTapGesture {
                                                            selectedConversationID = conversation.id
                                                        }
                                                    }
                                                }
                                                .padding(.leading, 10)
                                                .padding(.bottom, 5)
                                            }
                                        },
                                        label: {
                                            Text(groupKey)
                                                .font(.footnote) // << Increased font size
                                                .fontWeight(.semibold)
                                                .foregroundColor(isGroupSelected ? .white.opacity(0.9) : .gray)
                                                .padding(.vertical, 6) // << Slightly increased vertical padding
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    )
                                    .accentColor(.white.opacity(0.7))
                                    .background(isGroupSelected ? Color.white.opacity(0.1) : Color.clear)
                                    .cornerRadius(4)
                                    .padding(.horizontal, 5)
                                    .padding(.leading, 5) // << Added extra leading padding for arrow space
                                    .padding(.bottom, 3)
                                }
                            }
                            .padding(.top, 10)
                            .padding(.bottom, 10)
                        }
                        // --- END UPDATED List ---
                        Spacer()
                    }
                }
                .frame(width: 240)
                .transition(.move(edge: .leading))
            }
            // --- End Left Sidebar ---

            // --- Divider (Only show if sidebar is not collapsed) ---
            if !isSidebarCollapsed {
                 Divider()
            }
            // ------------------------------------------------------

            // --- Main Interaction Area (Right Side) ---
            VStack(spacing: 0) {
                // Header with Sidebar Toggle and Settings Button
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isSidebarCollapsed.toggle() }
                    } label: {
                        Image(systemName: isSidebarCollapsed ? "sidebar.right" : "sidebar.left")
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(PlainButtonStyle())

                    Text(currentConversationTitle)
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button {
                        withAnimation { showSettings.toggle() }
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()
                .background(Color.gray.opacity(0.2))

                // --- Settings Panel (Conditional) ---
                if showSettings {
                    VStack(alignment: .leading, spacing: 8) {
                        // Backend Selection
                        HStack {
                            Text("Backend:")
                                .foregroundColor(.white.opacity(0.8))
                                .font(.caption)
                            Picker("Backend", selection: $selectedBackend) {
                                ForEach(BackendType.allCases) { type in
                                    Text(type.rawValue).tag(type)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                        }

                        // Transparency
                        HStack {
                            Text("Transparency:")
                                .foregroundColor(.white.opacity(0.8))
                                .font(.caption)
                            Slider(value: $windowOpacity, in: 0.2...1.0)
                                .controlSize(.small)
                        }

                        Divider().background(Color.white.opacity(0.2))

                        // Conditional Settings
                        if selectedBackend == .ollama {
                            HStack {
                                Text("Ollama Model:")
                                    .foregroundColor(.white.opacity(0.8))
                                    .font(.caption)
                                TextField("Model Name", text: $llmModelName)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .controlSize(.small)
                            }
                        } else if selectedBackend == .agent {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("Agent URL:")
                                        .foregroundColor(.white.opacity(0.8))
                                        .font(.caption)
                                    TextField("Base URL", text: $agentBaseURL)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .controlSize(.small)
                                }
                                HStack {
                                    Text("Agent Strategy:")
                                        .foregroundColor(.white.opacity(0.8))
                                        .font(.caption)
                                    TextField("Delegation Strategy", text: $agentDelegationStrategy)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.3))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                // --- End Settings Panel ---

                // Chat Message Area
                if selectedConversationID != nil || !conversations.isEmpty {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if selectedConversationID != nil {
                                    ForEach(currentChatHistory.indices, id: \.self) { index in
                                        let message = currentChatHistory[index]
                                        HStack {
                                            if message.starts(with: "Agent:") { Spacer() }
                                            MessageView(message: message) // Ensure MessageView is defined
                                            if message.starts(with: "You:") { Spacer() }
                                        }
                                        .id(index)
                                        .frame(maxWidth: .infinity, alignment: message.starts(with: "You:") ? .trailing : .leading)
                                    }
                                }
                                if isSending && selectedConversationID != nil {
                                    HStack {
                                         Text("Agent is thinking...")
                                             .font(.caption)
                                             .foregroundColor(.gray)
                                             .padding(10)
                                             .background(Color.white.opacity(0.1))
                                             .cornerRadius(10)
                                         Spacer()
                                     }
                                     .padding(.leading)
                                }
                            }
                            .padding()
                        }
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
                                    isInputFocused = true
                                }
                            }
                        }
                    }
                    .padding(.bottom, 5)

                } else {
                    // Placeholder view when no conversations exist
                    Spacer()
                    Text("Type a message or press ⌘N to start a new chat.")
                        .foregroundColor(.gray)
                    Spacer()
                }

                // Input Area
                VStack(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        // This will now unambiguously use the CustomTextEditor from CustomTextEditor.swift
                        CustomTextEditor(
                            text: $userInput,
                            onCommit: sendMessage
                        )
                        if userInput.isEmpty {
                            Text("Type a message (Shift+Enter to send)...")
                                .font(Font.system(size: NSFont.systemFontSize))
                                .foregroundColor(.gray)
                                .padding(.horizontal, 7) // Adjust padding to match CustomTextEditor's internal padding
                                .padding(.top, 8)       // Adjust padding to match CustomTextEditor's internal padding
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 30, maxHeight: 120) // Allow more height for multi-line input
                    .focused($isInputFocused)
                    .disabled(isSending)

                    HStack(spacing: 10) {
                        Button { logger.info("Web icon tapped") } label: {
                            Image(systemName: "globe")
                                .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(PlainButtonStyle()).disabled(isSending)

                        Button { logger.info("Plus icon tapped") } label: {
                            Image(systemName: "plus")
                                .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(PlainButtonStyle()).disabled(isSending)

                        Spacer()

                        Button { logger.info("Mic icon tapped") } label: {
                            Image(systemName: "mic.fill")
                                .resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .buttonStyle(PlainButtonStyle()).disabled(isSending)

                        Button(action: sendMessage) {
                            if isSending {
                                ProgressView().controlSize(.small).frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .resizable().frame(width: 28, height: 28)
                                    .foregroundColor(userInput.isEmpty ? .gray : .blue)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(userInput.isEmpty || isSending)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)

                }
                .background(Color.white.opacity(0.1))
                .cornerRadius(10)
                .padding(.horizontal)
                .padding(.bottom, 10)

                // Hidden Button for Keyboard Shortcut (Cmd+N)
                Button(action: startNewConversation) { EmptyView() }
                    .hidden()
                    .keyboardShortcut("n", modifiers: .command)

            }
            .background(VisualEffectBlur())
            // --- End Main Interaction Area ---
        } // End Outermost HStack
        .opacity(windowOpacity)
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
             // Select the first conversation in the first group if none is selected
             if selectedConversationID == nil,
                let firstKey = sortedGroupKeys.first,
                let firstConv = groupedConversations[firstKey]?.first {
                 selectedConversationID = firstConv.id
             } else if conversations.isEmpty {
                 // Focus input if there are no conversations at all
                 DispatchQueue.main.async { isInputFocused = true }
             }
         }
    }

    // MARK: - Actions

    func startNewConversation() {
        userInput = ""
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        conversations.append(newConversation)
        selectedConversationID = newConversation.id
        logger.info("Started new conversation with ID: \(newConversation.id.uuidString)")
        // Focus is handled by onChange(of: selectedConversationID)
    }

    // --- sendMessage Function (Unchanged from previous version) ---
    func sendMessage() {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("sendMessage called. Backend: \(selectedBackend.rawValue), isSending: \(isSending), trimmedInput: '\(trimmedInput)'")

        guard !isSending else {
            logger.warning("sendMessage aborted: Already sending.")
            return
        }
        guard !trimmedInput.isEmpty else {
            logger.info("sendMessage aborted: Input is empty after trimming.")
            userInput = ""
            return
        }

        let messageToSend = trimmedInput

        if selectedConversationID == nil {
            logger.info("No conversation selected. Starting a new one before sending.")
            startNewConversation()
        }

        guard let currentID = selectedConversationID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == currentID }) else {
            logger.error("CRITICAL: Could not find or create conversation (ID: \(String(describing: selectedConversationID))).")
            return
        }

        // Append user message locally
        let userMessage = "You: \(messageToSend)"
        conversations[conversationIndex].messages.append(userMessage)
        conversations[conversationIndex].timestamp = Date()
        let messageLog = messageToSend // Capture for logging
        userInput = "" // Clear input field
        isSending = true

        Task {
            var agentResponse = "Error: Agent response not received."
            var taskError: Error? = nil

            // Determine Backend Configuration
            let targetURL: String
            let targetEndpoint: String
            let payload: [String: Any]

            switch selectedBackend {
            case .ollama:
                targetURL = "http://127.0.0.1:11434" // Ollama default URL
                targetEndpoint = "/api/generate"
                payload = [
                    "model": llmModelName,
                    "prompt": messageToSend,
                    "stream": false
                ]
                logger.debug("Configured for Ollama. Model: \(llmModelName)")

            case .agent:
                targetURL = agentBaseURL // Use the configured Agent URL
                targetEndpoint = "/execute_task" // Agent endpoint
                payload = [
                    "main_task": messageToSend,
                    "strategy": agentDelegationStrategy
                ]
                logger.debug("Configured for Agent. URL: \(targetURL), Strategy: \(agentDelegationStrategy)")
            }

            do {
                logger.debug("Sending task '\(messageLog)' to \(targetURL)\(targetEndpoint) for conversation \(currentID.uuidString)")

                // Use dynamic URL/Endpoint (Assumes AIConnect is adapted)
                let responseData = try await aiConnect.postToLocalServer(baseURL: targetURL, endpoint: targetEndpoint, payload: payload)

                // --- UPDATED Response Handling ---
                if selectedBackend == .agent {
                    // Try parsing the specific Agent JSON structure
                    if let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
                       let resultsArray = json["results"] as? [[String: Any]] {

                        // Find the first result dictionary where status is "completed"
                        if let completedResultDict = resultsArray.first(where: { ($0["status"] as? String) == "completed" }),
                           let resultString = completedResultDict["result"] as? String {
                            // Successfully found and extracted the completed result
                            agentResponse = resultString.trimmingCharacters(in: .whitespacesAndNewlines)
                            let slaveId = completedResultDict["slave_id"] as? String ?? "unknown"
                            logger.debug("Extracted result from first completed agent (\(slaveId)): \(agentResponse)")
                        } else {
                            // Handle cases where no agent completed successfully
                            let failedCount = resultsArray.filter { ($0["status"] as? String) != "completed" }.count
                            if failedCount > 0 && failedCount == resultsArray.count {
                                // If all agents failed, try to show the first error message
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
                                 // This might happen if there are other statuses or partial success without 'completed'
                                 agentResponse = "Error: No agent completed the task successfully."
                                 logger.warning("No agent found with 'completed' status in results: \(resultsArray)")
                            }
                        }
                    } else if let textResponse = String(data: responseData, encoding: .utf8) {
                        // Fallback if it's not the expected JSON structure, treat as plain text
                        // This might indicate an error message from the server itself before the agent logic ran
                        agentResponse = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                        logger.warning("Received non-standard JSON or plain text from Agent backend: \(agentResponse)")
                    } else {
                        // Fallback if decoding fails completely
                        logger.error("Failed to decode Agent response data (neither expected JSON nor UTF-8 text).")
                        agentResponse = "Error: Could not decode server response."
                    }

                } else if selectedBackend == .ollama {
                    // Keep the existing Ollama handling logic
                    if let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] {
                        let replyKey = "response" // Ollama uses "response"
                        if let reply = json[replyKey] as? String {
                            agentResponse = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                            logger.debug("Received Ollama JSON response using key '\(replyKey)': \(agentResponse)")
                        } else {
                            logger.warning("Received Ollama JSON, but key '\(replyKey)' not found or not a string. Keys: \(json.keys)")
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
                // --- End UPDATED Response Handling ---

            } catch {
                logger.error("Error during API call or decoding: \(error.localizedDescription)")
                taskError = error
                agentResponse = generateErrorMessage(error: error)
            }

            // Update UI on Main Actor
            await MainActor.run {
                // Find index using the main conversations array
                if let updatedIndex = conversations.firstIndex(where: { $0.id == currentID }) {
                    conversations[updatedIndex].messages.append("Agent: \(agentResponse)")
                    conversations[updatedIndex].timestamp = Date() // Update timestamp on response
                } else {
                    logger.error("Error: Conversation \(currentID.uuidString) disappeared before agent response could be added.")
                }
                isSending = false
                // Optionally re-focus input if needed
                // isInputFocused = true
            }
        }
    }
    // --- End sendMessage ---

    // MARK: - Helper Functions

    private func scrollToBottom(scrollProxy: ScrollViewProxy, history: [String], animated: Bool = true) {
         guard !history.isEmpty else { return }
         let lastIndex = history.count - 1
         logger.trace("Scrolling to index \(lastIndex)")
         if animated {
             withAnimation(.easeOut(duration: 0.2)) {
                 scrollProxy.scrollTo(lastIndex, anchor: .bottom)
             }
         } else {
             scrollProxy.scrollTo(lastIndex, anchor: .bottom)
         }
     }

    private func generateErrorMessage(error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost: return "Error: Could not connect to the server (\(selectedBackend.rawValue)). Check if it's running and the URL/Port is correct."
            case .networkConnectionLost: return "Error: Network connection lost."
            case .notConnectedToInternet: return "Error: Not connected to the internet."
            case .badServerResponse:
                // Try to get more info from userInfo if available
                if let responseData = urlError.userInfo["ResponseData"] as? Data,
                   let responseString = String(data: responseData, encoding: .utf8) {
                    return "Error: Bad server response. Server said: \(responseString.prefix(150))"
                }
                return "Error: Received an invalid response from the server."
            case .cannotFindHost: return "Error: Cannot find the server host (\(selectedBackend.rawValue)). Check address/DNS."
            case URLError.Code(rawValue: 1): return "Error: Operation not permitted (check Sandbox/Firewall)." // POSIX EPERM
            default:
                logger.warning("Unhandled URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                return "Error: Network request failed (\(urlError.localizedDescription))."
            }
        }
        logger.warning("Unhandled error type: \(type(of: error)) - \(error.localizedDescription)")
        return "Error: \(error.localizedDescription)" // General error
    }

}

// MARK: - Message View (Helper)
struct MessageView: View {
    let message: String
    let isUser: Bool

    init(message: String) {
        self.message = message
        self.isUser = message.starts(with: "You:")
    }

    var body: some View {
        let prefixLength = isUser ? 4 : (message.starts(with: "Agent:") ? 6 : 0)
        let displayText = message.dropFirst(prefixLength)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
        Text(displayText)
            .padding(10)
            .background(isUser ? Color.blue.opacity(0.4) : Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(10)
            .textSelection(.enabled) // Allow text selection
    }
}

// Ensure AIConnect struct/class is defined elsewhere in your project.
// Ensure CustomTextEditor struct is defined in CustomTextEditor.swift
