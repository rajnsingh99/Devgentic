// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  Phase 2: the lock is enforced — a local run that finds it taken WAITS, and starts when it passes.
//
//  ⚠️ Every wait here is BOUNDED. A broken waiter does not fail, it hangs; an unbounded `await` would
//  turn every interesting mutant into a stuck test runner instead of a red test.
//

import XCTest
@testable import devgentic

@MainActor
final class LocalInferenceEnforcementTests: XCTestCase {

    private var clock: LIClock!
    private var credits: CreditLog!

    /// Records the queue-wait credit calls the coordinator makes.
    final class CreditLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _begun: [UUID] = []
        private var _ended: [UUID] = []
        var begun: [UUID] { lock.withLock { _begun } }
        var ended: [UUID] { lock.withLock { _ended } }
        func begin(_ id: UUID) { lock.withLock { _begun.append(id) } }
        func end(_ id: UUID) { lock.withLock { _ended.append(id) } }
    }

    override func setUp() async throws {
        clock = LIClock()
        credits = CreditLog()
    }

    private func makeCoordinator(beginQueueWait: (@Sendable (UUID) async -> Void)? = nil) -> LocalInferenceCoordinator {
        let clock = clock!
        let credits = credits!
        return LocalInferenceCoordinator(
            mode: .enforce, now: { clock.now }, budgetBytes: { 16 << 30 }, agingInterval: 300,
            beginQueueWait: beginQueueWait ?? { credits.begin($0) },
            endQueueWait: { credits.end($0) })
    }

    private func local(_ model: ModelRequirement = LIFixtures.mlxQwen, origin: RunOrigin = .composer) -> InferenceRunManifest {
        LIFixtures.manifest(origin: origin, models: [model])
    }

    /// The outcome an `acquire` task delivered, if it returned. Read AFTER a bounded fulfillment —
    /// never by awaiting the task, which turns a waiter that never resumes into a hung runner.
    final class OutcomeBox { var value: LocalInferenceCoordinator.AcquireOutcome? }

    private var started: [Task<Void, Never>] = []

    override func tearDown() async throws {
        started.forEach { $0.cancel() }   // releases any waiter a failing test left parked
        started = []
    }

    /// Starts `acquire` in a task; `done` is fulfilled when it returns, `box` holds what it returned.
    private func startAcquire(_ coordinator: LocalInferenceCoordinator, _ manifest: InferenceRunManifest,
                              held: XCTestExpectation? = nil)
    -> (task: Task<Void, Never>, done: XCTestExpectation, box: OutcomeBox) {
        let done = expectation(description: "acquire returned for \(manifest.runID)")
        let box = OutcomeBox()
        let task = Task { @MainActor in
            box.value = await coordinator.acquire(manifest, observer: LocalWaitObserver(onHold: { _, _ in held?.fulfill() }))
            done.fulfill()
        }
        started.append(task)
        return (task, done, box)
    }

    /// Asserts a started acquire has NOT returned after a short grace period.
    private func assertStillWaiting(_ box: OutcomeBox, _ what: String,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(box.value, "\(what) returned while it should still be waiting", file: file, line: line)
    }

    // MARK: - Admit without waiting

    func testAFreeLockAdmitsAtOnceWithoutCallingOnHold() async {
        let coordinator = makeCoordinator()
        var heldCalled = false
        let outcome = await coordinator.acquire(local(), observer: LocalWaitObserver(onHold: { _, _ in heldCalled = true }))
        XCTAssertEqual(outcome, .admitted(waited: 0))
        XCTAssertFalse(heldCalled, "onHold is only for a run that actually waits")
        XCTAssertTrue(credits.begun.isEmpty, "no wait, no credit")
    }

    func testACloudRunNeverWaitsWhileALocalRunHoldsTheLock() async {
        let coordinator = makeCoordinator()
        _ = await coordinator.acquire(local())
        let outcome = await coordinator.acquire(LIFixtures.manifest(models: [LIFixtures.claude]))
        XCTAssertEqual(outcome, .admitted(waited: 0))
    }

    func testADeniedRunReturnsTheReasonAndHoldsNothing() async {
        let coordinator = makeCoordinator()
        let outcome = await coordinator.acquire(LIFixtures.manifest(shape: .delegating, models: [LIFixtures.mlxQwen]))
        XCTAssertEqual(outcome, .denied(.subAgentsUnsupportedLocally))
        XCTAssertTrue(coordinator.lock.isIdle)
    }

    /// ⚠️ Regression (device, 2026-10-08): a run whose model is estimated far above the budget is
    /// never refused outright. Nobody is watching this one, so it runs without asking (owner); an
    /// attended run is ASKED — `LocalInferenceConfirmationTests`.
    func testAnUnattendedRunEstimatedAboveTheBudgetIsAdmittedNotDenied() async {
        let coordinator = makeCoordinator()
        let outcome = await coordinator.acquire(LIFixtures.manifest(origin: .scheduled, attended: false, models: [LIFixtures.mlxQwen],
                                                                    footprints: [LIFixtures.mlxQwen.residencyKey: 20 << 30]))
        XCTAssertEqual(outcome, .admitted(waited: 0))
        XCTAssertTrue(coordinator.runsAwaitingConfirmation.isEmpty)
    }

    // MARK: - Waiting

    func testASecondLocalRunWaitsUntilTheHolderEnds() async {
        let coordinator = makeCoordinator()
        let a = local()
        let b = local(LIFixtures.mlxLlama)
        _ = await coordinator.acquire(a)

        let held = expectation(description: "b is told it waits")
        let (_, done, box) = startAcquire(coordinator, b, held: held)
        await fulfillment(of: [held], timeout: 2)
        XCTAssertEqual(coordinator.lock.queue.map(\.runID), [b.runID], "b is in line, not running")

        // b must NOT have returned yet — a waiter that resumes early is the defect.
        await assertStillWaiting(box, "b")

        clock.advance(42)
        coordinator.unregister(runID: a.runID)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(box.value, .admitted(waited: 42))
        XCTAssertEqual(coordinator.lock.holder, b.runID)
        XCTAssertEqual(credits.begun.count, 1)
        XCTAssertEqual(credits.begun, credits.ended, "the queue-wait credit is begun and ended with the same id")
    }

    func testCancellingAWaitingRunWithdrawsItAndKeepsTheHolder() async {
        let coordinator = makeCoordinator()
        let a = local()
        let b = local()
        _ = await coordinator.acquire(a)
        let held = expectation(description: "b waits")
        let (task, done, box) = startAcquire(coordinator, b, held: held)
        await fulfillment(of: [held], timeout: 2)

        task.cancel()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(box.value, .cancelled)
        XCTAssertEqual(coordinator.lock, LocalLockState(holder: a.runID), "a withdrawn run leaves the line; the holder is untouched")
        XCTAssertNil(coordinator.manifest(for: b.runID))
        XCTAssertEqual(credits.ended.count, 1, "a withdrawn wait still ends its credit")
    }

    /// ⚠️ THE LOST-WAKEUP WINDOW. The run awaits an actor (the queue-wait credit) between deciding to
    /// wait and suspending. A release landing in that window must still admit it.
    func testAReleaseBeforeTheWaiterSuspendsIsNotLost() async {
        let a = local()
        let b = local()
        final class Box: @unchecked Sendable { var coordinator: LocalInferenceCoordinator? }
        let box = Box()
        let coordinator = makeCoordinator(beginQueueWait: { _ in
            await MainActor.run { _ = box.coordinator?.unregister(runID: a.runID) }
        })
        box.coordinator = coordinator
        _ = await coordinator.acquire(a)
        let (_, done, result) = startAcquire(coordinator, b)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(result.value, .admitted(waited: 0))
        XCTAssertEqual(coordinator.lock.holder, b.runID)
    }

    /// The lock passes in priority order, and only the run it passes to wakes.
    func testOnlyTheRunTheLockPassesToWakes() async {
        let coordinator = makeCoordinator()
        let holder = local()
        let scheduled = LIFixtures.manifest(origin: .scheduled, attended: false, models: [LIFixtures.mlxQwen])
        let typed = local(origin: .composer)
        _ = await coordinator.acquire(holder)

        let heldS = expectation(description: "scheduled waits")
        let (_, sDone, sBox) = startAcquire(coordinator, scheduled, held: heldS)
        await fulfillment(of: [heldS], timeout: 2)
        let heldT = expectation(description: "typed waits")
        let (_, tDone, tBox) = startAcquire(coordinator, typed, held: heldT)
        await fulfillment(of: [heldT], timeout: 2)

        coordinator.unregister(runID: holder.runID)
        await fulfillment(of: [tDone], timeout: 2)
        XCTAssertEqual(tBox.value, .admitted(waited: 0), "the attended run outranks the scheduled one")
        await assertStillWaiting(sBox, "the scheduled run")

        coordinator.unregister(runID: typed.runID)
        await fulfillment(of: [sDone], timeout: 2)
        XCTAssertEqual(sBox.value, .admitted(waited: 0))
    }

    /// Withdrawing a run the lock has ALREADY passed to must not strand the lock: the run proceeds
    /// and releases it through its own end.
    func testWithdrawingTheNewHolderIsANoOp() async {
        let coordinator = makeCoordinator()
        let a = local()
        let b = local()
        _ = await coordinator.acquire(a)
        let held = expectation(description: "b waits")
        let (_, done, box) = startAcquire(coordinator, b, held: held)
        await fulfillment(of: [held], timeout: 2)

        coordinator.unregister(runID: a.runID)
        coordinator.withdraw(runID: b.runID)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(box.value, .admitted(waited: 0))
        XCTAssertEqual(coordinator.lock.holder, b.runID)
        XCTAssertNotNil(coordinator.manifest(for: b.runID), "the holder's record must survive a late withdraw")
    }

    // MARK: - Shadow mode stays a non-blocking kill switch

    func testShadowModeNeverWaitsOrDenies() async {
        let coordinator = LocalInferenceCoordinator(mode: .shadow, beginQueueWait: { _ in }, endQueueWait: { _ in })
        _ = await coordinator.acquire(local())
        let second = await coordinator.acquire(local())
        let delegating = await coordinator.acquire(LIFixtures.manifest(shape: .delegating, models: [LIFixtures.mlxQwen]))
        XCTAssertEqual(second, .admitted(waited: 0))
        XCTAssertEqual(delegating, .admitted(waited: 0))
    }

    func testTheTestHostDefaultsTheSharedInstanceToShadow() {
        XCTAssertEqual(LocalInferenceCoordinator.Mode.configured, .shadow,
                       "a run one test leaves unfinished must never hold a process-wide lock that hangs later tests")
    }

    // MARK: - What the user is told

    func testTheQueueNoticeNamesTheHolderAndThePosition() {
        let holder = LIFixtures.manifest(models: [LIFixtures.mlxQwen, LIFixtures.claude])
        XCTAssertEqual(ActiveStreamManager.localQueueNotice(holder: holder, holderTitle: "Release notes", position: 1),
                       "The local model (qwen) is in use by a run in “Release notes”. This run is next in line and starts by itself when that run finishes.")
        XCTAssertEqual(ActiveStreamManager.localQueueNotice(holder: nil, holderTitle: "  ", position: 3),
                       "The local model is in use by a run in another conversation. This run is number 3 in line and starts by itself when that run finishes.")
    }
}

/// The queue-wait credit pauses a run's own time bounds — and only those — like a HITL park.
final class LocalQueueWaitCreditTests: XCTestCase {

    func testAQueueWaitPausesTheCallersBoundsWithoutCountingAsAPark() async throws {
        let service = ExecutionSuspensionService.shared
        let conversation = UUID()
        let scope = UUID()
        let other = UUID()
        await service.registerScope(scope, conversationID: conversation, attended: true)
        await service.registerScope(other, conversationID: conversation, attended: true)
        let parkedBefore = await service.cumulativeParkedTime(for: conversation)

        let wait = UUID()
        await ParkScope.$chain.withValue([scope]) { await service.beginQueueWait(wait) }
        let pausedDuring = await service.isParked(scope: scope)
        let otherPaused = await service.isParked(scope: other)
        try await Task.sleep(for: .milliseconds(50))
        await service.endQueueWait(wait)

        XCTAssertTrue(pausedDuring, "the waiting run's bound must not time out while it is in line")
        XCTAssertFalse(otherPaused, "another bound in the conversation is not paused by this run's wait")
        let credited = await service.parkedTime(forScope: scope)
        XCTAssertGreaterThan(credited, 0.04)
        let stillPaused = await service.isParked(scope: scope)
        XCTAssertFalse(stillPaused)
        let parkedAfter = await service.cumulativeParkedTime(for: conversation)
        XCTAssertEqual(parkedAfter, parkedBefore, "a queue wait is not a park — nobody is waiting on a human")

        await service.endQueueWait(wait)   // idempotent
        await service.unregisterScope(scope)
        await service.unregisterScope(other)
    }
}
