// Views/Messages/AgentMessageContainerView.swift
import SwiftUI
import MarkdownUI
import Splash

struct AgentMessageContainerView: View {
    let message: ChatMessage

    private let maxImageWidth: CGFloat = 350
    private let agentForegroundColor = Color.primary // Adapts light/dark
    // Define error specific styling if needed, or let ErrorMessageView handle foreground
    // private let errorBackgroundColor = Color.red.opacity(0.1) // Alternative BG?

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) { // Use .bottom or .top based on preference
            messageContentWithStyling // Apply styling conditionally
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var messageContentWithStyling: some View {
        switch message.content {
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
                .frame(maxWidth: .infinity)
        case .image:
            messageContent.frame(maxWidth: maxImageWidth, alignment: .leading) // Align content LTR even in agent bubble
        case .plainText, .markdownText:
             messageContent
                 .foregroundColor(agentForegroundColor)
                 .frame(maxWidth: .infinity, alignment: .leading)
                 .padding(.bottom, 15)
        // --- NEW CASE: Error ---
        case .error:
             messageContent
                 .frame(maxWidth: .infinity, alignment: .leading) // Use standard text width
        // ------------------------
        default: // For future unsupported types
             messageContent
                 .foregroundColor(agentForegroundColor)
                 .frame(maxWidth: .infinity, alignment: .leading)
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
        case .image(let url, let alt): // <<< ADD IMAGE CASE
                     ImageView(url: url, alt: alt)
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
