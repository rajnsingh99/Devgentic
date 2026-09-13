// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
            // ⚠️ [mm-10] `profileType == nil` FIRST. `thoughts` is computed and walks
            // `flattenedTimelineEvents`, allocating an array per event; `&&` short-circuits, so
            // written the other way round EVERY bot/workflow/imageGen message paid a full
            // timeline flatten per body pass only to be rejected by the free test that follows.
            // (Agent and code messages were always insulated by the two `||` clauses above.)
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
                    contentToDisplay: contentToDisplay
                )
                // Settled bubbles skip their body when this view is recreated by a parent
                // re-render — see AgentBubbleContentView.==, which never claims equality
                // while streaming.
                .equatable()
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
        // ⚠️ [bm-3] ONE hook on the value, `initial: true` — not an `.onAppear` that only ever
        // turned the floor ON plus an `.onChange` that only handled the FALSE transition.
        // Written that way, the floor engaged solely when a bubble APPEARED already streaming, so
        // a Redo (`beginRegenerationVariant`) or a Resume — both of which set `isStreaming = true`
        // on the SAME, already-mounted `ChatMessage` instance, under a stable view identity — got
        // no floor at all, and the bubble collapsed to one line and re-grew as tokens arrived:
        // precisely the thrash the guard exists to stop, on the two paths most likely to show it.
        //
        // The two curves stay DIFFERENT on purpose — 0.3s easeInOut growing, 0.5s easeIn
        // collapsing — which the obvious one-line rewrite would have flattened into one.
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

// MARK: - Bot: Sparkle Loading View
struct SparkleLoadingView: View {
    var headline: String?
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                // `isActive:` rather than `value:` so Reduce Motion can stop it. A bounce
                // repeating for as long as the agent is loading is the most motion-heavy
                // effect in the chat.
                .symbolEffect(.bounce.up.byLayer, options: .repeating, isActive: isAnimating && !reduceMotion)
                .font(.system(.body, weight: .semibold))
                .foregroundColor(theme.accentColor)

            Text(headline ?? String(localized: "Generating..."))
                .font(theme.fontBody.weight(.medium))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.vertical, 4)
        .onAppear { isAnimating = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline ?? String(localized: "Generating response"))
    }
}

// [HITL/P6] The read-only in-bubble HITL record cards (PermissionRequestView /
// ClarificationRequestView / PlanReviewRequestView) were removed with the
// ChatMessage.pendingInteraction container. Live HITL renders in the shared
// InteractionBannerStack; a persisted in-bubble audit record is a P7 follow-on.

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
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isHovering && !disabled ? theme.surfaceOverlay.opacity(0.8) : Color.clear)
                )
                .contentShape(Capsule())
                .scaleEffect(isHovering && !disabled ? 1.03 : 1.0)
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

                if !chatActionsSuppressed {
                    // Single source for "may this run?" — shared with the runtime refusal in
                    // MessagingCoordinator. This used to hardcode `>= 5` while the coordinator read
                    // `ChatMessage.maxGenerationAttempts`, and neither expressed "a run is already
                    // live in this conversation", so Redo stayed clickable on older messages while
                    // another run streamed — the one-click path to an orphaned, uncancellable run.
                    let redoRefusal = mainAppViewModel.regenerationRefusal(for: message)
                    let isRedoDisabled = redoRefusal != nil
                    ChatActionButton(action: { mainAppViewModel.regenerateResponse(for: message) }, disabled: isRedoDisabled) {
                        Label("Redo", systemImage: "arrow.clockwise")
                    }
                    .foregroundColor(isRedoDisabled ? theme.tertiaryText : theme.secondaryText)
                    .help(redoRefusal?.userFacingReason ?? "Generate a new response")
                    .accessibilityLabel("Regenerate response")
                }

                if containsCode {
                    ChatActionButton(action: { chatHistoryViewModel.openMessageInCodeViewer(message: message) }) {
                        Label("Open in Editor", systemImage: "doc.text.magnifyingglass")
                    }
                    .foregroundColor(theme.secondaryText)
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
                        Label("Report", systemImage: "chart.bar.doc.horizontal")
                    }
                    .foregroundColor(theme.secondaryText)
                    .help("What happened during this run")
                    .accessibilityLabel("Open the run report for this response")
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

        // [sa-4] The `.speechOpenCodeViewer` observer used to live HERE, on the per-message
        // actions row. That row is inside the transcript's `LazyVStack`, so it is released once
        // the message scrolls out of the render window — and Read Aloud keeps going. The reader
        // then announced "Here is the code in the panel view", posted into nothing, and carried
        // on (or, with pause-on-code enabled, parked waiting for a panel that never opened).
        // NotificationCenter does not replay and `pendingCodeBlock` is already cleared by the
        // time the post is made, so the hand-off was simply lost. It now lives on
        // `ChatHistoryView`, which outlives any single row.
    }

    // MARK: - Read Aloud

    private func toggleReadAloud() {
        if isSpeaking {
            speechService.stop()
        } else {
            guard let content = message.currentAgentContent,
                  let text = content.textContent, !text.isEmpty else { return }
            // [CF-21] Tell the session whether a Code Viewer exists here at all. This same view is
            // rendered in the QuickAccess panel, whose view model is built WITHOUT `ownsCodeViewer`
            // — so the code-block hand-off announced "Here is the code in the panel view" and then
            // opened nothing, and with pause-on-code enabled it then held playback waiting for a
            // panel that could never appear. `SpeechService` announces a skip instead when this is
            // false; `canPresentCodeViewer` is the view model's own answer.
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
                            Button(action: { message.agentResponse?.selectedVariantIndex = index; isPresented = false }) {
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
