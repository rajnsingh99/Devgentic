import XCTest
@testable import devgentic

/// ⚠️ WF-TS13 — park accounting, the shared state behind "a node timed out while a human was
/// still deciding".
///
/// `WorkflowExecutor.computeTimeoutSentinel` charges a node for COMPUTE time, not wall-clock: any
/// stretch the conversation spent parked on a gate is subtracted before the budget is checked.
/// Nothing tested that. The register filed this as "run two top-level workflows concurrently and
/// watch them interfere", but that shape is unmutatable — with two live runs the scheduler decides
/// what interleaves, so a passing result proves nothing and a failing one is a flake. These tests
/// go at the state directly instead.
///
/// ⚠️ ISOLATION: `ExecutionSuspensionService.shared` is process-wide (`private init()`), has no
/// reset, and `parkedTotal` grows for the life of the process. Fresh `UUID()`s per test are the
/// isolation — nothing here may assert on a global total.
final class WorkflowParkAccountingTests: XCTestCase {

    /// Parks `op` in `conv` and returns only once the continuation is REALLY installed.
    ///
    /// ⚠️ `suspendForGate` writes `operationToConversation` and calls `beginPark` BEFORE it
    /// installs the continuation, so `isSuspended(for:)` goes true too early. Resuming on that
    /// signal leaves the parked Task hung forever — which in this repo presents as a runner hang,
    /// not a test failure. `pendingSuspensionCount()` only counts installed continuations.
    @discardableResult
    private func park(_ op: UUID, in conv: UUID, expecting count: Int) async throws -> Task<String?, Never> {
        let t = Task { await ExecutionSuspensionService.shared.suspendForGate(for: op, conversationID: conv) }
        for _ in 0..<400 {
            if await ExecutionSuspensionService.shared.pendingSuspensionCount() == count { return t }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("gate \(op) never parked")
        return t
    }

    private func assertDrained(file: StaticString = #filePath, line: UInt = #line) async {
        let pending = await ExecutionSuspensionService.shared.pendingSuspensionCount()
        XCTAssertEqual(pending, 0,
                       "a previous suite leaked a suspension — this test's barrier is meaningless",
                       file: file, line: line)
    }

    /// ⚠️ THE ONE THAT MATTERS. The 2026-08-13 defect was nodes being killed while a human was
    /// still looking at the gate: park time was charged as compute. The sentinel here is given a
    /// 0.5s budget and the conversation is then parked for 1.2s — straight through the whole
    /// nominal budget. If park credit is lost, it fires at ~0.5s.
    func testComputeTimeoutSentinel_CreditsParkedTimeAndDoesNotFireEarly() async throws {
        await assertDrained()
        let conv = UUID(), op = UUID()
        let start = Date()

        let sentinel = Task { () -> (fired: TimeInterval, error: Error?) in
            do {
                _ = try await WorkflowExecutor.computeTimeoutSentinel(0.5, conversationID: conv, nodeName: "N")
            } catch {
                return (Date().timeIntervalSince(start), error)
            }
        }

        let parked = try await park(op, in: conv, expecting: 1)
        try await Task.sleep(for: .milliseconds(1200))     // the park spans the entire nominal budget
        await ExecutionSuspensionService.shared.resumeGate(for: op, chosenOption: "X")
        _ = await parked.value

        let (firedAt, error) = await sentinel.value

        XCTAssertGreaterThan(firedAt, 1.4,
                             "the sentinel fired inside the parked window — park time is being charged as compute, which is exactly the defect that killed nodes waiting on a human")
        XCTAssertLessThan(firedAt, 6.0, "the sentinel never fired — the extension loop is not converging")

        let agentError = try XCTUnwrap(error as? AgentExecutionError, "got: \(String(describing: error))")
        guard case .executionTimeout(let elapsed, let limit) = agentError.reason else {
            XCTFail("expected .executionTimeout, got \(agentError.reason)"); return
        }
        XCTAssertEqual(limit, 0.5, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(elapsed, 0.5)
        XCTAssertLessThan(elapsed, 1.0,
                          "`elapsed` must be COMPUTE, not wall-clock — a wall-clock value here means the park subtraction was lost")
        await assertDrained()
    }

    /// Park credit is scoped to ONE conversation: a gate parked in another run must not buy this
    /// run's nodes extra time.
    func testParkCredit_IsScopedPerConversation() async throws {
        await assertDrained()
        let convA = UUID(), convB = UUID(), op = UUID()

        let parked = try await park(op, in: convB, expecting: 1)
        let duringA = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: convA)
        XCTAssertEqual(duringA, 0, "convA parked nothing — it must accrue no credit from convB's gate")

        try await Task.sleep(for: .milliseconds(200))
        await ExecutionSuspensionService.shared.resumeGate(for: op, chosenOption: "X")
        _ = await parked.value

        let afterA = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: convA)
        let afterB = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: convB)
        XCTAssertEqual(afterA, 0, "credit leaked across conversations")
        XCTAssertGreaterThanOrEqual(afterB, 0.15, "convB parked ~200ms and must be credited for it")
        await assertDrained()
    }

    /// ⚠️ The union-not-sum invariant: two gates parked at the same time in one conversation are
    /// credited ONCE for the overlapping wall-clock, not twice. This is why a parallel sibling's
    /// park does not double-credit and hand a node an inflated budget.
    func testOverlappingParksInOneConversationAreCreditedOnce() async throws {
        await assertDrained()
        let conv = UUID(), op1 = UUID(), op2 = UUID()

        let p1 = try await park(op1, in: conv, expecting: 1)
        let p2 = try await park(op2, in: conv, expecting: 2)
        try await Task.sleep(for: .milliseconds(300))

        await ExecutionSuspensionService.shared.resumeGate(for: op2, chosenOption: "X")
        _ = await p2.value
        await ExecutionSuspensionService.shared.resumeGate(for: op1, chosenOption: "X")
        _ = await p1.value

        let credited = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: conv)
        XCTAssertGreaterThanOrEqual(credited, 0.25, "the ~300ms overlap must be credited")
        XCTAssertLessThan(credited, 0.55,
                          "two overlapping parks were SUMMED (~600ms) instead of unioned — a node would get double the budget it waited for")
        await assertDrained()
    }

    /// ⚠️ The concrete form of "a gate resolved into the wrong run". A sub-workflow child shares
    /// its parent's conversationID, and the executor's `catch is CancellationError` arm calls
    /// `cancel(for: conversationID)` — so a timed-out sub-workflow node CAN sweep a parked gate on
    /// a parallel sibling branch. This pins that the sweep at least stops at the CONVERSATION
    /// boundary; the intra-conversation sibling sweep is a separate, wider question.
    func testCancelForConversation_DrainsOnlyThatConversation() async throws {
        await assertDrained()
        let convA = UUID(), convB = UUID(), opA = UUID(), opB = UUID()

        let parkedA = try await park(opA, in: convA, expecting: 1)
        let parkedB = try await park(opB, in: convB, expecting: 2)

        await ExecutionSuspensionService.shared.cancel(for: convA)

        let resultA = await parkedA.value
        XCTAssertNil(resultA, "a cancelled gate resolves with no choice")
        let stillPending = await ExecutionSuspensionService.shared.pendingSuspensionCount()
        XCTAssertEqual(stillPending, 1, "cancelling convA must not sweep convB's gate")
        let bSuspended = await ExecutionSuspensionService.shared.isSuspended(for: convB)
        XCTAssertTrue(bSuspended, "convB is still waiting on its human")

        // Leave the process-wide singleton drained for whatever runs next.
        await ExecutionSuspensionService.shared.resumeGate(for: opB, chosenOption: "X")
        _ = await parkedB.value
        await assertDrained()
    }
}
