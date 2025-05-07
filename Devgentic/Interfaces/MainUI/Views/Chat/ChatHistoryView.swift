// Views/ChatHistoryView.swift
import SwiftUI
import os

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatHistoryView")

struct ChatHistoryView: View {
    let messages: [ChatMessage]
    let isSending: Bool
    let hasSelectedConversation: Bool
    let chatHistoryBottomPadding: CGFloat // <<-- NEW parameter

    // Define a subtle color for the divider, adaptable to light/dark mode
    private var dividerColor: Color {
        #if os(macOS)
        return Color(NSColor.separatorColor)
        #else
        return Color(UIColor.separator)
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { // Set spacing to 0, manage with padding
                if hasSelectedConversation {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index > 0 {
                            let previousMessage = messages[index - 1]
                            if message.sender != previousMessage.sender {
                                Divider()
                                    .background(dividerColor)
                                    .padding(.vertical, 15)
                            }
                        }

                        if message.sender == .user {
                            UserMessageContainerView(message: message)
                                .padding(.vertical, 10)
                        } else { // message.sender == .agent
                            AgentMessageContainerView(message: message)
                                .padding(.vertical, 10)
                        }
                    }
                }

                if isSending && hasSelectedConversation {
                    if let lastMessage = messages.last, lastMessage.sender == .user {
                        Divider()
                            .background(dividerColor)
                            .padding(.vertical, 15)
                    }
                    HStack {
                        Text("Agent is thinking...")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .padding(10)
                            .background(Color.gray.opacity(0.15))
                            .cornerRadius(10)
                        Spacer()
                    }
                    .padding(.leading)
                    .padding(.vertical, 10)
                    .id("thinkingIndicator")
                }
            }
            .padding(.top, 20) // Keep original top padding
            .padding(.bottom, chatHistoryBottomPadding) // <<-- APPLY PADDING HERE
            .padding(.horizontal, 50) // Keep original horizontal padding
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.clear) // Make ScrollView background clear
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) // ScrollView takes full available space
    }
}

// --- UPDATED Preview Provider ---
struct ChatHistoryView_Previews: PreviewProvider {
    static let sampleConversationId = UUID()
    static let sampleMessages: [ChatMessage] = [
        ChatMessage(conversationId: sampleConversationId, sender: .user, content: .plainText("Hello there!")),
        ChatMessage(conversationId: sampleConversationId, sender: .agent, content: .markdownText("Hi! How can I help? This is the first agent message.")),
        ChatMessage(conversationId: sampleConversationId, sender: .agent, content: .codeBlock(language: "swift", code: "let a = 10")),
        ChatMessage(conversationId: sampleConversationId, sender: .user, content: .plainText("Tell me about SwiftUI.")),
        ChatMessage(conversationId: sampleConversationId, sender: .agent, content: .markdownText("It's a declarative UI framework from Apple, great for building interfaces across Apple platforms."))
    ]
    static let sampleMessagesAgentFirst: [ChatMessage] = [
         ChatMessage(conversationId: sampleConversationId, sender: .agent, content: .markdownText("Welcome!")),
         ChatMessage(conversationId: sampleConversationId, sender: .user, content: .plainText("Thanks!"))
    ]

    static var previews: some View {
        ChatHistoryView(
            messages: sampleMessages,
            isSending: false,
            hasSelectedConversation: true,
            chatHistoryBottomPadding: 120 // Provide a value for the preview
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 500)
        .background(Color.gray.opacity(0.5))
        .previewDisplayName("Standard History with Dividers")

        ChatHistoryView(
            messages: sampleMessagesAgentFirst,
            isSending: true,
            hasSelectedConversation: true,
            chatHistoryBottomPadding: 120 // Provide a value for the preview
        )
        .previewLayout(.sizeThatFits)
        .frame(height: 300)
        .background(Color.gray.opacity(0.5))
        .previewDisplayName("Agent Thinking with Dividers")
    }
}
