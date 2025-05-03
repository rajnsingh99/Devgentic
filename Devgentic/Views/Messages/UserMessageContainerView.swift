// Views/Messages/UserMessageContainerView.swift
import SwiftUI
import MarkdownUI // For Markdown rendering
import Splash     // For CodeBlockView syntax highlighting

struct UserMessageContainerView: View {
    let message: ChatMessage

    // Consistent styling parameters
    private let textMaxWidth: CGFloat = 500
    private let codeMaxWidth: CGFloat = 700 // Code blocks can be wider
    private let maxImageWidth: CGFloat = 350
    private let bubbleCornerRadius: CGFloat = 10
    private let bubblePadding: CGFloat = 10
    private let userBackgroundColor = Color.blue.opacity(0.4)
    private let userForegroundColor = SwiftUI.Color.white

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) { // Align to bottom for consistency
            // Apply styling conditionally based on content type
            messageContentWithStyling
            Spacer() // Push content to the left
        }
        .frame(maxWidth: .infinity, alignment: .leading) // Ensure HStack fills width, aligns left
        // Add padding on the right side of the entire HStack to prevent bubble touching edge
        // .padding(.trailing, 50) // Adjust as needed
    }

    // Applies the correct frame, padding, and background based on content type
    @ViewBuilder
    private var messageContentWithStyling: some View {
        switch message.content {
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
                // Code blocks manage their own background/padding via CodeBlockView itself
                .frame(maxWidth: codeMaxWidth) // Allow code blocks to be wider
        case .image: // <<< ADD IMAGE CASE
                    // Style image without bubble, provide padding directly if needed
                    messageContent
                       // Add padding *around* the ImageView if ImageView doesn't include enough
                       // .padding(.vertical, 4)
                       .frame(maxWidth: maxImageWidth, alignment: .leading) // Use appropriate width
        case .plainText, .markdownText:
             // Apply standard user bubble styling for text content
             messageContent // Get the Text or Markdown view
                 .padding(bubblePadding)
                 .background(userBackgroundColor)
                 .foregroundColor(userForegroundColor)
                 .cornerRadius(bubbleCornerRadius)
                 .frame(maxWidth: textMaxWidth, alignment: .leading) // Max width for text bubbles
        default:
             // Apply default styling for unsupported content (can match text bubble)
              messageContent
                 .padding(bubblePadding)
                 .background(Color.orange.opacity(0.2)) // Indicate unsupported?
                 .foregroundColor(userForegroundColor)
                 .cornerRadius(bubbleCornerRadius)
                 .frame(maxWidth: textMaxWidth, alignment: .leading)
        }
    }

    // Returns the actual view for the content (without bubble styling)
    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .plainText(let text):
            Text(text)
                .textSelection(.enabled)
        case .markdownText(let text):
            Markdown(text) // Use MarkdownUI view
                .textSelection(.enabled)
                .markdownTheme(.basic) // Apply a basic theme or customize as needed
        case .codeBlock:
             // Should not be reached here as CodeBlockView is created in messageContentWithStyling
             EmptyView()
        case .error(let title, let details): // Handle error case here too
                     ErrorMessageView(title: title, details: details)
        case .image(let url, let alt): // <<< ADD IMAGE CASE
            ImageView(url: url, alt: alt)
        default:
            // Fallback for unhandled or future content types
            Text("Unsupported content")
                .foregroundColor(.gray)
                .italic()
        }
    }
}

// MARK: - Preview Provider
struct UserMessageContainerView_Previews: PreviewProvider {
    static let sampleConversationId = UUID()
    static let plainTextMessage = ChatMessage(
        conversationId: sampleConversationId, sender: .user, content: .plainText("This is plain text.")
    )
    static let markdownMessage = ChatMessage(
        conversationId: sampleConversationId, sender: .user, content: .markdownText("This is **bold** and *italic* using MarkdownUI.")
    )
    static let codeMessage = ChatMessage(
        conversationId: sampleConversationId, sender: .user, content: .codeBlock(language: "swift", code: "let message = \"Hello, Preview!\"\nprint(message)")
    )

    static var previews: some View {
        VStack(alignment: .leading, spacing: 10) {
            UserMessageContainerView(message: plainTextMessage)
            UserMessageContainerView(message: markdownMessage)
            UserMessageContainerView(message: codeMessage)
        }
        .padding()
        .background(Color.gray.opacity(0.3))
    }
}
