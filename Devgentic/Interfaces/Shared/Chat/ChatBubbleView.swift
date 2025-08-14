//
//  ChatBubbleView.swift
//  Devgentic
//
//  Created by Raj Singh on 29/07/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatBubbleView")

private let CODE_BLOCK_LINE_LIMIT = 50

struct ChatBubbleView: View {
    let message: ChatMessage
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel

    var body: some View {
        HStack(alignment: .bottom, spacing: UITheme.Spacing.medium) {
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
                            AgentThinkingView()
                        } else if !text.isEmpty {
                            if message.isStreaming {
                                FadeInTypewriterView(markdown: text, message: message)
                            } else {
                                // MARK: - FIX: Use the array index as a stable ID since ContentBlock is no longer Identifiable.
                                let blocks = parseMarkdown(text)
                                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                    ContentBlockView(block: block, message: message)
                                }
                            }
                        }

                    case .codeBlock(let language, let code):
                        if code.components(separatedBy: .newlines).count > CODE_BLOCK_LINE_LIMIT {
                            CodeBlockCardView(language: language ?? "code", lineCount: code.components(separatedBy: .newlines).count, fileName: nil) {
                                let snippet = CodeSnippet(language: language, code: code)
                                chatHistoryViewModel.openMessageInCodeViewer(message: message, selectedSnippet: snippet)
                            }
                        } else {
                            CodeBlockView(language: language ?? "code", content: code)
                                .padding(.bottom, UITheme.Spacing.medium)
                                .frame(maxWidth: 700, alignment: .leading)
                        }

                    case .error(let title, let details):
                        ErrorMessageView(title: title, details: details)
                            .cardStyle()

                    case .image:
                        Text("[Image Content]")
                            .cardStyle()
                    }
                    
                    if !message.isStreaming && message.content.textContent != nil {
                        AgentMessageActionsView(message: message)
                            .environmentObject(chatHistoryViewModel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: message.isStreaming ? 500 : nil, alignment: .topLeading)
                .padding(.horizontal, 50)
                Spacer()
            } else { // message.sender == .user
                Spacer()
                VStack(alignment: .trailing, spacing: UITheme.Spacing.small) {
                    if let attachedTextFiles = message.attachedTextFiles, !attachedTextFiles.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: UITheme.Spacing.small) {
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
                            .padding(.vertical, UITheme.Spacing.xsmall)
                            .padding(.horizontal, UITheme.Spacing.xsmall)
                        }
                    }

                    if let textContent = message.content.textContent, !textContent.isEmpty {
                        UserMessageContentView(text: textContent)
                            .userBubbleStyle()
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 600, alignment: .trailing)
                .padding(.horizontal, 50)
            }
        }
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, alignment: message.sender == .agent ? .leading : .trailing)
    }
}

// MARK: - User Message Content View with Expand/Collapse
fileprivate struct UserMessageContentView: View {
    let text: String
    private let lineLimitCollapsed = 10
    @State private var isExpanded = false
    @State private var isTruncatable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isTruncatable {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isExpanded.toggle()
                        }
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .padding(6)
                            .background(Color.black.opacity(0.25))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand")
                }
            }

            Text(text)
                .font(UITheme.Fonts.body)
                .lineLimit(isExpanded ? nil : lineLimitCollapsed)
                .background(
                    GeometryReader { geometry in
                        Color.clear.onAppear {
                            determineTruncation(availableWidth: geometry.size.width)
                        }
                    }
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .clipped()
    }
    
    private func determineTruncation(availableWidth: CGFloat) {
        let fullTextView = Text(text)
            .font(UITheme.Fonts.body)
            .frame(width: availableWidth, alignment: .leading)
        
        let truncatedTextView = Text(text)
            .font(UITheme.Fonts.body)
            .lineLimit(lineLimitCollapsed)
            .frame(width: availableWidth, alignment: .leading)
            
        let fullSize = NSHostingView(rootView: fullTextView).fittingSize
        let truncatedSize = NSHostingView(rootView: truncatedTextView).fittingSize
        
        if fullSize.height > truncatedSize.height + 2 {
            self.isTruncatable = true
        }
    }
}


// MARK: - Reusable Action Button View
fileprivate struct ActionButton<LabelContent: View>: View {
    let action: () -> Void
    @ViewBuilder let label: LabelContent

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovering ? Color.gray.opacity(0.3) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Agent Message Actions View
fileprivate struct AgentMessageActionsView: View {
    let message: ChatMessage
    @EnvironmentObject var chatHistoryViewModel: ChatHistoryViewModel
    @State private var didCopy: Bool = false

    private var containsCode: Bool {
        switch message.content {
        case .codeBlock:
            return true
        case .markdownText(let text):
            return text.contains("```")
        default:
            return false
        }
    }

    var body: some View {
        HStack {
            Spacer()
            
            HStack(spacing: UITheme.Spacing.small) {
                if !containsCode {
                    ActionButton(action: {
                        chatHistoryViewModel.copyMessageContentToClipboard(message: message)
                        withAnimation(.easeInOut) { didCopy = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            withAnimation(.easeInOut) { didCopy = false }
                        }
                    }) {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .foregroundColor(didCopy ? .green : .secondary)
                    .help("Copy message content")
                    .animation(.easeInOut, value: didCopy)
                }

                ActionButton(action: {
                    // TODO: Implement redo functionality
                }) {
                    Label("Redo", systemImage: "arrow.clockwise")
                }
                .foregroundColor(.secondary)
                .help("Generate a new response (not implemented)")

                if containsCode {
                    ActionButton(action: {
                        chatHistoryViewModel.openMessageInCodeViewer(message: message)
                    }) {
                        Label("Open in Editor", systemImage: "doc.text.magnifyingglass")
                    }
                    .foregroundColor(.secondary)
                    .help("Open code in the side panel editor")
                }
            }
            .font(.system(size: 12))
            .padding(.top, UITheme.Spacing.small)
        }
    }
}


// MARK: - Agent Thinking Placeholder View
fileprivate struct AgentThinkingView: View {
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


// MARK: - Streaming FadeInTypewriter Animation View
struct FadeInTypewriterView: View {
    let markdown: String
    let message: ChatMessage
    
    var body: some View {
        VStack(alignment: .leading) {
            // MARK: - FIX: Use the array index as a stable ID since ContentBlock is no longer Identifiable.
            let blocks = parseMarkdown(markdown)
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                ContentBlockView(block: block, message: message)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: markdown)
        .onAppear {
            logger.info("SequentialTypewriterView appeared with initial markdown.")
        }
        .onChange(of: markdown) { oldValue, newValue in
            let newChars = newValue.count - oldValue.count
            logger.debug("STREAM_TRACE: FadeInTypewriterView markdown content updated. Added \(newChars) characters.")
        }
    }
}
