//
//  QuickAccessDispatchTests.swift
//  DevgenticTests
//
//  ⚠️ THE FIRST TESTS THIS SURFACE HAS EVER HAD. Nine production files under
//  `Devgentic/Interfaces/QuickAccess/` and, before this file, no test named
//  `QuickAccessSessionViewModel`, `QuickAccessPanel` or `QuickAccessWindow` — while Jarvis, the
//  other non-main surface, had 269 tests across 48 classes.
//
//  That gap mattered most exactly where it was widest. QuickAccess handed the send path a REVERSED
//  SLICE OF `currentChatMessages` as model history — the panel's PAGINATION WINDOW, a hard 20 rows
//  that never grew, because QuickAccess never calls `loadMoreMessages` (its only caller is the main
//  window's `ChatHistoryView`). The panel therefore gave the model at most 20 messages where the
//  main window gave up to `BackendHistoryResolver.messageLimit` (300), and it reset on every
//  summon. `architecture_readme.md` §7 invariant #8 forbids exactly this in writing — "Never
//  substitute the view's `currentChatMessages`: that is a pagination window, not the conversation"
//  — and nothing could have caught the violation.
//
//  ⚠️ Why these test `panelTurn` and a source scan rather than `submitQuery`.
//  `QuickAccessSessionViewModel.init` takes a `MainApplicationViewModel`, whose init runs
//  `ChatOpsCoordinator.bootstrap()` — real Telegram/Discord/Slack connections when the developer
//  has them configured. A unit test must never be able to do that, so the contract that carries
//  the defect is extracted, as it was for `JarvisSessionController.voiceTurn` and
//  `SchedulerCoordinator.prepareScheduledRequest`.
//
//  ⚠️ The STORE is no longer a blocker: `persistence` was widened to `ChatPersistenceProtocol` on
//  2026-09-07 (the `FetchDescriptor` that pinned it moved to `recentConversations(limit:)`), and
//  `activeStreamManager` to `any MessageStreamStarting`. The view model is now ONE dependency away
//  from being constructible here — `mainAppViewModel`, used for `backendConfiguration`,
//  `messagingCoordinator.fileProcessor` and `WorkflowRunBootstrap`'s registry. Until that is
//  narrowed the panel's orchestration stays untested: conversation bootstrap, the `[C3]` load wait,
//  stop/cancel, and the completion identity guard.
//

import XCTest
@testable import devgentic


@MainActor
private final class PanelStubStore: ChatPersistenceProtocol {
    var all: [ChatMessage] = []

    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {
        all.removeAll { $0.id == message.id }
        all.append(message)
    }

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        let scoped = all.filter { $0.conversationId == conversationId }
            .sorted { $0.timestamp > $1.timestamp }          // the real store's .reverse sort
        return Array(scoped.dropFirst(offset).prefix(limit))
    }

    func addConversation(from conversation: Conversation) {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}


@MainActor
final class QuickAccessDispatchTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private var store: PanelStubStore!

    override func setUp() async throws { store = PanelStubStore() }
    override func tearDown() async throws { store = nil }

    private func panelTurn(_ query: String, files: [FileSystemItem] = []) async -> ChatMessage {
        await QuickAccessSessionViewModel.panelTurn(
            query: query,
            conversationID: convID,
            files: files,
            fileProcessorService: FileProcessorService()
        )
    }

    private func settled(_ count: Int) -> [ChatMessage] {
        (0..<count).map { i in
            ChatMessage(id: UUID(), conversationId: convID,
                        timestamp: t0.addingTimeInterval(TimeInterval(i)),
                        sender: i % 2 == 0 ? .user : .agent, content: .plainText("m\(i)"))
        }
    }

    // MARK: - The turn itself

    /// The row the panel persists and displays is the row it hands to the send path — one object.
    /// The duplicate-query strip keys on its id, so two objects would mean the question survives
    /// into the blob and `pairTurns` reports it as abandoned.
    func testTheDisplayedRowIsTheRowSent() async {
        let message = await panelTurn("what changed in the build")

        XCTAssertEqual(message.content.textContent, "what changed in the build")
        XCTAssertEqual(message.sender, .user)
        XCTAssertEqual(message.conversationId, convID)
    }

    /// Panel traffic is attributed on the message so ChatOps mirroring, analytics and the audit
    /// trail can distinguish it from main-window (`.localUI`) sends.
    func testPanelTrafficIsAttributed() async {
        let message = await panelTurn("hello")
        XCTAssertEqual(message.messageSource, .quickAccess)
    }

    /// Unlike Jarvis the panel does not decorate its query, so the model's text and the displayed
    /// text are the same string and no override is needed. Pinned as a contract: a future panel
    /// decoration must travel as `promptOverride`, never by mutating this message.
    func testThePanelDoesNotDecorateItsQuery() async {
        let query = "summarise this"
        let message = await panelTurn(query)

        XCTAssertEqual(message.content.textContent, query,
                       "the model's copy and the displayed copy are the same string; if that ever "
                       + "stops being true the difference must be carried by promptOverride")
    }

    /// A query with no text is still a well-formed turn — the panel allows an attachment-only
    /// send, and the row must carry its identity and attribution either way.
    func testAnEmptyQueryStillProducesAWellFormedTurn() async {
        let message = await panelTurn("")

        XCTAssertEqual(message.content.textContent, "")
        XCTAssertEqual(message.sender, .user)
        XCTAssertEqual(message.messageSource, .quickAccess)
    }

    /// The panel DOES carry attachments, unlike a voice turn — so it must go through the same
    /// classification the main send path uses rather than a second copy of it. A text file must
    /// land in `attachedTextFiles`, which is what the docstring on the empty-query test used to
    /// claim while asserting nothing about files at all.
    func testAnAttachedTextFileIsClassifiedByTheSharedFactory() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qa-dispatch-\(convID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("notes.txt")
        try "the release is cut on friday".write(to: fileURL, atomically: true, encoding: .utf8)
        let item = FileSystemItem(id: fileURL, name: "notes.txt", url: fileURL, isDirectory: false)

        let message = await panelTurn("what does this say", files: [item])

        XCTAssertEqual(message.attachedTextFiles?.count, 1,
                       "the panel's attachment must be classified as TEXT by the shared factory — "
                       + "a panel that stopped forwarding `files:` would leave this nil and no "
                       + "other test in this file would notice")
        XCTAssertEqual(message.attachedTextFiles?.first?.name, "notes.txt")
        XCTAssertNil(message.attachedImageFiles, "a .txt is not an image")
        XCTAssertEqual(message.messageSource, .quickAccess)
    }

    // MARK: - ⚠️ The pagination window, gone

    /// ⚠️ THE REGRESSION THIS FILE EXISTS FOR. The panel's resident window is a hard 20 rows; the
    /// conversation is 200. What reaches the model must be the conversation, not the window.
    func testThePanelGetsTheConversationNotItsRenderWindow() async {
        store.all = settled(200)
        let residentWindow = Array(store.all.suffix(20))     // what the panel actually renders
        let turn = await panelTurn("follow up")

        let derived = await ActiveStreamManager.deriveHistory(
            userMessage: turn, before: nil, persistence: store)

        XCTAssertEqual(residentWindow.count, 20, "precondition: the panel renders one page")
        XCTAssertEqual(derived.count, 201,
                       "200 stored turns plus this question — 10× the old ceiling")
        XCTAssertGreaterThan(derived.count, residentWindow.count * 5)
    }

    /// The panel and the main window are handed the SAME conversation. Before the change the panel
    /// was capped at 20 while the main window resolved up to 300 for the same chat.
    func testThePanelAndTheMainWindowAreGivenTheSameHistory() async {
        store.all = settled(120)
        let fromPanel = await panelTurn("q")
        let panelHistory = await ActiveStreamManager.deriveHistory(
            userMessage: fromPanel, before: nil, persistence: store)

        // The main window's send builds its message the same way, through the same factory.
        let fromMainWindow = await MessagingCoordinator.makeUserMessage(
            conversationID: convID, query: "q", files: [],
            fileProcessorService: FileProcessorService())
        let mainHistory = await ActiveStreamManager.deriveHistory(
            userMessage: fromMainWindow, before: nil, persistence: store)

        XCTAssertEqual(panelHistory.count, mainHistory.count)
        XCTAssertEqual(panelHistory.dropLast().map(\.id), mainHistory.dropLast().map(\.id),
                       "identical history; the two differ only by whose question is last")
    }

    /// Invariant #8 at this surface: the store sorts descending, and the panel used to reverse a
    /// descending array by hand. Nothing it produces may be non-ascending now.
    func testWhatThePanelSendsIsOldestFirst() async {
        store.all = settled(30)
        let turn = await panelTurn("newest question")

        let derived = await ActiveStreamManager.deriveHistory(
            userMessage: turn, before: nil, persistence: store)

        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: derived))
        XCTAssertEqual(derived.last?.id, turn.id)
    }

    // MARK: - Wiring

    /// ⚠️ EVERY HITL DECISION MUST BE ATTRIBUTED. Four of the panel's five decision arms routed
    /// through `submitHITL` and emitted a `[HITL] … from the QuickAccess panel` line; gate CANCEL
    /// called `ExecutionSuspensionService.resumeGate` inline with no log at all, so a field log
    /// showed three of four Escape presses and the fourth simply vanished. The funnel's own doc
    /// claimed at the time that "a NEW decision kind cannot reintroduce the silent path" — which
    /// was false in the same file, 70 lines below.
    ///
    /// Source-scanned because the view model needs a `MainApplicationViewModel` to construct, and
    /// that init opens real ChatOps connections.
    func testEveryHITLDecisionIsAttributedToTheSurface() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot
            .appendingPathComponent("Devgentic/Interfaces/QuickAccess/QuickAccessSessionViewModel.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "source not reachable at \(source.path) — running outside a checkout")
        let body = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(body.contains("Task { await ExecutionSuspensionService.shared.resumeGate"),
                       "gate cancel must not reach the suspension service inline — that is the "
                       + "one decision with no VM wrapper, and it is exactly the one that went "
                       + "unlogged and unattributed")
        XCTAssertTrue(body.contains("submitHITLDirect(\"Gate cancelled\""),
                      "it must route through the attributed funnel instead")
        XCTAssertTrue(body.contains("private func submitHITLDirect("),
                      "…which must exist, logging the same [HITL] line with the same surface")
    }

    /// ⚠️ The assertions above are worth nothing if `submitQuery` rebuilds a history slice. The
    /// deleted code is the regression, so the source scan asserts its ABSENCE — a unit test
    /// structurally cannot see a caller reintroducing it.
    func testTheSendPathBuildsNoHistoryOfItsOwn() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot
            .appendingPathComponent("Devgentic/Interfaces/QuickAccess/QuickAccessSessionViewModel.swift")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("source not reachable — running outside a checkout")
        }
        let code = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        XCTAssertTrue(code.contains { $0.contains("await Self.panelTurn(") },
                      "the panel must build its turn through panelTurn — building the message "
                      + "separately is how the displayed row and the sent row drift apart, and it "
                      + "silently drops the .quickAccess attribution")

        // ⚠️ JOINED, not line-by-line. The slice this guards against was written as a MULTI-LINE
        // chain (`currentChatMessages` / `.filter {…}` / `.reversed()`), so a per-line scan sees
        // neither half together and passes over the exact shape it exists to catch. A first
        // version of this test did precisely that and survived the mutation.
        let body = code.joined(separator: "\n")
        let windowSlice = try NSRegularExpression(
            pattern: #"currentChatMessages[\s\S]{0,200}?\.reversed\(\)"#)
        XCTAssertNil(windowSlice.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                     "a reversed slice of currentChatMessages is the invariant-#8 violation this "
                     + "surface shipped — the panel's pagination window as model history")
    }
}
