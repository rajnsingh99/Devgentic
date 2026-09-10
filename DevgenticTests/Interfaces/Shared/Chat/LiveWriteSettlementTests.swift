// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  LiveWriteSettlementTests.swift
//  DevgenticTests
//
//  Regression cover for AD4 and its twin (Chat_Production_Readiness.md Part D).
//
//  CH60 migrated the live-write BEGAN guard to `destinationConversationID` but left the
//  symmetric handlers on `currentChatMessages.first?.conversationId`, which names the OUTGOING
//  conversation for the whole duration of a switch. So a write admitted mid-load could never be
//  settled, and a close mid-load resolved the wrong conversation's stash.
//

import XCTest
@testable import devgentic

/// Holds the next fetch suspended so a conversation switch can be observed mid-flight — the
/// window in which `currentChatMessages` still names the conversation being left.
@MainActor
private final class GatedStore: ChatPersistenceProtocol {
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
final class LiveWriteSettlementTests: XCTestCase {

    private var store: GatedStore!
    private var viewModel: ChatHistoryViewModel!
    private let conversationA = UUID()
    private let conversationB = UUID()

    override func setUp() async throws {
        store = GatedStore()
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

    private func waitForGate() async {
        for _ in 0 ..< 500 where store.gate == nil { await Task.yield() }
        XCTAssertNotNil(store.gate, "gate never armed")
    }

    private func began(_ conversation: UUID, path: String, content: String = "class X {}") -> AgentLiveWriteEvent.Began {
        .init(conversationID: conversation, path: path, fileName: (path as NSString).lastPathComponent,
              proposedContent: content)
    }

    private func completed(_ conversation: UUID, path: String, success: Bool) -> AgentLiveWriteEvent.Completed {
        .init(conversationID: conversation, path: path, fileName: (path as NSString).lastPathComponent,
              isSuccess: success, preWriteContent: nil)
    }

    // MARK: - AD4

    /// A write admitted mid-load by the began-guard must be settleable by the completion. The
    /// completion guard read the OUTGOING conversation, so it dropped silently and the tab kept
    /// `liveState == .active` forever — orange "Agent is writing this file" banner and a pulsing
    /// pill for a write that had already finished.
    func testCompletionSettlesATabAdmittedWhileTheDestinationIsStillLoading() async {
        await viewModel.loadConversation(id: conversationA)
        let path = "/tmp/devgentic_ad4_\(UUID().uuidString).swift"

        store.gateNextFetch = true
        let load = Task { await viewModel.loadConversation(id: conversationB) }
        await waitForGate()

        // Admitted because the DESTINATION is B, even though currentChatMessages still holds A.
        viewModel.handleAgentWriteBegan(began(conversationB, path: path))
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "precondition: the began-guard admitted it")
        XCTAssertTrue(viewModel.hasLiveAgentTabs)

        // The completion posts BEFORE the fetch returns — the window AD4 is about.
        viewModel.handleAgentWriteCompleted(completed(conversationB, path: path, success: true))

        // Guarded, not subscripted: an XCTAssert does not stop execution, so indexing after a
        // failed count assertion traps and takes the whole suite down instead of reporting.
        guard let settled = viewModel.codeViewerTabs.first else {
            store.release(); _ = await load.value
            return XCTFail("the live tab is gone")
        }
        XCTAssertNil(settled.liveState,
                     "the tab must settle — it was admitted under the same identity")
        XCTAssertFalse(viewModel.hasLiveAgentTabs, "the pulsing pill must stop")

        store.release()
        _ = await load.value
    }

    /// A DENIED write must reach `.rejected` in the same window — otherwise the user is told a
    /// file is being written when the proposal never reached disk.
    func testDeniedWriteIsMarkedRejectedWhileStillLoading() async {
        await viewModel.loadConversation(id: conversationA)
        let path = "/tmp/devgentic_ad4_\(UUID().uuidString).swift"

        store.gateNextFetch = true
        let load = Task { await viewModel.loadConversation(id: conversationB) }
        await waitForGate()

        viewModel.handleAgentWriteBegan(began(conversationB, path: path))
        viewModel.handleAgentWriteCompleted(completed(conversationB, path: path, success: false))

        guard let tab = viewModel.codeViewerTabs.first else {
            store.release(); _ = await load.value
            return XCTFail("the live tab is gone")
        }
        XCTAssertEqual(tab.liveState, .rejected,
                       "a denied write must be visibly rejected, not left claiming to be writing")

        store.release()
        _ = await load.value
    }

    /// Control: a completion for a DIFFERENT conversation must still be refused, so the fix did
    /// not simply widen the guard into accepting everything.
    func testCompletionForAnotherConversationIsStillRefused() async {
        await viewModel.loadConversation(id: conversationB)
        let path = "/tmp/devgentic_ad4_\(UUID().uuidString).swift"
        viewModel.handleAgentWriteBegan(began(conversationB, path: path))
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)

        viewModel.handleAgentWriteCompleted(completed(conversationA, path: path, success: true))

        guard let tab = viewModel.codeViewerTabs.first else { return XCTFail("the live tab is gone") }
        XCTAssertEqual(tab.liveState, .active,
                       "another conversation's completion must not settle this tab")
    }

    // MARK: - AD4's twin (cross-5)

    /// Closing a tab mid-switch must not remove the OUTGOING conversation's stash. `resetCodeViewer`
    /// has already filed A's tabs — including unsaved drafts, which live nowhere else — and
    /// `dropStashedTabs` resolved that same id, so the close destroyed them and logged a reason
    /// describing a tab the user never closed.
    func testClosingATabDuringASwitchDoesNotDestroyTheOutgoingStash() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let aTab = viewModel.codeViewerTabs.first?.id else { return XCTFail("no tab") }
        viewModel.updateCodeViewerDraft(tabID: aTab, content: "let a = 999 // unsaved")
        XCTAssertTrue(viewModel.codeViewerTabs.first?.isDirty == true, "precondition: A holds an unsaved draft")

        store.gateNextFetch = true
        let load = Task { await viewModel.loadConversation(id: conversationB) }
        await waitForGate()

        // A's tabs are stashed and the viewer is cleared; B's live write pops a tab in.
        let path = "/tmp/devgentic_ad4_\(UUID().uuidString).swift"
        viewModel.handleAgentWriteBegan(began(conversationB, path: path))
        guard let bTab = viewModel.codeViewerTabs.first?.id else { return XCTFail("no live tab") }

        // The user closes it before B's fetch returns.
        viewModel.closeCodeViewerTab(id: bTab)

        store.release()
        _ = await load.value

        // Back to A: the draft must still be there.
        await viewModel.loadConversation(id: conversationA)
        guard let restored = viewModel.codeViewerTabs.first else {
            return XCTFail("A's stash did not survive a tab close during the switch — the draft is gone")
        }
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(restored.effectiveCode, "let a = 999 // unsaved",
                       "the unsaved draft lives nowhere else")
    }

    /// Control: a close with NO switch in flight must still drop the stash — otherwise closed
    /// tabs resurrect, which is the bug `dropStashedTabs` exists to prevent.
    func testClosingATabOutsideASwitchStillDropsTheStash() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let tab = viewModel.codeViewerTabs.first?.id else { return XCTFail("no tab") }

        viewModel.closeCodeViewerTab(id: tab)
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty, "precondition: a clean tab closes immediately")

        await viewModel.loadConversation(id: conversationB)
        await viewModel.loadConversation(id: conversationA)

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty,
                      "an explicitly closed tab must not come back on reopen")
    }
}
