// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalInferenceConfirmationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class LocalInferenceConfirmationTests: XCTestCase {

    private var clock: LIClock!
    private var started: [Task<Void, Never>] = []
    private let budget: UInt64 = 16 << 30

    override func setUp() async throws { clock = LIClock() }
    override func tearDown() async throws { started.forEach { $0.cancel() }; started = [] }

    final class OutcomeBox { var value: LocalInferenceCoordinator.AcquireOutcome? }
    final class Events {
        var asked: [(concerns: [RunConcern], deadline: Date)] = []
        var confirmed = 0
        var held: [Int] = []
        var positions: [Int] = []
        var waitEnded = 0
    }

    private func makeCoordinator(timeout: TimeInterval = 60) -> LocalInferenceCoordinator {
        let clock = clock!
        let budget = budget
        return LocalInferenceCoordinator(mode: .enforce, now: { clock.now }, budgetBytes: { budget }, agingInterval: 300,
                                         beginQueueWait: { _ in }, endQueueWait: { _ in },
                                         residency: RecordingResidency(), confirmationTimeout: timeout)
    }

    private func oversized(attended: Bool = true) -> InferenceRunManifest {
        LIFixtures.manifest(origin: attended ? .composer : .scheduled, attended: attended, models: [LIFixtures.mlxQwen],
                            footprints: [LIFixtures.mlxQwen.residencyKey: budget * 2])
    }

    private func plain(_ model: ModelRequirement = LIFixtures.mlxLlama) -> InferenceRunManifest {
        LIFixtures.manifest(models: [model])
    }

    private func start(_ c: LocalInferenceCoordinator, _ m: InferenceRunManifest, events: Events = Events())
    -> (task: Task<Void, Never>, box: OutcomeBox) {
        let box = OutcomeBox()
        let task = Task { @MainActor in
            box.value = await c.acquire(m, observer: LocalWaitObserver(
                onHold: { position, _ in events.held.append(position) },
                onWaitEnded: { _ in events.waitEnded += 1 },
                onConfirmationNeeded: { concerns, deadline in events.asked.append((concerns, deadline)) },
                onConfirmed: { events.confirmed += 1 },
                onPositionChanged: { position, _ in events.positions.append(position) }))
        }
        started.append(task)
        return (task, box)
    }

    private func eventually(_ seconds: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: - Asked, not refused

    func testAnAttendedRunWithAConcernIsHeldAndAsked() async {
        let c = makeCoordinator()
        let events = Events()
        let run = oversized()
        let (_, box) = start(c, run, events: events)
        let asked = await eventually { !events.asked.isEmpty }
        XCTAssertTrue(asked, "the surface must be told to ask")
        XCTAssertEqual(events.asked.first?.concerns, [.memory(modelID: "qwen", estimatedBytes: budget * 2, budgetBytes: budget)])
        XCTAssertEqual(events.asked.first?.deadline, clock.now.addingTimeInterval(60))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(box.value, "a held run does not start before its user answers")
        XCTAssertNil(c.lock.holder, "nor does it take the lock meanwhile")
        XCTAssertEqual(c.runsAwaitingConfirmation, [run.runID])
    }

    /// While it waits for the answer it blocks nobody: a run arriving after it starts at once.
    func testARunBeingAskedAboutBlocksNobody() async {
        let c = makeCoordinator()
        let events = Events()
        _ = start(c, oversized(), events: events)
        _ = await eventually { !events.asked.isEmpty }
        let other = plain()
        let outcome = await c.acquire(other)
        XCTAssertEqual(outcome, .admitted(waited: 0))
        XCTAssertEqual(c.lock.holder, other.runID)
    }

    // MARK: - Proceed

    func testProceedWithTheLockFreeStartsAtOnce() async {
        let c = makeCoordinator()
        let events = Events()
        let run = oversized()
        let (_, box) = start(c, run, events: events)
        _ = await eventually { !events.asked.isEmpty }
        clock.advance(7)
        XCTAssertTrue(c.proceed(runID: run.runID))
        let returned = await eventually(2) { box.value != nil }
        XCTAssertTrue(returned, "acquire must return")
        XCTAssertEqual(box.value, .admitted(waited: 7))
        XCTAssertEqual(c.lock.holder, run.runID)
        XCTAssertEqual(events.confirmed, 1)
        XCTAssertTrue(c.runsAwaitingConfirmation.isEmpty)
    }

    /// Proceed while another run holds the lock: it waits its turn — from the place it ARRIVED at, so
    /// a run that came after it while it was being asked is still behind it.
    func testProceedWhileTheLockIsHeldWaitsFromItsOriginalPlace() async {
        let c = makeCoordinator()
        let holder = plain(ModelRequirement(engine: .mlx, modelID: "holder", role: .primary))
        _ = await c.acquire(holder)

        let events = Events()
        let run = oversized()
        let (_, box) = start(c, run, events: events)
        _ = await eventually { !events.asked.isEmpty }

        clock.advance(5)
        let later = plain()
        let laterEvents = Events()
        _ = start(c, later, events: laterEvents)
        _ = await eventually { !laterEvents.held.isEmpty }
        XCTAssertEqual(laterEvents.held, [1], "while the first is being asked, the later run is first in line")

        XCTAssertTrue(c.proceed(runID: run.runID))
        XCTAssertEqual(events.held, [1], "Proceed puts it back at the place it arrived at — ahead of the later run")
        let moved = await eventually { laterEvents.positions == [2] }
        XCTAssertTrue(moved, "the later run is told it moved back: \(laterEvents.positions)")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(box.value, "it waits for the holder")

        c.unregister(runID: holder.runID)
        let returned = await eventually(2) { box.value != nil }
        XCTAssertTrue(returned, "acquire must return")
        XCTAssertEqual(box.value, .admitted(waited: 5))
        XCTAssertEqual(c.lock.holder, run.runID)
        let promoted = await eventually { laterEvents.positions.last == 1 }
        XCTAssertTrue(promoted, "and the later run is told it is now next: \(laterEvents.positions)")
    }

    func testALateProceedIsIgnored() async {
        let c = makeCoordinator()
        XCTAssertFalse(c.proceed(runID: UUID()))
    }

    // MARK: - No answer

    /// Owner, 2026-10-08: with no answer the run is AUTO-DENIED — never started.
    func testNoAnswerAutoDeniesTheRun() async {
        let c = makeCoordinator(timeout: 0.2)
        let events = Events()
        let run = oversized()
        let (_, box) = start(c, run, events: events)
        let returned = await eventually(3) { box.value != nil }
        XCTAssertTrue(returned, "acquire must return")
        XCTAssertEqual(box.value, .denied(.notConfirmed(concerns: [.memory(modelID: "qwen", estimatedBytes: budget * 2, budgetBytes: budget)],
                                                        after: 0.2)))
        XCTAssertTrue(c.lock.isIdle)
        XCTAssertTrue(c.runsAwaitingConfirmation.isEmpty)
        XCTAssertEqual(events.waitEnded, 1, "the surface is told the wait ended, so the banner goes")
        XCTAssertFalse(c.proceed(runID: run.runID), "a Proceed after the auto-deny does nothing")
    }

    // MARK: - Stop

    func testStopWhileAskedWithdrawsAndNeverAutoDenies() async {
        let c = makeCoordinator(timeout: 0.3)
        let events = Events()
        let run = oversized()
        let (task, box) = start(c, run, events: events)
        _ = await eventually { !events.asked.isEmpty }
        task.cancel()
        let returned = await eventually(2) { box.value != nil }
        XCTAssertTrue(returned, "acquire must return")
        XCTAssertEqual(box.value, .cancelled)
        XCTAssertTrue(c.runsAwaitingConfirmation.isEmpty)
        XCTAssertNil(c.manifest(for: run.runID), "a run stopped before it started is forgotten")
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(c.lock.isIdle, "its timer died with it")
    }

    // MARK: - Nobody watching

    func testAnUnattendedRunWithAConcernRunsWithoutAsking() async {
        let c = makeCoordinator()
        let events = Events()
        let (_, box) = start(c, oversized(attended: false), events: events)
        let returned = await eventually(2) { box.value != nil }
        XCTAssertTrue(returned, "acquire must return")
        XCTAssertEqual(box.value, .admitted(waited: 0))
        XCTAssertTrue(events.asked.isEmpty)
    }

    // MARK: - Live position

    /// Every waiting run hears when the line moves.
    func testWaitingRunsAreToldWhenTheLineMoves() async {
        let c = makeCoordinator()
        let holder = plain(ModelRequirement(engine: .mlx, modelID: "holder", role: .primary))
        _ = await c.acquire(holder)
        let first = Events(), second = Events()
        _ = start(c, plain(), events: first)
        _ = await eventually { !first.held.isEmpty }
        clock.advance(1)
        _ = start(c, plain(LIFixtures.mlxQwen), events: second)
        _ = await eventually { !second.held.isEmpty }
        XCTAssertEqual(second.held, [2])

        c.unregister(runID: holder.runID)
        let moved = await eventually { second.positions == [1] }
        XCTAssertTrue(moved, "number 2 is told it is now number 1: \(second.positions)")
    }
}
