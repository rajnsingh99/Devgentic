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
private let STREAMING_BUBBLE_MIN_HEIGHT: CGFloat = 550

struct ChatBubbleView: View {
    @ObservedObject var message: ChatMessage
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel
    @EnvironmentObject private var mainAppViewModel: MainApplicationViewModel

    // MARK: - State to control the animation
    @State private var applyMinHeight: Bool = false

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
                    
                    // ---------------------------------------------------------
                    // 1. GLASS BOX: Thinking Process (Thoughts)
                    // ---------------------------------------------------------
                    if !message.thoughts.isEmpty || message.isStreaming {
                        ThinkingAccordionView(
                            thoughts: message.thoughts,
                            currentHeadline: message.thinkingHeadline,
                            isStreaming: message.isStreaming,
                            isExpanded: $message.isThinkingExpanded
                        )
                    }
                    
                    // ---------------------------------------------------------
                    // 2. GLASS BOX: Tool Artifacts (Data Cards)
                    // ---------------------------------------------------------
                    if !message.artifacts.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(message.artifacts) { artifact in
                                ArtifactCardView(artifact: artifact)
                            }
                        }
                        .padding(.bottom, 8)
                    }

                    // ---------------------------------------------------------
                    // 3. HITL: Permission Request Card (Gating)
                    // ---------------------------------------------------------
                    if let confirmation = message.pendingToolConfirmation {
                        PermissionRequestView(confirmation: confirmation, message: message)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // ---------------------------------------------------------
                    // 4. FINAL ANSWER (Text Content)
                    // ---------------------------------------------------------
                    switch contentToDisplay {
                    case .plainText(let text):
                        Text(text)
                            .font(UITheme.Fonts.body)
                            .foregroundColor(UITheme.Colors.primaryText)
                            .textSelection(.enabled)

                    case .markdownText(let text):
                        // MARK: - Dynamic Thinking Headline Update
                        if message.isStreaming && text.isEmpty {
                            // Only show spinner if NOT requesting permission
                            if message.pendingToolConfirmation == nil {
                                AgentThinkingView(headline: message.thinkingHeadline)
                            }
                        } else if !text.isEmpty {
                            let blocks = message.isStreaming ? parseMarkdown(text) : message.getOrCreateMarkdownBlocks(from: text)
                            
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                ContentBlockView(block: block, message: message)
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
                .frame(minHeight: applyMinHeight ? STREAMING_BUBBLE_MIN_HEIGHT : nil, alignment: .topLeading)
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
        .onAppear {
            if message.isStreaming && !applyMinHeight {
                withAnimation(.easeInOut(duration: 0.3)) {
                    applyMinHeight = true
                }
            }
        }
        .onChange(of: message.isStreaming) { _, isStreaming in
            if !isStreaming {
                withAnimation(.easeIn(duration: 0.5)) {
                    applyMinHeight = false
                }
            }
        }
    }
}

// MARK: - Thinking Accordion (Gemini-Style)

struct ThinkingAccordionView: View {
    let thoughts: [String]
    let currentHeadline: String?
    let isStreaming: Bool
    @Binding var isExpanded: Bool
    
    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(thoughts, id: \.self) { thought in
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 2)
                            .padding(.vertical, 2)
                        
                        Text(thought)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                if isStreaming, let headline = currentHeadline {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                        Text(headline)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.accentColor)
                            .italic()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.leading, 8)
            .padding(.top, 8)
            .padding(.bottom, 8)
            
        } label: {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(isStreaming ? .accentColor : .secondary)
                
                Text(isStreaming ? "Thinking..." : "Thought Process")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundColor(isStreaming ? .primary : .secondary)
                
                if isStreaming {
                    Text(currentHeadline ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
        .accentColor(.secondary)
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Permission Request Card (HITL)

struct PermissionRequestView: View {
    let confirmation: PendingToolConfirmation
    @ObservedObject var message: ChatMessage
    @EnvironmentObject var mainAppViewModel: MainApplicationViewModel
    
    @State private var isProcessingDecision = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))
                
                Text("Permission Required")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
            }
            
            Divider()
                .background(Color.gray.opacity(0.2))
            
            // Content
            VStack(alignment: .leading, spacing: 6) {
                Text("The agent wants to execute a sensitive action:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 6) {
                    Text(confirmation.toolName)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(4)
                }
                
                if !confirmation.params.isEmpty && confirmation.params != "{}" {
                    Text(confirmation.params)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(4)
                        .padding(8)
                        .background(Color.black.opacity(0.1))
                        .cornerRadius(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            
            // Actions
            HStack(spacing: 12) {
                if isProcessingDecision {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(height: 28)
                } else {
                    Button(action: {
                        submitDecision(approved: false)
                    }) {
                        Text("Deny")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: {
                        submitDecision(approved: true)
                    }) {
                        Text("Allow")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.8))
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(Color.orange.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .frame(maxWidth: 500)
    }
    
    private func submitDecision(approved: Bool) {
        withAnimation {
            isProcessingDecision = true
        }
        
        // Call ViewModel to resume execution
        mainAppViewModel.submitToolApproval(conversationID: message.conversationId, approved: approved)
        
        // Optimistic UI Update: clear the card immediately so the user feels responsiveness.
        // The stream will resume and likely clear this anyway via event updates, but this feels snappier.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation {
                message.pendingToolConfirmation = nil
                message.thinkingHeadline = approved ? "Permission granted. Resuming..." : "Permission denied. Reflecting..."
            }
        }
    }
}

// MARK: - Artifact Card (Polymorphic Tool Output)

struct ArtifactCardView: View {
    let artifact: ToolOutput
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    // DYNAMIC ICON based on tool name
                    Image(systemName: iconForTool(artifact.toolName))
                        .foregroundColor(.secondary)
                    
                    Text("Used tool: \(artifact.toolName)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if artifact.isSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                    }
                    
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(10)
                .background(Color.black.opacity(0.2))
            }
            .buttonStyle(.plain)
            
            // Content (Polymorphic)
            if isExpanded {
                Divider()
                
                ScrollView(.vertical) {
                    Text(artifact.output)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
        .background(Color.black.opacity(0.1))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
    
    private func iconForTool(_ name: String) -> String {
        switch name {
        case "list_directory": return "folder.fill"
        case "read_file": return "doc.text.fill"
        case "write_file": return "pencil.circle.fill"
        case "delete_file": return "trash.fill"
        case "execute_shell": return "terminal.fill"
        case "web_search": return "globe"
        case "fs_smart_search": return "magnifyingglass"
        default: return "hammer.fill"
        }
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


// MARK: - Agent Thinking Placeholder View (Updated)
fileprivate struct AgentThinkingView: View {
    // Optional headline passed from the ChatMessage transient state
    var headline: String?
    
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: UITheme.Spacing.small) {
            Image(systemName: "sparkle")
                .font(UITheme.Fonts.callout.weight(.bold))
                .foregroundColor(UITheme.Colors.accent)
                .opacity(isAnimating ? 1.0 : 0.5)
                .animation(Animation.easeInOut(duration: 1).repeatForever(), value: isAnimating)

            // Dynamic Text Update with Animation
            // Uses the passed headline, or falls back to "Thinking..."
            Text(headline ?? "Thinking...")
                .font(UITheme.Fonts.callout)
                .foregroundColor(UITheme.Colors.secondaryText)
                // Smooth transition when text changes (e.g. from "Thinking..." to "Scanning files...")
                .id(headline)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.snappy, value: headline)
        }
        .onAppear {
            self.isAnimating = true
        }
        .frame(height: 22)
    }
}
