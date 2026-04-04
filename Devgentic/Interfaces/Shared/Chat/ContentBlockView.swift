//
//  ContentBlockView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/08/25.
//
//  Phase 5: Motion & Polish - Added Blinking Cursor & Text Smoothing.
//  Step 5: Equatable Conformance for High-Performance Memoization.

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ContentBlockView")
private let CODE_BLOCK_LINE_LIMIT = 50

struct ContentBlock: Identifiable, Equatable, Hashable {
    let id: String // e.g., "block-0", "block-1"
    let type: BlockType

    enum BlockType: Equatable, Hashable {
        case paragraph(String)
        case code(language: String, content: String, fileName: String?)
        case heading(level: Int, text: String)
        case listItem(prefix: String, text: String, indentation: Int)
        case horizontalRule
        case table(headers: [String], rows: [[String]])
        case image(url: String, altText: String?)
    }
}

struct ContentBlockView: View, Equatable {
    let block: ContentBlock
    let message: ChatMessage
    var isLastBlock: Bool = false
    var searchQuery: String = ""
    var activeHighlightIndex: Int? = nil

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.appTheme) private var theme

    // MARK: - Equatable Memoization
    // This allows SwiftUI to completely skip re-rendering blocks that haven't changed.
    static func == (lhs: ContentBlockView, rhs: ContentBlockView) -> Bool {
        return lhs.block == rhs.block &&
               lhs.isLastBlock == rhs.isLastBlock &&
               lhs.message.id == rhs.message.id &&
               lhs.message.isStreaming == rhs.message.isStreaming &&
               lhs.searchQuery == rhs.searchQuery &&
               lhs.activeHighlightIndex == rhs.activeHighlightIndex
    }

    var body: some View {
        switch block.type {
        case .paragraph(let text):
            renderTextView(text: text)
                .padding(.bottom, theme.spacingSmall)

        case .code(let lang, let codeContent, let fileName):
            if codeContent.components(separatedBy: .newlines).count > CODE_BLOCK_LINE_LIMIT {
                CodeBlockCardView(language: lang, lineCount: codeContent.components(separatedBy: .newlines).count, fileName: fileName) {
                    let snippet = CodeSnippet(language: lang, code: codeContent)
                    chatHistoryViewModel.openMessageInCodeViewer(message: message, selectedSnippet: snippet)
                }
            } else {
                CodeBlockView(language: lang, content: codeContent)
                    .padding(.bottom, theme.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .heading(let level, let text):
            renderTextView(text: text, font: fontForHeading(level: level), weight: fontWeightForHeading(level: level))
                .padding(.top, theme.spacingMedium)
                .padding(.bottom, theme.spacingXSmall)

        case .listItem(let prefix, let text, let indentation):
            HStack(alignment: .top, spacing: theme.spacingSmall) {
                Text(prefix)
                    .font(themeManager.chatFont)
                    .foregroundColor(theme.secondaryText)
                    .frame(minWidth: 20, alignment: .leading)

                if isPathContent(text) {
                    renderPathListItem(text: text)
                } else {
                    renderTextView(text: text)
                }
            }
            .padding(.leading, CGFloat(indentation * 20))
            .padding(.bottom, theme.spacingXXSmall)

        case .horizontalRule:
            Divider()
                .padding(.vertical, theme.spacingMedium)

        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
                .transaction { $0.animation = nil }

        case .image(let url, let altText):
            if let imageUrl = URL(string: url) {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(theme.cornerRadiusMedium)
                            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium).stroke(theme.dividerColor, lineWidth: 1))
                    case .failure(_):
                        VStack(spacing: theme.spacingXSmall) {
                            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundColor(theme.secondaryText)
                            Text("Failed to load image").font(.caption).foregroundColor(theme.secondaryText)
                        }
                        .frame(maxWidth: 500, minHeight: 150, alignment: .center)
                        .background(theme.controlBackground)
                        .cornerRadius(theme.cornerRadiusMedium)
                    case .empty:
                        HStack {
                            Spacer()
                            VStack {
                                ProgressView()
                                if let alt = altText, !alt.isEmpty { Text(alt).font(.caption).foregroundColor(theme.secondaryText).padding(.top, 4) }
                            }
                            Spacer()
                        }
                        .frame(height: 150)
                        .background(theme.controlBackground)
                        .cornerRadius(theme.cornerRadiusMedium)
                    @unknown default: EmptyView()
                    }
                }
                .padding(.vertical, theme.spacingSmall)
                .frame(maxWidth: 500, alignment: .leading)
            } else { EmptyView() }
        }
    }

    // MARK: - Text Rendering with Motion & Polish

    /// Renders the styled text and optionally adds the blinking cursor if this is the active stream block.
    @ViewBuilder
    private func renderTextView(text: String, font: Font? = nil, weight: Font.Weight = .regular) -> some View {
        let resolvedFont = font ?? themeManager.chatFont
        HStack(alignment: .bottom, spacing: 0) {
            Text(createStyledString(from: text, font: resolvedFont, weight: weight))
                .lineSpacing(themeManager.chatLineSpacing)
                .textSelection(.enabled)
                // Smooth out text updates slightly to avoid harsh token jitter
                .animation(.linear(duration: 0.05), value: text.count)

            // Phase 5: The Blinking Cursor
            if message.isStreaming && isLastBlock {
                BlinkingCursor()
                    .padding(.leading, 2)
                    .padding(.bottom, 4) // Align with baseline
            }
        }
    }

    private func isPathContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Check for common path prefixes or emojis we added in the tool
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("📁") || trimmed.hasPrefix("📄") || trimmed.contains("/")
    }

    @ViewBuilder
    private func renderPathListItem(text: String) -> some View {
        let cleanText = text.replacingOccurrences(of: "📁 ", with: "").replacingOccurrences(of: "📄 ", with: "")
        let isFolder = text.contains("📁") || !cleanText.contains(".")
        
        HStack(spacing: theme.spacingXSmall) {
            Image(systemName: isFolder ? "folder.fill" : "doc.fill")
                .foregroundColor(theme.accentColor)
                .font(.system(size: 11))
            
            renderTextView(text: cleanText)
        }
    }

    private func createStyledString(from text: String, font: Font, weight: Font.Weight) -> AttributedString {
        // Capture theme colors for use inside AttributedString manipulation
        let inlineCodeBg = theme.inlineCodeBackground
        let inlineCodeFg = theme.inlineCodeText
        let textColor = theme.primaryText
        let inlineCodeHighlight = theme.inlineCodeHighlight

        var attributedString: AttributedString
        if let parsed = try? AttributedString(markdown: text) {
            attributedString = parsed
            for run in attributedString.runs {
                let intent = run.inlinePresentationIntent ?? []
                if intent.contains(.code) {
                    attributedString[run.range].backgroundColor = inlineCodeBg
                    attributedString[run.range].foregroundColor = inlineCodeHighlight
                    attributedString[run.range].font = .system(.body, design: .monospaced)
                } else if intent.contains(.stronglyEmphasized) {
                    attributedString[run.range].font = font.weight(.semibold)
                    attributedString[run.range].foregroundColor = textColor
                } else {
                    attributedString[run.range].font = font.weight(weight)
                    attributedString[run.range].foregroundColor = textColor
                }
            }
        } else {
            attributedString = AttributedString(text)
            attributedString.font = font.weight(weight)
            attributedString.foregroundColor = textColor
        }

        // MARK: - Search Highlighting
        if !searchQuery.isEmpty {
            attributedString = applySearchHighlighting(to: attributedString, query: searchQuery)
        }

        return attributedString
    }

    /// Applies yellow/orange background highlighting to all occurrences of the search query.
    private func applySearchHighlighting(to attrString: AttributedString, query: String) -> AttributedString {
        var result = attrString
        let plainText = String(result.characters)
        let lowercasedText = plainText.lowercased()
        let lowercasedQuery = query.lowercased()

        guard !lowercasedQuery.isEmpty else { return result }

        // Find all match ranges in the plain text
        var matchRanges: [Range<String.Index>] = []
        var searchStart = lowercasedText.startIndex
        while searchStart < lowercasedText.endIndex,
              let range = lowercasedText.range(of: lowercasedQuery, range: searchStart..<lowercasedText.endIndex) {
            matchRanges.append(range)
            searchStart = range.upperBound
        }

        // Apply highlighting in reverse to preserve range validity
        let highlightColor = Color.yellow.opacity(0.4)
        let activeHighlightColor = Color.orange.opacity(0.6)

        for (index, range) in matchRanges.enumerated().reversed() {
            // Convert String.Index range to AttributedString range
            let startOffset = plainText.distance(from: plainText.startIndex, to: range.lowerBound)
            let endOffset = plainText.distance(from: plainText.startIndex, to: range.upperBound)
            let attrStart = result.index(result.startIndex, offsetByCharacters: startOffset)
            let attrEnd = result.index(result.startIndex, offsetByCharacters: endOffset)
            let attrRange = attrStart..<attrEnd

            let isActiveMatch = (activeHighlightIndex == index)
            result[attrRange].backgroundColor = isActiveMatch ? activeHighlightColor : highlightColor
        }

        return result
    }

    private func fontForHeading(level: Int) -> Font {
        switch level {
        case 1: return theme.fontTitle1
        case 2: return theme.fontTitle2
        default: return theme.fontTitle3
        }
    }

    private func fontWeightForHeading(level: Int) -> Font.Weight {
        switch level {
        case 1: return .bold
        case 2: return .semibold
        default: return .semibold
        }
    }
}

// MARK: - Blinking Cursor View
struct BlinkingCursor: View {
    @Environment(\.appTheme) private var theme
    @State private var isVisible = true

    var body: some View {
        Rectangle()
            .fill(theme.accentColor)
            .frame(width: 8, height: 16)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(Animation.easeInOut(duration: 0.6).repeatForever()) {
                    isVisible.toggle()
                }
            }
    }
}
