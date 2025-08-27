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
    @ObservedObject var message: ChatMessage
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel
    @EnvironmentObject private var mainAppViewModel: MainApplicationViewModel

    private var contentToDisplay: MessageContent {
        if message.sender == .agent, let content = message.currentAgentContent {
            return content
        }
        return message.content
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: UITheme.Spacing.medium) {
            if message.sender == .agent {
                VStack(alignment: .leading, spacing: UITheme.Spacing.medium) {
                    switch contentToDisplay {
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

                    case .image(_, _, let imageData):
                        if let data = imageData {
                            ImageView(imageData: data)
                                .padding(.vertical, UITheme.Spacing.small)
                                .frame(maxWidth: 500, alignment: .leading)
                        } else {
                            ErrorMessageView(title: "Image Not Available", details: "The image data could not be loaded.")
                                .cardStyle()
                        }
                    }
                    
                    if !message.isStreaming && contentToDisplay.textContent != nil {
                        AgentMessageActionsView(message: message, mainAppViewModel: mainAppViewModel)
                            .environmentObject(chatHistoryViewModel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: message.isStreaming ? 50 : nil, alignment: .topLeading)
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
                        UserMessageView(text: textContent)
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
        .animation(.easeInOut, value: message.agentResponse?.selectedVariantIndex)
    }
}

// MARK: - Reusable Action Button View
fileprivate struct ActionButton<LabelContent: View>: View {
    let action: () -> Void
    @ViewBuilder let label: LabelContent
    var disabled: Bool = false

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovering && !disabled ? Color.gray.opacity(0.3) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Agent Message Actions View
fileprivate struct AgentMessageActionsView: View {
    @ObservedObject var message: ChatMessage
    var mainAppViewModel: MainApplicationViewModel
    @EnvironmentObject var chatHistoryViewModel: ChatHistoryViewModel
    
    @State private var didCopy: Bool = false
    @State private var showVariantsPopover: Bool = false

    private var containsCode: Bool {
        guard let content = message.currentAgentContent else { return false }
        switch content {
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

                // Variants Button
                if message.agentResponse?.variants.count ?? 0 > 1 {
                    ActionButton(action: {
                        showVariantsPopover.toggle()
                    }) {
                        Label("\(message.agentResponse?.variants.count ?? 0) Versions", systemImage: "square.3.layers.3d.down.right")
                    }
                    .foregroundColor(.secondary)
                    .help("Show other response versions")
                    .popover(isPresented: $showVariantsPopover, arrowEdge: .bottom) {
                        VariantsSelectionView(message: message, isPresented: $showVariantsPopover)
                    }
                }

                // Redo Button
                let isRedoDisabled = (message.agentResponse?.generationAttempts ?? 0) >= 5
                ActionButton(action: {
                    mainAppViewModel.regenerateResponse(for: message)
                }, disabled: isRedoDisabled) {
                    Label("Redo", systemImage: "arrow.clockwise")
                }
                .foregroundColor(isRedoDisabled ? .gray.opacity(0.5) : .secondary)
                .help(isRedoDisabled ? "Maximum number of responses generated" : "Generate a new response")

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

// MARK: - Variants Selection Popover View
fileprivate struct VariantsSelectionView: View {
    @ObservedObject var message: ChatMessage
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Response Versions")
                .font(.headline)
                .padding()
            
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let agentResponse = message.agentResponse {
                        ForEach(Array(zip(agentResponse.variants.indices, agentResponse.variants)), id: \.0) { index, variant in
                            Button(action: {
                                message.agentResponse?.selectedVariantIndex = index
                                isPresented = false
                            }) {
                                HStack {
                                    Text(variant.content.textContent ?? "Empty Response")
                                        .lineLimit(3)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    Spacer()
                                    
                                    if index == agentResponse.selectedVariantIndex {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding()
                                .background(index == agentResponse.selectedVariantIndex ? Color.accentColor.opacity(0.1) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            
                            if index < agentResponse.variants.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 400, maxWidth: 500, minHeight: 200, idealHeight: 300, maxHeight: 400)
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
    @ObservedObject var message: ChatMessage
    
    var body: some View {
        VStack(alignment: .leading) {
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
//            logger.debug("STREAM_TRACE: FadeInTypewriterView markdown content updated. Added \(newChars) characters.")
        }
    }
}
