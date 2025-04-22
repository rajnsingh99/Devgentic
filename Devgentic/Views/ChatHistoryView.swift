// Views/ChatHistoryView.swift
import SwiftUI
import os

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatHistoryView")

struct ChatHistoryView: View {
    // Data passed down
    let history: [String]
    let isSending: Bool
    let hasSelectedConversation: Bool // To know if we should show the "thinking" indicator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // Display messages only if a conversation is selected
                if hasSelectedConversation {
                    ForEach(history.indices, id: \.self) { index in
                        let message = history[index]
                        // Align messages left/right based on sender
                        HStack {
                            if message.starts(with: "Agent:") { Spacer() } // Push Agent messages right
                            MessageView(message: message) // Use the existing MessageView
                            if message.starts(with: "You:") { Spacer() } // Push User messages left
                        }
                        .id(index) // ID for ScrollViewReader
                        .frame(maxWidth: .infinity, alignment: message.starts(with: "You:") ? .trailing : .leading)
                    }
                }

                // "Agent is thinking..." indicator
                if isSending && hasSelectedConversation {
                    HStack {
                         Text("Agent is thinking...")
                             .font(.caption)
                             .foregroundColor(.gray)
                             .padding(10)
                             .background(Color.white.opacity(0.1))
                             .cornerRadius(10)
                         Spacer() // Align left
                     }
                     .padding(.leading)
                     .id("thinkingIndicator") // ID for ScrollViewReader if needed
                }

                // REMOVED Spacer()

            } // End VStack
            .padding() // Padding around the message list
            // Add frame modifier to make VStack expand vertically within ScrollView and align content top
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // <--- APPLY FRAME HERE

        } // End ScrollView
        // Note: .onChange modifiers and ScrollViewReader are kept in the parent view (FloatingWindowView)
    }
}

// Preview Provider (remains the same)
struct ChatHistoryView_Previews: PreviewProvider {
    static let sampleHistoryUserFirst = [
        "You: Hello there!",
        "Agent: Hi! How can I help?",
        "You: Tell me about SwiftUI.",
        "Agent: It's a declarative UI framework from Apple."
    ]
    static let sampleHistoryAgentFirst = [
        "Agent: Welcome!",
        "You: Thanks!"
    ]

    static var previews: some View {
        // Previews remain the same...
        ChatHistoryView(
            history: sampleHistoryUserFirst,
            isSending: false,
            hasSelectedConversation: true
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 300)
        .previewDisplayName("Standard History")

        ChatHistoryView(
            history: sampleHistoryAgentFirst,
            isSending: true, // Show thinking indicator
            hasSelectedConversation: true
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 200)
        .previewDisplayName("Agent Thinking")

        ChatHistoryView(
            history: [], // Empty history
            isSending: false,
            hasSelectedConversation: true // Still has selection, just no messages
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 200)
        .previewDisplayName("Empty History")

        ChatHistoryView(
            history: [], // No history
            isSending: false,
            hasSelectedConversation: false // No selection (should show nothing)
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 200)
        .previewDisplayName("No Selection")
    }
}
