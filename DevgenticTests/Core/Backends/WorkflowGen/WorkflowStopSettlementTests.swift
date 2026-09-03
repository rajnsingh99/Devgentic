//
//  WorkflowStopSettlementTests.swift
//  DevgenticTests
//
//  Created on 31/08/26.
//
//  Register EXC-1: Stop during a profile node recorded it `.completed` with truncated output.
//
//  ⚠️ Tested as a PURE FUNCTION because the behaviour is structurally unobservable through the
//  integration harness: cancelling the task that consumes the run's stream races the terminal
//  event's own delivery and always wins (the WF-CC1 note in `WorkflowExecutorIntegrationTests`
//  records an earlier attempt failing with both event arrays empty). `UserSkipTeardownPolicy` set
//  the precedent; `WorkflowExecutor.settledStreamEndStatus` follows it, and these tests are the
//  exhaustive coverage that extraction exists to make possible.
//

import XCTest
@testable import devgentic

final class WorkflowStopSettlementTests: XCTestCase {

    // MARK: - Rule 1: the demotion

    /// ⚠️ THE FILED BUG. A cancelled consumer of an `AsyncThrowingStream` gets `nil` from `next()`
    /// rather than a throw, so on Stop the stream child returns normally with no terminal outcome —
    /// and the `.completed` default stuck: the node was traced, counted and persisted as a SUCCESS
    /// holding whatever partial output had streamed before the user pressed Stop.
    func testStoppedStreamWithNoTerminalOutcomeSettlesCanceled() {
        let settled = WorkflowExecutor.settledStreamEndStatus(
            current: .completed, hadTerminalOutcome: false, taskCancelled: true)

        guard case .canceled = settled else {
            return XCTFail("a stream ended by Stop must settle .canceled, got \(settled) — "
                           + "the .completed default is a lie the run record then persists")
        }
    }

    // MARK: - Rule 2: an explicit terminal outcome is the authority

    /// An inner run that reported its terminal outcome BEFORE Stop landed genuinely finished —
    /// demoting it would discard a real answer over a cancellation that arrived too late to matter.
    /// Mirrors the sub-workflow arm's `case nil where Task.isCancelled`.
    func testAnExplicitTerminalOutcomeSurvivesCancellation() {
        let settled = WorkflowExecutor.settledStreamEndStatus(
            current: .completed, hadTerminalOutcome: true, taskCancelled: true)

        guard case .completed = settled else {
            return XCTFail("an explicit terminal outcome is the authority even under cancellation, got \(settled)")
        }
    }

    // MARK: - Rule 3: only the `.completed` default is ever touched

    /// A `.failed` that raced Stop stays failed: the failure is real, and `.failed` is what keeps
    /// it retryable and routes its error port. Rewriting it to `.canceled` would suppress both.
    func testAFailureThatRacedStopStaysFailed() {
        let failure = NodeExecutionStatus.failed(.modelError(provider: "x", error: "boom"))
        let settled = WorkflowExecutor.settledStreamEndStatus(
            current: failure, hadTerminalOutcome: false, taskCancelled: true)

        guard case .failed = settled else {
            return XCTFail("a real failure must not be relabelled by cancellation, got \(settled)")
        }
    }

    /// Idempotence: an already-`.canceled` status passes through unchanged.
    func testAnAlreadyCanceledStatusIsUntouched() {
        let settled = WorkflowExecutor.settledStreamEndStatus(
            current: .canceled, hadTerminalOutcome: false, taskCancelled: true)
        guard case .canceled = settled else { return XCTFail("got \(settled)") }
    }

    /// A user-skip settlement must survive too — `UserSkipTeardownPolicy` already decided it.
    func testASettledUserSkipIsUntouched() {
        let settled = WorkflowExecutor.settledStreamEndStatus(
            current: .skipped(reason: .byUser), hadTerminalOutcome: false, taskCancelled: true)
        guard case .skipped(reason: .byUser) = settled else { return XCTFail("got \(settled)") }
    }

    // MARK: - The control: no cancellation, no change

    /// The everyday path — a clean stream end with no terminal event legitimately stays
    /// `.completed`; that default existing is WHY the demotion must be gated on cancellation.
    func testACleanStreamEndStaysCompleted() {
        let settled = WorkflowExecutor.settledStreamEndStatus(
            current: .completed, hadTerminalOutcome: false, taskCancelled: false)

        guard case .completed = settled else {
            return XCTFail("an uncancelled clean stream end is a genuine success, got \(settled) — "
                           + "demoting it would cancel every healthy bot node")
        }
    }
}
