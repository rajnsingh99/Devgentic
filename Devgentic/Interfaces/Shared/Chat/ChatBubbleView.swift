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
    @Environment(\.appTheme) private var theme

    // MARK: - State to control the animation
    @State private var applyMinHeight: Bool = false

    // MARK: - Identity Logic
    private var isAgentic: Bool {
        if !message.thoughts.isEmpty { return true }

        if let response = message.agentResponse,
           let variant = response.variants.indices.contains(response.selectedVariantIndex) ? response.variants[response.selectedVariantIndex] : nil,
           let entityId = variant.backendEntityId {

            let profiles = BackendProfileStore.shared.fetchProfiles()
            if let profile = profiles.first(where: { $0.id == entityId }) {
                return profile.profileType == .agent
            }
        }
        return false
    }

    private var contentToDisplay: MessageContent {
        if message.sender == .agent, let content = message.currentAgentContent {
            return content
        }
        return message.content
    }

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacingMedium) {
            if message.sender == .agent {
                VStack(alignment: .leading, spacing: theme.spacingMedium) {

                    // 1. INDICATORS
                    if message.isStreaming {
                        if isAgentic {
                            ThinkingDynamicIsland(
                                thoughts: message.thoughts,
                                currentHeadline: message.thinkingHeadline,
                                isStreaming: message.isStreaming,
                                isExpanded: $message.isThinkingExpanded
                            )
                        } else {
                            if message.content.textContent?.isEmpty ?? true {
                                SparkleLoadingView(headline: message.thinkingHeadline)
                            }
                        }
                    } else if !message.thoughts.isEmpty {
                        ThinkingDynamicIsland(
                            thoughts: message.thoughts,
                            currentHeadline: nil,
                            isStreaming: false,
                            isExpanded: $message.isThinkingExpanded
                        )
                    }

                    // 2. ARTIFACTS
                    if !message.artifacts.isEmpty {
                        ToolArtifactsRow(artifacts: message.artifacts)
                            .padding(.bottom, 8)
                    }

                    // 3. HITL
                    if let confirmation = message.pendingToolConfirmation {
                        PermissionRequestView(confirmation: confirmation, message: message)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // 3b. CLARIFICATION
                    if let clarification = message.pendingClarification {
                        ClarificationRequestView(clarification: clarification, message: message)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // 4. CONTENT
                    switch contentToDisplay {
                    case .plainText(let text):
                        Text(text)
                            .font(theme.fontBody)
                            .foregroundColor(theme.primaryText)
                            .textSelection(.enabled)
                            .lineSpacing(4)

                    case .markdownText(let text):
                        if !text.isEmpty {
                            let blocks = message.isStreaming ? parseMarkdown(text) : message.getOrCreateMarkdownBlocks(from: text)

                            // Phase 5: Pass isLastBlock for Cursor Placement & Use stable IDs
                            ForEach(blocks) { block in
                                ContentBlockView(
                                    block: block,
                                    message: message,
                                    isLastBlock: block.id == blocks.last?.id
                                )
                                .equatable() // Explicitly enforce equatable checking for memoization
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
                                .padding(.bottom, theme.spacingMedium)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                    case .error(let title, let details):
                        ErrorMessageView(title: title, details: details)
                            .cardStyle()

                    case .image(_, _, let imageData):
                        if let data = imageData {
                            ImageView(imageData: data)
                                .padding(.vertical, theme.spacingSmall)
                                .frame(maxWidth: 500, alignment: .leading)
                        } else {
                            ErrorMessageView(title: "Image Not Available", details: "The image data could not be loaded.")
                                .cardStyle()
                        }
                    }

                    if !message.isStreaming && contentToDisplay.textContent != nil {
                        AgentMessageActionsView(message: message, mainAppViewModel: mainAppViewModel)
                            .environmentObject(chatHistoryViewModel)
                            .opacity(0.6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: applyMinHeight ? STREAMING_BUBBLE_MIN_HEIGHT : nil, alignment: .topLeading)

            } else { // User
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
                        }

                        if let textContent = message.content.textContent, !textContent.isEmpty {
                            UserMessageView(text: textContent)
                                .userBubbleStyle()
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 600, alignment: .trailing)

                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(theme.secondaryText.opacity(0.4))
                        .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 16)
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

// MARK: - Bot: Sparkle Loading View
struct SparkleLoadingView: View {
    var headline: String?
    @Environment(\.appTheme) private var theme
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .symbolEffect(.bounce.up.byLayer, options: .repeating, value: isAnimating)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.accentColor)

            Text(headline ?? "Generating...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.vertical, 4)
        .onAppear { isAnimating = true }
    }
}

// MARK: - Agent: Tool Artifacts
struct ToolArtifactsRow: View {
    let artifacts: [ToolOutput]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(artifacts) { artifact in
                    ToolChipView(artifact: artifact)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 1)
        }
    }
}

struct ToolChipView: View {
    let artifact: ToolOutput
    @Environment(\.appTheme) private var theme
    @State private var showPopover: Bool = false

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: iconForTool(artifact.toolName))
                    .font(.system(size: 10))
                    .foregroundColor(artifact.isSuccess ? theme.secondaryText : theme.warningColor)
                Text(artifact.toolName).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(theme.primaryText)
                if !artifact.isSuccess {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundColor(theme.warningColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.surfaceOverlay)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(artifact.isSuccess ? theme.successColor.opacity(0.2) : theme.warningColor.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Tool Output: \(artifact.toolName)").font(.headline)
                    Spacer()
                    if artifact.isSuccess { Label("Success", systemImage: "checkmark.circle.fill").foregroundColor(theme.successColor) }
                    else { Label("Failed", systemImage: "xmark.circle.fill").foregroundColor(theme.warningColor) }
                }
                .padding()
                .background(theme.controlBackground)
                Divider()
                ScrollView {
                    Text(artifact.output).font(.system(size: 11, design: .monospaced)).padding().frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
            .frame(width: 400, height: 300)
        }
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

// MARK: - Permission Request
struct PermissionRequestView: View {
    let confirmation: PendingToolConfirmation
    @ObservedObject var message: ChatMessage
    @EnvironmentObject var mainAppViewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme
    @State private var isProcessingDecision = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundColor(theme.warningColor).font(.system(size: 14))
                Text("Permission Required").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.primaryText)
                Spacer()
            }
            Divider().background(theme.dividerColor)
            VStack(alignment: .leading, spacing: 6) {
                Text("The agent wants to execute a sensitive action:").font(.caption).foregroundColor(theme.secondaryText)
                HStack(spacing: 6) {
                    Text(confirmation.toolName).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(theme.primaryText).padding(.horizontal, 6).padding(.vertical, 2).background(theme.surfaceOverlay).cornerRadius(4)
                }
                if !confirmation.params.isEmpty && confirmation.params != "{}" {
                    Text(confirmation.params).font(.system(size: 11, design: .monospaced)).foregroundColor(theme.secondaryText).lineLimit(4).padding(8).background(theme.surfaceOverlayStrong).cornerRadius(6).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 12) {
                if isProcessingDecision { ProgressView().scaleEffect(0.6).frame(height: 28) }
                else {
                    Button(action: { submitDecision(approved: false) }) { Text("Deny").font(.system(size: 12, weight: .medium)).foregroundColor(.white).padding(.horizontal, 16).padding(.vertical, 6).background(theme.errorColor.opacity(0.8)).cornerRadius(6) }.buttonStyle(.plain)
                    Button(action: { submitDecision(approved: true) }) { Text("Allow").font(.system(size: 12, weight: .medium)).foregroundColor(.white).padding(.horizontal, 16).padding(.vertical, 6).background(theme.successColor.opacity(0.8)).cornerRadius(6) }.buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
        .padding(12).background(theme.warningColor.opacity(0.08)).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.warningColor.opacity(0.2), lineWidth: 1)).frame(maxWidth: 500)
    }

    private func submitDecision(approved: Bool) {
        withAnimation { isProcessingDecision = true }
        mainAppViewModel.submitToolApproval(conversationID: message.conversationId, approved: approved)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation {
                message.pendingToolConfirmation = nil
                message.thinkingHeadline = approved ? "Permission granted. Resuming..." : "Permission denied. Reflecting..."
            }
        }
    }
}


// MARK: - Clarification Request
struct ClarificationRequestView: View {
    let clarification: PendingClarification
    @ObservedObject var message: ChatMessage
    @EnvironmentObject var mainAppViewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme
    @State private var userInput: String = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "questionmark.bubble.fill").foregroundColor(theme.streamingIndicator).font(.system(size: 14))
                Text("Clarification Needed").font(.system(size: 13, weight: .semibold)).foregroundColor(theme.primaryText)
                Spacer()
            }
            Divider().background(theme.dividerColor)
            Text(clarification.question)
                .font(.system(size: 13))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Type your response...", text: $userInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit { submitResponse() }
            HStack(spacing: 12) {
                if isSubmitting { ProgressView().scaleEffect(0.6).frame(height: 28) }
                else {
                    Button(action: { submitSkip() }) {
                        Text("Skip").font(.system(size: 12, weight: .medium)).foregroundColor(.white).padding(.horizontal, 16).padding(.vertical, 6).background(theme.secondaryText.opacity(0.6)).cornerRadius(6)
                    }.buttonStyle(.plain)
                    Button(action: { submitResponse() }) {
                        Text("Send").font(.system(size: 12, weight: .medium)).foregroundColor(.white).padding(.horizontal, 16).padding(.vertical, 6).background(theme.streamingIndicator.opacity(0.8)).cornerRadius(6)
                    }.buttonStyle(.plain).disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 4)
        }
        .padding(12).background(theme.streamingIndicator.opacity(0.08)).cornerRadius(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.streamingIndicator.opacity(0.2), lineWidth: 1)).frame(maxWidth: 500)
    }

    private func submitResponse() {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation { isSubmitting = true }
        mainAppViewModel.submitClarificationResponse(conversationID: message.conversationId, response: trimmed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation {
                message.pendingClarification = nil
                message.thinkingHeadline = "Received your input. Resuming..."
            }
        }
    }

    private func submitSkip() {
        withAnimation { isSubmitting = true }
        mainAppViewModel.submitClarificationResponse(conversationID: message.conversationId, response: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation {
                message.pendingClarification = nil
                message.thinkingHeadline = "Skipped clarification. Continuing..."
            }
        }
    }
}

// MARK: - Helpers
fileprivate struct ActionButton<LabelContent: View>: View {
    let action: () -> Void
    @ViewBuilder let label: LabelContent
    var disabled: Bool = false
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label.padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 8).fill(isHovering && !disabled ? theme.secondaryText.opacity(0.3) : Color.clear))
        }
        .buttonStyle(.plain).disabled(disabled).onHover { hovering in withAnimation(.easeInOut(duration: 0.2)) { isHovering = hovering } }
    }
}

fileprivate struct AgentMessageActionsView: View {
    @ObservedObject var message: ChatMessage
    var mainAppViewModel: MainApplicationViewModel
    @EnvironmentObject var chatHistoryViewModel: ChatHistoryViewModel
    @Environment(\.appTheme) private var theme
    @State private var didCopy: Bool = false
    @State private var showVariantsPopover: Bool = false

    private var containsCode: Bool {
        guard let content = message.currentAgentContent else { return false }
        switch content {
        case .codeBlock: return true
        case .markdownText(let text): return text.contains("```")
        default: return false
        }
    }

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: theme.spacingSmall) {
                if !containsCode {
                    ActionButton(action: {
                        chatHistoryViewModel.copyMessageContentToClipboard(message: message)
                        withAnimation(.easeInOut) { didCopy = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation(.easeInOut) { didCopy = false } }
                    }) {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .foregroundColor(didCopy ? theme.successColor : theme.secondaryText)
                }

                if message.agentResponse?.variants.count ?? 0 > 1 {
                    ActionButton(action: { showVariantsPopover.toggle() }) {
                        Label("\(message.agentResponse?.variants.count ?? 0) Versions", systemImage: "square.3.layers.3d.down.right")
                    }
                    .foregroundColor(theme.secondaryText)
                    .popover(isPresented: $showVariantsPopover, arrowEdge: .bottom) {
                        VariantsSelectionView(message: message, isPresented: $showVariantsPopover)
                    }
                }

                let isRedoDisabled = (message.agentResponse?.generationAttempts ?? 0) >= 5
                ActionButton(action: { mainAppViewModel.regenerateResponse(for: message) }, disabled: isRedoDisabled) {
                    Label("Redo", systemImage: "arrow.clockwise")
                }
                .foregroundColor(isRedoDisabled ? theme.tertiaryText : theme.secondaryText)

                if containsCode {
                    ActionButton(action: { chatHistoryViewModel.openMessageInCodeViewer(message: message) }) {
                        Label("Open in Editor", systemImage: "doc.text.magnifyingglass")
                    }
                    .foregroundColor(theme.secondaryText)
                }
            }
            .font(.system(size: 12))
            .padding(.top, theme.spacingSmall)
        }
    }
}

fileprivate struct VariantsSelectionView: View {
    @ObservedObject var message: ChatMessage
    @Binding var isPresented: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Response Versions").font(.headline).padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let agentResponse = message.agentResponse {
                        ForEach(Array(zip(agentResponse.variants.indices, agentResponse.variants)), id: \.0) { index, variant in
                            Button(action: { message.agentResponse?.selectedVariantIndex = index; isPresented = false }) {
                                HStack {
                                    Text(variant.content.textContent ?? "Empty Response").lineLimit(3).font(.body).foregroundColor(theme.primaryText).frame(maxWidth: .infinity, alignment: .leading)
                                    Spacer()
                                    if index == agentResponse.selectedVariantIndex { Image(systemName: "checkmark.circle.fill").foregroundColor(theme.accentColor) }
                                }
                                .padding().background(index == agentResponse.selectedVariantIndex ? theme.accentColor.opacity(0.08) : Color.clear)
                            }
                            .buttonStyle(.plain)
                            if index < agentResponse.variants.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 400, maxWidth: 500, minHeight: 200, idealHeight: 300, maxHeight: 400)
    }
}
