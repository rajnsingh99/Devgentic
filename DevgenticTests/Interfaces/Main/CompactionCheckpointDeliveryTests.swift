// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CompactionCheckpointDeliveryTests.swift
//  DevgenticTests
//
//  A compaction checkpoint must be DURABLY STORED before it is spliced into the live
//  transcript. These tests pin the order, not the policy.
//
//  The bug they close: `MessagingCoordinator.registerCompactionCheckpointSink` used to wrap
//  `addMessage` in an unawaited `Task` and splice immediately after, with a comment saying the
//  splice existed "so the NEXT turn's history resolution sees it in memory too". For the width
//  of that unawaited write, `currentChatMessages` was the ONLY copy of the checkpoint — the
//  view's array acting as a DATA channel rather than a render window.
//
//  Two consequences, both silent:
//    1. A history resolution reading the store alone in that window returns neither the
//       compacted turns (removed from the batch) nor the summary standing in for them.
//    2. It blocks deriving history from `ActiveStreamManager`'s own state, because a checkpoint
//       is neither a live stream nor the message being sent. `DerivedHistorySourceTests`
//       demonstrates that loss from the other side.
//
//  ⚠️ WHY THE SUSPENDING STORE. A test that just calls `deliverCheckpoint` and then asserts
//  "both happened" passes under the OLD code too — the detached `Task` also lands, eventually.
//  That is a policy test and it protects nothing. `SuspendingStore` holds `addMessage` open
//  until the test releases it, so the assertion "the splice has NOT happened yet" can only pass
//  when the write is genuinely awaited. Reintroducing a detached `Task` turns
//  `testSpliceDoesNotHappenUntilTheStoreWriteLands` red.
//

import XCTest
@testable import devgentic


/// Store double whose `addMessage` parks until `release()` is called, recording what it was
/// handed. Everything else is inert conformance; the Code-Viewer/search members are defaulted
/// on `ChatPersistenceProtocol`.
@MainActor
private final class SuspendingStore: ChatPersistenceProtocol {
    private(set) var stored: [ChatMessage] = []
    private(set) var addMessageEntered = false
    private var gate: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    /// Set false to let writes complete immediately.
    var parkOnWrite = true

    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {
        addMessageEntered = true
        arrival?.resume()                       // wake a test waiting on `waitUntilWriteEntered`
        arrival = nil
        if parkOnWrite {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate = continuation
            }
        }
        stored.append(message)
    }

    /// Suspends until `addMessage` has been entered. A handshake rather than a `Task.yield()`
    /// spin: both the test and the delivery task run on the main actor, so a busy-wait there
    /// is a deadlock risk, not just slow.
    func waitUntilWriteEntered() async {
        guard !addMessageEntered else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            arrival = continuation
        }
    }

    /// Lets a parked `addMessage` complete. No-op if nothing is parked.
    func release() {
        gate?.resume()
        gate = nil
    }

    /// Forgets that a write has been seen, so seeding a fixture through this same store does not
    /// make a later `waitUntilWriteEntered()` return instantly.
    func resetWriteTracking() {
        addMessageEntered = false
    }

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        stored.filter { $0.conversationId == conversationId }
            .sorted { $0.timestamp > $1.timestamp }
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
final class CompactionCheckpointDeliveryTests: XCTestCase {

    private let convID = UUID()
    private let t0 = Date(timeIntervalSince1970: 8_000_000)
    private let logger = DGLogger(category: "CompactionCheckpointDeliveryTests")

    private var store: SuspendingStore!
    private var viewModel: ChatHistoryViewModel!

    override func setUp() async throws {
        store = SuspendingStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            )
        )
    }

    override func tearDown() async throws {
        store?.release()
        viewModel = nil
        store = nil
    }

    // MARK: - Fixtures

    private func turn(_ index: Int, sender: SenderRole) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: convID,
                    timestamp: t0.addingTimeInterval(TimeInterval(index)),
                    sender: sender, content: .plainText("m\(index)"))
    }

    /// Matches `HistoryCompactionService.swift:300-306` — `.agent` sender, `.checkpoint` content.
    private func makeCheckpoint(_ index: Int) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: convID,
                    timestamp: t0.addingTimeInterval(TimeInterval(index)),
                    sender: .agent,
                    content: .checkpoint(summary: "turns 0-\(index) compacted"))
    }

    /// `insertCheckpoint` skips unless the target conversation is the loaded one
    /// (`ChatHistoryViewModel.swift:196`), so the splice half of these tests needs a real load.
    /// ⚠️ Seeding goes through the SAME store the test parks on, so parking must be off while
    /// the fixture lands — otherwise the first seed write suspends with nothing to release it.
    /// Tracking is reset afterwards so `waitUntilWriteEntered()` waits for the write under test,
    /// not for one of these.
    private func loadConversation(with messages: [ChatMessage]) async {
        let parking = store.parkOnWrite
        store.parkOnWrite = false
        for message in messages { await store.addMessage(message, toConversation: convID) }
        store.parkOnWrite = parking
        store.resetWriteTracking()
        await viewModel.loadConversation(id: convID)
    }

    private func viewHoldsCheckpoint(_ checkpoint: ChatMessage) -> Bool {
        viewModel.currentChatMessages.contains { $0.id == checkpoint.id }
    }

    // MARK: - The ordering contract

    /// ⚠️ THE WIRING TEST. Fails if the store write is ever detached from the splice again.
    /// While `addMessage` is parked, the checkpoint must exist in NEITHER place — publishing it
    /// to the view first is exactly the window that made the view array a data channel.
    func testSpliceDoesNotHappenUntilTheStoreWriteLands() async {
        await loadConversation(with: [turn(0, sender: .user), turn(1, sender: .agent)])
        let checkpoint = makeCheckpoint(2)

        let delivery = Task {
            await MessagingCoordinator.deliverCheckpoint(
                checkpoint, conversationID: convID,
                persistence: store, viewModel: viewModel, logger: logger
            )
        }

        await store.waitUntilWriteEntered()

        XCTAssertFalse(viewHoldsCheckpoint(checkpoint),
                       "the splice must NOT run while the store write is still in flight — "
                       + "that window is what made `currentChatMessages` a data channel")
        XCTAssertFalse(store.stored.contains { $0.id == checkpoint.id },
                       "precondition: the checkpoint's write really is parked (the seeded turns "
                       + "are already stored, so this asserts on the checkpoint alone)")

        store.release()
        await delivery.value

        XCTAssertTrue(store.stored.contains { $0.id == checkpoint.id },
                      "the checkpoint must be durable once delivery returns")
        XCTAssertTrue(viewHoldsCheckpoint(checkpoint),
                      "and only then visible in the live transcript")
    }

    /// Delivery must not return until the row is durable, so the caller
    /// (`HistoryCompactionService.swift:133-139`, whose `defer` releases the duplicate-run
    /// guard) cannot let a second turn re-plan the same batch against a store missing it.
    func testDeliveryDoesNotReturnBeforeTheRowIsDurable() async {
        await loadConversation(with: [turn(0, sender: .user)])
        let checkpoint = makeCheckpoint(1)

        let delivery = Task {
            await MessagingCoordinator.deliverCheckpoint(
                checkpoint, conversationID: convID,
                persistence: store, viewModel: viewModel, logger: logger
            )
        }
        await store.waitUntilWriteEntered()
        store.release()
        await delivery.value

        XCTAssertEqual(store.stored.last?.id, checkpoint.id,
                       "the store write is complete by the time delivery returns")
    }

    // MARK: - The store, not the view, is the carrier

    /// The property that lets history be DERIVED rather than passed: once delivery has
    /// returned, a resolution that never reads `currentChatMessages` still sees the checkpoint.
    /// This is the assertion `DerivedHistorySourceTests` could only model with a third input.
    func testAfterDeliveryTheCheckpointIsReachableWithoutTheViewArray() async {
        await loadConversation(with: [turn(0, sender: .user), turn(1, sender: .agent)])
        let checkpoint = makeCheckpoint(2)
        store.parkOnWrite = false

        await MessagingCoordinator.deliverCheckpoint(
            checkpoint, conversationID: convID,
            persistence: store, viewModel: viewModel, logger: logger
        )

        let resolved = await BackendHistoryResolver.resolve(
            conversationID: convID, inMemory: [], persistence: store   // ← no view array at all
        )

        XCTAssertTrue(resolved.history.contains { $0.id == checkpoint.id },
                      "the store alone must carry the checkpoint — otherwise deriving history "
                      + "from ActiveStreamManager's own state silently drops it")
    }

    // MARK: - The splice stays render-only, and stays safe

    /// The splice is now render-only, so its guards may skip it freely. A checkpoint for a
    /// conversation that is not open must still be durable — `insertCheckpoint` logs and returns
    /// (`ChatHistoryViewModel.swift:196-199`), and the persisted copy loads on reopen.
    func testCheckpointForAnUnloadedConversationIsStillPersisted() async {
        await loadConversation(with: [turn(0, sender: .user)])
        let otherConvID = UUID()
        let checkpoint = ChatMessage(id: UUID(), conversationId: otherConvID,
                                     timestamp: t0.addingTimeInterval(3), sender: .agent,
                                     content: .checkpoint(summary: "other conversation"))
        store.parkOnWrite = false

        await MessagingCoordinator.deliverCheckpoint(
            checkpoint, conversationID: otherConvID,
            persistence: store, viewModel: viewModel, logger: logger
        )

        XCTAssertTrue(store.stored.contains { $0.id == checkpoint.id },
                      "durability must not depend on which conversation happens to be open")
        XCTAssertFalse(viewHoldsCheckpoint(checkpoint),
                       "and it must not be spliced into the wrong transcript")
    }

    /// `addMessage` is an upsert-by-id and `insertCheckpoint` dedups by id
    /// (`ChatHistoryViewModel.swift:200`), so a re-delivered checkpoint must not double up.
    func testRedeliveringTheSameCheckpointDoesNotDuplicateIt() async {
        await loadConversation(with: [turn(0, sender: .user), turn(1, sender: .agent)])
        let checkpoint = makeCheckpoint(2)
        store.parkOnWrite = false

        for _ in 0..<3 {
            await MessagingCoordinator.deliverCheckpoint(
                checkpoint, conversationID: convID,
                persistence: store, viewModel: viewModel, logger: logger
            )
        }

        XCTAssertEqual(viewModel.currentChatMessages.filter { $0.id == checkpoint.id }.count, 1,
                       "the live transcript must hold exactly one copy")
    }

    /// The splice must land in DESCENDING position, not appended — `currentChatMessages` is
    /// newest-first (`ChatHistoryViewModel.swift:1722-1724`) and the checkpoint's timestamp sits
    /// just after the last compacted message (`HistoryCompactionService.swift:297-298`).
    func testSplicedCheckpointLandsInDescendingPosition() async {
        let older = turn(0, sender: .user)
        let newer = turn(4, sender: .agent)
        await loadConversation(with: [older, newer])
        let checkpoint = makeCheckpoint(2)          // between the two
        store.parkOnWrite = false

        await MessagingCoordinator.deliverCheckpoint(
            checkpoint, conversationID: convID,
            persistence: store, viewModel: viewModel, logger: logger
        )

        let ids = viewModel.currentChatMessages.map(\.id)
        XCTAssertEqual(ids, [newer.id, checkpoint.id, older.id],
                       "newest-first, with the checkpoint at its timestamp position")
    }
}
