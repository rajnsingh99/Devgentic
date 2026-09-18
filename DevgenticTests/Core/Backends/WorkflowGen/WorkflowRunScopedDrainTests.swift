// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunScopedDrainTests.swift
//  DevgenticTests
//
//  Register EXC-2 — a root run's Stop must drain ITS OWN parks, not a concurrent run's.
//
//  ⚠️ The two-live-executor-runs shape was rejected as unmutatable by WorkflowParkAccountingTests
//  (the scheduler decides what interleaves), so these tests go at the service state directly:
//  parks are hand-planted under explicit `WorkflowRunScope.$token` bindings — the same TaskLocal
//  the real suspend* stamping reads — and the drains are called with the tokens the executor
//  would hold. The executor's cancel ARM is pinned separately by
//  `WorkflowExecutorIntegrationTests.testStop_DoesNotDrainAForeignRunsPark`.
//
//  ⚠️ ISOLATION: `ExecutionSuspensionService.shared` is process-wide (`private init()`, no
//  reset). Fresh UUIDs per test are the isolation; every count assertion is BASELINE-RELATIVE
//  (SuspensionAccountingFixTests' discipline), never a global total.
//

import XCTest
@testable import devgentic

final class WorkflowRunScopedDrainTests: XCTestCase {

    private var service: ExecutionSuspensionService { ExecutionSuspensionService.shared }

    /// Parks a GATE op under an optional run-token binding; returns once the continuation is
    /// really installed (pendingSuspensionCount is the only safe barrier — `isSuspended` goes
    /// true before the continuation installs; see WorkflowParkAccountingTests.park).
    @discardableResult
    private func parkGate(_ op: UUID, in conv: UUID, token: UUID?,
                          file: StaticString = #filePath, line: UInt = #line) async throws -> Task<String?, Never> {
        let baseline = await service.pendingSuspensionCount()
        let t = Task { [service] in
            await WorkflowRunScope.$token.withValue(token) {
                await service.suspendForGate(for: op, conversationID: conv)
            }
        }
        try await waitForPending(atLeast: baseline + 1, file: file, line: line)
        return t
    }

    /// Parks a PERMISSION (tool-confirmation) op — the register's exact run-B scenario shape.
    @discardableResult
    private func parkPermission(_ op: UUID, in conv: UUID, token: UUID?, nodeID: UUID? = nil,
                                file: StaticString = #filePath, line: UInt = #line) async throws -> Task<Bool, Never> {
        let baseline = await service.pendingSuspensionCount()
        let t = Task { [service] in
            await WorkflowRunScope.$token.withValue(token) {
                await service.suspend(for: op, conversationID: conv, nodeID: nodeID)
            }
        }
        try await waitForPending(atLeast: baseline + 1, file: file, line: line)
        return t
    }

    private func waitForPending(atLeast count: Int,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if await service.pendingSuspensionCount() >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("park never installed (pending < \(count))", file: file, line: line)
    }

    // MARK: - cancelRun

    /// ⚠️ THE EXC-2 PIN. Run A's Stop drains run A's gate; run B's parked tool confirmation
    /// SURVIVES — before the fix it resolved `approved = false`, and back in run B
    /// `Task.isCancelled` was false, so the node recorded "User denied tool 'X'" and fired its
    /// error branch on a run the user never touched.
    func testCancelRun_DrainsOwnParksAndSparesAConcurrentRuns() async throws {
        let conv = UUID(), runA = UUID(), runB = UUID()
        let opA = UUID(), opB = UUID()

        let taskA = try await parkGate(opA, in: conv, token: runA)
        let taskB = try await parkPermission(opB, in: conv, token: runB)

        let drained = await service.cancelRun(runA, in: conv)

        XCTAssertEqual(drained, [opA], "run A's stop must drain exactly its own park — got \(drained)")
        // ⚠️ Rescue BEFORE awaiting (the suite's mandatory discipline — see the token-less test):
        // an UNDER-drain regression leaves opA parked, and awaiting it after the failed assertion
        // is a runner hang that poisons the whole batch, not a red test.
        if !drained.contains(opA) { await service.resumeGate(for: opA, chosenOption: nil, resolvedBy: nil) }
        let aResult = await taskA.value
        XCTAssertNil(aResult, "run A's gate resolves nil (cancelled)")

        // Run B is untouched: its op is still suspended and its waiter still parked.
        let bStillParked = await service.isSuspended(for: conv)
        XCTAssertTrue(bStillParked, "run B's confirmation must still be awaiting the user")

        // Rescue B so the singleton doesn't leak into later suites; the real user approves.
        await service.resume(for: opB, approved: true, resolvedBy: .localUI)
        let bResult = await taskB.value
        XCTAssertTrue(bResult, "run B's waiter must receive the USER's answer, not a forced denial")
    }

    /// Token-less parks in the run's conversation ARE swept — MCP-broker consents (raised on the
    /// transport's task, outside any run's task tree) would otherwise stand forever for a run
    /// that no longer exists. `cancelNode`'s doc calls that class "a HANG, not a warning".
    func testCancelRun_SweepsTokenlessParksInItsConversation() async throws {
        let conv = UUID(), runA = UUID()
        let opTokenless = UUID(), opA = UUID()

        let tokenlessTask = try await parkGate(opTokenless, in: conv, token: nil)
        let aTask = try await parkGate(opA, in: conv, token: runA)

        let drained = await service.cancelRun(runA, in: conv)

        XCTAssertEqual(Set(drained), Set([opTokenless, opA]),
                       "the run's own park AND the conversation's token-less park must both drain — got \(drained)")
        // ⚠️ Rescue BEFORE awaiting: a failed assertion does not stop an XCTest, and awaiting a
        // park the mutated drain skipped is a runner HANG, not a red test — the exact trap the
        // skip-store tests document. Resuming an already-drained op is a logged no-op.
        if !drained.contains(opTokenless) { await service.resumeGate(for: opTokenless, chosenOption: nil, resolvedBy: nil) }
        if !drained.contains(opA) { await service.resumeGate(for: opA, chosenOption: nil, resolvedBy: nil) }
        let tokenlessResult = await tokenlessTask.value
        let aResult = await aTask.value
        XCTAssertNil(tokenlessResult)
        XCTAssertNil(aResult)
    }

    /// The conversation term still binds: a park in ANOTHER conversation survives even a
    /// token-less sweep.
    func testCancelRun_LeavesOtherConversationsAlone() async throws {
        let conv1 = UUID(), conv2 = UUID(), runA = UUID()
        let opOther = UUID()

        let otherTask = try await parkGate(opOther, in: conv2, token: nil)

        let drained = await service.cancelRun(runA, in: conv1)

        XCTAssertTrue(drained.isEmpty, "nothing in conv1 was parked — got \(drained)")
        let stillParked = await service.isSuspended(for: conv2)
        XCTAssertTrue(stillParked, "conv2's park must survive conv1's run drain")

        await service.resumeGate(for: opOther, chosenOption: "ok", resolvedBy: .localUI)
        _ = await otherTask.value
    }

    // MARK: - cancelNode run-token filter

    /// Two runs of the SAME workflow have IDENTICAL node IDs (the WF-CC14 motivation), so run A's
    /// node timeout calling `cancelNode` must not drain run B's park for the same node. A caller
    /// with NO token keeps the legacy drain-regardless behavior (pinned by
    /// WorkflowParkAccountingTests' existing cancelNode tests, which run unbound).
    func testCancelNode_SparesSameNodeIDParkOfAnotherRun() async throws {
        let conv = UUID(), runA = UUID(), runB = UUID(), nodeID = UUID()
        let opB = UUID()

        let bTask = try await parkPermission(opB, in: conv, token: runB, nodeID: nodeID)

        // Run A (a different run, same node id) tears its node down: must NOT touch B's park.
        let drainedByA = await WorkflowRunScope.$token.withValue(runA) {
            await service.cancelNode(nodeID, in: conv)
        }
        XCTAssertTrue(drainedByA.isEmpty,
                      "run A's node teardown must not drain run B's park for the same node id — got \(drainedByA)")

        // Run B's own teardown DOES drain it.
        let drainedByB = await WorkflowRunScope.$token.withValue(runB) {
            await service.cancelNode(nodeID, in: conv)
        }
        XCTAssertEqual(drainedByB, [opB], "the owning run's node teardown must drain its own park")
        // ⚠️ Rescue BEFORE awaiting — an over-filtering regression leaves opB parked, and the
        // await would hang the runner instead of letting the red assertion above stand.
        if !drainedByA.contains(opB) && !drainedByB.contains(opB) {
            await service.resume(for: opB, approved: false, resolvedBy: nil)
        }
        let bResult = await bTask.value
        XCTAssertFalse(bResult, "a drained confirmation resolves false")
    }
}
