//
//  SaveClusterFixTests.swift
//  DevgenticTests
//
//  Regression cover for the Code Viewer save cluster fixed on 2026-08-10
//  (Chat_Production_Readiness.md rows CH1–CH3, CH8).
//

import XCTest
@testable import devgentic

@MainActor
private final class PlainStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        [ChatMessage(conversationId: conversationId, sender: .user, content: .plainText("anchor"))]
    }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

/// `PlainStore` plus a gate, so a test can hold `loadConversation` suspended mid-fetch —
/// the window in which `currentChatMessages` still names the OUTGOING conversation.
@MainActor
private final class GatedPlainStore: ChatPersistenceProtocol {
    var gateNextFetch = false
    var gate: CheckedContinuation<Void, Never>?

    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        if gateNextFetch {
            gateNextFetch = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in self.gate = c }
        }
        return [ChatMessage(conversationId: conversationId, sender: .user, content: .plainText("anchor"))]
    }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}

    func release() { gate?.resume(); gate = nil }
}

@MainActor
final class SaveClusterFixTests: XCTestCase {

    private var store: PlainStore!
    private var viewModel: ChatHistoryViewModel!
    private let conversationA = UUID()

    override func setUp() async throws {
        store = PlainStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store,
                                                     fileProcessorService: FileProcessorService()),
            ownsCodeViewer: true
        )
    }

    override func tearDown() async throws {
        viewModel = nil
        store = nil
    }

    // MARK: - CH8

    /// The welcome-screen round trip. Callers (`deselectConversationAndShowWelcome`,
    /// `performInterfaceSwitch`, ⌘N from code/workflow mode) pre-clear
    /// `currentChatMessages` and only THEN let the debounced `loadConversation(nil)` run.
    /// Reading the viewer's identity from the messages made that `nil != nil`, so the reset
    /// was skipped, `loadedConversationID` was nil'd, and the NEXT load cleared every tab
    /// under an identity the stash could not resolve.
    func testWelcomeScreenRoundTripPreservesTabsAndDrafts() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("no tab") }
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let a = 999 // draft")
        XCTAssertTrue(viewModel.codeViewerTabs.first?.isDirty == true, "precondition: tab is dirty")

        // Exactly what the coordinators do: pre-clear, then load nil.
        viewModel.currentChatMessages = []
        await viewModel.loadConversation(id: nil)

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty,
                      "the viewer must be cleared, not left rendering orphaned tabs")

        // Returning to the SAME conversation must bring the tab AND the draft back.
        await viewModel.loadConversation(id: conversationA)
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1,
                       "A's tab must be restored after a welcome-screen round trip")
        XCTAssertEqual(viewModel.codeViewerTabs.first?.effectiveCode, "let a = 999 // draft",
                       "the unsaved draft must survive — it exists nowhere else")
    }

    /// A same-conversation reload (the user-messages filter routes through
    /// `loadConversation`) must still NOT wipe open tabs. Guards the fix against
    /// over-resetting.
    func testSameConversationReloadKeepsTabs() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)

        await viewModel.loadConversation(id: conversationA)
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1,
                       "a same-conversation reload must not clear the viewer")
    }

    // MARK: - CH2

    /// A live agent rewrite of a tab the user had already SAVED must adopt the agent's
    /// content. `isDirty` is false after a successful save while `editedCode` is still set,
    /// so the tab slipped past the !isDirty guard holding the user's stale buffer — and a
    /// later ⌘S wrote that stale text back over the agent's file.
    func testLiveRewriteOfSavedTabAdoptsAgentContent() async {
        await viewModel.loadConversation(id: conversationA)
        let path = "/tmp/devgentic_save_cluster_\(UUID().uuidString).swift"

        viewModel.handleAgentWriteBegan(
            AgentLiveWriteEvent.Began(conversationID: conversationA,
                                      path: path,
                                      fileName: "Thing.swift",
                                      proposedContent: "let version = 1")
        )
        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("no tab") }

        // The user edits and saves: this is the state that leaves `editedCode` non-nil
        // while `isDirty` reads false.
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let version = 1 // mine")
        await viewModel.saveTabToItsPath(tabID: tabID)
        XCTAssertFalse(viewModel.codeViewerTabs.first?.isDirty ?? true,
                       "precondition: a saved tab is clean but still holds editedCode")

        // The agent writes the same file again.
        viewModel.handleAgentWriteBegan(
            AgentLiveWriteEvent.Began(conversationID: conversationA,
                                      path: path,
                                      fileName: "Thing.swift",
                                      proposedContent: "let version = 2")
        )

        XCTAssertEqual(viewModel.codeViewerTabs.first?.effectiveCode, "let version = 2",
                       "the tab must show the agent's new content, not the user's stale buffer")
        XCTAssertFalse(viewModel.codeViewerTabs.first?.isDirty ?? true,
                       "the tab must not claim unsaved changes it never earned")

        try? FileManager.default.removeItem(atPath: path)
    }

    /// The dirty case is unchanged: a tab holding genuine unsaved edits is still skipped.
    func testLiveRewriteStillSkipsTabWithUnsavedEdits() async {
        await viewModel.loadConversation(id: conversationA)
        let path = "/tmp/devgentic_save_cluster_\(UUID().uuidString).swift"

        viewModel.handleAgentWriteBegan(
            AgentLiveWriteEvent.Began(conversationID: conversationA, path: path,
                                      fileName: "Thing.swift", proposedContent: "let version = 1")
        )
        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("no tab") }
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "unsaved work")

        viewModel.handleAgentWriteBegan(
            AgentLiveWriteEvent.Began(conversationID: conversationA, path: path,
                                      fileName: "Thing.swift", proposedContent: "let version = 2")
        )

        XCTAssertEqual(viewModel.codeViewerTabs.first?.effectiveCode, "unsaved work",
                       "an unsaved draft must still be preserved against a live rewrite")
    }

    // MARK: - CH60

    /// A live agent write for the OUTGOING conversation, landing while the INCOMING
    /// conversation's fetch is still in flight, must be ignored.
    ///
    /// `loadConversation` assigns `currentChatMessages`/`loadedConversationID` only AFTER the
    /// fetch returns, so mid-load both still name the conversation being LEFT. The live-write
    /// guard compared against that, accepted the write, and appended its tab to the incoming
    /// conversation's just-cleared viewer — which then suppressed that conversation's restore,
    /// because `restoreCodeViewerSession` only fires on an empty viewer.
    ///
    /// Permanent home for the scenario in `ZZAuditTabLifecycleTests`, which is marked
    /// "TEMPORARY audit repro — delete after review".
    func testLiveWriteForOutgoingConversationDuringLoadIsIgnored() async {
        let gated = GatedPlainStore()
        let vm = ChatHistoryViewModel(
            persistenceService: gated,
            activeStreamManager: ActiveStreamManager(persistenceService: gated,
                                                     fileProcessorService: FileProcessorService()),
            ownsCodeViewer: true
        )
        let conversationB = UUID()

        // B gets a tab, then we switch to A so B's tab is stashed.
        await vm.loadConversation(id: conversationB)
        vm.showCodeInViewer(language: "python", code: "b = 2")
        await vm.loadConversation(id: conversationA)
        XCTAssertTrue(vm.codeViewerTabs.isEmpty, "precondition: switching away cleared the viewer")

        // Switch A -> B, and while that load is suspended, A's agent finishes a write.
        gated.gateNextFetch = true
        let load = Task { await vm.loadConversation(id: conversationB) }
        for _ in 0 ..< 500 where gated.gate == nil { await Task.yield() }
        XCTAssertNotNil(gated.gate, "gate never armed")

        vm.handleAgentWriteBegan(
            AgentLiveWriteEvent.Began(conversationID: conversationA,
                                      path: "/tmp/devgentic_ch60_\(UUID().uuidString).java",
                                      fileName: "FromA.java",
                                      proposedContent: "class FromA {}")
        )
        gated.release()
        _ = await load.value

        XCTAssertEqual(vm.codeViewerTabs.count, 1)
        XCTAssertEqual(vm.codeViewerTabs.first?.snippet.language, "python",
                       "B's stashed tab must be restored, not conversation A's live-write tab")

        // And A's orphan must not have overwritten B's stash on the way through.
        await vm.loadConversation(id: UUID())
        await vm.loadConversation(id: conversationB)
        XCTAssertEqual(vm.codeViewerTabs.first?.snippet.language, "python",
                       "B's stash still holds B's tab")
    }

    // MARK: - CH3

    /// Save As now routes through `contentToApply`, so overwriting an existing file keeps
    /// that file's edge whitespace instead of writing the trimmed editor buffer verbatim.
    func testContentToApplyRestoresEdgeWhitespaceForSaveAs() {
        // The buffer as the editor holds it — `normalizedCode` trimmed both edges on open.
        let buffer = "let a = 1"
        let onDisk = "\n    let a = 0\n"

        let written = ChatHistoryViewModel.contentToApply(
            snippetCode: buffer, preservingEdgeWhitespaceOf: onDisk
        )
        XCTAssertTrue(written.hasSuffix("\n"), "the POSIX trailing newline must be restored")
        XCTAssertTrue(written.hasPrefix("\n    "), "the leading blank line/indent must be restored")

        // A genuinely new file has no baseline: the buffer is written unchanged.
        let fresh = ChatHistoryViewModel.contentToApply(
            snippetCode: buffer, preservingEdgeWhitespaceOf: buffer
        )
        XCTAssertEqual(fresh, buffer, "a new Save-As target must not gain phantom whitespace")
    }
}
