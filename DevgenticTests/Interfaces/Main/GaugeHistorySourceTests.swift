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


    // MARK: - Agreement is not just "same resolver" (2026-09-06)

    /// ⚠️ THE AGREEMENT, restated after the request path began OMITTING in-flight turns.
    ///
    /// Sharing `BackendHistoryResolver` was necessary but not sufficient. Once
    /// `ActiveStreamManager.deriveHistory` started dropping turns that are still being written,
    /// a gauge that still counted them would size a payload that will never ship — the ring would
    /// climb while a concurrent scheduled or ChatOps run streamed, for context the model never
    /// receives. Both consumers must apply the SAME omission, from the same object.
    func testTheGaugeOmitsExactlyWhatTheRequestOmits() {
        let myQuestion = UUID(), myReply = UUID()
        let theirQuestion = UUID(), theirReply = UUID()
        let liveRuns = [myReply: myQuestion, theirReply: theirQuestion]

        // The request keeps the question it is asking; the gauge has no question yet.
        let requestOmits = ActiveStreamManager.incompleteTurnIDs(liveRuns: liveRuns, keeping: myQuestion)
        let gaugeOmits = ActiveStreamManager.incompleteTurnIDs(liveRuns: liveRuns, keeping: nil)

        XCTAssertEqual(gaugeOmits, requestOmits.union([myQuestion]),
                       "they differ by exactly one message — the one the request is about to send, "
                       + "which does not exist yet when the gauge runs")
        XCTAssertTrue(requestOmits.isSubset(of: gaugeOmits),
                      "the gauge never counts something the request would omit")
        for id in [myReply, theirReply, theirQuestion] {
            XCTAssertTrue(gaugeOmits.contains(id), "every unfinished-turn row is omitted by both")
        }
    }

    /// With nothing in flight — the ordinary case — the two are identical and the omission costs
    /// nothing. If this ever fails, the gauge has started subtracting something on its own.
    func testWithNothingInFlightTheGaugeAndRequestOmitNothing() {
        XCTAssertTrue(ActiveStreamManager.incompleteTurnIDs(liveRuns: [:], keeping: nil).isEmpty)
        XCTAssertTrue(ActiveStreamManager.incompleteTurnIDs(liveRuns: [:], keeping: UUID()).isEmpty)
    }

    /// ⚠️ WIRING. The two properties above are worth nothing if either consumer stops asking.
    /// Source-scanned in the `ToolRegistryDriftTests` idiom, because this is precisely the kind of
    /// agreement that decays silently — the gauge drifted from the request once already, which is
    /// why this file exists.
    func testBothConsumersAskTheSameObjectForTheOmission() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Devgentic").path) else {
            throw XCTSkip("sources not reachable — running outside a checkout")
        }
        func code(_ path: String) throws -> [String] {
            try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        }

        let request = try code("Devgentic/Core/Utils/ActiveStreamManager.swift")
        XCTAssertTrue(request.contains { $0.contains("omitting: self.incompleteTurnIDs(keeping: userMessage.id)") },
                      "the REQUEST path must omit in-flight turns, keeping its own question")

        // ⚠️ THE GAUGE ASKS THE SAME OBJECT, FOR A DIFFERENT SET — and that is deliberate.
        // It used to call `incompleteTurnIDs()` (turn-level, `keeping: nil`), which subtracted
        // the just-sent QUESTION as well as the live reply. The ring therefore FELL at the moment
        // of send — the question was removed from the size of a request that had just included
        // it — and jumped back when streaming ended. The question is a settled, persisted row the
        // next request certainly carries; only the half-written REPLY should be omitted.
        let gauge = try code("Devgentic/Interfaces/Shared/Chat/ChatHistoryViewModel.swift")
        XCTAssertTrue(gauge.contains { $0.contains("activeStreamManager.liveReplyIDs()") },
                      "the GAUGE must omit the live REPLY — sharing the resolver is not enough "
                      + "once the request omits rows the resolver returns")
        XCTAssertFalse(gauge.contains { $0.contains("activeStreamManager.incompleteTurnIDs()") },
                       "…and must NOT use the request path's turn-level set: that subtracts the "
                       + "just-sent question and makes the ring drop on send")

        // Both sets still come off the SAME live-run state, which is the property that keeps the
        // two consumers from drifting apart the way they did before either omitted anything.
        XCTAssertTrue(request.contains { $0.contains("Set(liveRunQuestionIDs.keys)") },
                      "liveReplyIDs must be derived from the same liveRunQuestionIDs the request "
                      + "path uses — a second, separately-maintained source is the divergence")
    }
}
