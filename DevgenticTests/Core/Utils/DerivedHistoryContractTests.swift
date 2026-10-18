// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DerivedHistoryContractTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic


@MainActor
private final class ContractStubStore: ChatPersistenceProtocol {
    var all: [ChatMessage] = []

    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {
        all.removeAll { $0.id == message.id }
        all.append(message)
    }

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        let scoped = all.filter { $0.conversationId == conversationId }
            .sorted { $0.timestamp > $1.timestamp }         // matches the real store's .reverse sort
        return Array(scoped.dropFirst(offset).prefix(limit))
    }

    func addConversation(from conversation: Conversation) {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}


@MainActor
final class DerivedHistoryContractTests: XCTestCase {

    private let convID = UUID()
    private let otherConvID = UUID()
    private let t0 = Date(timeIntervalSince1970: 5_000_000)
    private var store: ContractStubStore!

    override func setUp() async throws { store = ContractStubStore() }
    override func tearDown() async throws { store = nil }

    private func message(_ offset: Int, sender: SenderRole, text: String? = nil,
                         conversation: UUID? = nil, streaming: Bool = false) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: conversation ?? convID,
                    timestamp: t0.addingTimeInterval(TimeInterval(offset)),
                    sender: sender, content: .plainText(text ?? "m\(offset)"),
                    isStreaming: streaming)
    }

    private func settled(_ count: Int) -> [ChatMessage] {
        (0..<count).map { message($0, sender: $0 % 2 == 0 ? .user : .agent) }
    }

    private func derive(_ userMessage: ChatMessage,
                        omitting: Set<UUID> = [],
                        before: ChatMessage? = nil) async -> [ChatMessage] {
        await ActiveStreamManager.deriveHistory(
            userMessage: userMessage, omitting: omitting,
            before: before, persistence: store)
    }

    // MARK: - Invariant #8, now by construction

    /// The store sorts DESCENDING. Every derived history must come back oldest-first regardless,
    /// because the resolver sorts — this is what makes the scheduler's old bug unrepresentable.
    func testDerivedHistoryIsAlwaysAscending() async {
        store.all = settled(40)
        let userMessage = message(40, sender: .user)
        store.all.append(userMessage)

        let history = await derive(userMessage)

        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: history))
        XCTAssertEqual(history.last?.id, userMessage.id,
                       "the current question lands last, where the duplicate strip looks")
    }

    /// The window is the resolver's, not any surface's. QuickAccess's hard 20 is gone.
    func testWindowIsTheResolverLimitForEverySurface() async {
        store.all = settled(120)
        let history = await derive(message(120, sender: .user))
        XCTAssertEqual(history.count, 121, "far past QuickAccess's old 20-row ceiling")
    }

    /// The message being sent is included even when its persist has not landed — the property
    /// that lets a surface fire-and-forget its write without dropping its own question.
    func testTheUnpersistedCurrentMessageIsStillIncluded() async {
        store.all = settled(6)
        let userMessage = message(6, sender: .user, text: "not yet written")

        let history = await derive(userMessage)

        XCTAssertFalse(store.all.contains { $0.id == userMessage.id }, "precondition: not persisted")
        XCTAssertEqual(history.last?.id, userMessage.id)
    }

    /// ⚠️ INVERTED 2026-09-06, and the reason the old assertion gave was itself false.
    /// It asserted an in-flight assistant row must be INCLUDED, "because in-flight streams are
    /// never in the store". They are: `ActiveStreamManager.flushInFlight` upserts the row at every
    /// tool boundary and on the first content flush, so the store returns it within ~100 ms.
    /// An unfinished turn must be excluded, and excluded AFTER the resolve — filtering only the
    /// in-memory side would have swapped the live copy for a staler disk copy, not removed it.
    func testAnInFlightTurnIsExcludedEvenWhenTheStoreAlreadyHasIt() async {
        let question = message(6, sender: .user, text: "other run's question")
        let streaming = message(7, sender: .agent, text: "", streaming: true)
        store.all = settled(6) + [question, streaming]   // flushInFlight has already landed it
        let userMessage = message(8, sender: .user, text: "my question")

        let omit = ActiveStreamManager.incompleteTurnIDs(
            liveRuns: [streaming.id: question.id], keeping: userMessage.id)
        let history = await derive(userMessage, omitting: omit)

        XCTAssertFalse(history.contains { $0.id == streaming.id },
                       "the unfinished reply is gone even though the STORE returned it")
        XCTAssertFalse(history.contains { $0.id == question.id },
                       "and so is the question it is answering — otherwise that question becomes "
                       + "a trailing orphan reported as \"Agent never responded to this query\", "
                       + "which is a LOUDER falsehood than the one being fixed")
        XCTAssertEqual(history.last?.id, userMessage.id, "my own question is untouched")
    }

    /// The store is shared across conversations, so scoping is load-bearing: a run must never see
    /// another conversation's rows. `BackendHistoryResolver.resolve` filters by conversation and
    /// the derivation inherits that; this pins it, since `liveRunQuestionIDs` is app-wide and a
    /// concurrent run in a DIFFERENT conversation contributes ids that simply must not match.
    func testForeignConversationRowsAreExcluded() async {
        store.all = settled(4) + [message(5, sender: .user, conversation: otherConvID),
                                  message(6, sender: .agent, conversation: otherConvID)]
        let userMessage = message(7, sender: .user)

        let history = await derive(userMessage)

        XCTAssertTrue(history.allSatisfy { $0.conversationId == self.convID })
        XCTAssertEqual(history.count, 5, "four settled turns plus my question — nothing foreign")
    }

    // MARK: - The `before:` cut (regenerate / resume)

    /// With `updating:` set, the run replays only what preceded the message being rewritten.
    func testBeforeCutStopsAtTheMessageBeingRegenerated() async {
        let turns = settled(10)
        store.all = turns
        let boundary = turns[7]                       // an agent reply mid-conversation

        let history = await derive(turns[6], before: boundary)

        XCTAssertEqual(history.map(\.id), Array(turns[0..<7]).map(\.id))
        XCTAssertFalse(history.contains { $0.id == boundary.id }, "strictly before")
    }

    /// The question being re-asked must survive the cut — it precedes the reply being replaced.
    func testBeforeCutKeepsTheQuestionBeingReAsked() async {
        let turns = settled(10)
        store.all = turns
        let question = turns[6]                       // user
        let reply = turns[7]                          // its agent answer

        let history = await derive(question, before: reply)

        XCTAssertEqual(history.last?.id, question.id)
    }

    /// A boundary outside the resolved window falls back to a timestamp cut rather than replaying
    /// the whole conversation past it — `MessagingCoordinator.historySlice`'s documented fallback,
    /// reused here so both paths keep one definition of "before".
    func testBeforeCutFallsBackToTimestampWhenTheTargetIsNotResident() async {
        store.all = settled(10)
        let absent = message(5, sender: .agent, text: "never stored")

        let history = await derive(message(0, sender: .user), before: absent)

        XCTAssertTrue(history.allSatisfy { $0.timestamp < absent.timestamp })
        XCTAssertFalse(history.isEmpty, "a timestamp cut, not an empty result")
    }

    /// No boundary means the whole window — the ordinary send.
    func testNoBoundaryMeansTheFullWindow() async {
        store.all = settled(12)
        let history = await derive(message(12, sender: .user))
        XCTAssertEqual(history.count, 13)
    }

    // MARK: - The surfaces that used to build it wrong

    /// Orb's private transcript was never hydrated, so a turn typed into the same conversation
    /// from the chat window was invisible to the next voice turn. Deriving is store-backed, so it
    /// is not: this is §2c closed by construction.
    func testATypedTurnIsVisibleToTheNextVoiceTurn() async {
        let typedQuestion = message(0, sender: .user, text: "typed in the chat window")
        let typedAnswer = message(1, sender: .agent, text: "answered there")
        store.all = [typedQuestion, typedAnswer]
        let spokenCommand = message(2, sender: .user, text: "follow up by voice")

        let history = await derive(spokenCommand)

        XCTAssertEqual(history.map(\.id), [typedQuestion.id, typedAnswer.id, spokenCommand.id],
                       "a voice turn sees the typed turns in its own conversation")
    }

    /// QuickAccess's window was a hard 20 that reset on every summon. Deriving means the panel
    /// and the main window are handed the same conversation.
    func testThePanelAndTheMainWindowGetTheSameHistory() async {
        store.all = settled(200)
        let userMessage = message(200, sender: .user)

        let fromPanel = await derive(userMessage)
        let fromMainWindow = await derive(userMessage)

        XCTAssertEqual(fromPanel.map(\.id), fromMainWindow.map(\.id))
        XCTAssertEqual(fromPanel.count, 201, "not 20")
    }

    // MARK: - A run's own reply is not part of its own context

    /// ⚠️ THE REGRESSION THIS SUITE MISSED FIRST TIME. A run's own placeholder is registered into
    /// `activeStreams` before the task that derives history runs, so it was landing in the history
    /// that produces it and `pairTurns` reported the current question as answered with nothing.
    func testTheRunsOwnTurnIsExcludedButItsQuestionIsKept() {
        let myQuestion = UUID(), myReply = UUID()
        let ids = ActiveStreamManager.incompleteTurnIDs(
            liveRuns: [myReply: myQuestion], keeping: myQuestion)

        XCTAssertTrue(ids.contains(myReply), "the run's own empty reply must never reach its own context")
        XCTAssertFalse(ids.contains(myQuestion), "but the question it is asking obviously stays")
    }

    /// A CONCURRENT run — reachable because the scheduler, Orb and the ChatOps bridge carry no
    /// admission check — contributes a whole unfinished turn that must be dropped.
    func testAConcurrentRunsWholeTurnIsExcluded() {
        let myQuestion = UUID(), myReply = UUID()
        let theirQuestion = UUID(), theirReply = UUID()

        let ids = ActiveStreamManager.incompleteTurnIDs(
            liveRuns: [myReply: myQuestion, theirReply: theirQuestion], keeping: myQuestion)

        XCTAssertEqual(ids, [myReply, theirReply, theirQuestion],
                       "both halves of the other run's turn, plus my own reply — never my question")
    }

    /// No live runs, nothing omitted — the ordinary case costs nothing.
    func testWithNoLiveRunsNothingIsOmitted() {
        XCTAssertTrue(ActiveStreamManager.incompleteTurnIDs(liveRuns: [:], keeping: UUID()).isEmpty)
    }

    /// ⚠️ WIRING, not policy. The helper above is only worth anything if `startMessageStream`
    /// actually calls it. The first version of this change inlined the wrong expression, and no
    /// unit test could have seen that — so this reads the production source, in the
    /// `ToolRegistryDriftTests` idiom.
    func testStartMessageStreamUsesTheExclusionRatherThanRawActiveStreams() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot.appendingPathComponent("Devgentic/Core/Utils/ActiveStreamManager.swift")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("source not reachable — running outside a checkout")
        }
        let text = try String(contentsOf: source, encoding: .utf8)
        let code = text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }

        XCTAssertTrue(code.contains { $0.contains("omitting: self.incompleteTurnIDs(keeping: userMessage.id)") },
                      "startMessageStream must exclude in-flight turns via the SHARED instance "
                      + "method — the same one the context gauge asks "
                      + "(ChatHistoryViewModel.resolveContextHistory). Two consumers, one omission; "
                      + "see GaugeHistorySourceTests.testBothConsumersAskTheSameObjectForTheOmission.")
        XCTAssertTrue(code.contains { $0.contains("liveRunQuestionIDs[agentMessage.id] = userMessage.id") },
                      "and it must RECORD the question link, or incompleteTurnIDs has nothing to work "
                      + "from and silently omits nothing")
        XCTAssertFalse(code.contains { $0.contains("inMemory: [userMessage] + ") },
                       "in-flight rows must not be re-added on the in-memory side — the store already "
                       + "returns them via flushInFlight, and merge lets in-memory win")
    }
}
