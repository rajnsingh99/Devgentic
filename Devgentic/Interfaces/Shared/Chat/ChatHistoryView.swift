//
//  ChatHistoryView.swift
//  Devgentic
//
//  Created by Raj Singh
//


import SwiftUI
import os
import Down

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatHistoryView")

private let CODE_BLOCK_LINE_LIMIT = 50

// MARK: - ChatHistoryView
struct ChatHistoryView: View {

    @EnvironmentObject private var viewModel: MainApplicationViewModel
    
    @State private var showScrollToBottomButton = false
    @State private var scrollTargetID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                chatScrollView(proxy: proxy)
                    .task(id: viewModel.streamingTriggerID) {
                        guard viewModel.streamingTriggerID != nil else { return }
                        await consumeStream()
                    }
                    .onChange(of: viewModel.streamingTriggerID) { newTriggerID in
                        if let id = newTriggerID {
                            logger.info("Streaming trigger ID changed. Setting scroll target to \(id.uuidString)")
                            self.scrollTargetID = id
                        }
                    }
                    .onChange(of: scrollTargetID) { targetID in
                        if let id = targetID {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                logger.debug("Attempting to scroll to placeholder ID \(id.uuidString) with position: .top")
                                scrollTo(proxy: proxy, anchor: id, position: .top, animated: false)
                                self.scrollTargetID = nil
                            }
                        }
                    }
                    .onChange(of: viewModel.currentChatMessages.first?.id) {
                        if !viewModel.isSending, let firstMessageId = viewModel.currentChatMessages.first?.id {
                           scrollTo(proxy: proxy, anchor: firstMessageId, position: .bottom, animated: true)
                        }
                    }
                
                if showScrollToBottomButton {
                    scrollToBottomButton(proxy: proxy)
                }
            }
        }
    }

    private func chatScrollView(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if viewModel.selectedConversationID != nil {
                    ForEach(Array(viewModel.currentChatMessages.enumerated()), id: \.element.id) { index, message in
                        ChatBubbleView(message: message)
                            .id(message.id)
                            .rotationEffect(.degrees(180))
                            .scaleEffect(x: -1, y: 1, anchor: .center)
                            .onAppear {
                                if viewModel.currentChatMessages.last?.id == message.id && viewModel.canLoadMorePages {
                                    logger.debug("Reached top of chat, loading more messages.")
                                    Task {
                                        await viewModel.loadMoreMessages()
                                    }
                                }
                                
                                if index > 5 {
                                    withAnimation(.easeInOut) {
                                        showScrollToBottomButton = true
                                    }
                                }
                                if index < 2 {
                                     withAnimation(.easeInOut) {
                                        showScrollToBottomButton = false
                                    }
                                }
                            }

                        if index < viewModel.currentChatMessages.count - 1 {
                            Spacer().frame(height: UITheme.Spacing.xlarge) 
                                .rotationEffect(.degrees(180))
                                .scaleEffect(x: -1, y: 1, anchor: .center)
                        }
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(.top, UITheme.Spacing.large)
            .padding(.horizontal, 50)
            .padding(.bottom, UITheme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rotationEffect(.degrees(180))
        .scaleEffect(x: -1, y: 1, anchor: .center)
    }
    
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button(action: {
            if let lastMessageId = viewModel.currentChatMessages.first?.id {
                scrollTo(proxy: proxy, anchor: lastMessageId, position: .bottom, animated: true)
            }
        }) {
            Image(systemName: "arrow.down")
                .font(UITheme.Fonts.headline)
                .foregroundColor(.white)
                .padding(UITheme.Spacing.medium)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.bottom)
        .transition(.scale.combined(with: .opacity))
    }

    private func consumeStream() async {
        guard viewModel.streamingTriggerID != nil,
              let conversationID = viewModel.selectedConversationID,
              let lastUserMessage = viewModel.currentChatMessages.first(where: { $0.sender == .user }),
              let userQuery = lastUserMessage.content.textContent
        else {
            if viewModel.isSending {
                logger.warning("consumeStream: Pre-conditions not met, but isSending was true. Resetting state.")
                await viewModel.resetSendingState()
            }
            return
        }

        logger.debug("Starting stream consumption for user message ID: \(lastUserMessage.id.uuidString)")
        var finalError: Error?

        do {
            let history = Array(viewModel.currentChatMessages.dropFirst(2))
            
            let stream = viewModel.streamResponse(
                conversationID: conversationID,
                userQuery: userQuery,
                history: history,
                files: viewModel.attachedFiles
            )

            for try await token in stream {
                await viewModel.appendTokenToStreamingMessage(token)
            }
            logger.info("Stream consumption finished successfully.")
            
        } catch {
            logger.error("Stream consumption failed: \(error.localizedDescription)")
            finalError = error
        }

        await viewModel.finalizeStreaming(
            conversationID: conversationID,
            error: finalError
        )
    }

    private func scrollTo(proxy: ScrollViewProxy, anchor: any Hashable, position: UnitPoint, animated: Bool) {
        logger.debug("scrollTo called for anchor: \(String(describing: anchor)), position: \(String(describing: position)), animated: \(animated)")
        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(anchor, anchor: position)
            }
        } else {
            proxy.scrollTo(anchor, anchor: position)
        }
    }
}

// MARK: - Thinking Indicator View
fileprivate struct ThinkingIndicatorView: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: UITheme.Spacing.small) {
            Image(systemName: "sparkle")
                .font(UITheme.Fonts.callout.weight(.bold))
                .foregroundColor(UITheme.Colors.accent)
                .opacity(isAnimating ? 1.0 : 0.5)
                .animation(Animation.easeInOut(duration: 1).repeatForever(), value: isAnimating)

            Text("Thinking...")
                .font(UITheme.Fonts.callout)
                .foregroundColor(UITheme.Colors.secondaryText)
        }
        .onAppear {
            self.isAnimating = true
        }
        .frame(height: 22)
    }
}


// MARK: - ChatBubbleView
struct ChatBubbleView: View {
    let message: ChatMessage
    @EnvironmentObject private var viewModel: MainApplicationViewModel

    var body: some View {
        HStack(alignment: .top, spacing: UITheme.Spacing.medium) {
            if message.sender == .agent {
                VStack(alignment: .leading, spacing: UITheme.Spacing.medium) {
                    switch message.content {
                    case .plainText(let text):
                        Text(text)
                            .font(UITheme.Fonts.body)
                            .foregroundColor(UITheme.Colors.primaryText)
                            .textSelection(.enabled)

                    case .markdownText(let text):
                        if message.isStreaming && text.isEmpty {
                            ThinkingIndicatorView()
                        } else if !text.isEmpty {
                            ForEach(parseMarkdown(text)) { block in
                                renderContentBlock(block)
                            }
                        }

                    case .codeBlock(let language, let code):
                        renderCodeBlock(language: language, code: code)

                    case .error(let title, let details):
                        ErrorMessageView(title: title, details: details)
                            .cardStyle()

                    case .image:
                        Text("[Image Content]")
                            .cardStyle()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            } else { // message.sender == .user
                Spacer()
                VStack(alignment: .trailing, spacing: UITheme.Spacing.small) {
                    
                    if let attachedTextFiles = message.attachedTextFiles, !attachedTextFiles.isEmpty {
                        // This part can also be themed if needed
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: UITheme.Spacing.small) {
                                ForEach(attachedTextFiles) { file in
                                    Text(file.name)
                                        .font(UITheme.Fonts.footnote)
                                        .foregroundColor(.white.opacity(0.8))
                                        .padding(.horizontal, UITheme.Spacing.medium)
                                        .padding(.vertical, UITheme.Spacing.xsmall)
                                        .background(Color.black.opacity(0.2))
                                        .cornerRadius(UITheme.CornerRadius.medium)
                                }
                            }
                        }
                        .frame(height: 30)
                    }

                    if let textContent = message.content.textContent, !textContent.isEmpty {
                        Text(textContent)
                            .font(UITheme.Fonts.body)
                            .chatBubbleStyle(isCurrentUser: true)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 600, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .agent ? .leading : .trailing)
    }
    
    @ViewBuilder
    private func renderContentBlock(_ block: ContentBlock) -> some View {
        switch block {
        case .paragraph(let paragraphText):
            Text(try! AttributedString(markdown: paragraphText))
                .font(UITheme.Fonts.body)
                .lineSpacing(UITheme.Spacing.xsmall)
                .foregroundColor(UITheme.Colors.primaryText)
                .padding(.bottom, UITheme.Spacing.small)
                .textSelection(.enabled)
        
        case .code(let lang, let codeContent):
            renderCodeBlock(language: lang, code: codeContent)

        case .heading(let level, let headingText):
            Text(headingText)
                .font(fontForHeading(level: level))
                .fontWeight(fontWeightForHeading(level: level))
                .padding(.top, UITheme.Spacing.medium)
                .padding(.bottom, UITheme.Spacing.xsmall)
                .textSelection(.enabled)

        case .listItem(let prefix, let itemText, let indentation):
            HStack(alignment: .top, spacing: UITheme.Spacing.small) {
                Text(prefix)
                    .font(UITheme.Fonts.body)
                    .foregroundColor(UITheme.Colors.secondaryText)
                    .frame(minWidth: 20, alignment: .leading)
                
                Text(try! AttributedString(markdown: itemText))
                    .font(UITheme.Fonts.body)
                    .foregroundColor(UITheme.Colors.primaryText)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indentation * 20)) // 20pt per indent level
            .padding(.bottom, UITheme.Spacing.xxsmall)

        case .horizontalRule:
            Divider()
                .padding(.vertical, UITheme.Spacing.medium)
        }
    }
    
    @ViewBuilder
    private func renderCodeBlock(language: String?, code: String) -> some View {
        if code.components(separatedBy: .newlines).count > CODE_BLOCK_LINE_LIMIT {
            CodeBlockCardView(language: language ?? "code", lineCount: code.components(separatedBy: .newlines).count) {
                viewModel.showCodeInViewer(language: language, code: code)
            }
        } else {
            CodeBlockView(language: language ?? "code", content: code)
                .padding(.bottom, UITheme.Spacing.medium)
                .frame(maxWidth: 700, alignment: .leading)
        }
    }
    
    private func fontForHeading(level: Int) -> Font {
        switch level {
        case 1: return UITheme.Fonts.title1
        case 2: return UITheme.Fonts.title2
        default: return UITheme.Fonts.title3
        }
    }
    
    private func fontWeightForHeading(level: Int) -> Font.Weight {
        switch level {
        case 1: return .bold
        case 2: return .semibold
        default: return .semibold
        }
    }
}
