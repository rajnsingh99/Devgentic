//
//  AgentBubbleContentView.swift
//  Devgentic
//
//  Extracted from ChatBubbleView for decomposition.
//

import SwiftUI

private let CODE_BLOCK_LINE_LIMIT = 50

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

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingMedium) {

            // 1. INDICATORS
            if isAgentic {
                // Agent: full ThinkingDynamicIsland with reasoning steps, tool calls, etc.
                if message.isStreaming || !message.thoughts.isEmpty {
                    if agentViewVariant == .timeline {
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
            if !message.artifacts.isEmpty && agentViewVariant == .dynamicIsland {
                ToolArtifactsRow(artifacts: message.artifacts)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(message.artifacts.count) tool results")
            }

            // 3. HITL Interaction (unified)
            if let interaction = message.pendingInteraction {
                Group {
                    switch interaction {
                    case .toolConfirmation(let confirmation):
                        PermissionRequestView(confirmation: confirmation, message: message)
                            .accessibilityLabel("Permission request for \(confirmation.toolName)")
                    case .clarification(let clarification):
                        ClarificationRequestView(clarification: clarification, message: message)
                            .accessibilityLabel("Clarification: \(clarification.question)")
                    case .planReview(let planReview):
                        PlanReviewRequestView(planReview: planReview, message: message)
                            .accessibilityLabel("Plan review with \(planReview.subtasks.count) subtasks")
                    }
                }
                .padding(.bottom, 8)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
            }

            // 4. CONTENT
            contentView

            // 5. ACTIONS
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
            VStack(alignment: .leading, spacing: 8) {
                ErrorMessageView(title: title, details: details)
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
