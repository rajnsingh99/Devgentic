// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationSwitchIntegrityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
private final class SwitchStubStore: ChatPersistenceProtocol {
    var pages: [UUID: [ChatMessage]] = [:]
    var initialPage: [ChatMessage] = []
    /// Drives the real `prepareSearchCorpus` path rather than poking the cache.
    var searchDocuments: [UUID: [SearchDocument]] = [:]
    /// Runs inside `fetchMessages` — the deterministic stand-in for "something happened while
    /// the store was reading".
    var duringFetch: (@MainActor () -> Void)?

    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        duringFetch?()
        if offset == 0 { return initialPage }
        return pages[conversationId] ?? []
    }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument] {
        searchDocuments[conversationId] ?? []
    }
}

@MainActor
final class ConversationSwitchIntegrityTests: XCTestCase {

    private var store: SwitchStubStore!
    private var viewModel: ChatHistoryViewModel!
    private var tempDir: URL!

    override func setUp() async throws {
        store = SwitchStubStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        viewModel = nil
        store = nil
    }

    private func beganPayload(conversation: UUID, path: String, content: String = "let x = 1")
        -> AgentLiveWriteEvent.Began? {
        AgentLiveWriteEvent.began(
            toolName: "write_file",
            params: #"{"file_path": "\#(path)", "content": "\#(content)"}"#,
            conversationID: conversation
        )
    }

    private func completedPayload(conversation: UUID, path: String, isSuccess: Bool)
        -> AgentLiveWriteEvent.Completed? {
        AgentLiveWriteEvent.completed(
            toolName: "write_file",
            params: #"{"file_path": "\#(path)", "content": "let x = 1"}"#,
            isSuccess: isSuccess,
            preWriteContent: "original on disk",
            conversationID: conversation
        )
    }

    // MARK: - vm-1: nothing may be planted while a load is in flight

    /// ⚠️ A `began` admitted during `loadConversation`'s fetch window appended a tab into the
    /// freshly-emptied viewer. `restoreCodeViewerSession` only restores INTO AN EMPTY viewer, so
    /// that conversation's own stashed tabs were then silently never restored — and the next
    /// switch overwrote its stash with the single live tab, destroying the drafts.
    /// Mutation that must kill this: delete the `guard loadingConversationID == nil` in
    /// `handleAgentWriteBegan`.
    func testALiveWriteDuringALoadDoesNotPlantATabAndDoesNotSuppressTheRestore() async throws {
        let conversationB = UUID()

        // Give B a stashed tab holding an unsaved draft, entirely through production paths:
        // open it while B is loaded, then switch away so `resetCodeViewer` stashes it.
        store.initialPage = [ChatMessage(conversationId: conversationB, sender: .user,
                                         content: .markdownText("b"))]
        await viewModel.loadConversation(id: conversationB)
        let draftTabID = viewModel.openTab(
            for: CodeSnippet(language: "swift", code: "pristine"), fileName: "Draft.swift"
        )
        viewModel.updateCodeViewerDraft(tabID: draftTabID, content: "an unsaved edit")
        let other = UUID()
        store.initialPage = [ChatMessage(conversationId: other, sender: .user,
                                         content: .markdownText("other"))]
        await viewModel.loadConversation(id: other)
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty, "precondition: B's tab is stashed, not live")

        // The load for B is in flight, and a write for B lands inside its fetch.
        let path = tempDir.appendingPathComponent("Live.swift").path
        store.initialPage = [ChatMessage(conversationId: conversationB, sender: .user,
                                         content: .markdownText("hello"))]
        store.duringFetch = { [weak viewModel] in
            guard let payload = AgentLiveWriteEvent.began(
                toolName: "write_file",
                params: #"{"file_path": "\#(path)", "content": "let x = 1"}"#,
                conversationID: conversationB
            ) else { return XCTFail("payload should build") }
            viewModel?.handleAgentWriteBegan(payload)
        }

        await viewModel.loadConversation(id: conversationB)

        let paths = viewModel.codeViewerTabs.compactMap(\.fileName)
        XCTAssertTrue(paths.contains("Draft.swift"),
                      "B's stashed tab must be restored — a tab planted mid-load would suppress it")
        XCTAssertFalse(paths.contains("Live.swift"),
                       "no tab may be planted while a load is in flight")
    }

    /// The refusal must be scoped to the load window only — an ordinary live write with no load
    /// in flight still opens its tab.
    func testALiveWriteWithNoLoadInFlightStillOpensItsTab() async throws {
        let conversation = UUID()
        store.initialPage = [ChatMessage(conversationId: conversation, sender: .user,
                                         content: .markdownText("hello"))]
        await viewModel.loadConversation(id: conversation)

        let path = tempDir.appendingPathComponent("Normal.swift").path
        let payload = try XCTUnwrap(beganPayload(conversation: conversation, path: path))
        viewModel.handleAgentWriteBegan(payload)

        XCTAssertTrue(viewModel.codeViewerTabs.contains { $0.fileName == "Normal.swift" },
                      "the ordinary live-write path must be unaffected")
        XCTAssertTrue(viewModel.hasLiveAgentTabs, "…and the tab is marked as being written")
    }

    // MARK: - cv-2: a completion settles its tab live OR stashed

    /// ⚠️ THE REGRESSION GUARD. The completion used to be dropped when its conversation was no
    /// longer displayed, and looked the tab up only in the live array — so switching away during
    /// a write left the tab `.active` forever: orange "agent is writing this file" banner up, the
    /// pill pulsing, and `lastSavedDisk` never set so ⌘S was refused as on-disk drift on a false
    /// claim. Mutation that must kill this: restore the `payload.conversationID ==
    /// destinationConversationID` guard, or look only in `codeViewerTabs`.
    func testACompletionSettlesATabThatWasStashedByAConversationSwitch() async throws {
        let conversationA = UUID()
        let conversationB = UUID()
        let path = tempDir.appendingPathComponent("Writing.swift").path

        store.initialPage = [ChatMessage(conversationId: conversationA, sender: .user,
                                         content: .markdownText("a"))]
        await viewModel.loadConversation(id: conversationA)

        let began = try XCTUnwrap(beganPayload(conversation: conversationA, path: path))
        viewModel.handleAgentWriteBegan(began)
        XCTAssertTrue(viewModel.hasLiveAgentTabs, "precondition: A holds a live write tab")

        // The user switches to B while the write is in flight — A's tab is stashed, still .active.
        store.initialPage = [ChatMessage(conversationId: conversationB, sender: .user,
                                         content: .markdownText("b"))]
        await viewModel.loadConversation(id: conversationB)
        XCTAssertFalse(viewModel.hasLiveAgentTabs, "A's tab is no longer live — it is stashed")

        // The write is DENIED while B is displayed.
        let completed = try XCTUnwrap(completedPayload(conversation: conversationA,
                                                       path: path, isSuccess: false))
        viewModel.handleAgentWriteCompleted(completed)

        // Reopening A must show a settled tab, not one still claiming to be written.
        store.initialPage = [ChatMessage(conversationId: conversationA, sender: .user,
                                         content: .markdownText("a"))]
        await viewModel.loadConversation(id: conversationA)

        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.fileName == "Writing.swift" })
        XCTAssertEqual(tab.liveState, .rejected,
                       "a denied write must settle as rejected even though the user had switched away")
        XCTAssertEqual(tab.lastSavedDisk, "original on disk",
                       "…and the drift baseline must be set, or ⌘S is refused on a false drift claim")
        XCTAssertFalse(viewModel.hasLiveAgentTabs,
                       "nothing may still claim the agent is writing")
    }

    /// A successful write settles the same way when it lands after a switch.
    func testASuccessfulCompletionAlsoSettlesAStashedTab() async throws {
        let conversationA = UUID()
        let conversationB = UUID()
        let path = tempDir.appendingPathComponent("Landed.swift").path

        store.initialPage = [ChatMessage(conversationId: conversationA, sender: .user,
                                         content: .markdownText("a"))]
        await viewModel.loadConversation(id: conversationA)
        viewModel.handleAgentWriteBegan(try XCTUnwrap(beganPayload(conversation: conversationA, path: path)))

        store.initialPage = [ChatMessage(conversationId: conversationB, sender: .user,
                                         content: .markdownText("b"))]
        await viewModel.loadConversation(id: conversationB)

        viewModel.handleAgentWriteCompleted(
            try XCTUnwrap(completedPayload(conversation: conversationA, path: path, isSuccess: true))
        )

        store.initialPage = [ChatMessage(conversationId: conversationA, sender: .user,
                                         content: .markdownText("a"))]
        await viewModel.loadConversation(id: conversationA)

        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.fileName == "Landed.swift" })
        XCTAssertNil(tab.liveState, "a landed write clears the live badge entirely")
        XCTAssertNil(tab.lastSavedDisk,
                     "the proposal IS on disk, so the pre-write bytes must not become the baseline")
    }

    /// The scoping half: a completion must never settle a DIFFERENT conversation's tab for the
    /// same path. Two conversations can each hold a live tab for one file.
    func testACompletionDoesNotSettleAnotherConversationsTabForTheSamePath() async throws {
        let conversationA = UUID()
        let conversationB = UUID()
        let path = tempDir.appendingPathComponent("Shared.swift").path

        store.initialPage = [ChatMessage(conversationId: conversationA, sender: .user,
                                         content: .markdownText("a"))]
        await viewModel.loadConversation(id: conversationA)
        viewModel.handleAgentWriteBegan(try XCTUnwrap(beganPayload(conversation: conversationA, path: path)))

        store.initialPage = [ChatMessage(conversationId: conversationB, sender: .user,
                                         content: .markdownText("b"))]
        await viewModel.loadConversation(id: conversationB)
        viewModel.handleAgentWriteBegan(try XCTUnwrap(beganPayload(conversation: conversationB, path: path)))
        XCTAssertTrue(viewModel.hasLiveAgentTabs, "precondition: B also holds a live tab for it")

        // A's write finishes. B's tab — the displayed one — must be untouched.
        viewModel.handleAgentWriteCompleted(
            try XCTUnwrap(completedPayload(conversation: conversationA, path: path, isSuccess: true))
        )

        XCTAssertTrue(viewModel.hasLiveAgentTabs,
                      "B's write is still running; A's completion must not settle B's tab")
    }

    // MARK: - cv-3: a workflow node's abandoned write settles its live tab

    /// Builds a node timeline holding one still-executing `write_file` row.
    private func executingWriteRow(path: String) -> [TimelineEvent] {
        [.toolExecution(ToolExecutionData(
            id: UUID(),
            name: "write_file",
            params: #"{"file_path": "\#(path)", "content": "let x = 1"}"#,
            output: nil,
            isSuccess: nil,
            isExecuting: true
        ))]
    }

    /// Waits for one `AgentLiveWriteEvent.completed` post, or nil if none arrives.
    private func awaitCompletion(
        during body: @MainActor () -> Void
    ) async -> AgentLiveWriteEvent.Completed? {
        var received: AgentLiveWriteEvent.Completed?
        let token = NotificationCenter.default.addObserver(
            forName: AgentLiveWriteEvent.completed, object: nil, queue: .main
        ) { note in
            received = note.userInfo?[AgentLiveWriteEvent.payloadKey] as? AgentLiveWriteEvent.Completed
        }
        defer { NotificationCenter.default.removeObserver(token) }
        body()
        await Task.yield()
        return received
    }

    /// ⚠️ THE REGRESSION GUARD. `AgentLiveWriteEvent.began` is posted from `.toolCall` BEFORE the
    /// row is routed by `sourceNodeID`, so a workflow node's `write_file` DOES open a live tab —
    /// `DanglingToolRowCloser`'s own comment claimed it does not. CF-9's terminal walks
    /// `message.timelineEvents` only, and a node's rows live in `nodeTimelines`, so Stop during a
    /// parked node write settled the row but left the TAB `.active` for the rest of the session.
    /// Mutation that must kill this: change `closeReporting` back to `close` in
    /// `settleInFlightWork` and drop the `postLiveWriteCompletions` call.
    func testStoppingARunSettlesTheLiveTabOfAnAbandonedNodeWrite() async throws {
        let conversation = UUID()
        let path = tempDir.appendingPathComponent("NodeWrite.swift").path

        let state = WorkflowExecutionState()
        state.conversationID = conversation
        state.nodeTimelines[UUID()] = executingWriteRow(path: path)

        let completion = await awaitCompletion {
            state.settleInFlightWork(cancelled: true)
        }

        let payload = try XCTUnwrap(completion,
            "stopping a run must post a failed completion for the node's abandoned write, or its Code Viewer tab claims the agent is still writing forever")
        XCTAssertEqual(payload.conversationID, conversation)
        XCTAssertEqual(payload.fileName, "NodeWrite.swift")
        XCTAssertFalse(payload.isSuccess, "the proposal never reached disk")
    }

    /// The user-skip path had the same gap, and it is the one the false comment was attached to.
    /// Mutation that must kill this: revert `closeForUserSkipReporting` to `closeForUserSkip` and
    /// drop the post in `handleNodeSkipped`.
    func testSkippingANodeSettlesTheLiveTabOfItsAbandonedWrite() async throws {
        let conversation = UUID()
        let path = tempDir.appendingPathComponent("SkippedWrite.swift").path
        let nodeID = UUID()

        let state = WorkflowExecutionState()
        state.conversationID = conversation
        state.nodeTimelines[nodeID] = executingWriteRow(path: path)

        let completion = await awaitCompletion {
            state.handleNodeSkipped(nodeID: nodeID, profileName: "Writer",
                                    reason: .byUser, ranBeforeSkip: true)
        }

        let payload = try XCTUnwrap(completion,
            "a user skip must settle the abandoned write's tab — `began` is posted for node writes too")
        XCTAssertEqual(payload.fileName, "SkippedWrite.swift")
        XCTAssertFalse(payload.isSuccess)
    }

    /// A run with no abandoned writes must post nothing — the settle path runs on every cancel.
    func testSettlingARunWithNoAbandonedWritesPostsNothing() async {
        let state = WorkflowExecutionState()
        state.conversationID = UUID()

        let completion = await awaitCompletion {
            state.settleInFlightWork(cancelled: true)
        }
        XCTAssertNil(completion, "nothing was abandoned, so nothing may be posted")
    }

    // MARK: - vm-4: the page-in walk abandons on a conversation change

    /// ⚠️ The walk used to carry on after a switch, paging the NEWLY OPENED conversation up to the
    /// residency cap on the main actor — scroll jump, jank, and a cap notice for a conversation
    /// the user never scrolled back in. Mutation that must kill this: drop `myEpoch == loadEpoch`
    /// from `ensureMessageIsResident`'s loop condition and its in-loop guard.
    func testThePageInWalkStopsWhenAConversationLoadStarts() async throws {
        let conversationA = UUID()
        let resident = (0..<4).map { i in
            ChatMessage(conversationId: conversationA, sender: .user,
                        content: .markdownText("A-resident-\(i)"))
        }
        // Load A for real, so `loadedConversationID` is set and the corpus can be prepared
        // through the production path rather than seeded.
        store.initialPage = resident
        await viewModel.loadConversation(id: conversationA)
        viewModel.canLoadMorePages = true

        // A real corpus whose tail is NOT resident, so the walk has somewhere to page toward.
        let corpusIDs = resident.map(\.id) + (0..<36).map { _ in UUID() }
        store.searchDocuments[conversationA] = corpusIDs.map {
            SearchDocument(id: $0, timestamp: Date(), units: [])
        }
        await viewModel.prepareSearchCorpus()

        // Every page-in returns one more message, so the walk would otherwise keep going.
        store.pages[conversationA] = [ChatMessage(conversationId: conversationA, sender: .user,
                                                  content: .markdownText("A-older"))]
        // ⚠️ The switch must land during the loop's `Task.yield()`, NOT inside a fetch.
        // A switch inside a fetch is already absorbed by `loadMoreMessages`' own epoch guard:
        // the page is discarded, so `currentChatMessages.count == countBefore` and the loop's
        // pre-existing "no progress" break exits it anyway — an interleaving that cannot tell
        // this fix from its absence. (Verified: a first version of this test passed against a
        // mutant with the walk's guard removed.)
        //
        // Scheduling the bump as an unstructured Task from inside the first fetch defers it to
        // the next main-actor suspension, which IS that yield — after the page was appended and
        // progress was made. That is the real interleaving: `loadMoreMessages` then captures a
        // STABLE epoch on every later call and happily pages the newly-opened conversation.
        var fetches = 0
        store.duringFetch = { [weak viewModel] in
            fetches += 1
            if fetches == 1 {
                Task { @MainActor in viewModel?.bumpLoadEpochForTesting() }
            }
        }
        XCTAssertNotNil(viewModel.searchCorpusIndex(of: corpusIDs[corpusIDs.count - 1]),
                        "precondition: the target is in the corpus but not resident")

        // A target that is in the corpus but will never become resident.
        let unreachable = try XCTUnwrap(corpusIDs.last)
        let arrived = await viewModel.ensureMessageIsResident(unreachable)

        XCTAssertFalse(arrived, "the walk must report failure, not silently page the new conversation")
        XCTAssertLessThanOrEqual(fetches, 2,
                                 "the walk must abandon at the yield once a load started — without the guard it pages the NEW conversation up to the 300-message residency cap (32 pages)")
        XCTAssertFalse(viewModel.hasReachedResidencyCap,
                       "…and must not leave the newly-opened conversation flagged as capped, which disables its own scroll-back")
    }
}
