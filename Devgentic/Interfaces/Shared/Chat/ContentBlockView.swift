// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ContentBlockView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "ContentBlockView")

/// A rendered chunk of a chat message's markdown (paragraph, heading, code, list, table, image, and so on).
/// Equatable so views can memoize unchanged blocks.
struct ContentBlock: Identifiable, Equatable, Hashable {
    let id: String // e.g., "block-0", "block-1"; children are "block-0.1"
    let type: BlockType

    /// Task-list state for a `- [ ]` / `- [x]` item. `nil` = an ordinary list item.
    enum Checkbox: Equatable, Hashable {
        case unchecked, checked
    }

    /// A table column's `:--` / `:-:` / `--:` alignment.
    /// Mirrors `Markdown.Table.ColumnAlignment` so the view layer does not import the parser's vocabulary; the default
    /// is leading.
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

    /// The block model is recursive: a list item and a blockquote own child blocks.
    /// Modelling children as blocks is what makes nested lists, code in lists, multi-paragraph items and blockquotes
    /// renderable.
    enum BlockType: Equatable, Hashable {
        case paragraph(String)
        case code(language: String, content: String, fileName: String?)
        case heading(level: Int, text: String)
        /// `blocks` is everything the item contains in document order: paragraphs, code fences and nested lists.
        /// Nesting depth is the indentation, so there is no `indentation` parameter.
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
    /// The active match's location within the message, resolved locally against this block's own id.
    var activeMatch: ActiveSearchMatch? = nil

    /// [mc-11] What a file-reference verification depends on. `isStreaming` is part of the key
    /// so the SETTLE re-fires it — see the task below for why text alone cannot.
    private struct VerifyKey: Equatable {
        let text: String
        let isStreaming: Bool
    }

    /// This block's own active index, or nil when the active match belongs elsewhere.
    /// Mismatch degrades to "paint nothing", never to "paint the wrong run".
    private var activeHighlightIndex: Int? {
        guard let activeMatch, activeMatch.blockID == block.id else { return nil }
        return activeMatch.indexInBlock
    }

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme

    // Why: `@State` and not part of `==`: the memoized equality skips unchanged blocks, and state changes re-run `body`
    // anyway.
    /// Maps code span to absolute path for spans naming a readable file right now; only those are tappable.
    /// Filled off-main by `verifyFileReferences`; keyed by span because a bare filename cannot be re-derived.
    @State private var resolvedFileLinks: [String: String] = [:]

    /// Why the last tap on a file reference in this block opened nothing, or nil.
    /// The open can fail after verification (file moved, unreadable, not UTF-8); cleared on the next successful open.
    @State private var fileOpenFailureReason: String?

    /// Code sits a step below body prose (the same convention `MarkdownTableView` uses for
    /// cells), but it now MOVES with `chatFontSize` instead of being pinned at 12pt —
    /// a reader at 20pt prose was getting 12pt code with no way to change it.
    private var codeFontSize: CGFloat {
        ChatUIConstants.codeFontSize(forChatFontSize: themeManager.chatFontSize)
    }

    // MARK: - Equatable Memoization
    // This allows SwiftUI to completely skip re-rendering blocks that haven't changed.
    static func == (lhs: ContentBlockView, rhs: ContentBlockView) -> Bool {
        return lhs.block == rhs.block &&
               lhs.isLastBlock == rhs.isLastBlock &&
               lhs.message.id == rhs.message.id &&
               lhs.message.isStreaming == rhs.message.isStreaming &&
               lhs.searchQuery == rhs.searchQuery &&
               lhs.activeMatch == rhs.activeMatch
    }

    var body: some View {
        switch block.type {
        case .paragraph(let text):
            renderTextView(text: text)
                .padding(.bottom, theme.spacingSmall)

        case .code(let lang, let codeContent, let fileName):
            // Counted once per body pass via `CodeSnippet` and reused for the branch, the card and the accessibility label.
            let codeLines = CodeSnippet.lineCount(codeBlockContent: codeContent)
            if codeLines > ChatUIConstants.codeBlockLineLimit {
                CodeBlockCardView(language: lang, lineCount: codeLines, fileName: fileName, content: codeContent) {
                    let snippet = CodeSnippet(codeBlock: lang, content: codeContent)
                    chatHistoryViewModel.openMessageInCodeViewer(message: message, selectedSnippet: snippet)
                }
                .accessibilityLabel("\(lang) code block, \(codeLines) lines. Tap to open in viewer.")
            } else {
                // The inline Viewer button passes the same origin identity as the card branch, so re-opening refreshes the tab.
                CodeBlockView(language: lang, content: codeContent, fileName: fileName, fontSize: codeFontSize,
                              originMessageID: message.id,
                              resolveOriginBlockIndex: { [message] in
                                  // The message text is read here, not in the capture list: reading an `@Observable` property in `body` would defeat
                                  // `.equatable()` memoization.
                                  Self.codeBlockOrdinal(forContent: codeContent, in: message)
                              })
                    .padding(.bottom, theme.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("\(lang) code block")
            }

        case .heading(let level, let text):
            renderTextView(text: text, font: fontForHeading(level: level), weight: fontWeightForHeading(level: level))
                .padding(.top, theme.spacingMedium)
                .padding(.bottom, theme.spacingXSmall)
                // Header trait feeds VoiceOver's rotor; an explicit element because traits on a bare HStack may not reach the
                // Text.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(Self.headingLevel(level))

        case .listItem(let prefix, let blocks, let checkbox):
            // `.firstTextBaseline` keeps the marker on the first line of a wrapped item; `.top` and `.center` misalign it.
            HStack(alignment: .firstTextBaseline, spacing: theme.spacingSmall) {
                listMarker(prefix: prefix, checkbox: checkbox)

                // Everything the item contains in document order; the marker and this VStack supply the indentation.
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
            // One step below the chat body size; tables at full prose size read oversized.
            MarkdownTableView(headers: headers, rows: rows, alignments: alignments, cellFontSize: max(11, themeManager.chatFontSize - 2))
                .transaction { $0.animation = nil }

        case .image(let url, let altText):
            // A reference that names a FILE goes to disk, not to URLSession — see
            // `localImagePath`. Every agent-produced chart lands here.
            if let localPath = Self.localImagePath(forSource: url) {
                LocalMarkdownImageView(path: localPath, altText: altText)
            } else if let imageUrl = URL(string: url) {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                            .overlay(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium).stroke(theme.dividerColor, lineWidth: 1))
                            // `altText` is the accessibility label for the loaded image.
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
                        // Was a bare `150` — the same number the constant holds, written twice
                        // in one switch (the `.failure` case two branches up already used it).
                        .frame(height: ChatUIConstants.imagePlaceholderMinHeight)
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

    /// Renders a child block (list-item or blockquote content).
    /// `isLastBlock` propagates only into the last child of a last block, so the streaming cursor sits on the final
    /// glyph.
    @ViewBuilder
    private func childBlock(_ child: ContentBlock) -> some View {
        ContentBlockView(
            block: child,
            message: message,
            isLastBlock: isLastBlock && child.id == lastChildID,
            searchQuery: searchQuery,
            // Forwarded verbatim: the child resolves it against its own `block.id`.
            activeMatch: activeMatch
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
            // A task-list checkbox renders as a checked or unchecked square so done and not-done are distinguishable.
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
        VStack(alignment: .leading, spacing: theme.spacingXXSmall) {
            HStack(alignment: .bottom, spacing: 0) {
                Text(createStyledString(from: text, font: resolvedFont, weight: weight))
                    .lineSpacing(themeManager.chatLineSpacing)
                    .textSelection(.enabled)
                    // Smooth out text updates slightly to avoid harsh token jitter
                    .animation(.linear(duration: 0.05), value: text.count)

                if message.isStreaming && isLastBlock {
                    BlinkingCursor()
                        .padding(.leading, 2)
                        .padding(.bottom, 4) // Align with baseline
                }
            }

            // The one route these spans offer can fail after they were verified. Say so
            // under the block the tap happened in.
            if let fileOpenFailureReason {
                fileOpenFailureCaption(fileOpenFailureReason)
            }
        }
        // Why: keyed on (text, isStreaming) and skipped while streaming: settling must re-fire the task,
        // since a settled block keeps its positional id and unchanged text.
        // Existence checks stat each candidate and can hang on an unresponsive mount, so they never run in `body`.
        // Until the task lands the spans render as ordinary inline code.
        .task(id: VerifyKey(text: text, isStreaming: message.isStreaming)) {
            await verifyFileReferences(in: text)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let path = FileReferenceResolver.path(fromLinkURL: url) else {
                return .systemAction
            }
            // The URL scheme is not authorisation: only paths minted for this block (`resolvedFileLinks`) may open; reply text
            // is untrusted.
            guard Self.isVerifiedForThisBlock(path, verifiedPaths: resolvedFileLinks.values) else {
                // `.handled`, not `.systemAction`: refusing must not hand the URL back to the
                // system to open by some other route.
                logger.warning("[FileRef] REFUSED a \(FileReferenceResolver.scheme) link whose path was never verified for this block: \(path). CONSEQUENCE: nothing is opened — this link was authored in the message rather than minted from a checked file reference, and honouring it would let message content choose any path on disk.")
                fileOpenFailureReason = String(localized: "That link points somewhere this message never referenced, so it wasn't opened.")
                return .handled
            }
            openFileReference(path, inBlockText: text)
            return .handled
        })
    }

    /// Whether a tapped link's path is one this block verified.
    /// Separate from the SwiftUI handler so the rule that decides whether message content can choose a path is
    /// testable.
    nonisolated static func isVerifiedForThisBlock(_ path: String,
                                                   verifiedPaths: some Collection<String>) -> Bool {
        verifiedPaths.contains(path)
    }

    /// The "that didn't open" caption under a block whose file reference was tapped.
    /// Same shape as the agent timeline's row-level failure surface, at prose scale.
    @ViewBuilder
    private func fileOpenFailureCaption(_ reason: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.errorColor)
            Text(reason)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.errorColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.errorColor.opacity(0.2), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Could not open file. \(reason)"))
        .transition(.opacity)
    }

    /// Resolves which inline-code spans in `text` are openable files, off the main thread.
    /// An absolute path resolves by shape and a bare filename by matching a file this conversation read or wrote;
    /// either way it must still be a readable regular file.
    private func verifyFileReferences(in text: String) async {
        guard chatHistoryViewModel.canPresentCodeViewer else { return }
        // Verifies once per block at settle: paths in a streaming block are still arriving.
        guard !message.isStreaming else { return }

        // The index is built on the main actor because it reads the loaded messages; only small param blobs are
        // JSON-decoded.
        let index = FileReferenceResolver.fileIndex(from: chatHistoryViewModel.currentChatMessages)
        // ONE markdown parse, shared: `createStyledString` will parse this text again to render
        // it, but the second parse inside `candidateLinks(inMarkdown:)` was pure duplication.
        let spans = FileReferenceResolver.codeSpans(inMarkdown: text)
        let candidates = FileReferenceResolver.candidateLinks(inCodeSpans: spans, index: index)
        guard !candidates.isEmpty else {
            if !resolvedFileLinks.isEmpty { resolvedFileLinks = [:] }
            return
        }

        let paths = Set(candidates.values)
        let existing = await Task.detached(priority: .utility) {
            FileReferenceResolver.verifyExisting(paths)
        }.value
        let resolved = candidates.filter { existing.contains($0.value) }

        guard !Task.isCancelled, resolved != resolvedFileLinks else { return }
        if resolved.count < candidates.count {
            // The file is gone; silent on screen, but the unlinked span is logged.
            let missing = candidates.filter { !existing.contains($0.value) }.values.sorted()
            logger.debug("[FileRef] \(missing.count) reference(s) left unlinked — no readable file at: \(missing.joined(separator: ", ")).")
        }
        logger.debug("[FileRef] Linked \(resolved.count)/\(candidates.count) reference(s) in this block.")
        resolvedFileLinks = resolved
    }

    /// Reads the file and hands it to the Code Viewer, with the same off-main read and failure path as
    /// `AgentTimelineView.openInViewer`.
    /// `blockText` is re-verified after a failure so a dead link reverts to plain inline code.
    private func openFileReference(_ path: String, inBlockText blockText: String) {
        let viewModel = chatHistoryViewModel
        Task {
            // `try?` discarded the real error, so "moved", "no permission" and "not UTF-8"
            // were indistinguishable in the log and invisible on screen.
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do { return .success(try String(contentsOfFile: path, encoding: .utf8)) }
                catch { return .failure(error) }
            }.value

            switch result {
            case .failure(let error):
                fileOpenFailureReason = Self.openFailureText(for: error, path: path)
                logger.warning("[CodeViewer] File-reference open of '\(path)' failed — \(error.localizedDescription). Surfaced under the block; nothing opened, and the reference is being re-verified so a dead link stops looking tappable.")
                await verifyFileReferences(in: blockText)
            case .success(let content) where content.isEmpty:
                // Readable but empty: opening a blank tab looks like a bug, so say so.
                fileOpenFailureReason = String(localized: "This file is now empty — nothing to show.")
                logger.warning("[CodeViewer] File-reference open of '\(path)' read 0 bytes — the file is empty now; nothing opened, reason shown under the block.")
            case .success(let content):
                fileOpenFailureReason = nil
                viewModel.openTimelineFileInCodeViewer(
                    fileName: (path as NSString).lastPathComponent,
                    filePath: path,
                    content: content
                )
            }
        }
    }

    /// Turns a read error into something the user can act on, checking `CocoaError` codes so it survives localization.
    /// A local copy of `AgentTimelineView.openFailureText`; keep the wording in step with it.
    nonisolated static func openFailureText(for error: Error, path: String) -> String {
        let name = (path as NSString).lastPathComponent
        switch (error as? CocoaError)?.code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return String(localized: "\(name) has been moved or deleted since it was linked.")
        case .fileReadNoPermission:
            return String(localized: "Devgentic doesn't have permission to read \(name).")
        case .fileReadInapplicableStringEncoding:
            return String(localized: "\(name) isn't UTF-8 text, so it can't be shown here.")
        default:
            return String(localized: "Couldn't open \(name): \(error.localizedDescription)")
        }
    }

    private func createStyledString(from text: String, font: Font, weight: Font.Weight) -> AttributedString {
        // Capture theme colors for use inside AttributedString manipulation
        let textColor = theme.primaryText
        let inlineCodeHighlight = theme.inlineCodeHighlight
        let linkColor = theme.accentColor

        var attributedString: AttributedString
        if let parsed = try? AttributedString(markdown: text) {
            attributedString = parsed
            for run in attributedString.runs {
                let intent = run.inlinePresentationIntent ?? []
                // Every branch assigns `.font`, which overrides SwiftUI's inference, so italic must be applied explicitly.
                if intent.contains(.code) {
                    // Colour and monospace only, with no background chip, which would compete with the search highlight.
                    attributedString[run.range].foregroundColor = inlineCodeHighlight
                    // `font.monospaced()` so inline code matches the surrounding context, including headings.
                    attributedString[run.range].font = font.weight(weight).monospaced()

                    // Tappable only for a verified file; the underline is explicit because `.link` adds none once `foregroundColor` is
                    // set.
                    let span = String(attributedString[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // No `run.link != nil` case: Foundation drops the `.code` intent on a link label, so those runs take the
                    // ordinary-link branch.
                    if let path = resolvedFileLinks[span],
                       let url = FileReferenceResolver.linkURL(forVerifiedPath: path) {
                        attributedString[run.range].link = url
                        // Re-assert the colour: SwiftUI tints links with the accent otherwise,
                        // which is close to but not the same as the inline-code hue.
                        attributedString[run.range].foregroundColor = inlineCodeHighlight
                        attributedString[run.range].underlineStyle = .single
                    }
                } else if intent.contains(.stronglyEmphasized), intent.contains(.emphasized) {
                    attributedString[run.range].font = font.weight(.semibold).italic()
                    attributedString[run.range].foregroundColor = textColor
                } else if intent.contains(.stronglyEmphasized) {
                    attributedString[run.range].font = font.weight(.semibold)
                    attributedString[run.range].foregroundColor = textColor
                } else if intent.contains(.emphasized) {
                    attributedString[run.range].font = font.weight(weight).italic()
                    attributedString[run.range].foregroundColor = textColor
                } else if run.link != nil {
                    // An ordinary markdown link carries no inline intent; colour and underline are both explicit so it stays visible.
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

    /// Returns the filesystem path a markdown image reference names, or nil when it is a URL for `AsyncImage`.
    /// Claims `/abs`, `./`, `../` and `~/` shapes; `./` and `../` are returned verbatim and resolve against the working
    /// directory.
    nonisolated static func localImagePath(forSource source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A space does not make `URL(string:)` fail; the claim is taken from the source string, never a round trip through
        // `URL`.
        if let url = URL(string: trimmed), let scheme = url.scheme {
            // A `file:` URL names a local file too; read it directly instead of round-tripping.
            return scheme.caseInsensitiveCompare("file") == .orderedSame ? url.path : nil
        }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")
                || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// The chip caption for a local image reference that produced no picture.
    /// Three outcomes: exists but undecodable, missing, and a relative reference the app cannot resolve against a base.
    nonisolated static func localImageFailureText(path: String, fileExists: Bool) -> String {
        if fileExists {
            return String(localized: "This file isn't an image Devgentic can display.")
        }
        if !(path as NSString).isAbsolutePath {
            return String(localized: "This path is relative, and Devgentic can't tell which folder it starts from.")
        }
        return String(localized: "This file is no longer here.")
    }

    /// Returns the ordinal of a rendered code block, resolved against the text the bubble is actually showing.
    /// Uses `displayedContent`, not `content`, since they diverge after a Retry.
    /// `openMessageInCodeViewer` enumerates the same expression so the `(message.id, ordinal)` origin key is safe.
    nonisolated static func codeBlockOrdinal(forContent content: String, in message: ChatMessage) -> Int? {
        codeBlockOrdinal(forContent: content, in: message.displayedContent)
    }

    /// Returns where a code block sits among its message's code blocks, numbered as `openMessageInCodeViewer` numbers
    /// them.
    /// The numberings must agree so inline and card opens share one tab; identical blocks share an ordinal.
    nonisolated static func codeBlockOrdinal(forContent content: String, in messageContent: MessageContent) -> Int? {
        let normalized = CodeSnippet.normalizedCode(content)
        guard !normalized.isEmpty else { return nil }
        switch messageContent {
        case .codeBlock(_, let code):
            return CodeSnippet.normalizedCode(code) == normalized ? 0 : nil
        case .markdownText(let text):
            return CodeSnippetExtractor.extract(from: text).firstIndex { $0.code == normalized }
        default:
            return nil
        }
    }

    /// Returns the heading's true level, not the font bucket.
    /// `fontForHeading` collapses h3-h6 into one size, but VoiceOver's rotor navigates by level.
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

// MARK: - Local Markdown Image

/// A markdown image whose source names a file on disk instead of a URL.
/// Decodes off-main through `ImageDownsampler`; shows a file chip when missing or undecodable (see
/// `localImageFailureText`).
private struct LocalMarkdownImageView: View {
    let path: String
    let altText: String?

    @Environment(\.appTheme) private var theme
    @State private var image: NSImage?
    @State private var failureReason: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                    .overlay(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium).stroke(theme.dividerColor, lineWidth: 1))
                    .accessibilityLabel(altText?.isEmpty == false ? altText! : String(localized: "Image"))
                    .accessibilityAddTraits(.isImage)
            } else if let failureReason {
                fileChip(failureReason)
            } else {
                HStack {
                    Spacer()
                    VStack {
                        ProgressView()
                        if let alt = altText, !alt.isEmpty {
                            Text(alt).font(.caption).foregroundColor(theme.secondaryText).padding(.top, 4)
                        }
                    }
                    Spacer()
                }
                .frame(height: ChatUIConstants.imagePlaceholderMinHeight)
                .background(theme.controlBackground)
                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
            }
        }
        .padding(.vertical, theme.spacingSmall)
        .frame(maxWidth: ChatUIConstants.imageMaxWidth, alignment: .leading)
        .task(id: path) { await load() }
    }

    /// The chip that replaces a picture we could not produce. Names the file, because the
    /// path is the only thing the reader can act on.
    private func fileChip(_ reason: String) -> some View {
        let name = (path as NSString).lastPathComponent
        return HStack(alignment: .center, spacing: theme.spacingXSmall) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 16))
                .foregroundColor(theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reason)
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
        .help(path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Image \(name) could not be shown. \(reason)"))
    }

    private func load() async {
        let target = path
        let decoded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let data = FileManager.default.contents(atPath: target) else { return nil }
            // Retina headroom over the display cap, the same doubling attached thumbnails use.
            return ImageDownsampler.thumbnail(from: data, maxDimension: ChatUIConstants.imageMaxWidth * 2)
        }.value

        guard !Task.isCancelled else { return }
        if let decoded {
            image = decoded
            failureReason = nil
            return
        }

        // Only reached when there is nothing to draw, so the extra stat is cheap and yields distinct failure cards.
        let exists = await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: target)
        }.value
        guard !Task.isCancelled else { return }
        image = nil
        let cause: String
        if exists {
            cause = "unreadable, or not a decodable image"
        } else if (target as NSString).isAbsolutePath {
            cause = "no file at that path"
        } else {
            cause = "relative reference with no base — read against the process working directory '\(FileManager.default.currentDirectoryPath)', which is not the agent's workspace"
        }
        failureReason = ContentBlockView.localImageFailureText(path: target, fileExists: exists)
        logger.warning("[MEDIA] Local markdown image '\(target)' rendered no picture — \(cause); showing a file chip in its place.")
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
                // Under Reduce Motion the caret stays solid; a cancellable Task stops the blink when the view is removed.
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
