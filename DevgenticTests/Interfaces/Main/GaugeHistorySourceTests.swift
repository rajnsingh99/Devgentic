//
//  GaugeHistorySourceTests.swift
//  DevgenticTests
//
//  The context gauge sized the REQUEST from `currentChatMessages` — the UI's pagination
//  window (20 on open, +10 per scroll-back, cap 300). The request has always been
//  store-authoritative. `resolveBackendHistory` had already written the rule down:
//
//      "What the model sees is a context concern; what the list renders is a rendering
//       concern, and the two must not be the same value."
//
//  Consequences the gauge shipped with: the ring climbed as the user scrolled while the
//  prompt was unchanged, and a freshly-opened long conversation under-read its own history
//  by up to 15×.
//
//  Both paths now go through `BackendHistoryResolver`. These tests pin that they cannot
//  drift apart again.
//

import XCTest
@testable import devgentic


/// Store double returning the newest `limit` messages, matching `ChatPersistenceStore`'s
/// descending sort. Only `fetchMessages` matters here; the rest is inert conformance.
@MainActor
private final class GaugeStubStore: ChatPersistenceProtocol {
    var all: [ChatMessage] = []
    private(set) var fetchCount = 0

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        fetchCount += 1
        let scoped = all.filter { $0.conversationId == conversationId }
            .sorted { $0.timestamp > $1.timestamp }
        return Array(scoped.dropFirst(offset).prefix(limit))
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
final class GaugeHistorySourceTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 7_000_000)

    // MARK: - Fixtures

    private func message(_ index: Int, sender: SenderRole, text: String) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: convID,
                    timestamp: t0.addingTimeInterval(TimeInterval(index)),
                    sender: sender, content: .plainText(text))
    }

    /// `count` alternating turns, oldest first.
    private func conversation(_ count: Int, replyChars: Int = 40) -> [ChatMessage] {
        (0..<count).map { i in
            i % 2 == 0
                ? message(i, sender: .user, text: "q\(i)")
                : message(i, sender: .agent, text: String(repeating: "a", count: replyChars))
        }
    }

    // MARK: - The bug

    /// The render window is a fraction of the conversation. Sizing from it under-reads the
    /// request — this is the 15× case, expressed as a property rather than a magic number.
    func testResolvedHistoryIsNotTheRenderWindow() async {
        let store = GaugeStubStore()
        store.all = conversation(200)
        let renderWindow = Array(store.all.suffix(20).reversed())   // 20 newest, DESCENDING

        let resolved = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: renderWindow, persistence: store
        )

        XCTAssertEqual(renderWindow.count, 20, "precondition: the window is one page")
        XCTAssertEqual(resolved.history.count, 200,
                       "the request sees the whole conversation, not the page")
        XCTAssertGreaterThan(resolved.history.count, renderWindow.count * 5)
    }

    /// The property that made the ring move for no reason: scrolling grows the window, and
    /// the resolution must be indifferent to it.
    func testResolutionIsIndependentOfHowFarTheUserScrolled() async {
        let store = GaugeStubStore()
        store.all = conversation(120)

        var sizes: [Int] = []
        for residentCount in [20, 50, 120] {            // just opened → scrolled → fully scrolled
            let window = Array(store.all.suffix(residentCount).reversed())
            let resolved = await BackendHistoryResolver.resolve(
                conversationID: convID, inMemory: window, persistence: store
            )
            sizes.append(resolved.history.count)
        }

        XCTAssertEqual(Set(sizes).count, 1,
                       "scroll position must not change the resolved history: \(sizes)")
    }

    // MARK: - Ordering — the contract the gauge now depends on

    /// The gauge reads `lastTurn` with `.last(where:)` and feeds `pairTurns` directly, both
    /// of which require oldest-first. The render window is the opposite order.
    func testResolvedHistoryIsOldestFirst() async {
        let store = GaugeStubStore()
        store.all = conversation(10)
        let resolved = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: [], persistence: store
        )

        let stamps = resolved.history.map(\.timestamp)
        XCTAssertEqual(stamps, stamps.sorted(), "ascending is the contract")
    }

    // MARK: - The merge guarantees the request depends on

    /// In-memory-only messages must survive: the just-sent user message is persisted in a
    /// detached task that races the read, so a store-authoritative merge would intermittently
    /// drop the user's own question from the request answering it.
    func testInMemoryOnlyMessagesSurviveTheMerge() async {
        let store = GaugeStubStore()
        store.all = conversation(4)
        let justSent = message(99, sender: .user, text: "the question being asked right now")

        let resolved = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: [justSent], persistence: store
        )

        XCTAssertTrue(resolved.history.contains { $0.id == justSent.id },
                      "an unpersisted in-flight message must not be dropped")
        XCTAssertEqual(resolved.history.count, 5)
    }

    /// Other conversations' messages must not leak in through the in-memory side.
    func testForeignConversationMessagesAreExcluded() async {
        let store = GaugeStubStore()
        store.all = conversation(3)
        let foreign = ChatMessage(id: UUID(), conversationId: UUID(), timestamp: t0,
                                  sender: .user, content: .plainText("other chat"))

        let resolved = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: [foreign], persistence: store
        )
        XCTAssertFalse(resolved.history.contains { $0.id == foreign.id })
        XCTAssertEqual(resolved.history.count, 3)
    }

    /// The cap must be reported, because hitting it means older turns silently left direct
    /// context and now depend on retrieval.
    func testCapHitIsReported() async {
        let store = GaugeStubStore()
        store.all = conversation(BackendHistoryResolver.messageLimit + 25)

        let resolved = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: [], persistence: store
        )
        XCTAssertTrue(resolved.capHit)
        XCTAssertEqual(resolved.history.count, BackendHistoryResolver.messageLimit)

        let under = GaugeStubStore()
        under.all = conversation(10)
        let small = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: [], persistence: under
        )
        XCTAssertFalse(small.capHit)
    }

}
