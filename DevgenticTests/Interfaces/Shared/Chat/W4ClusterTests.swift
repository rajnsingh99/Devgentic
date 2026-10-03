// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  W4ClusterTests.swift
//  DevgenticTests
//
//  P3 batch W4: model/mm-5, render/mc-11, speech/sa-8, workflow/vm-2, workflow/vm-4, views/bm-5.
//  render/mc-14 has its own file (`StreamingFenceBoundaryTests`); viewmodel/vm-9 was a deletion.
//

import XCTest
@testable import devgentic

// MARK: - model/mm-5

/// Export listed an attached file by NAME and dropped its text. The branch that would have
/// embedded it was gated on a flag no caller in the app — production or test — ever passed, and
/// was mis-built besides: it re-read the file from disk through an extraction registry that
/// handles only PDF/DOCX/XLSX/CSV/PPTX/RTF, so a .txt/.md/.swift attachment fell through it
/// silently even with the flag on.
final class ExportAttachedFileContentTests: XCTestCase {

    private func textFile(_ name: String, _ content: String) -> AttachedTextFile {
        AttachedTextFile(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"), fileExtension: "txt",
                         content: content, size: Int64(content.utf8.count))
    }

    private func message(files: [AttachedTextFile]) -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .user, content: .markdownText("Have a look"),
                    attachedTextFiles: files)
    }

    /// THE pin: the words the model was answering about are in the export.
    func testAttachedTextIsEmbedded() async {
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [message(files: [textFile("notes.md", "the answer is 42")])])

        XCTAssertTrue(markdown.contains("the answer is 42"), markdown)
        XCTAssertTrue(markdown.contains("Content of notes.md"), markdown)
        XCTAssertTrue(markdown.contains("> - Attached: `notes.md`"), "the name line is unchanged")
    }

    /// A plain-text attachment — the shape the dead branch could never have handled, because its
    /// registry does not extract .txt/.md/.swift at all.
    func testPlainTextAndCodeAttachmentsAreEmbedded() async {
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [message(files: [textFile("main.swift", "let x = 1"),
                                                    textFile("data.json", "{\"k\":1}")])])

        XCTAssertTrue(markdown.contains("let x = 1"))
        XCTAssertTrue(markdown.contains("{\"k\":1}"))
    }

    /// ⚠️ The cap is load-bearing: `AttachedTextFile.content` holds up to 500 KB and a turn can
    /// carry several, so without it a .md export becomes multiple megabytes. Truncation is
    /// STATED in the document rather than silent.
    func testLongContentIsCappedAndTheDocumentSaysSo() async {
        let long = String(repeating: "x", count: ConversationExporter.attachedFileContentLimit + 500)
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [message(files: [textFile("big.txt", long)])])

        XCTAssertFalse(markdown.contains(long), "the whole 10.5 KB body must not be embedded")
        XCTAssertTrue(markdown.contains("first \(ConversationExporter.attachedFileContentLimit) characters of \(long.count)"),
                      "truncation is disclosed per file")
    }

    /// ⚠️ A markdown or code attachment containing its own fence would end the block early and
    /// render the rest of the file as document structure. `fence(for:)` already solves this —
    /// the embedding must use it.
    func testAnAttachmentContainingAFenceDoesNotBreakOutOfItsBlock() async {
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [message(files: [textFile("readme.md", "intro\n```swift\nlet a = 1\n```\nend")])])

        XCTAssertTrue(markdown.contains("````"), "the wrapper must outrun the content's own fence")
        XCTAssertTrue(markdown.contains("let a = 1"))
        XCTAssertTrue(markdown.contains("end"), "content after the inner fence survives")
    }

    func testAnEmptyAttachmentAddsNoBlock() async {
        let markdown = await ConversationExporter.toMarkdown(
            title: "T", messages: [message(files: [textFile("empty.txt", "")])])

        XCTAssertTrue(markdown.contains("> - Attached: `empty.txt`"))
        XCTAssertFalse(markdown.contains("Content of empty.txt"))
    }
}

// MARK: - render/mc-11

/// Every streaming flush re-ran the file-reference prologue on the main actor: a fresh index
/// over every loaded message, plus TWO markdown parses of the block (one to find code spans, one
/// inside `candidateLinks`). These pin the seam that removed the second parse.
final class FileReferenceSpanReuseTests: XCTestCase {

    private let index = ["Main.java": "/work/src/Main.java", "notes.md": "/work/notes.md"]
    private let text = "I changed `Main.java` and `notes.md`, but not `Double.NaN` or `/abs/path.txt`."

    /// THE pin: the spans overload resolves the same links the markdown overload does — stated
    /// as a LITERAL expectation, not as equality with the other overload.
    ///
    /// ⚠️ Comparing the two functions cannot fail: `candidateLinks(inMarkdown:)` now delegates to
    /// `candidateLinks(inCodeSpans:)`, so an overload that returned nothing would make both
    /// sides equally empty and the assertion would still hold. (Caught by the mutation run, not
    /// by review.)
    func testTheSpansOverloadResolvesTheSameLinks() {
        let spans = FileReferenceResolver.codeSpans(inMarkdown: text)

        XCTAssertEqual(FileReferenceResolver.candidateLinks(inCodeSpans: spans, index: index),
                       ["Main.java": "/work/src/Main.java",
                        "notes.md": "/work/notes.md",
                        "/abs/path.txt": "/abs/path.txt"])
        XCTAssertEqual(FileReferenceResolver.candidateLinks(inMarkdown: text, index: index),
                       FileReferenceResolver.candidateLinks(inCodeSpans: spans, index: index),
                       "and the two agree, which is what lets the caller share one parse")
    }

    /// ⚠️ It must return the span→path DICTIONARY, not the `Set` its sibling returns: a bare
    /// filename cannot be re-derived from its path, so the renderer needs the KEY to decide
    /// which run becomes a link. Swapping in the `Set` version would leave every run unlinked.
    func testItKeepsTheSpanKeysABareFilenameCannotBeRederivedFrom() {
        let links = FileReferenceResolver.candidateLinks(
            inCodeSpans: FileReferenceResolver.codeSpans(inMarkdown: text), index: index)

        XCTAssertEqual(links["Main.java"], "/work/src/Main.java")
        XCTAssertEqual(links["notes.md"], "/work/notes.md")
        XCTAssertEqual(links["/abs/path.txt"], "/abs/path.txt", "an absolute path resolves by shape")
        XCTAssertNil(links["Double.NaN"], "not a file this conversation touched")
    }

    func testOnlyCodeSpansAreEligible() {
        let prose = "I changed Main.java in prose, not in a code span."
        XCTAssertTrue(FileReferenceResolver.codeSpans(inMarkdown: prose).isEmpty, "sanity: no spans to resolve")
        XCTAssertTrue(FileReferenceResolver.candidateLinks(
            inCodeSpans: FileReferenceResolver.codeSpans(inMarkdown: prose), index: index).isEmpty)
        // …and the same names DO resolve once marked as code, so the emptiness above is the
        // span rule rather than a resolver that never resolves anything.
        XCTAssertFalse(FileReferenceResolver.candidateLinks(
            inCodeSpans: FileReferenceResolver.codeSpans(inMarkdown: "`Main.java`"), index: index).isEmpty)
    }
}

// MARK: - speech/sa-8

/// Pressing Read Aloud called `SpeechService.stop()`, which silences the synthesizer and clears
/// the session — but Orb's narration driver is STREAMING and went on ingesting the answer and
/// queueing utterances into a service it no longer owned, so the two interleaved.
@MainActor
final class ExternalNarrationHandoffTests: XCTestCase {

    private final class FakeDriver {}

    private let service = SpeechService.shared

    override func setUp() async throws {
        service.stop()
        service.clearExternalNarrationForTesting()
    }

    override func tearDown() async throws {
        service.stop()
        service.clearExternalNarrationForTesting()
    }

    /// THE pin: starting Read Aloud cancels the external driver, and clears the claim.
    func testStartingReadAloudCancelsExternalNarration() {
        let driver = FakeDriver()
        var cancelled = 0
        service.registerExternalNarration(owner: driver) { cancelled += 1 }
        XCTAssertTrue(service.hasExternalNarration)

        service.speak("Alpha segment.", messageID: UUID(), canPresentCodeViewer: false)

        XCTAssertEqual(cancelled, 1, "the other driver must be told to stop feeding this service")
        XCTAssertFalse(service.hasExternalNarration, "and the claim is released")
    }

    /// Cleared BEFORE it is called, so a canceller that re-enters `speak` cannot recurse.
    func testACancellerThatReentersDoesNotRecurse() {
        let driver = FakeDriver()
        var cancelled = 0
        service.registerExternalNarration(owner: driver) { [weak service] in
            cancelled += 1
            service?.speak("Bravo.", messageID: UUID(), canPresentCodeViewer: false)
        }

        service.speak("Alpha segment.", messageID: UUID(), canPresentCodeViewer: false)

        XCTAssertEqual(cancelled, 1)
    }

    /// ⚠️ A driver may only release its OWN claim. A teardown arriving late from a previous
    /// speaker must not clear the registration of the one that replaced it — that would leave
    /// the new driver feeding a service Read Aloud believes it has taken back.
    func testOnlyTheOwnerReleasesItsClaim() {
        let first = FakeDriver(), second = FakeDriver()
        service.registerExternalNarration(owner: first) {}
        service.registerExternalNarration(owner: second) {}

        service.releaseExternalNarrationCanceller(ifOwnedBy: first)
        XCTAssertTrue(service.hasExternalNarration, "the late teardown belonged to the old driver")

        service.releaseExternalNarrationCanceller(ifOwnedBy: second)
        XCTAssertFalse(service.hasExternalNarration)
    }

    /// With no external driver registered, Read Aloud behaves exactly as before.
    func testNoRegistrationIsANoOp() {
        service.speak("Alpha segment.", messageID: UUID(), canPresentCodeViewer: false)
        XCTAssertTrue(service.isActive)
        XCTAssertFalse(service.hasExternalNarration)
    }
}

// MARK: - workflow/vm-4

/// A run record holds the run's whole input and final output — tens of kilobytes is ordinary —
/// and the card handed both to `Text(...).lineLimit(1|2)`. `lineLimit` is a LAYOUT constraint:
/// the full string is still measured and retained per card, per body pass. The accessibility
/// label was worse, because it is a modifier ARGUMENT (built whether or not VoiceOver is
/// attached) and `spokenPreview` walked the whole string twice before its own 120-char cap.
final class RunCardBoundedPayloadTests: XCTestCase {

    private let long = String(repeating: "x", count: 60_000)

    private func record(userInput: String = "go", finalOutput: String = "", error: String? = nil,
                        status: WorkflowRunRecord.RunStatus = .completed) -> WorkflowRunRecord {
        WorkflowRunRecord(id: UUID(), conversationID: UUID(), workflowProfileID: UUID(),
                          workflowName: "wf", timestamp: Date(timeIntervalSince1970: 0),
                          userInput: userInput, nodeResults: [], finalOutput: finalOutput,
                          variables: [:], status: status, duration: 1, error: error)
    }

    func testBoundedCapsAndMarksTruncation() {
        XCTAssertEqual(RunCardBody.bounded("short"), "short")
        let bounded = RunCardBody.bounded(long)
        XCTAssertEqual(bounded.count, 201, "200 characters plus the ellipsis")
        XCTAssertTrue(bounded.hasSuffix("…"))
        XCTAssertEqual(RunCardBody.bounded(long, limit: 10), "xxxxxxxxxx…")
    }

    /// THE pin: the spoken label never HANDS `spokenPreview` more than the display bound.
    ///
    /// ⚠️ Asserting the RESULT length here cannot fail — `spokenPreview` has always capped its
    /// output at 120 characters. The defect is the work done before that cap: two full-size
    /// copies and an O(n) grapheme walk of a 60 KB string, per card, per body pass, whether or
    /// not VoiceOver is attached. So this pins the INPUT.
    func testTheSpokenLabelNeverWalksAnUnboundedPayload() {
        for record in [record(userInput: long),
                       record(finalOutput: long),
                       record(error: long, status: .failed),
                       record(finalOutput: long, error: "Cancelled", status: .cancelled)] {
            RunCardSpeech.longestSpokenPreviewInputForTesting = 0

            _ = RunCardSpeech.label(for: record, totalNodes: 1, failedNodes: 0, notRunNodes: 0)

            XCTAssertGreaterThan(RunCardSpeech.longestSpokenPreviewInputForTesting, 0,
                                 "sanity: this arm really does speak a payload")
            XCTAssertLessThanOrEqual(RunCardSpeech.longestSpokenPreviewInputForTesting, 201,
                                     "a \(long.count)-character payload reached spokenPreview unbounded")
        }
    }

    /// ⚠️ XUI-5: a Stop renders NEUTRALLY with its partial output, and the short reason words the
    /// badge pairs with must survive bounding.
    func testAStopKeepsItsShortReasonAndItsPartialOutput() {
        let stopped = record(finalOutput: "partial answer", error: "Cancelled", status: .cancelled)

        XCTAssertEqual(RunCardBody.of(status: .cancelled, error: "Cancelled", finalOutput: "partial answer"),
                       .output("partial answer"), "output first — the useful half")
        XCTAssertEqual(RunCardBody.of(status: .cancelled, error: "Cancelled", finalOutput: ""),
                       .reason("Cancelled"))
        XCTAssertTrue(RunCardSpeech.label(for: stopped, totalNodes: 1, failedNodes: 0, notRunNodes: 0)
            .contains("partial answer"))
    }

    /// `displayText` bounds for the screen; `of(...)` keeps the true strings, so a future
    /// copy/export consumer does not inherit a display truncation.
    func testTheDecisionFunctionKeepsTheTrueStringsAndOnlyDisplayTextBounds() {
        let body = RunCardBody.of(status: .failed, error: long, finalOutput: "")

        guard case .failure(let message) = body else { return XCTFail("expected .failure") }
        XCTAssertEqual(message.count, long.count, "the decision keeps the whole reason")
        XCTAssertEqual(body.displayText?.count, 201)
        XCTAssertNil(RunCardBody.none.displayText)
    }
}

// MARK: - views/bm-5

/// The scroll path asked for the same corpus POSITION twice in a row — once to decide
/// reachability, then again inside the paging call — and `searchCorpusIndex` reads the COMPUTED
/// `searchCorpus`, which rebuilds a 1,000-entry dictionary and sorts it on every access.
@MainActor
private final class BM5Store: ChatPersistenceProtocol {
    private let backing: [ChatMessage]
    init(conversationID: UUID, messageCount: Int = 1_500) {
        backing = (0..<messageCount).map { i in
            ChatMessage(conversationId: conversationID,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(1_000_000 - i)),
                        sender: i.isMultiple(of: 2) ? .user : .agent,
                        content: .markdownText("Message \(i)"))
        }
    }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        guard offset < backing.count else { return [] }
        return Array(backing[offset ..< min(offset + limit, backing.count)])
    }
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument] {
        backing.prefix(limit).map(ChatSearchDecomposition.document(for:))
    }
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class SearchCorpusPositionReuseTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()

    override func setUp() async throws {
        let store = BM5Store(conversationID: conversationID)
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService()))
        await viewModel.loadConversation(id: conversationID)
        await viewModel.prepareSearchCorpus()
    }

    override func tearDown() async throws {
        viewModel.releaseSearchCorpus()
        viewModel = nil
    }

    /// THE pin: one position, two answers, ONE corpus build. The scroll path used to build it
    /// twice for the same message.
    func testOnePositionServesBothReachabilityAndPaging() async {
        let target = viewModel.searchCorpus[ChatHistoryViewModel.maxResidentMessages + 5].id
        let before = viewModel.searchCorpusBuildsForTesting

        let corpusIndex = viewModel.searchCorpusIndex(of: target)
        let reachable = viewModel.isMatchReachable(messageID: target, corpusIndex: corpusIndex)
        let paged = await viewModel.ensureMessageIsResident(target, corpusIndex: corpusIndex)

        XCTAssertEqual(viewModel.searchCorpusBuildsForTesting - before, 1,
                       "the position is resolved once and handed to both")
        XCTAssertFalse(reachable, "sanity: past the residency cap")
        XCTAssertFalse(paged, "and refused before the first page")
    }

    /// The supplied position gives the same answers the self-resolving form does — otherwise
    /// the overload would be a different function wearing the same name.
    func testSuppliedPositionMatchesTheSelfResolvingForm() async {
        let far = viewModel.searchCorpus[ChatHistoryViewModel.maxResidentMessages + 5].id
        let resident = viewModel.currentChatMessages[0].id
        let unknown = UUID()

        for id in [far, resident, unknown] {
            XCTAssertEqual(viewModel.isMatchReachable(messageID: id, corpusIndex: viewModel.searchCorpusIndex(of: id)),
                           viewModel.isMatchReachable(messageID: id),
                           "disagreement for \(id)")
        }
    }

    /// A resident match short-circuits before either question — it never touches the corpus.
    func testAResidentMatchIsReachableWithoutACorpusPosition() {
        let resident = viewModel.currentChatMessages[0].id
        XCTAssertTrue(viewModel.isMatchReachable(messageID: resident, corpusIndex: nil),
                      "residency is decided from the loaded window, not from the corpus")
    }

    /// A message the corpus does not hold (conversation changed, corpus released) is
    /// unreachable rather than hunted for through the store.
    func testAnAbsentMessageIsUnreachable() async {
        XCTAssertFalse(viewModel.isMatchReachable(messageID: UUID(), corpusIndex: nil))
        let paged = await viewModel.ensureMessageIsResident(UUID(), corpusIndex: nil)
        XCTAssertFalse(paged)
    }
}
