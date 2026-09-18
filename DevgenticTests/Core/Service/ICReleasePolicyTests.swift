// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ICReleasePolicyTests.swift
//  DevgenticTests
//
//  The IC model residency decision table. Pure — no MLX, no model load.
//
//  Two invariants matter more than any individual case:
//    1. Never free while a generation is in flight.
//    2. A turn's sequential IC features share ONE load (release is idle-debounced).
//

import XCTest
@testable import devgentic

final class ICReleasePolicyTests: XCTestCase {

    // MARK: - Invariant 1: never free under an in-flight generation

    /// The hazard this whole change exists to remove: one feature finishing must not free
    /// the model (or clear the GPU cache) while another is still generating.
    func testRequestRelease_WhileGenerationInFlight_DoesNotFree() {
        var policy = ICReleasePolicy()
        policy.beginLease() // feature A generating

        let action = policy.requestRelease() // feature B says it's done

        XCTAssertEqual(action, .none, "Must not free or even schedule while a generation is live")
        XCTAssertEqual(policy.activeLeases, 1)
    }

    /// Even a deliberate teardown (Core Intelligence switched off) must wait for the
    /// in-flight generation rather than yanking the model out from under it.
    func testRequestImmediateRelease_WhileGenerationInFlight_DefersRatherThanFreeing() {
        var policy = ICReleasePolicy()
        policy.beginLease()

        XCTAssertEqual(policy.requestImmediateRelease(), .none,
                       "Immediate teardown must still respect an active lease")

        // ...and frees as soon as that generation finishes — without the idle wait.
        XCTAssertEqual(policy.endLease(), .freeNow,
                       "A deferred immediate teardown skips the idle grace period")
    }

    /// Concurrent generations: the model is only releasable after the LAST one ends.
    func testMultipleLeases_FreesOnlyAfterTheLastEnds() {
        var policy = ICReleasePolicy()
        policy.beginLease()
        policy.beginLease()

        XCTAssertEqual(policy.requestRelease(), .none)
        XCTAssertEqual(policy.endLease(), .none, "One of two generations finished — still in use")
        XCTAssertEqual(policy.endLease(), .scheduleIdleRelease, "Last one out schedules the free")
    }

    /// endLease must never underflow into a state where a stray release frees the model
    /// while a real generation is running.
    func testEndLease_DoesNotUnderflow() {
        var policy = ICReleasePolicy()
        XCTAssertEqual(policy.endLease(), .none)
        XCTAssertEqual(policy.activeLeases, 0)

        policy.beginLease()
        XCTAssertEqual(policy.activeLeases, 1)
        XCTAssertEqual(policy.endLease(), .none, "No release was requested — stay resident")
    }

    // MARK: - Invariant 2: one load per turn

    /// The regression that made an immediate unload the wrong fix: within a turn the IC
    /// features run one after another, so a release followed by new demand must NOT have
    /// freed anything in between.
    func testReleaseThenNewDemand_CancelsPendingRelease() {
        var policy = ICReleasePolicy()

        // RAG query rewriting finishes.
        XCTAssertEqual(policy.requestRelease(), .scheduleIdleRelease)
        XCTAssertTrue(policy.releaseRequested)

        // History compaction starts before the idle timer elapses.
        policy.didLoad()

        XCTAssertFalse(policy.releaseRequested, "New demand must cancel the pending release")
        XCTAssertFalse(policy.shouldHonorElapsedIdleRelease,
                       "A timer that fires now must find nothing to do")
    }

    /// The timer elapsing is not enough on its own — state is re-checked at fire time.
    func testElapsedIdleRelease_NotHonoredWhileGenerationInFlight() {
        var policy = ICReleasePolicy()
        XCTAssertEqual(policy.requestRelease(), .scheduleIdleRelease)

        policy.beginLease() // a generation started while the timer slept

        XCTAssertFalse(policy.shouldHonorElapsedIdleRelease,
                       "Must not free a model that is back in use")
    }

    func testElapsedIdleRelease_HonoredWhenStillIdleAndRequested() {
        var policy = ICReleasePolicy()
        XCTAssertEqual(policy.requestRelease(), .scheduleIdleRelease)
        XCTAssertTrue(policy.shouldHonorElapsedIdleRelease)
    }

    /// Nobody asked for a release, so an elapsed timer must not free the model.
    func testElapsedIdleRelease_NotHonoredWithoutARequest() {
        let policy = ICReleasePolicy()
        XCTAssertFalse(policy.shouldHonorElapsedIdleRelease)
    }

    // MARK: - Post-free state

    func testDidFree_ClearsPendingState() {
        var policy = ICReleasePolicy()
        _ = policy.requestImmediateRelease()
        XCTAssertTrue(policy.releaseRequested)
        XCTAssertTrue(policy.immediateRequested)

        policy.didFree()

        XCTAssertFalse(policy.releaseRequested)
        XCTAssertFalse(policy.immediateRequested)
        XCTAssertFalse(policy.shouldHonorElapsedIdleRelease,
                       "A stale timer after a free must be inert")
    }

    /// Full turn: rewrite → compaction → synthesis, then idle. Exactly one free, at the end.
    func testTypicalTurn_ProducesASingleRelease() {
        var policy = ICReleasePolicy()
        var frees = 0

        for _ in 0..<3 { // three sequential IC features
            policy.didLoad()
            policy.beginLease()
            let endAction = policy.endLease()
            if endAction == .freeNow { frees += 1 }
            let releaseAction = policy.requestRelease()
            if releaseAction == .freeNow { frees += 1 }
        }

        XCTAssertEqual(frees, 0, "Nothing may be freed mid-turn — that was the 2-3 loads/turn bug")
        XCTAssertTrue(policy.shouldHonorElapsedIdleRelease,
                      "After the turn, the idle timer is free to release exactly once")
    }
}
