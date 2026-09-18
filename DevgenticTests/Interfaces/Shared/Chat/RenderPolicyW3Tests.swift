// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RenderPolicyW3Tests.swift
//  DevgenticTests
//
//  P3 batch W3, the render/view half: render/mc-10, render/mc-12, render/mc-13, timeline/tc-6,
//  views/bm-2, views/bm-8. Each class below names the row it pins and what the defect was.
//

import XCTest
@testable import devgentic

// MARK: - render/mc-10

/// The table's spoken strings were implemented TWICE: `TableSpeech`, which every assertion in
/// `ChatAccessibilitySemanticsTests` pins, and a private `spokenLabel` on `TableCellView`, which
/// is what production actually called. The two had already drifted — the tested one trims the
/// header before deciding it is empty, the shipping one did not — so a whitespace-only header
/// spoke "   , 42" on screen and "42" in the suite, and the localized copies of all four strings
/// sat unused in the catalog while English literals shipped.
final class TableSpokenLabelRoutingTests: XCTestCase {

    /// THE pin: the function both of the table's `accessibilityLabel`s call routes to the
    /// TESTED helpers — header cells one way, data cells the other.
    func testTheViewsLabelRoutesToTheTestedHelpers() {
        XCTAssertEqual(
            TableSpeech.label(value: "42", header: "Count", isHeader: false),
            TableSpeech.cellLabel(value: "42", header: "Count")
        )
        XCTAssertEqual(
            TableSpeech.label(value: "Count", header: "", isHeader: true),
            TableSpeech.headerCellLabel(value: "Count")
        )
        // The two arms must actually differ — a router that ignored `isHeader` would satisfy
        // one of the equalities above by accident.
        XCTAssertNotEqual(
            TableSpeech.label(value: "Count", header: "Count", isHeader: true),
            TableSpeech.label(value: "Count", header: "Count", isHeader: false)
        )
    }

    /// The drift itself, pinned in the direction the tested version defines: a header that is
    /// only whitespace is no header, so the value is spoken alone.
    func testWhitespaceOnlyHeaderIsNotSpoken() {
        XCTAssertEqual(TableSpeech.label(value: "42", header: "   ", isHeader: false), "42")
        XCTAssertEqual(TableSpeech.label(value: "42", header: "", isHeader: false), "42")
    }

    /// An empty cell must SAY it is empty — silence reads as a bug, and this is the behaviour
    /// the shipping path now inherits from the tested one.
    func testEmptyCellSaysEmptyAndKeepsItsColumn() {
        let spoken = TableSpeech.label(value: "   ", header: "Status", isHeader: false)
        XCTAssertTrue(spoken.hasPrefix("Status, "), spoken)
        XCTAssertTrue(spoken.localizedCaseInsensitiveContains("empty"), spoken)
    }

    func testUnnamedHeaderIsAnnounced() {
        XCTAssertEqual(TableSpeech.label(value: "  ", header: "", isHeader: true),
                       TableSpeech.headerCellLabel(value: ""))
        XCTAssertTrue(TableSpeech.headerCellLabel(value: "").localizedCaseInsensitiveContains("unnamed"))
    }

    /// The header ROW's label is its own string: `rowLabel(index:of:)` cannot express it, which
    /// is why it was an inline literal at the call site — and how it escaped localization.
    func testHeaderRowLabelIsItsOwnStringNotRowZero() {
        XCTAssertEqual(TableSpeech.headerRowLabel, "Column headers")
        XCTAssertNotEqual(TableSpeech.headerRowLabel, TableSpeech.rowLabel(index: 0, of: 1))
        XCTAssertEqual(TableSpeech.rowLabel(index: 0, of: 7), "Row 1 of 7")
    }
}

// MARK: - render/mc-12

/// Two line counters decide different things about the same block — `CodeBlockView`'s decides
/// the scroll cap and the header's "N lines", `CodeSnippet`'s decides the card/inline boundary
/// and which snippets the viewer will open. `CodeSnippet.isLarge`'s own doc records what
/// happens when they disagree: a block renders a card the viewer's filter excludes, so the
/// user's click cannot reach the snippet they clicked.
final class CodeBlockLineCountAgreementTests: XCTestCase {

    /// THE pin, and the reason the "faster" newline count was rejected: CharacterSet splitting
    /// treats CRLF as two separators, so the two forms disagree by 2 on a 3-line CRLF file.
    ///
    /// Composed the way `body` composes it — the view counts its `displayContent`, not the raw
    /// block — so this compares what the header shows against what the card/viewer boundary
    /// decides, for every content shape an ordinary fence produces.
    func testBothCountersAgreeIncludingOnCRLFAndTrailingNewlines() {
        for code in ["a\nb\nc", "a\r\nb\r\nc", "", "one line", "trailing\n", "trailing\r\n",
                     "many\n\n\n", "a\n\nb"] {
            XCTAssertEqual(CodeBlockView.lineCount(of: CodeBlockView.displayContent(of: code)),
                           CodeSnippet.lineCount(codeBlockContent: code),
                           "counters disagree for \(code.debugDescription)")
        }
    }

    /// ⚠️ The one shape where they DO differ, pinned so it is on record rather than discovered
    /// again: a block that opens with blank lines. `CodeSnippet` trims both ends; the view
    /// strips trailing newlines only, because its value feeds the RENDERER and dropping leading
    /// blank lines would change what is drawn. Pre-existing — both sides are byte-identical to
    /// their pre-[mc-12] form.
    ///
    /// It is cosmetic because the DANGEROUS pair agree with each other: the card/inline
    /// boundary and the viewer's `largeSnippets` filter both use `CodeSnippet`, so a block can
    /// never render a card the viewer then refuses to open — the failure `CodeSnippet.isLarge`
    /// documents. Only the "N lines" badge over-reports, by the number of leading blank lines.
    func testLeadingBlankLinesAreCountedByTheBadgeButNotByTheBoundary() {
        let withLeadingBlanks = "\n\ncode\nmore"

        XCTAssertEqual(CodeBlockView.lineCount(of: CodeBlockView.displayContent(of: withLeadingBlanks)), 4)
        XCTAssertEqual(CodeSnippet.lineCount(codeBlockContent: withLeadingBlanks), 2)
    }

    /// A sanity anchor on the CRLF value itself, so a change to EITHER counter that happens to
    /// keep them equal still has to be deliberate.
    func testCRLFCountIsTheCharacterSetSplitValue() {
        XCTAssertEqual(CodeBlockView.lineCount(of: "a\r\nb\r\nc"), 5)
        XCTAssertEqual(CodeBlockView.lineCount(of: "a\nb\nc"), 3)
        XCTAssertEqual(CodeBlockView.lineCount(of: ""), 0)
    }

    /// The display trim itself: trailing newlines only, and every spelling of them. A block's
    /// leading content and its interior are untouched.
    ///
    /// ⚠️ THE CRLF CASE IS THE POINT. `"\r\n"` is ONE Swift Character, so the old
    /// `hasSuffix("\n") || hasSuffix("\r")` loop was false on the first test and stopped: a
    /// block written with Windows line endings kept the phantom trailing line this function
    /// exists to strip. Found while pinning the counters; it predates [mc-12].
    func testDisplayContentStripsEveryTrailingNewlineIncludingCRLF() {
        XCTAssertEqual(CodeBlockView.displayContent(of: "code\n\n"), "code")
        XCTAssertEqual(CodeBlockView.displayContent(of: "code\r\n"), "code")
        XCTAssertEqual(CodeBlockView.displayContent(of: "code\r\n\r\n"), "code")
        XCTAssertEqual(CodeBlockView.displayContent(of: "code\r"), "code")
        XCTAssertEqual(CodeBlockView.displayContent(of: "  indented\n"), "  indented")
        XCTAssertEqual(CodeBlockView.displayContent(of: "\ncode"), "\ncode", "leading blanks are the renderer's, not ours to drop")
        XCTAssertEqual(CodeBlockView.displayContent(of: "a\r\nb\r\n"), "a\r\nb", "interior line endings survive")
    }

    /// The user-visible consequence of the CRLF trim, in the terms the header shows: a
    /// one-line block written with Windows line endings reports one line, not three.
    func testACRLFTerminatedOneLinerReportsOneLine() {
        XCTAssertEqual(CodeBlockView.lineCount(of: CodeBlockView.displayContent(of: "print(1)\r\n")), 1)
        XCTAssertEqual(CodeSnippet.lineCount(codeBlockContent: "print(1)\r\n"), 1)
    }
}

// MARK: - render/mc-13

/// The table re-measured every visible cell on every `body` pass, under a comment claiming
/// `body` "only re-runs when the content actually changes" — which SwiftUI does not guarantee.
/// The measurement is memoized now; this pins the property that makes that safe, since the
/// previous cache (2026-07-16) was keyed at first APPEARANCE and could not notice a streaming
/// table growing under it.
final class TableWidthCacheKeyTests: XCTestCase {

    private let headers = ["Name", "Count"]
    private let rows = [["a", "1"], ["b", "2"]]

    private func key(fontSize: CGFloat = 12, columnCount: Int = 2,
                     headers: [String]? = nil, rows: [[String]]? = nil) -> Int {
        MarkdownTableView.widthKey(fontSize: fontSize, columnCount: columnCount,
                                   headers: headers ?? self.headers, rows: rows ?? self.rows)
    }

    func testSameContentSameKey() {
        XCTAssertEqual(key(), key())
    }

    /// THE pin: a table that GROWS gets a new key. This is the exact staleness that made the
    /// old cache hand back a widths array shorter than the row it was indexing.
    func testAGrowingTableGetsANewKey() {
        XCTAssertNotEqual(key(), key(rows: rows + [["c", "3"]]))
    }

    /// Every other input that can move a measured width.
    func testEveryMeasuredInputIsInTheKey() {
        XCTAssertNotEqual(key(), key(fontSize: 13), "font size changes every width")
        XCTAssertNotEqual(key(), key(columnCount: 3), "a ragged row adds a column to measure")
        XCTAssertNotEqual(key(), key(headers: ["Name", "Total"]), "headers are measured bold")
        XCTAssertNotEqual(key(), key(rows: [["a", "1"], ["b", "22222222"]]), "a widened cell")
    }

    /// Cell content moving BETWEEN rows is a different table, not the same one.
    func testReorderedRowsGetANewKey() {
        XCTAssertNotEqual(key(), key(rows: [["b", "2"], ["a", "1"]]))
    }
}

// MARK: - timeline/tc-6

/// The chevron and the disclosure disagreed: `hasDetail` counted any non-empty summary, while
/// the disclosure rendered one only for `.completed`. A `.cancelled` subtask grew a chevron that
/// expanded to nothing AND had its intermediate answer reachable from nowhere; a `.failed`
/// step's reason past two lines was readable only in the clamped collapsed row.
final class CapabilityStepDisclosureTests: XCTestCase {

    private func step(_ status: PlanStepStatus, summary: String?, events: Int = 0) -> PlanStepData {
        PlanStepData(id: "s", title: "Step", status: status, summary: summary,
                     events: (0..<events).map { .thought(id: UUID(), text: "e\($0)") })
    }

    /// THE pin: a non-completed step's summary is now disclosed. Previously nothing rendered it.
    func testCancelledAndFailedStepsDiscloseTheirSummary() {
        XCTAssertEqual(PlanProgressCard.disclosedSummary(step(.cancelled, summary: "Partial answer")), "Partial answer")
        XCTAssertEqual(PlanProgressCard.disclosedSummary(step(.failed, summary: "Timed out after 3 retries")),
                       "Timed out after 3 retries")
        XCTAssertEqual(PlanProgressCard.disclosedSummary(step(.warning, summary: "Degraded")), "Degraded")
        XCTAssertEqual(PlanProgressCard.disclosedSummary(step(.completed, summary: "Found 3 files")), "Found 3 files")
    }

    /// The capability's own synthetic summary is not worth a disclosure — the meta label
    /// already says it. This guard is what stops a clean step growing a pointless chevron.
    func testSyntheticCompletedSummaryIsNotDisclosed() {
        XCTAssertNil(PlanProgressCard.disclosedSummary(step(.completed, summary: "Completed (0 tool calls)")))
        XCTAssertNil(PlanProgressCard.disclosedSummary(step(.completed, summary: "Completed (7 tool calls)")))
    }

    func testNoSummaryDisclosesNothing() {
        XCTAssertNil(PlanProgressCard.disclosedSummary(step(.running, summary: nil)))
        XCTAssertNil(PlanProgressCard.disclosedSummary(step(.completed, summary: "")))
    }

    /// The chevron's predicate and the disclosure's are now ONE decision, so an empty
    /// expansion is impossible: a chevron appears only where events or a summary will render.
    func testChevronAndDisclosureCannotDisagree() {
        let cases: [PlanStepData] = [
            step(.completed, summary: "Completed (0 tool calls)"),          // no chevron, nothing to show
            step(.cancelled, summary: "Partial answer"),                    // chevron, summary
            step(.running, summary: nil, events: 2),                        // chevron, events
            step(.completed, summary: "Completed (2 tool calls)", events: 1) // chevron, events only
        ]
        for step in cases {
            let hasDetail = !step.events.isEmpty || PlanProgressCard.disclosedSummary(step) != nil
            let willRender = !step.events.isEmpty || PlanProgressCard.disclosedSummary(step) != nil
            XCTAssertEqual(hasDetail, willRender, "\(step.status) / \(step.summary ?? "nil")")
        }
        XCTAssertFalse(!cases[0].events.isEmpty || PlanProgressCard.disclosedSummary(cases[0]) != nil,
                       "a step with only a synthetic summary must grow no chevron at all")
    }
}

// MARK: - views/bm-2

/// Any change of the newest message id scrolled the transcript to the bottom, with the view's
/// own "the user has scrolled away" signal never consulted. Reading back through a long
/// conversation while a ChatOps message arrived for the conversation on screen — or while a
/// scheduled run posted into it — threw the reader back to the bottom mid-sentence.
final class FollowNewestPolicyTests: XCTestCase {

    private func message(_ source: MessageSource, sender: SenderRole = .user) -> ChatMessage {
        let m = ChatMessage(conversationId: UUID(), sender: sender, content: .plainText("hi"))
        m.messageSource = source
        return m
    }

    /// THE pin: a remote message does NOT yank a reader who has scrolled away.
    func testRemoteMessageDoesNotYankAReaderWhoHasScrolledAway() {
        for source in [MessageSource.telegram, .discord, .slack, .orb] {
            XCTAssertFalse(
                ChatHistoryView.shouldFollowNewest(isLocallyTyped: ChatHistoryView.isLocallyTyped(message(source)),
                                                   isAwayFromBottom: true),
                "\(source) must not scroll a reader who is away from the bottom")
        }
    }

    /// …but it still follows when the reader IS at the bottom, which is where a live
    /// conversation is normally watched.
    func testRemoteMessageStillFollowsAtTheBottom() {
        XCTAssertTrue(
            ChatHistoryView.shouldFollowNewest(isLocallyTyped: ChatHistoryView.isLocallyTyped(message(.telegram)),
                                               isAwayFromBottom: false))
    }

    /// The half that "gate on showScrollToBottom alone" would have broken: after a long
    /// streamed answer the button is already showing, and the user's OWN next message must
    /// still scroll into view.
    func testLocallyTypedMessageAlwaysFollowsEvenWhenAwayFromBottom() {
        XCTAssertTrue(ChatHistoryView.shouldFollowNewest(
            isLocallyTyped: ChatHistoryView.isLocallyTyped(message(.localUI)), isAwayFromBottom: true))
        XCTAssertTrue(ChatHistoryView.shouldFollowNewest(
            isLocallyTyped: ChatHistoryView.isLocallyTyped(message(.quickAccess)), isAwayFromBottom: true))
    }

    /// The half that "gate on sender == .user" would have broken: a ChatOps message IS a user
    /// message. `messageSource` is the only field that separates them.
    func testARemoteUserMessageIsNotLocallyTyped() {
        XCTAssertEqual(message(.telegram).sender, .user, "sanity: the filed case really is a user message")
        XCTAssertFalse(ChatHistoryView.isLocallyTyped(message(.telegram)))
        XCTAssertTrue(ChatHistoryView.isLocallyTyped(message(.localUI)))
    }

    /// An agent message is never "locally typed" — nobody typed it — so a streamed answer
    /// follows only when the reader is at the bottom. That is what keeps a long answer from
    /// dragging a reader who scrolled up to re-read something.
    func testAgentMessagesFollowOnlyAtTheBottom() {
        let agent = message(.localUI, sender: .agent)
        XCTAssertFalse(ChatHistoryView.isLocallyTyped(agent))
        XCTAssertFalse(ChatHistoryView.shouldFollowNewest(isLocallyTyped: false, isAwayFromBottom: true))
        XCTAssertTrue(ChatHistoryView.shouldFollowNewest(isLocallyTyped: false, isAwayFromBottom: false))
    }
}

// MARK: - views/bm-8

/// Saving an attached image from the LIGHTBOX slugified its filename and then appended the
/// sniffed extension: "Screenshot 2026-09-11.png" was written as
/// "screenshot-2026-09-11-png.png", while the same image saved from the card's own context
/// menu was written correctly. The two routes disagreed.
final class LightboxSaveNameTests: XCTestCase {

    /// THE pin: a real filename is used verbatim, so the extension is not slugified into the
    /// name and then re-appended.
    func testAFileNameIsUsedVerbatim() {
        XCTAssertEqual(
            ImageLightbox.suggestedBaseName(altText: "Screenshot 2026-09-11.png",
                                            fileBaseName: "Screenshot 2026-09-11"),
            "Screenshot 2026-09-11")
    }

    /// Prose keeps the slug path. This is why the extension is stripped by the CALLER and not
    /// inside this function: a blanket `deletingPathExtension` turns "diagram.of.the.system"
    /// into "diagram.of.the".
    func testProseLabelsStillSlugifyAndAreNotTreatedAsFilenames() {
        XCTAssertEqual(ImageLightbox.suggestedBaseName(altText: "A cat on a mat", fileBaseName: nil),
                       "a-cat-on-a-mat")
        XCTAssertEqual(ImageLightbox.suggestedBaseName(altText: "diagram.of.the.system", fileBaseName: nil),
                       "diagram-of-the-system")
    }

    /// The generated-image fallback is unchanged: no label, no filename, still a unique name
    /// `ImageExport.uniqueURL` can work with.
    func testNoLabelStillYieldsAUniqueFallbackName() {
        let a = ImageLightbox.suggestedBaseName(altText: nil, fileBaseName: nil)
        let b = ImageLightbox.suggestedBaseName(altText: "", fileBaseName: nil)
        XCTAssertTrue(a.hasPrefix("devgentic-image-"), a)
        XCTAssertTrue(b.hasPrefix("devgentic-image-"), b)
        XCTAssertNotEqual(a, b, "the fallback must be unique per call")
    }

    /// A whitespace-only filename is no filename — fall through rather than hand
    /// `saveToDownloads` a base name it cannot make unique.
    func testBlankFileNameFallsBackToTheLabel() {
        XCTAssertEqual(ImageLightbox.suggestedBaseName(altText: "A cat", fileBaseName: "   "), "a-cat")
        XCTAssertEqual(ImageLightbox.suggestedBaseName(altText: "A cat", fileBaseName: ""), "a-cat")
    }

    /// The 60-character cap applies to both paths — `uniqueURL` appends a counter and the
    /// result still has to be a legal filename.
    func testBothPathsAreCappedAtSixtyCharacters() {
        XCTAssertEqual(ImageLightbox.suggestedBaseName(altText: nil, fileBaseName: String(repeating: "x", count: 200)).count, 60)
        XCTAssertEqual(ImageLightbox.suggestedBaseName(altText: String(repeating: "y", count: 200), fileBaseName: nil).count, 60)
    }
}
