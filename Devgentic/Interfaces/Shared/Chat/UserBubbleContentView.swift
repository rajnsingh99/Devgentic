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
                    // A horizontal ScrollView fills the proposed width and CENTERS
                    // undersized content, which left a few attachment cards floating
                    // mid-row while the text bubble + avatar hug the right edge.
                    // Anchor alignment trailing so the cards join the right-aligned
                    // message group; overflowing rows still scroll normally.
                    .defaultScrollAnchor(.trailing, for: .alignment)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(attachedTextFiles.count) attached files")
                }

                // ATT-2: attached images finally render. Thumbnails come from the
                // persisted bytes (the durable copy — the source URL goes stale), so
                // they survive reload and source-file deletion alike.
                if let attachedImageFiles = message.attachedImageFiles, !attachedImageFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: theme.spacingSmall) {
                            ForEach(attachedImageFiles) { file in
                                AttachedImageCardView(file: file)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                    }
                    // Trailing anchor for the same reason as the file row above.
                    .defaultScrollAnchor(.trailing, for: .alignment)
                    // `.contain`, NOT `.combine` like the file row: each thumbnail
                    // carries its own lightbox action, and combining would collapse
                    // them into one blob VoiceOver can't activate.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(attachedImageFiles.count) attached images")
                }

                if let textContent = message.content.textContent, !textContent.isEmpty {
                    UserMessageView(
                        text: textContent,
                        searchQuery: searchViewModel.isSearchActive ? searchViewModel.effectiveQuery : "",
                        activeHighlightIndex: searchViewModel.activeMatchIndex(in: message.id, blockID: nil)
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
