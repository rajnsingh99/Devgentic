// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
/// [mc-14] A line's leading backtick RUN when that line is a fence marker, with whether it
/// carries an info string — nil when the line is not a fence at all.
///
/// THE reason this is not `hasPrefix("```")`: CommonMark closes a fenced block only on a run at
/// least as long as the one that opened it, so a ```` ```` ```` block containing an ordinary
/// ```` ``` ```` fence stays open — the shape a model emits constantly when it shows you
/// markdown. A boolean toggle reads that inner fence as a close, and both stages that used one
/// then disagreed with cmark about where the block ends.
///
/// `hasInfo` exists because only a BARE run can close: ```` ```swift ```` opens, it never
/// closes. Both callers need that distinction or a nested language fence still toggles.
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

/// Automatically closes unmatched code blocks to ensure AST parsers (and our UI)
/// render them correctly while streaming, instead of falling back to raw paragraph text.
///
/// [mc-14] Run-length aware, and it closes with a run of the OPENING length — a hard-coded
/// ```` ``` ```` cannot close a ```` ```` ```` block, so the old version appended a closer that
/// left the block open and the whole remainder of the answer rendered as code.
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

/// Rewrites every spelling of an HTML line break to a markdown HARD break.
///
/// Two bugs in one line, both confirmed against `AttributedString(markdown:)`:
///  - the replacement used to be `"\n"`, which CommonMark reads as a SOFT break and the
///    renderer collapses to a SPACE — so the break the author asked for silently vanished.
///    Only a two-space-then-newline survives as a real line break.
///  - only the literal lowercase `<br>` was matched, so `<br/>`, `<br />` and `<BR>`
///    reached the reader as literal tag text.
///
/// Applied wherever a string is about to be handed to `AttributedString(markdown:)`:
/// paragraph/fallback text via `preprocessMarkdownText`, and table cells in `BlockBuilder`.
/// Tables matter here specifically: the app's own `TableMarkdown.escapeCell` EMITS `<br>`
/// for a multi-line cell, so a table Devgentic serialises has to survive its own round trip.
/// ⚠️ The rewrite runs ONLY OUTSIDE code spans and fenced blocks. It is a blind regex over a
/// string that is sometimes already-serialised markdown (`cell.children.map { $0.format() }`
/// re-emits an inline-code child as `` `<br>` ``), so rewriting the whole string turns a
/// documented tag into three spaces: "Use `<br/>` to force a break" rendered as "Use     to
/// force a break", and a `<br>` inside a fence was mangled the same way. Code spans are
/// content, never markup to interpret — this is the repo's standing rule for payload-shaped
/// rewrites (repair only outside quoted/verbatim spans, never by shape-matching the payload).
func rewritingHTMLLineBreaks(_ text: String) -> String {
    guard text.contains("`") else { return rewritingBreaksInProse(text) }
    // Split on backtick RUNS: a run opens a span that only an equal-length run closes, so
    // ``a `b` c`` and a ``` fence are both handled by the same alternation of
    // outside/inside segments. Odd trailing run (unclosed span) leaves the tail as prose.
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
    // ⚠️ [CR16] A RUN of breaks collapses to ONE hard break, and any newline the source already
    // had after the run is consumed with it.
    //
    // Each `<br>` used to be rewritten to `"  \n"` independently, which is correct for a lone
    // tag and wrong the moment a second newline lands beside it: `"  \n  \n"` and `"  \n\n"` are
    // both PARAGRAPH breaks, and `AttributedString(markdown:)` renders a paragraph boundary as
    // NOTHING — no space, no newline. So the words on either side fused. Measured on this
    // machine: `a<br><br>b` rendered "ab", and — the commoner shape, which the finding did not
    // mention — `line1<br>\nline2` rendered "line1line2", because a single tag at end of line
    // already supplies the newline that makes the pair a paragraph.
    //
    // This is the same content-corruption class as the path-list fusion two functions below: a
    // transform that rewrites a payload by shape and silently joins text the author separated.
    //
    // ⚠️ The trailing group is `(?:[ \t]*\n)?` — horizontal whitespace is consumed ONLY as part of
    // a newline, never on its own. Written first as `[ \t]*\n?`, it ate the space in
    // `"<br> tail"` and rendered "span\ntail" instead of "span\n tail": a fix for content loss
    // that lost content. `HTMLLineBreakRewriteTests` caught it.
    //
    // ⚠️ RESIDUE, stated rather than hidden: an author's own BLANK LINE (`a<br>\n\nb`) is still a
    // paragraph break and still renders as nothing. That is the renderer's documented limit, not
    // this rewrite's doing, and it is not something a `<br>` rule can fix. A run is collapsed to
    // ONE break rather than N because a blank line is not representable here at all; injecting a
    // non-breaking space to fake one would put a character into the user's text that they would
    // copy out, which is the very class of harm this comment opens with.
    text.replacingOccurrences(
        of: "<br[ \t]*/?>(?:[ \t]*\n?[ \t]*<br[ \t]*/?>)*(?:[ \t]*\n)?",
        with: "  \n",
        options: [.regularExpression, .caseInsensitive]
    )
}

func preprocessMarkdownText(_ text: String) -> String {
    var processed = rewritingHTMLLineBreaks(text)

    // If the text looks like a list of paths but isn't properly formatted as a markdown list,
    // force real line breaks so each path stays on its own line.
    //
    // ⚠️ The separator is a markdown HARD break ("  \n") and MUST NOT go back to "\n\n".
    // This runs on ONE paragraph's `format()` output, and the result is handed to
    // `AttributedString(markdown:)` in `ContentBlockView.createStyledString` — which
    // concatenates block elements with NO character between them (it records the boundary
    // only in block-level `presentationIntent`, which that renderer never reads; the same
    // blindness ContentBlockView.swift:51-60 documents). Measured on this machine:
    //   "/a/b\n/c/d\n/e/f\n/g/h"       -> "/a/b /c/d /e/f /g/h"   (soft break = one space)
    //   "/a/b\n\n/c/d\n\n/e/f\n\n/g/h" -> "/a/b/c/d/e/f/g/h"      (paragraph = NOTHING)
    //   "a  \nb"                       -> "a\nb"                  (the one form that survives)
    // So "\n\n" replaced a space with nothing and FUSED the paths into one unbroken string —
    // a user copying a path out of it got one that does not exist. That is this repo's
    // content-corruption class: a transform that shape-matches a payload and silently
    // rewrites it.
    //
    // The trigger is deliberately left as-is. It is crude and does fire on prose with dates,
    // fractions or URLs — but with a hard break a false positive merely honours the newlines
    // the model actually wrote, which is faithful to the source rather than corrupting it.
    // That was not true of the old separator, where a false positive fused mid-sentence words.
    let lines = processed.components(separatedBy: .newlines)
    if lines.count > 3 && lines.filter({ $0.contains("/") }).count > lines.count / 2 {
        processed = lines.joined(separator: "  \n")
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
    var pendingFileName: PendingFileNameClaim? = nil
    var blocks = buildContentBlocks(from: document, idOffset: 0, pendingFileName: &pendingFileName)

    // If the AST produced zero blocks but the input was non-empty, the parser silently
    // dropped everything (e.g., deeply malformed markdown). Fall back to rendering the
    // raw text as a paragraph so the user sees *something* instead of a blank bubble.
    // ⚠️ Zero blocks is not always a failure. A node that is NOTHING BUT a file marker is
    // CONSUMED on purpose — that sentinel must never reach the user — so a document consisting
    // only of markers legitimately produces no blocks, and this fallback used to resurrect the
    // raw sentinel as prose. (Surfaced 2026-09-12 while testing mc-15; the fallback predates it
    // and defeated the marker-only case on its own.) The emptiness verdict tells the two apart.
    //
    // ⚠️ The verdict is computed INSIDE `blocks.isEmpty`. It is O(n) over the whole message with
    // two allocations per line, and it used to run EAGERLY on every parse — including
    // `ChatPersistenceStore.fetchSearchDocuments`, which parses every persisted message on the
    // main actor during ⌘F. The streaming twin already carried a warning that this must not run
    // on the normal path; the authoritative parser was quietly violating it.
    if blocks.isEmpty, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if !FileMarkerLine.isNothingButFileMarkers(markdown) {
            let preview = markdown.prefix(120).replacingOccurrences(of: "\n", with: "\\n")
            logger.warning("Markdown AST produced zero blocks for non-empty input (\(markdown.count) chars). Preview: \"\(preview)\". Falling back to raw paragraph.")
            blocks.append(ContentBlock(id: "block-0", type: .paragraph(markdown)))
        } else {
            // [CR30] The DELIBERATE empty render. Its sibling above logs, so silence here read as
            // "nothing happened" when in fact a whole message was consumed — a blank bubble left
            // no trace at all to start a diagnosis from.
            //
            // `.debug` because this is a designed outcome rather than an anomaly, and because it
            // is the one level `DGLogger` does not sanitize for egress: a marker on an agent or
            // code profile carries the file's absolute path, so this line reports COUNTS and
            // never a preview of the text.
            //
            // ⚠️ [CR62] The CONSEQUENCE clause used to name "prose that shared a line with a
            // sentinel" as a likely cause, because a sentinel LINE was removed WHOLE. Only the
            // SPAN goes now, so that prose survives and this branch no longer fires for it — but
            // it still fires when the span could not be resolved cleanly (a closer with no
            // trailing whitespace, an unterminated marker), which is the residue named on
            // `strippingFileMarkerLines`.
            logger.debug("[RENDER] Markdown consumed entirely as file-marker sentinels — \(markdown.count) chars in, 0 blocks out, every line was a '--- Start/End of file: … ---' sentinel. CONSEQUENCE: this message renders as an EMPTY bubble. Expected when the text really was nothing but sentinels; if content was expected, suspect upstream truncation, or a sentinel whose closing dashes are not followed by whitespace (that line is dropped whole rather than having its span removed).")
        }
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
    // ⚠️ MODULE-QUALIFIED. The macOS 27 SDK added `SwiftUI.Document`, and this file imports both
    // SwiftUI and Markdown — so a bare `Document` in TYPE position stopped resolving. The
    // `Document(parsing:options:)` call sites still compile unqualified because the argument
    // labels pick the overload, which is why this is the only line the upgrade broke.
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
/// A missed signal is graceful: it falls back to today's language-only labels.
///
/// ⚠️ [mc-6] A FALSE POSITIVE IS NOT COSMETIC, and this comment used to say it was. The
/// narrow part is true — `fileName` is not part of `denotesSameBlock`, so a wrong name cannot
/// fuse two different fences into one tab. But `openMessageInCodeViewer` feeds the inferred name
/// to a store-backed second pass (`resolvePendingSourceLinks`) that searches every
/// attachment-bearing message in the conversation for an exact name match, and a hit stamps
/// `sourceFileID` — which is what enables ⌘S / Apply Changes, and `performApplyChanges` then
/// writes the tab's buffer to that file's URL on disk. So a wrong name that happens to equal an
/// attached file's name links an unrelated fence to a REAL FILE and puts overwriting it one
/// keystroke away.
///
/// ⚠️ A claim is also UNBOUNDED in reach: nothing clears it but a fence or an explicit "End of
/// file" marker, so an inferred claim carries across any number of intervening blocks and can
/// name a later, unrelated fence. Verified 2026-09-13, NOT yet fixed — closing it needs the
/// threaded claim to carry its PROVENANCE so only inferred claims are dropped on the next
/// sibling (a marker claim is multi-block by design and must survive). Do not "fix" it by
/// clearing indiscriminately: that strips the filename, and therefore the source-file link, from
/// every fence inside an injected file. See the register row for the full plan and the two tests
/// that pin the marker behaviour a naive fix would break.
enum CodeFileNameInference {

    /// Longest prose allowed to claim a filename — a short lead-in like "Here is the
    /// updated `Main.swift`:", not a paragraph that happens to end in one. Kept as a
    /// second gate alongside the markup requirement in `fromTrailingProse`.
    private static let proseClaimLimit = 160

    /// [CR55] `"Foo.swift (/Users/raj/proj/Foo.swift)"` → `"Foo.swift"`; anything else verbatim.
    ///
    /// `BackendOrchestrationService.assembleTextFileContent(includeAbsolutePaths:)` labels the
    /// injected marker `<name> (<absolute path>)` for agent and code profiles, so the model can
    /// write back to the right file rather than to a relative path `FilePathResolver` would anchor
    /// to HOME. When a model echoes that marker into its visible answer, the whole decorated label
    /// became the claimed filename: the badge read as a full home path, and linking — which
    /// matches `AttachedTextFile.name`, a bare name — matched nothing.
    ///
    /// ⚠️ "Ends in a parenthetical that looks like a path" is NOT a sufficient test. A real file
    /// named `snapshot (~/Documents)` has exactly that shape, and on a bot profile (name-only
    /// label) it would be truncated to `snapshot`, breaking a link that works today. So the last
    /// component of the parenthesised path must EQUAL the leading part — the self-consistency that
    /// only this app's own label shape can satisfy. The scan is balanced, so a genuine
    /// `notes (v1).txt (/Users/raj/notes (v1).txt)` survives intact.
    ///
    /// ⚠️ Runs on the CAPTURED label, never on the marker text before the match. Normalising the
    /// marker is what ate the backslash in `back\slash.txt` during mc-15.
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

    /// The anchored "looks like a filename" test: `stem.ext` with a letter-led extension
    /// (1–8 chars), optionally path-qualified. Digit-led extensions are rejected so
    /// version strings ("v2.0") can't claim; URLs are rejected outright.
    ///
    /// Accepts the raw token as it appears in prose — wrapped in backticks/bold/quotes,
    /// with trailing punctuation ("`Foo.java`:", "(see Foo.java).") — and returns the
    /// cleaned name, or nil.
    static func filenameToken(_ raw: String) -> String? {
        var token = strippingTrailingPunctuation(raw.trimmingCharacters(in: .whitespaces))
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "`*_\"'()[]<>"))
        token = strippingTrailingPunctuation(token)
        guard !token.contains("://"), !token.hasPrefix("www.") else { return nil }
        guard token.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9_\-.\/]*\.[A-Za-z][A-Za-z0-9]{0,7}/) != nil else { return nil }
        return token
    }

    /// Trailing sentence punctuation, removed — with ONE exception that is the whole point:
    /// a `.` sitting directly after a letter or digit is NOT removed.
    ///
    /// That dot belongs to an abbreviation ("e.g.", "etc.", "Inc."), and stripping it
    /// manufactures an extension out of the letters in front of it: `e.g.:` used to clean
    /// down to `e.g`, which passes the `stem.ext` test and then became the file badge, the
    /// card title, the viewer tab name and the Save-As default filename. A real filename
    /// never ends in a bare dot, so refusing to strip that one costs nothing — while a dot
    /// after a bracket or backtick (`src/Main.java).`) is ordinary prose punctuation and
    /// still goes.
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

    /// `filenameToken`, plus the one shape test that only makes sense for a claim made in
    /// PROSE (or a heading): the token must not be a fully-qualified identifier.
    ///
    /// CF-3's markup gate asks the AUTHOR whether a token names a file, and that is the
    /// right question for `Node.js` in a bare sentence — but a backticked dotted identifier
    /// immediately above a fence ("a small example using `java.util.List`:") is the single
    /// most common trailing token in code chat, and the backticks are ordinary code
    /// formatting, not a file claim. It still became the block's badge, its viewer tab title
    /// and its Save-As default filename.
    ///
    /// The separable half of that class is structural, not a word list: a fully-qualified type
    /// name is DOTTED THREE OR MORE DEEP and ends in a Pascal-cased segment
    /// (`java.util.List`, `com.example.Main`, `org.slf4j.Logger`), which no real filename is.
    ///
    /// ⚠️ BOTH halves of that test are load-bearing; an earlier form rejected any uppercase
    /// first character of the extension and silently un-named a whole class of real files —
    /// measured: `script.R` (the canonical R extension), `README.MD`, `query.SQL`,
    /// `Makefile.PL`, `analysis.Rmd`. Losing a real file's badge, tab title and Save-As name
    /// is the same cosmetic cost as a wrong one, so a rule that trades one for the other buys
    /// nothing. Requiring the third dot keeps every one of those.
    ///
    /// ⚠️ The rest of the class is NOT separable by shape and is deliberately left open:
    /// `ASP.NET`, `os.path`, `numpy.random` and `Node.js` are indistinguishable from a real
    /// filename (`app.min.js` is one). They claim only when the author marked them up, which
    /// is the signal this gate exists to honour.
    ///
    /// Deliberately NOT folded into `filenameToken`: the fence info string (```java Foo.NET),
    /// the leading comment and the injected file marker are explicit claims, and an explicit
    /// claim is honoured whatever its extension looks like.
    private static func plausibleFilenameToken(_ raw: String) -> String? {
        guard let token = filenameToken(raw) else { return nil }
        let ext = (token as NSString).pathExtension
        let endsInPascalCasedSegment = ext.first?.isUppercase == true
            && ext.dropFirst().contains(where: \.isLowercase)
        guard !(endsInPascalCasedSegment && token.split(separator: ".").count >= 3) else { return nil }
        return token
    }

    /// A LABELLED claim inside the author's markup — "**File: src/Main.java**",
    /// "**Updated: config.yaml**" — reduced to the token it labels.
    ///
    /// Models label the filename constantly, and the label is exactly what a whole-string
    /// `filenameToken` test chokes on: its spaces defeat the anchored `stem.ext` match. The
    /// CF-3 gate handed the whole `Strong` run to `filenameToken`, so those two shapes — which
    /// carry the very markup signal the gate asks for — stopped naming their block and
    /// regressed to "Java Snippet".
    ///
    /// Only the text after the LAST colon counts, and only when it is a SINGLE token: a label
    /// is short and what follows it is the name and nothing else, which keeps a bolded
    /// SENTENCE ("**Note: this program runs on Node.js**") out — its remainder is four words.
    ///
    /// Everything this accepts, the pre-CF-3 last-word rule accepted too (and then some): it
    /// restores lost shapes, it cannot introduce a claim that behaviour did not already make.
    private static func labelledFilenameToken(_ raw: String) -> String? {
        if let direct = plausibleFilenameToken(raw) { return direct }
        guard let colon = raw.lastIndex(of: ":") else { return nil }
        let label = raw[raw.startIndex..<colon].trimmingCharacters(in: .whitespaces)
        let remainder = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // ⚠️ The label must look like a LABEL — a plain word. Splitting on the last colon of an
        // arbitrary token also splits a URL (`http://localhost:3000/app.js` → `3000/app.js`),
        // which then sails past `filenameToken`'s own URL guard because that guard never sees
        // the scheme. A real label carries no slash and no dot.
        guard !label.isEmpty,
              !label.contains("/"), !label.contains("."),
              !remainder.contains(where: \.isWhitespace) else { return nil }
        return plausibleFilenameToken(remainder)
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
        // [mc-5] The language is then DERIVED from the extension, exactly as a tab opened from a
        // FILE already does. It used to be left as the whole filename, under a comment claiming
        // a "lookup miss → plain-text grammar"; there is no such miss. `SyntaxHighlightService.
        // resolvedLanguage` renders plain ONLY for ""/code/text/plaintext and hands every other
        // token to hljs, whose undefined result Highlightr turns into `highlightAuto` across every
        // bundled grammar — on EVERY streaming flush of the block. And both badges print the raw
        // token, so the header read "dijkstrasolver.java" beside a file chip reading
        // "DijkstraSolver.java" — the filename twice, one of them labelled as the language.
        // An UNKNOWN extension yields that bare extension (`languageHint`'s best-effort contract),
        // which reaches hljs like any other unknown token — the residue CF-2 accepted, now
        // confined to extensions no grammar exists for instead of hitting every bare filename.
        if fileName == nil, language.contains("."), let name = filenameToken(language) {
            fileName = name
            language = CodeSnippet.languageHint(forFileName: name) ?? ""
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

    /// Short prose that DELIBERATELY names a file at its end — "`DijkstraSolver.java`"
    /// alone above a fence, or "Here is the updated `Main.swift`:".
    ///
    /// Ends-with alone is not enough, and that was a real defect: the last word of any
    /// paragraph up to `proseClaimLimit` chars was handed to `filenameToken`, so ordinary
    /// prose ending in "…in Node.js:" or "…with ASP.NET:" claimed the file badge, the card
    /// title, the viewer tab name and the Save-As default filename. Those words ARE
    /// `stem.ext` shaped; no amount of token cleaning can tell them from a filename. What
    /// separates a claim from a mention is the AUTHOR'S MARKUP, so the trailing token must
    /// arrive as an inline-code span or a bold run — which is how models actually write a
    /// filename above a fence.
    ///
    /// Trailing punctuation after the claim ("…`Main.swift`:") is skipped, so the colon
    /// lead-in still works, and a LABEL inside the marked-up run ("**File: src/Main.java**")
    /// is stepped over rather than defeating the claim — see `labelledFilenameToken`.
    static func fromTrailingProse(in paragraph: Paragraph) -> String? {
        guard paragraph.plainText.count <= proseClaimLimit else { return nil }
        return emphasizedTrailingToken(in: paragraph)
    }

    /// A heading that claims a filename for the fence below it.
    ///
    /// A heading gets one signal prose does not: being the ENTIRE heading. "### DijkstraSolver.java"
    /// is a section named after a file, not a sentence that happens to end in one — there is
    /// no surrounding prose for the token to be a stray word of. A heading that merely ends
    /// in a filename-shaped word ("## Setting up Node.js") must still carry markup emphasis,
    /// exactly like prose — its spaces defeat the anchored whole-string match below.
    ///
    /// ⚠️ [mc-16] The sentence above used to stop at "exactly like prose", which reads as a
    /// guarantee it does not make. A ONE-WORD heading that is wholly filename-shaped claims with
    /// NO markup gate: `## Node.js` names the next fence "Node.js", and so do `## ASP.NET` and
    /// `## Package.json`. That is an ACCEPTED FALSE POSITIVE, not an oversight — the trade is
    /// stated at `plausibleFilenameToken`, and it is the same trade: there is no shape that
    /// separates `Node.js` from a real `app.min.js`. Pinned deliberately in
    /// `FileNameInferenceTests.testAOneWordFrameworkHeadingClaimsAndThatIsAccepted`.
    ///
    /// ⚠️ Do NOT "fix" this by gating on `CodeSnippet.languageHint(forFileName:) != nil`: that
    /// helper returns nil only for an EMPTY extension, which `filenameToken` already excludes,
    /// so the gate rejects nothing and a test written against it is green against a no-op.
    /// The only rule that would actually refuse `## Node.js` is corroborating the claim against
    /// the fence's own language at the CONSUMPTION site, which needs the claim to carry its
    /// provenance — see [mc-6].
    ///
    /// The whole-heading escape hatch deliberately does NOT take `labelledFilenameToken`'s
    /// label fallback: a heading carries no markup signal of its own, so "## Note: Node.js"
    /// would claim on the colon alone. Inside a heading, a labelled claim still has to be
    /// marked up, and `emphasizedTrailingToken` below is where that is read.
    static func fromHeading(_ heading: Heading) -> String? {
        let plain = heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, plain.count <= proseClaimLimit else { return nil }
        if let wholeHeading = plausibleFilenameToken(plain) { return wholeHeading }
        return emphasizedTrailingToken(in: heading)
    }

    /// The filename in the container's last MARKED-UP inline (`` `Main.swift` `` or
    /// **Main.swift**), or nil.
    ///
    /// Walks the inline children backwards, stepping over trailing punctuation-only text
    /// and line breaks. The first child that carries content decides: inline code or strong
    /// emphasis may claim, anything else (plain text, a link, italics) stops the walk. That
    /// backwards walk IS the ends-with test — a mid-sentence mention ("I changed
    /// `Foo.java` and then reran") stops on the trailing prose and never claims.
    ///
    /// The run is read through `labelledFilenameToken`, not `filenameToken`: the whole run is
    /// what a model writes ("**File: src/Main.java**"), and the label inside it must not be
    /// what defeats the claim.
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

/// Maps swift-markdown AST nodes to `ContentBlock`s, recursing into containers
/// (list items, blockquotes) rather than flattening their children to raw markdown.
///
/// `makeID` produces each block's identity from its sibling index, so top-level blocks
/// stay `"block-N"` (the streaming parser's settled-region stitching and its tests
/// depend on that) while nested blocks get `"<parent>.N"`.
/// [mc-6] A pending filename claim and WHERE it came from.
///
/// The origin is what makes bounding the claim possible at all. An injected
/// `--- Start of file: X ---` marker spans an entire file body by design — that is why the "End
/// of file" branch exists as its terminator — so a marker claim MUST survive intervening blocks.
/// An INFERRED claim (prose, heading) has no such span, and before this it inherited the
/// marker's unbounded reach: nothing but a fence or an End marker cleared it, so a claim made in
/// one paragraph could name a fence arbitrarily far below it.
///
/// ⚠️ A VALUE type, deliberately. `StreamingMarkdownParser` keeps an active-region COPY of this
/// (`transientFileName`) precisely so a claim made in text that has not settled yet cannot leak
/// into the permanent `prefixBlocks` state. A class here would alias that copy and make every
/// active-region claim permanent — the same family as the permanent-cut bugs this file's
/// streaming half already carries scar tissue for.
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

/// [CR32] The ONE definition of "this line is an injected file-marker sentinel".
///
/// `consumedFileMarker` and `BlockBuilder.strippingFileMarkerLines` must never disagree about
/// that, because detection GATES the strip: the strip runs only when detection fired, so any line
/// the strip would remove but detection misses renders the raw sentinel to the reader. They used
/// to disagree by construction — detection was an unanchored `firstMatch` over the whole node,
/// stripping was a per-line `hasPrefix` — and the two directions fail very differently:
///
///  - detection WIDER than stripping costs a visible sentinel (prose quoting our format) and, for
///    the Start branch, a bogus `.marker` claim, which `mc-6` exempts from the one-sibling bound
///    and which therefore names an arbitrarily later fence;
///  - detection NARROWER than stripping is the dangerous one: it is silent, and it puts the raw
///    sentinel on screen on input the old code hid.
///
/// Both now call `kind(of:)`, so the Start half agrees by construction. The End half deliberately
/// does not — see `consumedFileMarker`.
enum FileMarkerLine: Equatable {
    case start
    case end

    /// The marker kind this line IS, or nil for every other line.
    ///
    /// ⚠️ BEGINS-with, not contains. The injected markers are always emitted on their own line, so
    /// a prefix test catches every real one while prose that merely MENTIONS "--- End of file:"
    /// mid-sentence keeps its whole line. Widening this to `contains` would delete the author's
    /// sentence around the mention.
    ///
    /// ⚠️ Backslashes are removed before the test and the trimmed copy is then DISCARDED — the
    /// caller keeps the raw line. That is the difference from the identical strip removed from
    /// `consumedFileMarker` during mc-15, which rewrote the CAPTURED filename and turned
    /// `back\slash.txt` into `backslash.txt`. Here it only decides, and it is NOT dead code:
    /// `parseMarkdown`'s zero-block check passes the RAW message text, which cmark has never seen,
    /// and `MarkupFormatter.visitHTMLBlock` re-emits an HTML block's source lines verbatim — so
    /// `\--- Start of file: X ---` reaches this test with its backslashes on both of those paths.
    static func kind(of line: some StringProtocol) -> FileMarkerLine? {
        let bare = line.replacingOccurrences(of: "\\", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard bare.hasPrefix("---") || bare.hasPrefix("—") else { return nil }
        if bare.contains("Start of file:") { return .start }
        if bare.contains("End of file:") { return .end }
        return nil
    }

    /// The lines of a text, CRLF included.
    ///
    /// ⚠️ [mc-14, again] NOT `split(separator: "\n")`. Swift's `"\r\n"` is ONE Character and is not
    /// `"\n"`, so that spelling sees an all-CRLF document as a SINGLE line — the identical bug
    /// `lastSafeBoundary` carries a warning about 400 lines below. cmark normalises line endings,
    /// so only the RAW-text callers can ever see CRLF; that is exactly where a whole document
    /// collapsing to one "line" decides whether a sentinel is published.
    static func lines<S: StringProtocol>(of text: S) -> [S.SubSequence] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// A line split into its block-quote / indent PREFIX and the BODY after it.
    ///
    /// `MarkupFormatter.linePrefix(for:)` decorates every line of `format()` output with one
    /// `"> "` per BlockQuote ancestor — and it reads the node's REAL parental chain, so a
    /// paragraph formatted on its own still carries them. `'>'` is the only prefix character that
    /// is not whitespace (list nesting contributes spaces, which `kind` already trims), which is
    /// why the block-quote case is the only one that ever defeated the sentinel test.
    static func quotePrefixSplit<S: StringProtocol>(_ line: S) -> (prefix: S.SubSequence, body: S.SubSequence) {
        let start = line.firstIndex(where: { $0 != ">" && $0 != " " && $0 != "\t" }) ?? line.endIndex
        return (line[line.startIndex..<start], line[start...])
    }

    /// The sentinel SPAN inside a line — what `strippingFileMarkerLines` removes.
    ///
    /// ⚠️ DELIBERATELY NOT the capture regex in `consumedFileMarker`, and the two must not be
    /// merged: that one names a FILE THE APP WRITES TO, this one only decides where the marker
    /// ends on screen.
    ///
    /// ⚠️ The `(?=\s|$)` lookahead is load-bearing. Without it the lazy `.*?` stops at the first
    /// `---` INSIDE a filename, so `--- Start of file: my---file.txt ---` leaves `file.txt ---`
    /// on screen — filename debris published where today the whole line is hidden. With it, a
    /// closer that is not followed by whitespace simply does not match, and the caller falls back
    /// to exactly what it does today.
    static let sentinelSpan = /(?:---|—)\s*(?:Start|End) of file:\s*.*?\s*(?:---|—)(?=\s|$)/

    /// Whether every non-blank line of `text` IS a sentinel line.
    ///
    /// The EMPTINESS question, kept separate from the RENDER question `strippingFileMarkerLines`
    /// answers. They are genuinely different, and conflating them coupled two substrates that
    /// disagree: `parseMarkdown` and `StreamingMarkdownParser` pass RAW message text, which cmark
    /// has never touched, while the block branches pass `format()` output, which cmark has already
    /// decoded. `--- End of file: x.txt --- &nbsp;` is the case that exposed it — the raw text
    /// still spells the entity (letters!) where `format()` carries a decoded U+00A0 — and a
    /// disagreement there flips `parseMarkdown` between rendering nothing and republishing the
    /// whole raw sentinel. Asking each caller its own question removes the coupling entirely.
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

    /// A node's plain text with its LINE STRUCTURE intact.
    ///
    /// Neither of the two obvious spellings can be used for a line-anchored test:
    ///
    ///  - `plainText` flattens. `SoftBreak.plainText` is a SPACE in the pinned swift-markdown
    ///    (probed, 0.7.3), so a marker on its own line and a marker mid-sentence arrive as the
    ///    same string and the anchor cannot tell them apart.
    ///  - `format()` keeps the lines but decorates them. `MarkupFormatter.linePrefix(for:)` walks
    ///    the node's REAL `parentalChain`, not the chain below whatever node you called `format()`
    ///    on, so a paragraph inside a block quote comes back with `"> "` on every line and no line
    ///    begins with the sentinel any more. It also re-emits inline markup, so a marker the model
    ///    wrote as `--- **Start** of file: X ---` stops matching.
    ///
    /// So: the children's own plain text, with the two break kinds restored as newlines.
    /// `InlineCode.plainText` keeps its backticks, which is the behaviour we want — a marker
    /// inside a code span no longer begins its line and correctly stops claiming.
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
    /// Threads a filename claim across siblings (and across separately-parsed streaming
    /// regions) so the next code block can consume it. Set by the explicit
    /// `--- Start of file: X ---` marker AND by `CodeFileNameInference`'s prose/heading
    /// signal; the nearest claim wins and every fence clears it.
    var pendingFileName: PendingFileNameClaim?

    init(makeID: @escaping (Int) -> String, pendingFileName: PendingFileNameClaim?) {
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
    /// ⚠️ [mc-15] Applies the marker's CLAIM and reports whether one was found — it no longer
    /// decides that the whole node disappears. It used to return a bare Bool and both call sites
    /// `return`ed on true, so ANY paragraph merely CONTAINING a marker was discarded whole, with
    /// nothing logged.
    ///
    /// That is not an edge case: the injected marker is followed by the file's content with NO
    /// blank line between them, so cmark parses marker-and-content as ONE paragraph — the common
    /// shape, not the rare one. The first lines of an attached file were being dropped from the
    /// transcript, and the End branch is looser still (a bare `contains`), so prose that merely
    /// MENTIONS "--- End of file:" vanished too.
    ///
    /// The claim must still be applied even when text survives, or the following fence loses its
    /// filename badge — which is a worse outcome than losing the prose, and the reason this
    /// returns a claim rather than just a remainder.
    private mutating func consumedFileMarker(lineStructured: String, flattened: String) -> Bool {
        // ⚠️ Do NOT "normalise" the text before matching — in particular, do not strip
        // backslashes. I added exactly that during mc-15 to compensate for the `\-\-\-` escape
        // the comment at the paragraph call site described, and BOTH were wrong: a probe of the
        // pinned swift-markdown shows `Paragraph.format()` emits `--- Start of file: X ---`
        // unescaped, so there was nothing to compensate for. The strip was not harmless either —
        // `match.1` below is captured out of the matched string and becomes `pendingFileName`,
        // i.e. the filename the rest of the app links by, so a legitimately-named
        // `back\slash.txt` was captured as `backslash.txt` and its badge stopped resolving.
        // `FileMarkerLine.kind` may strip backslashes because it only DECIDES; this must not,
        // because it CAPTURES.
        //
        // ⚠️ [CR32] The Start branch is LINE-ANCHORED, through the same predicate
        // `strippingFileMarkerLines` uses, so the two cannot disagree about which lines are
        // sentinels. It used to be an unanchored `firstMatch` over the whole node, which fired on
        // a sentence merely QUOTING our format — the strip then removed nothing (its own test is
        // line-anchored), so the sentinel rendered AND a `.marker` claim was armed from prose.
        // `.marker` is the one origin mc-6 exempts from the one-sibling bound, so that bogus claim
        // named an arbitrarily later fence, and a name that collides with an attached file puts
        // Apply Changes' on-disk write one keystroke away. Start's error runs toward a write;
        // that is why it is the branch that gets anchored.
        let lines = lineStructured.split(separator: "\n", omittingEmptySubsequences: false)
        if let index = lines.firstIndex(where: { FileMarkerLine.kind(of: $0) == .start }) {
            // ⚠️ Matched from THIS LINE ONWARD, rejoined, not on the line alone. The
            // `includeAbsolutePaths` label an agent/code profile injects
            // (`<name> (<absolute path>)`) routinely runs past 70 characters, and a model
            // re-emitting it can wrap before the closing dashes — leaving the opener on one line
            // and `---` on the next. Matching the line alone would find no closer, drop the claim,
            // and take the fence's badge and Apply Changes with it. Starting AT this line is what
            // an unanchored match over the whole node could not do: an earlier mid-sentence
            // mention can no longer win the capture.
            let fromMarker = lines[index...].joined(separator: " ")
            if let match = fromMarker.firstMatch(of: /(?:---|—)\s*Start of file:\s*(.*?)\s*(?:---|—)/) {
                let label = String(match.1)
                let name = CodeFileNameInference.nameFromMarkerLabel(label)
                if name != label {
                    // ⚠️ Logs the BARE NAME and a length, never the label. By construction this
                    // branch only fires when the label was `<name> (<its own absolute path>)`, so
                    // printing it would put the user's home path in the log — and `DGLogger.debug`
                    // is the one level that does NOT run `sanitizedForEgress`. The CR30 branch
                    // thirty lines up refuses a preview for exactly this reason; this line was
                    // doing what that comment forbids.
                    logger.debug("[FILENAME] Marker label carried its own absolute path (\(label.count) chars) — agent and code profiles disclose it so the model can write back to the right file. Linking by the bare name '\(name)'. CONSEQUENCE: none intended; the decorated label matched no attachment, so the fence had no badge, no source link and no Apply Changes.")
                }
                pendingFileName = PendingFileNameClaim(name: name, origin: .marker)
            }
            // True even when the regex found no closer: this line IS a sentinel by the shared
            // predicate, so `strippingFileMarkerLines` will remove it, and returning false here
            // would leave it on screen — the precise failure this anchoring exists to prevent.
            return true
        }
        // ⚠️ The End branch stays UNANCHORED, deliberately — the asymmetry is the point.
        // Its errors run the SAFE way round: over-clearing costs a filename badge, under-clearing
        // leaves a `.marker` claim alive past the file body it belonged to, which is the same
        // unbounded reach the Start branch is anchored to prevent. It also has to keep working
        // inside a block quote, where `format()` gives every line a `"> "` prefix (see
        // `FileMarkerLine.lineStructuredPlainText`) and no line-anchored test would fire at all.
        if flattened.contains("--- End of file:") || flattened.contains("— End of file:") {
            pendingFileName = nil
            return true
        }
        return false
    }

    /// The marker LINES removed, every other line kept verbatim.
    ///
    /// ⚠️ [CR43] This used to claim that detection "stays on `plainText` … the only form the regex
    /// reliably matches (the formatter escapes a leading `---` to `\-\-\-`)". Both halves were
    /// false, and the same sentence is what talked mc-15 into a blanket backslash strip inside
    /// `consumedFileMarker` that ate a legal character out of `back\slash.txt`. What is actually
    /// true, probed in the pinned swift-markdown: `MarkupFormatter.visitText` prints through
    /// `softWrapPrint(text.string)`, which with the default `preferredLineLimit == nil` writes the
    /// string raw — so `format()` neither escapes the sentinel nor re-wraps a long line.
    ///
    /// THREE callers, and they are all `format()` output — but not all the same `format()`. The
    /// paragraph branch and the unknown-node fallback pass a node with its REAL ancestors, so a
    /// block quote decorates every line with `"> "`; `appendTextRun` passes a SYNTHETIC
    /// `Paragraph`, a new root with no ancestors and therefore no prefix. Either way cmark has
    /// already decoded the text.
    ///
    /// ⚠️ The two RAW-text callers — `parseMarkdown`'s zero-block check and
    /// `StreamingMarkdownParser`'s — do NOT come here. They ask
    /// `FileMarkerLine.isNothingButFileMarkers` instead, because they want an emptiness VERDICT,
    /// not rendered text, and answering both questions with one function coupled two substrates
    /// that disagree about their own input. Raw text is the one input cmark has never run over,
    /// which is why `FileMarkerLine.kind` removes backslashes before testing and why that is not
    /// dead code — see its own note.
    ///
    /// ⚠️ The line predicate is SHARED with `consumedFileMarker`'s Start branch on purpose. This
    /// function runs only when detection fired, so a line it would remove but detection misses
    /// renders the raw sentinel; going through one `FileMarkerLine.kind` is what makes that
    /// impossible rather than merely unlikely.
    ///
    /// ⚠️ [CR61 + CR62] THE RULE THIS FUNCTION OBEYS: it may remove a sentinel, and it may
    /// RECOVER prose that used to be deleted — but it must never delete anything this same code
    /// would have rendered yesterday, and never publish a sentinel yesterday hid. Every case the
    /// span removal cannot resolve cleanly therefore falls back to `todayWouldDropTheLine`, which
    /// is literally the old predicate. That is what makes the change monotone, and it is the only
    /// reason widening the gate to block-quoted lines is safe.
    ///
    /// [CR62] A sentinel LINE used to be removed WHOLE, so
    /// `--- End of file: config.yaml --- and that is everything I changed.` lost the author's
    /// sentence — and, being the only content, rendered as an empty bubble. Only the SPAN goes
    /// now. mc-15's contract was "a file marker takes only itself with it"; the mid-sentence half
    /// was fixed then, this is the other half.
    ///
    /// [CR61] A marker inside a BLOCK QUOTE used to survive: `format()` prefixes every line with
    /// `"> "`, so nothing began with the sentinel and nothing was removed, while detection — which
    /// reads the undecorated `lineStructuredPlainText` — armed the claim anyway. The test now runs
    /// on the BODY after that prefix and the prefix is put back on the output, so ordinary quoted
    /// prose is byte-identical and only marker lines change. ⚠️ Not the whole story even before
    /// this: a quoted marker paragraph that also carries an IMAGE was already stripped, because
    /// `appendTextRun` formats a SYNTHETIC `Paragraph` which is a new root with no BlockQuote
    /// ancestor and therefore no prefix. The two branches agree now.
    ///
    /// ⚠️ Residue, stated rather than hidden: a closer not followed by whitespace
    /// (`--- End of file: x.txt ---.`) does not match the span, so that line still behaves as it
    /// does today. Recovering it would mean guessing where the sentinel ends, and guessing is what
    /// publishes filename debris — see `FileMarkerLine.sentinelSpan`.
    static func strippingFileMarkerLines(from text: String) -> String {
        var kept: [String] = []
        for line in FileMarkerLine.lines(of: text) {
            let (prefix, body) = FileMarkerLine.quotePrefixSplit(line)
            guard FileMarkerLine.kind(of: body) != nil else { kept.append(String(line)); continue }

            // The old predicate, verbatim: it saw the WHOLE line, so a `"> "` prefix hid the
            // sentinel from it and the line was kept. Anything this fix cannot clean must land
            // exactly here.
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
            // A residue with no letter or digit is punctuation left over from the sentinel — an
            // escape that survived, a stray dash. Not worth publishing, and on the raw substrate
            // it is what used to flip a message between "renders nothing" and "renders the whole
            // sentinel". Emptiness is NOT the test: `\` is not blank.
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

            // ⚠️ [mc-6] An INFERRED claim reaches only as far as its own neighbourhood.
            //
            // Nothing but a fence or an explicit "End of file" marker used to clear a claim, so a
            // prose claim carried across any number of intervening blocks and named a later,
            // unrelated fence. That is not merely a wrong badge: `openMessageInCodeViewer` feeds
            // the inferred name to a store-backed lookup that stamps `sourceFileID` on an exact
            // name match, which is what enables Apply Changes — and that writes the tab's buffer
            // to the matched file on disk.
            //
            // Measured in SIBLING NODES, not in parse regions: a claim and its fence routinely
            // land in different streaming flushes, and a region boundary is not a node. A
            // stateless per-node rule keeps that working, where "stale on entry to a builder"
            // would break it.
            //
            // ⚠️ `.marker` is exempt, and that exemption is the whole reason this carries an
            // origin. An injected `--- Start of file: X ---` wraps a WHOLE file body, so its
            // claim must outlive every block in between; the End branch is its terminator.
            // Clearing markers here would strip the filename — and therefore the source-file
            // link, and therefore diff and apply — from every fence inside an injected file.
            //
            // ⚠️ `.heading` is also exempt, for now. A heading claim is naturally section-scoped
            // and its ordinary shape is "### Main.swift" → an explanatory paragraph → the fence;
            // dropping it on the first non-claiming sibling would silently unbadge that. Bounding
            // it properly means clearing on the next Heading or ThematicBreak, which is only
            // worth doing once a heading claim is harder to arm than it is today (see mc-16).
            if !claimed, let claim = pendingFileName, claim.origin == .prose {
                pendingFileName = nil
                logger.debug("[FILENAME] Prose claim '\(claim.name)' dropped — the next block made no claim of its own and was not a fence, so the claim does not reach past it.")
            }
        }
    }

    private mutating func append(node child: Markup) -> Bool {
        // [mc-6] Whether THIS node made a claim. Reported so `append(children:)` can bound an
        // INFERRED claim to its own neighbourhood without a freshness heuristic — comparing the
        // claim value before and after cannot do it, because a repeated identical claim (a
        // heading and then a sentence naming the same file) would read as "unchanged" and the
        // real setter would be judged stale.
        var didClaim = false
        if let paragraph = child as? Paragraph {
            // [mc-3] A paragraph carrying ANY image is split at its images: the text runs between
            // them become `.paragraph`s and each image its own `.image` block, in document order.
            // Only a paragraph that was NOTHING BUT one image used to reach `.image`; every other
            // shape fell to the text branch below, where `AttributedString(markdown:)` keeps an
            // image's alt TEXT as characters and nothing draws a picture. So
            //
            //     Here is the chart:
            //     ![chart](/tmp/x.png)
            //
            // — prose, ONE newline, image: the common model shape, which cmark folds into a single
            // [Text, SoftBreak, Image] paragraph — rendered as "Here is the chart: chart" with no
            // image, no failure card and no log line; only a blank line before the image saved
            // it. The whole `localImagePath` / `LocalMarkdownImageView` path was reachable from
            // the single-child branch alone.
            //
            // [CR32] Two forms, because the two branches need different things: the End branch
            // wants the flat text (it is a deliberately unanchored `contains`), the Start branch
            // wants the line structure (it is anchored). `plain` also serves as the cheap gate —
            // it is the string this branch already needed, and building the line-structured form
            // for every ordinary paragraph would be pure waste. `format()` is NOT the substrate
            // here: it carries a block quote's `"> "` line prefix and re-emits inline markup,
            // either of which stops an anchored test from firing. See `FileMarkerLine`.
            let plain = paragraph.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            // [mc-15] The claim is applied either way; only a node that is NOTHING BUT the
            // marker disappears. A merged marker+content paragraph renders its content.
            // ⚠️ Applied BEFORE the image split: a marker paragraph CAN carry an image (a quoted
            // or persisted `.md` attachment opening with a logo), and splitting first would print
            // the sentinel as prose and lose the filename claim for the fence that follows.
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
                // ⚠️ [CR62 + CR17] `escapingLeadingBlockSyntax`, the same helper `appendTextRun`
                // has always applied to a run that follows an inline image, and for the same
                // reason: what survives here was INLINE content in the source, protected from
                // block interpretation by the sentinel in front of it. Handed to
                // `AttributedString(markdown:)` on its own, a leading `1.` / `-` / `>` / `#`
                // becomes a list or heading whose marker that renderer silently eats. Span
                // removal makes this reachable for the first time — `--- End of file: x --- 1.
                // renumbered` now leaves a residue that STARTS with a block marker — and without
                // it the two branches would disagree about the identical input, since
                // `appendTextRun` escapes and this one did not.
                let remainder = Self.escapingLeadingBlockSyntax(Self.strippingFileMarkerLines(
                    from: paragraph.format().trimmingCharacters(in: .whitespacesAndNewlines)))
                if remainder.isEmpty { return didClaim }
                logger.debug("[FILENAME] File marker stripped from a paragraph that also carried \(remainder.count) chars of content — the content is kept.")
                append(.paragraph(preprocessMarkdownText(remainder)))
                return didClaim
            }
            // Prose filename claim ("`DijkstraSolver.java`" above a fence). Unlike the
            // marker the paragraph stays VISIBLE — it's the model's own prose, not an
            // injected sentinel to hide. The AST node itself is passed, not `plain`: the
            // claim requires the author's own markup (inline code or bold) on the trailing
            // token, and plainText erases bold entirely.
            if let inferred = CodeFileNameInference.fromTrailingProse(in: paragraph) {
                pendingFileName = PendingFileNameClaim(name: inferred, origin: .prose)
                didClaim = true
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
            // ⚠️ [mc-8] `.format()` of the CHILDREN, not `plainText`. `plainText` is
            // swift-markdown's markup-STRIPPING accessor — `## A **bold** word` arrived here as
            // "A bold word", so bold, italic, inline code and links inside a heading rendered as
            // flat text while the identical markup one line lower, in a paragraph, rendered
            // correctly. The paragraph branch has always used `format()`; this is the same
            // treatment the table cells above already get, `rewritingHTMLLineBreaks` included.
            //
            // Children rather than the node, so no ATX `#` prefix is produced and nothing has to
            // know how many of them this level would emit.
            // ⚠️ [CR17] The heading's TEXT is re-parsed as markdown by the renderer, and cmark
            // had already eaten the `##`, so text that begins with another block marker is read
            // as that block and its marker disappears: `## 1. Setup` rendered "Setup",
            // `## - Prerequisites` rendered "Prerequisites", `## > Note` rendered "Note".
            // Numbering a section is ordinary, so this silently dropped the number from headings
            // models write constantly.
            //
            // Same helper, same reason as a text run that follows an inline image ([mc-3]): the
            // marker was inline content in the source and must not be promoted to structure when
            // the fragment is parsed on its own. It escapes only a LEADING marker followed by
            // whitespace, so `## 1.5 release` and `## #hashtag` are untouched.
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
            // Previously fell through to the `else` fallback below, which stringified
            // the whole quote via format(); AttributedString then ate the `>` markers
            // and the quote rendered as indistinguishable body prose.
            let id = makeID(blocks.count)
            var nested = BlockBuilder(makeID: { "\(id).\($0)" }, pendingFileName: pendingFileName)
            nested.append(children: Array(quote.children))
            // [mc-6] A claim made INSIDE this container was set by a node the outer loop never
            // sees, so the container itself must report it — otherwise the next sibling would
            // judge it stale and drop it before a following top-level fence could consume it.
            didClaim = didClaim || (nested.pendingFileName != nil && nested.pendingFileName != pendingFileName)
            pendingFileName = nested.pendingFileName
            blocks.append(ContentBlock(id: id, type: .blockquote(blocks: nested.blocks)))
        }
        else if let table = child as? Markdown.Table {
            // Cells never reached `preprocessMarkdownText` — `TableCellView.textCell` parses
            // this string directly — so `a<br>b` displayed the tag as literal text, including
            // in tables the app itself serialised through `TableMarkdown.escapeCell`.
            func cellText(_ cell: Markdown.Table.Cell) -> String {
                rewritingHTMLLineBreaks(cell.children.map { $0.format() }.joined())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let headers: [String] = table.head.cells.map(cellText)
            let rows: [[String]] = table.body.rows.map { $0.cells.map(cellText) }
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
            // [mc-15] Same rule as the paragraph branch: apply the claim, keep any content that
            // is not the marker itself. This branch already works on `format()` output, so the
            // strip is over the same string it renders — and so, here, is detection: an HTML
            // block has no inline children to derive a line-structured plain text from, and
            // `format()` already preserves its source lines verbatim (`visitHTMLBlock` re-emits
            // `trimmedLineSegments`, backslashes and all).
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

    /// [mc-3] The image an inline node IS, if any: a `Markdown.Image` itself, or a `Link` /
    /// `Emphasis` / `Strong` whose ONLY child is one — the `[![alt](src)](href)` "click to
    /// enlarge" / badge idiom and the `*![Figure 1](src)*` caption idiom. Both used to collapse
    /// to their alt text exactly like a bare inline image did. A wrapper with anything else in
    /// it is prose and stays prose.
    static func imageChild(_ inline: Markup) -> Markdown.Image? {
        if let image = inline as? Markdown.Image { return image }
        guard inline is Markdown.Link || inline is Markdown.Emphasis || inline is Markdown.Strong,
              inline.childCount == 1 else { return nil }
        return inline.child(at: 0) as? Markdown.Image
    }

    /// [mc-3] Emits a paragraph that contains images as alternating `.paragraph` / `.image`
    /// blocks.
    ///
    /// A text run is the inline nodes between two images, formatted as ONE synthetic
    /// `Paragraph` — never node by node. `Markup.format()` builds a fresh formatter per call and
    /// a `SoftBreak` only QUEUES its newline for the next print in the same formatter, so a
    /// per-node join emitted "" for every soft break and "  " for every hard break: two lines of
    /// prose before an image fused into one word ("png.Here"). The synthetic paragraph prints
    /// `\n` / `"  \n"` between the texts exactly as the whole-paragraph branch does. A run that
    /// trims to nothing — the `SoftBreak` between two images on consecutive lines — emits no
    /// block. The prose-filename claim is not evaluated on the runs (a claim taken from half a
    /// paragraph would be a new false positive); the file-MARKER claim was already applied by
    /// the caller, which passes `stripMarkers` so the sentinel lines never render.
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

    /// A run that FOLLOWS an image was inline content in the source (" - caption", " 1. Open
    /// Settings"), protected from block interpretation by the image before it. Trimmed and
    /// handed to `AttributedString(markdown:)` on its own it would become a list item or
    /// heading whose marker that renderer silently eats. The marker is escaped so the characters
    /// the author wrote stay on screen; the formatter never escapes text itself.
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

    /// Emits one `.listItem` per item, carrying EVERYTHING the item contains as child
    /// blocks in DOCUMENT ORDER — including any nested list, which recurses naturally
    /// through `append(children:)` back into this method.
    ///
    /// An earlier version split the children into "own content" vs "nested lists" and
    /// emitted the own content first, flattening nested items to siblings. That
    /// reordered the output: a fence written *after* the sub-bullets rendered *above*
    /// them. Preserving the AST's child order is the whole point.
    /// - Returns: whether any item made a filename claim ([mc-6] — the list is one sibling to the
    ///   outer loop, so a claim made inside it has to be reported or the next sibling drops it).
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

        // Advance the settled boundary to the last blank line (outside a code fence)
        // in the unconsumed tail. Everything before it can never re-parse differently
        // under our flattened block model, so parse it once and lock it in.
        let tail = fullText[tailStart...]
        // [mc-14] A tail that never yields a boundary is re-parsed WHOLE on every flush — the
        // O(n²) behaviour this parser exists to avoid. It is silent by construction (the render
        // stays correct), so it is logged once past a threshold rather than left to be
        // discovered by a user watching a long answer get slower.
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

        // Mirror parseMarkdown's non-empty-input fallback so a malformed stream still shows raw
        // text instead of a blank bubble — INCLUDING its marker test, which [CR29] found missing
        // here. A node that is nothing but a sentinel is consumed on purpose, so zero blocks is
        // DELIBERATE, and resurrecting the raw text as prose defeats mc-15 for the whole duration
        // of the stream: the user watches `--- Start of file: x ---` sit in the bubble until the
        // next flush carries real content.
        //
        // ⚠️ RESIDUE, stated rather than hidden: this hides a line the sentinel predicate
        // recognises. The frames before that — `---` (a thematic break), then `--- S`, `--- Sta`
        // … up to `--- Start of file` — are ordinary paragraphs and still show. Suppressing those
        // would mean shape-matching an unfinished payload, which is this file's documented
        // content-corruption class, and it would make this parser disagree with the authoritative
        // `parseMarkdown` at settle. Both are worse than the residue.
        //
        // ⚠️ The strip stays INSIDE this branch. It is O(n) over the whole accumulated text, and
        // on the normal path — where `result` is never empty — it must not run at all, or it
        // reintroduces exactly the per-flush whole-text work this parser exists to avoid.
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

    /// Index just past the last completed blank line that sits outside any ``` fence,
    /// or nil if the tail contains no safe boundary yet.
    ///
    /// Shares ONE fence rule with `preprocessStreamResilientMarkdown` —
    /// `markdownFenceMarker(inTrimmedLine:)` — because everything before the cut this returns is
    /// parsed WITHOUT the preprocessor and then locked into `prefixBlocks` forever. A cut that
    /// lands inside a fence is not a rendering glitch that heals on the next flush; it is
    /// permanent until the message settles.
    ///
    /// ⚠️ [mc-14] Two things this used to get wrong, both of which made that permanent cut real:
    ///
    /// 1. A boolean toggle on `hasPrefix("```")`. Given ```` ````markdown ```` followed by an
    ///    inner ```` ```swift ```` — the shape a model emits whenever it shows you markdown —
    ///    the inner fence toggled the flag back off, a blank line inside the outer block was
    ///    accepted as a boundary, and the settled region ended mid-fence. cmark then swallowed
    ///    the settled text as one unterminated code block and the rest of the code rendered as
    ///    prose. Run length and the bare-run requirement are what cmark itself uses.
    ///
    /// 2. `firstIndex(of: "\n")`. Swift's `"\r\n"` is ONE Character, so this found NOTHING in
    ///    an all-CRLF tail: the whole tail read as a single line, no boundary was ever returned,
    ///    and the streaming parser silently degraded to the full re-parse per flush it exists to
    ///    avoid — while `preprocessStreamResilientMarkdown` split the same text into 9 lines with
    ///    `components(separatedBy: .newlines)`. The doc here claimed the two stages "can't
    ///    disagree about what's inside a fence"; they disagreed about what a LINE is.
    ///    `\.isNewline` matches the CRLF cluster and every separator that `CharacterSet.newlines`
    ///    splits on, so the two now agree on both questions.
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
