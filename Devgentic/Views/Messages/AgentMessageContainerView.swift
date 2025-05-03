// Views/Messages/AgentMessageContainerView.swift
import SwiftUI
import MarkdownUI
import Splash

struct AgentMessageContainerView: View {
    let message: ChatMessage

    // ... (Keep styling parameters) ...
    private let textMaxWidth: CGFloat = 600
    private let codeMaxWidth: CGFloat = 700
    private let bubbleCornerRadius: CGFloat = 10
    private let bubblePadding: CGFloat = 10
    private let agentBackgroundColor = Color.gray.opacity(0.15)
    private let agentForegroundColor = Color.primary // Adapts light/dark
    // Define error specific styling if needed, or let ErrorMessageView handle foreground
    // private let errorBackgroundColor = Color.red.opacity(0.1) // Alternative BG?

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) { // Use .bottom or .top based on preference
            Spacer()
            messageContentWithStyling // Apply styling conditionally
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var messageContentWithStyling: some View {
        switch message.content {
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
                .frame(maxWidth: codeMaxWidth)
        case .plainText, .markdownText:
             messageContent
                 .padding(bubblePadding)
                 .background(agentBackgroundColor)
                 .foregroundColor(agentForegroundColor)
                 .cornerRadius(bubbleCornerRadius)
                 .frame(maxWidth: textMaxWidth, alignment: .leading)
        // --- NEW CASE: Error ---
        case .error:
             messageContent // Get the ErrorMessageView
                 .padding(bubblePadding) // Apply standard bubble padding
                 .background(agentBackgroundColor) // Use standard agent background for consistency
                 // ErrorMessageView sets its own foreground colors (red icon etc)
                 .cornerRadius(bubbleCornerRadius)
                 .frame(maxWidth: textMaxWidth, alignment: .leading) // Use standard text width
        // ------------------------
        default: // For future unsupported types
             messageContent
                 .padding(bubblePadding)
                 .background(Color.orange.opacity(0.2))
                 .foregroundColor(agentForegroundColor)
                 .cornerRadius(bubbleCornerRadius)
                 .frame(maxWidth: textMaxWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .plainText(let text):
            Text(text)
                .textSelection(.enabled)
        case .markdownText(let text):
            Markdown(text)
                .textSelection(.enabled)
                .markdownTheme(.basic)
        case .codeBlock:
             EmptyView() // Handled in messageContentWithStyling
        // --- NEW CASE: Error ---
        case .error(let title, let details):
             ErrorMessageView(title: title, details: details)
             // ErrorMessageView handles internal layout and colors
        // ------------------------
        default:
            Text("Unsupported content")
                .foregroundColor(.gray)
                .italic()
        }
    }
}

// MARK: - Preview Provider
struct AgentMessageContainerView_Previews: PreviewProvider {
    static let sampleConversationId = UUID()
    static let plainTextMessage = ChatMessage(
        conversationId: sampleConversationId, sender: .agent, content: .plainText("This is a plain text response from the agent.")
    )
    static let markdownMessage = ChatMessage(
        conversationId: sampleConversationId, sender: .agent, content: .markdownText("The agent can also respond with **Markdown** including lists:\n* Item 1\n* Item 2")
    )
    static let codeMessage = ChatMessage(
        conversationId: sampleConversationId, sender: .agent, content: .codeBlock(language: "python", code: "def agent_func(param):\n    return f\"Processed: {param}\"")
    )

    static var previews: some View {
        VStack(alignment: .trailing, spacing: 10) {
            AgentMessageContainerView(message: plainTextMessage)
            AgentMessageContainerView(message: markdownMessage)
            AgentMessageContainerView(message: codeMessage)
        }
        .padding()
        .background(Color.gray.opacity(0.3))
    }
}
