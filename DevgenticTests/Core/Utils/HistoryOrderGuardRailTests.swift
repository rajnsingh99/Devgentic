// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HistoryOrderGuardRailTests.swift
//  DevgenticTests
//
//  Invariant #8 (`architecture_readme.md` §7) — "Ascending history only, from
//  `BackendHistoryResolver`" — had NO executable check of any kind, and it is the one invariant
//  in that register that was violated in shipped code.
//
//  That is not a coincidence, and the register itself shows why: #14 (`NativeToolCatalog` is the
//  only place a native tool is declared) has `ToolRegistryDriftTests`, #15 (`ToolCapability`
//  describes, never enforces) has `ToolCapabilityTests` checking in both directions. Both hold.
//  #8 had only prose — plus `EpisodicFitGaugeAlignmentTests`, which proves the FORMATTER
//  misreports on a descending array but could not fail when a caller handed one over. A policy
//  test with no wiring behind it. (Callers can no longer hand one over at all; what remains
//  worth detecting is the resolver itself returning an unordered merge.)
//
//  `ActiveStreamManager.startMessageStream` is the one chokepoint all seven run-start sites pass
//  through. ⚠️ It does NOT receive `history` — an earlier version of this header said it did, and
//  that was already false when the file was written: the same change set deleted `history`,
//  `conversationID` and `userQuery` from the signature. History is DERIVED inside, so the
//  guard-rail there is a SELF-check, not a caller check — production says so at its own site
//  ("Callers no longer supply history… this is a regression in BackendHistoryResolver.merge, not
//  a caller bug"). These tests pin the predicate behind it, which is what makes the check
//  meaningful either way.
//
//  ⚠️ The guard-rail LOGS, it does not repair. Invariant #8: "Never re-add a `.reversed()` at a
//  call site; if history arrives descending, the resolver is the bug." Sorting at the chokepoint
//  would hide a caller that is also reading the wrong SOURCE — a pagination window, a private
//  transcript — which no sort can fix. So these tests assert on DETECTION only; there is
//  deliberately no "and then it fixed it" case to write.
//

import XCTest
@testable import devgentic


final class HistoryOrderGuardRailTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 9_000_000)

    private func message(at offset: Int, sender: SenderRole = .user) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: convID,
                    timestamp: t0.addingTimeInterval(TimeInterval(offset)),
                    sender: sender, content: .plainText("m\(offset)"))
    }

    /// Alternating turns, oldest first — what `BackendHistoryResolver.resolve` returns.
    private func ascendingConversation(_ count: Int) -> [ChatMessage] {
        (0..<count).map { message(at: $0, sender: $0 % 2 == 0 ? .user : .agent) }
    }

    // MARK: - Clean input must not trip it

    func testAscendingHistoryDoesNotTrip() {
        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: ascendingConversation(40)))
    }

    func testEmptyAndSingleMessageHistoriesDoNotTrip() {
        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: []))
        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: [message(at: 0)]))
    }

    /// A tie is unordered, not descending. `BackendHistoryResolver.merge` sorts by timestamp over
    /// a dictionary's values, so it can legitimately emit equal-stamped rows in either order —
    /// tripping on that would make the guard-rail cry wolf on correct input.
    func testEqualTimestampsDoNotTrip() {
        let a = message(at: 5, sender: .user)
        let b = message(at: 5, sender: .agent)
        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: [a, b]))
        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: [b, a]))
    }

    // MARK: - The shapes that must trip it

    func testFullyDescendingHistoryTrips() {
        let descending = Array(ascendingConversation(40).reversed())
        XCTAssertEqual(ActiveStreamManager.firstDescendingPair(in: descending), 1,
                       "a reversed array inverts at the very first pair")
    }

    /// A single row out of place still corrupts pairing from that point on, so partial disorder
    /// must trip too — the realistic shape if a caller splices a row at the wrong index.
    func testASingleOutOfPlaceMessageTrips() {
        var history = ascendingConversation(10)
        history.insert(message(at: 2), at: 8)          // an old row spliced near the end
        XCTAssertEqual(ActiveStreamManager.firstDescendingPair(in: history), 8)
    }

    func testDisorderAtTheVeryEndIsStillCaught() {
        var history = ascendingConversation(10)
        history.append(message(at: -1))                // older than everything, appended newest
        XCTAssertEqual(ActiveStreamManager.firstDescendingPair(in: history), 10,
                       "the scan must reach the last pair, not stop early")
    }

    // MARK: - The regression this exists for

    /// ⚠️ THE POINT OF THE GUARD-RAIL, expressed as the exact production shape it missed.
    ///
    /// `ChatPersistenceStore.fetchMessages` sorts `SortDescriptor(\.timestamp, order: .reverse)`,
    /// and `SchedulerCoordinator` used to hand that result straight to `startMessageStream`. This
    /// models that array. If this ever stops tripping, the guard-rail has stopped protecting the
    /// one invariant it was written for.
    func testRawFetchMessagesOutputTripsTheGuardRail() {
        let storeOrder = ascendingConversation(50).sorted { $0.timestamp > $1.timestamp }
        XCTAssertNotNil(ActiveStreamManager.firstDescendingPair(in: storeOrder),
                        "descending store output must be detected at the chokepoint")
    }

    /// And the fix's output must be clean — `BackendHistoryResolver` is what the guard-rail's
    /// FIX line tells the caller to use, so the two must agree.
    ///
    /// The only test here that needs the main actor: `ChatPersistenceProtocol` is `@MainActor`.
    /// The class deliberately is NOT, which is itself the point — `firstDescendingPair` is
    /// `nonisolated`, so the rule is checkable with no actor, no store and no view model.
    @MainActor
    func testResolverOutputPassesTheGuardRail() async {
        let store = OrderGuardStubStore()
        store.all = ascendingConversation(50)
        let resolved = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: [], persistence: store
        )
        XCTAssertEqual(resolved.history.count, 50, "precondition: the fixture actually resolved")
        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: resolved.history),
                     "the remedy the guard-rail names must satisfy the guard-rail")
    }

    /// Models the resolver-level sequence a scheduled run produces — persist the user message,
    /// then `BackendHistoryResolver.resolve(inMemory: [userMessage])` — and asserts the three
    /// properties the old raw `fetchMessages` broke.
    ///
    /// ⚠️ This said "`SchedulerCoordinator` has no test class of its own", which was false in the
    /// same change set: `SchedulerCoordinatorTests` drives the real coordinator through a
    /// `MessageStreamStarting` spy. Nor is this the scheduler's sequence any more — it persists
    /// and then hands the message to `startMessageStream`, which derives. Kept because the ORDER
    /// property is worth pinning at the resolver, where it is cheap; the surface-level contract
    /// belongs to `SchedulerCoordinatorTests`.
    @MainActor
    func testScheduledRunSequenceProducesAscendingHistoryEndingInTheCurrentQuery() async {
        let store = OrderGuardStubStore()
        store.all = ascendingConversation(60)                  // 60 settled turns
        let userMessage = message(at: 60, sender: .user)       // this firing's prompt
        store.all.append(userMessage)                          // what persistScheduledQuestion writes

        let resolved = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: [userMessage], persistence: store
        )

        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: resolved.history),
                     "1. ascending, so pairTurns matches each reply to its own question")
        XCTAssertEqual(resolved.history.last?.id, userMessage.id,
                       "2. the current query is LAST, so BackendOrchestrationService's `.last` "
                       + "duplicate-strip inspects the right row instead of the oldest one")
        XCTAssertEqual(resolved.history.count, 61,
                       "3. the window is the resolver's 300, not the old hardcoded 50")
    }

    /// The recurring-task false positive, stated as an ordering property. A scheduled task fires
    /// the SAME prompt every time, so on a descending array the oldest row's text matched
    /// `userQuery` and `removeLast()` silently deleted the conversation's first turn. Ascending
    /// order is what makes `.last` the current message rather than the oldest identical one.
    @MainActor
    func testRecurringPromptDoesNotPutAnIdenticalOldRowWhereTheDedupLooks() async {
        let store = OrderGuardStubStore()
        let firstFiring = ChatMessage(id: UUID(), conversationId: convID, timestamp: t0,
                                      sender: .user, content: .plainText("daily standup"))
        let reply = message(at: 1, sender: .agent)
        let thisFiring = ChatMessage(id: UUID(), conversationId: convID,
                                     timestamp: t0.addingTimeInterval(2),
                                     sender: .user, content: .plainText("daily standup"))
        store.all = [firstFiring, reply, thisFiring]

        let resolved = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: [thisFiring], persistence: store
        )

        XCTAssertEqual(resolved.history.last?.id, thisFiring.id,
                       "the row the dedup inspects must be THIS firing, not the identical first one")
        XCTAssertEqual(resolved.history.first?.id, firstFiring.id,
                       "and the conversation's first turn stays put instead of being stripped")
    }
}


/// Minimal store double reproducing `ChatPersistenceStore.fetchMessages`' descending sort.
@MainActor
private final class OrderGuardStubStore: ChatPersistenceProtocol {
    var all: [ChatMessage] = []

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        let scoped = all.filter { $0.conversationId == conversationId }
            .sorted { $0.timestamp > $1.timestamp }
        return Array(scoped.dropFirst(offset).prefix(limit))
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
