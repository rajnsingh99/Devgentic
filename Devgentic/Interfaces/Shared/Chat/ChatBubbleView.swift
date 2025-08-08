//
//  ChatBubbleView.swift
//  Devgentic
//
//  Created by Raj Singh on 29/07/25.
//

import SwiftUI
import os
import Down

private let CODE_BLOCK_LINE_LIMIT = 50

struct ChatBubbleView: View {
    let message: ChatMessage
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel // Observe ChatHistoryViewModel

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
                    
                    // Action buttons for completed agent messages
                    if !message.isStreaming && message.content.textContent != nil {
                        AgentMessageActionsView(message: message)
                            .environmentObject(chatHistoryViewModel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 50)
                Spacer()
            } else { // message.sender == .user
                Spacer()
                VStack(alignment: .trailing, spacing: UITheme.Spacing.small) {
                    
                    if let attachedTextFiles = message.attachedTextFiles, !attachedTextFiles.isEmpty {
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
                .padding(.horizontal, 50)
            }
        }
        .padding(.vertical, 30)
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
                // --- FIX ---
                // The card was calling the wrong view model function.
                // It now calls `openMessageInCodeViewer`, which contains the logic
                // to scan the message for all large code blocks and enable navigation.
                let snippet = CodeSnippet(language: language, code: code)
                chatHistoryViewModel.openMessageInCodeViewer(message: message, selectedSnippet: snippet)
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
