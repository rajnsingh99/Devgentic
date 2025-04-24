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
                if hasSelectedConversation {
                    ForEach(history.indices, id: \.self) { index in
                        let message = history[index]
                        if message.starts(with: "You:") {
                            HStack {
                                Spacer() // Push to the right
                                MessageView(message: message)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            HStack {
                                MessageView(message: message)
                                Spacer() // Push to the left
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if isSending && hasSelectedConversation {
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
                    .id("thinkingIndicator")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.black.opacity(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
