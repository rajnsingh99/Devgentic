// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    var groupStyle: BubbleGroupStyle = .standalone
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    /// ⚠️ Read ONLY for a continuation's "Redo Report" — every surface that draws an agent bubble
    /// provides it (`AgentBubbleContentView` requires it), and a user bubble never reads it.
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
                    contentToDisplay: contentToDisplay,
                    groupStyle: groupStyle
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

    /// A report delivered by a woken background-task run — a turn nobody asked for.
    ///
    /// ⚠️ Reads `messageSource`, NOT `sender`. The report is genuinely `.agent`: the agent wrote
    /// it, from this conversation's own profile, through the same executor. What differs is what
    /// CAUSED the turn, and collapsing the two questions into one enum was considered and
    /// rejected — `sender` is compared at ~30 sites, almost all `if`/ternary, and Swift enforces
    /// exhaustiveness only on `switch`, so a third role would have landed silently in the wrong
    /// branch here (right-aligned like a user bubble, per `ChatBubbleView.body`) with no compile
    /// error. See `ChatMessage.messageSource`.
    private var isUnpromptedReport: Bool {
        Self.isUnpromptedReport(source: message.messageSource)
    }

    /// The rule itself, promoted out of the view body.
    ///
    /// ⚠️ A `private var` inside a SwiftUI `View` cannot be exercised without rendering, so a test
    /// would have to TRANSCRIBE the condition — and a transcribed predicate stays green when the
    /// production one is neutered. `BackgroundTasksFloatingButton.shouldShow` was promoted for
    /// exactly this reason; this follows it so there is one pattern.
    ///
    /// ⚠️ `.scheduled` is deliberately NOT included, though it is also an unattended run. A
    /// scheduled turn answers a question the user WROTE when they set the task up, so Redo re-runs
    /// something real; a woken report's preceding "question" is a machine-written stub. Folding
    /// the two together would remove Redo from scheduled runs for no reason.
    static func isUnpromptedReport(source: MessageSource) -> Bool {
        source == .backgroundTask
    }

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: theme.spacingSmall) {
                // ⚠️ `|| isUnpromptedReport` — otherwise a report whose task printed a fenced
                // block loses Copy entirely, because the `containsCode` branch below hands its
                // slot to "Open in Editor", which a report does not get.
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

                // ⚠️⚠️ COPY IS THE ONLY ACTION A WOKEN REPORT GETS, and the reason is Redo.
                // `regenerateResponse` re-runs the USER MESSAGE that precedes this one — which,
                // for a report, is the synthetic stub a background task wrote. Pressing it would
                // re-ask the model to report on a task using a one-line stub in place of the
                // output (that lived in `promptOverride` and was never persisted), producing a
                // confident answer about nothing. It is not that Redo is unhelpful here; it is
                // that Redo is WRONG here, and a wrong button that looks live is worse than an
                // absent one.
                //
                // The rest follow it for weaker but real reasons: there are no variants to pick
                // between on a single unprompted turn, and Read Aloud on a turn the user did not
                // ask for is a machine talking unbidden.
                //
                // ⚠️ The trace Report goes too, and that one is a genuine LOSS — a woken run is
                // unattended and therefore among the hardest to debug, and its `traceID` is real.
                // It was dropped to match the agreed design; restoring it is this `if` plus
                // nothing else, and the trace itself is untouched either way.
                // ⚠️ Versions sit OUTSIDE the report trim. A report has one version until a Retry
                // (its failure card) redoes it — and then hiding the picker would hide the first one.
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
                    // Single source for "may this run?" — shared with the runtime refusal in
                    // MessagingCoordinator. This used to hardcode `>= 5` while the coordinator read
                    // `ChatMessage.maxGenerationAttempts`, and neither expressed "a run is already
                    // live in this conversation", so Redo stayed clickable on older messages while
                    // another run streamed — the one-click path to an orphaned, uncancellable run.
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
