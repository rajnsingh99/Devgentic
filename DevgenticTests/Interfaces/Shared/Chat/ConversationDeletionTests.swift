// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationDeletionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
private final class DeletionNoopStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class ConversationDeletionTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationA = UUID()
    private let conversationB = UUID()

    override func setUp() async throws {
        let store = DeletionNoopStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )
    }

    override func tearDown() async throws { viewModel = nil }

    /// Leaving a conversation stashes its tabs; coming back restores them. This is the
    /// whole of "persistence" now — one app session, no disk.
    func testTabsFollowTheirConversationAcrossASwitch() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let a = 999   // draft")

        await viewModel.loadConversation(id: conversationB)
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty, "Switch clears the live viewer")

        await viewModel.loadConversation(id: conversationA)
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "Tabs come back")
        XCTAssertEqual(viewModel.codeViewerTabs[0].effectiveCode, "let a = 999   // draft",
                       "…including the unsaved draft, the one thing that exists nowhere else")
    }

    /// An emptied viewer must CLEAR its entry. Leaving a stale one behind would resurrect
    /// closed tabs on return — the in-memory shape of the bug this file was written for.
    func testEmptiedViewerDoesNotResurrectOnReturn() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        viewModel.closeCodeViewerTab(id: tabID)
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)

        await viewModel.loadConversation(id: conversationB)
        await viewModel.loadConversation(id: conversationA)

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty, "Closed tabs stay closed")
        XCTAssertFalse(viewModel.isCodeViewerVisible)
    }

    /// Tabs belong to their own conversation and must not leak across a switch.
    func testTabsDoNotLeakBetweenConversations() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")

        await viewModel.loadConversation(id: conversationB)
        viewModel.showCodeInViewer(language: "python", code: "b = 2")
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1, "B sees only its own tab")
        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.language, "python")

        await viewModel.loadConversation(id: conversationA)
        XCTAssertEqual(viewModel.codeViewerTabs.count, 1)
        XCTAssertEqual(viewModel.codeViewerTabs[0].snippet.language, "swift")
    }

    /// QuickAccess mounts no viewer and must neither stash nor restore.
    func testNonOwningViewModelKeepsNoTabs() async {
        let store = DeletionNoopStore()
        let quickAccess = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: false
        )

        await quickAccess.loadConversation(id: conversationA)
        quickAccess.showCodeInViewer(language: "swift", code: "let a = 1")
        await quickAccess.loadConversation(id: conversationB)
        await quickAccess.loadConversation(id: conversationA)

        XCTAssertTrue(quickAccess.codeViewerTabs.isEmpty,
                      "A non-owning view model restores nothing")
    }

    // MARK: - Interrupted conversation switch (2026-07-26 audit, fixed 2026-07-27)
    //
    // Switching A→B and then to C before B's fetch returns ran `resetCodeViewer` twice. The
    // second run saw an EMPTY viewer — emptied by the first, still filed under A because
    // `loadedConversationID` had not moved — read that as "the user closed everything", and
    // deleted A's stash. Tabs and their unsaved drafts were destroyed for a conversation the
    // user never actually left, and drafts exist nowhere else.

    /// A store whose fetch can be parked, so the interruption is deterministic rather than a
    /// timing race.
    @MainActor
    private final class GatedStore: ChatPersistenceProtocol {
        var shouldGate = false
        var gate: CheckedContinuation<Void, Never>?

        func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
            if shouldGate {
                shouldGate = false
                await withCheckedContinuation { gate = $0 }
            }
            return []
        }
        func release() { gate?.resume(); gate = nil }

        func addConversation(from conversation: Conversation) {}
        func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
        func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
        func getConversation(withId id: UUID) -> ConversationSD? { nil }
        func deleteConversation(with id: UUID) {}
        func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
        func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
        func togglePinStatus(for conversationId: UUID) {}
    }

    func testInterruptedSwitchKeepsTheOutgoingConversationsTabs() async {
        let store = GatedStore()
        let vm = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )
        let conversationC = UUID()

        await vm.loadConversation(id: conversationA)
        vm.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let tabID = vm.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        vm.updateCodeViewerDraft(tabID: tabID, content: "let a = 999   // unsaved work")

        // Leave for B, but park its fetch so the switch never completes.
        store.shouldGate = true
        let interrupted = Task { await vm.loadConversation(id: conversationB) }
        var spins = 0
        while store.gate == nil && spins < 1000 { await Task.yield(); spins += 1 }
        XCTAssertNotNil(store.gate, "B's load never parked — the test cannot reproduce the race")
        XCTAssertTrue(vm.codeViewerTabs.isEmpty, "the first switch already cleared the viewer")

        // …and change our mind, switching to C while B is still in flight. This is the second
        // `resetCodeViewer`, the one that used to delete A's stash.
        await vm.loadConversation(id: conversationC)

        store.release()
        _ = await interrupted.value

        await vm.loadConversation(id: conversationA)

        XCTAssertEqual(vm.codeViewerTabs.count, 1, "A's tabs must survive a switch A never completed")
        XCTAssertEqual(vm.codeViewerTabs.first?.effectiveCode, "let a = 999   // unsaved work",
                       "…including the unsaved draft, which exists nowhere else")
    }

    /// The guard the fix must not weaken: an explicit close-all still forgets the tabs, so
    /// they cannot come back on a later return.
    func testCloseAllStillForgetsTheTabs() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        viewModel.forceCloseAllCodeViewerTabs()

        await viewModel.loadConversation(id: conversationB)
        await viewModel.loadConversation(id: conversationA)

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty, "closed means closed")
    }

    /// Closing the LAST tab one-by-one is the other route to an empty viewer.
    func testClosingTheLastTabForgetsTheTabs() async {
        await viewModel.loadConversation(id: conversationA)
        viewModel.showCodeInViewer(language: "swift", code: "let a = 1")
        guard let tabID = viewModel.codeViewerTabs.first?.id else { return XCTFail("No tab") }
        viewModel.forceCloseCodeViewerTab(id: tabID)

        await viewModel.loadConversation(id: conversationB)
        await viewModel.loadConversation(id: conversationA)

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)
    }
}
