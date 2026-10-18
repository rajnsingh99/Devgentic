// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MessageResidencyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
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
        // The corpus must be fetched before it can be indexed past the resident window —
        // without this, `searchCorpus` falls back to the ~300 resident messages and indexing
        // beyond the cap traps.
        await viewModel.prepareSearchCorpus()
        for _ in 0..<80 { await viewModel.loadMoreMessages() }
        XCTAssertTrue(viewModel.hasReachedResidencyCap, "sanity: capped")

        // ⚠️ A REAL corpus id past the cap, not a random UUID. With a random one this test exits
        // at `ensureMessageIsResident`'s corpus-MEMBERSHIP guard and stays green even if the cap
        // guard is deleted — it pinned the wrong branch.
        let offWindow = SearchMatch(messageID: viewModel.searchCorpus[ChatHistoryViewModel.maxResidentMessages + 5].id,
                                    blockID: nil, indexInBlock: 0)
        let resident = SearchMatch(messageID: viewModel.currentChatMessages[0].id, blockID: nil, indexInBlock: 0)

        XCTAssertEqual(viewModel.unreachableMatchCount(in: [offWindow, resident]), 1)

        let fetchesBefore = store.fetchCount
        let reachable = await viewModel.ensureMessageIsResident(offWindow.messageID)
        XCTAssertFalse(reachable, "An unreachable match must report failure, not pretend to navigate")
        XCTAssertEqual(store.fetchCount, fetchesBefore,
                       "and it must cost ZERO store fetches — refusing before the walk is the whole of CF-35")
    }


    /// Reopening a conversation starts fresh — a previous session's cap must not persist.
    func testCapResetsOnConversationLoad() async {
        for _ in 0..<80 { await viewModel.loadMoreMessages() }
        XCTAssertTrue(viewModel.hasReachedResidencyCap)

        await viewModel.loadConversation(id: conversationID)

        XCTAssertFalse(viewModel.hasReachedResidencyCap, "A fresh load starts under the cap")
        XCTAssertLessThanOrEqual(viewModel.currentChatMessages.count, 20)
    }

    // MARK: - CF-36: the cap leaves the window untouched (the view's scroll guard's premise)

    /// `ChatHistoryView.loadPreviousPage` re-anchors the viewport only when a page actually
    /// landed. That guard is only sound if a capped `loadMoreMessages` really leaves the
    /// window untouched — count AND oldest row — which is what this pins.
    func testAtTheCapLoadMoreLeavesTheResidentWindowUnchanged() async {
        for _ in 0..<80 { await viewModel.loadMoreMessages() }
        XCTAssertTrue(viewModel.hasReachedResidencyCap, "sanity: capped")
        let countAtCap = viewModel.currentChatMessages.count
        let oldestAtCap = viewModel.currentChatMessages.last?.id

        await viewModel.loadMoreMessages()

        XCTAssertEqual(viewModel.currentChatMessages.count, countAtCap)
        XCTAssertEqual(viewModel.currentChatMessages.last?.id, oldestAtCap,
                       "nothing appended → the view must not re-anchor the viewport")
        XCTAssertFalse(viewModel.isLoadingPage, "the cap returns before the loading flag is ever set")
    }

    // MARK: - CF-37: unreachableMatchCount stays consistent with isMatchReachable

    /// The defect: `unreachableMatchCount` predates `isMatchReachable` (CF-35) and used a
    /// cruder "not in the currently-resident window" test, which overcounts — a match past
    /// the 20-message initial window but still inside the 300-message residency cap IS
    /// reachable by paging, and the old count called it unreachable anyway. This pins that
    /// the two now agree exactly, match for match.
    func testUnreachableCountAgreesWithIsMatchReachablePerMatch() async {
        await viewModel.prepareSearchCorpus()
        let corpus = viewModel.searchCorpus
        let cap = ChatHistoryViewModel.maxResidentMessages
        XCTAssertGreaterThan(corpus.count, cap + 5, "sanity: the corpus reaches past the cap")

        // A mix of reachable-but-not-yet-resident (well inside the cap) and genuinely
        // unreachable (past the cap) matches — the shape a real search returns.
        let matches = [corpus[0], corpus[cap - 1], corpus[cap], corpus[cap + 1], corpus[cap + 4]]
            .map { SearchMatch(messageID: $0.id, blockID: nil, indexInBlock: 0) }

        let expectedUnreachable = matches.filter { !viewModel.isMatchReachable(messageID: $0.messageID) }.count
        XCTAssertEqual(expectedUnreachable, 3, "sanity: cap and cap+1 and cap+4 are past the cap")
        XCTAssertEqual(viewModel.unreachableMatchCount(in: matches), expectedUnreachable)
    }

    /// Every match resident or reachable by paging: the count must be honestly zero, not a
    /// residual from the OLD "not in the current 20-message window" heuristic.
    func testUnreachableCountIsZeroWhenEveryMatchIsWithinTheCap() async {
        await viewModel.prepareSearchCorpus()
        let corpus = viewModel.searchCorpus
        let cap = ChatHistoryViewModel.maxResidentMessages

        let matches = [corpus[0], corpus[10], corpus[cap - 1]]
            .map { SearchMatch(messageID: $0.id, blockID: nil, indexInBlock: 0) }

        XCTAssertEqual(viewModel.unreachableMatchCount(in: matches), 0,
                       "all three are within the residency cap and must count as reachable")
    }

    /// ⚠️ The count is in MATCHES, not distinct messages, because the badge prints it beside a
    /// match count ("3 of 120 · N older not shown"). Counting messages made the two halves of
    /// that string use different units and under-reported every message holding several hits —
    /// invisible in a fixture where each message carries exactly one match, which is what the
    /// sibling tests above use.
    func testUnreachableCountIsInMatchesNotMessages() async {
        await viewModel.prepareSearchCorpus()
        let corpus = viewModel.searchCorpus
        let cap = ChatHistoryViewModel.maxResidentMessages

        // THREE hits inside ONE unreachable message, plus one reachable message.
        let unreachableMessage = corpus[cap + 1]
        let matches = [
            SearchMatch(messageID: unreachableMessage.id, blockID: nil, indexInBlock: 0),
            SearchMatch(messageID: unreachableMessage.id, blockID: nil, indexInBlock: 1),
            SearchMatch(messageID: unreachableMessage.id, blockID: nil, indexInBlock: 2),
            SearchMatch(messageID: corpus[0].id, blockID: nil, indexInBlock: 0),
        ]

        XCTAssertEqual(viewModel.unreachableMatchCount(in: matches), 3,
                       "three unreachable HITS, not the one message holding them")
    }

    // MARK: - CF-35: reachability is decided from the corpus position, without paging

    /// The corpus is newest-first, so a match's index is the number of resident slots it
    /// needs in front of it. Index `cap - 1` is the last reachable position; `cap` is not.
    func testMatchReachabilityIsDecidedByCorpusPosition() async {
        await viewModel.prepareSearchCorpus()
        let corpus = viewModel.searchCorpus
        let cap = ChatHistoryViewModel.maxResidentMessages
        XCTAssertGreaterThan(corpus.count, cap + 1, "sanity: the corpus reaches past the cap")

        XCTAssertTrue(viewModel.isMatchReachable(messageID: corpus[0].id), "resident")
        XCTAssertEqual(viewModel.searchCorpusIndex(of: corpus[cap].id), cap, "sanity: the index is the corpus position")
        XCTAssertTrue(viewModel.isMatchReachable(messageID: corpus[cap - 1].id), "index < cap")
        XCTAssertFalse(viewModel.isMatchReachable(messageID: corpus[cap].id), "index == cap")
        XCTAssertFalse(viewModel.isMatchReachable(messageID: corpus[cap + 1].id), "index > cap")
        XCTAssertFalse(viewModel.isMatchReachable(messageID: UUID()), "not in the corpus")
    }

    /// ⚠️ THE CF-35 PIN. An unreachable match must be refused BEFORE the first page: the old
    /// loop only learned about the cap by hitting it, so one debounced keystroke walked up to
    /// 28 synchronous main-actor fetches and then scrolled nowhere.
    func testUnreachableMatchIsRefusedWithoutAnyStoreFetch() async {
        await viewModel.prepareSearchCorpus()
        let target = viewModel.searchCorpus[ChatHistoryViewModel.maxResidentMessages + 5]
        let fetchesBefore = store.fetchCount
        let residentBefore = viewModel.currentChatMessages.count

        let reachable = await viewModel.ensureMessageIsResident(target.id)

        XCTAssertFalse(reachable)
        XCTAssertEqual(store.fetchCount, fetchesBefore, "no page may be fetched for a match that can never be resident")
        XCTAssertEqual(viewModel.currentChatMessages.count, residentBefore, "the window must not grow on its behalf")
        XCTAssertFalse(viewModel.hasReachedResidencyCap, "refused by arithmetic, not by walking into the cap")
    }

    /// A message the corpus does not hold (a stale match after a conversation switch or a
    /// corpus release) is not hunted for through the store either.
    func testMatchAbsentFromTheCorpusIsRefusedWithoutPaging() async {
        await viewModel.prepareSearchCorpus()
        let fetchesBefore = store.fetchCount

        let reachable = await viewModel.ensureMessageIsResident(UUID())

        XCTAssertFalse(reachable)
        XCTAssertEqual(store.fetchCount, fetchesBefore)
    }

    // MARK: - CF-38: a cancelled fetch must not publish the corpus

    /// Both ways out of an open search cancel the fetch task — Esc flips the `.task(id:)`
    /// key, an interface-mode switch tears the chat view down — and both RELEASE the corpus
    /// while the fetch is still in flight. Publishing regardless put the whole projection
    /// back behind that release; in the teardown case with no chat view left to free it
    /// again, which is the CH31/AD6 retention shape reached through the disappear ordering.
    ///
    /// Cancelling before the task's first tick is deterministic here: the test holds the
    /// main actor from `Task { }` to `cancel()`, so the fetch cannot have started.
    func testCancelledCorpusFetchIsNotPublished() async {
        let vm = viewModel!
        let residentCount = vm.currentChatMessages.count
        XCTAssertGreaterThan(residentCount, 0, "sanity: the resident fallback is not trivially empty")

        let fetch = Task { await vm.prepareSearchCorpus() }
        fetch.cancel()
        await fetch.value

        XCTAssertEqual(vm.searchCorpus.count, residentCount,
                       "a cancelled fetch must leave the corpus at its resident-window fallback, "
                       + "not publish the store snapshot behind the release that already ran")

        // ...and the refusal must be cancellation-specific, not a blanket one: the very same
        // call on a live task still publishes, or search would silently stop reaching past
        // the scroll window.
        await vm.prepareSearchCorpus()
        XCTAssertGreaterThan(vm.searchCorpus.count, residentCount,
                             "an uncancelled fetch still publishes the store snapshot")
    }

    /// The boundary from the other side: the last reachable position really does page in,
    /// so the arithmetic refuses nothing the loop could have delivered.
    func testLastReachablePositionStillPagesIn() async {
        await viewModel.prepareSearchCorpus()
        let target = viewModel.searchCorpus[ChatHistoryViewModel.maxResidentMessages - 1]
        let fetchesBefore = store.fetchCount

        let reachable = await viewModel.ensureMessageIsResident(target.id)

        XCTAssertTrue(reachable)
        XCTAssertGreaterThan(store.fetchCount, fetchesBefore, "a reachable match is paged in, not refused")
        XCTAssertTrue(viewModel.currentChatMessages.contains { $0.id == target.id })
    }
}
