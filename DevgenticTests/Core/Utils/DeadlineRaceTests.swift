// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeadlineRaceTests.swift
//  DevgenticTests
//
//  The race that RETURNS AT ITS LIMIT (HITL Waiting Contract §6.3). The work under test is
//  deliberately NON-cancellable — a `Task.sleep` body would pass against the old task-group race
//  too, which is exactly how `PerToolTimeoutTests` stayed green while the bound held for 4 s (P1).
//

import XCTest
@testable import devgentic

final class DeadlineRaceTests: XCTestCase {

    /// Resumes after `seconds` on a GCD thread and ignores cancellation — the shape of a process
    /// wait, a blocking syscall or an MCP request.
    private func nonCancellable(_ seconds: Double, returning value: String = "done") async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume(returning: value) }
        }
    }

    func testWorkInsideTheLimitFinishes() async throws {
        let outcome = try await DeadlineRace.run(limit: 5, stopGrace: 1) { "fast" }
        guard case .finished(.success(let value)) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(value, "fast")
    }

    /// THE CONTRACT: work that ignores cancellation does not hold the race past limit + grace.
    func testNonCancellableWorkDoesNotHoldTheRace() async throws {
        let start = ContinuousClock.now
        let outcome = try await DeadlineRace.run(limit: 0.3, stopGrace: 0.2) {
            await self.nonCancellable(3)
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(1500),
                          "the race waited \(elapsed) for work that ignores cancellation — a bound that holds is not a bound")
        guard case .timedOut(let measured, let afterStop) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertNil(afterStop, "the work was still running, so nothing came back within the grace")
        XCTAssertGreaterThanOrEqual(measured, 0.29)
    }

    /// Work that answers cancellation with what it had is kept — the shell's partial-output path.
    func testWorkThatStopsOnCancellationHandsBackItsResult() async throws {
        let outcome = try await DeadlineRace.run(limit: 0.2, stopGrace: 2) { () async throws -> String in
            do { try await Task.sleep(for: .seconds(10)) } catch { return "partial" }
            return "full"
        }
        guard case .timedOut(_, .success(let value)?) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(value, "partial")
    }

    /// Stop: a cancelled caller returns at once, even while the work ignores cancellation.
    func testCallerCancellationReturnsPromptly() async {
        let start = ContinuousClock.now
        let task = Task {
            try await DeadlineRace.run(limit: 60, stopGrace: 5) { await self.nonCancellable(3) }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1500))
        guard case .failure(let error) = result, error is CancellationError else {
            return XCTFail("a cancelled caller must get CancellationError, got \(result)")
        }
    }

    func testAThrowingWorkIsReportedAsFinished() async throws {
        struct Boom: Error {}
        let outcome = try await DeadlineRace.run(limit: 5, stopGrace: 1) { () async throws -> String in throw Boom() }
        guard case .finished(.failure(let error)) = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertTrue(error is Boom)
    }
}
