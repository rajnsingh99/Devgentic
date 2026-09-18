// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeViewerP3ClusterTests.swift
//  DevgenticTests
//
//  Covers the Code Viewer half of the P3 pass (Chat_Production_Readiness_Fresh.md):
//  CF-10 (a rejected live-write tab's drift baseline), CF-11 (Save & Close for path-linked
//  tabs), CF-12 (save bookkeeping surviving a stash), CF-13 (per-tab editor view state),
//  CF-16 (the intra-line refinement split out of the line-level diff), CF-17 (the Save-As
//  destination pre-read cap).
//
//  CF-12's stash-during-modeless-panel race is NOT covered here: `tabsByConversation` and
//  the stash functions are private, and the race can only be reached by suspending real
//  filesystem I/O mid-await, which this store-injection seam does not reach. Verify on
//  device: Save As on an agent-written tab, switch conversations while the panel is open,
//  confirm the tab is linked and clean on return.
//

import XCTest
import CodeEditSourceEditor
@testable import devgentic

@MainActor
private final class NoopChatStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

// MARK: - CF-11: Save & Close reachability

final class SaveAndCloseReachabilityTests: XCTestCase {

    private func tab(sourceFileID: UUID? = nil, filePath: String? = nil) -> CodeViewerTab {
        let snippet = CodeSnippet(language: "swift", code: "let x = 1",
                                  sourceMessageID: sourceFileID.map { _ in UUID() },
                                  sourceFileID: sourceFileID)
        return CodeViewerTab(snippet: snippet, filePath: filePath)
    }

    /// The defect: only an ATTACHMENT-linked tab (`sourceFileID`) could Save & Close, so
    /// every agent live-write tab — `filePath` set, `sourceFileID` nil — offered only
    /// Discard or Cancel although ⌘S saves it fine.
    func testPathLinkedTabCanSaveAndClose() {
        XCTAssertTrue(CodeViewerPanelView.canSaveAndClose(tab(filePath: "/tmp/Agent.swift")))
    }

    func testAttachmentLinkedTabCanSaveAndClose() {
        XCTAssertTrue(CodeViewerPanelView.canSaveAndClose(tab(sourceFileID: UUID())))
    }

    /// An unlinked chat-block tab has nowhere ⌘S would write either — Save & Close must
    /// stay hidden for it, or the button would offer an action that silently does nothing.
    func testUnlinkedTabCannotSaveAndClose() {
        XCTAssertFalse(CodeViewerPanelView.canSaveAndClose(tab()))
    }
}

// MARK: - CF-13: per-tab editor state

@MainActor
final class CodeViewerEditorStateStoreTests: XCTestCase {

    func testUnseenTabStartsAtAFreshState() {
        let store = CodeViewerEditorStateStore()
        XCTAssertEqual(store.retainedTabCount, 0)
        // A fresh SourceEditorState is what "starts at the top" means here — retrieving
        // one must not itself retain anything (a pure read shouldn't grow the store).
        _ = store.state(for: UUID())
        XCTAssertEqual(store.retainedTabCount, 0)
    }

    /// The whole point of the store: state set for one tab must come back for THAT tab,
    /// and switching to a different tab and back must not have disturbed it.
    func testStateIsKeyedByTabAndSurvivesASwitchAway() {
        let store = CodeViewerEditorStateStore()
        let tabA = UUID()
        let tabB = UUID()
        // ⚠️ DISTINGUISHABLE, not `SourceEditorState()`. Two default-constructed states compare
        // equal, so a fixture built from defaults passes this test even when the store hands
        // back the WRONG tab's state — which is the only thing it exists to get right.
        let stateA = SourceEditorState(findText: "needle-A")
        store.setState(stateA, for: tabA)

        let readB = store.state(for: tabB)
        let retrieved = store.state(for: tabA)

        XCTAssertEqual(retrieved, stateA)
        XCTAssertNotEqual(readB, stateA, "tabB must not see tabA's state")
        XCTAssertEqual(store.retainedTabCount, 1, "reading tabB must not retain a state for it")
    }

    /// Closing a tab must drop its state — a closed tab has nothing to resume.
    func testForgetDropsClosedTabsOnly() {
        let store = CodeViewerEditorStateStore()
        let closed = UUID()
        let kept = UUID()
        let keptState = SourceEditorState(findText: "keep-me")
        store.setState(SourceEditorState(findText: "drop-me"), for: closed)
        store.setState(keptState, for: kept)

        store.forget(tabIDs: [closed])

        XCTAssertEqual(store.retainedTabCount, 1)
        // ⚠️ Assert against the VALUE that was stored. The earlier form compared
        // `state(for: kept)` with itself, which is true however wrong the store is.
        XCTAssertEqual(store.state(for: kept), keptState, "forget dropped the surviving tab's state")
        XCTAssertNotEqual(store.state(for: closed), SourceEditorState(findText: "drop-me"),
                          "the closed tab's state must be gone, not merely unreferenced")
    }
}

// MARK: - CF-16: line-level diff vs the full refinement

final class DiffUtilityLineLevelTests: XCTestCase {

    /// The whole of CF-16: `lineLevelDiff` must NOT compute segments — that is the
    /// expensive half `changeCounts` was paying for and throwing away.
    func testLineLevelDiffNeverPopulatesSegments() {
        let original = "func a() {\n    return 1\n}"
        let modified = "func a() {\n    return 2\n}"
        let rows = DiffUtility.lineLevelDiff(original: original, modified: modified)

        XCTAssertTrue(rows.contains { $0.type == .added || $0.type == .deleted },
                      "fixture must actually produce a change (a 'modified' line is a deleted+added pair)")
        XCTAssertTrue(rows.allSatisfy { $0.segments == nil },
                      "lineLevelDiff must skip the intra-line refinement entirely")
    }

    /// `generateDiff` is UNCHANGED for the one caller that consumes `segments`
    /// (`FileChangePreviewView` renders them), so the split must not have silently emptied
    /// them there too.
    func testGenerateDiffStillRefines() {
        let original = "let value = computeSomething(1, 2)"
        let modified = "let value = computeSomething(1, 3)"
        let rows = DiffUtility.generateDiff(original: original, modified: modified)

        XCTAssertTrue(rows.contains { $0.segments != nil },
                      "generateDiff must still attach intra-line segments for a similar modified pair")
    }

    /// The counts must agree between the two entry points — `lineLevelDiff` changes WHICH
    /// work runs, never WHAT a row's type is, since `refineIntraLine` only ever attaches
    /// `segments` and never rewrites `type`.
    func testChangeCountsAgreeWithGenerateDiffsRowTypes() {
        let original = "line one\nline two\nline three"
        let modified = "line one\nline TWO\nline three\nline four"

        let (added, deleted) = DiffUtility.changeCounts(original: original, modified: modified)
        let fullDiff = DiffUtility.generateDiff(original: original, modified: modified)
        let addedFromFull = fullDiff.filter { $0.type == .added }.count
        let deletedFromFull = fullDiff.filter { $0.type == .deleted }.count

        XCTAssertEqual(added, addedFromFull)
        XCTAssertEqual(deleted, deletedFromFull)
    }
}

// MARK: - CF-17: Save-As destination pre-read cap

final class SaveAsDestinationPreReadCapTests: XCTestCase {

    /// The defect the cap closes: Save As read the chosen destination in FULL before writing
    /// a ~50 KB buffer over it, so picking an existing multi-GB log or DB dump allocated the
    /// whole file as a Swift String. Moving that read to a detached task removed the UI
    /// freeze but not the allocation — this is the half CF-17 left open.
    func testOversizedDestinationIsNotPreRead() {
        XCTAssertFalse(CodeViewerPanelView.shouldPreReadSaveAsDestination(
            byteSize: AgentLiveWriteEvent.liveContentByteLimit + 1))
    }

    /// The cap must not disable the pre-read for ordinary destinations: without a baseline
    /// `contentToApply` degrades to a no-op and Save As writes `normalizedCode` verbatim,
    /// silently deleting the destination's leading blank line and POSIX trailing newline.
    /// A gate that returned false everywhere would pass the test above and reintroduce that.
    func testOrdinaryDestinationIsStillPreRead() {
        XCTAssertTrue(CodeViewerPanelView.shouldPreReadSaveAsDestination(byteSize: 0))
        XCTAssertTrue(CodeViewerPanelView.shouldPreReadSaveAsDestination(byteSize: 64_000))
        // Boundary: the cap is inclusive, matching `handleAgentWriteBegan`'s `<=`.
        XCTAssertTrue(CodeViewerPanelView.shouldPreReadSaveAsDestination(
            byteSize: AgentLiveWriteEvent.liveContentByteLimit))
    }
}

// MARK: - CF-10: rejected live-write tab drift baseline

@MainActor
final class RejectedLiveWriteDriftBaselineTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()
    private var tempDir: URL!

    override func setUp() async throws {
        let store = NoopChatStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        )
        viewModel.currentChatMessages = [
            ChatMessage(conversationId: conversationID, sender: .user, content: .plainText("hi"))
        ]
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cf10_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        viewModel = nil
    }

    private func began(path: String, content: String) -> AgentLiveWriteEvent.Began {
        .init(conversationID: conversationID, path: path,
             fileName: (path as NSString).lastPathComponent, proposedContent: content)
    }

    private func completed(path: String, success: Bool, pre: String? = nil) -> AgentLiveWriteEvent.Completed {
        .init(conversationID: conversationID, path: path,
             fileName: (path as NSString).lastPathComponent, isSuccess: success, preWriteContent: pre)
    }

    /// Polls for the async pre-read `handleAgentWriteBegan` fires — same idiom
    /// `LiveWriteSettlementTests.waitForGate` uses for the equivalent race.
    private func waitForPreWriteDisk(path: String) async {
        for _ in 0 ..< 500 {
            if viewModel.codeViewerTabs.first(where: { $0.filePath == path })?.preWriteDisk != nil { return }
            await Task.yield()
        }
        XCTFail("preWriteDisk never landed")
    }

    /// The defect: a denied write kept the PROPOSAL as the drift baseline (by definition
    /// not on disk), so the guard refused every ⌘S on the tab as "changed on disk" forever.
    func testDeniedWriteAdoptsThePreWriteReadAsTheDriftBaseline() async throws {
        let path = tempDir.appendingPathComponent("Main.swift").path
        let onDisk = "let existing = true\n"
        try onDisk.write(toFile: path, atomically: true, encoding: .utf8)

        viewModel.handleAgentWriteBegan(began(path: path, content: "let proposed = false\n"))
        await waitForPreWriteDisk(path: path)

        // Denial carries no executor snapshot — ToolExecutionLoop builds it before the
        // pre-write snapshot runs — so the UI's own pre-read is the only baseline there is.
        viewModel.handleAgentWriteCompleted(completed(path: path, success: false, pre: nil))

        let tab = viewModel.codeViewerTabs.first { $0.filePath == path }
        XCTAssertEqual(tab?.liveState, .rejected)
        XCTAssertEqual(tab?.lastSavedDisk, onDisk,
                       "the baseline must be what's actually on disk, not the rejected proposal")
    }

    /// The end-to-end proof: with the baseline fixed, ⌘S on a rejected tab can actually
    /// write — a save whose buffer matches (or is trivially derived from) what's on disk
    /// must not be refused as drift.
    func testDeniedTabCanSubsequentlyBeSavedWithoutADriftRefusal() async throws {
        let path = tempDir.appendingPathComponent("Config.swift").path
        let onDisk = "let flag = 1\n"
        try onDisk.write(toFile: path, atomically: true, encoding: .utf8)

        viewModel.handleAgentWriteBegan(began(path: path, content: "let flag = 2\n"))
        await waitForPreWriteDisk(path: path)
        viewModel.handleAgentWriteCompleted(completed(path: path, success: false))

        guard let tabID = viewModel.codeViewerTabs.first(where: { $0.filePath == path })?.id else {
            return XCTFail("tab missing")
        }
        // Edit the tab's buffer to the user's own change before saving.
        if let idx = viewModel.codeViewerTabs.firstIndex(where: { $0.id == tabID }) {
            viewModel.codeViewerTabs[idx].editedCode = "let flag = 3\n"
        }

        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertNil(viewModel.codeApplyError, "must not be refused as on-disk drift")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let flag = 3\n")
    }

    /// A successful write must clear `preWriteDisk` and must NOT seed `lastSavedDisk` from
    /// the pre-write bytes — the proposal IS what's on disk now, so the guard falls back to
    /// `snippet.code`, which is what actually landed.
    func testSuccessfulWriteDoesNotPromoteThePreWriteSnapshot() async throws {
        let path = tempDir.appendingPathComponent("Success.swift").path
        try "old\n".write(toFile: path, atomically: true, encoding: .utf8)

        viewModel.handleAgentWriteBegan(began(path: path, content: "new\n"))
        await waitForPreWriteDisk(path: path)
        viewModel.handleAgentWriteCompleted(completed(path: path, success: true))

        let tab = viewModel.codeViewerTabs.first { $0.filePath == path }
        XCTAssertNil(tab?.liveState)
        XCTAssertNil(tab?.preWriteDisk)
        XCTAssertNil(tab?.lastSavedDisk, "success falls back to snippet.code, not the stale pre-write bytes")
    }

    /// The "not applied" banner must clear once the user's OWN save puts the rejected
    /// content on disk — nothing else ever reset it, so it survived a save that made its
    /// claim false.
    func testUserSaveClearsTheRejectedBadge() async throws {
        let path = tempDir.appendingPathComponent("Badge.swift").path
        try "before\n".write(toFile: path, atomically: true, encoding: .utf8)

        viewModel.handleAgentWriteBegan(began(path: path, content: "proposed\n"))
        await waitForPreWriteDisk(path: path)
        viewModel.handleAgentWriteCompleted(completed(path: path, success: false))

        guard let tabID = viewModel.codeViewerTabs.first(where: { $0.filePath == path })?.id else {
            return XCTFail("tab missing")
        }
        XCTAssertEqual(viewModel.codeViewerTabs.first { $0.id == tabID }?.liveState, .rejected)

        if let idx = viewModel.codeViewerTabs.firstIndex(where: { $0.id == tabID }) {
            viewModel.codeViewerTabs[idx].editedCode = "before\n"
        }
        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertNil(viewModel.codeViewerTabs.first { $0.id == tabID }?.liveState,
                     "the rejected badge must clear once the user's save lands")
    }
}
