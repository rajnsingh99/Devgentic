// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  Phase 4: a run waiting on a human gives the local lock up, and takes it back — from the front of
//  the line, never interrupting the holder — at its next local generation.
//
//  ⚠️ Every wait is BOUNDED and every result is read from a box, never by awaiting the task: a broken
//  waiter hangs rather than fails, and an unbounded await turns that into a stuck test runner.
//

import XCTest
@testable import devgentic

@MainActor
final class LocalInferenceReleaseTests: XCTestCase {

    private var clock: LIClock!
    private var coordinator: LocalInferenceCoordinator!
    private var started: [Task<Void, Never>] = []

    override func setUp() async throws {
        clock = LIClock()
        let clock = clock!
        coordinator = LocalInferenceCoordinator(mode: .enforce, now: { clock.now }, budgetBytes: { 16 << 30 },
                                                agingInterval: 300, beginQueueWait: { _ in }, endQueueWait: { _ in })
    }

    override func tearDown() async throws {
        started.forEach { $0.cancel() }
        started = []
    }

    final class BoolBox { var value: Bool? }
    final class OutcomeBox { var value: LocalInferenceCoordinator.AcquireOutcome? }

    private func local(origin: RunOrigin = .composer, attended: Bool = true) -> InferenceRunManifest {
        LIFixtures.manifest(origin: origin, attended: attended, models: [LIFixtures.mlxQwen])
    }

    /// Starts a local generation for `runID` in its own task (a run's branch).
    private func startGeneration(_ runID: UUID) -> (task: Task<Void, Never>, done: XCTestExpectation, box: BoolBox) {
        let done = expectation(description: "generation gate returned for \(runID)")
        let box = BoolBox()
        let coordinator = coordinator!
        let task = Task { @MainActor in
            box.value = await coordinator.beginLocalGeneration(runID)
            done.fulfill()
        }
        started.append(task)
        return (task, done, box)
    }

    private func startAcquire(_ manifest: InferenceRunManifest, observer: LocalWaitObserver = LocalWaitObserver())
    -> (done: XCTestExpectation, box: OutcomeBox) {
        let done = expectation(description: "acquire returned for \(manifest.runID)")
        let box = OutcomeBox()
        let coordinator = coordinator!
        started.append(Task { @MainActor in
            box.value = await coordinator.acquire(manifest, observer: observer)
            done.fulfill()
        })
        return (done, box)
    }

    /// Lets queued main-actor work run until `condition` holds, for at most `seconds`.
    private func eventually(_ seconds: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func isQueued(_ runID: UUID) -> Bool { coordinator.lock.queue.contains { $0.runID == runID } }

    // MARK: - Release

    func testAParkedRunGivesTheLockToTheNextRun() async {
        let a = local()
        let b = local()
        _ = await coordinator.acquire(a)
        let (bDone, bBox) = startAcquire(b)
        let bQueued = await eventually { self.isQueued(b.runID) }
        XCTAssertTrue(bQueued)

        coordinator.parkBegan(runID: a.runID, operationID: UUID())
        await fulfillment(of: [bDone], timeout: 2)
        XCTAssertEqual(bBox.value, .admitted(waited: 0))
        XCTAssertEqual(coordinator.lock.holder, b.runID)
        XCTAssertTrue(coordinator.released.contains(a.runID))
    }

    /// A sibling branch still generating keeps the lock; it goes when that generation ends.
    func testAParkDuringAGenerationReleasesOnlyWhenTheGenerationEnds() async {
        let a = local()
        let b = local()
        _ = await coordinator.acquire(a)
        let generating = await coordinator.beginLocalGeneration(a.runID)
        XCTAssertTrue(generating)
        let (bDone, bBox) = startAcquire(b)
        _ = await eventually { self.isQueued(b.runID) }

        coordinator.parkBegan(runID: a.runID, operationID: UUID())
        XCTAssertEqual(coordinator.lock.holder, a.runID, "a branch is mid-generation — the lock must stay")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(bBox.value)

        coordinator.endLocalGeneration(a.runID)
        await fulfillment(of: [bDone], timeout: 2)
        XCTAssertEqual(coordinator.lock.holder, b.runID)
    }

    /// Both park events arrive as separate main-actor hops; an end seen first must cancel its begin.
    func testAParkEndSeenBeforeItsBeginIsNotLeftOpen() async {
        let a = local()
        _ = await coordinator.acquire(a)
        let op = UUID()
        coordinator.parkEnded(runID: a.runID, operationID: op)
        coordinator.parkBegan(runID: a.runID, operationID: op)
        XCTAssertEqual(coordinator.lock.holder, a.runID, "a park that already ended must not release the lock")
        XCTAssertFalse(coordinator.released.contains(a.runID))
    }

    /// An end for a run the coordinator does not know (it ended, or never registered) is not kept:
    /// `parkBegan` ignores such a run, so nothing would ever claim the entry.
    func testAParkEndForAnUnknownRunIsNotKept() async {
        coordinator.parkEnded(runID: UUID(), operationID: UUID())
        XCTAssertTrue(coordinator.parksEndedEarly.isEmpty)

        let a = local()
        _ = await coordinator.acquire(a)
        coordinator.unregister(runID: a.runID)
        coordinator.parkEnded(runID: a.runID, operationID: UUID())
        XCTAssertTrue(coordinator.parksEndedEarly.isEmpty, "a run that has ended keeps no early-end entry")
    }

    /// …while an early end for a run still registered IS kept, and claimed by its begin.
    func testAnEarlyEndForARegisteredRunIsKeptUntilItsBegin() async {
        let a = local()
        _ = await coordinator.acquire(a)
        let op = UUID()
        coordinator.parkEnded(runID: a.runID, operationID: op)
        XCTAssertEqual(coordinator.parksEndedEarly, [op])
        coordinator.parkBegan(runID: a.runID, operationID: op)
        XCTAssertTrue(coordinator.parksEndedEarly.isEmpty)
    }

    func testShadowModeIgnoresParks() async {
        let shadow = LocalInferenceCoordinator(mode: .shadow, beginQueueWait: { _ in }, endQueueWait: { _ in })
        let a = local()
        _ = await shadow.acquire(a)
        shadow.parkBegan(runID: a.runID, operationID: UUID())
        XCTAssertEqual(shadow.lock.holder, a.runID)
    }

    // MARK: - Take back

    /// ⚠️ The answer alone takes nothing back: the approved tool runs at once; only the next local
    /// generation waits. Taking the lock at the answer would make the answer wait for another run.
    func testTheAnswerAloneDoesNotTakeTheLockBack() async {
        let a = local()
        let b = local()
        _ = await coordinator.acquire(a)
        let op = UUID()
        coordinator.parkBegan(runID: a.runID, operationID: op)
        _ = await coordinator.acquire(b)
        coordinator.parkEnded(runID: a.runID, operationID: op)
        XCTAssertEqual(coordinator.lock.holder, b.runID)
        XCTAssertFalse(isQueued(a.runID))
    }

    func testTakingBackAFreeLockIsImmediate() async {
        let a = local()
        _ = await coordinator.acquire(a)
        let op = UUID()
        coordinator.parkBegan(runID: a.runID, operationID: op)
        XCTAssertNil(coordinator.lock.holder, "released with nobody waiting")
        coordinator.parkEnded(runID: a.runID, operationID: op)
        let held = await coordinator.beginLocalGeneration(a.runID)
        XCTAssertTrue(held)
        XCTAssertEqual(coordinator.lock.holder, a.runID)
        XCTAssertFalse(coordinator.released.contains(a.runID))
    }

    /// A run that already started goes back to the FRONT — ahead of an attended run that was waiting
    /// first — and the holder is never interrupted.
    func testATakeBackWaitsAtTheFrontWithoutInterruptingTheHolder() async {
        let a = local()
        let b = local()
        let c = local(origin: .composer)
        _ = await coordinator.acquire(a)
        let op = UUID()
        coordinator.parkBegan(runID: a.runID, operationID: op)
        _ = await coordinator.acquire(b)                       // b holds now
        let (cDone, cBox) = startAcquire(c)                    // c waits
        _ = await eventually { self.isQueued(c.runID) }
        clock.advance(10)
        coordinator.parkEnded(runID: a.runID, operationID: op)

        let (_, aDone, aBox) = startGeneration(a.runID)        // a wants the model again
        _ = await eventually { self.isQueued(a.runID) }
        XCTAssertEqual(coordinator.lock.holder, b.runID, "the holder is never interrupted")

        coordinator.unregister(runID: b.runID)
        await fulfillment(of: [aDone], timeout: 2)
        XCTAssertEqual(aBox.value, true)
        XCTAssertEqual(coordinator.lock.holder, a.runID, "the resumed run outranks a run that never started")
        XCTAssertNil(cBox.value)

        coordinator.unregister(runID: a.runID)
        await fulfillment(of: [cDone], timeout: 2)
    }

    /// Two branches of one run waiting to take the lock back share ONE place in line, and cancelling
    /// one of them never fails the other.
    func testCancellingOneWaitingBranchDoesNotFailItsSibling() async {
        let a = local()
        let b = local()
        _ = await coordinator.acquire(a)
        coordinator.parkBegan(runID: a.runID, operationID: UUID())
        _ = await coordinator.acquire(b)

        let (branch1, done1, box1) = startGeneration(a.runID)
        let (_, done2, box2) = startGeneration(a.runID)
        _ = await eventually { self.isQueued(a.runID) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(coordinator.lock.queue.filter { $0.runID == a.runID }.count, 1, "one place in line per run")

        branch1.cancel()
        await fulfillment(of: [done1], timeout: 2)
        XCTAssertEqual(box1.value, false)
        XCTAssertTrue(isQueued(a.runID), "the sibling is still waiting, so the run keeps its place")
        XCTAssertNil(box2.value)

        coordinator.unregister(runID: b.runID)
        await fulfillment(of: [done2], timeout: 2)
        XCTAssertEqual(box2.value, true)
        XCTAssertEqual(coordinator.lock.holder, a.runID)
    }

    /// A run whose manifest declared no local model still cannot generate locally without the lock.
    func testAnUndeclaredLocalUseTakesTheLockFirst() async {
        let a = local()
        let cloud = LIFixtures.manifest(models: [LIFixtures.claude])
        _ = await coordinator.acquire(a)
        _ = await coordinator.acquire(cloud)
        let (_, done, box) = startGeneration(cloud.runID)
        _ = await eventually { self.isQueued(cloud.runID) }
        XCTAssertNil(box.value, "it must wait for the holder")

        coordinator.unregister(runID: a.runID)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(box.value, true)
        XCTAssertEqual(coordinator.lock.holder, cloud.runID)
    }

    /// The run's observer hears about a take-back wait exactly as about its first wait.
    func testTheRunsObserverIsToldAboutATakeBackWait() async {
        var holds = 0
        var ends = 0
        let a = local()
        let b = local()
        _ = await coordinator.acquire(a, observer: LocalWaitObserver(onHold: { _, _ in holds += 1 },
                                                                     onWaitEnded: { _ in ends += 1 }))
        coordinator.parkBegan(runID: a.runID, operationID: UUID())
        _ = await coordinator.acquire(b)
        let (_, done, _) = startGeneration(a.runID)
        _ = await eventually { holds == 1 }
        XCTAssertEqual(holds, 1)
        coordinator.unregister(runID: b.runID)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(ends, 1)
    }

    /// A released run that ends leaves nothing behind.
    func testAReleasedRunThatEndsLeavesNoState() async {
        let a = local()
        let b = local()
        _ = await coordinator.acquire(a)
        coordinator.parkBegan(runID: a.runID, operationID: UUID())
        _ = await coordinator.acquire(b)
        coordinator.unregister(runID: a.runID)
        XCTAssertFalse(coordinator.released.contains(a.runID))
        XCTAssertEqual(coordinator.lock.holder, b.runID)
        let held = await coordinator.beginLocalGeneration(a.runID)
        XCTAssertTrue(held, "an unregistered run is not gated")
        XCTAssertEqual(coordinator.lock.holder, b.runID)
    }
}
