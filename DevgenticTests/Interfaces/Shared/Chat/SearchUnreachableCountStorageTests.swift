// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SearchUnreachableCountStorageTests.swift
//  DevgenticTests
//
//  Register viewmodel/vm-3 — `ChatSearchBar.body` computed the "N older not shown" count by
//  calling `unreachableMatchCount(in:)`, which enumerates the COMPUTED `searchCorpus` (a
//  1,000-entry dictionary rebuild + sort + a full-text hash of every resident message) — on
//  every keystroke and, because reading each resident message's `displayedContent` made the
//  bar an observer of all of them, on every streaming flush. `ChatSearchDecomposition`'s header
//  says "never call this from inside a SwiftUI body"; the bar did.
//
//  The count is now STORED on `ChatSearchViewModel`, written by `ChatHistoryViewModel.runSearch`
//  from the same corpus snapshot the matches came from. These pin: one corpus build per search
//  run, zero per read of the count, and the bar's source no longer holding the handle it would
//  need to do it the old way.
//

import XCTest
@testable import devgentic

/// A long conversation with stable rows, served newest-first — the shape `MessageResidencyTests`
/// uses, duplicated privately because that stub is file-private there.
@MainActor
private final class CorpusStore: ChatPersistenceProtocol {
    private let backing: [ChatMessage]

    init(conversationID: UUID, messageCount: Int = 1_500) {
        backing = (0..<messageCount).map { i in
            ChatMessage(
                conversationId: conversationID,
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_000_000 - i)),
                sender: i.isMultiple(of: 2) ? .user : .agent,
                content: .markdownText("Message \(i)")
            )
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
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class SearchUnreachableCountStorageTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private var searchViewModel: ChatSearchViewModel!
    private let conversationID = UUID()

    override func setUp() async throws {
        let store = CorpusStore(conversationID: conversationID)
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        )
        await viewModel.loadConversation(id: conversationID)
        // Page to the residency cap and load the store corpus, so matches exist on BOTH sides
        // of the cap — the only state in which the count is non-trivial.
        for _ in 0..<80 { await viewModel.loadMoreMessages() }
        await viewModel.prepareSearchCorpus()
        XCTAssertTrue(viewModel.hasReachedResidencyCap, "sanity: capped")

        searchViewModel = ChatSearchViewModel()
        searchViewModel.activate()
        searchViewModel.searchQuery = "Message"
    }

    override func tearDown() async throws {
        viewModel.releaseSearchCorpus()
        viewModel = nil
        searchViewModel = nil
    }

    // MARK: - The stored value is right

    /// `runSearch` writes the same count the corpus-walking method computes — from a state
    /// where that count is large and non-zero, so a stored 0 cannot pass.
    func testRunSearchStoresTheUnreachableCount() {
        viewModel.runSearch(searchViewModel)

        XCTAssertGreaterThan(searchViewModel.matches.count, ChatHistoryViewModel.maxResidentMessages,
                             "sanity: the query reaches past the resident window")
        let expected = viewModel.unreachableMatchCount(in: searchViewModel.matches)
        XCTAssertGreaterThan(expected, 0, "sanity: some matches lie past the cap")
        XCTAssertEqual(searchViewModel.unreachableMatchCount, expected)
    }

    // MARK: - The cost

    /// ONE corpus build per run: the matches and the count come from the same snapshot.
    func testOneSearchRunBuildsTheCorpusExactlyOnce() {
        let before = viewModel.searchCorpusBuildsForTesting

        viewModel.runSearch(searchViewModel)

        XCTAssertEqual(viewModel.searchCorpusBuildsForTesting - before, 1,
                       "a second build means the count was derived by walking the corpus again")
    }

    /// Building BOTH badge strings — what the bar's body does per keystroke and per flush —
    /// builds NOTHING. The strings live on the search view model so this is the real consumer,
    /// not a stored Int read in isolation (the first cut of this test was that, and could not
    /// fail).
    func testBuildingTheBadgeStringsNeverBuildsTheCorpus() {
        viewModel.runSearch(searchViewModel)
        let before = viewModel.searchCorpusBuildsForTesting

        var sink = 0
        for _ in 0..<200 {
            sink += searchViewModel.matchCountLabel.count + searchViewModel.matchCountAccessibilityLabel.count
        }

        XCTAssertGreaterThan(sink, 0, "sanity")
        XCTAssertEqual(viewModel.searchCorpusBuildsForTesting, before,
                       "the badge strings must come from the stored count, not the corpus")
    }

    /// The badge SHOWS the stored count. A bar that read the value and then rendered 0 would
    /// pass every other test here.
    func testBadgeStringsRenderTheStoredCount() {
        viewModel.runSearch(searchViewModel)
        let count = searchViewModel.unreachableMatchCount
        XCTAssertGreaterThan(count, 0, "sanity")

        XCTAssertTrue(searchViewModel.matchCountLabel.hasSuffix("· \(count) older not shown"),
                      searchViewModel.matchCountLabel)
        XCTAssertTrue(searchViewModel.matchCountAccessibilityLabel.contains("\(count) older matches not loaded"),
                      searchViewModel.matchCountAccessibilityLabel)

        searchViewModel.unreachableMatchCount = 0
        XCTAssertFalse(searchViewModel.matchCountLabel.contains("older"), "no suffix when nothing is unreachable")
    }

    // MARK: - Lifecycle of the stored value

    /// A new match set invalidates the old count until the next `runSearch` writes it.
    func testPerformSearchResetsTheCount() {
        viewModel.runSearch(searchViewModel)
        XCTAssertGreaterThan(searchViewModel.unreachableMatchCount, 0, "sanity")

        searchViewModel.performSearch(in: [])

        XCTAssertEqual(searchViewModel.unreachableMatchCount, 0)
    }

    func testDismissResetsTheCount() {
        viewModel.runSearch(searchViewModel)
        XCTAssertGreaterThan(searchViewModel.unreachableMatchCount, 0, "sanity")

        searchViewModel.dismiss()

        XCTAssertEqual(searchViewModel.unreachableMatchCount, 0)
    }

    // MARK: - The wiring

    /// The bar has no `ChatHistoryViewModel` in its environment any more — the handle it would
    /// need to reach the corpus from `body`. It reads the stored count from the search view
    /// model instead, and the chat view's three re-run sites all go through `runSearch`.
    func testSearchBarReadsTheStoredCountAndHoldsNoHistoryViewModel() throws {
        let chatDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()               // Chat/
            .deletingLastPathComponent()               // Shared/
            .deletingLastPathComponent()               // Interfaces/
            .deletingLastPathComponent()               // DevgenticTests/
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("Devgentic/Interfaces/Shared/Chat")
        // Code lines only — the comments explaining the fix name the old call by design.
        func code(_ file: String) throws -> String {
            try String(contentsOf: chatDir.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let bar = try code("ChatSearchBar.swift")
        let view = try code("ChatHistoryView.swift")

        XCTAssertTrue(bar.contains("searchViewModel.matchCountLabel") && bar.contains("searchViewModel.matchCountAccessibilityLabel"),
                      "the bar must render the view model's strings, which are built from the STORED count")
        XCTAssertFalse(bar.contains("@Environment(ChatHistoryViewModel.self)"),
                       "the bar must not hold the handle that reaches `searchCorpus` from a body")
        XCTAssertFalse(bar.contains("unreachableMatchCount(in:"),
                       "the bar must not compute the count")
        XCTAssertEqual(view.components(separatedBy: "runSearch(searchViewModel)").count - 1, 3,
                       "all three re-run sites (membership, debounced query, bar opened) go through runSearch")
        XCTAssertFalse(view.contains("performSearch(in: chatHistoryViewModel.searchCorpus)"),
                       "a direct performSearch leaves the stored count at 0")
    }
}
