// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalInferenceCoordinatorTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class LocalInferenceCoordinatorTests: XCTestCase {

    private var clock: LIClock!
    private var coordinator: LocalInferenceCoordinator!

    override func setUp() async throws {
        clock = LIClock()
        let clock = clock!
        coordinator = LocalInferenceCoordinator(mode: .shadow, now: { clock.now }, budgetBytes: { 16 << 30 }, agingInterval: 300,
                                                beginQueueWait: { _ in }, endQueueWait: { _ in })
    }

    private func local(_ model: ModelRequirement = LIFixtures.mlxQwen, origin: RunOrigin = .composer,
                       attended: Bool = true) -> InferenceRunManifest {
        LIFixtures.manifest(origin: origin, attended: attended, models: [model])
    }

    func testTheFirstLocalRunHoldsTheLock() {
        let a = local()
        XCTAssertEqual(coordinator.register(a), .admit(.lockFree))
        XCTAssertEqual(coordinator.lock.holder, a.runID)
    }

    func testACloudRunNeverTouchesTheLock() {
        let holder = local()
        coordinator.register(holder)
        let cloud = LIFixtures.manifest(models: [LIFixtures.claude])
        XCTAssertEqual(coordinator.register(cloud), .admit(.noLocalModel))
        XCTAssertEqual(coordinator.lock, LocalLockState(holder: holder.runID))
        XCTAssertNil(coordinator.unregister(runID: cloud.runID))
        XCTAssertEqual(coordinator.lock.holder, holder.runID, "a cloud run ending must not release a local holder")
    }

    func testASecondLocalRunWouldWaitAndIsAdmittedWhenTheHolderEnds() {
        let a = local()
        let b = local(LIFixtures.mlxLlama)
        coordinator.register(a)
        XCTAssertEqual(coordinator.register(b), .hold(behind: a.runID, position: 1))
        XCTAssertEqual(coordinator.lock.queue.map(\.runID), [b.runID])

        clock.advance(40)
        XCTAssertEqual(coordinator.unregister(runID: a.runID), b.runID)
        XCTAssertEqual(coordinator.lock, LocalLockState(holder: b.runID))
    }

    func testTheLockPassesByPriorityNotArrival() {
        let holder = local()
        let scheduled = local(origin: .scheduled, attended: false)
        let typed = local(origin: .composer)
        coordinator.register(holder)
        coordinator.register(scheduled)
        clock.advance(1)
        coordinator.register(typed)
        XCTAssertEqual(coordinator.unregister(runID: holder.runID), typed.runID)
        XCTAssertEqual(coordinator.unregister(runID: typed.runID), scheduled.runID)
    }

    /// In shadow mode a "waiting" run is really running; it can finish before the holder does.
    func testARunThatEndsWhileWaitingLeavesTheQueueAndKeepsTheHolder() {
        let a = local()
        let b = local()
        coordinator.register(a)
        coordinator.register(b)
        XCTAssertNil(coordinator.unregister(runID: b.runID))
        XCTAssertEqual(coordinator.lock, LocalLockState(holder: a.runID))
    }

    func testUnregisterIsIdempotentAndUnknownRunsAreNoOps() {
        let a = local()
        coordinator.register(a)
        coordinator.unregister(runID: a.runID)
        XCTAssertNil(coordinator.unregister(runID: a.runID))
        XCTAssertNil(coordinator.unregister(runID: UUID()))
        XCTAssertTrue(coordinator.lock.isIdle)
        XCTAssertNil(coordinator.manifest(for: a.runID), "an ended run's manifest must not outlive it")
    }

    /// A second registration of the same run would queue it behind ITSELF.
    func testRegisteringTwiceKeepsTheFirstDecision() {
        let a = local()
        XCTAssertEqual(coordinator.register(a), .admit(.lockFree))
        XCTAssertEqual(coordinator.register(a), .admit(.lockFree))
        XCTAssertTrue(coordinator.lock.queue.isEmpty)
    }

    func testADeniedRunTakesNoPlaceInTheLock() {
        let a = LIFixtures.manifest(shape: .delegating, models: [LIFixtures.mlxQwen])
        XCTAssertEqual(coordinator.register(a), .deny(.subAgentsUnsupportedLocally))
        XCTAssertTrue(coordinator.lock.isIdle)
    }

    func testAWaitingRunGeneratingIsReportedAsACollisionOnce() {
        let a = local()
        let b = local(LIFixtures.mlxLlama)
        coordinator.register(a)
        coordinator.register(b)
        let before = coordinator.lock
        XCTAssertEqual(coordinator.noteLocalUse(runID: b.runID, engine: .mlx, modelID: "llama"), [.collision])
        XCTAssertEqual(coordinator.noteLocalUse(runID: b.runID, engine: .mlx, modelID: "llama"), [],
                       "reported once per run and model, not once per generation")
        XCTAssertEqual(coordinator.noteLocalUse(runID: a.runID, engine: .mlx, modelID: "qwen"), [],
                       "the holder generating is the normal case")
        XCTAssertEqual(coordinator.lock, before, "use reports are evidence only; they never move the lock")
    }

    func testAModelTheManifestDidNotDeclareIsReported() {
        let a = local()
        coordinator.register(a)
        XCTAssertEqual(coordinator.noteLocalUse(runID: a.runID, engine: .mlx, modelID: "other"), [.undeclaredModel])
        XCTAssertEqual(coordinator.noteLocalUse(runID: a.runID, engine: .mlx, modelID: " qwen "), [],
                       "a declared model under another spelling is still declared")
    }

    func testUsesOutsideARunOrByAnEndedRunAreReported() {
        XCTAssertEqual(coordinator.noteLocalUse(runID: nil, engine: .mlx, modelID: "qwen"), [.outsideAnyRun])
        let a = local()
        coordinator.register(a)
        coordinator.unregister(runID: a.runID)
        XCTAssertEqual(coordinator.noteLocalUse(runID: a.runID, engine: .mlx, modelID: "qwen"), [.unregisteredRun])
    }

    /// The real wiring of the scope: a report made inside a task bound to a run reaches the
    /// coordinator attributed to that run.
    func testTheScopeCarriesTheRunIDIntoUnstructuredTasks() async {
        let runID = UUID()
        let seen = await LocalInferenceScope.$runID.withValue(runID) {
            await Task { LocalInferenceScope.runID }.value
        }
        XCTAssertEqual(seen, runID)
        XCTAssertNil(LocalInferenceScope.runID)
    }
}
