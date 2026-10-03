// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
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

    /// ⚠️ REWRITTEN 2026-09-12 (vm-1). This used to assert that a write for the INCOMING
    /// conversation IS admitted mid-load and must then be settleable. `handleAgentWriteBegan` now
    /// refuses the whole window, so that tab is never created — which makes AD4's hazard
    /// unreachable rather than merely handled, and closes a worse one: `restoreCodeViewerSession`
    /// only restores INTO AN EMPTY viewer, so any tab planted here silently cancelled the incoming
    /// conversation's own restore, and the next switch then overwrote its stash — losing drafts
    /// that live nowhere else. `AgentTimelineView.shouldDeliverOpen` already refused this same
    /// window for the timeline's open path; the two now agree.
    ///
    /// AD4's REAL protection is preserved and still asserted below: a completion arriving mid-load
    /// must settle its tab. It is now exercised on a tab created BEFORE the load — the case that
    /// still occurs — where the old completion guard (which read the outgoing conversation) would
    /// have dropped it.
    func testNoTabIsAdmittedMidLoadAndAPriorTabStillSettles() async {
        await viewModel.loadConversation(id: conversationA)
        let priorPath = "/tmp/devgentic_ad4_prior_\(UUID().uuidString).swift"
        viewModel.handleAgentWriteBegan(began(conversationA, path: priorPath))
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "precondition: A holds a live write tab")

        store.gateNextFetch = true
        let load = Task { await viewModel.loadConversation(id: conversationB) }
        await waitForGate()

        // A write for the conversation being LOADED gets no tab at all.
        let midLoadPath = "/tmp/devgentic_ad4_\(UUID().uuidString).swift"
        viewModel.handleAgentWriteBegan(began(conversationB, path: midLoadPath))
        XCTAssertFalse(viewModel.codeViewerTabs.contains { $0.filePath == midLoadPath },
                       "nothing may be planted while a load is in flight — it suppresses that conversation's restore")

        // A's earlier write finishes while B is still loading. It must still settle, on the
        // stashed copy — this is the half of AD4 that remains reachable.
        viewModel.handleAgentWriteCompleted(completed(conversationA, path: priorPath, success: true))

        store.release()
        _ = await load.value
        await viewModel.loadConversation(id: conversationA)

        guard let settled = viewModel.codeViewerTabs.first(where: { $0.filePath == priorPath }) else {
            return XCTFail("A's live tab is gone")
        }
        XCTAssertNil(settled.liveState, "the completion must settle it even though it arrived mid-load")
        XCTAssertFalse(viewModel.hasLiveAgentTabs, "the pulsing pill must stop")
    }

    /// A DENIED write must reach `.rejected` even when its completion lands mid-load — otherwise
    /// the user is told a file is being written when the proposal never reached disk.
    ///
    /// ⚠️ REWRITTEN 2026-09-12 (vm-1): the tab is now created BEFORE the load starts, because a
    /// mid-load `began` is refused outright. See `testNoTabIsAdmittedMidLoadAndAPriorTabStillSettles`.
    func testDeniedWriteIsMarkedRejectedWhenTheCompletionLandsMidLoad() async {
        await viewModel.loadConversation(id: conversationA)
        let path = "/tmp/devgentic_ad4_\(UUID().uuidString).swift"
        viewModel.handleAgentWriteBegan(began(conversationA, path: path))
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "precondition: the tab exists before the switch")

        store.gateNextFetch = true
        let load = Task { await viewModel.loadConversation(id: conversationB) }
        await waitForGate()

        viewModel.handleAgentWriteCompleted(completed(conversationA, path: path, success: false))

        store.release()
        _ = await load.value
        await viewModel.loadConversation(id: conversationA)

        guard let tab = viewModel.codeViewerTabs.first(where: { $0.filePath == path }) else {
            return XCTFail("the live tab is gone")
        }
        XCTAssertEqual(tab.liveState, .rejected,
                       "a denied write must be visibly rejected, not left claiming to be writing")
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
    func testARefusedLiveWriteDuringASwitchDoesNotDestroyTheOutgoingStash() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let aTab = viewModel.codeViewerTabs.first?.id else { return XCTFail("no tab") }
        viewModel.updateCodeViewerDraft(tabID: aTab, content: "let a = 999 // unsaved")
        XCTAssertTrue(viewModel.codeViewerTabs.first?.isDirty == true, "precondition: A holds an unsaved draft")

        store.gateNextFetch = true
        let load = Task { await viewModel.loadConversation(id: conversationB) }
        await waitForGate()

        // ⚠️ REWRITTEN 2026-09-12 (vm-1). This used to pop a live-write tab in for B mid-load and
        // close THAT, because `dropStashedTabs` resolved the closed tab's id back to A's stash and
        // destroyed the draft. `handleAgentWriteBegan` now refuses the whole load window, and the
        // timeline's open path (`shouldDeliverOpen`) already did — so no tab can exist to be
        // closed here, and cross-5's hazard is unreachable rather than handled.
        //
        // What is still worth pinning, and is the point of the test, is the OUTCOME: A's unsaved
        // draft survives a switch during which a live write for B arrives and is refused. The
        // refusal must not disturb the stash it was protecting.
        let path = "/tmp/devgentic_ad4_\(UUID().uuidString).swift"
        viewModel.handleAgentWriteBegan(began(conversationB, path: path))
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty,
                      "the refused write must leave the viewer empty, so B's own restore is not suppressed")

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

    // ⚠️ `dropStashedTabs`' load guard has NO reachable caller and therefore no test — reported,
    // not papered over. The cross-5 rewrite removed its only coverage (that test reached it by
    // closing a live-write tab planted mid-load, which vm-1 now refuses to plant), and both
    // remaining routes are closed too: the single close needs a tab to close, and
    // `forceCloseAllCodeViewerTabs` returns at its own
    // `guard !codeViewerTabs.isEmpty || isCodeViewerVisible` — mid-load `resetCodeViewer` has made
    // BOTH false. A test I wrote against the close-all route passed with the guard deleted, which
    // is how this was found. The guard stays as a backstop; see its doc for why.

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
