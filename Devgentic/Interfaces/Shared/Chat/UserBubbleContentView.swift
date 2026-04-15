//
//  UserBubbleContentView.swift
//  Devgentic
//
//  Extracted from ChatBubbleView for decomposition.
//

import SwiftUI

struct UserBubbleContentView: View {
    var message: ChatMessage

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(ChatSearchViewModel.self) private var searchViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        Spacer()

        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: theme.spacingSmall) {
                if let attachedTextFiles = message.attachedTextFiles, !attachedTextFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: theme.spacingSmall) {
                            ForEach(attachedTextFiles) { file in
                                FileAttachmentCardView(
                                    fileName: file.name,
                                    action: {
                                        let fileExtension = (file.name as NSString).pathExtension
                                        chatHistoryViewModel.showCodeInViewer(language: fileExtension, code: file.content)
                                    }
                                )
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(attachedTextFiles.count) attached files")
                }

                if let textContent = message.content.textContent, !textContent.isEmpty {
                    UserMessageView(
                        text: textContent,
                        searchQuery: searchViewModel.isSearchActive ? searchViewModel.searchQuery : "",
                        activeHighlightIndex: searchViewModel.activeMatchLocalIndex(for: message.id)
                    )
                    .userBubbleStyle()
                    .textSelection(.enabled)
                    .accessibilityLabel("You said: \(textContent)")
                }
            }
            .frame(maxWidth: 600, alignment: .trailing)

            Image(systemName: "person.circle.fill")
                .font(.system(size: 24)) // Fixed size: intentional (icon)
                .foregroundColor(theme.secondaryText.opacity(0.4))
                .padding(.top, 4)
                .accessibilityHidden(true)
        }
    }
}
