// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentBubbleContentView.swift
//  Devgentic
//
//  Extracted from ChatBubbleView for decomposition.
//

import SwiftUI

struct AgentBubbleContentView: View, Equatable {
    var message: ChatMessage
    let isAgentic: Bool
    let contentToDisplay: MessageContent

    /// Lets a settled bubble skip its body when a PARENT re-render recreates it — which
    /// happens to every visible message whenever `ChatHistoryView.body` re-runs (a scroll
    /// flipping `showScrollToBottom`, a search toggle, the speech island appearing).
    ///
    /// It deliberately does NOT try to help while streaming. This view *observes*
    /// `isStreaming`, `timelineEvents`, `terminalOutcome` and friends, so `@Observable`
    /// invalidates it directly when they change and the body re-runs regardless of what
    /// `==` says. Claiming equality mid-stream would buy nothing and risk a stale gate.
    /// Hence: while either side is streaming, never equal.
    ///
    /// Everything compared below is read by `body`'s conditionals. If you add a
    /// `message.x` read to the body, it belongs here too — otherwise a settled bubble
    /// can miss the update that a parent re-render would have shown.
    static func == (lhs: AgentBubbleContentView, rhs: AgentBubbleContentView) -> Bool {
        guard !lhs.message.isStreaming, !rhs.message.isStreaming else { return false }
        return lhs.message.id == rhs.message.id
            && lhs.isAgentic == rhs.isAgentic
            && lhs.contentToDisplay == rhs.contentToDisplay
            && lhs.message.lifecycleState == rhs.message.lifecycleState
            && lhs.message.terminalOutcome == rhs.message.terminalOutcome
            && lhs.message.terminalReason == rhs.message.terminalReason
            && lhs.message.tokenUsage == rhs.message.tokenUsage
            // Only the emptiness gates the timeline, but the count is just as cheap and
            // catches a post-stream append (a resumed run) that `isEmpty` would miss.
            && lhs.message.timelineEvents.count == rhs.message.timelineEvents.count
    }

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(MainApplicationViewModel.self) private var mainAppViewModel
    @Environment(ChatSearchViewModel.self) private var searchViewModel
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // [QA revival P1c] When set (by the QuickAccess panel), hide Redo/Resume — they target
    // the main window's conversation and no-op on a panel-only message.
    @Environment(\.chatActionsSuppressed) private var chatActionsSuppressed

    /// See `ContentBlockView.codeFontSize` — code tracks `chatFontSize`, a step below prose.
    private var codeFontSize: CGFloat {
        ChatUIConstants.codeFontSize(forChatFontSize: themeManager.chatFontSize)
    }

    /// True when the bubble's current content is an `.error` card. The error
    /// card already carries a full title + details + retry affordance, so the
    /// terminal-outcome warning chip would duplicate the same "something went
    /// wrong" signal and clutter the bubble.
    private var isErrorContent: Bool {
        if case .error = contentToDisplay { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingMedium) {

            // 1. INDICATORS
            if isAgentic {
                // Agent: the timeline, with reasoning steps, tool calls, capability cards.
                // Gate on `timelineEvents` — covers tool calls, warnings, capability milestones,
                // and media, not just text thoughts. A tool-heavy response with no narration
                // should still show its timeline after streaming ends.
                //
                // There used to be a second variant here (ThinkingDynamicIsland) chosen by an
                // `agentViewVariant` setting; it was removed 2026-07-17 and the timeline is now
                // the only agent view. AgentTimelineView renders its own capability cards, so
                // the island's compensating ForEach went with it.
                if message.isStreaming || !message.timelineEvents.isEmpty {
                    AgentTimelineView(message: message)
                        // [TL-4] Skip the O(events) grouping rebuild on every streamed
                        // token — body re-runs only when the timeline revision (or the
                        // streaming flag / post-stream final text) actually changes.
                        .equatable()
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            } else if message.isStreaming {
                // Bot: simple "Generating..." indicator while streaming
                SparkleLoadingView(headline: "Generating response...")
            }

            // 1b. INTERRUPTED-RUN BADGE (G1 Piece 1)
            // A reloaded message whose run never finalized — the app was force-quit or crashed while
            // it was still streaming or parked on a HITL. `isStreaming` is false on a reloaded row, so
            // this shows only post-restart, never for a live run; it pairs with the partial timeline
            // above to explain why the response looks unfinished.
            if !message.isStreaming, message.lifecycleState.isInterrupted {
                InterruptedRunChip(
                    wasParked: message.lifecycleState.parkedOperationID != nil,
                    onResume: chatActionsSuppressed ? nil : { mainAppViewModel.resumeRun(for: message) },
                    refusal: mainAppViewModel.resumeRefusal(for: message)
                )
            }

            // 2. ARTIFACTS — removed with the dynamic island (2026-07-17).
            // `ToolArtifactsRow` was gated on `.dynamicIsland`, so the timeline never showed
            // it; the timeline surfaces tool calls as its own action rows instead. Nothing a
            // timeline user could see has changed.

            // [HITL/P6] Live HITL now renders exclusively in the shared above-input
            // InteractionBannerStack — the per-bubble request cards were removed with the
            // ChatMessage.pendingInteraction container.

            // 4. CONTENT
            contentView

            // 5. TERMINAL OUTCOME INDICATOR
            // Surfaces a subtle chip when the run ended in a non-success state
            // (circuit-breaker abort, iteration exhaustion). Keeps
            // the bubble honest — user shouldn't mistake best-effort synthesis
            // for an authoritative answer.
            //
            // Skipped when cancelled or showing a stopped-run placeholder (the text already explains
            // that the operation was stopped, making a "Run stopped" chip redundant) or when content
            // is already a `.error` card.
            if !message.isStreaming,
               let outcome = message.terminalOutcome,
               outcome != .completed,
               outcome != .cancelled,
               !(contentToDisplay.textContent.map(ChatMessage.isSyntheticPlaceholder) ?? false),
               !isErrorContent {
                TerminalOutcomeChip(outcome: outcome, reason: message.terminalReason)
            }

            // 6. ACTIONS
            if !message.isStreaming && contentToDisplay.textContent != nil {
                AgentMessageActionsView(message: message, mainAppViewModel: mainAppViewModel)
                    .environment(chatHistoryViewModel)
                    .opacity(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Content Rendering

    @ViewBuilder
    private var contentView: some View {
        switch contentToDisplay {
        case .plainText(let text):
            Text(highlightPlainText(text))
                .font(themeManager.chatFont)
                .foregroundColor(theme.primaryText)
                .textSelection(.enabled)
                .lineSpacing(themeManager.chatLineSpacing)
                .accessibilityLabel(text)

        case .markdownText(let text):
            if !text.isEmpty {
                // During streaming: use getOrCreateMarkdownBlocks which caches blocks and only
                // reparses when text changes. Previously called parseMarkdown() on every body
                // evaluation — O(n) per keystroke. Now O(1) when text hasn't changed.
                // The cache is invalidated by ActiveStreamManager when content updates.
                let blocks = message.getOrCreateMarkdownBlocks(from: text)
                let query = searchViewModel.isSearchActive ? searchViewModel.effectiveQuery : ""
                let activeMatch = searchViewModel.activeMatch(in: message.id)

                ForEach(blocks) { block in
                    ContentBlockView(
                        block: block,
                        message: message,
                        isLastBlock: block.id == blocks.last?.id,
                        searchQuery: query,
                        activeMatch: activeMatch
                    )
                    .equatable()
                }

                // [ASM-2] A failed run that KEPT its partial prose (throw after streaming;
                // the error card demoted to the timeline) has no error-card Retry — give
                // the failure the same affordance. `terminalOutcome` is only stamped at
                // finalize, so this never shows mid-stream.
                if message.terminalOutcome == .failed {
                    RetryMessageButton(
                        action: { mainAppViewModel.regenerateResponse(for: message) },
                        refusal: mainAppViewModel.regenerationRefusal(for: message)
                    )
                }
            }

        case .codeBlock(let language, let code):
            if CodeSnippet.isLarge(codeBlockContent: code) {
                CodeBlockCardView(language: language ?? "code", lineCount: CodeSnippet.lineCount(codeBlockContent: code), fileName: nil, content: code) {
                    let snippet = CodeSnippet(codeBlock: language, content: code)
                    chatHistoryViewModel.openMessageInCodeViewer(message: message, selectedSnippet: snippet)
                }
            } else {
                CodeBlockView(language: language ?? "code", content: code, fontSize: codeFontSize)
                    .padding(.bottom, theme.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .error(let title, let details, let category, let suggestion):
            VStack(alignment: .leading, spacing: 8) {
                // [CF-40] An identity-bearing announcement key, so VoiceOver speaks a RETRY that
                // failed the same way instead of suppressing it as a repeat. Keyed on the message
                // plus `generationAttempts`, which `beginRegenerationVariant` increments on every
                // Retry — the same shape `MediaArtifactImageView` uses with its `loadAttempt`.
                // Without it this card falls back to the error SENTENCE, and two identical failures
                // five seconds apart are indistinguishable from the same card being rebuilt.
                ErrorMessageView(
                    title: title, details: details, category: category, suggestion: suggestion,
                    announcementKey: "agent-error-\(message.id.uuidString)#\(message.agentResponse?.generationAttempts ?? 1)"
                )

                // P1: Retry button for failed agent responses
                RetryMessageButton(
                    action: { mainAppViewModel.regenerateResponse(for: message) },
                    refusal: mainAppViewModel.regenerationRefusal(for: message)
                )
            }
            // [CF-42] `.contain`, not `.combine`. `.combine` merged the card and its Retry into
            // ONE element, and the `.accessibilityLabel` that followed then REPLACED the merged
            // label outright — so the two things a screen-reader user needs here never arrived:
            // `RetryMessageButton`'s refusal reason ("This message has reached its limit of 3
            // attempts."), and `ErrorMessageView`'s `suggestion` line. Both children already
            // label themselves correctly, and the ASM-2 Retry above sits under the body's own
            // `.contain` and has always worked; this makes the error path match it. The hand-
            // written label is gone rather than extended: it was a lossy duplicate of
            // `ErrorMessageView.spokenDescription`, free to drift from it.
            .accessibilityElement(children: .contain)

        // NB there is no `.image` case any more (removed 2026-07-17): MediaArtifact is the
        // single image representation. Legacy persisted "image" messages convert at decode
        // time — data becomes an `.ephemeralData` artifact, URL-only becomes `.remoteURL`
        // (whose resolve failure lands in MediaArtifactImageView's error card + Retry).
        case .mediaArtifact(let artifact):
            if artifact.kind == .image {
                MediaArtifactImageView(artifact: artifact)
                    .padding(.vertical, theme.spacingSmall)
            } else {
                Text("[\(artifact.kind.rawValue): \(artifact.label ?? artifact.mimeType)]")
                    .font(theme.fontBody)
                    .foregroundColor(theme.secondaryText)
                    .italic()
            }

        case .checkpoint(let summary):
            VStack(alignment: .leading, spacing: 4) {
                Label("History Checkpoint", systemImage: "archivebox.fill")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(.orange)
                Text(summary)
                    .font(themeManager.chatFont)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .padding(theme.spacingSmall)
            .background(Color.orange.opacity(0.06))
            .cornerRadius(8)

        case .unknown:
            // Shown, and explicitly reassuring. The bytes ARE preserved — this build simply has no
            // renderer — so the wording must not read like the message was lost. The payload is not
            // displayed: it is raw JSON, not something the user wrote.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                Text("This message was written by a newer version of Devgentic and can't be shown here. It hasn't been changed or lost.")
                    .font(themeManager.chatFont)
                    .foregroundColor(theme.secondaryText)
                    .textSelection(.enabled)
            }
            .padding(theme.spacingSmall)
            .background(theme.secondaryBackground.opacity(0.5))
            .cornerRadius(8)
        }
    }

    // MARK: - Search Highlighting

    private func highlightPlainText(_ text: String) -> AttributedString {
        let query = searchViewModel.isSearchActive ? searchViewModel.effectiveQuery : ""
        // `.plainText` renders as ONE Text over the raw string — a single unit, so it carries
        // no block id.
        let activeLocalIdx = searchViewModel.activeMatchIndex(in: message.id, blockID: nil)
        // Live UI path: highlight with the theme's tokens (the static wrapper below
        // is theme-less and only exists for the test suite).
        return SearchHighlighter.highlight(
            text,
            query: query,
            activeMatchIndex: activeLocalIdx,
            base: theme.searchHighlight,
            active: theme.searchHighlightActive
        )
    }

    /// Thin static wrapper over `SearchHighlighter` retained for unit tests and
    /// theme-less benchmarking; uses the default highlight hues.
    static func highlightText(_ text: String, query: String, activeMatchIndex: Int? = nil) -> AttributedString {
        SearchHighlighter.highlight(text, query: query, activeMatchIndex: activeMatchIndex)
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        if message.isStreaming {
            return String(localized: "Agent response, generating")
        }
        if let text = contentToDisplay.textContent {
            return String(localized: "Agent response: \(String(text.prefix(200)))")
        }
        return String(localized: "Agent response")
    }
}

// MARK: - Interrupted Run Chip

/// [G1 Piece 1] Shown under a reloaded message whose run never finalized — the app was force-quit
/// or crashed while it was still streaming or parked on a HITL. Subdued, like `TerminalOutcomeChip`:
/// it explains why the response looks unfinished without alarming. Distinguishes a run that was
/// waiting on the user (`.parkedHITL`) from one cut off mid-stream.
struct InterruptedRunChip: View {
    /// True when the run died while waiting for the user (a parked HITL) vs cut off mid-stream.
    let wasParked: Bool
    /// [G1 Piece 2] Resume action — present only when the run is parked AND resumable. Nil hides the
    /// Resume button (a mid-stream cut-off run has no clean re-entry point and isn't resumable in v1).
    var onResume: (() -> Void)? = nil
    /// Why Resume is temporarily unavailable, or nil when it may run. Distinct from `onResume == nil`
    /// on purpose: that means "never resumable" and HIDES the button, whereas this is a transient
    /// state (a run is live in this conversation) that must DISABLE it with a reason instead — a
    /// button that vanishes and returns reads as a glitch.
    var refusal: RunAdmissionPolicy.Refusal? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: wasParked ? "pause.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.warningColor)
                .frame(width: 16, alignment: .center)

            Text(wasParked
                 ? "Interrupted — this run was waiting for your input when the app closed."
                 : "Interrupted — this response was cut off when the app closed.")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(theme.warningColor.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            // Resume is offered for BOTH interruption types: parked (re-raise the dangling tool) and
            // streaming/mid-compute (drop the dangling tool, continue from completed work).
            if let onResume {
                Button(action: { if refusal == nil { onResume() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.circle.fill")
                        Text("Resume")
                    }
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(refusal == nil ? theme.accentColor : theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .disabled(refusal != nil)
                .help(refusal?.userFacingReason ?? "Resume this interrupted run")
                .accessibilityLabel("Resume interrupted run")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.warningColor.opacity(0.12), theme.warningColor.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.warningColor.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(wasParked ? "Run interrupted while waiting for your input" : "Response interrupted before completion")
    }
}

// MARK: - Terminal Outcome Chip

/// Compact banner shown under the final response when the agent run didn't complete
/// cleanly. Distinguishes best-effort synthesis (`.failed` — circuit breaker / iteration
/// exhaustion) from a user stop (`.cancelled`). Deliberately subdued styling so it
/// informs without alarming — honesty about completion state, not a loud error banner.
struct TerminalOutcomeChip: View {
    let outcome: ExecutionOutcome
    let reason: String?

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(tint.opacity(0.95))

                if let reason, !reason.isEmpty {
                    Text(reason)
                        .font(.system(.caption2))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.12), tint.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var icon: String {
        switch outcome {
        case .failed, .completedWithWarnings: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch outcome {
        case .failed, .completedWithWarnings: return .orange
        case .cancelled: return .gray
        case .completed: return .green
        }
    }

    private var headline: String {
        switch outcome {
        // Degraded success reads the same as the old failed-with-content UX — the answer
        // shipped, but the run stopped early (circuit breaker / iteration budget).
        case .failed, .completedWithWarnings:
            return String(localized: "Response may be incomplete — the agent didn't finish cleanly.")
        // Neutral wording: `.cancelled` covers both an explicit Stop and a system
        // refusal to resume an interrupted run (unresumable profile / provider drift
        // / etc.). The reason line below states which — the headline must not assert
        // "by user" over a reason that says otherwise.
        case .cancelled: return String(localized: "Run stopped.")
        case .completed: return String(localized: "Completed.")
        }
    }

    private var accessibilityLabel: String {
        reason.map { "\(headline) \($0)" } ?? headline
    }
}
