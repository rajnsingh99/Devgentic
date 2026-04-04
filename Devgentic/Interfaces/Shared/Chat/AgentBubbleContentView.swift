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
    @EnvironmentObject private var searchViewModel: ChatSearchViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.appTheme) private var theme

    @AppStorage(AppSettings.agentViewVariantKey) private var agentViewVariant: AgentViewVariant = .dynamicIsland

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingMedium) {

            // 1. INDICATORS
            if message.isStreaming || !message.thoughts.isEmpty {
                if isAgentic {
                    if agentViewVariant == .timeline {
                        AgentTimelineView(message: message)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        ThinkingDynamicIsland(
                            thoughts: message.thoughts,
                            currentHeadline: message.isStreaming ? message.thinkingHeadline : nil,
                            agentState: message.agentState,
                            isStreaming: message.isStreaming,
                            isExpanded: Bindable(message).isThinkingExpanded
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                } else if message.isStreaming {
                    if message.content.textContent?.isEmpty ?? true {
                        SparkleLoadingView(headline: message.thinkingHeadline)
                    }
                }
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
                .transition(.opacity.combined(with: .move(edge: .top)))
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
                let blocks = message.isStreaming ? parseMarkdown(text) : message.getOrCreateMarkdownBlocks(from: text)
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
        }
    }

    // MARK: - Search Highlighting

    private func highlightPlainText(_ text: String) -> AttributedString {
        var attrString = AttributedString(text)
        let query = searchViewModel.isSearchActive ? searchViewModel.searchQuery : ""
        guard !query.isEmpty else { return attrString }

        let lowercasedText = text.lowercased()
        let lowercasedQuery = query.lowercased()
        let activeLocalIdx = searchViewModel.activeMatchLocalIndex(for: message.id)

        var matchRanges: [Range<String.Index>] = []
        var searchStart = lowercasedText.startIndex
        while searchStart < lowercasedText.endIndex,
              let range = lowercasedText.range(of: lowercasedQuery, range: searchStart..<lowercasedText.endIndex) {
            matchRanges.append(range)
            searchStart = range.upperBound
        }

        for (index, range) in matchRanges.enumerated().reversed() {
            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let endOffset = text.distance(from: text.startIndex, to: range.upperBound)
            let attrStart = attrString.index(attrString.startIndex, offsetByCharacters: startOffset)
            let attrEnd = attrString.index(attrString.startIndex, offsetByCharacters: endOffset)
            let attrRange = attrStart..<attrEnd

            let isActiveMatch = (activeLocalIdx == index)
            attrString[attrRange].backgroundColor = isActiveMatch ? Color.orange.opacity(0.6) : Color.yellow.opacity(0.4)
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
