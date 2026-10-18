// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentBubbleContentView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// How a bubble sits in its group (`TranscriptGrouping`).
enum BubbleGroupStyle: Equatable {
    /// Drawn on its own, with its own action bar.
    case standalone
    /// A human turn's reply with continuations below: the group's action bar is drawn after the
    /// last of them instead of here.
    case head
    /// A report drawn inside the turn above it; `lead` is its stub's words.
    case continuation(lead: String)

    var lead: String? {
        if case .continuation(let lead) = self { return lead }
        return nil
    }
}

struct AgentBubbleContentView: View, Equatable {
    var message: ChatMessage
    let isAgentic: Bool
    let contentToDisplay: MessageContent
    var groupStyle: BubbleGroupStyle = .standalone

    // Why: everything compared here is read by `body`'s conditionals; a new `message.x` read in the body must be added here too,
    // or a settled bubble can miss an update.
    /// Lets a settled bubble skip its body when a parent re-render recreates it (every visible message whenever
    /// `ChatHistoryView.body` re-runs). While either side is streaming, never equal: the view observes streaming state
    /// directly, so equality would buy nothing and risk a stale gate.
    static func == (lhs: AgentBubbleContentView, rhs: AgentBubbleContentView) -> Bool {
        guard !lhs.message.isStreaming, !rhs.message.isStreaming else { return false }
        return lhs.message.id == rhs.message.id
            && lhs.groupStyle == rhs.groupStyle
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

    /// True when the bubble's current content is an `.error` card, which already carries title, details and retry, so the
    /// terminal-outcome chip would duplicate the signal.
    private var isErrorContent: Bool {
        if case .error = contentToDisplay { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingMedium) {

            // 1. INDICATORS
            if isAgentic {
                // Agent timeline (reasoning steps, tool calls, capability cards), gated on `timelineEvents` so a tool-heavy response
                // with no narration still shows it after streaming ends.
                if message.isStreaming || !message.timelineEvents.isEmpty {
                    AgentTimelineView(message: message, continuationLead: groupStyle.lead)
                        // Skip the O(events) grouping rebuild on every streamed token: body re-runs only when the timeline revision,
                        // streaming flag or post-stream final text changes.
                        .equatable()
                        .transition(.opacity)
                } else if let lead = groupStyle.lead {
                    ContinuationLeadRow(lead: lead)
                }
            } else {
                // A bot has no timeline to carry the lead-in, so it gets the plain row.
                if let lead = groupStyle.lead {
                    ContinuationLeadRow(lead: lead)
                }
                if message.isStreaming {
                    // Bot: simple "Generating..." indicator while streaming
                    SparkleLoadingView(headline: "Generating response...")
                }
            }

            // 1b. Interrupted-run badge: a reloaded message whose run never finalized (force-quit or crashed mid-stream or while
            // parked on a HITL). `isStreaming` is false on a reloaded row, so it never shows for a live run.
            if !message.isStreaming, message.lifecycleState.isInterrupted {
                InterruptedRunChip(
                    wasParked: message.lifecycleState.parkedOperationID != nil,
                    onResume: chatActionsSuppressed ? nil : { mainAppViewModel.resumeRun(for: message) },
                    refusal: mainAppViewModel.resumeRefusal(for: message)
                )
            }

            // Live HITL renders only in the shared above-input InteractionBannerStack, not in per-bubble request cards.

            // 4. CONTENT
            contentView

            // 4b. FILES THIS TURN EDITED — Code turns only, once the run is done.
            if TurnFileChanges.showsCard(for: message) {
                TurnFileChangesCard(message: message)
            }

            // 4c. PROJECT MEMORY THIS TURN CHANGED — renders nothing unless it saved or removed one.
            if TurnMemoryChanges.showsCard(for: message) {
                TurnMemoryChangesCard(message: message)
            }

            // 5. Terminal outcome indicator: a subtle chip for a non-success end (circuit-breaker abort, iteration exhaustion),
            // so best-effort synthesis isn't read as authoritative.
            if !message.isStreaming,
               let outcome = message.terminalOutcome,
               outcome != .completed,
               outcome != .cancelled,
               !(contentToDisplay.textContent.map(ChatMessage.isSyntheticPlaceholder) ?? false),
               !isErrorContent {
                TerminalOutcomeChip(outcome: outcome, reason: message.terminalReason)
            }

            // 6. ACTIONS — only a standalone bubble draws its own; a group draws one bar after its
            // last message (`GroupActionBar`).
            if groupStyle == .standalone && !message.isStreaming && contentToDisplay.textContent != nil {
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
                // During streaming: `getOrCreateMarkdownBlocks` caches blocks and only reparses when the text changes;
                // ActiveStreamManager invalidates the cache when content updates.
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

                // A failed run that kept its partial prose (the error card is demoted to the timeline) has no error-card Retry, so
                // show one here; `terminalOutcome` is stamped only at finalize, so this never shows mid-stream.
                if message.terminalOutcome?.isFailureLike == true {
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
                // An identity-bearing announcement key, so VoiceOver speaks a retry that failed the same way instead of suppressing
                // it as a repeat: keyed on the message plus `generationAttempts`, which each Retry increments.
                ErrorMessageView(
                    title: title, details: details, category: category, suggestion: suggestion,
                    announcementKey: "agent-error-\(message.id.uuidString)#\(message.agentResponse?.generationAttempts ?? 1)"
                )

                // Retry button for failed agent responses.
                RetryMessageButton(
                    action: { mainAppViewModel.regenerateResponse(for: message) },
                    refusal: mainAppViewModel.regenerationRefusal(for: message)
                )
            }
            // `.contain`, not `.combine`: combining merged the card and its Retry and the following `.accessibilityLabel`
            // replaced the merged label, hiding the Retry refusal reason and the card's suggestion from VoiceOver.
            .accessibilityElement(children: .contain)

        // There is no `.image` case: MediaArtifact is the single image representation, and legacy persisted "image" messages
        // convert at decode time (data becomes `.ephemeralData`, URL-only becomes `.remoteURL`).
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
            // Shown, and reassuring: the bytes are preserved and this build simply has no renderer, so the wording must not read
            // as if the message was lost. The raw JSON payload is not displayed.
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

/// Shown under a reloaded message whose run never finalized (force-quit or crashed mid-stream or while parked on a
/// HITL). Subdued, like `TerminalOutcomeChip`: it explains why the response looks unfinished without alarming.
/// Distinguishes a run that was waiting on the user (`.parkedHITL`) from one cut off mid-stream.
struct InterruptedRunChip: View {
    /// True when the run died while waiting for the user (a parked HITL) vs cut off mid-stream.
    let wasParked: Bool
    /// [G1 Piece 2] Resume action — present only when the run is parked AND resumable. Nil hides the
    /// Resume button (a mid-stream cut-off run has no clean re-entry point and isn't resumable in v1).
    var onResume: (() -> Void)? = nil
    /// Why Resume is temporarily unavailable, or nil when it may run. Distinct from `onResume == nil`, which means "never
    /// resumable" and hides the button; this is a transient state (a run is live in this conversation) that disables it
    /// with a reason.
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

/// Compact banner under the final response when the agent run didn't complete cleanly. Distinguishes best-effort
/// synthesis (`.failed`: circuit breaker, iteration exhaustion) from a user stop (`.cancelled`). Subdued styling so
/// it informs without alarming.
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
        case .timedOut: return "clock.badge.exclamationmark"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch outcome {
        case .failed, .completedWithWarnings: return .orange
        case .cancelled: return .gray
        case .timedOut: return .orange
        case .completed: return .green
        }
    }

    private var headline: String {
        switch outcome {
        // Degraded success reads the same as the old failed-with-content UX — the answer
        // shipped, but the run stopped early (circuit breaker / iteration budget).
        case .failed, .completedWithWarnings:
            return String(localized: "Response may be incomplete — the agent didn't finish cleanly.")
        // Neutral wording: `.cancelled` covers both an explicit Stop and a system refusal to resume an interrupted run, so
        // the headline must not assert "by user"; the reason line below states which.
        case .cancelled: return String(localized: "Run stopped.")
        // The reason line below states the limit that was hit.
        case .timedOut: return String(localized: "Timed out — the run hit its execution limit.")
        case .completed: return String(localized: "Completed.")
        }
    }

    private var accessibilityLabel: String {
        reason.map { "\(headline) \($0)" } ?? headline
    }
}

/// The "↳ …" lead-in for a continuation with no timeline header to carry it: a bot's report, or a
/// stub whose report has not started yet (its wake is waiting its turn).
struct ContinuationLeadRow: View {
    let lead: String
    var isWaiting: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Text("↳ \(lead)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(theme.secondaryText)
            if isWaiting {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isWaiting ? "\(lead). Report pending." : lead)
    }
}

/// Stands in for reports whose tasks an EARLIER attempt of the turn started — the turn was redone
/// since, so they are not answers to the attempt on screen. Folded, never removed.
struct EarlierAttemptFoldRow: View {
    let count: Int
    let isExpanded: Bool
    let toggle: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Text("↳ \(count) report\(count == 1 ? "" : "s") from an earlier attempt")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide reports from an earlier attempt" : "Show reports from an earlier attempt")
        .accessibilityLabel("\(count) reports from an earlier attempt. " + (isExpanded ? "Hide" : "Show"))
    }
}
