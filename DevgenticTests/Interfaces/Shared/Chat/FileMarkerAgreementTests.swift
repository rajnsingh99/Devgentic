// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileMarkerAgreementTests.swift
//  DevgenticTests
//
//  The five MarkdownParser cold-read P3s (CR29, CR30, CR32, CR43, CR55), plus the one
//  guard outside the parser that CR55 needs in order to be safe.
//
//  The through-line is that DETECTION GATES STRIPPING: `strippingFileMarkerLines` runs only
//  when `consumedFileMarker` fired. So the two must agree about what a sentinel line is, and
//  the two ways of disagreeing fail very differently —
//
//    detection WIDER  → a visible sentinel and, on the Start branch, a bogus `.marker` claim
//                       that mc-6 exempts from the one-sibling bound (CR32).
//    detection NARROWER → silent: a line the strip would have removed renders raw.
//
//  Both branches now go through `FileMarkerLine.kind`, except the End branch, which stays a
//  loose `contains` ON PURPOSE — its errors cost a badge, never a write.
//

import XCTest
@testable import devgentic

@MainActor
private final class NoopChatStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

// MARK: - CR32: detection and stripping agree

@MainActor
final class FileMarkerAgreementTests: XCTestCase {

    private func firstCodeFileName(in markdown: String) -> String? {
        for block in parseMarkdown(markdown) {
            if case .code(_, _, let fileName) = block.type { return fileName }
        }
        return nil
    }

    private func paragraphs(_ markdown: String) -> [String] {
        parseMarkdown(markdown).compactMap {
            if case .paragraph(let text) = $0.type { return text }
            return nil
        }
    }

    /// ⚠️ THE CR32 PIN. Prose that merely QUOTES the sentinel used to arm a claim, because
    /// detection was an unanchored `firstMatch` over the whole node while stripping was
    /// line-anchored. Nothing was stripped (correctly — it is the author's sentence), so the
    /// sentinel showed AND an arbitrary later fence was badged with a filename the message never
    /// attached. `.marker` is the origin mc-6 exempts from the one-sibling bound, so the claim's
    /// reach was unlimited, and a name that collides with a real attachment puts Apply Changes'
    /// on-disk write one keystroke away.
    ///
    /// Mutation that must kill this: drop the line anchor — go back to matching the regex against
    /// the flattened text instead of scanning for a line whose `FileMarkerLine.kind` is `.start`.
    func testProseQuotingTheStartMarkerClaimsNothing() {
        let markdown = """
        I quoted --- Start of file: secret.txt --- in passing.

        ```swift
        let a = 1
        ```
        """
        XCTAssertNil(firstCodeFileName(in: markdown),
                     "a sentence that merely mentions the sentinel must not name the fence below it")
        XCTAssertTrue(paragraphs(markdown).contains { $0.contains("I quoted") },
                      "…and the author's sentence must survive intact")
    }

    /// The real injected shape is unaffected: marker on its own line, fence below.
    func testAMarkerOnItsOwnLineStillClaims() {
        let markdown = """
        --- Start of file: Notes.swift ---

        ```swift
        let a = 1
        ```
        """
        XCTAssertEqual(firstCodeFileName(in: markdown), "Notes.swift")
        XCTAssertFalse(paragraphs(markdown).contains { $0.contains("Start of file:") },
                       "the sentinel itself is never rendered")
    }

    /// The common merged shape — marker and the file's first lines in ONE paragraph, because the
    /// injector puts no blank line between them.
    func testAMergedMarkerParagraphKeepsItsContentAndStillClaims() {
        let markdown = """
        --- Start of file: Notes.swift ---
        the first real line
        and a second

        ```swift
        let a = 1
        ```
        """
        let text = paragraphs(markdown).joined(separator: "\n")
        XCTAssertTrue(text.contains("the first real line"), "file content must not vanish: \(text)")
        XCTAssertTrue(text.contains("and a second"))
        XCTAssertFalse(text.contains("Start of file:"), "…but the sentinel line is still removed")
        XCTAssertEqual(firstCodeFileName(in: markdown), "Notes.swift")
    }

    /// ⚠️ THE NARROWER-THAN-STRIPPING GUARD. A line can open with the sentinel and have its
    /// closing dashes on the NEXT line — the `includeAbsolutePaths` label runs past 70 characters,
    /// so it is the one marker this app makes long enough to invite a wrap. `strippingFileMarkerLines`
    /// removes that opener either way, so detection MUST fire on it or the raw sentinel renders and
    /// the badge is lost.
    ///
    /// Mutation that must kill this: run the capture regex against the marker line ALONE instead of
    /// from that line onward.
    func testAMarkerWhoseClosingDashesWrappedStillClaims() {
        let markdown = """
        --- Start of file: Main.swift
        (/Users/example/proj/Main.swift) ---

        ```swift
        let a = 1
        ```
        """
        XCTAssertEqual(firstCodeFileName(in: markdown), "Main.swift",
                       "a wrapped marker must still name the fence")
        XCTAssertFalse(paragraphs(markdown).contains { $0.contains("Start of file:") },
                       "and its opening line must not render")
    }

    /// An opener with no closing dashes anywhere is still a sentinel line by the shared predicate,
    /// so it is removed rather than published as prose — the shape a stream shows mid-flight.
    func testAnUnterminatedMarkerLineIsNotPublished() {
        XCTAssertFalse(paragraphs("--- Start of file: Main.swift").contains { $0.contains("Start of file:") },
                       "an unterminated sentinel must not reach the reader")
    }

    /// ⚠️ The End branch stays UNANCHORED on purpose, so this keeps working: over-clearing costs a
    /// badge, under-clearing would leave a `.marker` claim alive past the file body it belonged to.
    /// It also has to fire inside a block quote, where `format()` gives every line a `"> "` prefix.
    ///
    /// Mutation that must kill this: anchor the End branch the way the Start branch is anchored.
    func testTheEndMarkerStillClearsAClaimItDoesNotBeginItsLine() {
        let markdown = """
        --- Start of file: Notes.swift ---
        body

        the tail of the file --- End of file: Notes.swift ---

        ```swift
        let a = 1
        ```
        """
        XCTAssertNil(firstCodeFileName(in: markdown),
                     "the End marker must terminate the claim so the following fence is unbadged")
    }

    /// Control, and the pin from mc-15: prose that mentions the End marker keeps its sentence.
    func testProseMentioningTheEndMarkerSurvives() {
        XCTAssertTrue(paragraphs("I looked for the --- End of file: marker and found it")
                        .contains { $0.contains("I looked for the") })
    }

    /// The captured filename is what the app LINKS BY, so the marker text must never be
    /// normalised before the capture — `FileMarkerLine.kind` may strip backslashes because it only
    /// DECIDES; the capture must not, because it names a file.
    func testAFilenameContainingABackslashIsCapturedVerbatim() {
        let markdown = #"""
        --- Start of file: back\slash.txt ---

        ```swift
        let a = 1
        ```
        """#
        XCTAssertEqual(firstCodeFileName(in: markdown), #"back\slash.txt"#)
    }

    /// The em-dash spelling still works — it is what a marker became in the smart-punctuation era
    /// and what still arrives from a composer with smart dashes on.
    func testTheEmDashSpellingStillClaims() {
        let markdown = """
        — Start of file: Notes.swift —

        ```swift
        let a = 1
        ```
        """
        XCTAssertEqual(firstCodeFileName(in: markdown), "Notes.swift")
    }

    /// A marker inside a code span does not begin its line once the backticks are counted, so it
    /// claims nothing — the behaviour `InlineCode.plainText` keeping its backticks gives us.
    func testAMarkerInsideACodeSpanClaimsNothing() {
        let markdown = """
        The format is `--- Start of file: secret.txt ---` exactly.

        ```swift
        let a = 1
        ```
        """
        XCTAssertNil(firstCodeFileName(in: markdown))
    }
}

// MARK: - CR55: the absolute-path label

final class MarkerLabelPathTests: XCTestCase {

    /// ⚠️ THE CR55 PIN. Agent and code profiles label the injected marker `<name> (<path>)` so the
    /// model can write back to the right file. The whole decorated label used to become the claimed
    /// filename, so the badge read as a home path and linking — which matches `AttachedTextFile.name`,
    /// a bare name — matched nothing.
    ///
    /// Mutation that must kill this: return `label` unconditionally from `nameFromMarkerLabel`.
    func testTheAppsOwnLabelShapeYieldsTheBareName() {
        XCTAssertEqual(
            CodeFileNameInference.nameFromMarkerLabel("Main.swift (/Users/example/proj/Main.swift)"),
            "Main.swift")
        XCTAssertEqual(
            CodeFileNameInference.nameFromMarkerLabel("Makefile (/Users/example/proj/Makefile)"),
            "Makefile")
    }

    /// ⚠️ The self-consistency check is what makes this safe. A real file whose NAME ends in a
    /// path-shaped parenthetical has the same surface shape, and truncating it would break a link
    /// that works today. The last path component must EQUAL the leading part.
    ///
    /// Mutation that must kill this: drop the `lastPathComponent == name` guard.
    func testANameThatMerelyLooksLikeTheShapeIsKeptWhole() {
        XCTAssertEqual(CodeFileNameInference.nameFromMarkerLabel("snapshot (~/Documents)"),
                       "snapshot (~/Documents)",
                       "the parenthetical is not this file's own path — keep the name verbatim")
        XCTAssertEqual(CodeFileNameInference.nameFromMarkerLabel("report (final).pdf"),
                       "report (final).pdf")
        XCTAssertEqual(CodeFileNameInference.nameFromMarkerLabel("Main.swift (/Users/example/Other.swift)"),
                       "Main.swift (/Users/example/Other.swift)")
    }

    /// The scan is balanced, so parentheses in the name itself survive.
    ///
    /// Mutation that must kill this: replace the balanced walk with `firstIndex(of: "(")`.
    func testParenthesesInsideTheNameSurvive() {
        XCTAssertEqual(
            CodeFileNameInference.nameFromMarkerLabel("notes (v1).txt (/Users/example/notes (v1).txt)"),
            "notes (v1).txt")
    }

    /// A plain name is untouched — the bot-profile label shape.
    func testAPlainNameIsUntouched() {
        XCTAssertEqual(CodeFileNameInference.nameFromMarkerLabel("Main.swift"), "Main.swift")
        XCTAssertEqual(CodeFileNameInference.nameFromMarkerLabel(""), "")
    }

    /// End to end through the parser: the badge is the bare name.
    func testTheFenceIsBadgedWithTheBareName() {
        let markdown = """
        --- Start of file: Main.swift (/Users/example/proj/Main.swift) ---

        ```swift
        let a = 1
        ```
        """
        let name: String? = parseMarkdown(markdown).compactMap {
            if case .code(_, _, let fileName) = $0.type { return fileName }
            return nil
        }.first ?? nil
        XCTAssertEqual(name, "Main.swift",
                       "the badge must not carry the user's absolute home path")
    }
}

// MARK: - CR29: the streaming zero-block fallback

final class StreamingMarkerSuppressionTests: XCTestCase {

    private func paragraphs(_ blocks: [ContentBlock]) -> [String] {
        blocks.compactMap {
            if case .paragraph(let text) = $0.type { return text }
            return nil
        }
    }

    /// ⚠️ THE CR29 PIN. `parseMarkdown` guards its zero-block fallback with the marker strip —
    /// a node that is nothing but a sentinel is consumed on PURPOSE, so zero blocks there is
    /// deliberate. The streaming parser mirrored the fallback without the guard, so mid-stream it
    /// resurrected the raw sentinel as prose and the user watched it sit in the bubble.
    ///
    /// Mutation that must kill this: delete the `strippingFileMarkerLines` test from the streaming
    /// fallback.
    func testAMarkerOnlyStreamRendersNothingRatherThanTheSentinel() {
        let blocks = StreamingMarkdownParser().parse("--- Start of file: x.swift ---")
        XCTAssertFalse(paragraphs(blocks).contains { $0.contains("Start of file:") },
                       "the sentinel must never be published as prose: \(paragraphs(blocks))")
        XCTAssertEqual(blocks.count, 0, "a marker-only stream renders no blocks at all")
    }

    /// …and the streaming parser now agrees with the authoritative full parse on that input,
    /// which is the invariant the asymmetry actually broke.
    func testStreamingAgreesWithTheFullParseOnMarkerOnlyInput() {
        let text = "--- Start of file: x.swift ---"
        XCTAssertEqual(StreamingMarkdownParser().parse(text), parseMarkdown(text))
    }

    /// The fallback is NOT disabled — genuinely malformed, non-marker input still shows raw text
    /// instead of a blank bubble.
    ///
    /// Mutation that must kill this: make the streaming fallback unconditional in the other
    /// direction (never fall back).
    func testOrdinaryStreamedTextStillRenders() {
        let blocks = StreamingMarkdownParser().parse("Just a normal paragraph.")
        XCTAssertEqual(paragraphs(blocks).first, "Just a normal paragraph.")
    }

    /// A marker followed by real content behaves exactly as the full parse does.
    func testAMarkerFollowedByContentStillRendersTheContent() {
        let text = "--- Start of file: x.swift ---\nthe first real line"
        let blocks = StreamingMarkdownParser().parse(text)
        let text0 = paragraphs(blocks).joined()
        XCTAssertTrue(text0.contains("the first real line"))
        XCTAssertFalse(text0.contains("Start of file:"))
    }
}

// MARK: - CR55 companion: ambiguity fails closed

@MainActor
final class AmbiguousSourceFileLinkTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()

    override func setUp() async throws {
        let store = NoopChatStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            )
        )
    }

    override func tearDown() async throws {
        viewModel = nil
    }

    private func lines(_ label: String, _ count: Int) -> String {
        (1...count).map { "print(\"\(label) \($0)\")" }.joined(separator: "\n")
    }

    private func userMessageAttaching(name: String, path: String) -> ChatMessage {
        let content = lines(path, 60)
        return ChatMessage(
            conversationId: conversationID,
            sender: .user,
            content: .plainText("Here is the file"),
            attachedTextFiles: [AttachedTextFile(
                name: name,
                url: URL(fileURLWithPath: path),
                fileExtension: "tsx",
                content: content,
                size: Int64(content.count)
            )]
        )
    }

    private func agentMessageNaming(_ name: String) -> ChatMessage {
        ChatMessage(
            conversationId: conversationID,
            sender: .agent,
            content: .markdownText("""
            --- Start of file: \(name) ---

            ```tsx
            \(lines("REWRITTEN", 60))
            ```
            """)
        )
    }

    /// ⚠️ THE GUARD CR55 NEEDS. Linking resolves by BARE NAME, and the attach path dedupes on URL,
    /// so two files called `page.tsx` from different directories can both be attached. Taking the
    /// first match stamps `sourceFileID` for the wrong one, which flips `canSaveAndClose` and puts
    /// `performApplyChanges` — an atomic overwrite — one keystroke away. The drift guard cannot see
    /// it: it compares that file's own baseline against its own disk, which match.
    ///
    /// Before CR55 the decorated label matched nothing and this failed closed by accident. Now that
    /// the label resolves, the refusal has to be deliberate.
    ///
    /// Mutation that must kill this: return the first match instead of nil when `matches.count > 1`.
    func testANameMatchingTwoAttachmentsRefusesToLink() {
        let message = agentMessageNaming("page.tsx")
        viewModel.currentChatMessages = [
            userMessageAttaching(name: "page.tsx", path: "/tmp/web/app/page.tsx"),
            userMessageAttaching(name: "page.tsx", path: "/tmp/docs/app/page.tsx"),
            message
        ]

        viewModel.openMessageInCodeViewer(message: message)

        guard let tab = viewModel.activeCodeViewerTab else { return XCTFail("Viewer never opened") }
        XCTAssertNil(tab.snippet.sourceFileID,
                     "an ambiguous name must not link — linking would pick one by attachment order")
        XCTAssertNil(tab.snippet.sourceMessageID)
    }

    /// The unambiguous case still links, so the guard is a refusal and not a disablement.
    ///
    /// Mutation that must kill this: return nil unconditionally.
    func testASingleMatchStillLinks() {
        let message = agentMessageNaming("page.tsx")
        viewModel.currentChatMessages = [
            userMessageAttaching(name: "page.tsx", path: "/tmp/web/app/page.tsx"),
            userMessageAttaching(name: "other.tsx", path: "/tmp/docs/app/other.tsx"),
            message
        ]

        viewModel.openMessageInCodeViewer(message: message)

        guard let tab = viewModel.activeCodeViewerTab else { return XCTFail("Viewer never opened") }
        XCTAssertNotNil(tab.snippet.sourceFileID, "an unambiguous name must still link")
    }
}


// MARK: - CR61 + CR62: the sentinel SPAN goes, the line stays

/// ⚠️ THE RULE THESE PIN. `strippingFileMarkerLines` may remove a sentinel and may RECOVER prose
/// that used to be deleted — but it must never delete anything the old code rendered, and never
/// publish a sentinel the old code hid. Every case span removal cannot resolve falls back to the
/// old whole-line predicate, which is what makes widening the gate to quoted lines safe.
@MainActor
final class MarkerSpanStrippingTests: XCTestCase {

    private func paragraphs(_ markdown: String) -> [String] {
        var out: [String] = []
        func walk(_ blocks: [ContentBlock]) {
            for b in blocks {
                switch b.type {
                case .paragraph(let t): out.append(t)
                case .blockquote(let inner): walk(inner)
                default: break
                }
            }
        }
        walk(parseMarkdown(markdown))
        return out
    }

    private func firstCodeFileName(in markdown: String) -> String? {
        for block in parseMarkdown(markdown) {
            if case .code(_, _, let fileName) = block.type { return fileName }
        }
        return nil
    }

    // MARK: CR62 — prose sharing a line with a sentinel

    /// ⚠️ THE CR62 PIN. Measured before the fix: this produced ZERO blocks — the whole sentence
    /// was eaten and the message rendered as a blank bubble.
    /// Mutation that must kill this: go back to dropping a sentinel line whole.
    func testProseAfterASentinelOnTheSameLineSurvives() {
        let text = paragraphs("--- End of file: config.yaml --- and that is everything I changed.")
        XCTAssertEqual(text.count, 1, "the sentence must render, not vanish: \(text)")
        XCTAssertTrue(text.first?.contains("and that is everything I changed.") == true,
                      "got \(text)")
        XCTAssertFalse(text.first?.contains("End of file:") == true, "…without the sentinel")
    }

    /// The Start spelling, and the claim must still reach the fence.
    func testProseAfterAStartSentinelSurvivesAndStillClaims() {
        let markdown = """
        --- Start of file: Notes.swift --- here is the file you asked for

        ```swift
        let a = 1
        ```
        """
        XCTAssertTrue(paragraphs(markdown).contains { $0.contains("here is the file you asked for") },
                      "got \(paragraphs(markdown))")
        XCTAssertEqual(firstCodeFileName(in: markdown), "Notes.swift")
    }

    /// ⚠️ [CR62 + CR17] Span removal makes a residue that STARTS with a block marker reachable for
    /// the first time. `AttributedString(markdown:)` eats a leading `1.`, so it must be escaped —
    /// the same treatment `appendTextRun` gives a run after an inline image.
    /// Mutation that must kill this: drop `escapingLeadingBlockSyntax` from the remainder.
    func testARecoveredResidueKeepsALeadingListMarker() {
        let text = paragraphs("--- End of file: x.txt --- 1. renumbered").joined()
        XCTAssertTrue(text.contains("1"), "the author's numbering must survive: \(text.debugDescription)")
        XCTAssertTrue(text.hasPrefix("1\\."),
                      "the marker must be ESCAPED or the renderer eats it: \(text.debugDescription)")
    }

    // MARK: CR61 — a marker inside a block quote

    /// ⚠️ THE CR61 PIN. `format()` prefixes every line with "> ", so the sentinel test never fired
    /// and the raw marker rendered inside the quote — while detection, which reads the undecorated
    /// line-structured plain text, armed the claim anyway.
    /// Mutation that must kill this: stop splitting the quote prefix off before `kind`.
    func testAMarkerInsideABlockQuoteIsNotRendered() {
        let text = paragraphs("> --- Start of file: X.swift ---\n> body").joined(separator: "\n")
        XCTAssertFalse(text.contains("Start of file:"),
                       "the sentinel must not survive inside a quote: \(text.debugDescription)")
        XCTAssertTrue(text.contains("body"), "…and the quoted content must remain: \(text.debugDescription)")
    }

    /// Ordinary quoted prose must be byte-identical — the prefix is put back on the output, and
    /// only marker lines are touched at all.
    func testOrdinaryQuotedProseIsUntouched() {
        XCTAssertEqual(paragraphs("> just some quoted prose\n> second line"),
                       ["> just some quoted prose\n> second line"])
    }

    // MARK: Monotonicity — never delete what renders today

    /// ⚠️ THE GUARD BOTH REFUTERS DEMANDED. Widening the gate to quoted lines means every
    /// whole-line fallback becomes a NEW deletion on input that renders today. A closer with no
    /// trailing whitespace does not match the span, so this line must come through VERBATIM.
    /// Mutation that must kill this: drop the line when no span matched, regardless of prefix.
    func testAQuotedLineWhoseSpanCannotBeResolvedIsKeptWhole() {
        let text = paragraphs("> --- End of file: x.txt ---. And my note.").joined()
        XCTAssertTrue(text.contains("And my note."),
                      "prose that renders today must not start disappearing: \(text.debugDescription)")
    }

    /// The same rule for a quoted marker whose closing dashes wrapped to the next line.
    func testAQuotedWrappedMarkerKeepsBothLines() {
        let text = paragraphs("> --- Start of file: Main.swift\n> (/Users/example/proj/Main.swift) ---").joined()
        XCTAssertTrue(text.contains("Main.swift"), "nothing may be deleted here: \(text.debugDescription)")
    }

    /// ⚠️ A `---` inside the FILENAME must not truncate the span — that would publish
    /// `file.txt ---` as visible debris where the whole line is hidden today. The `(?=\s|$)`
    /// lookahead is what prevents it.
    /// Mutation that must kill this: drop the lookahead from `sentinelSpan`.
    func testAFilenameContainingDashesDoesNotLeaveDebris() {
        let text = paragraphs("--- Start of file: my---file.txt ---").joined()
        XCTAssertFalse(text.contains("file.txt"),
                       "no filename debris may be published: \(text.debugDescription)")
    }

    /// An ESCAPED sentinel is still hidden. ⚠️ This does NOT exercise the residue guard, though it
    /// reads as if it should: cmark resolves the `\-` escape during inline parsing, so the
    /// backslash is gone long before the strip sees the text and the span matches cleanly. Pinned
    /// because that resolution is the reason `FileMarkerLine.kind`'s own backslash removal only
    /// matters on the RAW substrate.
    func testAnEscapedSentinelIsStillHidden() {
        let text = paragraphs(#"\--- Start of file: x.txt ---"#).joined()
        XCTAssertFalse(text.contains("Start of file:"), "got \(text.debugDescription)")
    }

    /// ⚠️ THE RESIDUE-GUARD PIN. A four-dash marker — a shape models write constantly — leaves one
    /// stray `-` behind after the span comes out. A punctuation-only residue must not keep the
    /// line alive, or that dash is published as prose. `isEmpty` is NOT the test: `-` is not blank.
    /// Mutation that must kill this: test the residue with `isEmpty` instead of letter-or-digit.
    func testAFourDashMarkerLeavesNoStrayDash() {
        let text = paragraphs("---- Start of file: x.txt ----").joined()
        XCTAssertTrue(text.isEmpty,
                      "a marker-only line must render nothing at all, not leftover punctuation: \(text.debugDescription)")
    }

    /// A stranded half-sentinel — one marker's closer eaten as another's opener — must never be
    /// published.
    /// Mutation that must kill this: remove the residual-sentinel post-condition.
    func testAStrandedHalfSentinelIsNeverPublished() {
        let text = paragraphs("--- Start of file: a.txt --- End of file: b.txt ---").joined()
        XCTAssertFalse(text.contains("End of file:"), "got \(text.debugDescription)")
    }
}

// MARK: - The emptiness verdict, kept separate from the render strip

final class FileMarkerEmptinessTests: XCTestCase {

    /// ⚠️ THE TWO-SUBSTRATE PIN. The raw-text callers ask about EMPTINESS; the block branches ask
    /// for RENDERED TEXT. Answering both with one function coupled substrates that disagree:
    /// raw text still spells `&nbsp;` (letters!) where `format()` carries a decoded U+00A0, and a
    /// disagreement flips `parseMarkdown` between rendering nothing and republishing the sentinel.
    /// Mutation that must kill this: route the raw callers back through `strippingFileMarkerLines`.
    func testAnEntityAfterASentinelDoesNotRepublishTheRawText() {
        let blocks = parseMarkdown("--- End of file: x.txt --- &nbsp;")
        let text = blocks.compactMap { b -> String? in
            if case .paragraph(let t) = b.type { return t }
            return nil
        }.joined()
        XCTAssertFalse(text.contains("End of file:"),
                       "the raw sentinel must never be republished: \(text.debugDescription)")
    }

    /// CRLF: `"\r\n"` is ONE Swift Character, so `split(separator: "\n")` sees an all-CRLF
    /// document as a SINGLE line — the identical bug mc-14 fixed in `lastSafeBoundary`.
    /// Mutation that must kill this: split on `"\n"` instead of `\.isNewline`.
    func testTheEmptinessVerdictSeesCRLFLines() {
        XCTAssertTrue(FileMarkerLine.isNothingButFileMarkers("--- Start of file: a.txt ---\r\n--- End of file: a.txt ---"))
        XCTAssertFalse(FileMarkerLine.isNothingButFileMarkers("--- Start of file: a.txt ---\r\nreal content"),
                       "real content after a CRLF must be seen")
    }

    /// ⚠️ THE SAME PIN, ON THE STREAMING CALLER. `parseMarkdown` and `StreamingMarkdownParser` are
    /// two separate raw-text callers and each has to ask the emptiness question itself; a test on
    /// one says nothing about the other. Routing this one back through the render strip republishes
    /// the whole raw sentinel mid-stream, because the strip sees `&nbsp;` as letters while the
    /// block branches see a decoded U+00A0 that trims to nothing.
    /// Mutation that must kill this: `strippingFileMarkerLines(from: fullText).isEmpty` here.
    func testStreamingDoesNotRepublishTheRawSentinelForAnEntityResidue() {
        let blocks = StreamingMarkdownParser().parse("--- End of file: x.txt --- &nbsp;")
        let text = blocks.compactMap { b -> String? in
            if case .paragraph(let t) = b.type { return t }
            return nil
        }.joined()
        XCTAssertFalse(text.contains("End of file:"),
                       "the raw sentinel must never be republished mid-stream: \(text.debugDescription)")
    }

    /// Blank and marker-only inputs.
    func testVerdictBasics() {
        XCTAssertTrue(FileMarkerLine.isNothingButFileMarkers("--- Start of file: a.txt ---"))
        XCTAssertTrue(FileMarkerLine.isNothingButFileMarkers("> --- Start of file: a.txt ---"))
        XCTAssertFalse(FileMarkerLine.isNothingButFileMarkers("ordinary prose"))
        XCTAssertFalse(FileMarkerLine.isNothingButFileMarkers("   "), "blank input is not 'all markers'")
    }
}
