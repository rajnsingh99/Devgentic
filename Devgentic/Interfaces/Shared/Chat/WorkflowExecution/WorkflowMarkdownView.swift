//
//  WorkflowMarkdownView.swift
//  Devgentic
//
//  Created by Raj Singh on 12/04/26.
//
//  Standalone markdown renderer for workflow output areas.
//  Reuses the shared `parseMarkdown()` pipeline and renders ContentBlock types
//  without requiring a ChatMessage. Supports paragraphs, headings, code blocks,
//  lists, tables, horizontal rules, and images — matching the chat appearance.
//

import SwiftUI

struct WorkflowMarkdownView: View {
    let text: String
    @Environment(\.appTheme) private var theme
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        let blocks = parseMarkdown(text)

        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                renderBlock(block)
            }
        }
    }

    // MARK: - Block Rendering

    @ViewBuilder
    private func renderBlock(_ block: ContentBlock) -> some View {
        switch block.type {
        case .paragraph(let text):
            renderText(text)
                .padding(.bottom, theme.spacingSmall)

        case .code(let lang, let codeContent, _):
            CodeBlockView(language: lang, content: codeContent)
                .padding(.bottom, theme.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let text):
            renderText(text, font: fontForHeading(level: level), weight: fontWeightForHeading(level: level))
                .padding(.top, theme.spacingMedium)
                .padding(.bottom, theme.spacingXSmall)

        case .listItem(let prefix, let text, let indentation):
            HStack(alignment: .top, spacing: theme.spacingSmall) {
                Text(prefix)
                    .font(themeManager.chatFont)
                    .foregroundColor(theme.secondaryText)
                    .frame(minWidth: 20, alignment: .leading)
                renderText(text)
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
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                    case .failure:
                        Label("Failed to load image", systemImage: "photo.on.rectangle.angled")
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                    case .empty:
                        HStack {
                            Spacer()
                            VStack {
                                ProgressView()
                                if let alt = altText, !alt.isEmpty {
                                    Text(alt).font(.caption).foregroundColor(theme.secondaryText)
                                }
                            }
                            Spacer()
                        }
                        .frame(height: 100)
                    @unknown default:
                        EmptyView()
                    }
                }
                .padding(.vertical, theme.spacingSmall)
                .frame(maxWidth: 500, alignment: .leading)
            }
        }
    }

    // MARK: - Text Rendering

    private func renderText(_ text: String, font: Font? = nil, weight: Font.Weight = .regular) -> some View {
        let resolvedFont = font ?? themeManager.chatFont
        return Text(createStyledString(from: text, font: resolvedFont, weight: weight))
            .lineSpacing(themeManager.chatLineSpacing)
            .textSelection(.enabled)
    }

    private func createStyledString(from text: String, font: Font, weight: Font.Weight) -> AttributedString {
        let inlineCodeBg = theme.inlineCodeBackground
        let inlineCodeHighlight = theme.inlineCodeHighlight
        let textColor = theme.primaryText

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

        return attributedString
    }

    // MARK: - Heading Fonts

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
