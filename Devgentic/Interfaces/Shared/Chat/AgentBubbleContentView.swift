//
//  AgentBubbleContentView.swift
//  Devgentic
//
//  Extracted from ChatBubbleView for decomposition.
//

import SwiftUI

struct AgentBubbleContentView: View {
    var message: ChatMessage
    let isAgentic: Bool
    let contentToDisplay: MessageContent

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(MainApplicationViewModel.self) private var mainAppViewModel
    @Environment(ChatSearchViewModel.self) private var searchViewModel
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(AppSettings.agentViewVariantKey) private var agentViewVariant: AgentViewVariant = .dynamicIsland

    /// Code mode always uses the timeline — its ReAct loops produce many tool calls
    /// that render better as grouped actions than a dynamic island.
    private var effectiveVariant: AgentViewVariant {
        message.profileType == .code ? .timeline : agentViewVariant
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
                // Agent: full ThinkingDynamicIsland with reasoning steps, tool calls, etc.
                // Gate on `timelineEvents` — covers tool calls, warnings, capability milestones,
                // and media, not just text thoughts. A tool-heavy response with no narration
                // should still show its timeline after streaming ends.
                if message.isStreaming || !message.timelineEvents.isEmpty {
                    if effectiveVariant == .timeline {
                        AgentTimelineView(message: message)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    } else {
                        ThinkingDynamicIsland(
                            thoughts: message.thoughts,
                            currentHeadline: message.isStreaming ? message.thinkingHeadline : nil,
                            agentState: message.agentState,
                            isStreaming: message.isStreaming,
                            isExpanded: Bindable(message).isThinkingExpanded
                        )
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                }
            } else if message.isStreaming {
                // Bot: simple "Generating..." indicator while streaming
                SparkleLoadingView(headline: "Generating response...")
            }

            // 2. ARTIFACTS
            if !message.artifacts.isEmpty && effectiveVariant == .dynamicIsland {
                ToolArtifactsRow(artifacts: message.artifacts)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(message.artifacts.count) tool results")
            }

            // [HITL/P6] Live HITL now renders exclusively in the shared above-input
            // InteractionBannerStack — the per-bubble request cards were removed with the
            // ChatMessage.pendingInteraction container.

            // 4. CONTENT
            contentView

            // 5. TERMINAL OUTCOME INDICATOR
            // Surfaces a subtle chip when the run ended in a non-success state
            // (circuit-breaker abort, iteration exhaustion, cancellation). Keeps
            // the bubble honest — user shouldn't mistake best-effort synthesis
            // for an authoritative answer.
            //
            // Skipped when content is already a `.error` card — the card itself
            // communicates the failure with more detail than the chip, and
            // showing both creates a redundant "something went wrong" double-banner.
            if !message.isStreaming,
               let outcome = message.terminalOutcome,
               outcome != .completed,
               !isErrorContent {
                TerminalOutcomeChip(outcome: outcome, reason: message.terminalReason)
            }

            // 6. ACTIONS
            if !message.isStreaming && contentToDisplay.textContent != nil {
                AgentMessageActionsView(message: message, mainAppViewModel: mainAppViewModel)
                    .environment(chatHistoryViewModel)
                    .opacity(0.6)
            }

            // 6. TOKEN USAGE BADGE
            if let usage = message.tokenUsage, !message.isStreaming {
                TokenUsageBadge(usage: usage)
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
                let query = searchViewModel.isSearchActive ? searchViewModel.searchQuery : ""
                let activeLocalIdx = searchViewModel.activeMatchLocalIndex(for: message.id)

                ForEach(blocks) { block in
                    ContentBlockView(
                        block: block,
                        message: message,
                        isLastBlock: block.id == blocks.last?.id,
                        searchQuery: query,
                        activeHighlightIndex: activeLocalIdx
                    )
                    .equatable()
                }
            }

        case .codeBlock(let language, let code):
            if code.components(separatedBy: .newlines).count > ChatUIConstants.codeBlockLineLimit {
                CodeBlockCardView(language: language ?? "code", lineCount: code.components(separatedBy: .newlines).count, fileName: nil) {
                    let snippet = CodeSnippet(language: language, code: code)
                    chatHistoryViewModel.openMessageInCodeViewer(message: message, selectedSnippet: snippet)
                }
            } else {
                CodeBlockView(language: language ?? "code", content: code)
                    .padding(.bottom, theme.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .error(let title, let details, let category, let suggestion):
            VStack(alignment: .leading, spacing: 8) {
                ErrorMessageView(title: title, details: details, category: category, suggestion: suggestion)
                    .cardStyle()

                // P1: Retry button for failed agent responses
                RetryMessageButton {
                    mainAppViewModel.regenerateResponse(for: message)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Error: \(title ?? "Unknown"). \(details)")

        case .image(_, _, let imageData):
            if let data = imageData {
                ImageView(imageData: data)
                    .padding(.vertical, theme.spacingSmall)
                    .frame(maxWidth: 500, alignment: .leading)
                    .accessibilityLabel("Generated image")
            } else {
                ErrorMessageView(title: "Image Not Available", details: "The image data could not be loaded.")
                    .cardStyle()
            }

        case .mediaArtifact(let artifact):
            if artifact.kind == .image {
                MediaArtifactImageView(artifact: artifact)
                    .padding(.vertical, theme.spacingSmall)
                    .accessibilityLabel("Media: \(artifact.label ?? artifact.kind.rawValue)")
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
        }
    }

    // MARK: - Search Highlighting

    private func highlightPlainText(_ text: String) -> AttributedString {
        let query = searchViewModel.isSearchActive ? searchViewModel.searchQuery : ""
        let activeLocalIdx = searchViewModel.activeMatchLocalIndex(for: message.id)
        return Self.highlightText(text, query: query, activeMatchIndex: activeLocalIdx)
    }

    /// Highlights search matches in plain text. Optimized to avoid O(n²) repeated
    /// String.distance calls by tracking character offsets incrementally during the
    /// match-finding pass and applying highlights in a single forward scan.
    ///
    /// Extracted as static for testability and performance benchmarking.
    static func highlightText(_ text: String, query: String, activeMatchIndex: Int? = nil) -> AttributedString {
        var attrString = AttributedString(text)
        guard !query.isEmpty else { return attrString }

        let lowercasedText = text.lowercased()
        let lowercasedQuery = query.lowercased()
        let queryCharCount = lowercasedQuery.count

        // Single-pass: find matches and record character offsets incrementally.
        // Each `distance(from: searchStart, to: range.lowerBound)` is short (gap only),
        // avoiding repeated O(n) `distance(from: startIndex, ...)` calls.
        struct MatchOffset {
            let start: Int
            let end: Int
        }

        var matchOffsets: [MatchOffset] = []
        var searchStart = lowercasedText.startIndex
        var runningOffset = 0

        while searchStart < lowercasedText.endIndex,
              let range = lowercasedText.range(of: lowercasedQuery, range: searchStart..<lowercasedText.endIndex) {
            runningOffset += lowercasedText.distance(from: searchStart, to: range.lowerBound)
            matchOffsets.append(MatchOffset(start: runningOffset, end: runningOffset + queryCharCount))
            searchStart = range.upperBound
            runningOffset += queryCharCount
        }

        guard !matchOffsets.isEmpty else { return attrString }

        // Apply highlights in a single forward pass through the AttributedString.
        // Cursor advances incrementally — each `index(_:offsetByCharacters:)` is O(gap) not O(n).
        var cursor = attrString.startIndex
        var cursorOffset = 0

        for (index, match) in matchOffsets.enumerated() {
            let advanceToStart = match.start - cursorOffset
            if advanceToStart > 0 {
                cursor = attrString.index(cursor, offsetByCharacters: advanceToStart)
                cursorOffset = match.start
            }
            let attrStart = cursor

            let advanceToEnd = match.end - cursorOffset
            cursor = attrString.index(cursor, offsetByCharacters: advanceToEnd)
            cursorOffset = match.end

            let isActiveMatch = (activeMatchIndex == index)
            attrString[attrStart..<cursor].backgroundColor = isActiveMatch
                ? Color.orange.opacity(0.6) // Static context — no theme access
                : Color.yellow.opacity(0.4)
        }

        return attrString
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        if message.isStreaming {
            return "Agent response, generating"
        }
        if let text = contentToDisplay.textContent {
            return "Agent response: \(String(text.prefix(200)))"
        }
        return "Agent response"
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
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var icon: String {
        switch outcome {
        case .failed:    return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch outcome {
        case .failed:    return .orange
        case .cancelled: return .gray
        case .completed: return .green
        }
    }

    private var headline: String {
        switch outcome {
        case .failed:    return "Response may be incomplete — the agent didn't finish cleanly."
        case .cancelled: return "Run stopped by user."
        case .completed: return "Completed."
        }
    }

    private var accessibilityLabel: String {
        reason.map { "\(headline) \($0)" } ?? headline
    }
}
