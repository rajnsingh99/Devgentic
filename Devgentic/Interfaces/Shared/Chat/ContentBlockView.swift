// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ContentBlockView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/08/25.
//
//  Phase 5: Motion & Polish - Added Blinking Cursor & Text Smoothing.
//  Step 5: Equatable Conformance for High-Performance Memoization.

import SwiftUI
import AppKit
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
    /// The active match's location within the MESSAGE, resolved locally against this block's
    /// own id. Previously this was a bare `Int` counted across the whole message and handed
    /// to every block, which then compared it against its own offsets — so the active
    /// highlight painted a different occurrence than the one being navigated to, or nothing.
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

    /// `code span → absolute path` for the spans in this block that name a readable file RIGHT
    /// NOW — the only ones that become tappable. Filled off-main by `verifyFileReferences`;
    /// empty until it lands and whenever nothing resolves, which is the feature's silent default.
    ///
    /// Keyed by SPAN, not path: a bare filename like `AbstractionDemo.java` cannot be
    /// re-derived from the resolved path at render time, so the mapping has to be carried.
    ///
    /// Deliberately `@State` and NOT part of `==`: the memoized equality below exists to skip
    /// re-rendering unchanged blocks, and state changes re-run `body` regardless.
    @State private var resolvedFileLinks: [String: String] = [:]

    /// Why the last tap on a file reference in this block opened nothing, or nil.
    ///
    /// The open can fail after the span was verified — the file moves, loses read
    /// permission, or stops being UTF-8 text — and until this existed the failure was a log
    /// line only: the link stayed underlined and tapping it did nothing visible, forever,
    /// because `resolvedFileLinks` re-verifies on `.task(id: text)` and a settled block's
    /// text never changes again. Cleared on the next successful open.
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
            // Counted and built via CodeSnippet so this card, and the snippet the viewer
            // opens when it's tapped, are derived identically — see CodeSnippet.isLarge.
            // [mc-12] Counted ONCE per body pass and reused for the branch, the card and the
            // accessibility label. It used to be three separate walks of the same unbounded
            // string — `isLarge` internally counts too — on every streaming flush of the block.
            let codeLines = CodeSnippet.lineCount(codeBlockContent: codeContent)
            if codeLines > ChatUIConstants.codeBlockLineLimit {
                CodeBlockCardView(language: lang, lineCount: codeLines, fileName: fileName, content: codeContent) {
                    let snippet = CodeSnippet(codeBlock: lang, content: codeContent)
                    chatHistoryViewModel.openMessageInCodeViewer(message: message, selectedSnippet: snippet)
                }
                .accessibilityLabel("\(lang) code block, \(codeLines) lines. Tap to open in viewer.")
            } else {
                // The inline Viewer button gets the SAME origin identity the card branch
                // above passes through `openMessageInCodeViewer`, so re-opening a block
                // refreshes its tab instead of appending a second one. The ordinal is
                // resolved in the closure — on the click, not on every streamed body pass.
                CodeBlockView(language: lang, content: codeContent, fileName: fileName, fontSize: codeFontSize,
                              originMessageID: message.id,
                              resolveOriginBlockIndex: { [message] in
                                  // The message's text is read HERE, not in the capture list:
                                  // reading an @Observable property inside `body` would make
                                  // every settled block a dependency of the streaming text and
                                  // defeat the `.equatable()` memoization this file is built on.
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
            // line of a wrapped item; `.top` floated it above the text's cap height and
            // `.center` floated it to the vertical middle of a multi-line item. (This used to
            // point at `renderPathListItem` for the `.center` half — that helper was deleted as
            // dead code in the same 2026-09-12 pass; see the note at its former site.)
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
            // Forwarded verbatim: the child resolves it against its own `block.id`, which is
            // the entire nesting fix — a nested paragraph used to receive the message-global
            // integer and compare it against its own local offsets.
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
        VStack(alignment: .leading, spacing: theme.spacingXXSmall) {
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

            // The one route these spans offer can fail after they were verified. Say so
            // under the block the tap happened in.
            if let fileOpenFailureReason {
                fileOpenFailureCaption(fileOpenFailureReason)
            }
        }
        // Existence checking is a `stat` per candidate and can hang for seconds on an
        // unresponsive network mount, so it never runs in `body`. Until this lands the set
        // is empty and the spans render as ordinary inline code — the silent default.
        //
        // ⚠️ [mc-11] Keyed on (text, isStreaming), and the work is SKIPPED while streaming.
        // Keyed on `text` alone it re-ran the whole main-actor prologue on every flush — a
        // fresh `fileIndex` over every loaded message plus a markdown parse of the block — for
        // a block whose paths were still arriving a character at a time. The composite key is
        // what makes the settle itself an event: `ContentBlock.id` is POSITIONAL, so a settled
        // block keeps its identity and, when its final text equals its last streamed text, a
        // task keyed on text alone would never fire again — no reference in it would ever
        // linkify, and `openFileReference` below depends on exactly that standing task.
        .task(id: VerifyKey(text: text, isStreaming: message.isStreaming)) {
            await verifyFileReferences(in: text)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let path = FileReferenceResolver.path(fromLinkURL: url) else {
                return .systemAction
            }
            // ⚠️ [CR18] The scheme is NOT an authorisation check, and treating it as one let a
            // MODEL open any file on this machine.
            //
            // Everything upstream of here gates which inline CODE SPANS become links:
            // `verifyFileReferences` resolves a span against the conversation's own file index
            // and `stat`s it, and only then does `linkURL(forVerifiedPath:)` mint a URL. None of
            // that constrains a link the author WROTE. A reply containing
            // `[click here](devgentic-file://open?path=/Users/you/.ssh/id_rsa)` parses to a run
            // whose `link` carries that URL verbatim — probed: Foundation preserves a custom
            // scheme through `AttributedString(markdown:)` — it lands here, passes the
            // scheme/host test, and the path is opened. The reply is untrusted input.
            //
            // So the path must be one WE minted for this block. `resolvedFileLinks` is exactly
            // that set: filled off-main from this block's own verified spans.
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

    /// [CR18] Whether a tapped link's path is one THIS block verified.
    ///
    /// Extracted so the rule is testable: the handler that calls it lives in a SwiftUI `body` and
    /// cannot be reached from a test, and this is the check that decides whether message content
    /// gets to choose a path on disk.
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
    ///
    /// Two kinds resolve: an absolute path by its shape, and a bare filename by matching a file
    /// this conversation actually read or wrote. Either way the file must STILL be a readable
    /// regular file, so a reference to something the agent has since deleted quietly reverts to
    /// plain text.
    private func verifyFileReferences(in text: String) async {
        guard chatHistoryViewModel.canPresentCodeViewer else { return }
        // [mc-11] Exactly one verification per block, at settle. A streaming block's paths are
        // still arriving, so every intermediate answer is provisional and the final one is the
        // only one that can be right — and the re-key above guarantees this fires again when
        // `isStreaming` flips.
        guard !message.isStreaming else { return }

        // The index is built on the main actor because it reads the loaded messages. It is a
        // plain walk of already-decoded timeline events — writes contribute `effect.path` with
        // no parsing at all, and only small param blobs are decoded (see `maxParamsScanLength`),
        // so a write carrying a whole file never gets JSON-parsed here.
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
            // Named a file that is no longer there. Silent on screen by design, but the reason
            // a span the user expected to be tappable isn't should be visible somewhere.
            let missing = candidates.filter { !existing.contains($0.value) }.values.sorted()
            logger.debug("[FileRef] \(missing.count) reference(s) left unlinked — no readable file at: \(missing.joined(separator: ", ")).")
        }
        logger.debug("[FileRef] Linked \(resolved.count)/\(candidates.count) reference(s) in this block.")
        resolvedFileLinks = resolved
    }

    /// Reads the file and hands it to the Code Viewer. Mirrors `AgentTimelineView.openInViewer`
    /// — same off-main read, same explicit failure path. A file can be moved or deleted
    /// between the verification above and the tap.
    ///
    /// `blockText` is this block's own text, re-verified after a failure so a link that has
    /// gone dead reverts to plain inline code instead of staying underlined and inert: the
    /// standing `.task(id: text)` never fires again for a settled block.
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

    /// Turns a read error into something the user can act on. `CocoaError` codes are checked
    /// rather than the message, so the distinction survives localization.
    ///
    /// Deliberately a local copy of `AgentTimelineView.openFailureText` rather than a shared
    /// helper: the two surfaces are being fixed independently and hoisting one file's private
    /// static into the other is a bigger change than either row asked for. Keep the wording
    /// in step if one of them changes.
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

    // [mc-9] `isPathContent` and `renderPathListItem` were DELETED here on 2026-09-12. They had
    // had zero callers since the ContentBlock model went recursive — the folder/file icon
    // treatment for path list items stopped rendering then and nobody noticed, which is the
    // honest measure of how much it was worth.
    //
    // Deleted rather than re-wired: `renderPathListItem` takes a single `String` and ends in
    // `renderTextView(text:)`, so calling it from the `.listItem` branch would have rendered only
    // the item's first paragraph and SILENTLY DROPPED its other children — nested lists, extra
    // paragraphs, fenced code. Restoring an icon by losing content is not a fix.

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
                // NB: every branch here ASSIGNS `.font`, which overrides whatever
                // SwiftUI would otherwise infer from the intent — so italic has to be
                // applied explicitly. It previously fell into the generic `else` below
                // and was silently dropped (`*text*` rendered upright).
                if intent.contains(.code) {
                    // Colour + monospace ONLY — no background chip. The filled pill read as
                    // visual noise in a paragraph that names a handful of symbols, and it
                    // fought with the search highlight, which is the one background in this
                    // string that carries meaning.
                    attributedString[run.range].foregroundColor = inlineCodeHighlight
                    // `font.monospaced()` rather than `.system(.body, …)`: the hardcoded body
                    // size ignored the surrounding context, which the chip used to disguise.
                    // Inline code in a heading now matches the heading.
                    attributedString[run.range].font = font.weight(weight).monospaced()

                    // Tappable when — and only when — this span resolved to a file that
                    // exists. `resolvedFileLinks` is filled off-main by `verifyFileReferences`,
                    // so an unresolved span simply isn't a link. `.link` is the only per-run
                    // interactive attribute a `Text` supports.
                    //
                    // ⚠️ The underline is set EXPLICITLY. This comment used to claim `.link`
                    // brought one with it — an ImageRenderer pixel probe showed it does not once
                    // the run carries an explicit `foregroundColor`, and we re-assert one two
                    // lines below. So a verified, tappable file reference was rendering
                    // byte-identical to ordinary inline code, with no affordance at all.
                    let span = String(attributedString[run.range].characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // ⚠️ No `run.link != nil` case here, deliberately: a link whose LABEL is
                    // inline code does not reach this branch at all. Probed — Foundation drops
                    // the `.code` intent on a link label, so that run has `link` set and no
                    // intent, and falls to the ordinary-link branch below. See
                    // `FileReferenceResolver.codeSpans` for the probe and `LinkedCodeSpanTests`
                    // for the pin.
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
                    // An ordinary markdown link. It carries NO `inlinePresentationIntent`, so
                    // before this branch existed it fell into the `else` below — which assigns
                    // `foregroundColor = textColor`, overwriting the accent tint SwiftUI would
                    // otherwise give a link. With no underline either, `[docs](https://…)`
                    // rendered pixel-identical to the prose around it: the only clickable thing
                    // in the paragraph was invisible. Colour ALONE is not enough here, which is
                    // why the underline is explicit (see the file-reference note above).
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

    /// The filesystem path a markdown image reference names, or nil when it is a genuine URL
    /// that belongs on the `AsyncImage` path. Absolute for every shape but `./` and `../` —
    /// see the warning below.
    ///
    /// `URL(string:)` happily returns a SCHEME-LESS URL for `/abs/chart.png`, `./out/chart.png`
    /// and `~/chart.png`, and `AsyncImage` loads through URLSession, which rejects anything
    /// without a scheme — so those references could only ever reach the "Failed to load image"
    /// card. Confirmed for all three shapes.
    ///
    /// Only the shapes an author writes when they mean a path are claimed. A bare relative
    /// reference ("images/a.png") reads equally as a relative URL, so it stays on the remote
    /// path exactly as before rather than being guessed at.
    ///
    /// ⚠️ `./` and `../` ARE claimed — nothing else could have loaded them — but they are
    /// returned verbatim, and nothing here can resolve them: `expandingTildeInPath` is a no-op
    /// on them and the app has no base directory for a chat transcript. `FileManager` then
    /// resolves them against the PROCESS working directory ("/" for a Finder-launched app),
    /// not against the agent's workspace, so they normally miss. `localImageFailureText` is
    /// what keeps that honest — the chip must not tell the reader a file that exists is gone.
    nonisolated static func localImagePath(forSource source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The scheme test tolerates a nil URL and falls through. NOTE: a space does NOT make
        // `URL(string:)` fail — it percent-encodes it ("/Users/a b/x.png" → "/Users/a%20b/x.png"),
        // which is the reason the claim below is taken from the SOURCE STRING and never from a
        // round trip through `URL`: the encoded form names no file on disk.
        if let url = URL(string: trimmed), let scheme = url.scheme {
            // A `file:` URL names a local file too; read it directly instead of round-tripping.
            return scheme.caseInsensitiveCompare("file") == .orderedSame ? url.path : nil
        }
        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")
                || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    /// The chip caption for a local image reference that produced no picture.
    ///
    /// Three outcomes, not two. "This file is no longer here." is a confident, specific claim,
    /// and for a RELATIVE reference it is not one we can make: `./out/chart.png` is claimed as
    /// a path because nothing else could ever have loaded it, but there is no base to resolve
    /// it against, so `FileManager` uses the process working directory — "/" for a
    /// Finder-launched app, never the agent's workspace. The read then misses a file that is
    /// on disk, and the chip (which shows only the last path component) gave the reader no way
    /// to see that Devgentic had looked somewhere else entirely.
    nonisolated static func localImageFailureText(path: String, fileExists: Bool) -> String {
        if fileExists {
            return String(localized: "This file isn't an image Devgentic can display.")
        }
        if !(path as NSString).isAbsolutePath {
            return String(localized: "This path is relative, and Devgentic can't tell which folder it starts from.")
        }
        return String(localized: "This file is no longer here.")
    }

    /// The ordinal of a rendered code block, resolved against the text the bubble is
    /// ACTUALLY showing.
    ///
    /// `displayedContent`, not `content`: the blocks on screen come from
    /// `ChatBubbleView.contentToDisplay`, and after a Retry the two diverge — the streaming
    /// path writes only `variants[selected]` while `content` keeps the ORIGINAL answer. Read
    /// against `content`, a regenerated message's blocks are not found at all, the ordinal is
    /// nil, and the inline button falls back to exact-code dedup — which is precisely the
    /// duplicate-tab defect CF-5 filed.
    ///
    /// ⚠️ `ChatHistoryViewModel.openMessageInCodeViewer` enumerates `message.displayedContent`
    /// too (ChatHistoryViewModel.swift, `switch message.displayedContent`), so the inline path
    /// and the card path number the same blocks on a regenerated message as on any other. That
    /// agreement is what makes the shared `(message.id, ordinal)` origin key safe: if the two
    /// ever read different expressions again, they would stamp the same key onto DIFFERENT
    /// code and a card open would overwrite an inline tab's contents.
    nonisolated static func codeBlockOrdinal(forContent content: String, in message: ChatMessage) -> Int? {
        codeBlockOrdinal(forContent: content, in: message.displayedContent)
    }

    /// Where a code block sits among its message's code blocks, numbered the way
    /// `openMessageInCodeViewer` numbers them — enumerated over `CodeSnippetExtractor.extract`
    /// for markdown, and index 0 for a single `.codeBlock` message.
    ///
    /// The two numberings must agree, because a block that crosses the 50-line card threshold
    /// while it streams is opened from the inline button before the threshold and from the
    /// card after it; disagreeing ordinals would leave the user with two tabs for one block,
    /// the older holding the truncated fragment.
    ///
    /// Two byte-identical blocks in one message resolve to the same ordinal (`firstIndex`).
    /// They share a tab, which is what content-equality dedup already did for them.
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

// MARK: - Local Markdown Image

/// A markdown image whose source names a file on disk instead of a URL.
///
/// `AsyncImage` cannot render one — see `ContentBlockView.localImagePath` — so every chart an
/// agent wrote to disk and then referenced showed the "Failed to load image" card. Reads and
/// decodes off-main through `ImageDownsampler`, the same bounded ImageIO path attached images
/// use, so a 12 MB PNG costs a thumbnail rather than a full bitmap on the render thread.
///
/// When the file is missing or isn't decodable it shows a FILE CHIP naming it, not a generic
/// failure card: "this file isn't here any more" is actionable, "failed to load image" is not.
/// The three reasons a chip can carry — including the one for a relative reference the app has
/// no base for — live in `ContentBlockView.localImageFailureText`.
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

        // Only reached when there is nothing to draw, so the extra stat costs nothing that
        // matters and turns one useless card into three distinguishable ones — see
        // `ContentBlockView.localImageFailureText` for why "relative" is one of them.
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
