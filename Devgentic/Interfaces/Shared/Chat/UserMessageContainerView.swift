//
//  UserMessageContainerView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import MarkdownUI
import Splash     

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
        HStack(alignment: .bottom, spacing: 0) {
            Spacer()
            messageContentWithStyling
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }


    @ViewBuilder
    private var messageContentWithStyling: some View {
        switch message.content {
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
                .frame(maxWidth: codeMaxWidth)
        case .image:
            messageContent
                       .frame(maxWidth: maxImageWidth, alignment: .trailing)
        case .plainText, .markdownText:
             messageContent
                 .padding(bubblePadding)
                 .background(userBackgroundColor)
                 .foregroundColor(userForegroundColor)
                 .cornerRadius(bubbleCornerRadius)
                 .frame(maxWidth: textMaxWidth, alignment: .trailing)
        default:
              messageContent
                 .padding(bubblePadding)
                 .background(Color.orange.opacity(0.2))
                 .foregroundColor(userForegroundColor)
                 .cornerRadius(bubbleCornerRadius)
                 .frame(maxWidth: textMaxWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        switch message.content {
        case .plainText(let text):
            Text(text)
                .font(.system(size: 16))
                .textSelection(.enabled)
        case .markdownText(let text):
            Markdown(text)
                .textSelection(.enabled)
                .markdownTheme(.basic.text {
                    FontSize(16)
                })
        case .codeBlock:
             EmptyView()
        case .error(let title, let details):
                     ErrorMessageView(title: title, details: details)
        case .image(let url, let alt):
            ImageView(url: url, alt: alt)
        default:
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
