// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatBubbleView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "ChatBubbleView")

struct ChatBubbleView: View {
    var message: ChatMessage
    var groupStyle: BubbleGroupStyle = .standalone
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    /// Read only for a continuation's 'Redo Report'; every surface that draws an agent bubble provides it, and a user bubble
    /// never reads it.
    @Environment(MainApplicationViewModel.self) private var mainAppViewModel
    @Environment(\.chatActionsSuppressed) private var chatActionsSuppressed
    @Environment(\.appTheme) private var theme
    /// [bm-3] The streaming min-height floor animates a frame by up to
    /// `streamingBubbleMinHeight`; snapping that in is exactly the motion this setting suppresses.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // `profileType == nil` is tested first: `thoughts` walks `flattenedTimelineEvents` and allocates, so `&&`
            // short-circuits it for bot/workflow/imageGen messages.
            || (message.profileType == nil && !message.thoughts.isEmpty)
    }

    /// Single-sourced on `ChatMessage`. This was the duplicate `displayedContent`'s own comment
    /// names — search and render must never disagree about WHICH text a message shows, or a
    /// regenerated response is searched in one variant and highlighted in another.
    private var contentToDisplay: MessageContent { message.displayedContent }

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacingMedium) {
            if message.sender == .agent {
                AgentBubbleContentView(
                    message: message,
                    isAgentic: isAgentic,
                    contentToDisplay: contentToDisplay,
                    groupStyle: groupStyle
                )
                // Settled bubbles skip their body when this view is recreated by a parent re-render; see AgentBubbleContentView.==,
                // which never claims equality while streaming.
                .equatable()
                .frame(minHeight: applyMinHeight ? ChatUIConstants.streamingBubbleMinHeight : nil, alignment: .topLeading)
            } else {
                UserBubbleContentView(message: message)
            }
        }
        // A group reads as one turn: its members sit closer together than separate exchanges.
        .padding(.top, groupStyle.lead == nil ? 16 : 4)
        .padding(.bottom, groupStyle == .standalone ? 16 : 6)
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
            // A report in a group has no action bar of its own; this is its Redo. It re-reports
            // from the task's saved output, report-only (`MessagingCoordinator.continueRegeneration`).
            if groupStyle.lead != nil, !chatActionsSuppressed {
                let refusal = mainAppViewModel.regenerationRefusal(for: message)
                Button {
                    mainAppViewModel.regenerateResponse(for: message)
                } label: {
                    Label("Redo Report", systemImage: "arrow.clockwise")
                }
                .disabled(refusal != nil)
                .help(refusal?.userFacingReason ?? String(localized: "Write this report again from the task's saved output"))
            }
        }
        // One hook on the value with `initial: true`, so the floor engages for a Redo or Resume, which set `isStreaming` on an
        // already-mounted `ChatMessage`. The two curves differ on purpose: 0.3s easeInOut growing, 0.5s easeIn collapsing.
        .onChange(of: message.isStreaming, initial: true) { _, streaming in
            let curve: Animation? = reduceMotion
                ? nil
                : (streaming ? .easeInOut(duration: 0.3) : .easeIn(duration: 0.5))
            withAnimation(curve) { applyMinHeight = streaming }
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

// MARK: - Bot: Loading View (Gyroscopic Flux)
struct SparkleLoadingView: View {
    var headline: String?
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            DevgenticActivityIndicator(style: .gyroscope, size: 16, tint: theme.accentColor)

            Text(headline ?? String(localized: "Generating..."))
                .font(theme.fontBody.weight(.medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline ?? String(localized: "Generating response"))
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
            label
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering && !disabled ? theme.surfaceOverlay.opacity(0.8) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .scaleEffect(isHovering && !disabled ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering in 
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { 
                isHovering = hovering 
            } 
        }
    }
}

struct AgentMessageActionsView: View {
    var message: ChatMessage
    /// Set when this is a GROUP's bar (`TranscriptGrouping`): `message` is the human turn's reply,
    /// and these are the reply plus its reports, in order. Copy and Read Aloud then cover the whole
    /// group; every other action still acts for `message` alone.
    var groupMessages: [ChatMessage]? = nil
    var speechService = SpeechService.shared
    var mainAppViewModel: MainApplicationViewModel
    @Environment(ChatHistoryViewModel.self) var chatHistoryViewModel
    @Environment(\.appTheme) private var theme
    // [QA revival P1c] Hide Redo in the QuickAccess panel (it targets the main window).
    @Environment(\.chatActionsSuppressed) private var chatActionsSuppressed
    @State private var didCopy: Bool = false
    @State private var showVariantsPopover: Bool = false
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

    /// A report delivered by a woken background-task run, a turn nobody asked for. Reads `messageSource`, not `sender`: the
    /// report is genuinely `.agent`, and what differs is what caused the turn. See `ChatMessage.messageSource`.
    private var isUnpromptedReport: Bool {
        Self.isUnpromptedReport(source: message.messageSource)
    }

    /// The rule itself, promoted out of the view body so a test exercises the real predicate rather than a transcription.
    /// `.scheduled` is deliberately not included: a scheduled turn answers a question the user wrote, so Redo re-runs
    /// something real.
    static func isUnpromptedReport(source: MessageSource) -> Bool {
        source == .backgroundTask
    }

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: theme.spacingSmall) {
                // `|| isUnpromptedReport`: otherwise a report whose task printed a fenced block loses Copy, since the `containsCode`
                // branch hands its slot to 'Open in Editor', which a report does not get.
                if !containsCode || isUnpromptedReport {
                    ChatActionButton(action: {
                        if let groupText {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(groupText, forType: .string)
                        } else {
                            chatHistoryViewModel.copyMessageContentToClipboard(message: message)
                        }
                        withAnimation(.easeInOut) { didCopy = true }
                        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); withAnimation(.easeInOut) { didCopy = false } }
                    }) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .foregroundColor(didCopy ? theme.successColor : theme.secondaryText)
                    .help(didCopy ? String(localized: "Copied!") : String(localized: "Copy"))
                    .accessibilityLabel(didCopy ? "Copied to clipboard" : "Copy response")
                }

                // Copy is the only action a woken report gets: Redo would re-run the synthetic stub instead of the task output; the
                // variants picker stays outside this trim, since a Retry can add a second version.
                if message.agentResponse?.variants.count ?? 0 > 1 {
                    ChatActionButton(action: { showVariantsPopover.toggle() }) {
                        Image(systemName: "square.3.layers.3d.down.right")
                    }
                    .foregroundColor(theme.secondaryText)
                    .help(String(localized: "\(message.agentResponse?.variants.count ?? 0) Versions"))
                    .accessibilityLabel("\(message.agentResponse?.variants.count ?? 0) response versions available")
                    .popover(isPresented: $showVariantsPopover, arrowEdge: .bottom) {
                        VariantsSelectionView(message: message, isPresented: $showVariantsPopover)
                    }
                }

                if !isUnpromptedReport {

                if !chatActionsSuppressed {
                    // Single source for 'may this run?', shared with the runtime refusal in MessagingCoordinator, so Redo is not clickable
                    // on older messages while another run streams in the conversation.
                    let redoRefusal = mainAppViewModel.regenerationRefusal(for: message)
                    let isRedoDisabled = redoRefusal != nil
                    ChatActionButton(action: { mainAppViewModel.regenerateResponse(for: message) }, disabled: isRedoDisabled) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .foregroundColor(isRedoDisabled ? theme.tertiaryText : theme.secondaryText)
                    .help(redoRefusal?.userFacingReason ?? String(localized: "Redo"))
                    .accessibilityLabel("Regenerate response")
                }

                if containsCode {
                    ChatActionButton(action: { chatHistoryViewModel.openMessageInCodeViewer(message: message) }) {
                        Image(systemName: "doc.text.magnifyingglass")
                    }
                    .foregroundColor(theme.secondaryText)
                    .help(String(localized: "Open in Editor"))
                    .accessibilityLabel("Open code in editor")
                }

                if message.traceID != nil || message.agentResponse != nil {
                    ChatActionButton(action: {
                        ReportInspectorPanelManager.shared.show(
                            messageID: message.id,
                            conversationID: message.conversationId,
                            traceID: message.traceID,
                            theme: theme,
                            isDeveloperMode: isDeveloperMode,
                            // The report's ANSWER row shows the full prose without a
                            // cross-store fetch — the bubble already holds it.
                            answerPreview: message.currentAgentContent?.textContent
                        )
                    }) {
                        // One unified report now — the Trace/Feedback fork is gone.
                        Image(systemName: "chart.bar.doc.horizontal")
                    }
                    .foregroundColor(theme.secondaryText)
                    .help(String(localized: "Report"))
                    .accessibilityLabel("Open the run report for this response")
                }

                // Read Aloud
                ChatActionButton(action: { toggleReadAloud() }) {
                    Image(systemName: isSpeaking ? "stop.fill" : "speaker.wave.2")
                }
                .foregroundColor(isSpeaking ? theme.accentColor : theme.secondaryText)
                .help(isSpeaking ? String(localized: "Stop reading aloud") : String(localized: "Read aloud"))
                .accessibilityLabel(isSpeaking ? "Stop reading aloud" : "Read response aloud")

                }   // end `if !isUnpromptedReport`
            }
            .font(.system(.caption))
            .padding(.top, theme.spacingSmall)
        }

        // The `.speechOpenCodeViewer` observer lives on `ChatHistoryView`, not on this row: rows scrolled out of the
        // `LazyVStack` window are released, and NotificationCenter does not replay a missed hand-off.
    }

    // MARK: - Read Aloud

    /// The group's text, oldest first, or nil for an ordinary bar.
    private var groupText: String? {
        guard let groupMessages else { return nil }
        let parts = groupMessages.compactMap { ($0.currentAgentContent ?? $0.content).textContent }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private func toggleReadAloud() {
        if isSpeaking {
            speechService.stop()
        } else {
            guard let text = groupText ?? message.currentAgentContent?.textContent, !text.isEmpty else { return }
            // Tells the session whether a Code Viewer exists here (QuickAccess renders this view without `ownsCodeViewer`), so
            // `SpeechService` announces a skip instead of opening nothing.
            speechService.speak(text, messageID: message.id,
                                canPresentCodeViewer: chatHistoryViewModel.canPresentCodeViewer)
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
                            Button(action: {
                                message.agentResponse?.selectedVariantIndex = index
                                // Conversation memory follows the chosen version, not the newest one.
                                RAGIndexingService.reindexSelectedVariant(of: message)
                                isPresented = false
                            }) {
                                HStack {
                                    Text(variant.content.textContent ?? String(localized: "Empty Response")).lineLimit(3).font(.body).foregroundColor(theme.primaryText).frame(maxWidth: .infinity, alignment: .leading)
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
