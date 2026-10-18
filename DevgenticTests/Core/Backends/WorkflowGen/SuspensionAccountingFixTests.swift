// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SuspensionAccountingFixTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class SuspensionAccountingFixTests: XCTestCase {

    private let svc = ExecutionSuspensionService.shared

    /// Barrier: waits until the service holds `count` MORE installed continuations than
    /// `baseline`. Never gate on `isSuspended` — it goes true before the continuation installs.
    private func waitForInstalls(above baseline: Int, count: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await svc.pendingSuspensionCount() >= baseline + count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    // MARK: - 1. Overwrite-guard balance

    /// Gate kind: suspend twice with the SAME operationID. The first waiter must resolve nil,
    /// and — the fix — after the second resolves, the conversation's park window must be CLOSED:
    /// `cumulativeParkedTime` stops growing. With the old bare-resume guard the leaked depth
    /// keeps the window open forever and the delta below tracks wall-clock.
    func testGateOverwriteGuardBalancesParkAccounting() async throws {
        let conv = UUID()
        let op = UUID()
        let baseline = await svc.pendingSuspensionCount()

        let first = Task { await svc.suspendForGate(for: op, conversationID: conv) }
        let firstInstalled = await waitForInstalls(above: baseline, count: 1)
        XCTAssertTrue(firstInstalled, "first gate park must install before the overwrite can be exercised")

        let second = Task { await svc.suspendForGate(for: op, conversationID: conv) }
        let firstResult = await first.value
        XCTAssertNil(firstResult, "the overwritten waiter resolves nil")

        let secondInstalled = await waitForInstalls(above: baseline, count: 1)
        XCTAssertTrue(secondInstalled)
        await svc.resumeGate(for: op, chosenOption: "picked", resolvedBy: .localUI)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, "picked")

        // The window must be closed: parked time stops growing. A leaked depth (the old bare
        // resume) keeps crediting wall-clock and this delta tracks the full 300ms sleep.
        let t1 = await svc.cumulativeParkedTime(for: conv)
        try await Task.sleep(for: .milliseconds(300))
        let t2 = await svc.cumulativeParkedTime(for: conv)
        XCTAssertLessThan(t2 - t1, 0.15,
                          "parkDepth must return to zero after both resolutions — a leaked depth makes every later node timeout in this conversation credit all wall-clock as parked time and never fire")
    }

    /// Permission kind — the same balance through `suspend`/`resume(for:)`.
    func testPermissionOverwriteGuardBalancesParkAccounting() async throws {
        let conv = UUID()
        let op = UUID()
        let baseline = await svc.pendingSuspensionCount()

        let first = Task { await svc.suspend(for: op, conversationID: conv) }
        _ = await waitForInstalls(above: baseline, count: 1)

        let second = Task { await svc.suspend(for: op, conversationID: conv) }
        let firstResult = await first.value
        XCTAssertFalse(firstResult, "the overwritten waiter resolves denied")

        _ = await waitForInstalls(above: baseline, count: 1)
        await svc.resume(for: op, approved: true, resolvedBy: .localUI)
        let secondResult = await second.value
        XCTAssertTrue(secondResult)

        let t1 = await svc.cumulativeParkedTime(for: conv)
        try await Task.sleep(for: .milliseconds(300))
        let t2 = await svc.cumulativeParkedTime(for: conv)
        XCTAssertLessThan(t2 - t1, 0.15)
    }

    // MARK: - 2. Honest teardown outcome

    /// Captures the next resolved notification for `operationID`, returning its outcome string.
    @MainActor
    private final class OutcomeCapture {
        private var observer: NSObjectProtocol?
        private(set) var outcome: String?
        private(set) var approved: Bool?
        let fulfilled = XCTestExpectation(description: "resolved notification")

        init(name: Notification.Name, operationID: UUID) {
            observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let opID = note.userInfo?[HITLResolvedKey.operationID] as? UUID, opID == operationID else { return }
                MainActor.assumeIsolated {
                    self?.outcome = note.userInfo?[HITLResolvedKey.outcome] as? String
                    self?.approved = note.userInfo?[HITLResolvedKey.approved] as? Bool
                    self?.fulfilled.fulfill()
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// Task-tree cancellation of a permission park must post outcome "cancelled" — the trace and
    /// audit rows stop claiming the user denied a tool they never saw resolve. `approved` stays
    /// false (the waiter's Bool contract — false is the only safe answer on teardown).
    func testTaskCancellationPostsOutcomeCancelledNotDenied() async throws {
        let conv = UUID()
        let op = UUID()
        let capture = await MainActor.run { OutcomeCapture(name: .hitlPermissionResolved, operationID: op) }
        let baseline = await svc.pendingSuspensionCount()

        let parked = Task { await svc.suspend(for: op, conversationID: conv) }
        _ = await waitForInstalls(above: baseline, count: 1)
        parked.cancel()

        let approved = await parked.value
        XCTAssertFalse(approved, "teardown resolves the waiter as denied — that side is unchanged")

        await fulfillment(of: [capture.fulfilled], timeout: 5)
        let outcome = await MainActor.run { capture.outcome }
        let notifApproved = await MainActor.run { capture.approved }
        XCTAssertEqual(outcome, "cancelled",
                       "a cancelled park is not a denial — 'denied' here writes a user decision that never happened into the audit row")
        XCTAssertEqual(notifApproved, false)
    }

    /// The control: a REAL denial still posts "denied" — the honest-outcome change must not
    /// blur actual decisions.
    func testRealDenialStillPostsDenied() async throws {
        let conv = UUID()
        let op = UUID()
        let capture = await MainActor.run { OutcomeCapture(name: .hitlPermissionResolved, operationID: op) }
        let baseline = await svc.pendingSuspensionCount()

        let parked = Task { await svc.suspend(for: op, conversationID: conv) }
        _ = await waitForInstalls(above: baseline, count: 1)
        await svc.resume(for: op, approved: false, resolvedBy: .localUI)

        let approved = await parked.value
        XCTAssertFalse(approved)

        await fulfillment(of: [capture.fulfilled], timeout: 5)
        let outcome = await MainActor.run { capture.outcome }
        XCTAssertEqual(outcome, "denied")
    }

    /// Clarification twin: task-tree cancellation posts "cancelled", not "skipped" — a torn-down
    /// question was never skipped by the user.
    func testClarificationCancellationPostsCancelledNotSkipped() async throws {
        let conv = UUID()
        let op = UUID()
        let capture = await MainActor.run { OutcomeCapture(name: .hitlClarificationResolved, operationID: op) }
        let baseline = await svc.pendingSuspensionCount()

        let parked = Task { await svc.suspendForClarification(for: op, conversationID: conv) }
        _ = await waitForInstalls(above: baseline, count: 1)
        parked.cancel()
        let answer = await parked.value
        XCTAssertNil(answer)

        await fulfillment(of: [capture.fulfilled], timeout: 5)
        let outcome = await MainActor.run { capture.outcome }
        XCTAssertEqual(outcome, "cancelled")
    }
}

// MARK: - Install-window probe

/// Empirically probes the drain-vs-install window: `suspendForGate` publishes its indexes and
/// `beginPark` BEFORE the actor releases at the `await` that installs the continuation. A drain
/// (`cancelNode`) landing in that gap — WITHOUT task cancellation — strips the indexes and finds
/// no continuation; the park then installs and waits forever, unreachable by any later drain.
///
/// Every production drain today accompanies task cancellation (the running-skip engine included —
/// its belt-and-braces drain runs only after the group teardown cancelled the producer), so the
/// window is currently guarded by the `Task.isCancelled` check inside the continuation body. This
/// probe exists to answer, with evidence rather than argument, whether the interleaving is
/// PHYSICALLY reachable for the first future caller that drains without cancelling.
final class SuspensionInstallWindowProbeTests: XCTestCase {

    /// Hang-proof completion signal. ⚠️ NOT `Task.value` raced against a sleep in a task group:
    /// `Task.value` is not cancellation-responsive, so the group child awaiting it blocks group
    /// exit until the park resolves — and on a genuine window hit (an orphaned park) that is
    /// NEVER, turning the probe's positive case into a runner hang instead of a count.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func mark() { lock.lock(); done = true; lock.unlock() }
        func isDone() -> Bool { lock.lock(); defer { lock.unlock() }; return done }
    }

    /// Polls the box up to `ms`; true if the park resolved in time.
    private func resolvedInTime(_ box: Box, within ms: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < deadline {
            if box.isDone() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return box.isDone()
    }

    func testDrainRacingInstallNeverStrandsThePark() async throws {
        let svc = ExecutionSuspensionService.shared
        var windowHits = 0
        let iterations = 500

        for _ in 0..<iterations {
            let conv = UUID(), node = UUID(), op = UUID()
            let box = Box()
            let park = Task { let r = await svc.suspendForGate(for: op, conversationID: conv, nodeID: node); box.mark(); return r }
            // Race the node-scoped drain against the install — no barrier, that IS the test.
            let drained = await svc.cancelNode(node, in: conv, outcome: "race-probe")

            // The verdict is `isOrphaned(operation:)` — the ATOMIC observation of "continuation
            // installed, indexes stripped", which only a drain landing in the pre-install window
            // can produce. (Sampling the two maps separately from out here races the install and
            // misclassifies a merely-slow normal park.)
            //
            // Where a hit can live: a drain that ran BEFORE publish returns EMPTY and leaves the
            // indexes intact — no orphan is possible there. A drain that saw the op returns it
            // (NON-empty) whether it resolved an installed continuation (the fine case) or
            // stripped the indexes of one still installing (the window). So the suspicious shape
            // is exactly: non-empty drain, park not promptly resolved — poll it; the window
            // state, once entered, persists until something resumes the orphan directly.
            if !drained.isEmpty, await resolvedInTime(box, within: 40) == false {
                let watchDeadline = Date().addingTimeInterval(0.15)
                while Date() < watchDeadline {
                    if await svc.isOrphaned(operation: op) {
                        windowHits += 1
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }

            // ⚠️ TERMINATION BY CANCELLATION, unconditionally — the one resolution that reaches
            // EVERY state the iteration can be in: a normal park (onCancel resumes it), a
            // not-yet-installed park (the in-body `Task.isCancelled` check resolves at install),
            // and an orphan (onCancel's resume-by-operationID keys the continuation map
            // directly, no conversation index needed). Two earlier designs of this probe tried
            // to rescue with bare `resumeGate` calls and both could hang the runner on a starved
            // install — an `await park.value` nothing was ever going to resolve.
            park.cancel()
            _ = await park.value
        }

        XCTAssertEqual(windowHits, 0,
                       "a drain raced the continuation install and stranded the park (\(windowHits)/\(iterations)) — the install-window tombstone is required before any caller drains without task cancellation")
    }
}
