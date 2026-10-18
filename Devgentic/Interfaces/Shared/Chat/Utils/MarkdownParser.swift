// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MarkdownParser.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI
import Markdown
import os

private let logger = DGLogger(category: "MarkdownParser")

// Why: a block opened by a longer run stays open across shorter inner fences, so a boolean toggle ends the block early.
/// A line's leading backtick run when the line is a fence marker, and whether it carries an info string.
/// Only a bare run can close a fence; an info-string run (```swift) only opens one.
struct MarkdownFenceMarker {
    let run: Int
    let hasInfo: Bool
}

func markdownFenceMarker(inTrimmedLine trimmed: String) -> MarkdownFenceMarker? {
    var run = 0
    var index = trimmed.startIndex
    while index < trimmed.endIndex, trimmed[index] == "`" {
        run += 1
        index = trimmed.index(after: index)
    }
    guard run >= 3 else { return nil }
    return MarkdownFenceMarker(run: run, hasInfo: index < trimmed.endIndex)
}

/// Closes unmatched code blocks so AST parsers and the UI render them while streaming.
/// The closer uses a backtick run of the opening length, so longer fences are closed correctly.
func preprocessStreamResilientMarkdown(_ text: String) -> String {
    var openFenceRun: Int? = nil

    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = markdownFenceMarker(inTrimmedLine: trimmed) else { continue }
        if let open = openFenceRun {
            // Only an equal-or-longer BARE run closes.
            if marker.run >= open, !marker.hasInfo { openFenceRun = nil }
        } else {
            openFenceRun = marker.run
        }
    }

    // If we reach the end of the stream and a code block is still open, artificially close it.
    if let open = openFenceRun {
        return text + "\n" + String(repeating: "`", count: open) + "\n"
    }
    return text
}

// Why: a soft break renders as a space; only two spaces plus newline survive `AttributedString(markdown:)`.
/// Rewrites every spelling of an HTML line break (`<br>`, `<br/>`, `<br />`, `<BR>`) to a markdown hard break.
/// Applies only outside code spans and fenced blocks, which are content and never rewritten.
func rewritingHTMLLineBreaks(_ text: String) -> String {
    guard text.contains("`") else { return rewritingBreaksInProse(text) }
    // Splits on backtick runs: a run opens a span that only an equal-length run closes.
    // An odd trailing run (unclosed span) leaves the tail as prose.
    var result = ""
    var index = text.startIndex
    var insideFence: String? = nil          // the run that opened the current span
    var segment = ""
    while index < text.endIndex {
        guard text[index] == "`" else {
            segment.append(text[index])
            index = text.index(after: index)
            continue
        }
        var run = ""
        while index < text.endIndex, text[index] == "`" {
            run.append(text[index])
            index = text.index(after: index)
        }
        if let open = insideFence {
            // Inside a span: only an equal-length run closes it. Content passes through raw.
            segment.append(run)
            if run == open {
                result += segment
                segment = ""
                insideFence = nil
            }
        } else {
            result += rewritingBreaksInProse(segment)
            segment = run
            insideFence = run
        }
    }
    // An unterminated run never opened a span at all — CommonMark leaves an unmatched
    // backtick as literal text — so the tail is prose and its breaks still count.
    result += rewritingBreaksInProse(segment)
    return result
}

private func rewritingBreaksInProse(_ text: String) -> String {
    // Why: adjacent hard breaks plus a newline form a paragraph break, which renders as nothing and fuses the words.
    // A run of breaks collapses to one hard break, consuming any newline that follows the run.
    // Horizontal whitespace is consumed only as part of a newline, never on its own.
    text.replacingOccurrences(
        of: "<br[ \t]*/?>(?:[ \t]*\n?[ \t]*<br[ \t]*/?>)*(?:[ \t]*\n)?",
        with: "  \n",
        options: [.regularExpression, .caseInsensitive]
    )
}

func preprocessMarkdownText(_ text: String) -> String {
    var processed = rewritingHTMLLineBreaks(text)

    // If the text looks like a list of paths but is not a markdown list, forces real line breaks per path.
    // The separator must remain a hard break ("  \n"); a paragraph break would fuse the paths.
    let lines = processed.components(separatedBy: .newlines)
    if lines.count > 3 && lines.filter({ $0.contains("/") }).count > lines.count / 2 {
        processed = lines.joined(separator: "  \n")
    }

    return processed
}

/// Parses markdown into content blocks by mapping the swift-markdown AST.
func parseMarkdown(_ markdown: String) -> [ContentBlock] {
    // 1. Apply the stream-resilient preprocessor to ensure safe parsing
    let safeMarkdown = preprocessStreamResilientMarkdown(markdown)

    // Why: smart punctuation rewrites quotes and dashes in prose, silently corrupting code shown outside fences.
    // Generates the AST with swift-markdown, with smart punctuation disabled.
    let document = Document(parsing: safeMarkdown, options: [.disableSmartOpts])

    // 3. Map top-level AST nodes to ContentBlocks
    var pendingFileName: PendingFileNameClaim? = nil
    var blocks = buildContentBlocks(from: document, idOffset: 0, pendingFileName: &pendingFileName)

    // Falls back to rendering the raw text as a paragraph when the AST produced no blocks for non-empty input.
    // Skipped when the input is nothing but file markers, which are consumed on purpose; computed lazily for cost.
    if blocks.isEmpty, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if !FileMarkerLine.isNothingButFileMarkers(markdown) {
            let preview = markdown.prefix(120).replacingOccurrences(of: "\n", with: "\\n")
            logger.warning("Markdown AST produced zero blocks for non-empty input (\(markdown.count) chars). Preview: \"\(preview)\". Falling back to raw paragraph.")
            blocks.append(ContentBlock(id: "block-0", type: .paragraph(markdown)))
        } else {
            // Why: debug is not sanitized for egress and a marker can carry an absolute path.
            // Logs the deliberate empty render at debug level, reporting counts and never a preview of the text.
            logger.debug("[RENDER] Markdown consumed entirely as file-marker sentinels — \(markdown.count) chars in, 0 blocks out, every line was a '--- Start/End of file: … ---' sentinel. CONSEQUENCE: this message renders as an EMPTY bubble. Expected when the text really was nothing but sentinels; if content was expected, suspect upstream truncation, or a sentinel whose closing dashes are not followed by whitespace (that line is dropped whole rather than having its span removed).")
        }
    }

    return blocks
}

/// Maps a parsed document's top-level nodes to `ContentBlock`s.
/// `idOffset` keeps positional block ids consistent across streaming regions; `pendingFileName` threads a
/// file marker across calls. `format()` runs only for paragraphs and the unknown-node fallback.
fileprivate func buildContentBlocks(
    // Module-qualified because SwiftUI also exports a `Document` type and this file imports both.
    from document: Markdown.Document,
    idOffset: Int,
    pendingFileName: inout PendingFileNameClaim?
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

// Why: a wrong inferred name can link a fence to a real attached file and enable Apply Changes (a disk write).
/// Infers a filename for code blocks with no explicit file marker, from an info string, comment or prose.
/// Precedence: marker, info string, leading comment, prose; a missed signal falls back to language-only labels.
enum CodeFileNameInference {

    /// Longest prose allowed to claim a filename — a short lead-in like "Here is the
    /// updated `Main.swift`:", not a paragraph that happens to end in one. Kept as a
    /// second gate alongside the markup requirement in `fromTrailingProse`.
    private static let proseClaimLimit = 160

    // Why: runs on the captured label; normalising the marker text drops legal characters such as backslashes.
    /// Reduces a decorated marker label like `Foo.swift (/abs/path/Foo.swift)` to `Foo.swift`; else returns it as is.
    /// The parenthesised path's last component must equal the leading name, so `snapshot (~/Documents)` survives.
    static func nameFromMarkerLabel(_ label: String) -> String {
        guard label.hasSuffix(")") else { return label }

        // Walk back from the close paren to its partner so nested parens in the NAME can't
        // confuse the split.
        var depth = 0
        var open: String.Index? = nil
        var index = label.endIndex
        while index > label.startIndex {
            index = label.index(before: index)
            let character = label[index]
            if character == ")" {
                depth += 1
            } else if character == "(" {
                depth -= 1
                if depth == 0 { open = index; break }
            }
        }
        guard let open else { return label }

        let inner = String(label[label.index(after: open)..<label.index(before: label.endIndex)])
        guard inner.hasPrefix("/") || inner.hasPrefix("~/") else { return label }

        let name = String(label[label.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, (inner as NSString).lastPathComponent == name else { return label }
        return name
    }

    /// The anchored filename test: `stem.ext` with a letter-led extension (1-8 chars), optionally path-qualified.
    /// Accepts the raw prose token with surrounding markup and trailing punctuation, returning the cleaned name or nil.
    static func filenameToken(_ raw: String) -> String? {
        var token = strippingTrailingPunctuation(raw.trimmingCharacters(in: .whitespaces))
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "`*_\"'()[]<>"))
        token = strippingTrailingPunctuation(token)
        guard !token.contains("://"), !token.hasPrefix("www.") else { return nil }
        guard token.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9_\-.\/]*\.[A-Za-z][A-Za-z0-9]{0,7}/) != nil else { return nil }
        return token
    }

    /// Strips trailing sentence punctuation, except a `.` directly after a letter or digit.
    /// That dot belongs to an abbreviation ("e.g."); stripping it would manufacture a fake extension.
    private static func strippingTrailingPunctuation(_ input: String) -> String {
        var token = input
        while let last = token.last, ":.,;!?".contains(last) {
            if last == "." {
                let lastIndex = token.index(before: token.endIndex)
                if lastIndex > token.startIndex {
                    let preceding = token[token.index(before: lastIndex)]
                    if preceding.isLetter || preceding.isNumber { break }
                }
            }
            token.removeLast()
        }
        return token
    }

    // Why: rejecting any uppercase extension would un-name real files such as `script.R` and `README.MD`.
    /// `filenameToken` plus the prose-only shape test: the token must not be a fully-qualified identifier.
    /// Dotted three or more deep ending in a Pascal-cased segment (`java.util.List`) is rejected.
    private static func plausibleFilenameToken(_ raw: String) -> String? {
        guard let token = filenameToken(raw) else { return nil }
        let ext = (token as NSString).pathExtension
        let endsInPascalCasedSegment = ext.first?.isUppercase == true
            && ext.dropFirst().contains(where: \.isLowercase)
        guard !(endsInPascalCasedSegment && token.split(separator: ".").count >= 3) else { return nil }
        return token
    }

    /// Reduces a labelled claim inside the author's markup ("**File: src/Main.java**") to the token it labels.
    /// Only the single token after the last colon counts, which keeps a bolded sentence out.
    private static func labelledFilenameToken(_ raw: String) -> String? {
        if let direct = plausibleFilenameToken(raw) { return direct }
        guard let colon = raw.lastIndex(of: ":") else { return nil }
        let label = raw[raw.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let remainder = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // The label must be a plain word: no slash or dot, so a URL's `host:port/path` is not split on its colon.
        guard !label.isEmpty,
              !label.contains("/"), !label.contains("."),
              !remainder.contains(where: \.isWhitespace) else { return nil }
        return plausibleFilenameToken(remainder)
    }

    /// Splits a fence info string into its language token and an optional filename.
    /// Handles a bare second token, `key=value` (title=Foo.java) and the colon form (js:app.js).
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

        // The info string is the filename: the language is derived from the extension, so the header does not echo the filename.
        // An unknown extension yields the bare extension.
        if fileName == nil, language.contains("."), let name = filenameToken(language) {
            fileName = name
            language = CodeSnippet.languageHint(forFileName: name) ?? ""
        }

        return (language, fileName)
    }

    /// Reads a first non-empty line that is a comment containing only a filename, optionally labelled "File:"/"Filename:".
    /// A comment sentence mentioning a file does not claim; shebangs never claim.
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

    // Why: ordinary prose ending in a filename-shaped word ("Node.js:") would otherwise claim the file badge.
    /// Reads short prose that deliberately names a file at its end, such as "`Main.swift`:" above a fence.
    /// The trailing token must arrive as an inline-code span or bold run; a label inside the marked-up run is stepped over.
    static func fromTrailingProse(in paragraph: Paragraph) -> String? {
        guard paragraph.plainText.count <= proseClaimLimit else { return nil }
        return emphasizedTrailingToken(in: paragraph)
    }

    // Why: the label fallback is not used here: a heading carries no markup signal of its own.
    /// A heading that claims a filename for the fence below it.
    /// A heading that is entirely a filename-shaped word claims without markup; otherwise the trailing token
    /// must be marked up. A one-word framework heading (`## Node.js`) therefore claims, an accepted false positive.
    static func fromHeading(_ heading: Heading) -> String? {
        let plain = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, plain.count <= proseClaimLimit else { return nil }
        if let wholeHeading = plausibleFilenameToken(plain) { return wholeHeading }
        return emphasizedTrailingToken(in: heading)
    }

    /// The filename in the container's last marked-up inline (inline code or bold), or nil.
    /// Walks children backwards over trailing punctuation and line breaks; any other first content child stops the walk.
    private static func emphasizedTrailingToken(in container: some Markup) -> String? {
        for child in container.children.reversed() {
            if let text = child as? Markdown.Text {
                let trimmed = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
                // A colon, a period or a closing bracket after the claim is normal prose.
                if trimmed.isEmpty || trimmed.allSatisfy({ ":.,;!?)]}".contains($0) }) { continue }
                return nil
            }
            if child is SoftBreak || child is LineBreak { continue }
            if let code = child as? InlineCode { return labelledFilenameToken(code.code) }
            if let strong = child as? Strong { return labelledFilenameToken(strong.plainText) }
            return nil
        }
        return nil
    }
}

// Why: a value type on purpose: the streaming parser's active-region copy must not alias permanent state.
/// Maps swift-markdown AST nodes to `ContentBlock`s, recursing into containers such as list items and blockquotes.
/// `makeID` derives each block's id from its sibling index: top-level `"block-N"`, nested `"<parent>.N"`.
/// Carries a pending filename claim and its origin; marker claims span a file body, inferred claims are bounded.
struct PendingFileNameClaim: Equatable {
    enum Origin: Equatable {
        /// An injected `--- Start of file: X ---` sentinel. Spans multiple blocks BY DESIGN.
        case marker
        /// A heading that is, or ends in, a filename.
        case heading
        /// A short paragraph ending in a marked-up filename token.
        case prose
    }

    let name: String
    let origin: Origin
}

// Why: detection gates the strip; a line stripped but not detected would render the raw sentinel.
/// The single definition of "this line is an injected file-marker sentinel".
/// Detection and `strippingFileMarkerLines` both call `kind(of:)` so they agree on which lines are sentinels.
enum FileMarkerLine: Equatable {
    case start
    case end

    // Why: backslashes are removed for the test only and the raw line is kept; raw text can still carry them.
    /// The marker kind this line is, or nil for every other line.
    /// Tests begins-with, not contains, so prose that merely mentions a marker keeps its whole line.
    static func kind(of line: some StringProtocol) -> FileMarkerLine? {
        let bare = line.replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard bare.hasPrefix("---") || bare.hasPrefix("—") else { return nil }
        if bare.contains("Start of file:") { return .start }
        if bare.contains("End of file:") { return .end }
        return nil
    }

    // Why: Swift treats "\r\n" as one Character, so splitting on "\n" sees an all-CRLF document as one line.
    /// The lines of a text, CRLF included.
    static func lines<S: StringProtocol>(of text: S) -> [S.SubSequence] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// A line split into its block-quote / indent prefix and the body after it.
    /// `>` is the only non-whitespace prefix character that `format()` adds.
    static func quotePrefixSplit<S: StringProtocol>(_ line: S) -> (prefix: S.SubSequence, body: S.SubSequence) {
        let start = line.firstIndex(where: { $0 != ">" && $0 != " " && $0 != "\t" }) ?? line.endIndex
        return (line[line.startIndex..<start], line[start...])
    }

    // Why: the `(?=\s|$)` lookahead stops the lazy match at a `---` inside a filename.
    /// The sentinel span inside a line, which `strippingFileMarkerLines` removes.
    /// Deliberately separate from the capture regex in `consumedFileMarker`, which names a file the app writes to.
    static let sentinelSpan = /(?:---|—)\s*(?:Start|End) of file:\s*.*?\s*(?:---|—)(?=\s|$)/

    /// Whether every non-blank line of `text` is a sentinel line.
    /// Answers emptiness on raw text, separately from the render question `strippingFileMarkerLines` answers.
    static func isNothingButFileMarkers(_ text: some StringProtocol) -> Bool {
        var sawContent = false
        for line in lines(of: text) {
            let body = quotePrefixSplit(line).body
            if body.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            sawContent = true
            if kind(of: body) == nil { return false }
        }
        return sawContent
    }

    /// A node's plain text with its line structure intact: soft and hard breaks are restored as newlines.
    /// `plainText` flattens breaks and `format()` adds block-quote prefixes, so neither suits a line-anchored test.
    static func lineStructuredPlainText(of markup: Markup) -> String {
        markup.children.map { child -> String in
            if child is SoftBreak || child is LineBreak { return "\n" }
            if child is InlineContainer, child.childCount > 0 { return lineStructuredPlainText(of: child) }
            return (child as? PlainTextConvertibleMarkup)?.plainText ?? ""
        }.joined()
    }
}

private struct BlockBuilder {
    let makeID: (Int) -> String
    var blocks: [ContentBlock] = []
    /// Threads a filename claim across siblings and streaming regions so the next code block can consume it.
    /// Set by the file marker and by prose/heading inference; the nearest claim wins and every fence clears it.
    var pendingFileName: PendingFileNameClaim?

    init(makeID: @escaping (Int) -> String, pendingFileName: PendingFileNameClaim?) {
        self.makeID = makeID
        self.pendingFileName = pendingFileName
    }

    private mutating func append(_ type: ContentBlock.BlockType) {
        blocks.append(ContentBlock(id: makeID(blocks.count), type: type))
    }

    /// Applies a file marker's claim to this node and returns true when a marker was found.
    /// Matches `---` or an em dash, since markers typed with smart dashes still arrive; non-marker content is kept.
    private mutating func consumedFileMarker(lineStructured: String, flattened: String) -> Bool {
        // The Start branch is line-anchored via the predicate `strippingFileMarkerLines` uses, so quoted prose cannot arm one.
        // The text is not normalised before matching: the captured name becomes the claim and keeps backslashes.
        let lines = lineStructured.split(separator: "\n", omittingEmptySubsequences: false)
        if let index = lines.firstIndex(where: { FileMarkerLine.kind(of: $0) == .start }) {
            // Matches from this line onward, rejoined: a long agent label can wrap before the closing dashes.
            // Starting at this line keeps an earlier mid-sentence mention from winning the capture.
            let fromMarker = lines[index...].joined(separator: " ")
            if let match = fromMarker.firstMatch(of: /(?:---|—)\s*Start of file:\s*(.*?)\s*(?:---|—)/) {
                let label = String(match.1)
                let name = CodeFileNameInference.nameFromMarkerLabel(label)
                if name != label {
                    // Logs the bare name and a length, never the label, which carries the user's absolute path.
                    // `DGLogger.debug` does not sanitize for egress.
                    logger.debug("[FILENAME] Marker label carried its own absolute path (\(label.count) chars) — agent and code profiles disclose it so the model can write back to the right file. Linking by the bare name '\(name)'. CONSEQUENCE: none intended; the decorated label matched no attachment, so the fence had no badge, no source link and no Apply Changes.")
                }
                pendingFileName = PendingFileNameClaim(name: name, origin: .marker)
            }
            // Returns true even without a closer: the shared predicate marks this line a sentinel and it will be stripped.
            return true
        }
        // The End branch stays unanchored on purpose: over-clearing only costs a badge, and it must work inside block quotes.
        if flattened.contains("--- End of file:") || flattened.contains("— End of file:") {
            pendingFileName = nil
            return true
        }
        return false
    }

    // Why: the line predicate is shared with `consumedFileMarker`'s Start branch so detection and stripping agree.
    /// Removes the marker lines, keeping every other line verbatim; only the sentinel span goes, so trailing prose survives.
    /// Inside a block quote the test runs on the body after the `> ` prefix, which is restored on output.
    /// Cases the span cannot resolve cleanly fall back to the line-drop behaviour.
    static func strippingFileMarkerLines(from text: String) -> String {
        var kept: [String] = []
        for line in FileMarkerLine.lines(of: text) {
            let (prefix, body) = FileMarkerLine.quotePrefixSplit(line)
            guard FileMarkerLine.kind(of: body) != nil else { kept.append(String(line)); continue }

            // The line-drop predicate on the whole line; anything the span removal cannot clean lands here.
            let todayWouldDropTheLine = FileMarkerLine.kind(of: line) != nil
            func fallBackToTodaysBehaviour() {
                if !todayWouldDropTheLine { kept.append(String(line)) }
            }

            let cleaned = body.replacing(FileMarkerLine.sentinelSpan, with: "")
            // No span matched — an unterminated marker, or one whose closer the lookahead
            // rejected. There is no way to tell sentinel from prose here.
            guard cleaned != body else { fallBackToTodaysBehaviour(); continue }
            // A stranded half-sentinel: one marker's closer was eaten as another's opener. Never
            // publish that.
            guard !cleaned.contains("Start of file:"), !cleaned.contains("End of file:") else {
                fallBackToTodaysBehaviour(); continue
            }

            let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
            // The body was NOTHING but the sentinel: drop the line. Nothing an author wrote is
            // lost, and this is the case that closes CR61 for the ordinary quoted marker.
            if trimmed.isEmpty { continue }
            // A residue with no letter or digit is leftover punctuation from the sentinel and is not published.
            guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else {
                fallBackToTodaysBehaviour(); continue
            }
            kept.append(String(prefix) + trimmed)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func append(children: [Markup]) {
        for child in children {
            let claimed = append(node: child)

            // Why: marker claims wrap a whole file body and must outlive every block in between.
            // An inferred (prose) claim reaches only its own neighbourhood: it is cleared on the first sibling that does not claim.
            // Measured in sibling nodes, not parse regions; marker and heading claims are exempt.
            if !claimed, let claim = pendingFileName, claim.origin == .prose {
                pendingFileName = nil
                logger.debug("[FILENAME] Prose claim '\(claim.name)' dropped — the next block made no claim of its own and was not a fence, so the claim does not reach past it.")
            }
        }
    }

    private mutating func append(node child: Markup) -> Bool {
        // Whether this node made a claim, so `append(children:)` can bound an inferred claim without comparing claim values.
        var didClaim = false
        if let paragraph = child as? Paragraph {
            // A paragraph carrying any image is split at its images: text runs become `.paragraph`s, each image an `.image`.
            // The flat text is a cheap gate; `format()` is avoided because it adds `> ` prefixes and re-emits inline markup.
            let plain = paragraph.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            // The marker claim is applied either way; only a node that is nothing but the marker disappears.
            // Applied before the image split so a marker paragraph carrying an image does not print the sentinel.
            let mayCarryMarker = plain.contains("Start of file:") || plain.contains("End of file:")
            let hadMarker = mayCarryMarker
                ? consumedFileMarker(lineStructured: FileMarkerLine.lineStructuredPlainText(of: paragraph),
                                     flattened: plain)
                : false
            didClaim = didClaim || hadMarker
            if paragraph.children.contains(where: { Self.imageChild($0) != nil }) {
                appendSplittingImages(in: paragraph, stripMarkers: hadMarker)
                return didClaim
            }
            if hadMarker {
                // Escapes leading block syntax in the remainder, as `appendTextRun` does, so a leading `1.` or `#` is not parsed.
                let remainder = Self.escapingLeadingBlockSyntax(Self.strippingFileMarkerLines(
                    from: paragraph.format().trimmingCharacters(in: .whitespacesAndNewlines)))
                if remainder.isEmpty { return didClaim }
                logger.debug("[FILENAME] File marker stripped from a paragraph that also carried \(remainder.count) chars of content — the content is kept.")
                append(.paragraph(preprocessMarkdownText(remainder)))
                return didClaim
            }
            // Prose filename claim: the paragraph stays visible, and the AST node is passed so the author's markup is checked.
            if let inferred = CodeFileNameInference.fromTrailingProse(in: paragraph) {
                pendingFileName = PendingFileNameClaim(name: inferred, origin: .prose)
                didClaim = true
                logger.debug("[FILENAME] Prose claim '\(inferred)' pending for next code block.")
            }
            let text = paragraph.format().trimmingCharacters(in: .whitespacesAndNewlines)
            append(.paragraph(preprocessMarkdownText(text)))
        }
        else if let codeBlock = child as? CodeBlock {
            // Precedence: the marker or a prose/heading claim outranks the info string, which outranks a first-line comment.
            // The marker stays on top because source-file linking resolves by name.
            let (language, infoFileName) = CodeFileNameInference.languageAndFileName(fromInfoString: codeBlock.language ?? "")
            let fileName = pendingFileName?.name
                ?? infoFileName
                ?? CodeFileNameInference.fromLeadingComment(in: codeBlock.code)
            append(.code(language: language, content: codeBlock.code, fileName: fileName))
            pendingFileName = nil
        }
        else if let heading = child as? Heading {
            // A heading that IS a filename ("### DijkstraSolver.java") claims; one that
            // merely ends in a filename-shaped word needs the same markup emphasis prose does.
            if let inferred = CodeFileNameInference.fromHeading(heading) {
                pendingFileName = PendingFileNameClaim(name: inferred, origin: .heading)
                didClaim = true
                logger.debug("[FILENAME] Heading claim '\(inferred)' pending for next code block.")
            }
            // Formats the heading's children rather than `plainText`, so inline markup is preserved and no `#` prefix is produced.
            // Leading block syntax is escaped so `## 1. Setup` keeps its number; only a marker followed by whitespace is escaped.
            let headingText = Self.escapingLeadingBlockSyntax(
                rewritingHTMLLineBreaks(heading.children.map { $0.format() }.joined())
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            append(.heading(level: heading.level, text: headingText))
        }
        else if child is ThematicBreak {
            append(.horizontalRule)
        }
        else if let list = child as? UnorderedList {
            didClaim = append(listItems: Array(list.listItems), ordered: false, start: 1) || didClaim
        }
        else if let list = child as? OrderedList {
            didClaim = append(listItems: Array(list.listItems), ordered: true, start: Int(list.startIndex)) || didClaim
        }
        else if let quote = child as? BlockQuote {
            // Block quotes recurse into nested blocks instead of stringifying via `format()`, which would lose the `>` markers.
            let id = makeID(blocks.count)
            var nested = BlockBuilder(makeID: { "\(id).\($0)" }, pendingFileName: pendingFileName)
            nested.append(children: Array(quote.children))
            // The container reports a claim made inside it, or the next sibling would judge it stale and drop it.
            didClaim = didClaim || (nested.pendingFileName != nil && nested.pendingFileName != pendingFileName)
            pendingFileName = nested.pendingFileName
            blocks.append(ContentBlock(id: id, type: .blockquote(blocks: nested.blocks)))
        }
        else if let table = child as? Markdown.Table {
            // Table cells are parsed directly, so line breaks are rewritten here rather than in `preprocessMarkdownText`.
            func cellText(_ cell: Markdown.Table.Cell) -> String {
                rewritingHTMLLineBreaks(cell.children.map { $0.format() }.joined())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let headers: [String] = table.head.cells.map(cellText)
            let rows: [[String]] = table.body.rows.map { $0.cells.map(cellText) }
            // Reads the column alignment cmark parses; `nil` means unspecified, which GFM renders leading.
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
            // Applies the claim and keeps content that is not the marker; works on `format()` output, which keeps HTML lines.
            if consumedFileMarker(lineStructured: text, flattened: text) {
                // Same escape, same reason as the paragraph branch — see its note.
                let remainder = Self.escapingLeadingBlockSyntax(Self.strippingFileMarkerLines(from: text))
                if remainder.isEmpty { return didClaim }
                append(.paragraph(preprocessMarkdownText(remainder)))
                return didClaim
            }
            append(.paragraph(preprocessMarkdownText(text)))
        }
        return didClaim
    }

    /// The image an inline node is, if any: a `Markdown.Image`, or a `Link`/`Emphasis`/`Strong` whose only child is one.
    /// A wrapper with anything else in it stays prose.
    static func imageChild(_ inline: Markup) -> Markdown.Image? {
        if let image = inline as? Markdown.Image { return image }
        guard inline is Markdown.Link || inline is Markdown.Emphasis || inline is Markdown.Strong,
              inline.childCount == 1 else { return nil }
        return inline.child(at: 0) as? Markdown.Image
    }

    // Why: formatting node by node loses soft breaks, since a SoftBreak only queues its newline in the same formatter.
    /// Emits a paragraph that contains images as alternating `.paragraph` / `.image` blocks.
    /// A text run is formatted as one synthetic `Paragraph`; runs that trim to nothing emit no block.
    private mutating func appendSplittingImages(in paragraph: Paragraph, stripMarkers: Bool) {
        var run: [Markup] = []
        var images = 0
        var textRuns = 0
        for inline in paragraph.children {
            if let image = Self.imageChild(inline) {
                if appendTextRun(run, stripMarkers: stripMarkers) { textRuns += 1 }
                run.removeAll()
                if let link = inline as? Markdown.Link {
                    logger.debug("[RENDER] Linked image rendered as its image; the link target (\(link.destination ?? "none")) is not carried — the block has nowhere to put it.")
                }
                append(.image(url: image.source ?? "", altText: image.plainText))
                images += 1
            } else {
                run.append(inline)
            }
        }
        if appendTextRun(run, stripMarkers: stripMarkers) { textRuns += 1 }
        if textRuns > 0 || images > 1 {
            logger.debug("[RENDER] Paragraph split at \(images) inline image(s) into \(textRuns) text run(s) — each image renders as its own block instead of collapsing to its alt text.")
        }
    }

    /// Appends one text run of a split paragraph; false when the run had no visible text.
    @discardableResult
    private mutating func appendTextRun(_ run: [Markup], stripMarkers: Bool) -> Bool {
        var text = Paragraph(run.compactMap { $0 as? InlineMarkup }).format()
        if stripMarkers { text = Self.strippingFileMarkerLines(from: text) }
        text = Self.escapingLeadingBlockSyntax(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !text.isEmpty else { return false }
        append(.paragraph(preprocessMarkdownText(text)))
        return true
    }

    /// Escapes leading block syntax in a run that follows an image, so the characters the author wrote stay on screen.
    /// Handed to `AttributedString(markdown:)` alone, a leading marker would become a list or heading and be eaten.
    static func escapingLeadingBlockSyntax(_ text: String) -> String {
        if let match = text.firstMatch(of: /^(\d{1,9})([.)])(?=\s|$)/) {
            return String(match.1) + "\\" + String(match.2) + text[match.range.upperBound...]
        }
        if let first = text.first, "-+*#>".contains(first) {
            let rest = text.dropFirst()
            if rest.isEmpty || rest.first?.isWhitespace == true || first == "#" && rest.first == "#" {
                return "\\" + text
            }
        }
        return text
    }

    // Why: splitting own content from nested lists reorders output, rendering a trailing fence above the sub-bullets.
    /// Emits one `.listItem` per item, with everything it contains as child blocks in document order, nested lists included.
    /// - Returns: whether any item made a filename claim, so the outer loop does not drop it.
    @discardableResult
    private mutating func append(listItems: [ListItem], ordered: Bool, start: Int) -> Bool {
        var didClaim = false
        for (offset, item) in listItems.enumerated() {
            let id = makeID(blocks.count)
            var nested = BlockBuilder(makeID: { "\(id).\($0)" }, pendingFileName: pendingFileName)
            nested.append(children: Array(item.children))
            didClaim = didClaim || (nested.pendingFileName != nil && nested.pendingFileName != pendingFileName)
            pendingFileName = nested.pendingFileName

            let checkbox: ContentBlock.Checkbox? = item.checkbox.map { $0 == .checked ? .checked : .unchecked }
            // A task item's marker is the checkbox itself; keep the bullet for the rest.
            let prefix = ordered ? "\(start + offset)." : "•"

            blocks.append(ContentBlock(
                id: id,
                type: .listItem(prefix: prefix, blocks: nested.blocks, checkbox: checkbox)
            ))
        }
        return didClaim
    }
}

// MARK: - Incremental Streaming Parser

/// Incremental markdown parser for a message that is still streaming.
/// Regions ending at a blank line outside any fence are settled and cached; only the active tail re-parses per flush.
/// Callers must run one full `parseMarkdown` when streaming ends. Not thread-safe; main-actor render path only.
final class StreamingMarkdownParser {

    private var consumedPrefix: String = ""
    /// Cached `consumedPrefix.count` — `String.count` is O(n), and we need it per flush.
    private var consumedPrefixCharCount: Int = 0
    private var prefixBlocks: [ContentBlock] = []
    /// [mc-14] Tail size at the last "no settle boundary" warning, so a long answer logs on
    /// growth rather than on every flush.
    private var lastUnboundedTailWarning = 0
    /// Tail size past which never finding a boundary is worth saying out loud.
    private static let unboundedTailWarningChars = 8_000
    /// File-marker state carried across settled regions (marker paragraph and its
    /// code block may arrive in different flushes).
    private var pendingFileName: PendingFileNameClaim? = nil
    /// [CR29] One-shot, so a marker-only stream logs once per message rather than once per flush.
    private var didLogMarkerOnlyRender = false

    /// Parses the full accumulated text, reusing blocks for already-settled regions.
    /// Safe for arbitrary input: if `fullText` is not an append to what was consumed
    /// before (regeneration, error replacement), the parser resets and starts over.
    func parse(_ fullText: String) -> [ContentBlock] {
        if !fullText.hasPrefix(consumedPrefix) {
            reset()
        }

        var tailStart = fullText.index(fullText.startIndex, offsetBy: consumedPrefixCharCount)

        // Advances the settled boundary to the last blank line (outside a code fence) in the unconsumed tail.
        let tail = fullText[tailStart...]
        // A tail that never yields a boundary is re-parsed whole on every flush; it is logged once past a threshold.
        if Self.lastSafeBoundary(in: tail) == nil, tail.count > Self.unboundedTailWarningChars,
           tail.count - lastUnboundedTailWarning > Self.unboundedTailWarningChars {
            lastUnboundedTailWarning = tail.count
            logger.warning("[RENDER] Streaming parser found no settle boundary in a \(tail.count)-char tail — every flush re-parses all of it. CONSEQUENCE: render is correct but cost grows with the answer; usually an unterminated fence or a tail with no blank line outside one.")
        }
        if let cut = Self.lastSafeBoundary(in: tail) {
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

        // Mirrors `parseMarkdown`'s fallback, including the marker test: a stream of only sentinels yields zero blocks.
        // The strip stays inside this branch; it is O(n) and must not run on the normal path.
        if result.isEmpty, !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if FileMarkerLine.isNothingButFileMarkers(fullText) {
                if !didLogMarkerOnlyRender {
                    didLogMarkerOnlyRender = true
                    logger.debug("[RENDER] Streamed text is nothing but file-marker sentinel(s) so far — rendering no blocks rather than falling back to the raw text. CONSEQUENCE: the bubble is briefly empty while the sentinel is on its own; it fills as soon as content arrives, and the sentinel is never shown. Logged once per message.")
                }
            } else {
                result = [ContentBlock(id: "block-0", type: .paragraph(fullText))]
            }
        }
        return result
    }

    private func reset() {
        consumedPrefix = ""
        consumedPrefixCharCount = 0
        prefixBlocks = []
        pendingFileName = nil
        lastUnboundedTailWarning = 0
        didLogMarkerOnlyRender = false
    }

    // Why: a cut inside a fence is locked into `prefixBlocks` and stays wrong until the message settles.
    /// Index just past the last completed blank line outside any fence, or nil if the tail has no safe boundary yet.
    /// Shares one fence rule with `preprocessStreamResilientMarkdown` and splits lines by `\.isNewline` so CRLF counts.
    static func lastSafeBoundary(in tail: Substring) -> Substring.Index? {
        var openFenceRun: Int? = nil
        var lastCut: Substring.Index? = nil
        var lineStart = tail.startIndex

        while lineStart < tail.endIndex {
            let newlineIndex = tail[lineStart...].firstIndex(where: \.isNewline)
            let lineContentEnd = newlineIndex ?? tail.endIndex
            let nextLineStart = newlineIndex.map { tail.index(after: $0) } ?? tail.endIndex

            let trimmed = tail[lineStart..<lineContentEnd].trimmingCharacters(in: .whitespaces)
            if let marker = markdownFenceMarker(inTrimmedLine: trimmed) {
                if let open = openFenceRun {
                    if marker.run >= open, !marker.hasInfo { openFenceRun = nil }
                } else {
                    openFenceRun = marker.run
                }
            } else if trimmed.isEmpty, openFenceRun == nil, newlineIndex != nil {
                // A COMPLETED blank line (has its newline) outside any fence.
                lastCut = nextLineStart
            }

            lineStart = nextLineStart
        }
        return lastCut
    }
}
