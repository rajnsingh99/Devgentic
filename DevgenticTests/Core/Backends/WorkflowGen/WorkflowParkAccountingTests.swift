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

    // MARK: - Node-scoped drain (N3, plan increment 1)

    /// Parks a GATE for `op` attributed to `node`, returning once the continuation is really
    /// installed. Same install barrier as `park` — see its note.
    @discardableResult
    private func parkNode(_ op: UUID, in conv: UUID, node: UUID, expecting count: Int) async throws -> Task<String?, Never> {
        let t = Task { await ExecutionSuspensionService.shared.suspendForGate(for: op, conversationID: conv, nodeID: node) }
        for _ in 0..<400 {
            if await ExecutionSuspensionService.shared.pendingSuspensionCount() == count { return t }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("gate \(op) never parked")
        return t
    }

    /// ⚠️ THE N3 DEFECT. Two nodes of one run park at once; draining ONE must leave the other
    /// alone. Before this, cancelling node A force-resolved node B's banner too and B's tool was
    /// reported "denied by the user" — a decision the user never made, on a request they never saw.
    func testCancelNode_DrainsOnlyThatNodesParks() async throws {
        await assertDrained()
        let conv = UUID(), nodeA = UUID(), nodeB = UUID()
        let opA = UUID(), opB = UUID()

        let taskA = try await parkNode(opA, in: conv, node: nodeA, expecting: 1)
        let taskB = try await parkNode(opB, in: conv, node: nodeB, expecting: 2)

        let drained = await ExecutionSuspensionService.shared.cancelNode(nodeA, in: conv)
        XCTAssertEqual(drained, [opA], "exactly node A's operation")
        _ = await taskA.value

        let pendingAfterDrain = await ExecutionSuspensionService.shared.pendingSuspensionCount()
        XCTAssertEqual(pendingAfterDrain, 1, "node B's park must survive — this is the whole fix")
        let bStillParked = await ExecutionSuspensionService.shared.isSuspended(node: nodeB, in: conv)
        let aStillParked = await ExecutionSuspensionService.shared.isSuspended(node: nodeA, in: conv)
        XCTAssertTrue(bStillParked)
        XCTAssertFalse(aStillParked)

        await ExecutionSuspensionService.shared.resumeGate(for: opB, chosenOption: "chosen")
        let resolvedB = await taskB.value
        XCTAssertEqual(resolvedB, "chosen", "B must still resolve with the USER's answer")
        await assertDrained()
    }

    /// ⚠️ THE PARK-ACCOUNTING TRAP, and the reason this increment ships alone. `beginPark`/`endPark`
    /// are a reference count over a UNION window keyed by CONVERSATION. A partial drain must call
    /// `endPark` EXACTLY ONCE, leaving the window OPEN while a sibling is still parked. One extra
    /// call drives the depth to zero early, closes the window, and then every later node in that
    /// conversation stops crediting parked time — its timeout fires on wall-clock and kills work
    /// that was only ever waiting on a human. Silent, and for the life of the process.
    func testCancelNode_KeepsTheParkWindowOpenForTheSurvivor() async throws {
        await assertDrained()
        let conv = UUID(), nodeA = UUID(), nodeB = UUID()
        let opA = UUID(), opB = UUID()

        let taskA = try await parkNode(opA, in: conv, node: nodeA, expecting: 1)
        let taskB = try await parkNode(opB, in: conv, node: nodeB, expecting: 2)

        await ExecutionSuspensionService.shared.cancelNode(nodeA, in: conv)
        _ = await taskA.value

        // The window must still be OPEN: B is parked, so parked time keeps accruing.
        let first = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: conv)
        try await Task.sleep(for: .milliseconds(120))
        let second = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: conv)
        XCTAssertGreaterThan(second, first,
                             "the survivor's park window closed early — every later node in this conversation would now time out on wall-clock")

        await ExecutionSuspensionService.shared.resumeGate(for: opB, chosenOption: nil)
        _ = await taskB.value

        // Now that nothing is parked the window is closed and the total is frozen.
        let afterClose = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: conv)
        try await Task.sleep(for: .milliseconds(80))
        let stillFrozen = await ExecutionSuspensionService.shared.cumulativeParkedTime(for: conv)
        XCTAssertEqual(afterClose, stillFrozen, accuracy: 0.02,
                       "with no parks left the window must be CLOSED — an unbalanced count would keep it open forever")
        await assertDrained()
    }

    /// A park with NO node dimension — every chat/code run, and both MCP brokers — must be
    /// invisible to the node drain and still drained by the conversation-wide one. Getting this
    /// wrong is a HANG, not a warning: nothing else would ever resolve it.
    func testCancelNode_IgnoresParksWithNoNodeDimension() async throws {
        await assertDrained()
        let conv = UUID(), node = UUID(), chatOp = UUID()

        let chatTask = try await park(chatOp, in: conv, expecting: 1)   // no nodeID
        let drainedNothing = await ExecutionSuspensionService.shared.cancelNode(node, in: conv)
        XCTAssertEqual(drainedNothing, [], "a node drain must not touch a park that carries no node")
        let stillPending = await ExecutionSuspensionService.shared.pendingSuspensionCount()
        XCTAssertEqual(stillPending, 1)

        await ExecutionSuspensionService.shared.cancel(for: conv)
        _ = await chatTask.value
        await assertDrained()
    }

    /// The conversation boundary: the same node id under a DIFFERENT conversation must not match.
    /// Guards a stale node id from an earlier run of the same graph.
    func testCancelNode_IsScopedToItsConversation() async throws {
        await assertDrained()
        let convA = UUID(), convB = UUID(), node = UUID(), op = UUID()

        let task = try await parkNode(op, in: convA, node: node, expecting: 1)
        let wrongConv = await ExecutionSuspensionService.shared.cancelNode(node, in: convB)
        XCTAssertEqual(wrongConv, [], "same node id, different conversation — must not drain")
        let pending = await ExecutionSuspensionService.shared.pendingSuspensionCount()
        XCTAssertEqual(pending, 1)

        await ExecutionSuspensionService.shared.cancelNode(node, in: convA)
        _ = await task.value
        await assertDrained()
    }

    /// After a NORMAL resume, the node must no longer look parked and a later drain must find
    /// nothing — so a resolved operation can never be re-resolved by a node-scoped drain.
    ///
    /// ⚠️ SCOPE, stated because a mutation proved the obvious reading wrong: this does NOT verify
    /// that `operationToNode` itself is cleaned up. Every lookup (`isSuspended(node:in:)`,
    /// `cancelNode`) is gated on `operationToConversation`, which `resume*` removes — so deleting
    /// the `operationToNode.removeValue` from a resume path leaves this test GREEN. That removal is
    /// hygiene against unbounded growth in a process-wide singleton with no reset, and it is
    /// invisible to behaviour by construction. Verifying it would mean exposing the map's size as
    /// production API purely for a test, which is not worth it — the gating is the real guarantee.
    func testNormalResumeLeavesNothingForALaterDrain() async throws {
        await assertDrained()
        let conv = UUID(), node = UUID(), op = UUID()

        let task = try await parkNode(op, in: conv, node: node, expecting: 1)
        await ExecutionSuspensionService.shared.resumeGate(for: op, chosenOption: "yes")
        _ = await task.value

        let stale = await ExecutionSuspensionService.shared.isSuspended(node: node, in: conv)
        XCTAssertFalse(stale, "a resolved operation must not still read as parked")
        let nothingLeft = await ExecutionSuspensionService.shared.cancelNode(node, in: conv)
        XCTAssertEqual(nothingLeft, [], "a resolved operation must leave nothing for a later drain to find")
        await assertDrained()
    }
}
