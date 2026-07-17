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

private let logger = DGLogger(category: "ContentBlockView")

struct ContentBlock: Identifiable, Equatable, Hashable {
    let id: String // e.g., "block-0", "block-1"; children are "block-0.1"
    let type: BlockType

    /// Task-list state for a `- [ ]` / `- [x]` item. `nil` = an ordinary list item.
    enum Checkbox: Equatable, Hashable {
        case unchecked, checked
    }

    /// A table column's `:--` / `:-:` / `--:` alignment.
    ///
    /// Mirrors `Markdown.Table.ColumnAlignment` rather than re-exporting it, so the view
    /// layer doesn't import the parser's vocabulary. GFM's unspecified default is leading.
    enum ColumnAlignment: Equatable, Hashable {
        case leading, center, trailing

        var textAlignment: TextAlignment {
            switch self {
            case .leading: return .leading
            case .center:  return .center
            case .trailing: return .trailing
            }
        }

        var frameAlignment: Alignment {
            switch self {
            case .leading: return .topLeading
            case .center:  return .top
            case .trailing: return .topTrailing
            }
        }
    }

    /// The block model is RECURSIVE: a list item and a blockquote own child blocks.
    ///
    /// It used to be flat — `listItem` held a `String`, and there was no blockquote —
    /// so the parser dumped an item's children into that string as raw markdown via
    /// `format()`. `createStyledString` then fed that to `AttributedString(markdown:)`,
    /// which consumed the `-`/`>`/fence markers (and the newlines!) into BLOCK-level
    /// `presentationIntent` that the renderer never read. Result on screen:
    /// "1. Install dependenciesRun npm installVerify with npm -v". Modelling children
    /// as blocks is what makes nested lists, code-in-list, multi-paragraph items and
    /// blockquotes renderable at all.
    ///
    /// (No `indirect` needed: the recursion passes through `Array`, which already
    /// provides the heap indirection.)
    enum BlockType: Equatable, Hashable {
        case paragraph(String)
        case code(language: String, content: String, fileName: String?)
        case heading(level: Int, text: String)
        /// `blocks` = everything the item contains, IN DOCUMENT ORDER — its paragraphs,
        /// its code fences, and any nested list (as further `.listItem` children).
        ///
        /// Order matters: an earlier version partitioned an item's children into
        /// "own content" vs "nested lists" and emitted the former first, which silently
        /// REORDERED output — a fence written after the sub-bullets rendered above them.
        /// There is no `indentation` parameter because nesting depth IS the indentation;
        /// the renderer's marker+VStack layout indents children for free.
        case listItem(prefix: String, blocks: [ContentBlock], checkbox: Checkbox?)
        case blockquote(blocks: [ContentBlock])
        case horizontalRule
        /// `alignments` is per-column and parallel to `headers`. Markdown's `:--`/`--:`
        /// was parsed by cmark and then dropped here, so a numeric column that the author
        /// right-aligned rendered left like everything else.
        case table(headers: [String], rows: [[String]], alignments: [ColumnAlignment])
        case image(url: String, altText: String?)
    }
}

extension ContentBlock {
    /// Recursively flattens this block to plain text, for consumers that need a
    /// string rather than a view tree (RAG chunking, plain-text previews).
    var plainText: String {
        switch type {
        case .paragraph(let text), .heading(_, let text):
            return text
        case .code(_, let content, _):
            return content
        case .listItem(let prefix, let blocks, let checkbox):
            let marker: String? = checkbox.map { $0 == .checked ? "[x]" : "[ ]" }
            let body = blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: " ")
            return [prefix, marker, body]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .blockquote(let blocks):
            return blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: " ")
        case .table(let headers, let rows, _):
            let headerText = headers.joined(separator: " | ")
            let rowsText = rows.map { $0.joined(separator: " | ") }.joined(separator: "\n")
            return headerText + "\n" + rowsText
        case .horizontalRule:
            return ""
        case .image(_, let altText):
            return altText ?? ""
        }
    }
}

struct ContentBlockView: View, Equatable {
    let block: ContentBlock
    let message: ChatMessage
    var isLastBlock: Bool = false
    var searchQuery: String = ""
    var activeHighlightIndex: Int? = nil

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    /// Code sits a step below body prose (the same convention `MarkdownTableView` uses for
    /// cells), but it now MOVES with `chatFontSize` instead of being pinned at 12pt —
    /// a reader at 20pt prose was getting 12pt code with no way to change it.
    private var codeFontSize: CGFloat {
        max(10, themeManager.chatFontSize - 2)
    }

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
            // Counted and built via CodeSnippet so this card, and the snippet the viewer
            // opens when it's tapped, are derived identically — see CodeSnippet.isLarge.
            if CodeSnippet.isLarge(codeBlockContent: codeContent) {
                CodeBlockCardView(language: lang, lineCount: CodeSnippet.lineCount(codeBlockContent: codeContent), fileName: fileName, content: codeContent) {
                    let snippet = CodeSnippet(codeBlock: lang, content: codeContent)
                    chatHistoryViewModel.openMessageInCodeViewer(message: message, selectedSnippet: snippet)
                }
                .accessibilityLabel("\(lang) code block, \(CodeSnippet.lineCount(codeBlockContent: codeContent)) lines. Tap to open in viewer.")
            } else {
                CodeBlockView(language: lang, content: codeContent, fileName: fileName, fontSize: codeFontSize)
                    .padding(.bottom, theme.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(lang) code block")
            }

        case .heading(let level, let text):
            renderTextView(text: text, font: fontForHeading(level: level), weight: fontWeightForHeading(level: level))
                .padding(.top, theme.spacingMedium)
                .padding(.bottom, theme.spacingXSmall)
                // Headings were size and weight only — visual structure a VoiceOver user
                // couldn't see or navigate. With the trait they populate the rotor, so a
                // long reply can be skimmed section by section instead of read start to end.
                // Explicit element because `renderTextView` returns an HStack (text +
                // streaming cursor), and traits on a bare container don't reliably reach the
                // Text inside. The cursor is `.accessibilityHidden`, so nothing else merges in.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(Self.headingLevel(level))

        case .listItem(let prefix, let blocks, let checkbox):
            // `.firstTextBaseline` keeps the marker (number/bullet/checkbox) on the FIRST
            // line of a wrapped item. `.top` used to float them up relative to the icon,
            // and the icon's own HStack defaulted to `.center` — see renderPathListItem.
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingSmall) {
                listMarker(prefix: prefix, checkbox: checkbox)

                // Everything the item contains, in document order — so a fenced code
                // block inside an item is a real code block, a multi-paragraph item
                // keeps its paragraphs, and a NESTED list renders here as child items.
                // The marker + this VStack supply the indentation; no manual padding.
                VStack(alignment: .leading, spacing: theme.spacingXXSmall) {
                    ForEach(blocks) { child in
                        childBlock(child)
                    }
                }
            }
            .padding(.bottom, theme.spacingXXSmall)

        case .blockquote(let blocks):
            HStack(alignment: .top, spacing: theme.spacingSmall) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor.opacity(0.45))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: theme.spacingXXSmall) {
                    ForEach(blocks) { child in
                        childBlock(child)
                    }
                }
                .foregroundColor(theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, theme.spacingSmall)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quote")

        case .horizontalRule:
            Divider()
                .padding(.vertical, theme.spacingMedium)

        case .table(let headers, let rows, let alignments):
            // One step below the chat body size — tables at full prose size read
            // oversized (and previously hard-coded 15pt regardless of the setting).
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
                            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium).stroke(theme.dividerColor, lineWidth: 1))
                            // altText reached this view but was only ever shown as a caption
                            // WHILE loading — the loaded image, the one that stays on screen,
                            // had no description at all.
                            .accessibilityLabel(altText?.isEmpty == false ? altText! : String(localized: "Image"))
                            .accessibilityAddTraits(.isImage)
                    case .failure(_):
                        VStack(spacing: theme.spacingXSmall) {
                            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundColor(theme.secondaryText)
                            Text("Failed to load image").font(.caption).foregroundColor(theme.secondaryText)
                        }
                        .frame(maxWidth: ChatUIConstants.imageMaxWidth,
                               minHeight: ChatUIConstants.imagePlaceholderMinHeight, alignment: .center)
                        .background(theme.controlBackground)
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(altText?.isEmpty == false ? "Image failed to load: \(altText!)" : "Image failed to load")
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
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                    @unknown default: EmptyView()
                    }
                }
                .padding(.vertical, theme.spacingSmall)
                .frame(maxWidth: ChatUIConstants.imageMaxWidth, alignment: .leading)
            } else { EmptyView() }
        }
    }

    // MARK: - Nested Blocks

    /// Renders a child block (list-item content, blockquote content).
    ///
    /// The streaming cursor belongs on the very last glyph of the message, so
    /// `isLastBlock` only propagates into the LAST child of a last block. Search
    /// highlighting threads through unchanged.
    @ViewBuilder
    private func childBlock(_ child: ContentBlock) -> some View {
        ContentBlockView(
            block: child,
            message: message,
            isLastBlock: isLastBlock && child.id == lastChildID,
            searchQuery: searchQuery,
            activeHighlightIndex: activeHighlightIndex
        )
        .equatable()
    }

    /// Id of the final child of this block, if it has children.
    private var lastChildID: String? {
        switch block.type {
        case .listItem(_, let blocks, _), .blockquote(let blocks):
            return blocks.last?.id
        default:
            return nil
        }
    }

    /// Bullet / number / task checkbox for a list item.
    @ViewBuilder
    private func listMarker(prefix: String, checkbox: ContentBlock.Checkbox?) -> some View {
        if let checkbox {
            // `- [x]` / `- [ ]` used to be discarded entirely — both rendered as a
            // plain bullet, so done and not-done were indistinguishable.
            Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square")
                .font(themeManager.chatFont)
                .foregroundColor(checkbox == .checked ? theme.accentColor : theme.secondaryText)
                .frame(minWidth: 20, alignment: .leading)
                .accessibilityLabel(checkbox == .checked ? "Completed task" : "Incomplete task")
        } else {
            Text(prefix)
                .font(themeManager.chatFont)
                .foregroundColor(theme.secondaryText)
                .frame(minWidth: 20, alignment: .leading)
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
        // Only explicit path ROWS get the icon treatment: tool-emitted 📁/📄 markers,
        // or items that ARE a path (start with / or ~/). The old `contains("/")`
        // clause decorated prose that merely MENTIONED a path ("…was created in
        // /tmp/") — some numbered items got icons, adjacent ones didn't.
        return trimmed.hasPrefix("📁") || trimmed.hasPrefix("📄")
            || trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")
    }

    @ViewBuilder
    private func renderPathListItem(text: String) -> some View {
        let cleanText = text.replacingOccurrences(of: "📁 ", with: "").replacingOccurrences(of: "📄 ", with: "")
        let isFolder = text.contains("📁") || !cleanText.contains(".")
        
        // `.firstTextBaseline` (not the default `.center`) pins the icon to the first line
        // of a multi-line item instead of floating it to the vertical middle.
        HStack(alignment: .firstTextBaseline, spacing: theme.spacingXSmall) {
            Image(systemName: isFolder ? "folder.fill" : "doc.fill")
                .foregroundColor(theme.accentColor)
                .font(.system(.caption))

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
                // NB: every branch here ASSIGNS `.font`, which overrides whatever
                // SwiftUI would otherwise infer from the intent — so italic has to be
                // applied explicitly. It previously fell into the generic `else` below
                // and was silently dropped (`*text*` rendered upright).
                if intent.contains(.code) {
                    attributedString[run.range].backgroundColor = inlineCodeBg
                    attributedString[run.range].foregroundColor = inlineCodeHighlight
                    attributedString[run.range].font = .system(.body, design: .monospaced)
                } else if intent.contains(.stronglyEmphasized), intent.contains(.emphasized) {
                    attributedString[run.range].font = font.weight(.semibold).italic()
                    attributedString[run.range].foregroundColor = textColor
                } else if intent.contains(.stronglyEmphasized) {
                    attributedString[run.range].font = font.weight(.semibold)
                    attributedString[run.range].foregroundColor = textColor
                } else if intent.contains(.emphasized) {
                    attributedString[run.range].font = font.weight(weight).italic()
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

    /// Applies search-match background highlighting to the styled markdown string,
    /// via the shared `SearchHighlighter` (O(n) forward-cursor pass). Highlight hues
    /// come from the theme so every chat surface highlights identically.
    private func applySearchHighlighting(to attrString: AttributedString, query: String) -> AttributedString {
        SearchHighlighter.highlight(
            attrString,
            query: query,
            activeMatchIndex: activeHighlightIndex,
            base: theme.searchHighlight,
            active: theme.searchHighlightActive
        )
    }

    /// The heading's TRUE level, not the font bucket.
    ///
    /// `fontForHeading` collapses h3–h6 into one size, but the document structure is still
    /// real: VoiceOver's rotor can navigate by level, so an h4 nested under an h3 should say
    /// so even where they look identical on screen.
    static func headingLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: return .h1
        case 2: return .h2
        case 3: return .h3
        case 4: return .h4
        case 5: return .h5
        case 6: return .h6
        default: return .unspecified
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        Rectangle()
            .fill(theme.accentColor)
            .frame(width: 8, height: 16)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                // Under Reduce Motion the caret stays solid rather than blinking for the
                // whole reply. Use a cancellable Task instead of repeatForever() so the
                // animation stops when the view is removed from the hierarchy.
                guard !reduceMotion else { return }
                animationTask = Task { @MainActor in
                    while !Task.isCancelled {
                        withAnimation(.easeInOut(duration: 0.6)) {
                            isVisible.toggle()
                        }
                        try? await Task.sleep(for: .seconds(0.6))
                    }
                }
            }
            .onDisappear {
                animationTask?.cancel()
                animationTask = nil
            }
            // Decoration: it marks where text will appear, and says nothing to a
            // VoiceOver user beyond noise.
            .accessibilityHidden(true)
    }
}
