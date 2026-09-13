// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemainingP3Tests.swift
//  DevgenticTests
//
//  The last unverified P3 rows, each put through its own verification pass first:
//  model/mm-3, viewmodel/vm-5, workflow/vm-3, plus a defect found while verifying render/mc-7
//  that is not in the register at all.
//

import XCTest
@testable import devgentic

// MARK: - model/mm-3

/// A markdown export never stated a run's terminal outcome. On screen a failed or stopped run
/// carries a `TerminalOutcomeChip` beside its partial answer; the export dropped that half, so a
/// turn that streamed real prose and THEN failed exported exactly like one that answered.
final class ExportRunOutcomeTests: XCTestCase {

    private func agentMessage(text: String = "Here is what I found so far.",
                              outcome: ExecutionOutcome? = nil,
                              reason: String? = nil) -> ChatMessage {
        let m = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(text))
        m.terminalOutcome = outcome
        m.terminalReason = reason
        return m
    }

    /// THE pin: a failed run says so, above its prose.
    func testAFailedRunStatesItsOutcome() async {
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [agentMessage(outcome: .failed, reason: "The provider returned 503")])

        XCTAssertTrue(markdown.contains("> **Run outcome:** Failed — The provider returned 503"), markdown)
        // ⚠️ BEFORE the content: the failure being reported is the one most likely to have left
        // the prose ending in an unclosed fence, and a line after that lands inside it.
        let outcomeAt = try? XCTUnwrap(markdown.range(of: "Run outcome"))
        let proseAt = try? XCTUnwrap(markdown.range(of: "Here is what I found so far."))
        if let outcomeAt, let proseAt { XCTAssertLessThan(outcomeAt.lowerBound, proseAt.lowerBound) }
    }

    func testEveryNonCompletedOutcomeIsNamed() async {
        for outcome in [ExecutionOutcome.failed, .cancelled, .completedWithWarnings] {
            let markdown = await ConversationExporter.toMarkdown(title: "T", messages: [agentMessage(outcome: outcome)])
            XCTAssertTrue(markdown.contains("> **Run outcome:** \(outcome.displayName)"),
                          "\(outcome) missing from: \(markdown)")
        }
    }

    /// A completed run says nothing — the line exists to mark the exceptions.
    func testACompletedRunAddsNoLine() async {
        let markdown = await ConversationExporter.toMarkdown(title: "T", messages: [agentMessage(outcome: .completed)])
        XCTAssertFalse(markdown.contains("Run outcome"), markdown)
    }

    /// ⚠️ Mirrors the bubble's own `!isErrorContent` suppression: the `.error` arm already prints
    /// "**Error**: …", and two verdicts for one turn is noise.
    func testAnErrorCardIsNotGivenASecondVerdict() async {
        let m = ChatMessage(conversationId: UUID(), sender: .agent,
                            content: .error(title: "Timeout", details: "no response"))
        m.terminalOutcome = ExecutionOutcome.failed

        let markdown = await ConversationExporter.toMarkdown(title: "T", messages: [m])

        XCTAssertTrue(markdown.contains("**Error**: Timeout"), markdown)
        XCTAssertFalse(markdown.contains("Run outcome"), "the card already states the verdict: \(markdown)")
    }

    /// ⚠️ One quoted PARAGRAPH, never a quote plus a `> - ` list item. A whitespace-only reason
    /// would emit an EMPTY list item, and per CommonMark an empty list item cannot interrupt a
    /// paragraph — it would collapse into the line above and render "Run outcome: Failed -".
    func testAWhitespaceOnlyReasonLeavesNoDanglingSeparator() {
        XCTAssertEqual(ConversationExporter.outcomeLine("Failed", reason: "   \n "), "> **Run outcome:** Failed")
        XCTAssertEqual(ConversationExporter.outcomeLine("Failed", reason: nil), "> **Run outcome:** Failed")
        XCTAssertEqual(ConversationExporter.outcomeLine("Failed", reason: ""), "> **Run outcome:** Failed")
    }

    /// ⚠️ `terminalReason` is provider text. A raw newline would END the block quote and drop the
    /// rest of the sentence out of it.
    func testAMultiLineReasonIsFlattenedOntoOneLine() {
        let line = ConversationExporter.outcomeLine("Failed", reason: "connection reset\nby peer\r\nafter 30s")

        XCTAssertEqual(line, "> **Run outcome:** Failed — connection reset by peer after 30s")
        XCTAssertFalse(line.contains("\n"), "a newline here breaks out of the quote")
    }

    /// A run cut off with no recorded outcome still says so. ⚠️ `isInterrupted` is `!= .final`,
    /// which is TRUE for a live streaming row — the not-streaming guard is what makes this mean
    /// "never finished" rather than "in progress".
    func testAnInterruptedRunWithNoOutcomeIsNamed() async {
        let m = agentMessage()
        m.lifecycleState = .streaming

        let markdown = await ConversationExporter.toMarkdown(title: "T", messages: [m])

        XCTAssertTrue(markdown.contains("> **Run outcome:** Interrupted"), markdown)
    }

    func testAUserMessageNeverGetsAnOutcomeLine() async {
        let user = ChatMessage(conversationId: UUID(), sender: .user, content: .plainText("hello"))
        let markdown = await ConversationExporter.toMarkdown(title: "T", messages: [user])
        XCTAssertFalse(markdown.contains("Run outcome"), markdown)
    }
}

// MARK: - render/mc-7 follow-on (not in the register)

/// ⚠️ PINS A NON-DEFECT, and says why — a verification pass proposed a fix here and the fix was
/// wrong because the premise was wrong.
///
/// The claim was that `[`Main.java`](https://github.com/…)` produces ONE run carrying both
/// `.code` and `.link`, so the file-reference pass would harvest it and the renderer would
/// overwrite the author's destination with a local-file URL. Probed instead of reasoned:
/// Foundation's `AttributedString(markdown:)` DROPS the `.code` intent on a link label. The run
/// has `link` set and no presentation intent, so it is invisible to `codeSpans` and to the
/// renderer's `.code` branch, and lands in the ordinary-link branch that gives it the accent
/// colour and an underline.
///
/// These tests exist so the next reader does not re-derive the hazard from how markdown "ought
/// to" parse. If Foundation ever changes, the first test goes red and the guard becomes real.
final class LinkedCodeSpanTests: XCTestCase {

    /// THE premise, asserted directly rather than through the code that depends on it.
    func testFoundationDropsTheCodeIntentOnALinkLabel() throws {
        let parsed = try AttributedString(
            markdown: "See [`Main.java`](https://example.com/Main.java) for the change.")
        let linked = parsed.runs.first { $0.link != nil }

        let run = try XCTUnwrap(linked, "the link must survive the parse")
        XCTAssertEqual(String(parsed[run.range].characters), "Main.java", "the backticks are consumed")
        XCTAssertFalse((run.inlinePresentationIntent ?? []).contains(.code),
                       "⚠️ if this ever becomes true, a linked label starts reaching the `.code` branch and CAN be retargeted")
    }

    func testAnAuthorLinkedCodeSpanIsNotAFileReferenceCandidate() {
        let spans = FileReferenceResolver.codeSpans(
            inMarkdown: "See [`Main.java`](https://github.com/org/repo/blob/main/Main.java) for the change.")

        XCTAssertTrue(spans.isEmpty, "not by a guard — the run simply carries no code intent: \(spans)")
    }

    /// The ordinary case is untouched — an unlinked code span is still a candidate.
    func testAnUnlinkedCodeSpanIsStillACandidate() {
        let index = ["Main.java": "/work/src/Main.java"]
        let spans = FileReferenceResolver.codeSpans(inMarkdown: "I changed `Main.java` today.")

        XCTAssertEqual(spans, ["Main.java"])
        XCTAssertEqual(FileReferenceResolver.candidateLinks(inCodeSpans: spans, index: index),
                       ["Main.java": "/work/src/Main.java"])
    }

    /// A linked span and an unlinked one in the same paragraph: only the second is eligible.
    func testOnlyTheUnlinkedSpanSurvives() {
        let spans = FileReferenceResolver.codeSpans(
            inMarkdown: "Compare [`Old.java`](https://example.com/Old.java) with `New.java`.")

        XCTAssertEqual(spans, ["New.java"])
    }
}

// MARK: - viewmodel/vm-5

@MainActor
private final class VM5Store: ChatPersistenceProtocol {
    var messages: [ChatMessage] = []
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        offset == 0 ? messages : []
    }
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument] { [] }
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

/// The resident search projection is memoized on the message's TEXT hash alone. The text does not
/// change when a message settles — the finalizer keeps the streamed content verbatim — but the
/// DECOMPOSITION does: a streaming message is split by `StreamingMarkdownParser`, whose positional
/// `block-N` ids can differ from the authoritative parse that runs at settle. So an entry written
/// during the stream was served forever after, pointing search at block ids the renderer no
/// longer has.
@MainActor
final class StreamingSearchProjectionTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private var message: ChatMessage!
    private let conversationID = UUID()

    override func setUp() async throws {
        let store = VM5Store()
        message = ChatMessage(conversationId: conversationID, sender: .agent,
                              content: .markdownText("Intro paragraph.\n\nSecond paragraph."))
        message.isStreaming = true
        store.messages = [message]
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService()))
        await viewModel.loadConversation(id: conversationID)
        XCTAssertEqual(viewModel.currentChatMessages.count, 1, "sanity")
    }

    override func tearDown() async throws {
        viewModel = nil
        message = nil
    }

    /// THE pin: no memo is served across the settle boundary. The text is byte-identical either
    /// side of it, so a hash-keyed memo cannot notice — only the streaming flag can.
    func testAStreamingProjectionIsNeverServedAfterTheMessageSettles() {
        _ = viewModel.searchCorpus        // writes the streaming entry
        _ = viewModel.searchCorpus        // serves it — the memo still works mid-stream
        let hitsWhileStreaming = viewModel.residentUnitsCacheHitsForTesting
        XCTAssertGreaterThan(hitsWhileStreaming, 0, "the memo must still work during a stream")

        let textBefore = viewModel.currentChatMessages[0].displayedContent.textContent
        viewModel.currentChatMessages[0].isStreaming = false
        XCTAssertEqual(viewModel.currentChatMessages[0].displayedContent.textContent, textBefore,
                       "⚠️ the premise: the TEXT does not change at settle, so the hash alone cannot invalidate")

        _ = viewModel.searchCorpus        // first settled read: must RECOMPUTE, not serve
        XCTAssertEqual(viewModel.residentUnitsCacheHitsForTesting, hitsWhileStreaming,
                       "the streaming-era entry must not be served across the settle boundary")
    }

    /// …and once settled, the memo does its job. Without this the guard could simply disable
    /// memoization altogether and the test above would still pass.
    func testASettledProjectionIsStillMemoized() {
        viewModel.currentChatMessages[0].isStreaming = false

        _ = viewModel.searchCorpus        // writes the settled entry
        _ = viewModel.searchCorpus        // serves it

        XCTAssertGreaterThan(viewModel.residentUnitsCacheHitsForTesting, 0,
                             "a settled message must still be memoized — this is a correctness fix, not a cache removal")
    }
}

// MARK: - workflow/vm-3

/// The LIVE factory rebuilt a node's input preview — every upstream's entire model output,
/// concatenated — on every body pass, for a view that shows 200 characters. The string is
/// identical every pass: a settled upstream's detail never changes.
final class LiveInputPreviewBoundTests: XCTestCase {

    private func result(_ name: String, detail: String,
                        status: WorkflowNodeResult.Status = .completed) -> WorkflowNodeResult {
        WorkflowNodeResult(id: UUID(), nodeID: UUID(), profileName: name, status: status,
                           detail: detail, startTime: Date(timeIntervalSince1970: 0),
                           endTime: Date(timeIntervalSince1970: 1))
    }

    /// THE pin: one upstream's contribution is bounded for the live preview.
    func testALargeUpstreamOutputIsBoundedForTheLivePreview() {
        let huge = String(repeating: "x", count: 40_000)
        let node = result("Fetcher", detail: huge)

        let bounded = WorkflowExecutionState.boundedUpstreamInputContribution(
            of: node, resultsByNodeID: [node.nodeID: node], edges: [], userInput: "go")

        XCTAssertEqual(bounded.count, WorkflowExecutionState.livePreviewContributionCap)
        XCTAssertTrue(huge.hasPrefix(bounded), "the bound is a prefix, not a re-encoding")
    }

    /// A short contribution is returned whole — no ellipsis, no allocation.
    func testAShortContributionIsUntouched() {
        let node = result("Fetcher", detail: "ALPHA OUTPUT")

        XCTAssertEqual(WorkflowExecutionState.boundedUpstreamInputContribution(
            of: node, resultsByNodeID: [node.nodeID: node], edges: [], userInput: "go"), "ALPHA OUTPUT")
    }

    /// ⚠️ The cap must clear the view's own 200-character cut by enough that a contribution
    /// opening with a long whitespace run cannot change what is displayed — `boundedPreview`
    /// TRIMS before it cuts. The two constants are coupled only by this assertion.
    func testTheCapClearsTheViewsCutWithSlack() {
        XCTAssertGreaterThanOrEqual(WorkflowExecutionState.livePreviewContributionCap, 1_000,
                                    "the collapsed row trims whitespace and then cuts at 200; a cap near 200 would change displayed text")
    }

    /// The bound is LIVE-only: a frozen record is the durable artefact and keeps the full text.
    func testTheUnboundedHelperStillReturnsTheWholeValue() {
        let huge = String(repeating: "y", count: 40_000)
        let node = result("Fetcher", detail: huge)

        XCTAssertEqual(WorkflowExecutionState.upstreamInputContribution(
            of: node, resultsByNodeID: [node.nodeID: node], edges: [], userInput: "go").count, 40_000)
    }
}

// MARK: - speech/sa-2

/// Every other transport verb cancels the 1-second beat that follows a code-block hand-off —
/// `stop()`, `skipForward()`, `skipBackward()`. Pause did not, and during that beat there is
/// nothing in the synthesizer to pause, so the transport flipped to Paused, the beat fired
/// anyway, and the NEXT segment spoke in full under a Paused island.
@MainActor
final class PauseDuringCodeBlockBeatTests: XCTestCase {

    private let service = SpeechService.shared

    /// prose / fence / prose — `parseSegments` splits only on fences, so this is the shortest
    /// message with a segment AFTER the code block.
    private let threeSegments = """
    Alpha segment.
    ```swift
    let x = 1
    ```
    Bravo segment.
    """

    override func setUp() async throws { service.stop() }
    override func tearDown() async throws { service.stop() }

    /// THE pin: Pause during the beat parks the playlist on the NEXT segment without speaking
    /// it, and cancels the beat that would have spoken it.
    func testPauseDuringTheBeatParksWithoutSpeaking() {
        service.speak(threeSegments, messageID: UUID(), canPresentCodeViewer: false)
        XCTAssertEqual(service.totalSegmentCount, 3, "sanity: prose, code, prose")
        // The beat is armed once the CODE BLOCK has been announced, i.e. on segment 2.
        service.skipForward()
        XCTAssertEqual(service.currentSegmentIndex, 2, "sanity: parked on the code block")
        service.armCodeBlockBeatForTesting()
        XCTAssertTrue(service.pendingDelayTaskIsArmedForTesting, "sanity: the beat is armed")

        service.pauseSpeaking()

        XCTAssertFalse(service.pendingDelayTaskIsArmedForTesting,
                       "the beat must be cancelled — otherwise it speaks the next segment under a paused transport")
        XCTAssertTrue(service.isPaused)
        XCTAssertTrue(service.isActive, "the session is parked, not ended")
        XCTAssertEqual(service.currentSegmentIndex, 3,
                       "parked ON the next segment, so Play speaks it once rather than re-announcing the code block")
    }

    /// ⚠️ A code block as the LAST segment has nothing to park on. Advancing past the end and
    /// setting Paused would leave "N of N" with a Play button that can only end the session, and
    /// a bubble still reading Stop. The old behaviour was accidentally right here — the beat ran
    /// off the end and finished — so the OUTCOME is preserved.
    func testPauseDuringTheBeatOfAFinalCodeBlockEndsTheSession() {
        service.speak("Alpha segment.\n```swift\nlet x = 1\n```", messageID: UUID(), canPresentCodeViewer: false)
        XCTAssertEqual(service.totalSegmentCount, 2, "sanity: prose then a trailing code block")
        while service.currentSegmentIndex < 2 { service.skipForward() }
        service.armCodeBlockBeatForTesting()

        service.pauseSpeaking()

        XCTAssertFalse(service.isActive, "no dead-end park: the session ends")
        XCTAssertFalse(service.isPaused)
        XCTAssertFalse(service.pendingDelayTaskIsArmedForTesting)
    }

    /// Ordinary Pause — no beat armed — is untouched.
    func testPauseOutsideTheBeatIsUnchanged() {
        service.speak(threeSegments, messageID: UUID(), canPresentCodeViewer: false)
        let segmentBefore = service.currentSegmentIndex
        XCTAssertFalse(service.pendingDelayTaskIsArmedForTesting, "sanity: no beat")

        service.pauseSpeaking()

        XCTAssertTrue(service.isPaused)
        XCTAssertTrue(service.isActive)
        XCTAssertEqual(service.currentSegmentIndex, segmentBefore,
                       "an ordinary pause must NOT advance the playlist")
    }

    /// Pause is idempotent and inert when nothing is playing.
    func testPauseIsInertWhenIdleOrAlreadyPaused() {
        service.pauseSpeaking()
        XCTAssertFalse(service.isPaused, "idle: nothing to pause")

        service.speak(threeSegments, messageID: UUID(), canPresentCodeViewer: false)
        service.pauseSpeaking()
        let segment = service.currentSegmentIndex
        service.pauseSpeaking()
        XCTAssertEqual(service.currentSegmentIndex, segment, "a second Pause must not advance again")
    }
}

// MARK: - views/bm-6

/// The chat-font-size path ran the two-`NSHostingView` truncation measurement SYNCHRONOUSLY and
/// undebounced — once per slider step, for every visible long message — and zeroed the width
/// sentinel while doing it, which made the width handler take its immediate branch too. All of
/// it invisible: the settings pane sits above the chat, which is held at opacity 0 while it is
/// open. The font size is part of the cache key now, so there is nothing to zero.
final class TruncationCacheKeyTests: XCTestCase {

    private func shouldRemeasure(width: CGFloat = 400, lastWidth: CGFloat = 400,
                                 fontSize: CGFloat = 14, lastFontSize: CGFloat = 14) -> Bool {
        UserMessageView.shouldRemeasure(availableWidth: width, lastMeasuredWidth: lastWidth,
                                        fontSize: fontSize, lastMeasuredFontSize: lastFontSize)
    }

    /// THE pin: the same width at a different font size is a MISS. Before this the font size was
    /// not in the key at all, and the call site papered over it by zeroing the width.
    func testAFontSizeChangeAtAnUnchangedWidthRemeasures() {
        XCTAssertTrue(shouldRemeasure(fontSize: 15, lastFontSize: 14))
        XCTAssertTrue(shouldRemeasure(fontSize: 13, lastFontSize: 14))
    }

    /// ⚠️ EXACT on the font size — no tolerance. One slider step is one point, so a ±2 rule
    /// there would serve a stale answer for the two steps that matter most.
    func testTheFontSizeComparisonHasNoTolerance() {
        XCTAssertTrue(shouldRemeasure(fontSize: 14.5, lastFontSize: 14))
    }

    /// The width tolerance survives: a drag emits a callback per point, and the answer cannot
    /// change that fast.
    func testASmallWidthDriftAtTheSameFontSizeDoesNotRemeasure() {
        XCTAssertFalse(shouldRemeasure(width: 401, lastWidth: 400))
        XCTAssertFalse(shouldRemeasure(width: 398, lastWidth: 400))
        XCTAssertTrue(shouldRemeasure(width: 405, lastWidth: 400))
    }

    /// Nothing moved, nothing to do — the case that makes the cache worth having.
    func testAnUnchangedWidthAndFontSizeIsACacheHit() {
        XCTAssertFalse(shouldRemeasure())
    }

    /// ⚠️ 0 still means "never measured": the first geometry callback can arrive before layout
    /// resolves, and that degenerate call must be short-circuited so the first REAL width is
    /// still measured immediately rather than debounced.
    func testTheDegenerateZeroWidthCallbackIsStillShortCircuited() {
        XCTAssertFalse(shouldRemeasure(width: 0, lastWidth: 0),
                       "a 0-width callback against the initial state must not measure")
        XCTAssertTrue(shouldRemeasure(width: 380, lastWidth: 0),
                       "and the first real width must")
    }
}
