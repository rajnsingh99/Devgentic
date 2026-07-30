//
//  MarkdownParser.swift
//  Devgentic
//
//  Created by Raj Singh on 20/07/25.
//

import Foundation
import SwiftUI
import Markdown
import os

private let logger = DGLogger(category: "MarkdownParser")

/// Step 3: Stream-Resilient Preprocessor
/// Automatically closes unmatched code blocks to ensure AST parsers (and our UI)
/// render them correctly while streaming, instead of falling back to raw paragraph text.
func preprocessStreamResilientMarkdown(_ text: String) -> String {
    var unclosedCodeBlock = false
    let lines = text.components(separatedBy: .newlines)

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // A standard code block marker. We ignore inline backticks by checking the prefix.
        if trimmed.hasPrefix("```") {
            unclosedCodeBlock.toggle()
        }
    }

    // If we reach the end of the stream and a code block is still open, artificially close it.
    if unclosedCodeBlock {
        return text + "\n```\n"
    }
    return text
}

func preprocessMarkdownText(_ text: String) -> String {
    var processed = text.replacingOccurrences(of: "<br>", with: "\n")

    // If the text looks like a list of paths but isn't properly formatted as a markdown list,
    // we can try to force double newlines to ensure readability in the UI.
    let lines = processed.components(separatedBy: .newlines)
    if lines.count > 3 && lines.filter({ $0.contains("/") }).count > lines.count / 2 {
        processed = lines.joined(separator: "\n\n")
    }

    return processed
}

/// Step 4: swift-markdown AST Mapper
/// Replaces the legacy line-by-line regex parser with a true structural AST traversal.
func parseMarkdown(_ markdown: String) -> [ContentBlock] {
    // 1. Apply the stream-resilient preprocessor to ensure safe parsing
    let safeMarkdown = preprocessStreamResilientMarkdown(markdown)

    // 2. Generate AST using Apple's swift-markdown.
    //
    // `.disableSmartOpts`: cmark's smart punctuation is ON by default and rewrites what
    // the model actually said — `"` → `“”`, `--` → `—`, `...` → `…` — in PROSE. In a chat
    // that carries code and shell commands outside fences (models do this constantly),
    // that's silent corruption: `print("hi")` rendered and RAG-indexed as `print(“hi”)`,
    // so exact-match retrieval on quoted code missed. Prose loses typographic quotes;
    // fidelity to the source wins. (This is also what turned `--- Start of file ---`
    // markers into em dashes — see consumedFileMarker, which still matches both.)
    let document = Document(parsing: safeMarkdown, options: [.disableSmartOpts])

    // 3. Map top-level AST nodes to ContentBlocks
    var pendingFileName: String? = nil
    var blocks = buildContentBlocks(from: document, idOffset: 0, pendingFileName: &pendingFileName)

    // If the AST produced zero blocks but the input was non-empty, the parser silently
    // dropped everything (e.g., deeply malformed markdown). Fall back to rendering the
    // raw text as a paragraph so the user sees *something* instead of a blank bubble.
    if blocks.isEmpty && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let preview = markdown.prefix(120).replacingOccurrences(of: "\n", with: "\\n")
        logger.warning("Markdown AST produced zero blocks for non-empty input (\(markdown.count) chars). Preview: \"\(preview)\". Falling back to raw paragraph.")
        blocks.append(ContentBlock(id: "block-0", type: .paragraph(markdown)))
    }

    return blocks
}

/// Maps a parsed document's top-level nodes to `ContentBlock`s.
///
/// `idOffset` keeps the positional `"block-N"` identities globally consistent when the
/// streaming parser stitches separately-parsed regions together. `pendingFileName`
/// threads the `--- Start of file: X ---` marker across calls for the same reason —
/// the marker paragraph and its code block may settle in different regions.
///
/// Performance: `format()` (re-serializing an AST node back to markdown) runs ONLY for
/// the nodes whose rendering needs it — paragraphs and the unknown-node fallback.
/// The previous implementation formatted EVERY node up front, so a streamed code-heavy
/// answer re-serialized its entire code body on every flush and then ignored the result
/// (code blocks read `codeBlock.code`). That also let a code block whose *content*
/// contained a file-marker line be mistaken for the marker and swallowed entirely.
fileprivate func buildContentBlocks(
    from document: Document,
    idOffset: Int,
    pendingFileName: inout String?
) -> [ContentBlock] {
    var builder = BlockBuilder(
        makeID: { index in "block-\(idOffset + index)" },
        pendingFileName: pendingFileName
    )
    builder.append(children: Array(document.children))
    pendingFileName = builder.pendingFileName
    return builder.blocks
}

// MARK: - Filename Inference

/// Heuristic filename detection for code blocks that carry no explicit
/// `--- Start of file ---` marker.
///
/// Models constantly name the file in ordinary output — an inline-code span right above
/// the fence (`DijkstraSolver.java`), a fence info string (```java DijkstraSolver.java),
/// or a first-line comment (`// DijkstraSolver.java`) — but only the injected marker ever
/// populated `ContentBlock.code`'s `fileName`, so those blocks rendered as "Java Snippet"
/// and their viewer tabs as "Java". This ladder recognizes the common shapes. Confidence
/// order (the marker stays authoritative; see the CodeBlock branch): marker > info string
/// > leading comment > preceding prose.
///
/// Failure is graceful by construction: a missed signal falls back to today's
/// language-only labels, and a false positive costs a cosmetic title — `fileName` never
/// participates in snippet identity (`denotesSameBlock`) or tab dedup.
enum CodeFileNameInference {

    /// Longest prose allowed to claim a filename — a short lead-in like "Here is the
    /// updated `Main.swift`:", not a paragraph that happens to end in one.
    private static let proseClaimLimit = 160

    /// The anchored "looks like a filename" test: `stem.ext` with a letter-led extension
    /// (1–8 chars), optionally path-qualified. Digit-led extensions are rejected so
    /// version strings ("v2.0") can't claim; URLs are rejected outright.
    ///
    /// Accepts the raw token as it appears in prose — wrapped in backticks/bold/quotes,
    /// with trailing punctuation ("`Foo.java`:", "(see Foo.java).") — and returns the
    /// cleaned name, or nil.
    static func filenameToken(_ raw: String) -> String? {
        var token = raw.trimmingCharacters(in: .whitespaces)
        while let last = token.last, ":.,;!?".contains(last) { token.removeLast() }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "`*_\"'()[]<>"))
        while let last = token.last, ":.,;!?".contains(last) { token.removeLast() }
        guard !token.contains("://"), !token.hasPrefix("www.") else { return nil }
        guard token.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9_\-.\/]*\.[A-Za-z][A-Za-z0-9]{0,7}/) != nil else { return nil }
        return token
    }

    /// Splits a fence info string into its language token and an optional filename.
    /// Handles the three conventions models actually emit: a bare second token
    /// (```java DijkstraSolver.java), key=value (```java title=Foo.java), and the
    /// colon form (```js:app.js). The language is the FIRST whitespace token — which
    /// also stops a multi-word info string from leaking whole into the language badge
    /// and the viewer's grammar lookup.
    static func languageAndFileName(fromInfoString info: String) -> (language: String, fileName: String?) {
        let trimmed = info.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ("", nil) }

        var parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        var language = parts.removeFirst()
        var fileName: String? = nil

        if language.contains(":") {
            let pieces = language.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2, let name = filenameToken(pieces[1]) {
                language = pieces[0]
                fileName = name
            }
        }

        if fileName == nil {
            for part in parts {
                var candidate = part
                for key in ["title=", "filename=", "file="] where candidate.lowercased().hasPrefix(key) {
                    candidate.removeFirst(key.count)
                }
                if let name = filenameToken(candidate) {
                    fileName = name
                    break
                }
            }
        }

        // The info string IS the filename (```DijkstraSolver.java) — models do this too.
        // The language token is left as-is (same lookup miss → plain-text grammar as today).
        if fileName == nil, language.contains("."), let name = filenameToken(language) {
            fileName = name
        }

        return (language, fileName)
    }

    /// A first non-empty line that is a comment containing ONLY a filename (optionally
    /// labelled "File:"/"Filename:"). A comment *sentence* mentioning a file must not
    /// claim, so after stripping the comment syntax the remainder has to be the bare
    /// token. Shebangs fail the token test (`!/usr/bin/...`) and never claim.
    static func fromLeadingComment(in code: String) -> String? {
        guard let firstLine = code.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }

        var line = firstLine.trimmingCharacters(in: .whitespaces)
        let openers = ["<!--", "//", "/*", "--", "#", ";", "%", "*"]
        guard let opener = openers.first(where: { line.hasPrefix($0) }) else { return nil }
        line.removeFirst(opener.count)
        for closer in ["*/", "-->"] where line.hasSuffix(closer) { line.removeLast(closer.count) }
        line = line.trimmingCharacters(in: .whitespaces)

        for label in ["filename:", "file:"] where line.lowercased().hasPrefix(label) {
            line.removeFirst(label.count)
        }
        return filenameToken(line.trimmingCharacters(in: .whitespaces))
    }

    /// Short prose (or a heading) whose LAST word is a filename — "`DijkstraSolver.java`"
    /// alone above a fence, or "Here is the updated `Main.swift`:". Ends-with is the
    /// discriminator: a mid-sentence mention ("I changed Foo.java and then…") ends on a
    /// different word and never claims.
    static func fromTrailingProse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= proseClaimLimit else { return nil }
        guard let lastWord = trimmed.split(whereSeparator: \.isWhitespace).last else { return nil }
        return filenameToken(String(lastWord))
    }
}

/// Maps swift-markdown AST nodes to `ContentBlock`s, recursing into containers
/// (list items, blockquotes) rather than flattening their children to raw markdown.
///
/// `makeID` produces each block's identity from its sibling index, so top-level blocks
/// stay `"block-N"` (the streaming parser's settled-region stitching and its tests
/// depend on that) while nested blocks get `"<parent>.N"`.
private struct BlockBuilder {
    let makeID: (Int) -> String
    var blocks: [ContentBlock] = []
    /// Threads a filename claim across siblings (and across separately-parsed streaming
    /// regions) so the next code block can consume it. Set by the explicit
    /// `--- Start of file: X ---` marker AND by `CodeFileNameInference`'s prose/heading
    /// signal; the nearest claim wins and every fence clears it.
    var pendingFileName: String?

    init(makeID: @escaping (Int) -> String, pendingFileName: String?) {
        self.makeID = makeID
        self.pendingFileName = pendingFileName
    }

    private mutating func append(_ type: ContentBlock.BlockType) {
        blocks.append(ContentBlock(id: makeID(blocks.count), type: type))
    }

    /// File-marker handling for text-bearing nodes. Returns true when the node WAS a
    /// marker (already consumed — the caller should skip it).
    ///
    /// Matches `---` OR an em dash `—`, and BOTH branches are load-bearing:
    /// - `---` is what arrives now that parsing passes `.disableSmartOpts` (and what the
    ///   backend literally injects).
    /// - `—` is what a marker became in the smart-punctuation era — cmark rewrote `---`
    ///   during parsing, which silently broke the original `---`-only regex — and it
    ///   still arrives via user text typed while the composer had smart dashes enabled.
    ///   Dropping that branch would orphan those messages' filename badges.
    private mutating func consumedFileMarker(_ text: String) -> Bool {
        if let match = text.firstMatch(of: /(?:---|—)\s*Start of file:\s*(.*?)\s*(?:---|—)/) {
            pendingFileName = String(match.1)
            return true
        }
        if text.contains("--- End of file:") || text.contains("— End of file:") {
            pendingFileName = nil
            return true
        }
        return false
    }

    mutating func append(children: [Markup]) {
        for child in children {
            append(node: child)
        }
    }

    private mutating func append(node child: Markup) {
        if let paragraph = child as? Paragraph {
            // Standalone images are often wrapped inside a single Paragraph node
            if paragraph.childCount == 1,
               let image = paragraph.child(at: 0) as? Markdown.Image {
                append(.image(url: image.source ?? "", altText: image.plainText))
                return
            }
            // Marker detection uses plainText, NOT format(): the formatter escapes a
            // leading "---" (to `\-\-\-`, since re-parsing it would read as a thematic
            // break), which silently defeated the regex ever since the AST migration.
            let plain = paragraph.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if consumedFileMarker(plain) { return }
            // Prose filename claim ("`DijkstraSolver.java`" above a fence). Unlike the
            // marker the paragraph stays VISIBLE — it's the model's own prose, not an
            // injected sentinel to hide. plainText again: no backtick/bold markers.
            if let inferred = CodeFileNameInference.fromTrailingProse(plain) {
                pendingFileName = inferred
                logger.debug("[FILENAME] Prose claim '\(inferred)' pending for next code block.")
            }
            let text = paragraph.format().trimmingCharacters(in: .whitespacesAndNewlines)
            append(.paragraph(preprocessMarkdownText(text)))
        }
        else if let codeBlock = child as? CodeBlock {
            // Confidence ladder: the explicit marker (or a prose/heading claim) outranks
            // the fence's own info string, which outranks a first-line comment. The
            // marker must stay on top — it's what source-file linking resolves by name,
            // and letting a weaker signal rename a linked block would break that lookup.
            let (language, infoFileName) = CodeFileNameInference.languageAndFileName(fromInfoString: codeBlock.language ?? "")
            let fileName = pendingFileName
                ?? infoFileName
                ?? CodeFileNameInference.fromLeadingComment(in: codeBlock.code)
            append(.code(language: language, content: codeBlock.code, fileName: fileName))
            pendingFileName = nil
        }
        else if let heading = child as? Heading {
            // A heading that IS a filename ("### DijkstraSolver.java") claims like prose.
            if let inferred = CodeFileNameInference.fromTrailingProse(heading.plainText) {
                pendingFileName = inferred
                logger.debug("[FILENAME] Heading claim '\(inferred)' pending for next code block.")
            }
            append(.heading(level: heading.level, text: heading.plainText))
        }
        else if child is ThematicBreak {
            append(.horizontalRule)
        }
        else if let list = child as? UnorderedList {
            append(listItems: Array(list.listItems), ordered: false, start: 1)
        }
        else if let list = child as? OrderedList {
            append(listItems: Array(list.listItems), ordered: true, start: Int(list.startIndex))
        }
        else if let quote = child as? BlockQuote {
            // Previously fell through to the `else` fallback below, which stringified
            // the whole quote via format(); AttributedString then ate the `>` markers
            // and the quote rendered as indistinguishable body prose.
            let id = makeID(blocks.count)
            var nested = BlockBuilder(makeID: { "\(id).\($0)" }, pendingFileName: pendingFileName)
            nested.append(children: Array(quote.children))
            pendingFileName = nested.pendingFileName
            blocks.append(ContentBlock(id: id, type: .blockquote(blocks: nested.blocks)))
        }
        else if let table = child as? Markdown.Table {
            let headers: [String] = table.head.cells.map { cell in
                cell.children.map { $0.format() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let rows: [[String]] = table.body.rows.map { row in
                row.cells.map { cell in
                    cell.children.map { $0.format() }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            // cmark parsed `:--` / `:-:` / `--:` all along; we simply never read it, so an
            // author's right-aligned numbers rendered left. `nil` = unspecified, which GFM
            // renders leading.
            let alignments: [ContentBlock.ColumnAlignment] = table.columnAlignments.map { alignment in
                switch alignment {
                case .left:   return .leading
                case .center: return .center
                case .right:  return .trailing
                case nil:     return .leading
                }
            }
            append(.table(headers: headers, rows: rows, alignments: alignments))
        }
        else {
            // Fallback for HTML blocks or other unknown types
            let text = child.format().trimmingCharacters(in: .whitespacesAndNewlines)
            if consumedFileMarker(text) { return }
            append(.paragraph(preprocessMarkdownText(text)))
        }
    }

    /// Emits one `.listItem` per item, carrying EVERYTHING the item contains as child
    /// blocks in DOCUMENT ORDER — including any nested list, which recurses naturally
    /// through `append(children:)` back into this method.
    ///
    /// An earlier version split the children into "own content" vs "nested lists" and
    /// emitted the own content first, flattening nested items to siblings. That
    /// reordered the output: a fence written *after* the sub-bullets rendered *above*
    /// them. Preserving the AST's child order is the whole point.
    private mutating func append(listItems: [ListItem], ordered: Bool, start: Int) {
        for (offset, item) in listItems.enumerated() {
            let id = makeID(blocks.count)
            var nested = BlockBuilder(makeID: { "\(id).\($0)" }, pendingFileName: pendingFileName)
            nested.append(children: Array(item.children))
            pendingFileName = nested.pendingFileName

            let checkbox: ContentBlock.Checkbox? = item.checkbox.map { $0 == .checked ? .checked : .unchecked }
            // A task item's marker is the checkbox itself; keep the bullet for the rest.
            let prefix = ordered ? "\(start + offset)." : "•"

            blocks.append(ContentBlock(
                id: id,
                type: .listItem(prefix: prefix, blocks: nested.blocks, checkbox: checkbox)
            ))
        }
    }
}

// MARK: - Incremental Streaming Parser

/// Incremental markdown parser for a message that is still streaming.
///
/// The full-reparse-per-flush pipeline was O(n²) over a response: every flush
/// (~0.05–0.2s) rebuilt the swift-markdown AST for the ENTIRE accumulated text on
/// the main thread. But streamed text only ever grows by appending, so markdown
/// already delivered can't change — with one caveat: the block containing the
/// insertion point can. This parser exploits that:
///
///  - Regions ending at a **blank line outside any code fence** are *settled*:
///    they're parsed once, their blocks cached, and never touched again.
///  - Only the trailing *active* region (after the last such boundary — typically
///    the one block currently being streamed) re-parses on each flush.
///  - Positional `"block-N"` ids stay globally stable, so `ContentBlockView`'s
///    `.equatable()` memoization skips every settled block.
///
/// Known mid-stream cosmetic deviations from a full parse (all self-healing —
/// callers MUST run one full `parseMarkdown` when streaming ends, which
/// `ChatMessage.getOrCreateMarkdownBlocks` does):
///  - an indented (4-space) code block or multi-blank-line HTML block spanning a
///    blank line renders as two blocks until completion;
///  - a reference-style link whose `[id]: url` definition hasn't streamed in yet
///    renders literally until completion.
///
/// Not thread-safe; used from the main-actor render path only.
final class StreamingMarkdownParser {

    private var consumedPrefix: String = ""
    /// Cached `consumedPrefix.count` — `String.count` is O(n), and we need it per flush.
    private var consumedPrefixCharCount: Int = 0
    private var prefixBlocks: [ContentBlock] = []
    /// File-marker state carried across settled regions (marker paragraph and its
    /// code block may arrive in different flushes).
    private var pendingFileName: String? = nil

    /// Parses the full accumulated text, reusing blocks for already-settled regions.
    /// Safe for arbitrary input: if `fullText` is not an append to what was consumed
    /// before (regeneration, error replacement), the parser resets and starts over.
    func parse(_ fullText: String) -> [ContentBlock] {
        if !fullText.hasPrefix(consumedPrefix) {
            reset()
        }

        var tailStart = fullText.index(fullText.startIndex, offsetBy: consumedPrefixCharCount)

        // Advance the settled boundary to the last blank line (outside a code fence)
        // in the unconsumed tail. Everything before it can never re-parse differently
        // under our flattened block model, so parse it once and lock it in.
        if let cut = Self.lastSafeBoundary(in: fullText[tailStart...]) {
            let settled = String(fullText[tailStart..<cut])
            if !settled.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Fences inside a settled region are balanced by construction (the
                // boundary scanner never cuts inside one), so no preprocessor needed.
                let document = Document(parsing: settled, options: [.disableSmartOpts])
                prefixBlocks += buildContentBlocks(
                    from: document,
                    idOffset: prefixBlocks.count,
                    pendingFileName: &pendingFileName
                )
            }
            consumedPrefix += settled
            consumedPrefixCharCount += settled.count
            tailStart = cut
        }

        // Re-parse only the active region. Copy the marker state — the active region
        // is transient and will be parsed again next flush (or settle later).
        let active = String(fullText[tailStart...])
        var activeBlocks: [ContentBlock] = []
        if !active.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var transientFileName = pendingFileName
            let document = Document(parsing: preprocessStreamResilientMarkdown(active), options: [.disableSmartOpts])
            activeBlocks = buildContentBlocks(
                from: document,
                idOffset: prefixBlocks.count,
                pendingFileName: &transientFileName
            )
        }

        var result = prefixBlocks + activeBlocks

        // Mirror parseMarkdown's non-empty-input fallback so a malformed stream
        // still shows raw text instead of a blank bubble.
        if result.isEmpty && !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = [ContentBlock(id: "block-0", type: .paragraph(fullText))]
        }
        return result
    }

    private func reset() {
        consumedPrefix = ""
        consumedPrefixCharCount = 0
        prefixBlocks = []
        pendingFileName = nil
    }

    /// Index just past the last completed blank line that sits outside any ``` fence,
    /// or nil if the tail contains no safe boundary yet. Uses the same fence heuristic
    /// as `preprocessStreamResilientMarkdown` (trimmed `hasPrefix("```")` toggles) so
    /// the two stages can't disagree about what's inside a fence.
    static func lastSafeBoundary(in tail: Substring) -> Substring.Index? {
        var inFence = false
        var lastCut: Substring.Index? = nil
        var lineStart = tail.startIndex

        while lineStart < tail.endIndex {
            let newlineIndex = tail[lineStart...].firstIndex(of: "\n")
            let lineContentEnd = newlineIndex ?? tail.endIndex
            let nextLineStart = newlineIndex.map { tail.index(after: $0) } ?? tail.endIndex

            let trimmed = tail[lineStart..<lineContentEnd].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
            } else if trimmed.isEmpty, !inFence, newlineIndex != nil {
                // A COMPLETED blank line (has its newline) outside any fence.
                lastCut = nextLineStart
            }

            lineStart = nextLineStart
        }
        return lastCut
    }
}
