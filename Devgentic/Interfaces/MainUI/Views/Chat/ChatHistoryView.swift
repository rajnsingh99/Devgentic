// Views/ChatHistoryView.swift
import SwiftUI
import os

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatHistoryView")

struct ChatHistoryView: View {
    // --- UPDATED ---
    // Data passed down is now an array of ChatMessage objects
    let messages: [ChatMessage]
    // ---------------
    let isSending: Bool
    let hasSelectedConversation: Bool // To know if we should show the "thinking" indicator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if hasSelectedConversation {
                    // --- UPDATED ---
                    // Iterate over the Identifiable ChatMessage objects
                    ForEach(messages) { message in // No need for indices anymore
                        // Dispatch to the appropriate container view based on sender
                        if message.sender == .user {
                            UserMessageContainerView(message: message)
                        } else { // message.sender == .agent
                            AgentMessageContainerView(message: message)
                        }
                    }
                    // ---------------
                }

                // "Thinking" indicator logic remains the same, driven by isSending
                if isSending && hasSelectedConversation {
                    HStack {
                        // Display thinking indicator (consider making this an AgentMessageContainerView with .loading content later)
                        Text("Agent is thinking...")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(10)
                            .background(Color.gray.opacity(0.15)) // Consistent background
                            .cornerRadius(10)
                        Spacer()
                    }
                    .padding(.leading) // Keep padding consistent with message bubbles
                    .id("thinkingIndicator") // ID for scrolling remains
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 50) // Keep overall padding for the VStack content
            .frame(maxWidth: .infinity, alignment: .topLeading) // Ensure VStack takes width
        }
        // Keep background and frame for the ScrollView container
        .background(Color.clear) // Make ScrollView background clear, parent provides blur
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// --- UPDATED ---
// Preview Provider needs sample ChatMessage data
struct ChatHistoryView_Previews: PreviewProvider {
    // Create sample ChatMessage data
    static let sampleConversationId = UUID()
    static let sampleMessages: [ChatMessage] = [
        ChatMessage(conversationId: sampleConversationId, sender: .user, content: .plainText("Hello there!")),
        ChatMessage(conversationId: sampleConversationId, sender: .agent, content: .markdownText("Hi! How can I help?")),
        ChatMessage(conversationId: sampleConversationId, sender: .user, content: .plainText("Tell me about SwiftUI.")),
        ChatMessage(conversationId: sampleConversationId, sender: .agent, content: .markdownText("It's a declarative UI framework from Apple, great for building interfaces across Apple platforms."))
    ]
    static let sampleMessagesAgentFirst: [ChatMessage] = [
         ChatMessage(conversationId: sampleConversationId, sender: .agent, content: .markdownText("Welcome!")),
         ChatMessage(conversationId: sampleConversationId, sender: .user, content: .plainText("Thanks!"))
    ]


    static var previews: some View {
        ChatHistoryView(
            messages: sampleMessages, // Use sample ChatMessage array
            isSending: false,
            hasSelectedConversation: true
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 300)
        .background(Color.gray.opacity(0.5)) // Add background for preview visibility
        .previewDisplayName("Standard History")

        ChatHistoryView(
            messages: sampleMessagesAgentFirst, // Use sample ChatMessage array
            isSending: true, // Show thinking indicator
            hasSelectedConversation: true
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 200)
        .background(Color.gray.opacity(0.5))
        .previewDisplayName("Agent Thinking")

        ChatHistoryView(
            messages: [], // Empty history
            isSending: false,
            hasSelectedConversation: true
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 200)
        .background(Color.gray.opacity(0.5))
        .previewDisplayName("Empty History")

        ChatHistoryView(
            messages: [], // No history
            isSending: false,
            hasSelectedConversation: false // No selection (should show nothing)
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 200)
        .background(Color.gray.opacity(0.5))
        .previewDisplayName("No Selection")
    }
}
// ---------------
