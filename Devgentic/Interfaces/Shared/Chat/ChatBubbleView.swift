//
//  ChatBubbleView.swift
//  Devgentic
//
//  Created by Raj Singh on 29/07/25.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "ChatBubbleView")

struct ChatBubbleView: View {
    var message: ChatMessage
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme

    // MARK: - State
    @State private var applyMinHeight: Bool = false
    @State private var didCopyFeedback: Bool = false
    @State private var feedbackTask: Task<Void, Never>?

    // MARK: - Identity Logic
    /// Uses the persisted profileType (tagged at creation) instead of runtime profile store lookups.
    /// Falls back to checking thoughts for legacy messages without profileType.
    private var isAgentic: Bool {
        message.profileType == .agent
            || message.profileType == .code
            || (!message.thoughts.isEmpty && message.profileType == nil)
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
                AgentBubbleContentView(
                    message: message,
                    isAgentic: isAgentic,
                    contentToDisplay: contentToDisplay
                )
                .frame(minHeight: applyMinHeight ? ChatUIConstants.streamingBubbleMinHeight : nil, alignment: .topLeading)
            } else {
                UserBubbleContentView(message: message)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: message.sender == .agent ? .leading : .trailing)
        .animation(.easeInOut, value: message.agentResponse?.selectedVariantIndex)
        .accessibilityElement(children: .contain)
        // MARK: - Full-Message Copy Context Menu
        .contextMenu {
            if let text = contentToDisplay.textContent, !text.isEmpty {
                Button {
                    copyFullMessage(text)
                } label: {
                    Label(didCopyFeedback ? "Copied!" : "Copy Message", systemImage: didCopyFeedback ? "checkmark" : "doc.on.doc")
                }
            }
        }
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
        .onDisappear {
            feedbackTask?.cancel()
        }
    }

    // MARK: - Full-Message Copy
    private func copyFullMessage(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopyFeedback = true
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopyFeedback = false
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
                .font(.system(.body, weight: .semibold))
                .foregroundColor(theme.accentColor)

            Text(headline ?? "Generating...")
                .font(theme.fontBody.weight(.medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.vertical, 4)
        .onAppear { isAnimating = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline ?? "Generating response")
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
                    .font(.system(.caption2))
                    .foregroundColor(artifact.isSuccess ? theme.secondaryText : theme.warningColor)
                Text(artifact.toolName).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(theme.primaryText) // Fixed size: monospaced
                if !artifact.isSuccess {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8)).foregroundColor(theme.warningColor) // Fixed size: intentional (badge/chip text)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(artifact.isSuccess ? theme.successColor.opacity(0.2) : theme.warningColor.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(artifact.toolName), \(artifact.isSuccess ? "succeeded" : "failed")")
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
                    Text(artifact.output).font(.system(size: 11, design: .monospaced)).padding().frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) // Fixed size: monospaced
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
        case "ask_user": return "person.fill.questionmark"
        default: return "hammer.fill"
        }
    }
}

// MARK: - Permission Request (Read-only history record)
struct PermissionRequestView: View {
    let confirmation: PendingToolConfirmation
    var message: ChatMessage
    @Environment(\.appTheme) private var theme

    private var isResolved: Bool { message.pendingToolConfirmation == nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isResolved ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(.caption))
                .foregroundColor(isResolved ? theme.successColor.opacity(0.7) : theme.warningColor.opacity(0.7))

            Text(confirmation.toolName)
                .font(.system(size: 12, weight: .semibold, design: .monospaced)) // Fixed size: monospaced
                .foregroundColor(theme.secondaryText)

            if !confirmation.params.isEmpty && confirmation.params != "{}" {
                Text(confirmation.params)
                    .font(.system(size: 11, design: .monospaced)) // Fixed size: monospaced
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Text(isResolved ? "Resolved" : "Awaiting...")
                .font(.system(.caption2, weight: .medium))
                .foregroundColor(isResolved ? theme.successColor.opacity(0.7) : theme.warningColor.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(isResolved ? theme.successColor.opacity(0.08) : theme.warningColor.opacity(0.08))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.surfaceOverlay.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isResolved ? theme.successColor.opacity(0.15) : theme.warningColor.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: 500, alignment: .leading)
    }
}

// MARK: - Clarification Request (Read-only history record)
struct ClarificationRequestView: View {
    let clarification: PendingClarification
    var message: ChatMessage
    @Environment(\.appTheme) private var theme

    private var isResolved: Bool { message.pendingClarification == nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isResolved ? "bubble.left.fill" : "questionmark.bubble.fill")
                .font(.system(.caption))
                .foregroundColor(isResolved ? theme.streamingIndicator.opacity(0.7) : theme.streamingIndicator.opacity(0.7))

            Text(clarification.question)
                .font(.system(.caption))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Text(isResolved ? "Answered" : "Awaiting...")
                .font(.system(.caption2, weight: .medium))
                .foregroundColor(isResolved ? theme.streamingIndicator.opacity(0.7) : theme.streamingIndicator.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(theme.streamingIndicator.opacity(0.08))
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.surfaceOverlay.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(theme.streamingIndicator.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: 500, alignment: .leading)
    }
}

// MARK: - Plan Review Request (Read-only history record)
struct PlanReviewRequestView: View {
    let planReview: PendingPlanReview
    var message: ChatMessage
    @Environment(\.appTheme) private var theme

    private var isResolved: Bool { message.pendingPlanReview == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack(spacing: 8) {
                Image(systemName: isResolved ? "checkmark.circle.fill" : "checklist.checked")
                    .font(.system(.caption))
                    .foregroundColor(isResolved ? theme.successColor.opacity(0.7) : theme.streamingIndicator.opacity(0.7))

                Text("Plan: \(planReview.subtasks.count) subtask\(planReview.subtasks.count == 1 ? "" : "s")")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Text(isResolved ? "Approved" : "Awaiting...")
                    .font(.system(.caption2, weight: .medium))
                    .foregroundColor(isResolved ? theme.successColor.opacity(0.7) : theme.streamingIndicator.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isResolved ? theme.successColor.opacity(0.08) : theme.streamingIndicator.opacity(0.08))
                    )
            }

            // Compact subtask list
            ForEach(Array(planReview.subtasks.enumerated()), id: \.element.id) { index, subtask in
                HStack(spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 10, weight: .medium, design: .monospaced)) // Fixed size: monospaced
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 18, alignment: .trailing)

                    Text(subtask.description)
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.surfaceOverlay.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isResolved ? theme.successColor.opacity(0.15) : theme.streamingIndicator.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: 500, alignment: .leading)
    }
}

// MARK: - Helpers
struct ChatActionButton<LabelContent: View>: View {
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

struct AgentMessageActionsView: View {
    var message: ChatMessage
    var speechService = SpeechService.shared
    var mainAppViewModel: MainApplicationViewModel
    @Environment(ChatHistoryViewModel.self) var chatHistoryViewModel
    @Environment(\.appTheme) private var theme
    @State private var didCopy: Bool = false
    @State private var showVariantsPopover: Bool = false
    @State private var showReportInspector: Bool = false
    @AppStorage(AppSettings.developerModeKey) private var isDeveloperMode: Bool = false

    /// Whether this specific message is currently being read aloud.
    private var isSpeaking: Bool {
        speechService.isActive && speechService.currentMessageID == message.id
    }

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
                    ChatActionButton(action: {
                        chatHistoryViewModel.copyMessageContentToClipboard(message: message)
                        withAnimation(.easeInOut) { didCopy = true }
                        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); withAnimation(.easeInOut) { didCopy = false } }
                    }) {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .foregroundColor(didCopy ? theme.successColor : theme.secondaryText)
                    .accessibilityLabel(didCopy ? "Copied to clipboard" : "Copy response")
                }

                if message.agentResponse?.variants.count ?? 0 > 1 {
                    ChatActionButton(action: { showVariantsPopover.toggle() }) {
                        Label("\(message.agentResponse?.variants.count ?? 0) Versions", systemImage: "square.3.layers.3d.down.right")
                    }
                    .foregroundColor(theme.secondaryText)
                    .accessibilityLabel("\(message.agentResponse?.variants.count ?? 0) response versions available")
                    .popover(isPresented: $showVariantsPopover, arrowEdge: .bottom) {
                        VariantsSelectionView(message: message, isPresented: $showVariantsPopover)
                    }
                }

                let isRedoDisabled = (message.agentResponse?.generationAttempts ?? 0) >= 5
                ChatActionButton(action: { mainAppViewModel.regenerateResponse(for: message) }, disabled: isRedoDisabled) {
                    Label("Redo", systemImage: "arrow.clockwise")
                }
                .foregroundColor(isRedoDisabled ? theme.tertiaryText : theme.secondaryText)
                .accessibilityLabel("Regenerate response")

                if containsCode {
                    ChatActionButton(action: { chatHistoryViewModel.openMessageInCodeViewer(message: message) }) {
                        Label("Open in Editor", systemImage: "doc.text.magnifyingglass")
                    }
                    .foregroundColor(theme.secondaryText)
                    .accessibilityLabel("Open code in editor")
                }

                if message.traceID != nil || message.agentResponse != nil {
                    ChatActionButton(action: { showReportInspector = true }) {
                        Label(
                            isDeveloperMode ? "Trace" : "Feedback",
                            systemImage: isDeveloperMode ? "chart.bar.doc.horizontal" : "bubble.left.and.exclamationmark.bubble.right"
                        )
                    }
                    .foregroundColor(theme.secondaryText)
                    .help(isDeveloperMode ? "View Execution Trace" : "Share Feedback")
                    .accessibilityLabel(isDeveloperMode ? "View execution trace" : "Share feedback on this response")
                }

                // Read Aloud
                ChatActionButton(action: { toggleReadAloud() }) {
                    Label(isSpeaking ? "Stop" : "Read Aloud", systemImage: isSpeaking ? "stop.fill" : "speaker.wave.2")
                }
                .foregroundColor(isSpeaking ? theme.accentColor : theme.secondaryText)
                .accessibilityLabel(isSpeaking ? "Stop reading aloud" : "Read response aloud")
            }
            .font(.system(.caption))
            .padding(.top, theme.spacingSmall)
        }
        .sheet(isPresented: $showReportInspector) {
            ReportInspectorView(
                messageID: message.id,
                conversationID: message.conversationId,
                traceID: message.traceID
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .speechOpenCodeViewer)) { notification in
            guard let messageID = notification.object as? UUID, messageID == message.id,
                  let userInfo = notification.userInfo,
                  let code = userInfo["code"] as? String else { return }

            let language = userInfo["language"] as? String
            chatHistoryViewModel.showCodeInViewer(language: language, code: code)
        }
    }

    // MARK: - Read Aloud

    private func toggleReadAloud() {
        if isSpeaking {
            speechService.stop()
        } else {
            guard let content = message.currentAgentContent,
                  let text = content.textContent, !text.isEmpty else { return }
            speechService.speak(text, messageID: message.id)
        }
    }
}

struct VariantsSelectionView: View {
    var message: ChatMessage
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
                            .accessibilityLabel("Version \(index + 1)\(index == agentResponse.selectedVariantIndex ? ", selected" : "")")
                            if index < agentResponse.variants.count - 1 { Divider() }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 400, maxWidth: 500, minHeight: 200, idealHeight: 300, maxHeight: 400)
    }
}
