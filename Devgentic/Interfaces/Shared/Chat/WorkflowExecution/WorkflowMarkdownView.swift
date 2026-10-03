// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    /// Pre-parsed blocks, used when this view re-enters itself to render the children
    /// of a list item / blockquote.
    ///
    /// Recursion MUST route through this nominal type rather than `renderBlock`
    /// calling itself: a `@ViewBuilder func` returning `some View` that recurses
    /// defines its opaque type in terms of itself, which the compiler rejects. Holding
    /// a `WorkflowMarkdownView` as a subview is fine — the child's `body` type never
    /// enters the parent's.
    private var presetBlocks: [ContentBlock]?

    @Environment(\.appTheme) private var theme
    @Environment(ThemeManager.self) private var themeManager

    init(text: String) {
        self.text = text
        self.presetBlocks = nil
    }

    private init(blocks: [ContentBlock]) {
        self.text = ""
        self.presetBlocks = blocks
    }

    var body: some View {
        let blocks = presetBlocks ?? parseMarkdown(text)

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

        case .code(let lang, let codeContent, let fileName):
            // [XUI-8] The user's code size, not `CodeBlockView`'s 12pt default. This surface's prose
            // and tables already scaled with `chatFontSize`; only its code blocks did not, so a
            // reader at 20pt prose got 12pt code in a workflow node and correctly-sized code in the
            // chat bubble two inches away.
            CodeBlockView(language: lang, content: codeContent, fileName: fileName,
                          fontSize: ChatUIConstants.codeFontSize(forChatFontSize: themeManager.chatFontSize))
                .padding(.bottom, theme.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let text):
            renderText(text, font: fontForHeading(level: level), weight: fontWeightForHeading(level: level))
                .padding(.top, theme.spacingMedium)
                .padding(.bottom, theme.spacingXSmall)
                // Same markdown, same renderer gap — workflow output needs the rotor too.
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(ContentBlockView.headingLevel(level))

        case .listItem(let prefix, let blocks, let checkbox):
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingSmall) {
                if let checkbox {
                    Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                        .font(themeManager.chatFont)
                        .foregroundColor(checkbox == .checked ? theme.accentColor : theme.secondaryText)
                        .frame(minWidth: 20, alignment: .leading)
                } else {
                    Text(prefix)
                        .font(themeManager.chatFont)
                        .foregroundColor(theme.secondaryText)
                        .frame(minWidth: 20, alignment: .leading)
                }
                WorkflowMarkdownView(blocks: blocks)
            }
            .padding(.bottom, theme.spacingXXSmall)

        case .blockquote(let blocks):
            HStack(alignment: .top, spacing: theme.spacingSmall) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor.opacity(0.45))
                    .frame(width: 3)
                WorkflowMarkdownView(blocks: blocks)
                .foregroundColor(theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, theme.spacingSmall)

        case .horizontalRule:
            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)
                .padding(.vertical, theme.spacingMedium)

        case .table(let headers, let rows, let alignments):
            // Matches ContentBlockView: one step below chat body size.
            MarkdownTableView(headers: headers, rows: rows, alignments: alignments, cellFontSize: max(11, themeManager.chatFontSize - 2))
                .transaction { $0.animation = nil }

        case .image(let url, let altText):
            if let imageUrl = URL(string: url) {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                            // Was shown as a caption while loading, then dropped once the
                            // image — the thing that stays on screen — actually arrived.
                            .accessibilityLabel(altText?.isEmpty == false ? altText! : String(localized: "Image"))
                            .accessibilityAddTraits(.isImage)
                    case .failure:
                        Label("Failed to load image", systemImage: "photo.on.rectangle.angled")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                            .accessibilityLabel(altText?.isEmpty == false ? "Image failed to load: \(altText!)" : "Image failed to load")
                    case .empty:
                        HStack {
                            Spacer()
                            VStack {
                                ProgressView()
                                if let alt = altText, !alt.isEmpty {
                                    Text(alt).font(theme.fontCaption2).foregroundColor(theme.secondaryText)
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
                .frame(maxWidth: ChatUIConstants.imageMaxWidth, alignment: .leading)
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
        let inlineCodeHighlight = theme.inlineCodeHighlight
        let textColor = theme.primaryText
        let linkColor = theme.accentColor

        var attributedString: AttributedString
        if let parsed = try? AttributedString(markdown: text) {
            attributedString = parsed
            for run in attributedString.runs {
                let intent = run.inlinePresentationIntent ?? []
                if intent.contains(.code) {
                    // Colour + monospace only, matching `ContentBlockView` — the chat and
                    // the workflow timeline must render the same markdown identically.
                    attributedString[run.range].foregroundColor = inlineCodeHighlight
                    attributedString[run.range].font = font.weight(weight).monospaced()
                } else if intent.contains(.stronglyEmphasized), intent.contains(.emphasized) {
                    attributedString[run.range].font = font.weight(.semibold).italic()
                    attributedString[run.range].foregroundColor = textColor
                } else if intent.contains(.stronglyEmphasized) {
                    attributedString[run.range].font = font.weight(.semibold)
                    attributedString[run.range].foregroundColor = textColor
                } else if intent.contains(.emphasized) {
                    // Was missing entirely, so italic runs fell into the generic `else` and had
                    // a NON-italic font assigned over them — silently destroying the emphasis.
                    // The comment above states the contract this broke: chat and the workflow
                    // timeline must render the same markdown identically.
                    attributedString[run.range].font = font.weight(weight).italic()
                    attributedString[run.range].foregroundColor = textColor
                } else if run.link != nil {
                    // Kept in step with `ContentBlockView.createStyledString`, which carries the
                    // full reasoning: a markdown link has NO `inlinePresentationIntent`, so it
                    // fell into the `else` below and had SwiftUI's accent tint overwritten with
                    // body colour — leaving a workflow node's links indistinguishable from the
                    // prose around them. The underline must be explicit; `.link` does not bring
                    // one once the run carries its own `foregroundColor`.
                    attributedString[run.range].font = font.weight(weight)
                    attributedString[run.range].foregroundColor = linkColor
                    attributedString[run.range].underlineStyle = .single
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
