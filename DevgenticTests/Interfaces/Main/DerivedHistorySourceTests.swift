// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DerivedHistorySourceTests.swift
//  DevgenticTests
//
//  Could `ActiveStreamManager` DERIVE the model-facing history instead of ACCEPTING it?
//
//  ⚠️ WRITTEN AS A FEASIBILITY GATE, BEFORE THE MOVE — and left in the present tense after it,
//  which made it read as a description of live code for a day. `startMessageStream` NO LONGER
//  TAKES `history`, `conversationID` or `userQuery` (`ActiveStreamManager.swift:357-366`); it
//  takes `userMessage` and derives the rest. The paragraphs below are kept because they record
//  WHY, but read them as history, not as the current API.
//
//  What it took history as a parameter FOR: the manager could not tell a resolved ascending
//  merge from a descending store dump (`SchedulerCoordinator`) from a 20-message pagination
//  window (`QuickAccessSessionViewModel`) from a private append-only transcript
//  (`OrbSessionController`). Every rule about that argument lived in a comment. That is why
//  invariant #8 ("ascending history only, from `BackendHistoryResolver`") was violated in live
//  code by the scheduler.
//
//  The fix was the move `LLM_Execution_Concurrency_Design.md:55` had already made once for
//  `streamingMessageID`: stop passing the value, derive it, and the wrong call becomes
//  unrepresentable rather than guarded against.
//
//  ⚠️ WHAT THIS FILE GUARDS NOW. Its tests exercise `BackendHistoryResolver` — that the derived
//  SOURCE (`[userMessage] ∪ activeStreams`) is equivalent to the UI array it replaced, which is
//  the property that made the move safe. It does NOT guard `ActiveStreamManager.deriveHistory`
//  itself; `DerivedHistoryContractTests` does that, and the two files assert DIFFERENT layers.
//  Where they look contradictory — an in-flight reply, carried here and absent there — see
//  `testTheResolverCarriesTheInFlightReplyAndTheSendPathThenOmitsIt` below, which pins both
//  halves in one place so neither can be read as refuting the other.
//
//  `BackendHistoryResolver.resolve(inMemory:)` USED TO BE fed
//  `chatHistoryViewModel.currentChatMessages`. The derivation was only safe if the manager's own
//  state carries everything that array contributes. The resolver's own header says `inMemory`
//  exists for exactly two reasons (`MessagingCoordinator.swift:795-797`): the just-sent user
//  message racing its detached persist, and in-flight streaming messages. If that is the whole
//  list, the manager can supply both — the user message becomes a parameter, and the streams
//  are `activeStreams`. The UI array would then be OVER-SUPPLY, which is precisely what let
//  QuickAccess pass a pagination window in the first place.
//
//  It was NOT the whole list when this file was written, and
//  `testTwoInputDerivationLosesAnUnpersistedCompactionCheckpoint` is the counter-example that
//  found the third: `MessagingCoordinator` used to persist a compaction checkpoint in a DETACHED
//  task while splicing it into `currentChatMessages` immediately, with the comment "so the NEXT
//  turn's history resolution sees it in memory too". For the width of that unawaited write the
//  UI array was the ONLY carrier, so a two-input derivation dropped it and the model lost the
//  summary standing in for turns already compacted away — silent context loss, the exact class
//  the resolver exists to prevent.
//
//  ✅ RESOLVED at the source rather than absorbed here. `MessagingCoordinator.deliverCheckpoint`
//  now AWAITS the store write before splicing, so the store is authoritative before anything can
//  observe the checkpoint and the splice is render-only. The derivation therefore needs only TWO
//  inputs in production:
//      derived = [the just-sent user message] ∪ activeStreams
//
//  These tests stay as the guard on both halves of that. `…LosesAnUnpersistedCompactionCheckpoint`
//  records WHY the await is load-bearing; `…ThreeInputDerivationIsEquivalentToTheUIArray` pins the
//  fallback shape if an unpersisted in-memory carrier is ever reintroduced; and
//  `…TheThirdInputIsOnlyNeededWhileThePersistIsInFlight` is the one that now describes production.
//  The ordering itself is pinned separately, and mutation-checked, by
//  `CompactionCheckpointDeliveryTests`.
//
//  Equivalence is compared as an ORDERED SEQUENCE OF IDS, never as a count or a character sum.
//  A character sum is order-independent, which is how the descending-history bug survived
//  (`architecture_readme.md` §7 #8, and `EpisodicFitGaugeAlignmentTests`).
//

import XCTest
@testable import devgentic


/// Store double matching `ChatPersistenceStore.fetchMessages`' DESCENDING sort
/// (`ChatPersistenceStore.swift:191`) and its offset/limit paging, so the resolver under test
/// is fed the same shape production gives it. The rest is inert conformance; the three
/// Code-Viewer/search members are defaulted on the protocol.
@MainActor
private final class DerivationStubStore: ChatPersistenceProtocol {
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


@MainActor
final class DerivedHistorySourceTests: XCTestCase {

    private let convID = UUID()
    private let otherConvID = UUID()
    private let t0 = Date(timeIntervalSince1970: 7_000_000)

    // MARK: - Fixtures

    private func message(
        _ index: Int,
        sender: SenderRole,
        text: String,
        conversation: UUID? = nil,
        streaming: Bool = false
    ) -> ChatMessage {
        ChatMessage(id: UUID(),
                    conversationId: conversation ?? convID,
                    timestamp: t0.addingTimeInterval(TimeInterval(index)),
                    sender: sender,
                    content: .plainText(text),
                    isStreaming: streaming)
    }

    private func checkpoint(_ index: Int) -> ChatMessage {
        // `sender: .agent` + `.checkpoint` content, matching HistoryCompactionService.swift:300-306.
        ChatMessage(id: UUID(),
                    conversationId: convID,
                    timestamp: t0.addingTimeInterval(TimeInterval(index)),
                    sender: .agent,
                    content: .checkpoint(summary: "turns 0-\(index) compacted"))
    }

    /// `count` alternating turns, oldest first — the persisted conversation.
    private func settledConversation(_ count: Int) -> [ChatMessage] {
        (0..<count).map { i in
            i % 2 == 0 ? message(i, sender: .user, text: "q\(i)")
                       : message(i, sender: .agent, text: "a\(i)")
        }
    }

    // MARK: - The two candidate `inMemory` sources

    /// WHAT CALLERS USED TO PASS: whatever the view model happened to hold, with nothing
    /// constraining its contents or its size. `currentChatMessages` is DESCENDING.
    private func uiWindow(_ resident: [ChatMessage]) -> [ChatMessage] {
        resident.sorted { $0.timestamp > $1.timestamp }
    }

    /// PROPOSED: assembled from `ActiveStreamManager`'s own state plus the message being sent.
    /// `pendingCheckpoints` is the third input this file exists to justify — pass `[]` to model
    /// the naive two-input derivation.
    private func derived(
        userMessage: ChatMessage?,
        liveStreams: [ChatMessage],
        pendingCheckpoints: [ChatMessage] = []
    ) -> [ChatMessage] {
        (userMessage.map { [$0] } ?? []) + liveStreams + pendingCheckpoints
    }

    /// Resolve both candidates and compare as an ordered id sequence.
    private func resolvedIDs(
        _ inMemory: [ChatMessage],
        store: DerivationStubStore
    ) async -> [UUID] {
        await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: inMemory, persistence: store
        ).history.map(\.id)
    }

    // MARK: - Reason 1: the user message racing its detached persist

    /// The user message is inserted into the UI array before its persist is guaranteed to have
    /// landed on every surface. The resolver keeps in-memory-only messages precisely so
    /// the user's own question cannot vanish from the request that answers it
    /// (`BackendHistoryResolver.swift:34-38`). A parameter carries it just as well as the array.
    func testDerivedSourceCoversTheUserMessageRacingItsPersist() async {
        let store = DerivationStubStore()
        store.all = settledConversation(6)              // the persist has NOT landed
        let justSent = message(6, sender: .user, text: "q6")

        let fromUI = await resolvedIDs(uiWindow(store.all + [justSent]), store: store)
        let fromDerived = await resolvedIDs(
            derived(userMessage: justSent, liveStreams: []), store: store
        )

        XCTAssertEqual(fromUI, fromDerived,
                       "the parameter must carry the racing user message exactly as the UI array did")
        XCTAssertEqual(fromDerived.last, justSent.id,
                       "and it must land LAST — ascending, so `.last` is the current question")
    }

    // MARK: - Reason 2: in-flight streaming messages, never in the store

    /// The agent placeholder is inserted into the UI array (`MessagingCoordinator.swift:236`)
    /// and registered in `activeStreams` at the same moment. `activeStreams` is therefore an
    /// equivalent carrier — and unlike the UI array it is keyed and view-free.
    func testDerivedSourceCoversInFlightStreamingMessages() async {
        let store = DerivationStubStore()
        store.all = settledConversation(6)
        let justSent = message(6, sender: .user, text: "q6")
        let streamingReply = message(7, sender: .agent, text: "", streaming: true)

        let fromUI = await resolvedIDs(
            uiWindow(store.all + [justSent, streamingReply]), store: store
        )
        let fromDerived = await resolvedIDs(
            derived(userMessage: justSent, liveStreams: [streamingReply]), store: store
        )

        XCTAssertEqual(fromUI, fromDerived)
        XCTAssertTrue(fromDerived.contains(streamingReply.id),
                      "the RESOLVER must carry it: an in-flight stream may not be in the store, and "
                      + "a source that dropped it could not represent the turn in progress at all. "
                      + "Whether the SEND PATH then keeps it is a separate decision — see the next test")
    }

    /// ⚠️ THE TWO LAYERS, PINNED TOGETHER so neither reads as refuting the other. The test above
    /// asserts an in-flight reply IS carried by the resolver; `DerivedHistoryContractTests`
    /// asserts it is ABSENT from what the model receives. Both are true, and they are not the
    /// same layer: the resolver's job is to lose nothing, and `deriveHistory` then subtracts the
    /// turns still being written, because a half-written turn makes `pairTurns` report the
    /// question as answered with nothing.
    ///
    /// This is also the only test in this file that touches the SHIPPED derivation — the rest
    /// exercise the resolver, which is why a regression in `deriveHistory` would not show up here.
    func testTheResolverCarriesTheInFlightReplyAndTheSendPathThenOmitsIt() async {
        let store = DerivationStubStore()
        store.all = settledConversation(6)
        let justSent = message(6, sender: .user, text: "q6")
        let streamingReply = message(7, sender: .agent, text: "", streaming: true)
        store.all.append(streamingReply)          // flushInFlight upserts the partial into the store

        let carried = await resolvedIDs([justSent], store: store)
        XCTAssertTrue(carried.contains(streamingReply.id),
                      "layer 1: the resolver returns everything, including the partial row the "
                      + "store now holds")

        let sent = await ActiveStreamManager.deriveHistory(
            userMessage: justSent,
            omitting: ActiveStreamManager.incompleteTurnIDs(
                liveRuns: [streamingReply.id: UUID()], keeping: justSent.id),
            before: nil,
            persistence: store
        )
        XCTAssertFalse(sent.contains { $0.id == streamingReply.id },
                       "layer 2: the send path subtracts the turn still being written")
        XCTAssertEqual(sent.last?.id, justSent.id,
                       "and the current question survives the subtraction and lands last")
    }

    // MARK: - What the UI array contributes that the store already has

    /// The 15× case, restated as the derivation's core claim: everything the render window
    /// holds beyond the two live messages is store-backed, so the derived source loses nothing
    /// by not reading the window. This is the test that makes the window OVER-SUPPLY.
    func testDerivedSourceLosesNothingByNotReadingTheRenderWindow() async {
        let store = DerivationStubStore()
        store.all = settledConversation(200)
        let resident = Array(store.all.suffix(20))       // one page, as just-opened

        let fromUI = await resolvedIDs(uiWindow(resident), store: store)
        let fromDerived = await resolvedIDs(derived(userMessage: nil, liveStreams: []), store: store)

        XCTAssertEqual(fromUI, fromDerived,
                       "the page adds nothing the store fetch did not already return")
        XCTAssertEqual(fromDerived.count, 200)
    }

    /// The property that matters for QuickAccess, whose window is a HARD 20 that never grows
    /// (`loadMoreMessages()` has one caller, the main window's `ChatHistoryView.swift:479`).
    /// Deriving makes the model's view independent of the panel's.
    func testDerivationIsIndifferentToHowMuchTheSurfaceRendered() async {
        let store = DerivationStubStore()
        store.all = settledConversation(120)
        let justSent = message(120, sender: .user, text: "q120")

        var uiResults: [[UUID]] = []
        for residentCount in [0, 20, 50, 120] {          // popover → just-opened → scrolled → full
            let resident = Array(store.all.suffix(residentCount)) + [justSent]
            uiResults.append(await resolvedIDs(uiWindow(resident), store: store))
        }
        let fromDerived = await resolvedIDs(
            derived(userMessage: justSent, liveStreams: []), store: store
        )

        XCTAssertEqual(Set(uiResults.map { $0.count }).count, 1,
                       "precondition: the resolver already neutralises window size")
        for (i, ui) in uiResults.enumerated() {
            XCTAssertEqual(ui, fromDerived, "derivation must match UI variant \(i)")
        }
    }

    /// `currentChatMessages` can hold another conversation's rows mid-switch — for ≥250 ms plus
    /// a model unload, `ConversationSwitchCoordinator.swift:126`/`:162-164`/`:172`. The resolver
    /// filters by `conversationId` (`BackendHistoryResolver.swift:57`), and the derived source
    /// inherits that. Pinned because deriving must not REMOVE a protection the array had.
    func testForeignConversationRowsAreExcludedFromBothSources() async {
        let store = DerivationStubStore()
        store.all = settledConversation(6)
        let justSent = message(6, sender: .user, text: "q6")
        let foreign = message(7, sender: .user, text: "wrong chat", conversation: otherConvID)

        let fromUI = await resolvedIDs(uiWindow(store.all + [justSent, foreign]), store: store)
        let fromDerived = await resolvedIDs(
            derived(userMessage: justSent, liveStreams: [foreign]), store: store
        )

        XCTAssertEqual(fromUI, fromDerived)
        XCTAssertFalse(fromDerived.contains(foreign.id),
                       "a foreign row must never reach the model, from either source")
    }

    // MARK: - The counter-example: a THIRD input is required

    /// ⚠️ THE FINDING. `MessagingCoordinator.swift:87-90` persists a compaction checkpoint in a
    /// DETACHED, UNAWAITED task, then splices it into `currentChatMessages` at `:94` — the
    /// comment at `:91-93` says the splice exists "so the NEXT turn's history resolution sees it
    /// in memory too". For the width of that write the UI array is the ONLY carrier: the
    /// checkpoint is neither a live stream nor the message being sent.
    ///
    /// CONSEQUENCE if the derivation shipped with two inputs: the turn sent in that window loses
    /// the checkpoint, so the model sees neither the compacted turns (removed) nor the summary
    /// that replaced them (dropped) — silent context loss with no log line.
    func testTwoInputDerivationLosesAnUnpersistedCompactionCheckpoint() async {
        let store = DerivationStubStore()
        store.all = settledConversation(6)
        let pending = checkpoint(3)                      // spliced into the UI, write not landed
        let justSent = message(6, sender: .user, text: "q6")

        let fromUI = await resolvedIDs(
            uiWindow(store.all + [pending, justSent]), store: store
        )
        let fromTwoInput = await resolvedIDs(
            derived(userMessage: justSent, liveStreams: []), store: store
        )

        XCTAssertTrue(fromUI.contains(pending.id),
                      "precondition: today's source DOES carry the un-persisted checkpoint")
        XCTAssertFalse(fromTwoInput.contains(pending.id),
                       "and a two-input derivation does NOT — this is why the contract is three inputs")
        XCTAssertNotEqual(fromUI, fromTwoInput,
                          "if these ever match, either the splice or this test has stopped meaning anything")
    }

    /// The contract the derivation must actually implement. Green here is the precondition for
    /// moving the seven `startMessageStream` call sites.
    func testThreeInputDerivationIsEquivalentToTheUIArray() async {
        let store = DerivationStubStore()
        store.all = settledConversation(6)
        let pending = checkpoint(3)
        let justSent = message(6, sender: .user, text: "q6")
        let streamingReply = message(7, sender: .agent, text: "", streaming: true)

        let fromUI = await resolvedIDs(
            uiWindow(store.all + [pending, justSent, streamingReply]), store: store
        )
        let fromDerived = await resolvedIDs(
            derived(userMessage: justSent,
                    liveStreams: [streamingReply],
                    pendingCheckpoints: [pending]),
            store: store
        )

        XCTAssertEqual(fromUI, fromDerived,
                       "three inputs — user message, activeStreams, pending checkpoints — is the whole list")
    }

    /// Once the checkpoint's store write lands, it stops being a third input and the two-input
    /// derivation is sufficient again. Pins that the third input is a RACE WINDOW carrier, not a
    /// permanent channel — so an implementation may instead await the persist at
    /// `MessagingCoordinator.swift:88` and drop the third input entirely.
    func testTheThirdInputIsOnlyNeededWhileThePersistIsInFlight() async {
        let store = DerivationStubStore()
        let pending = checkpoint(3)
        store.all = settledConversation(6) + [pending]   // the detached write HAS landed
        let justSent = message(6, sender: .user, text: "q6")

        let fromUI = await resolvedIDs(uiWindow(store.all + [justSent]), store: store)
        let fromTwoInput = await resolvedIDs(
            derived(userMessage: justSent, liveStreams: []), store: store
        )

        XCTAssertEqual(fromUI, fromTwoInput,
                       "a persisted checkpoint arrives via the store; awaiting the write is the alternative fix")
        XCTAssertTrue(fromTwoInput.contains(pending.id))
    }

    // MARK: - Whole-inventory composite

    /// Every kind of row the nine `currentChatMessages` insert sites can add, in one conversation:
    ///   ConversationSyncService.swift:80        → a ChatOps stream          (activeStreams)
    ///   ChatHistoryViewModel.swift:205          → a compaction checkpoint   (pendingCheckpoints)
    ///   ChatHistoryViewModel.swift:1785         → paged older messages      (store)
    ///   MessagingCoordinator.swift:181/710      → the user message          (parameter)
    ///   MessagingCoordinator.swift:236/765      → the agent placeholder     (activeStreams)
    ///   QuickAccessSessionViewModel.swift:326   → the user message          (parameter)
    ///   QuickAccessSessionViewModel.swift:374   → the agent placeholder     (activeStreams)
    /// If this passes, no insert site contributes a row the derivation cannot reach.
    func testDerivationCoversEveryCurrentChatMessagesInsertSite() async {
        let store = DerivationStubStore()
        store.all = settledConversation(40)                       // paged / settled rows
        let pending = checkpoint(41)
        let justSent = message(42, sender: .user, text: "q42")
        let ownStream = message(43, sender: .agent, text: "", streaming: true)
        let chatOpsStream = message(44, sender: .agent, text: "", streaming: true)

        let resident = store.all + [pending, justSent, ownStream, chatOpsStream]
        let fromUI = await resolvedIDs(uiWindow(resident), store: store)
        let fromDerived = await resolvedIDs(
            derived(userMessage: justSent,
                    liveStreams: [ownStream, chatOpsStream],
                    pendingCheckpoints: [pending]),
            store: store
        )

        XCTAssertEqual(fromUI, fromDerived,
                       "a row reachable only through the view model would show up as a diff here")
        XCTAssertEqual(fromDerived.count, 44)
    }

    // MARK: - Invariant #8, at the boundary the derivation would own

    /// The whole point of deriving: the resolver sorts ascending
    /// (`BackendHistoryResolver.swift:43`), so a derived history CANNOT arrive descending the way
    /// `SchedulerCoordinator.swift:159` does today. Asserted on ids, not on a character sum —
    /// a character sum is order-independent, which is how this went unnoticed.
    func testDerivedHistoryIsAlwaysAscendingRegardlessOfInputOrder() async {
        let store = DerivationStubStore()
        store.all = settledConversation(20)
        let justSent = message(20, sender: .user, text: "q20")

        let ascendingInput = derived(userMessage: justSent, liveStreams: [])
        let descendingInput = Array(ascendingInput.reversed())

        let a = await resolvedIDs(ascendingInput, store: store)
        let b = await resolvedIDs(descendingInput, store: store)
        let expected = (store.all + [justSent]).map(\.id)   // store.all is built oldest-first

        XCTAssertEqual(a, b, "input order must not survive the resolver")
        XCTAssertEqual(a, expected, "and the output must be oldest-first — invariant #8")
    }
}
