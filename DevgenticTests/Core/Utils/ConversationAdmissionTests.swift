// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationAdmissionTests.swift
//  DevgenticTests
//
//  ⚠️⚠️ THE DEFECT: two concurrent runs in ONE conversation were reachable and nothing stopped
//  them. The only guard was the composer greying out its send button — a property of the TEXT BOX.
//  `SchedulerCoordinator`, Orb and the ChatOps bridge call `ActiveStreamManager` directly, and
//  `deriveHistory`'s own comment said so: *"the scheduler, Orb and the ChatOps bridge carry no
//  admission check."*
//
//  Nothing threw, because `activeStreams` is keyed by MESSAGE id and two runs in one conversation
//  are a valid state. The damage was silent: two agents reading the same history (each seeing the
//  other's half-written turn), calling tools against the same files, at double the token cost.
//

import XCTest
@testable import devgentic

@MainActor
final class ConversationAdmissionTests: XCTestCase {

    /// Stands in for `activeStreams`: conversation → the message ids currently live in it.
    private var live: [UUID: Set<UUID>] = [:]
    private var admission: ConversationAdmission!
    private let conversation = UUID()

    override func setUp() {
        super.setUp()
        live = [:]
        admission = ConversationAdmission { [weak self] conversationID, excluding in
            guard let self else { return false }
            return (self.live[conversationID] ?? []).contains { $0 != excluding }
        }
    }

    private func start(_ messageID: UUID, in conversationID: UUID? = nil) {
        live[conversationID ?? conversation, default: []].insert(messageID)
    }

    private func finish(_ messageID: UUID, in conversationID: UUID? = nil) {
        let id = conversationID ?? conversation
        live[id]?.remove(messageID)
        // ⚠️ The order `ActiveStreamManager` uses: leave the live set FIRST, then admit. Admitting
        // first hands the next run a conversation that still looks occupied.
        admission.admitNext(inConversation: id)
    }

    /// ⚠️ BOUNDED, never `await task.value`.
    ///
    /// Every interesting mutation of this gate — never admitting, always reporting busy, dropping
    /// the resume — manifests as a run that NEVER STARTS. An unbounded await turns each of those
    /// into a hung suite instead of a red test, which is worse: mutation runs stall, CI stalls, and
    /// the signal ("this mutant is not caught") is indistinguishable from "the machine is slow".
    private func waitUntil(_ condition: @escaping () -> Bool, seconds: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }

    // MARK: - The gate

    func testAnIdleConversationAdmitsImmediately() async {
        let first = UUID()
        start(first)
        var admitted = false
        let task = Task { @MainActor in
            await admission.awaitTurn(conversationID: conversation, messageID: first)
            admitted = true
        }
        defer { task.cancel() }

        let admitted1 = await waitUntil { admitted }
        XCTAssertTrue(admitted1,
                      "the only run in a conversation parked — every run would find ITSELF busy "
                      + "and nothing would ever start")
        XCTAssertEqual(admission.waitingCount(inConversation: conversation), 0)
    }

    /// ⚠️ THE ONE THAT MATTERS. Without the gate this returns instantly and two runs proceed.
    func testASecondRunWaitsWhileTheFirstIsLive() async {
        let first = UUID(), second = UUID()
        start(first)
        start(second)

        var secondStarted = false
        let task = Task { @MainActor in
            await admission.awaitTurn(conversationID: conversation, messageID: second)
            secondStarted = true
        }
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(secondStarted,
                       "the second run started while the first was still live — two agents now "
                       + "share one conversation's history, tools and transcript")
        XCTAssertEqual(admission.waitingCount(inConversation: conversation), 1)

        finish(first)
        let admitted2 = await waitUntil { secondStarted }
        XCTAssertTrue(admitted2,
                      "the second run was never admitted after the first ended — the conversation "
                      + "is deadlocked and nothing will ever run in it again")
        task.cancel()
    }

    /// A ChatOps message that has waited longest must not be overtaken.
    func testWaitersAreAdmittedInArrivalOrder() async {
        let first = UUID(), second = UUID(), third = UUID()
        start(first); start(second); start(third)

        var order: [UUID] = []
        let a = Task { @MainActor in
            await admission.awaitTurn(conversationID: conversation, messageID: second)
            order.append(second)
        }
        await Task.yield(); await Task.yield()
        let b = Task { @MainActor in
            await admission.awaitTurn(conversationID: conversation, messageID: third)
            order.append(third)
        }
        await Task.yield(); await Task.yield()
        XCTAssertEqual(admission.waitingCount(inConversation: conversation), 2)

        finish(first)
        let admitted3 = await waitUntil { order.count == 1 }
        XCTAssertTrue(admitted3,
 "the first waiter was never admitted")
        // `second` is still in `live`, so `third` keeps waiting — exactly as a real run would.
        XCTAssertEqual(order, [second], "the queue did not hold the third run back")

        finish(second)
        let admitted4 = await waitUntil { order.count == 2 }
        XCTAssertTrue(admitted4,
 "the second waiter was never admitted")
        XCTAssertEqual(order, [second, third], "waiters were admitted out of arrival order")
        a.cancel(); b.cancel()
    }

    func testADifferentConversationIsNotBlocked() async {
        let other = UUID()
        let busy = UUID(), elsewhere = UUID()
        start(busy)
        start(elsewhere, in: other)

        var started = false
        let task = Task { @MainActor in
            await admission.awaitTurn(conversationID: other, messageID: elsewhere)
            started = true
        }
        defer { task.cancel() }
        let admitted5 = await waitUntil { started }
        XCTAssertTrue(admitted5,
 "a run was blocked by another conversation")
        XCTAssertEqual(admission.waitingCount(inConversation: other), 0,
                       "a run was blocked by a DIFFERENT conversation's activity — the gate is "
                       + "per conversation, not global")
    }

    // MARK: - Teardown

    /// ⚠️ `withCheckedContinuation` is NOT cancellation-aware. A parked waiter whose stream is
    /// cancelled never resumes on its own: the continuation leaks for the life of the process and
    /// anything awaiting that task hangs forever.
    func testCancellingAConversationReleasesItsWaiters() async {
        let first = UUID(), second = UUID()
        start(first); start(second)

        var released = false
        let task = Task { @MainActor in
            await admission.awaitTurn(conversationID: conversation, messageID: second)
            released = true
        }
        await Task.yield(); await Task.yield()
        XCTAssertEqual(admission.waitingCount(inConversation: conversation), 1)

        admission.releaseAll(inConversation: conversation)

        let admitted6 = await waitUntil { released }
        XCTAssertTrue(admitted6,
 "a waiting run was left parked forever when its conversation was "
                      + "cancelled — its continuation leaks and anything awaiting it hangs")
        XCTAssertEqual(admission.waitingCount(inConversation: conversation), 0)
        task.cancel()
    }

    /// A queued id whose task is gone must not block everything behind it.
    func testAStaleQueueEntryDoesNotStallTheQueue() async {
        let first = UUID(), ghost = UUID(), real = UUID()
        start(first); start(ghost); start(real)

        let ghostTask = Task { @MainActor in
            await admission.awaitTurn(conversationID: conversation, messageID: ghost)
        }
        await Task.yield(); await Task.yield()

        var realStarted = false
        let realTask = Task { @MainActor in
            await admission.awaitTurn(conversationID: conversation, messageID: real)
            realStarted = true
        }
        await Task.yield(); await Task.yield()

        // The ghost withdraws. ⚠️ Its id STAYS in the queue — `forget` drops only the waiter, so
        // the skip inside `admitNext` is the single mechanism that keeps the queue moving.
        admission.forget(messageID: ghost, inConversation: conversation)
        XCTAssertEqual(admission.waitingCount(inConversation: conversation), 2,
                       "forget must leave the id queued — otherwise admitNext's skip guards a "
                       + "state nothing can produce, and goes untested")
        finish(first)
        let admitted7 = await waitUntil { realStarted }
        XCTAssertTrue(admitted7,
                      "the queue stalled behind an id whose task had already gone")
        ghostTask.cancel(); realTask.cancel()
    }

    func testForgettingARunThatIsNotQueuedIsHarmless() {
        admission.forget(messageID: UUID(), inConversation: conversation)
        XCTAssertEqual(admission.waitingCount(inConversation: conversation), 0)
    }

    // MARK: - Saying so on screen

    /// ⚠️ Without this a queued run is indistinguishable from a slow one — the indicator reads
    /// "Reasoning" while nothing is reasoning. A ChatOps message arriving while the user types
    /// locally then looks like the app has stalled rather than like it is second in line.
    func testParkingTellsTheCallerSoItCanSayItOnScreen() async {
        let first = UUID(), second = UUID()
        start(first); start(second)

        var announced = false
        let task = Task { @MainActor in
            await admission.awaitTurn(conversationID: conversation, messageID: second,
                                      onWait: { announced = true })
        }
        defer { task.cancel() }

        let sawIt = await waitUntil { announced }
        XCTAssertTrue(sawIt, "a run parked without telling anyone — the UI cannot distinguish "
                      + "waiting from working")
    }

    /// ⚠️ `onWait` must fire ONLY when it parks. A run admitted immediately that flashed "Waiting
    /// its turn" would be a lie in the other direction, on every ordinary message.
    func testAnImmediateAdmissionAnnouncesNothing() async {
        let only = UUID()
        start(only)

        var announced = false
        var returned: Bool?
        let task = Task { @MainActor in
            returned = await admission.awaitTurn(conversationID: conversation, messageID: only,
                                                 onWait: { announced = true })
        }
        defer { task.cancel() }

        let done = await waitUntil { returned != nil }
        XCTAssertTrue(done, "the only run in a conversation never returned")
        XCTAssertFalse(announced, "a run that never waited claimed to be queued")
        XCTAssertEqual(returned, false, "awaitTurn must report that it did not park")
    }

    /// The caller undoes the label on the strength of this, so it has to be true.
    func testAParkedRunReportsThatItParked() async {
        let first = UUID(), second = UUID()
        start(first); start(second)

        var returned: Bool?
        let task = Task { @MainActor in
            returned = await admission.awaitTurn(conversationID: conversation, messageID: second)
        }
        defer { task.cancel() }
        _ = await waitUntil { self.admission.waitingCount(inConversation: self.conversation) == 1 }

        finish(first)
        let done = await waitUntil { returned != nil }
        XCTAssertTrue(done, "the parked run never resumed")
        XCTAssertEqual(returned, true, "a run that waited reported that it had not")
    }

    /// The label itself must reach the UI, which renders `detail.rawValue`.
    func testTheQueuedStateHasAReadableLabel() {
        XCTAssertEqual(AgentState.thinking(.queued).headline, "Waiting its turn",
                       "the queued state has no readable headline, so the indicator would show "
                       + "nothing useful while a run waits")
        XCTAssertEqual(AgentState.thinking(.queued).category, .thinking,
                       "a waiting run must still read as in-progress, not idle or completed")
    }

    // MARK: - The real busy predicate

    /// ⚠️ MUTATION FOUND THIS UNCOVERED. Every test above injects its own `isBusy`, so the
    /// PRODUCTION predicate had no coverage at all — deleting `excluding` from it left the whole
    /// suite green while, in the real app, every run would have found ITSELF busy and parked
    /// forever. Testing the policy with a fake says nothing about the fake's real counterpart.
    func testTheRealBusyPredicateIgnoresTheAskingRun() {
        let mine = ChatMessage(conversationId: conversation, sender: .agent, content: .markdownText(""))
        let streams = [mine.id: mine]

        XCTAssertFalse(
            ActiveStreamManager.isConversationBusy(streams, conversationID: conversation, excluding: mine.id),
            "a run found ITSELF busy — it would park forever and the conversation would never run "
            + "anything again")
    }

    func testTheRealBusyPredicateSeesAnotherRun() {
        let mine = ChatMessage(conversationId: conversation, sender: .agent, content: .markdownText(""))
        let theirs = ChatMessage(conversationId: conversation, sender: .agent, content: .markdownText(""))
        let streams = [mine.id: mine, theirs.id: theirs]

        XCTAssertTrue(
            ActiveStreamManager.isConversationBusy(streams, conversationID: conversation, excluding: mine.id),
            "a second live run in the same conversation was not seen — this is the concurrency the "
            + "gate exists to stop")
    }

    func testTheRealBusyPredicateIsScopedToOneConversation() {
        let elsewhere = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
        let mine = ChatMessage(conversationId: conversation, sender: .agent, content: .markdownText(""))
        let streams = [elsewhere.id: elsewhere, mine.id: mine]

        XCTAssertFalse(
            ActiveStreamManager.isConversationBusy(streams, conversationID: conversation, excluding: mine.id),
            "another CONVERSATION's run blocked this one — the gate is per conversation")
    }

    // MARK: - Queue existence alone is enough to park

    /// ⚠️ The window `hasQueue` exists for: a caller that queues BEFORE it appears in the live set
    /// leaves `isBusy` saying no while runs are genuinely waiting. Without this an arrival in that
    /// window jumps the entire queue — and the message that has waited longest is exactly the one
    /// that must not be starved.
    func testAnArrivalDoesNotOvertakeAQueueWhenTheConversationLooksIdle() async {
        var pretendBusy = true
        let gate = ConversationAdmission { _, _ in pretendBusy }

        let waiting = UUID()
        let waitingTask = Task { @MainActor in
            await gate.awaitTurn(conversationID: conversation, messageID: waiting)
        }
        defer { waitingTask.cancel() }
        let queued = await waitUntil { gate.waitingCount(inConversation: self.conversation) == 1 }
        XCTAssertTrue(queued, "bad fixture — nothing was queued")

        // The conversation now looks idle, but someone is still waiting.
        pretendBusy = false

        let latecomer = UUID()
        var latecomerStarted = false
        let lateTask = Task { @MainActor in
            await gate.awaitTurn(conversationID: conversation, messageID: latecomer)
            latecomerStarted = true
        }
        defer { lateTask.cancel() }

        let overtook = await waitUntil({ latecomerStarted }, seconds: 0.4)
        XCTAssertFalse(overtook,
                       "a new arrival ran immediately while another was still queued — it jumped "
                       + "the whole queue, which starves whatever has waited longest")
        XCTAssertEqual(gate.waitingCount(inConversation: conversation), 2)
    }

    // MARK: - Wiring

    /// Without this the gate is a type nothing consults, and every caller still races.
    func testTheStreamManagerActuallyAwaitsAdmission() throws {
        let source = try sourceFile("Devgentic/Core/Utils/ActiveStreamManager.swift")
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("admission.awaitTurn("),
                      "the send path does not wait for admission — the scheduler, Orb and ChatOps "
                      + "can still start a run into a busy conversation")
        XCTAssertTrue(code.contains("admission.admitNext("),
                      "nothing admits the next run, so a queued run waits forever")
        XCTAssertTrue(code.contains("admission.releaseAll("),
                      "cancelling a conversation leaves its waiters parked")
        XCTAssertTrue(code.contains(".thinking(.queued)"),
                      "a parked run never says so on screen — it shows the ordinary thinking "
                      + "indicator and reads as a stalled app")

        // ⚠️ SETTING the label is half the job. Nothing else re-sets `agentState` between
        // admission and the executor's first event, so without the clear an admitted run keeps
        // claiming to be queued WHILE IT IS WORKING — the same class of lie, pointing the other
        // way. Mutation deleting this line left every gate test green, because the gate is not
        // what owns it.
        guard let queuedAt = code.range(of: ".thinking(.queued)"),
              let clearedAt = code.range(of: "waited { agentMessage.agentState = .thinking(.reasoning) }")
        else {
            return XCTFail("the queued label is set but never cleared — an admitted run keeps "
                           + "showing 'Waiting its turn' until its first executor event")
        }
        XCTAssertLessThan(queuedAt.lowerBound, clearedAt.lowerBound,
                          "the label must be cleared AFTER admission, not before")
    }

    /// ⚠️ Ordering, pinned structurally: `admitNext` must come AFTER the finishing run leaves
    /// `activeStreams`, or the run it admits sees a conversation that still looks occupied, parks
    /// again, and nothing is left to wake it. A behavioural test cannot see this — the wrong order
    /// simply hangs.
    func testTheNextRunIsAdmittedAfterTheFinishedOneLeavesTheLiveSet() throws {
        let source = try sourceFile("Devgentic/Core/Utils/ActiveStreamManager.swift")
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        guard let removal = code.range(of: "activeStreams.removeValue(forKey: message.id)") else {
            return XCTFail("the stream removal moved — this guard is checking nothing")
        }
        guard let admit = code.range(of: "admission.admitNext(") else {
            return XCTFail("admitNext is not called on the finish path")
        }
        XCTAssertLessThan(removal.lowerBound, admit.lowerBound,
                          "admitNext runs BEFORE the finishing run leaves activeStreams — the run "
                          + "it admits re-parks and the conversation deadlocks")
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return source
    }
}
