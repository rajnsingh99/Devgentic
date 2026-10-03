// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SchedulerCoordinatorTests.swift
//  DevgenticTests
//
//  The first tests this type has ever had. It is the surface that shipped the only live
//  violation of `architecture_readme.md` §7 invariant #8 — "Ascending history only, from
//  `BackendHistoryResolver`" — and it went unnoticed because nothing here was covered.
//
//  Two layers are covered here.
//
//  1. `persistScheduledQuestion` + `ActiveStreamManager.deriveHistory` — the two real steps of a
//     scheduled run's pre-flight, in the real order. This is the half that carried the invariant
//     #8 bug.
//  2. `sendScheduledMessage` — the WHOLE path, driven for real through the `MessageStreamStarting`
//     seam. This is the layer that could not be tested at all before: the method used to need a
//     `MainApplicationViewModel` (whose init runs `ChatOpsCoordinator.bootstrap()` and opens real
//     Telegram/Discord/Slack connections when the developer has them enabled), and it parks on a
//     continuation only `startMessageStream`'s `onComplete` resumes — with `ActiveStreamManager`
//     being `final`, there was nothing to intercept.
//
//  Both blockers are gone: the user-message factory is `MessagingCoordinator.makeUserMessage`
//  (needs a `FileProcessorService`, not a view model), workflow bookkeeping takes the narrow
//  `WorkflowRunRegistry`, and the stream boundary is `MessageStreamStarting`. A spy conforming to
//  it captures the hand-off and resumes the continuation, so the real method runs to completion
//  with no backend, no network and no view model.
//
//  Everything below asserts on ORDERED IDS, never on counts or character sums. A character sum
//  is order-independent, which is exactly what let a descending array ship.
//

import XCTest
@testable import devgentic


/// Store double reproducing `ChatPersistenceStore.fetchMessages`' DESCENDING sort and its
/// offset/limit paging, so the resolver under test sees the shape production gives it.
/// `addMessage` is an upsert-by-id, matching the real store.
@MainActor
private final class SchedulerStubStore: ChatPersistenceProtocol {
    var all: [ChatMessage] = []
    private(set) var fetchLimits: [Int] = []

    /// ⚠️ SNAPSHOT AT WRITE TIME. `ChatMessage` is a CLASS, so storing the reference means a
    /// later mutation is visible retroactively through it — an assertion that production set a
    /// field BEFORE the write cannot fail, because the same object is re-read afterwards. The
    /// real store does not behave that way: it projects into `ChatMessageSD` at write time, so a
    /// field set after `addMessage` never reaches the durable row. These snapshots reproduce that.
    private(set) var writeTimeAttribution: [(id: UUID, sender: SenderRole, source: MessageSource)] = []

    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {
        writeTimeAttribution.append((message.id, message.sender, message.messageSource))
        all.removeAll { $0.id == message.id }
        all.append(message)
    }

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        fetchLimits.append(limit)
        let scoped = all.filter { $0.conversationId == conversationId }
            .sorted { $0.timestamp > $1.timestamp }
        return Array(scoped.dropFirst(offset).prefix(limit))
    }

    func addConversation(from conversation: Conversation) {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    /// `sendScheduledMessage` bails at its first guard when this is nil, so the end-to-end
    /// tests need a real row. Registered by `seedConversation`.
    var conversations: [UUID: ConversationSD] = [:]
    func getConversation(withId id: UUID) -> ConversationSD? { conversations[id] }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}


/// Captures what a surface hands to the send path's chokepoint, and completes the run so the
/// caller's `withCheckedContinuation` resumes. This is the whole point of `MessageStreamStarting`:
/// before it, no test could see what `SchedulerCoordinator` passed — which is why it shipped a
/// descending array past every review.
@MainActor
private final class SpyStreamStarter: MessageStreamStarting {
    struct Handoff {
        let userMessage: ChatMessage
        let promptOverride: String?
        let files: [FileSystemItem]
        let updating: ChatMessage?
        let workflowExecutionState: WorkflowExecutionState?
        /// What the model will actually be told, after `promptOverride` is applied.
        var effectiveQuery: String { promptOverride ?? userMessage.content.textContent ?? "" }
        var conversationID: UUID { userMessage.conversationId }
    }

    private(set) var handoffs: [Handoff] = []
    private(set) var cancelled: [UUID] = []
    /// Content the fake assistant turn reports, so summary extraction can be asserted.
    var replyText = "done"

    @discardableResult
    func startMessageStream(
        withConfig config: BackendRequestConfig,
        userMessage: ChatMessage,
        promptOverride: String?,
        files: [FileSystemItem],
        updating existingMessage: ChatMessage?,
        workflowExecutionState: WorkflowExecutionState?,
        resumeState: TimelineReconstruction?,
        onComplete: @escaping () -> Void
    ) -> ChatMessage {
        handoffs.append(Handoff(userMessage: userMessage, promptOverride: promptOverride,
                                files: files, updating: existingMessage,
                                workflowExecutionState: workflowExecutionState))
        let agentMessage = ChatMessage(conversationId: userMessage.conversationId, sender: .agent,
                                       content: .plainText(replyText))
        // Resume on the next turn of the loop, mirroring a real stream finishing after the
        // caller has returned from `startMessageStream` and filled its message box.
        Task { @MainActor in onComplete() }
        return agentMessage
    }

    func cancelStream(for messageId: UUID) { cancelled.append(messageId) }
}


/// Three properties, per `WorkflowRunBootstrap.swift:45-56`. `begin` returns nil for every
/// non-workflow profile, so nothing here is touched on the ordinary scheduled path.
@MainActor
private final class StubRunRegistry: WorkflowRunRegistry {
    var workflowExecutionStates: [UUID: WorkflowExecutionState] = [:]
    var workflowRunHistory: [UUID: [WorkflowRunRecord]] = [:]
    var unsavedWorkflowCanvasProfileIDs: [UUID] { [] }
}


@MainActor
final class SchedulerCoordinatorTests: XCTestCase {

    private let convID = UUID()
    private let otherConvID = UUID()
    private let t0 = Date(timeIntervalSince1970: 6_000_000)
    private let logger = DGLogger(category: "SchedulerCoordinatorTests")

    private var store: SchedulerStubStore!
    /// ⚠️ Held for the test's lifetime on purpose: `SchedulerCoordinator.runRegistry` is WEAK
    /// (the view model owns the coordinator in production, so a strong ref would be a cycle).
    /// An inline `StubRunRegistry()` at a call site deallocates before the send runs, and the
    /// coordinator correctly refuses with "run registry unavailable".
    private var registry: StubRunRegistry!

    override func setUp() async throws {
        store = SchedulerStubStore()
        registry = StubRunRegistry()
    }

    override func tearDown() async throws {
        store = nil
        registry = nil
    }

    // MARK: - Fixtures

    private func message(_ offset: Int, sender: SenderRole, text: String? = nil,
                         conversation: UUID? = nil) -> ChatMessage {
        ChatMessage(id: UUID(),
                    conversationId: conversation ?? convID,
                    timestamp: t0.addingTimeInterval(TimeInterval(offset)),
                    sender: sender,
                    content: .plainText(text ?? "m\(offset)"))
    }

    /// `count` alternating turns, oldest first.
    private func priorTurns(_ count: Int) -> [ChatMessage] {
        (0..<count).map { message($0, sender: $0 % 2 == 0 ? .user : .agent) }
    }

    /// What a scheduled run ACTUALLY does: persist the question, then let `ActiveStreamManager`
    /// derive the history the request will carry.
    ///
    /// ⚠️ These assertions used to read the return value of `prepareScheduledRequest`, which
    /// resolved history itself — a resolve production DISCARDED (`_ = await …`). So the tests were
    /// pinning a value no run ever used, while the value runs actually carry went unasserted. The
    /// resolve is gone; the helper now performs both real steps in the real order, so every
    /// assertion below is about what the model receives.
    private func prepare(userMessage: ChatMessage, in conversation: UUID? = nil) async -> [ChatMessage] {
        let convo = conversation ?? convID
        await SchedulerCoordinator.persistScheduledQuestion(
            userMessage: userMessage, conversationID: convo, persistence: store, logger: logger
        )
        return await ActiveStreamManager.deriveHistory(
            userMessage: userMessage, before: nil, persistence: store
        )
    }

    // MARK: - Invariant #8: the defect this type shipped

    /// ⚠️ THE REGRESSION TEST. The store returns newest-first; the request must be oldest-first.
    /// If this fails, `pairTurns` is mispairing every turn of every scheduled run again.
    func testResolvedHistoryIsAscendingEvenThoughTheStoreReturnsDescending() async {
        store.all = priorTurns(20)
        let raw = await store.fetchMessages(for: convID, offset: 0, limit: 50)
        XCTAssertNotNil(ActiveStreamManager.firstDescendingPair(in: raw),
                        "precondition: the raw store output really is descending")

        let history = await prepare(userMessage: message(20, sender: .user, text: "run the report"))

        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: history),
                     "the request must carry oldest-first history — invariant #8")
        XCTAssertEqual(history.map(\.id), history.sorted { $0.timestamp < $1.timestamp }.map(\.id))
    }

    /// `BackendOrchestrationService` strips the duplicate current query by inspecting `.last`.
    /// On the old descending array `.last` was the OLDEST row, so the strip could never fire for
    /// the right message. Ascending order is what puts the current question where it looks.
    func testCurrentQueryIsTheLastElementSoTheDuplicateStripCanSeeIt() async {
        store.all = priorTurns(8)
        let userMessage = message(8, sender: .user, text: "run the report")

        let history = await prepare(userMessage: userMessage)

        XCTAssertEqual(history.last?.id, userMessage.id)
        XCTAssertEqual(history.last?.sender, .user)
    }

    /// ⚠️ The nastiest of the three defects, and the one no prior test could have caught.
    /// A recurring task sends the SAME prompt every firing. On a descending array `.last` was the
    /// conversation's FIRST-EVER user message, whose text is identical — so the duplicate strip
    /// matched it and `removeLast()` silently deleted the oldest real turn from model history.
    /// Ascending order means the identical old row is at `.first`, nowhere near the strip.
    func testRecurringPromptLeavesTheOldestIdenticalTurnIntact() async {
        let prompt = "daily standup summary"
        let firstFiring = message(0, sender: .user, text: prompt)
        let firstReply = message(1, sender: .agent, text: "yesterday you…")
        store.all = [firstFiring, firstReply]
        let thisFiring = message(2, sender: .user, text: prompt)

        let history = await prepare(userMessage: thisFiring)

        XCTAssertEqual(history.first?.id, firstFiring.id,
                       "the conversation's first turn must survive — it used to be removeLast()'d")
        XCTAssertEqual(history.last?.id, thisFiring.id,
                       "and the row the strip inspects must be THIS firing")
        XCTAssertEqual(history.count, 3, "no turn lost to the false-positive strip")
    }

    // MARK: - The window

    /// The old call hardcoded `limit: 50`. A scheduled turn must not get a smaller view of the
    /// conversation than the desktop UI would give it — the rule ChatOps already follows.
    func testWindowIsTheResolverLimitNotTheOldHardcodedFifty() async {
        store.all = priorTurns(120)

        let history = await prepare(userMessage: message(120, sender: .user))

        XCTAssertEqual(history.count, 121, "121 > the old 50-message ceiling")
        XCTAssertEqual(store.fetchLimits, [BackendHistoryResolver.messageLimit],
                       "the fetch must ask for the resolver's window, exactly once")
    }

    /// And the cap still bounds it, so a very long conversation cannot blow up the request.
    func testTheResolverCapStillBoundsAVeryLongConversation() async {
        store.all = priorTurns(BackendHistoryResolver.messageLimit + 40)

        let history = await prepare(userMessage: message(9_999, sender: .user))

        XCTAssertLessThanOrEqual(history.count, BackendHistoryResolver.messageLimit + 1,
                                 "store rows are capped; the in-memory current message is additive")
    }

    // MARK: - Ordering of the pre-flight itself

    /// Persist BEFORE the derivation. It is store-authoritative, so a question that has not landed
    /// is missing from the very request that answers it.
    func testUserMessageIsPersistedBeforeHistoryIsDerived() async {
        store.all = priorTurns(4)
        let userMessage = message(4, sender: .user, text: "run the report")
        XCTAssertFalse(store.all.contains { $0.id == userMessage.id }, "precondition")

        let history = await prepare(userMessage: userMessage)

        XCTAssertTrue(store.all.contains { $0.id == userMessage.id },
                      "the scheduled turn must be durable, not only in the request")
        XCTAssertTrue(history.contains { $0.id == userMessage.id },
                      "and present in the history that answers it")
    }

    /// The persist is an upsert-by-id and the resolver dedups by id, so the message the caller
    /// also passes as `inMemory` must not appear twice.
    func testTheCurrentMessageAppearsExactlyOnce() async {
        store.all = priorTurns(6)
        let userMessage = message(6, sender: .user, text: "run the report")

        let history = await prepare(userMessage: userMessage)

        XCTAssertEqual(history.filter { $0.id == userMessage.id }.count, 1)
    }

    /// A brand-new scheduled conversation has no prior turns; the request is just the question.
    func testFirstEverFiringCarriesOnlyItsOwnQuestion() async {
        let userMessage = message(0, sender: .user, text: "kickoff")

        let history = await prepare(userMessage: userMessage)

        XCTAssertEqual(history.map(\.id), [userMessage.id])
    }

    /// Scheduled runs are conversation-scoped like every other surface — another conversation's
    /// rows must never leak in, even though they share the store.
    func testOtherConversationsAreNotIncluded() async {
        store.all = priorTurns(6) + [
            message(7, sender: .user, text: "different chat", conversation: otherConvID),
            message(8, sender: .agent, text: "different reply", conversation: otherConvID)
        ]
        let userMessage = message(9, sender: .user, text: "run the report")

        let history = await prepare(userMessage: userMessage)

        XCTAssertTrue(history.allSatisfy { $0.conversationId == convID })
        XCTAssertEqual(history.count, 7)
    }

    // MARK: - The chokepoint agrees

    /// End-to-end on the two things step 0 and step 1 were meant to make agree: what the Scheduler
    /// produces must satisfy the guard-rail that would have caught the old bug.
    func testSchedulerOutputSatisfiesTheStartMessageStreamGuardRail() async {
        store.all = priorTurns(60)

        let history = await prepare(userMessage: message(60, sender: .user, text: "run the report"))

        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: history),
                     "the surface that tripped the guard-rail must now pass it")
    }

    // MARK: - The whole path, through the seam

    /// A coordinator whose registry is already gone — the teardown shape the guard exists for.
    private func makeRegistrylessCoordinator(spy: SpyStreamStarter) -> SchedulerCoordinator {
        SchedulerCoordinator(
            viewModel: nil,
            persistenceService: store,
            activeStreamManager: spy,
            fileProcessorService: FileProcessorService(),
            runRegistry: nil
        )
    }

    private func makeCoordinator(spy: SpyStreamStarter) -> SchedulerCoordinator {
        SchedulerCoordinator(
            viewModel: nil,                      // ⚠️ no MainApplicationViewModel — the point
            persistenceService: store,
            activeStreamManager: spy,
            fileProcessorService: FileProcessorService(),
            runRegistry: registry          // the test-lifetime instance; see the property note
        )
    }

    private func botConfig() -> BackendRequestConfig {
        BackendRequestConfig(profile: BackendProfileSnapshot(
            id: UUID(),
            displayName: "Scheduled Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama,
                                                             modelName: "test-model")))
        ))
    }

    private func workflowConfig() -> BackendRequestConfig {
        BackendRequestConfig(profile: BackendProfileSnapshot(
            id: UUID(),
            displayName: "Scheduled Workflow",
            details: .workflow(WorkflowConfig())
        ))
    }

    private func seedConversation() {
        store.conversations[convID] = ConversationSD(id: convID, userDefinedTitle: "Scheduled")
    }

    /// ⚠️ THE TEST THAT COULD NOT EXIST BEFORE THE SEAM. Drives the real `sendScheduledMessage`
    /// and asserts on what actually reached the chokepoint. A descending array here is exactly
    /// what shipped, and exactly what no test could see.
    func testSendScheduledMessageHandsAscendingHistoryToTheStream() async {
        seedConversation()
        store.all = priorTurns(30)
        let spy = SpyStreamStarter()
        let coordinator = makeCoordinator(spy: spy)

        _ = await coordinator.sendScheduledMessage(
            prompt: "run the report", config: botConfig(),
            conversationID: convID, attachedFileURLs: []
        )

        XCTAssertEqual(spy.handoffs.count, 1, "exactly one run started")
        let handoff = spy.handoffs[0]
        XCTAssertEqual(handoff.conversationID, convID)
        XCTAssertEqual(handoff.effectiveQuery, "run the report")
        // ⚠️ The surface no longer HANDS OVER history — it hands over the message and
        // `ActiveStreamManager` derives it. So the assertion moved to the derivation itself.
        let derived = await ActiveStreamManager.deriveHistory(
            userMessage: handoff.userMessage, before: nil, persistence: store)
        XCTAssertNil(ActiveStreamManager.firstDescendingPair(in: derived),
                     "the history the run will carry must be oldest-first — invariant #8")
    }

    /// The current question must be the last row the boundary receives, so
    /// `BackendOrchestrationService`'s `.last` duplicate-strip inspects it rather than the oldest.
    func testTheQueryHandedOverIsAlsoTheLastMessageInTheHistory() async {
        seedConversation()
        store.all = priorTurns(10)
        let spy = SpyStreamStarter()
        let coordinator = makeCoordinator(spy: spy)

        _ = await coordinator.sendScheduledMessage(
            prompt: "weekly digest", config: botConfig(),
            conversationID: convID, attachedFileURLs: []
        )

        let handoff = spy.handoffs[0]
        let derived = await ActiveStreamManager.deriveHistory(
            userMessage: handoff.userMessage, before: nil, persistence: store)
        XCTAssertEqual(derived.last?.id, handoff.userMessage.id)
        XCTAssertEqual(derived.last?.sender, .user)
    }

    /// The run must reach the boundary with the resolver's window, not the old hardcoded 50.
    func testTheStreamReceivesTheFullResolverWindow() async {
        seedConversation()
        store.all = priorTurns(120)
        let spy = SpyStreamStarter()
        let coordinator = makeCoordinator(spy: spy)

        _ = await coordinator.sendScheduledMessage(
            prompt: "digest", config: botConfig(),
            conversationID: convID, attachedFileURLs: []
        )

        let derived = await ActiveStreamManager.deriveHistory(
            userMessage: spy.handoffs[0].userMessage, before: nil, persistence: store)
        XCTAssertEqual(derived.count, 121)
    }

    /// A bot profile takes no workflow ticket (`begin` returns nil for non-workflow profiles), so
    /// the ordinary scheduled path must hand over no execution state — and must not have needed
    /// the registry to do real work.
    func testOrdinaryScheduledRunCarriesNoWorkflowState() async {
        seedConversation()
        let spy = SpyStreamStarter()
        let coordinator = makeCoordinator(spy: spy)

        _ = await coordinator.sendScheduledMessage(
            prompt: "ping", config: botConfig(),
            conversationID: convID, attachedFileURLs: []
        )

        XCTAssertNil(spy.handoffs[0].workflowExecutionState)
        XCTAssertTrue(registry.workflowExecutionStates.isEmpty)
    }

    /// The scheduled turn must be durable before the stream starts — an unattended run is only
    /// reviewable from history.
    func testTheUserMessageIsPersistedBeforeTheStreamStarts() async {
        seedConversation()
        let spy = SpyStreamStarter()
        let coordinator = makeCoordinator(spy: spy)

        _ = await coordinator.sendScheduledMessage(
            prompt: "persist me", config: botConfig(),
            conversationID: convID, attachedFileURLs: []
        )

        XCTAssertTrue(store.all.contains { $0.content.textContent == "persist me" && $0.sender == .user })
    }

    /// The caller (a Telegram reply body, a scheduler log) gets the assistant's text back.
    func testSummaryComesFromTheAssistantReply() async {
        seedConversation()
        let spy = SpyStreamStarter()
        spy.replyText = "Report generated: 14 items."
        let coordinator = makeCoordinator(spy: spy)

        let summary = await coordinator.sendScheduledMessage(
            prompt: "run", config: botConfig(),
            conversationID: convID, attachedFileURLs: []
        )

        XCTAssertEqual(summary, "Report generated: 14 items.")
    }

    /// An unknown conversation must refuse before creating or persisting anything.
    func testUnknownConversationStartsNoRun() async {
        let spy = SpyStreamStarter()
        let coordinator = makeCoordinator(spy: spy)

        let summary = await coordinator.sendScheduledMessage(
            prompt: "orphan", config: botConfig(),
            conversationID: UUID(), attachedFileURLs: []
        )

        XCTAssertTrue(spy.handoffs.isEmpty, "no run may start for a conversation that is not there")
        XCTAssertTrue(store.all.isEmpty, "and nothing may be written")
        XCTAssertTrue(summary.hasPrefix("Error:"))
    }

    // MARK: - Attribution (the field-log contract)

    /// ⚠️ The scheduler set `messageSource` only on the AGENT message, so `[STREAM_START]` — which
    /// reads the source off THIS message to name the surface that started a run — reported every
    /// scheduled run as `localUI`. A device log showing `started by localUI` for a 03:00 scheduled
    /// task sends the reader after the wrong thing entirely.
    ///
    /// ⚠️ THE CONTRACT IS THE FIELD LOG, NOTHING ELSE. `messageSource` is TRANSIENT — no column,
    /// not restored by `toChatMessage()`, so a reloaded row reads `.localUI` whatever it was sent
    /// as. An earlier version of this comment claimed ChatOps mirroring, analytics and the audit
    /// trail depend on it; none of them read the field (`RemoteMirrorService` has no reference to
    /// it at all). Do not widen these assertions to imply durability they do not have.
    func testTheScheduledUserMessageIsAttributedToTheScheduler() async {
        seedConversation()
        let spy = SpyStreamStarter()
        let coordinator = makeCoordinator(spy: spy)

        _ = await coordinator.sendScheduledMessage(
            prompt: "nightly digest", config: botConfig(),
            conversationID: convID, attachedFileURLs: []
        )

        XCTAssertEqual(spy.handoffs[0].userMessage.messageSource, .scheduled,
                       "the row handed to the send path — and read by [STREAM_START] — must name "
                       + "the scheduler, not the .localUI default")
        let persistedID = store.all.first { $0.content.textContent == "nightly digest" }?.id
        XCTAssertEqual(store.writeTimeAttribution.first { $0.id == persistedID }?.source, .scheduled,
                       "and the row as it stood AT THE WRITE carries it too — the assignment "
                       + "happens before addMessage, so anything reading the message in-process "
                       + "during the write sees the real surface, not the .localUI default")
    }

    /// Attribution is set before the persist, not patched afterwards — otherwise the durable row
    /// and the in-flight one disagree for the width of the write.
    func testAttributionIsSetBeforeThePersist() async {
        seedConversation()
        let spy = SpyStreamStarter()
        let coordinator = makeCoordinator(spy: spy)

        _ = await coordinator.sendScheduledMessage(
            prompt: "check", config: botConfig(), conversationID: convID, attachedFileURLs: [])

        // Read the WRITE-TIME snapshot, not the live object: `store.all` holds the same
        // references production mutates, so asserting on it passes even if the assignment is
        // moved below the persist — which is exactly the ordering this test is named for.
        let userWrites = store.writeTimeAttribution.filter { $0.sender == .user }
        XCTAssertFalse(userWrites.isEmpty, "precondition: the scheduled question was persisted")
        XCTAssertTrue(userWrites.allSatisfy { $0.source == .scheduled },
                      "no user row may reach the store carrying the .localUI default — attribution "
                      + "must be assigned BEFORE addMessage, not patched afterwards")
    }

    // MARK: - ⚠️ A missing run registry must not strand the question (fixed 2026-09-07)

    /// ⚠️ THE ORDERING DEFECT. The registry guard was moved below `persistScheduledQuestion`
    /// during the derive-don't-accept work, so a nil registry aborted AFTER the user's scheduled
    /// question had been durably written — leaving a row nothing would ever answer.
    /// `EpisodicHistoryFormatter.pairTurns` then reports it to the model on the next turn as
    /// "Agent never responded to this query". Refusing before the write leaves the conversation
    /// exactly as it was.
    func testAWorkflowRunWithNoRegistryIsRefusedBeforeAnythingIsPersisted() async {
        seedConversation()
        let spy = SpyStreamStarter()
        let coordinator = makeRegistrylessCoordinator(spy: spy)
        let before = store.all.count

        let result = await coordinator.sendScheduledMessage(
            prompt: "nightly workflow", config: workflowConfig(),
            conversationID: convID, attachedFileURLs: [])

        XCTAssertEqual(result, "Error: run registry unavailable.")
        XCTAssertEqual(store.all.count, before,
                       "no row may be written by a run that is then refused — the abort must "
                       + "happen BEFORE the persist, not after it")
        XCTAssertTrue(store.writeTimeAttribution.isEmpty, "…and nothing reached the store at all")
        XCTAssertTrue(spy.handoffs.isEmpty, "and nothing was sent")
    }

    /// ⚠️ THE OVER-ABORT. The same guard refused EVERY profile type while its own `.error` said
    /// in so many words that "non-workflow profiles are unaffected" — and they are:
    /// `WorkflowRunBootstrap.begin` returns nil for them without touching the registry. A bot
    /// schedule was being refused for a dependency it never uses.
    func testABotRunWithNoRegistryStillSends() async {
        seedConversation()
        let spy = SpyStreamStarter()
        let coordinator = makeRegistrylessCoordinator(spy: spy)

        _ = await coordinator.sendScheduledMessage(
            prompt: "nightly digest", config: botConfig(),
            conversationID: convID, attachedFileURLs: [])

        XCTAssertEqual(spy.handoffs.count, 1,
                       "a bot schedule needs no run registry and must not be refused for one")
        XCTAssertEqual(spy.handoffs.first?.userMessage.messageSource, .scheduled)
    }

}


// MARK: - HITL Waiting Contract, slice 3: the scheduled run's execution limit

/// Behaves like a real stream: runs until cancelled (then completes, as `ActiveStreamManager`'s
/// finalize does), or until `finishAfter` passes. Optionally parks on a gate INSIDE the run —
/// from a task created within `startMessageStream`, so it inherits the run's `ParkScope` exactly
/// as the real stream's producer task does.
@MainActor
private final class HoldingStreamStarter: MessageStreamStarting {
    var finishAfter: Duration? = nil
    var parkFor: Duration? = nil
    private(set) var cancelled: [UUID] = []
    private var completions: [UUID: () -> Void] = [:]
    private(set) var parkOperation: UUID?
    private(set) var lastMessage: ChatMessage?

    @discardableResult
    func startMessageStream(withConfig config: BackendRequestConfig, userMessage: ChatMessage,
                            promptOverride: String?, files: [FileSystemItem], updating existingMessage: ChatMessage?,
                            workflowExecutionState: WorkflowExecutionState?, resumeState: TimelineReconstruction?,
                            onComplete: @escaping () -> Void) -> ChatMessage {
        let message = ChatMessage(conversationId: userMessage.conversationId, sender: .agent, content: .plainText("working"))
        lastMessage = message
        completions[message.id] = onComplete
        let conversation = userMessage.conversationId
        let id = message.id
        if let parkFor {
            let op = UUID()
            parkOperation = op
            Task {   // inherits the run's ParkScope chain
                let park = Task { await ExecutionSuspensionService.shared.suspendForGate(for: op, conversationID: conversation) }
                try? await Task.sleep(for: parkFor)
                await ExecutionSuspensionService.shared.resumeGate(for: op, chosenOption: "ok", resolvedBy: .localUI)
                _ = await park.value
                await MainActor.run { self.complete(id) }
            }
        } else if let finishAfter {
            Task { @MainActor in
                try? await Task.sleep(for: finishAfter)
                self.complete(id)
            }
        }
        return message
    }

    func cancelStream(for messageId: UUID) {
        cancelled.append(messageId)
        complete(messageId)
    }

    private func complete(_ id: UUID) {
        completions.removeValue(forKey: id)?()
    }
}

@MainActor
final class SchedulerRunLimitTests: XCTestCase {

    private let convID = UUID()
    private var store: SchedulerStubStore!
    private var registry: StubRunRegistry!

    override func setUp() async throws {
        store = SchedulerStubStore()
        store.conversations[convID] = ConversationSD(id: convID, userDefinedTitle: "Scheduled")
        registry = StubRunRegistry()
    }

    private func agentConfig(executionTimeout: TimeInterval?) -> BackendRequestConfig {
        var agent = AgentConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m"), tools: [])
        agent.executionTimeout = executionTimeout
        return BackendRequestConfig(profile: BackendProfileSnapshot(id: UUID(), displayName: "Scheduled Agent",
                                                                     details: .agent(agent)))
    }

    private func coordinator(_ streams: HoldingStreamStarter) -> SchedulerCoordinator {
        SchedulerCoordinator(viewModel: nil, persistenceService: store, activeStreamManager: streams,
                             fileProcessorService: FileProcessorService(), runRegistry: registry)
    }

    /// The limit fires, the run is recorded TIMED OUT (not "Cancelled by user", not "completed"),
    /// and the caller returns promptly.
    func testARunPastItsLimitIsStoppedAndRecordedAsTimedOut() async {
        let streams = HoldingStreamStarter()
        // Finishes on its own at 3 s — so a regression FAILS (the run completes) instead of hanging.
        streams.finishAfter = .seconds(3)
        let start = ContinuousClock.now
        let result = await coordinator(streams).runScheduledMessage(
            prompt: "report", config: agentConfig(executionTimeout: 0.5), conversationID: convID, attachedFileURLs: [])

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertTrue(result.summary.hasPrefix("Timed out"), result.summary)
        XCTAssertEqual(streams.cancelled.count, 1, "the run must actually be stopped")
        // Status sweep: the run's own message says TIMED OUT, with the contract's wording.
        XCTAssertEqual(streams.lastMessage?.terminalOutcome, .timedOut)
        XCTAssertEqual(streams.lastMessage?.terminalReason, ActiveStreamManager.executionTimeoutMessage(limit: 0.5))
    }

    /// D-20: the limit drains THIS run's parks only. An attended run's banner in the same
    /// conversation — here, a park owned by another bound — must survive it.
    func testTheLimitDoesNotResolveAnotherRunsBanner() async throws {
        let otherBound = UUID(), op = UUID()
        await ExecutionSuspensionService.shared.registerScope(otherBound, conversationID: convID)
        let foreign = Task.detached { [convID] in
            await ParkScope.$chain.withValue([otherBound]) {
                await ExecutionSuspensionService.shared.suspendForGate(for: op, conversationID: convID)
            }
        }
        for _ in 0..<400 {
            if await ExecutionSuspensionService.shared.pendingSuspensionCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let result = await coordinator(HoldingStreamStarter()).runScheduledMessage(
            prompt: "report", config: agentConfig(executionTimeout: 0.3), conversationID: convID, attachedFileURLs: [])
        XCTAssertEqual(result.outcome, .timedOut)
        try await Task.sleep(for: .milliseconds(200))
        let stillParked = await ExecutionSuspensionService.shared.pendingSuspensionCount()
        XCTAssertEqual(stillParked, 1, "the scheduled run's limit resolved another run's banner (D-20)")

        await ExecutionSuspensionService.shared.resumeGate(for: op, chosenOption: "X", resolvedBy: .localUI)
        _ = await foreign.value
        await ExecutionSuspensionService.shared.unregisterScope(otherBound)
    }

    /// Decision 1, through the real wiring: a park INSIDE the run pauses its limit. The run parks
    /// for 1.2 s against a 0.5 s limit and then finishes — it must complete, not time out.
    func testAParkInsideTheRunPausesItsLimit() async {
        let streams = HoldingStreamStarter()
        streams.parkFor = .milliseconds(1200)
        let result = await coordinator(streams).runScheduledMessage(
            prompt: "report", config: agentConfig(executionTimeout: 0.5), conversationID: convID, attachedFileURLs: [])
        XCTAssertEqual(result.outcome, .completed,
                       "a human wait inside the scheduled run was charged against its limit")
        XCTAssertTrue(streams.cancelled.isEmpty)
    }

    func testTheLimitIsTheProfilesOwnElseThirtyMinutes() {
        XCTAssertEqual(SchedulerCoordinator.scheduledRunLimit(for: agentConfig(executionTimeout: 90).profile), 90)
        XCTAssertEqual(SchedulerCoordinator.scheduledRunLimit(for: agentConfig(executionTimeout: nil).profile), 30 * 60)
        XCTAssertEqual(SchedulerCoordinator.scheduledRunLimit(for: agentConfig(executionTimeout: 0).profile), 30 * 60,
                       "0 must never mean 'stop at once'")
    }

    // MARK: - Per-task limit (owner decision 2026-09-27)

    func testATasksOwnLimitWinsOverItsProfileAndTheDefault() {
        let profile = agentConfig(executionTimeout: 90).profile
        XCTAssertEqual(SchedulerCoordinator.scheduledRunLimit(for: profile, taskLimit: 300), 300)
        XCTAssertEqual(SchedulerCoordinator.scheduledRunLimit(for: profile, taskLimit: nil), 90)
        XCTAssertEqual(SchedulerCoordinator.scheduledRunLimit(for: profile, taskLimit: 0), 90,
                       "an unusable task limit falls through to the profile's, never 'stop at once'")
    }

    /// End to end: a bot profile has no limit of its own, so only the TASK's limit can stop it.
    func testATasksOwnLimitStopsTheRun() async {
        let bot = BackendRequestConfig(profile: BackendProfileSnapshot(
            id: UUID(), displayName: "Bot",
            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "m")))))
        let streams = HoldingStreamStarter()
        streams.finishAfter = .seconds(3)   // a regression completes instead of hanging
        let start = ContinuousClock.now
        let result = await coordinator(streams).runScheduledMessage(
            prompt: "report", config: bot, conversationID: convID, attachedFileURLs: [], runLimit: 0.4)
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3))
    }

    /// The model ↔ value mapping is hand-written (`toStruct` / `apply`), which is exactly where a
    /// new field gets silently dropped. Round-trip both directions.
    func testTheTasksLimitSurvivesTheStore() {
        var task = ScheduledTaskModel(id: UUID()).toStruct()
        XCTAssertNil(task.runLimit)
        task.runLimit = 45 * 60
        let model = ScheduledTaskModel(id: task.id)
        model.apply(from: task)
        XCTAssertEqual(model.runLimitSeconds, 45 * 60)
        XCTAssertEqual(model.toStruct().runLimit, 45 * 60)
        task.runLimit = nil
        model.apply(from: task)
        XCTAssertNil(model.toStruct().runLimit, "clearing the limit must persist too")
    }

    func testTheServicePassesTheTasksLimitToTheRun() throws {
        let service = try source("Devgentic/Core/Service/Scheduler/SchedulerService.swift")
        XCTAssertTrue(service.contains("runLimit: task.runLimit"),
                      "the scheduler no longer hands the task's own limit to the run")
    }

    // MARK: - Decision C: nobody-to-ask refusals

    /// The MCP brokers cannot read a run's attendance (their requests arrive on the transport's
    /// own task), so they ask the suspension service. An unattended bound in the conversation —
    /// and anything nested under it — must make the answer "no".
    func testAttendanceIsKnownPerConversationForOutOfChainAsks() async {
        let conversation = UUID(), run = UUID(), tool = UUID(), elsewhere = UUID()
        let suspension = ExecutionSuspensionService.shared
        var reachable = await suspension.canReachAHuman(inConversation: conversation)
        XCTAssertTrue(reachable, "no open bound: an attended conversation")

        await suspension.registerScope(run, conversationID: conversation, attended: false)
        await suspension.registerScope(tool, under: [run])
        await suspension.registerScope(elsewhere, conversationID: UUID(), attended: true)
        reachable = await suspension.canReachAHuman(inConversation: conversation)
        XCTAssertFalse(reachable, "an unattended run is open here — an MCP question must be refused")

        await suspension.unregisterScope(run)
        reachable = await suspension.canReachAHuman(inConversation: conversation)
        XCTAssertFalse(reachable, "the nested tool bound inherits its run's attendance")
        await suspension.unregisterScope(tool)
        reachable = await suspension.canReachAHuman(inConversation: conversation)
        XCTAssertTrue(reachable)
        await suspension.unregisterScope(elsewhere)
    }

    /// The in-run asks that used to park with nobody to answer (decision C). Pinned at their
    /// sites: each needs a live model to drive behaviourally.
    func testTheUngatedAsksAreNowGatedOnAttendance() throws {
        let planning = try source("Devgentic/Core/Backends/TextGen/Capabilities/PlanningCapability.swift")
        XCTAssertTrue(planning.contains("&& WorkflowRunAttendance.canReachAHuman"),
                      "clarify-before-planning parks in unattended runs again")
        XCTAssertTrue(planning.contains("config.requiresPlanApproval && !subtasks.isEmpty && !WorkflowRunAttendance.canReachAHuman"),
                      "plan review parks in unattended runs again")
        let loop = try source("Devgentic/Core/Backends/TextGen/ReAct/Components/Execution/ToolExecutionLoop.swift")
        guard let ask = loop.range(of: "if case .askUser(let reason) = boundary.outcome {") else {
            return XCTFail("the out-of-project ask moved — this pin checks nothing")
        }
        let window = loop[ask.upperBound...].prefix(600)
        XCTAssertTrue(window.contains("if !WorkflowRunAttendance.canReachAHuman"),
                      "the out-of-project ask parks in unattended runs again")
        for path in ["Devgentic/Interfaces/Main/Views/Tooling/Mcp/MCPElicitationBroker.swift",
                     "Devgentic/Interfaces/Main/Views/Tooling/Mcp/MCPSamplingBroker.swift"] {
            XCTAssertTrue(try source(path).contains("canReachAHuman(inConversation:"),
                          "\(path) parks in unattended runs again")
        }
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}
