//
//  MessageResidencyTests.swift
//  DevgenticTests
//
//  `loadMoreMessages` only ever appended — pagination deferred loading but never capped
//  residency, so scrolling back through a long conversation made every message permanently
//  resident along with its decoded timeline and cached markdown.
//
//  These pin the two bounding measures AND the invariant that makes them safe: the cap must
//  never masquerade as "the store is exhausted", because `resolveBackendHistory` treats that
//  as "the loaded window IS the conversation" and hands it to the model as its entire
//  history.
//

import XCTest
@testable import devgentic

/// A long conversation with STABLE rows, served newest-first in offset/limit slices —
/// matching the real store. Stability matters: message identity is what links a search hit
/// to the row that gets paged in and scrolled to.
@MainActor
private final class EndlessChatStore: ChatPersistenceProtocol {
    let conversationID: UUID
    private(set) var fetchCount = 0
    private let backing: [ChatMessage]

    init(conversationID: UUID, messageCount: Int = 1_500) {
        self.conversationID = conversationID
        // Index 0 = newest, matching the store's descending sort.
        self.backing = (0..<messageCount).map { i in
            ChatMessage(
                conversationId: conversationID,
                timestamp: Date(timeIntervalSince1970: TimeInterval(1_000_000 - i)),
                sender: i.isMultiple(of: 2) ? .user : .agent,
                content: .markdownText("Message \(i)\n\n```swift\nlet x = \(i)\n```")
            )
        }
    }

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        fetchCount += 1
        guard offset < backing.count else { return [] }
        return Array(backing[offset ..< min(offset + limit, backing.count)])
    }

    /// Must be implemented, not left to the protocol's `[]` default — the corpus is fetched
    /// through THIS method now, and the default would silently make every corpus test assert
    /// against an empty corpus.
    func fetchSearchDocuments(for conversationId: UUID, limit: Int) async -> [SearchDocument] {
        fetchCount += 1
        return backing.prefix(limit).map(ChatSearchDecomposition.document(for:))
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
final class MessageResidencyTests: XCTestCase {

    private var store: EndlessChatStore!
    private var viewModel: ChatHistoryViewModel!
    private let conversationID = UUID()

    override func setUp() async throws {
        store = EndlessChatStore(conversationID: conversationID)
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store, fileProcessorService: FileProcessorService())
        )
        await viewModel.loadConversation(id: conversationID)
    }

    override func tearDown() async throws {
        viewModel = nil
        store = nil
    }

    /// Scroll back forever: residency must stop at the cap instead of growing without bound.
    func testResidencyIsBounded() async {
        for _ in 0..<80 { await viewModel.loadMoreMessages() }

        XCTAssertLessThanOrEqual(viewModel.currentChatMessages.count,
                                 ChatHistoryViewModel.maxResidentMessages + 10,
                                 "Scroll-back must not grow the resident window without bound")
        XCTAssertTrue(viewModel.hasReachedResidencyCap, "The cap should be flagged once hit")
    }

    /// THE load-bearing invariant. `canLoadMorePages == false` tells the history resolver
    /// "the window IS the conversation" — so a memory cap must never set it.
    func testCapDoesNotClaimTheStoreIsExhausted() async {
        for _ in 0..<80 { await viewModel.loadMoreMessages() }

        XCTAssertTrue(viewModel.hasReachedResidencyCap)
        XCTAssertTrue(viewModel.canLoadMorePages,
                      "The store still HAS older messages. Setting this false would make the "
                      + "history resolver hand the model this window as its whole memory.")
    }

    /// Once capped, further scrolling must stop hitting the store at all.
    func testCappedScrollStopsFetching() async {
        for _ in 0..<80 { await viewModel.loadMoreMessages() }
        let fetchesAtCap = store.fetchCount

        for _ in 0..<20 { await viewModel.loadMoreMessages() }

        XCTAssertEqual(store.fetchCount, fetchesAtCap, "A capped window must not keep paging")
    }

    /// The derived markdown cache is released for messages far from both ends, and rebuilds
    /// transparently — same blocks, no behaviour change.
    func testMarkdownCacheIsTrimmedButRebuildsIdentically() async {
        for _ in 0..<30 { await viewModel.loadMoreMessages() }
        let middle = viewModel.currentChatMessages.count / 2
        let message = viewModel.currentChatMessages[middle]

        guard case .markdownText(let text) = message.content else { return XCTFail("fixture") }
        let expected = parseMarkdown(text)

        // Trimmed by the paging pass above; the accessor rebuilds it on demand.
        let rebuilt = message.getOrCreateMarkdownBlocks(from: text)
        XCTAssertEqual(rebuilt.count, expected.count, "Rebuild must reproduce the same blocks")
        XCTAssertEqual(rebuilt.map(\.id), expected.map(\.id))
    }

    // MARK: - Store-backed search

    /// The point of the corpus: searching must reach past the scroll window. Previously
    /// `performSearch(in: currentChatMessages)` reported "no results" for anything not
    /// loaded, which reads as "not there" rather than "not loaded".
    func testSearchCorpusReachesBeyondTheResidentWindow() async {
        XCTAssertLessThanOrEqual(viewModel.currentChatMessages.count, 20, "sanity: small window")

        await viewModel.prepareSearchCorpus()

        XCTAssertGreaterThan(viewModel.searchCorpus.count, viewModel.currentChatMessages.count,
                             "Search must see more than the scroll window holds")
    }

    /// Live/streaming messages exist only in memory — the corpus must merge them OVER the
    /// store snapshot, never be replaced by it.
    func testSearchCorpusKeepsInMemoryOnlyMessages() async {
        await viewModel.prepareSearchCorpus()

        let live = ChatMessage(conversationId: conversationID,
                               timestamp: Date(timeIntervalSince1970: 2_000_000),
                               sender: .user,
                               content: .plainText("just typed, not persisted yet"))
        viewModel.currentChatMessages.insert(live, at: 0)

        XCTAssertTrue(viewModel.searchCorpus.contains { $0.id == live.id },
                      "A not-yet-persisted message must still be searchable")
    }

    /// Corpus is newest-first, matching `currentChatMessages`, because `performSearch`
    /// reverses its input to emit matches in display order.
    func testSearchCorpusIsNewestFirst() async {
        await viewModel.prepareSearchCorpus()
        let corpus = viewModel.searchCorpus

        XCTAssertGreaterThan(corpus.count, 1)
        for i in 1..<corpus.count {
            XCTAssertGreaterThanOrEqual(corpus[i - 1].timestamp, corpus[i].timestamp,
                                        "Corpus ordering feeds match navigation order")
        }
    }

    /// A match outside the window must be paged in, or the jump scrolls to a view that
    /// isn't rendered and silently does nothing.
    func testEnsureMessageIsResidentPagesInAnOffWindowMatch() async {
        await viewModel.prepareSearchCorpus()

        // Something in the corpus but well outside the initial 20-message window.
        let target = viewModel.searchCorpus[80]
        XCTAssertFalse(viewModel.currentChatMessages.contains { $0.id == target.id },
                       "sanity: not resident yet")

        let reachable = await viewModel.ensureMessageIsResident(target.id)

        XCTAssertTrue(reachable)
        XCTAssertTrue(viewModel.currentChatMessages.contains { $0.id == target.id },
                      "The match must be rendered before we scroll to it")
    }

    /// Already-resident targets short-circuit — no paging, no store hit.
    func testEnsureMessageIsResidentIsANoOpWhenAlreadyLoaded() async {
        let target = viewModel.currentChatMessages[2]
        let fetchesBefore = store.fetchCount

        let reachable = await viewModel.ensureMessageIsResident(target.id)

        XCTAssertTrue(reachable)
        XCTAssertEqual(store.fetchCount, fetchesBefore, "No paging needed for a resident match")
    }

    /// Beyond the residency cap the honest answer is "found but not reachable" — the caller
    /// reports it instead of scrolling nowhere.
    func testUnreachableMatchesAreReportedNotHidden() async {
        for _ in 0..<80 { await viewModel.loadMoreMessages() }
        XCTAssertTrue(viewModel.hasReachedResidencyCap, "sanity: capped")

        let offWindow = SearchMatch(messageID: UUID(), blockID: nil, indexInBlock: 0)
        let resident = SearchMatch(messageID: viewModel.currentChatMessages[0].id, blockID: nil, indexInBlock: 0)

        XCTAssertEqual(viewModel.unreachableMatchCount(in: [offWindow, resident]), 1)

        let reachable = await viewModel.ensureMessageIsResident(offWindow.messageID)
        XCTAssertFalse(reachable, "An unreachable match must report failure, not pretend to navigate")
    }

    /// Reopening a conversation starts fresh — a previous session's cap must not persist.
    func testCapResetsOnConversationLoad() async {
        for _ in 0..<80 { await viewModel.loadMoreMessages() }
        XCTAssertTrue(viewModel.hasReachedResidencyCap)

        await viewModel.loadConversation(id: conversationID)

        XCTAssertFalse(viewModel.hasReachedResidencyCap, "A fresh load starts under the cap")
        XCTAssertLessThanOrEqual(viewModel.currentChatMessages.count, 20)
    }
}
