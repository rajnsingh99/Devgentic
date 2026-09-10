// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  StreamingTabIdentityTests.swift
//  DevgenticTests
//
//  Regression cover for the field-observed duplicate-tab defect (2026-07-25).
//
//  A user opened a message's code blocks WHILE the response was still streaming, then
//  clicked the same message again after it completed. Tab identity was content equality
//  (`denotesSameBlock` = language + code), so the block that had grown in the meantime
//  matched nothing and appended a SECOND tab holding the truncated mid-stream fragment —
//  two tabs with the same title, one of them silently wrong.
//
//  Identity is now (originMessageID, originBlockIndex), which is stable from the first
//  token onward.
//

import XCTest
@testable import devgentic

@MainActor
private final class TabIdentityNoopStore: ChatPersistenceProtocol {
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

@MainActor
final class StreamingTabIdentityTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()

    override func setUp() async throws {
        let store = TabIdentityNoopStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            // Stash/restore across a switch is owner-only, like the live-agent tabs.
            ownsCodeViewer: true
        )
    }

    override func tearDown() async throws { viewModel = nil }

    // MARK: - Fixtures

    private func lines(_ label: String, _ count: Int) -> String {
        (1...count).map { "System.out.println(\"\(label) \($0)\");" }.joined(separator: "\n")
    }

    /// Two java blocks; the SECOND is the one that keeps growing, mirroring the field case
    /// where `InventoryManagerSystem.java` was the last block still streaming.
    ///
    /// Both are over `ChatUIConstants.codeBlockLineLimit` (50) from the start, so this
    /// isolates "the block grew" from "the block became large" — the latter has its own test.
    private func markdown(secondBlockLines: Int) -> String {
        """
        **File:** `GraphTraversal.java`

        ```java
        \(lines("GRAPH", 60))
        ```

        **File:** `InventoryManagerSystem.java`

        ```java
        \(lines("INVENTORY", secondBlockLines))
        ```
        """
    }

    private func message(_ markdown: String, id: UUID) -> ChatMessage {
        ChatMessage(id: id, conversationId: conversationID, sender: .agent, content: .markdownText(markdown))
    }

    // MARK: - Tests

    /// THE FIELD CASE: open mid-stream, then re-open once complete.
    func testReopeningAGrownStreamingMessageRefreshesInPlaceInsteadOfDuplicating() {
        let messageID = UUID()

        viewModel.openMessageInCodeViewer(message: message(markdown(secondBlockLines: 60), id: messageID))
        XCTAssertEqual(viewModel.codeViewerTabs.count, 2, "Two large blocks → two tabs")
        let idsAfterFirstOpen = viewModel.codeViewerTabs.map(\.id)

        // The stream continued: the second block is now much longer.
        viewModel.openMessageInCodeViewer(message: message(markdown(secondBlockLines: 200), id: messageID))

        XCTAssertEqual(viewModel.codeViewerTabs.count, 2, "Re-opening must refresh, not append a duplicate")
        XCTAssertEqual(viewModel.codeViewerTabs.map(\.id), idsAfterFirstOpen, "Tab identity must be preserved")
        XCTAssertTrue(
            viewModel.codeViewerTabs[1].snippet.code.contains("INVENTORY 200"),
            "The refreshed tab must hold the COMPLETE block, not the truncated fragment"
        )
    }

    /// A user's unsaved edit outranks the refresh — losing typed work to a late stream
    /// chunk would be strictly worse than a stale tab.
    func testGrownBlockDoesNotClobberAnUnsavedDraft() {
        let messageID = UUID()
        viewModel.openMessageInCodeViewer(message: message(markdown(secondBlockLines: 60), id: messageID))
        let tabID = viewModel.codeViewerTabs[1].id
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "my hand-typed edit")

        viewModel.openMessageInCodeViewer(message: message(markdown(secondBlockLines: 200), id: messageID))

        XCTAssertEqual(viewModel.codeViewerTabs.count, 2)
        XCTAssertEqual(viewModel.codeViewerTabs[1].editedCode, "my hand-typed edit", "Draft must survive")
    }

    /// Identity is per-message: the same code from two different messages stays distinct
    /// under the origin rule, and neither gets refreshed by the other.
    func testBlocksFromDifferentMessagesGetTheirOwnTabs() {
        let text = markdown(secondBlockLines: 60)
        viewModel.openMessageInCodeViewer(message: message(text, id: UUID()))
        let firstCount = viewModel.codeViewerTabs.count

        viewModel.openMessageInCodeViewer(message: message(text, id: UUID()))

        XCTAssertEqual(
            viewModel.codeViewerTabs.count, firstCount,
            "Identical content from another message still merges via the content fallback"
        )
    }

    /// The index must be taken over the UNFILTERED block list: a block that is small while
    /// streaming and large when complete changes the filtered ordering underneath us.
    func testIndexSurvivesABlockCrossingTheLargeThreshold() {
        let messageID = UUID()
        // First block small (filtered out of the large set), second large.
        let early = """
        ```java
        \(lines("SMALL", 3))
        ```

        ```java
        \(lines("BIG", 80))
        ```
        """
        // The first block has now grown past the threshold too.
        let late = """
        ```java
        \(lines("SMALL", 90))
        ```

        ```java
        \(lines("BIG", 80))
        ```
        """
        viewModel.openMessageInCodeViewer(message: message(early, id: messageID))
        let bigTabID = viewModel.codeViewerTabs.first(where: { $0.snippet.code.contains("BIG") })?.id

        viewModel.openMessageInCodeViewer(message: message(late, id: messageID))

        let bigTabs = viewModel.codeViewerTabs.filter { $0.snippet.code.contains("BIG") }
        XCTAssertEqual(bigTabs.count, 1, "The unchanged large block must not duplicate when a sibling grows")
        XCTAssertEqual(bigTabs.first?.id, bigTabID, "and it must keep its identity")
    }

    /// Origin identity must survive a conversation switch, or the first re-open after
    /// coming back duplicates every stashed tab. (In-memory now — nothing is persisted.)
    func testOriginIdentitySurvivesAConversationSwitch() async {
        let messageID = UUID()
        await viewModel.loadConversation(id: conversationID)
        viewModel.openMessageInCodeViewer(message: message(markdown(secondBlockLines: 60), id: messageID))
        let idsBefore = viewModel.codeViewerTabs.map(\.id)
        XCTAssertEqual(idsBefore.count, 2)

        await viewModel.loadConversation(id: UUID())
        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty, "Switch clears the live viewer")
        await viewModel.loadConversation(id: conversationID)

        XCTAssertEqual(viewModel.codeViewerTabs.map(\.id), idsBefore,
                       "Stashed tabs come back with their identity intact")

        // Re-opening the same message must still dedup against the restored tabs.
        viewModel.openMessageInCodeViewer(message: message(markdown(secondBlockLines: 60), id: messageID))
        XCTAssertEqual(viewModel.codeViewerTabs.count, 2, "No duplicates after a round trip")
    }
}
