// /Users/alice/Documents/Workspace/mac-projects/devgentic-mac/AgenticDev/FloatingWindowView.swift
//
//  ContentView.swift
//  AgenticDev
//
//  Created by Raj Singh on 19/04/25.
//

import SwiftUI
import AppKit
import os // Import os for logging

// Logger for better debugging
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "FloatingWindowView")

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
            return String(content.prefix(30)) + (content.count > 30 ? "..." : "")
        }
        // Fallback if no user message yet or only agent messages
        return messages.first?.prefix(30).trimmingCharacters(in: .whitespacesAndNewlines) ?? "New Chat"
    }
}


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
                Conversation(id: UUID(), messages: ["You: Hello there!", "Agent: Hi! How can I help?"], timestamp: Date()),
                Conversation(id: UUID(), messages: ["You: What is Swift?"], timestamp: Date().addingTimeInterval(-3600))
            ],
            selectedConversationID: nil // Start with none selected in preview
        )
        .frame(width: 800, height: 500)

        // Example with no conversations
        FloatingWindowView(conversations: [])
            .frame(width: 800, height: 500)
            .previewDisplayName("No Conversations")

    }
}

struct FloatingWindowView: View {
    // --- Focus State ---
    @FocusState private var isInputFocused: Bool // <--- Add FocusState

    @State private var userInput = ""
    // --- Updated State ---
    @State var conversations: [Conversation] // Use @State for mutable array
    @State var selectedConversationID: UUID? // Use @State for mutable selection
    // --------------------

    // --- New State Variables ---
    @State private var showSettings: Bool = false
    @State private var windowOpacity: Double = 1.0 // Default opacity
    @State private var isSending: Bool = false // To disable input/button while waiting for response
    @State private var llmModelName: String = "gemma4b" // Default model, make configurable later if needed
    // --------------------------

    // --- AI Connection ---
    // Consider making this injectable or configurable
    private let aiConnect = AIConnect(baseURL: "http://127.0.0.1:11434")
    private let chatEndpoint = "/api/generate"
    // --------------------

    // Initializer for previews or external data loading
    init(conversations: [Conversation] = [], selectedConversationID: UUID? = nil) {
        _conversations = State(initialValue: conversations)
        _selectedConversationID = State(initialValue: selectedConversationID)
    }


    // Computed property to get the messages of the selected conversation
    private var currentChatHistory: [String] {
        guard let selectedID = selectedConversationID,
              let conversation = conversations.first(where: { $0.id == selectedID }) else {
            return [] // Return empty if no conversation is selected
        }
        return conversation.messages
    }

    // Computed property to get the index of the selected conversation
    private var selectedConversationIndex: Int? {
        guard let selectedID = selectedConversationID else { return nil }
        return conversations.firstIndex(where: { $0.id == selectedID })
    }

    // Computed property for sorted conversations (Optimization)
    private var sortedConversations: [Conversation] {
        conversations.sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        HStack(spacing: 0) {
            // --- Left Sidebar ---
            ZStack {
                Color.black.opacity(0.85)
                VStack(alignment: .leading, spacing: 0) {
                    // Header with New Chat Button
                    HStack {
                        Text("Conversations")
                            .font(.title3) // Slightly smaller title
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                        Spacer()
                        Button(action: startNewConversation) {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .buttonStyle(PlainButtonStyle())
                        // Add the shortcut to the visible button as well, for menu bar integration
                        .keyboardShortcut("n", modifiers: .command) // <--- Add shortcut here too
                    }
                    .padding()


                    Divider().background(Color.white.opacity(0.2))

                    // List of Conversations
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) { // Reduced spacing
                            // Use the computed property for sorting
                            ForEach(sortedConversations) { conversation in
                                // Use HStack + onTapGesture for better hit testing
                                HStack {
                                    Text(conversation.displayTitle)
                                        .foregroundColor(selectedConversationID == conversation.id ? .blue : .white) // Highlight selected
                                        .padding(.horizontal)
                                        .padding(.vertical, 8) // Slightly more padding
                                        .frame(maxWidth: .infinity, alignment: .leading) // Make visual content fill width
                                }
                                .background(selectedConversationID == conversation.id ? Color.white.opacity(0.2) : Color.clear) // Background for the HStack
                                .cornerRadius(5) // Corner radius for the HStack background
                                .contentShape(Rectangle()) // Define the tappable shape as the rectangle
                                .onTapGesture { // Add the tap action
                                    selectedConversationID = conversation.id
                                    isInputFocused = true // <--- Set focus when selecting a chat
                                }
                            }
                        }
                        .padding(.horizontal, 5) // Padding for the list itself
                        .padding(.top, 10)
                    }
                    Spacer() // Pushes list to the top
                }
            }
            .frame(width: 240)
            // --- End Left Sidebar ---

            Divider()

            // --- Main Interaction Area (Right Side) ---
            VStack(spacing: 0) {
                // Header with Settings Button
                HStack {
                    // Display title of current chat or placeholder
                    Text(currentConversationTitle)
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1) // Prevent wrapping
                        .truncationMode(.tail) // Add ellipsis if too long
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

                // Settings Slider (Conditional)
                if showSettings {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Transparency:")
                                .foregroundColor(.white.opacity(0.8))
                                .font(.caption)
                            Slider(value: $windowOpacity, in: 0.2...1.0)
                                .controlSize(.small)
                        }
                        HStack {
                            Text("Model:")
                                .foregroundColor(.white.opacity(0.8))
                                .font(.caption)
                            TextField("Model Name", text: $llmModelName)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.3))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Chat Message Area
                if selectedConversationID != nil || !conversations.isEmpty {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                // Display messages only if a conversation is selected
                                if selectedConversationID != nil {
                                    ForEach(currentChatHistory.indices, id: \.self) { index in
                                        let message = currentChatHistory[index]
                                        HStack {
                                            if message.starts(with: "Agent:") { Spacer() }
                                            MessageView(message: message)
                                            if message.starts(with: "You:") { Spacer() }
                                        }
                                        .id(index) // ID for scrolling
                                        .frame(maxWidth: .infinity, alignment: message.starts(with: "You:") ? .trailing : .leading)
                                    }
                                }
                                // Typing indicator (only show if sending within a selected chat)
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
                            .padding() // Padding inside the scroll view
                        }
                        .onChange(of: currentChatHistory) { _ in
                            // Only scroll if a conversation is selected
                            if selectedConversationID != nil {
                                scrollToBottom(scrollProxy: scrollProxy, history: currentChatHistory)
                            }
                        }
                        .onChange(of: isSending) { _ in
                             // Only scroll if a conversation is selected
                             if selectedConversationID != nil {
                                 scrollToBottom(scrollProxy: scrollProxy, history: currentChatHistory)
                             }
                        }
                        // Scroll when conversation changes
                        .onChange(of: selectedConversationID) { newID in
                            // Only scroll if the new ID is not nil
                            if newID != nil {
                                // Use DispatchQueue to allow view update before scrolling
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    scrollToBottom(scrollProxy: scrollProxy, history: currentChatHistory, animated: false)
                                    isInputFocused = true // <--- Set focus when selection changes
                                }
                            }
                        }
                    }
                    .padding(.bottom, 5) // <--- Added padding below the ScrollViewReader

                } else {
                    // Placeholder view when no conversation is selected AND the list is empty
                    Spacer()
                    Text("Type a message or press ⌘N to start a new chat.") // Updated placeholder
                        .foregroundColor(.gray)
                    Spacer()
                }


                // Input Area (disable only when sending)
                VStack(spacing: 6) {
                    // Use CustomTextEditor instead of standard TextEditor
                    CustomTextEditor(text: $userInput, onCommit: sendMessage)
                        .padding(2) // Add slight padding around the scrollview if needed
                        .frame(minHeight: 40, maxHeight: 120)
                        .background(Color.white.opacity(0.1)) // Apply background to the container
                        .cornerRadius(10) // Apply corner radius to the container
                        .focused($isInputFocused) // Bind focus state
                        .disabled(isSending)

                    HStack {
                        Spacer()
                        Button(action: sendMessage) {
                            if isSending {
                                ProgressView().controlSize(.small).frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .resizable()
                                    .frame(width: 28, height: 28)
                                    .foregroundColor(userInput.isEmpty ? .gray : .blue)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(userInput.isEmpty || isSending)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 10) // Existing padding below input area

                // --- Hidden Button for Keyboard Shortcut (Cmd+N) ---
                Button(action: startNewConversation) { EmptyView() }
                    .hidden() // Make it invisible
                    .keyboardShortcut("n", modifiers: .command) // Assign Cmd+N
                // ---------------------------------------------

            }
            .background(VisualEffectBlur())
            // --- End Main Interaction Area ---
        }
        .opacity(windowOpacity)
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
             // Select the most recent conversation on launch, if any
             if selectedConversationID == nil, let mostRecent = sortedConversations.first {
                 selectedConversationID = mostRecent.id
                 // Optionally set focus on appear if a chat is auto-selected
                 // DispatchQueue.main.async { isInputFocused = true }
             } else if conversations.isEmpty {
                 // If starting completely fresh, set focus
                 DispatchQueue.main.async { isInputFocused = true }
             }
         }
    }

    // MARK: - Computed Properties for UI
    private var currentConversationTitle: String {
        guard let index = selectedConversationIndex else { return "New Chat" } // Show "New Chat" if none selected
        return conversations[index].displayTitle
    }


    // MARK: - Actions

    func startNewConversation() {
        userInput = "" // Clear input field
        let newConversation = Conversation(id: UUID(), messages: [], timestamp: Date())
        conversations.append(newConversation)
        selectedConversationID = newConversation.id // Select the new one
        logger.info("Started new conversation with ID: \(newConversation.id.uuidString)")
        // Set focus when starting a new chat
        DispatchQueue.main.async { isInputFocused = true } // Use async to ensure view updates first
    }

    func sendMessage() {
        let trimmedInput = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        logger.debug("sendMessage called. isSending: \(isSending), trimmedInput: '\(trimmedInput)', isInputFocused: \(isInputFocused)")

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
            startNewConversation() // This will also set focus
        }

        guard let currentID = selectedConversationID,
              let conversationIndex = conversations.firstIndex(where: { $0.id == currentID }) else {
            logger.error("CRITICAL: Could not find or create a conversation (ID: \(String(describing: selectedConversationID))) to send message.")
            return
        }

        let userMessage = "You: \(messageToSend)"
        conversations[conversationIndex].messages.append(userMessage)
        conversations[conversationIndex].timestamp = Date()
        let messageLog = messageToSend
        userInput = "" // Clear input field *after* processing
        isSending = true
        // Ensure focus remains after sending if needed, though clearing might shift it
        // DispatchQueue.main.async { isInputFocused = true }


        Task {
            var agentResponse = "Error: Agent response not received."
            var taskError: Error? = nil

            do {
                let payload: [String: Any] = [
                    "model": llmModelName,
                    "prompt": messageToSend,
                    "stream": false
                ]
                logger.debug("Sending query '\(messageLog)' to \(chatEndpoint) for conversation \(currentID.uuidString)")
                let responseData = try await aiConnect.postToLocalServer(endpoint: chatEndpoint, payload: payload)

                if let json = try? JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any],
                   let reply = json["response"] as? String {
                    agentResponse = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.debug("Received JSON response: \(agentResponse)")
                } else if let textResponse = String(data: responseData, encoding: .utf8) {
                    agentResponse = textResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                    logger.warning("Received non-JSON or unexpected JSON response. Used plain text.")
                } else {
                    logger.error("Failed to decode response data.")
                    agentResponse = "Error: Could not decode server response."
                }

            } catch {
                logger.error("Error during API call or decoding: \(error.localizedDescription)")
                taskError = error
                agentResponse = generateErrorMessage(error: error)
            }

            await MainActor.run {
                if let updatedIndex = conversations.firstIndex(where: { $0.id == currentID }) {
                    conversations[updatedIndex].messages.append("Agent: \(agentResponse)")
                    conversations[updatedIndex].timestamp = Date()
                } else {
                    logger.error("Error: Conversation \(currentID.uuidString) disappeared before agent response could be added.")
                }
                isSending = false
                // Restore focus after response if desired
                // DispatchQueue.main.async { isInputFocused = true }
            }
        }
    }

    private func scrollToBottom(scrollProxy: ScrollViewProxy, history: [String], animated: Bool = true) {
         guard !history.isEmpty else { return }
         let lastIndex = history.count - 1
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
            case .cannotConnectToHost: return "Error: Could not connect to the local AI server (check if running)."
            case .networkConnectionLost: return "Error: Network connection lost."
            case .notConnectedToInternet: return "Error: Not connected to the internet."
            case .badServerResponse: return "Error: Received an invalid response from the server."
            case .cannotFindHost: return "Error: Cannot find the AI server host (check address/DNS)."
            case URLError.Code(rawValue: 1): return "Error: Operation not permitted (check Sandbox/Firewall)."
            default: return "Error: Network request failed (\(urlError.localizedDescription))."
            }
        }
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
        let displayText = (isUser ? message.dropFirst(4) : message.dropFirst(6))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
        Text(displayText)
            .padding(10)
            .background(isUser ? Color.blue.opacity(0.4) : Color.white.opacity(0.1))
            .foregroundColor(.white)
            .cornerRadius(10)
            .textSelection(.enabled)
    }
}
