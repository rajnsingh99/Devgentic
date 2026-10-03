// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ZZAuditTabLifecycleTests.swift
//  DevgenticTests
//
//  TEMPORARY audit repro — delete after review.
//

import XCTest
@testable import devgentic

@MainActor
private final class GatedStore: ChatPersistenceProtocol {
    /// When true, the NEXT fetch suspends until `release()`.
    var gateNextFetch = false
    var gate: CheckedContinuation<Void, Never>?

    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        if gateNextFetch {
            gateNextFetch = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                self.gate = c
            }
        }
        return [ChatMessage(conversationId: conversationId, sender: .user, content: .plainText("anchor"))]
    }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}

    func release() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
final class ZZAuditTabLifecycleTests: XCTestCase {

    private var store: GatedStore!
    private var viewModel: ChatHistoryViewModel!
    private let conversationA = UUID()
    private let conversationB = UUID()
    private let conversationC = UUID()

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
        for _ in 0 ..< 500 {
            if store.gate != nil { return }
            await Task.yield()
        }
        XCTFail("Gate never armed")
    }

    /// A→B→C where the B load is CANCELLED after `resetCodeViewer` ran.
    /// A's tabs (and drafts) must survive.
    func testInterruptedSwitchDoesNotDeleteTheStash() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let a = 999 // draft")

        store.gateNextFetch = true
        let load = Task { await viewModel.loadConversation(id: conversationB) }
        await waitForGate()
        load.cancel()
        store.release()
        _ = await load.value

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty, "The interrupted switch cleared the viewer")

        await viewModel.loadConversation(id: conversationC)
        await viewModel.loadConversation(id: conversationA)

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1,
                       "A's stashed tab must survive an interrupted switch")
        XCTAssertEqual(viewModel.codeViewerTabs.first?.effectiveCode, "let a = 999 // draft")
    }

    /// A live agent write for the OUTGOING conversation landing mid-load leaves a tab in
    /// the just-cleared viewer, which suppresses the INCOMING conversation's restore.
    func testLiveWriteDuringLoadDoesNotSuppressRestore() async {
        // B gets a tab of its own, then we switch back to A (B is stashed).
        await viewModel.loadConversation(id: conversationB)
        viewModel.showCodeInViewer(language: "python", code: "b = 2")
        await viewModel.loadConversation(id: conversationA)
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)

        // Switch A -> B; while the load is in flight, A's agent finishes a file write.
        store.gateNextFetch = true
        let load = Task { await viewModel.loadConversation(id: conversationB) }
        await waitForGate()
        viewModel.handleAgentWriteBegan(
            AgentLiveWriteEvent.Began(conversationID: conversationA,
                                      path: "/tmp/zz_audit_nonexistent/FromA.java",
                                      fileName: "FromA.java",
                                      proposedContent: "class FromA {}")
        )
        store.release()
        _ = await load.value

        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(viewModel.codeViewerTabs.first?.snippet.language, "python",
                       "B's stashed tab must be restored, not conversation A's live-write tab")

        // And B's stash must not have been overwritten by A's tab.
        await viewModel.loadConversation(id: conversationC)
        await viewModel.loadConversation(id: conversationB)
        XCTAssertEqual(viewModel.codeViewerTabs.first?.snippet.language, "python",
                       "B's stash still holds B's tab")
    }

    /// Close-all does not clear the dictionary entry, and a SAME-conversation reload skips the
    /// stash — so the restore rehydrates tabs the user explicitly closed. [vm-9] The route this
    /// comment used to name (the user-messages filter) is deleted; the live one is QuickAccess
    /// re-opening the conversation it already holds (`QuickAccessSessionViewModel` calls
    /// `loadConversation(id:)` with its own `conversationID` on resume).
    func testClosedTabsDoNotResurrectOnSameConversationReload() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        // Round-trip so A gets a dictionary entry.
        await viewModel.loadConversation(id: conversationB)
        await viewModel.loadConversation(id: conversationA)
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "A's tab restored")

        viewModel.forceCloseAllCodeViewerTabs()
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty, "user closed everything")

        // Reload the SAME conversation — what a QuickAccess resume does.
        await viewModel.loadConversation(id: conversationA)

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty,
                      "Closed tabs must stay closed across a same-conversation reload")
    }
}
