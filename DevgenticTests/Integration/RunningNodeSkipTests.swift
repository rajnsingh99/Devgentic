// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RunningNodeSkipTests.swift
//  DevgenticTests
//
//  Phase B increment 5 of per-node SKIP (`LLM_Execution_Concurrency_Design.md` §0.6 D2.1):
//  skipping a node that is ALREADY EXECUTING. The engine is a third racer child in
//  `executeNode`'s task group (`runningSkipSentinel`), a typed `WorkflowNodeSkipRequested`
//  signal, and `UserSkipTeardownPolicy` classifying the ambiguous teardown.
//
//  ⚠️ Every mid-flight test uses the mock's `.slow` script (yields then blocks until cancelled)
//  with `onInvoke` as the "node is genuinely running NOW" barrier — never `.workflowNodeStarted`
//  (yielded before the provider is called) and never a sleep. `tornDownProfileIDs` is the proof
//  that the skip actually cancelled the in-flight stream rather than waiting it out.
//
//  ⚠️ Deadline discipline: a broken skip's failure mode is a HANG (the `.slow` stream never
//  finishes). Every test that could hang runs through `executeWithDeadline`, which fails in
//  seconds instead of poisoning the runner for 400s.
//

import XCTest
@testable import devgentic

final class RunningNodeSkipTests: XCTestCase {

    private var mockProvider: MockWorkflowStreamProvider!
    private var traceContext: TraceContext!
    private let conversationID = UUID()

    override func setUp() {
        super.setUp()
        mockProvider = MockWorkflowStreamProvider()
        traceContext = TestTraceContext.make()
    }

    override func tearDown() {
        let cid = conversationID
        Task { @MainActor in WorkflowNodeSkipStore.shared.clear(conversationID: cid, reason: "test teardown") }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Fires a running-skip for `nodeID` the moment the given profile's stream is invoked —
    /// the deterministic "node is running now" barrier.
    private func skipWhenInvoked(node nodeID: UUID, profileID: UUID) {
        let cid = conversationID
        mockProvider.onInvoke = { pid in
            guard pid == profileID else { return }
            Task { @MainActor in
                WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: nodeID, conversationID: cid)
            }
        }
    }

    private func makeStream(
        _ scenario: WorkflowTestScenario,
        userInput: String
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let workflowProfileID = UUID()
        let executor = WorkflowExecutor(workflowProfileID: workflowProfileID)
        // [WF-CC14] ROOT depth, deliberately: the run must `beginRun` so the store owns the
        // conversation — a mid-run `requestRunningSkip` targets the ACTIVE run's token. (The old
        // `withValue(1)` nested-depth wrap dodged the root start-clear, which no longer exists.)
        return executor.executeWorkflow(
            userInput: userInput,
            conversationID: self.conversationID,
            traceContext: self.traceContext,
            onTraceUpdate: { _ in },
            layout: scenario.layout,
            profileMap: scenario.profileMap,
            streamProvider: self.mockProvider
        )
    }

    /// Collects the run with a hard deadline. On deadline the collection task is cancelled
    /// (which tears the run down — `.slow` resolves through the normal cancel path) and the
    /// test fails fast instead of hanging the runner.
    private func executeWithDeadline(
        _ scenario: WorkflowTestScenario,
        userInput: String = "Test input",
        seconds: TimeInterval = 20
    ) async throws -> [AgentStreamEvent] {
        let stream = makeStream(scenario, userInput: userInput)

        // ⚠️ Both racers are DIRECT group children, never wrapped `Task`s awaited via `.value`:
        // `Task.value` is not cancellation-responsive, so a wrapped deadline made `cancelAll` a
        // no-op and every SUCCESSFUL test still waited out the full deadline before the group
        // could return (measured: 10 × ~20s of pure latency on a green suite).
        return try await withThrowingTaskGroup(of: [AgentStreamEvent]?.self) { group in
            group.addTask { try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: nil) }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            guard let first = try await group.next(), let events = first else {
                // Deadline won: cancel the collector child — tearing the run down — and fail fast.
                group.cancelAll()
                _ = try? await group.next()
                throw XCTSkip.deadlineFailure()
            }
            group.cancelAll()
            return events
        }
    }

    private func skipReasons(in events: [AgentStreamEvent]) -> [UUID: NodeSkipReason] {
        var out: [UUID: NodeSkipReason] = [:]
        for event in events {
            if case .workflowNodeSkipped(let nodeID, _, let reason, _) = event { out[nodeID] = reason }
        }
        return out
    }


    /// What the EXECUTOR said about whether each skipped node had started. Asserted separately
    /// from the reason because the two settle sites produce the same reason and differ only here.
    private func ranBeforeSkipFlags(in events: [AgentStreamEvent]) -> [UUID: Bool] {
        var out: [UUID: Bool] = [:]
        for event in events {
            if case .workflowNodeSkipped(let nodeID, _, _, let ran) = event { out[nodeID] = ran }
        }
        return out
    }

    private func cancelledNodeIDs(in events: [AgentStreamEvent]) -> [UUID] {
        events.compactMap {
            if case .workflowNodeCancelled(let nodeID, _) = $0 { return nodeID }
            return nil
        }
    }

    /// Polls the mock for stream teardown — the proof the skip cancelled the in-flight work.
    private func waitForTeardown(of profileID: UUID, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if mockProvider.tornDownProfileIDs.contains(profileID) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return mockProvider.tornDownProfileIDs.contains(profileID)
    }

    // MARK: - The core contract

    /// A → B → C, B skipped MID-GENERATION. The five things that must all hold: B's stream was
    /// genuinely torn down; B settles `.skipped(.byUser)` with EXACTLY ONE skip event and no
    /// cancel event; C runs; C receives B's INPUT (A's output), not B's partial output; the run
    /// completes with C's answer.
    func testRunningSkip_MidGeneration_TearsDownAndPassesInputThrough() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let b = scenario.addBotNode(name: "Bot B")
        let c = scenario.addBotNode(name: "Bot C")
        scenario.connect(from: a, to: b)
        scenario.connect(from: b, to: c)

        let bPID = scenario.profileID(for: b)!
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("alpha")])
        mockProvider.scriptSlowStream(for: bPID, initialEvents: [.content("PARTIAL OUTPUT")])
        mockProvider.scriptStream(for: scenario.profileID(for: c)!, events: [.content("gamma")])

        skipWhenInvoked(node: b, profileID: bPID)
        let events = try await executeWithDeadline(scenario)

        XCTAssertEqual(skipReasons(in: events)[b], .byUser,
                       "a running-skip must settle the node as skipped-by-user")
        // ⚠️ THE SOURCE OF TRUTH for the "Not run" mislabel. The node dispatched and burned model
        // time before the skip landed; every display surface reads this flag to decide its wording.
        // Asserted HERE, at the executor, because a display-level test would pass on a hardcoded
        // value and never notice the emit site was wrong.
        XCTAssertEqual(ranBeforeSkipFlags(in: events)[b], true,
                       "a RUNNING skip must report that the node had already started")
        XCTAssertEqual(events.filter {
            if case .workflowNodeSkipped(let id, _, _, _) = $0 { return id == b }; return false
        }.count, 1, "exactly ONE terminal skip event — a second would race the state handler")
        XCTAssertFalse(cancelledNodeIDs(in: events).contains(b),
                       "a skip is not a cancellation — emitting both is a last-writer-wins race on the row")

        let tornDown = await waitForTeardown(of: bPID)
        XCTAssertTrue(tornDown, "the skip must CANCEL the in-flight stream, not wait it out")

        let cInvocation = mockProvider.invocations.first { $0.profileID == scenario.profileID(for: c)! }
        XCTAssertNotNil(cInvocation, "downstream of a running-skip must RUN")
        XCTAssertTrue(cInvocation?.userInput.contains("alpha") == true,
                      "C must receive B's INPUT (A's output), passed through unchanged")
        XCTAssertFalse(cInvocation?.userInput.contains("PARTIAL OUTPUT") == true,
                       "B's partial output is DISCARDED — forwarding it would be the pass-through contract broken quietly")

        XCTAssertEqual(StreamCollector.contentText(from: events), "gamma",
                       "the run completes with C's answer")
    }

    /// Parallel lanes: skipping B must not touch its sibling D. D's `.delayed` sleep is
    /// cancellation-sensitive by design — if the skip's teardown leaked to the sibling, D would
    /// die instead of completing and this test fails on D's missing output.
    func testRunningSkip_LeavesParallelSiblingUntouched() async throws {
        let scenario = WorkflowTestScenario()
        let b = scenario.addBotNode(name: "Bot B")
        let d = scenario.addBotNode(name: "Bot D")
        let c = scenario.addBotNode(name: "Bot C")
        scenario.connect(from: b, to: c)
        scenario.connect(from: d, to: c)

        let bPID = scenario.profileID(for: b)!
        mockProvider.scriptSlowStream(for: bPID, initialEvents: [])
        mockProvider.scriptDelayedStream(for: scenario.profileID(for: d)!, events: [.content("delta")], milliseconds: 400)
        mockProvider.scriptStream(for: scenario.profileID(for: c)!, events: [.content("done")])

        skipWhenInvoked(node: b, profileID: bPID)
        let events = try await executeWithDeadline(scenario)

        XCTAssertEqual(skipReasons(in: events)[b], .byUser)
        let dCompleted = events.contains {
            if case .workflowNodeCompleted(let id, _, let summary, _) = $0 { return id == d && summary == "delta" }
            return false
        }
        XCTAssertTrue(dCompleted, "the sibling must COMPLETE — its work is independent and stays valid (2026-08-12 rule)")

        let cInvocation = mockProvider.invocations.first { $0.profileID == scenario.profileID(for: c)! }
        XCTAssertTrue(cInvocation?.userInput.contains("delta") == true,
                      "the fan-in must carry the sibling's real output")
        XCTAssertTrue(cInvocation?.userInput.contains("Test input") == true,
                      "and the skipped entry node's pass-through (the user query) — both arrivals count")
    }

    /// Retries configured on the skipped node: the node must be invoked exactly ONCE. This is the
    /// e2e twin the Phase A retry test could not be (its skip fired pre-dispatch, so the loop was
    /// never entered) — a RUNNING skip settles `.skipped` INSIDE `executeProfileNodeWithRetry`'s
    /// attempt loop, where only `WorkflowRetryPolicy.stopsRetrying`'s `.skipped` arm halts it.
    func testRunningSkip_WithRetriesConfigured_DoesNotRedispatch() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let b = scenario.addBotNode(name: "Bot B")
        scenario.connect(from: a, to: b)
        scenario.setNodeConfig(WorkflowNodeConfig(maxNodeRetries: 2), for: b)

        let bPID = scenario.profileID(for: b)!
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("alpha")])
        mockProvider.scriptSlowStream(for: bPID, initialEvents: [])
        // Queue extra scripts so a wrongly-retried B would find one and RUN instead of erroring.
        mockProvider.scriptStream(for: bPID, events: [.content("RETRY RAN")])
        mockProvider.scriptStream(for: bPID, events: [.content("RETRY RAN")])

        skipWhenInvoked(node: b, profileID: bPID)
        let events = try await executeWithDeadline(scenario)

        XCTAssertEqual(skipReasons(in: events)[b], .byUser)
        XCTAssertEqual(mockProvider.invocations.filter { $0.profileID == bPID }.count, 1,
                       "a skipped node must not be re-dispatched — retrying it would re-run work the user just discarded, at full token cost")
        XCTAssertFalse(StreamCollector.contentText(from: events).contains("RETRY RAN"))
    }

    /// The single-node case: the entry node IS the only terminal. Its running-skip pass-through
    /// is the user's own query, and that becomes the run's answer (the Phase A terminal-verdict
    /// fix, exercised through the NEW settle path).
    func testRunningSkip_EntryTerminal_AnswersWithTheUserQuery() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let aPID = scenario.profileID(for: a)!
        mockProvider.scriptSlowStream(for: aPID, initialEvents: [])

        skipWhenInvoked(node: a, profileID: aPID)
        let events = try await executeWithDeadline(scenario, userInput: "the query itself")

        XCTAssertEqual(skipReasons(in: events)[a], .byUser)
        XCTAssertEqual(StreamCollector.contentText(from: events), "the query itself",
                       "an entry node's pass-through is the user query — the answer, since it is the only terminal")
        XCTAssertFalse(events.contains { if case .error = $0 { return true }; return false },
                       "a user skip is not a failure")
    }

    /// A park held under the node's identity but OUTSIDE the producer's task tree — the one shape
    /// task-tree cancellation cannot reach. The engine's belt-and-braces
    /// `cancelNode(_, in:, outcome: "skipped")` in `settleUserSkipTeardown` is the ONLY thing
    /// that resolves it; deleting that line strands this park and the test fails on the bounded
    /// wait. (In production every park lives in the producer's tree and resolves through the
    /// suspension service's own cancellation handlers, covered by HonestParkResolutionTests.)
    func testRunningSkip_DrainsAParkOutsideTheTaskTree() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let b = scenario.addBotNode(name: "Bot B")
        scenario.connect(from: a, to: b)

        let aPID = scenario.profileID(for: a)!
        mockProvider.scriptSlowStream(for: aPID, initialEvents: [])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("beta")])

        let invoked = expectation(description: "A invoked")
        mockProvider.onInvoke = { pid in
            if pid == aPID { invoked.fulfill() }
        }

        let collector = Task { try await self.executeWithDeadline(scenario) }
        await fulfillment(of: [invoked], timeout: 10)

        // Register a REAL park under (nodeID: a, conversationID) from a task the run does not
        // own — the stand-in for a hypothetical unstructured park.
        let cid = conversationID
        let op = UUID()
        let baseline = await ExecutionSuspensionService.shared.pendingSuspensionCount()
        let parkOutcome = CompletionBox<Bool>()
        let parkTask = Task {
            let r = await ExecutionSuspensionService.shared.suspend(for: op, conversationID: cid, nodeID: a)
            parkOutcome.set(r)
            return r
        }
        _ = parkTask
        let installDeadline = Date().addingTimeInterval(5)
        while await ExecutionSuspensionService.shared.pendingSuspensionCount() < baseline + 1,
              Date() < installDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        await MainActor.run { WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: a, conversationID: cid) }

        // Bounded wait, HANG-PROOF: poll the completion box rather than awaiting
        // `parkTask.value` inside a task group — `Task.value` is not cancellation-responsive,
        // so a group child awaiting it blocks group exit until the park resolves… which, under
        // the very mutation this test exists to catch (the belt-and-braces drain deleted), is
        // NEVER. The failure mode must be a red assertion in 10s, not a poisoned runner.
        var approved: Bool?
        let waitDeadline = Date().addingTimeInterval(10)
        while Date() < waitDeadline {
            if let resolved = parkOutcome.get() { approved = resolved; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if approved == nil {
            // Rescue the stranded park so it cannot leak into later tests, THEN fail.
            await ExecutionSuspensionService.shared.resume(for: op, approved: false, resolvedBy: .localUI)
        }
        XCTAssertEqual(approved, false,
                       "the skip must drain the node's park — without the belt-and-braces cancelNode this waits forever")

        let events = try await collector.value
        XCTAssertEqual(skipReasons(in: events)[a], .byUser)
        XCTAssertEqual(StreamCollector.contentText(from: events), "beta", "downstream still runs")
    }

    // MARK: - Structured output through the skip (the audited Phase A defect + its running twin)

    /// A emits JSON, B is skipped PRE-DISPATCH (Phase A), C is a Code node reading
    /// `{{ input.json.* }}`. The first test this field has ever had: before the fix the skip
    /// envelope silently defaulted `structuredOutput` to nil and C's template substituted nothing.
    func testPendingSkip_ForwardsStructuredJSONToCodeNode() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let b = scenario.addBotNode(name: "Bot B")
        let c = scenario.addCodeNode(name: "Extract", template: "The value is {{ input.json.answer }}")
        scenario.connect(from: a, to: b)
        scenario.connect(from: b, to: c)

        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("{\"answer\": 42}")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("SHOULD NEVER RUN")])

        await MainActor.run { WorkflowNodeSkipStore.shared.toggle(nodeID: b, conversationID: conversationID) }
        let events = try await executeWithDeadline(scenario)

        XCTAssertEqual(skipReasons(in: events)[b], .byUser)
        XCTAssertTrue(StreamCollector.contentText(from: events).contains("The value is 42"),
                      "the skip must forward upstream structured JSON — dropping it breaks {{ input.json.* }} with no error anywhere")
    }

    /// The RUNNING twin: B is skipped mid-flight and the JSON must still reach C.
    ///
    /// ⚠️ TWO upstreams (JSON + prose) on purpose. With a single JSON upstream this test passes
    /// against the very mutation it targets: the pass-through text IS the raw JSON, so the
    /// envelope build's parseStructured fallback re-derives the identical value and the explicit
    /// `compactMap(\.structuredOutput).first` forwarding is unobservable. Two upstreams join with
    /// "---", which does not parse — only the explicit forwarding can carry the JSON.
    func testRunningSkip_ForwardsStructuredJSONToCodeNode() async throws {
        let scenario = WorkflowTestScenario()
        let a1 = scenario.addBotNode(name: "Bot A1")
        let a2 = scenario.addBotNode(name: "Bot A2")
        let b = scenario.addBotNode(name: "Bot B")
        let c = scenario.addCodeNode(name: "Extract", template: "The value is {{ input.json.answer }}")
        scenario.connect(from: a1, to: b)
        scenario.connect(from: a2, to: b)
        scenario.connect(from: b, to: c)

        let bPID = scenario.profileID(for: b)!
        mockProvider.scriptStream(for: scenario.profileID(for: a1)!, events: [.content("{\"answer\": 42}")])
        mockProvider.scriptStream(for: scenario.profileID(for: a2)!, events: [.content("plain prose sibling")])
        mockProvider.scriptSlowStream(for: bPID, initialEvents: [])

        skipWhenInvoked(node: b, profileID: bPID)
        let events = try await executeWithDeadline(scenario)

        XCTAssertEqual(skipReasons(in: events)[b], .byUser)
        XCTAssertTrue(StreamCollector.contentText(from: events).contains("The value is 42"),
                      "a running-skip must forward upstream structured JSON exactly like a pending skip")
    }

    /// Skipping an ERROR-HANDLER node: its only upstream is a FAILED envelope on a live error
    /// edge. The pass-through must carry the annotated failure (`includeFailures: true`, exactly
    /// what the handler itself would have received) — with the shipped default it compiled to ""
    /// and downstream recovery got a blank.
    func testPendingSkip_OfErrorHandler_ForwardsTheAnnotatedFailure() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let h = scenario.addBotNode(name: "Handler")
        let n = scenario.addBotNode(name: "Notify")
        scenario.connect(from: a, to: h, portLabel: WorkflowEdge.errorPortLabel)
        scenario.connect(from: h, to: n)

        mockProvider.scriptError(for: scenario.profileID(for: a)!,
                                 error: AgentExecutionError(reason: .modelError(provider: "test", error: "boom")))
        mockProvider.scriptStream(for: scenario.profileID(for: h)!, events: [.content("SHOULD NEVER RUN")])
        mockProvider.scriptStream(for: scenario.profileID(for: n)!, events: [.content("notified")])

        await MainActor.run { WorkflowNodeSkipStore.shared.toggle(nodeID: h, conversationID: conversationID) }
        let events = try await executeWithDeadline(scenario)

        XCTAssertEqual(skipReasons(in: events)[h], .byUser)
        let nInvocation = mockProvider.invocations.first { $0.profileID == scenario.profileID(for: n)! }
        XCTAssertNotNil(nInvocation, "downstream of the skipped handler must run")
        XCTAssertTrue(nInvocation?.userInput.contains("failed") == true,
                      "the pass-through must carry the annotated failure the handler would have received — not an empty string")
    }
}

// MARK: - Hang-proof completion box

/// Poll-a-box bounded waiting for a task that may NEVER complete. `Task.value` is not
/// cancellation-responsive: a task-group child awaiting it blocks the group's exit until the
/// task finishes, so "race the value against a sleep" silently becomes "wait for the value" —
/// a runner hang whenever the awaited task is the very thing a mutation broke. The task writes
/// its result here; the test polls with a deadline and fails RED instead of hanging.
final class CompletionBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.lock(); stored = value; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return stored }
}

// MARK: - XCTSkip helper

private extension XCTSkip {
    /// A thrown deadline failure that reads as a FAILURE, not a skip — XCTSkip is not used;
    /// this indirection exists only to make the throw site read clearly.
    static func deadlineFailure() -> Error {
        struct DeadlineExceeded: Error, CustomStringConvertible {
            var description: String { "run did not finish before the test deadline — the skip machinery is hanging (this is the failure mode the deadline exists to catch)" }
        }
        return DeadlineExceeded()
    }
}

// MARK: - Teardown-verdict policy (pure truth table)

final class UserSkipTeardownPolicyTests: XCTestCase {

    private func verdict(_ caught: Bool, _ cancelled: Bool, _ fired: Bool) -> UserSkipTeardownPolicy.Verdict {
        UserSkipTeardownPolicy.classify(caughtSkipSignal: caught, externallyCancelled: cancelled, skipFired: fired)
    }

    /// STOP ALWAYS WINS — all four rows with externallyCancelled true, regardless of the skip
    /// signals. A `.skipped` verdict inside a dying run would keep downstream edges live in a
    /// teardown.
    func testExternalCancellationWinsOverEverySkipSignal() {
        XCTAssertEqual(verdict(true, true, true), .cancelled)
        XCTAssertEqual(verdict(true, true, false), .cancelled)
        XCTAssertEqual(verdict(false, true, true), .cancelled)
        XCTAssertEqual(verdict(false, true, false), .cancelled)
    }

    /// The common path: the typed signal was caught and nothing external cancelled.
    func testCaughtSignalSkips() {
        XCTAssertEqual(verdict(true, false, true), .skippedByUser)
        // caught-but-not-fired cannot occur (the sentinel marks fired before throwing) but the
        // policy must still not lose the user's instruction if it ever does.
        XCTAssertEqual(verdict(true, false, false), .skippedByUser)
    }

    /// The repair row: the work child's CancellationError surfaced first, but the store recorded
    /// the firing — still the user's skip.
    func testFiredWithoutSignalRepairsToSkip() {
        XCTAssertEqual(verdict(false, false, true), .skippedByUser)
    }

    /// Nothing says skip ⇒ nothing may claim one.
    func testPlainCancellationStaysCancelled() {
        XCTAssertEqual(verdict(false, false, false), .cancelled)
    }
}

// MARK: - Store: the running-skip channel

@MainActor
final class WorkflowNodeSkipStoreRunningChannelTests: XCTestCase {

    private let conv = UUID()
    /// [WF-CC14] The store is run-token-keyed now; these unit tests declare a run scope the way
    /// the executor does at run start.
    private let token = UUID()

    override func setUp() {
        super.setUp()
        WorkflowNodeSkipStore.shared.beginRun(conversationID: conv, runToken: token)
    }

    override func tearDown() {
        WorkflowNodeSkipStore.shared.clear(conversationID: conv, reason: "test teardown")
        super.tearDown()
    }

    /// [Found on adversarial audit] `try await someTask.value` on a `CheckedContinuation`-backed
    /// waiter has no bound: if a future regression in the exact run-token-keying logic under test
    /// here (WF-CC14) ever fails to resume the right waiter, the raw `.value` await hangs the test
    /// HOST rather than failing red — this session's other suites (`RunningNodeSkipTests`'s own
    /// `executeWithDeadline`, `UnattendedApprovalTests`'s racer) already established this bounded
    /// pattern for the same subsystem; this closes the one place it was missing.
    private func awaitBounded<T: Sendable>(_ task: Task<T, Error>, seconds: TimeInterval = 5) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            guard let first = try await group.next(), let result = first else {
                group.cancelAll()
                task.cancel()
                XCTFail("waiter did not resolve within \(seconds)s — the store failed to resume it")
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    /// Request before any waiter: buffered, then consumed instantly at registration — the shape
    /// that covers both the register race and a request landing between retry attempts.
    func testBufferedRequestConsumedAtRegistration() async throws {
        let node = UUID()
        WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: node, conversationID: conv)
        XCTAssertTrue(WorkflowNodeSkipStore.shared.runningSkipInFlight(nodeID: node, conversationID: conv))

        try await WorkflowNodeSkipStore.shared.awaitRunningSkip(nodeID: node, conversationID: conv, runToken: token)
        XCTAssertTrue(WorkflowNodeSkipStore.shared.runningSkipFired(nodeID: node, conversationID: conv, runToken: token),
                      "consumption must be recorded — the executor's verdict repair reads it")
    }

    /// Waiter first, request second: the request resumes it without a throw.
    func testRequestResumesARegisteredWaiter() async throws {
        let node = UUID()
        let waiter = Task { @MainActor in
            try await WorkflowNodeSkipStore.shared.awaitRunningSkip(nodeID: node, conversationID: conv, runToken: token)
            return true
        }
        // Give the waiter a beat to register (registration and buffering both succeed — the
        // assertion is on the OUTCOME either way, which is the contract).
        try await Task.sleep(for: .milliseconds(50))
        WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: node, conversationID: conv)

        let fired = try await awaitBounded(waiter)
        XCTAssertTrue(fired)
        XCTAssertTrue(WorkflowNodeSkipStore.shared.runningSkipFired(nodeID: node, conversationID: conv, runToken: token))
    }

    /// The node finished first: the group cancels the racer child, whose await must throw
    /// CancellationError and record NO firing.
    func testCancelledWaiterThrowsAndRecordsNothing() async throws {
        let node = UUID()
        let waiter = Task { @MainActor in
            try await WorkflowNodeSkipStore.shared.awaitRunningSkip(nodeID: node, conversationID: conv, runToken: token)
        }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("a cancelled waiter must throw")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(WorkflowNodeSkipStore.shared.runningSkipFired(nodeID: node, conversationID: conv, runToken: token),
                       "cancellation is not a firing — recording one would make the verdict repair claim a skip nobody asked for")
    }

    /// The pending-toggle bridge: a Phase A request that landed AFTER dispatch (the row still
    /// said Waiting when clicked) is consumed by the racer registration instead of dying inert
    /// while the row misleadingly shows "Undo skip".
    func testStalePendingToggleBridgesToRunningSkip() async throws {
        let node = UUID()
        WorkflowNodeSkipStore.shared.toggle(nodeID: node, conversationID: conv)

        try await WorkflowNodeSkipStore.shared.awaitRunningSkip(nodeID: node, conversationID: conv, runToken: token)

        XCTAssertTrue(WorkflowNodeSkipStore.shared.runningSkipFired(nodeID: node, conversationID: conv, runToken: token))
        XCTAssertFalse(WorkflowNodeSkipStore.shared.isRequested(nodeID: node, conversationID: conv),
                       "the pending request must be CONSUMED — leaving it flips the row to a lying 'Undo skip'")
    }

    /// Clear drops buffered requests and fired markers for that conversation only.
    func testClearIsConversationScoped() {
        let node = UUID()
        let otherConv = UUID()
        let otherNode = UUID()
        WorkflowNodeSkipStore.shared.beginRun(conversationID: otherConv, runToken: UUID())
        WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: node, conversationID: conv)
        WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: otherNode, conversationID: otherConv)

        WorkflowNodeSkipStore.shared.clear(conversationID: conv, reason: "test")

        XCTAssertFalse(WorkflowNodeSkipStore.shared.runningSkipInFlight(nodeID: node, conversationID: conv))
        XCTAssertTrue(WorkflowNodeSkipStore.shared.runningSkipInFlight(nodeID: otherNode, conversationID: otherConv),
                      "another conversation's request must survive")
        WorkflowNodeSkipStore.shared.clear(conversationID: otherConv, reason: "test teardown")
    }

    /// A second request while the first is buffered is a no-op — and the buffered request still
    /// fires exactly once.
    func testDuplicateRequestIsSingleShot() async throws {
        let node = UUID()
        WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: node, conversationID: conv)
        WorkflowNodeSkipStore.shared.requestRunningSkip(nodeID: node, conversationID: conv)

        try await WorkflowNodeSkipStore.shared.awaitRunningSkip(nodeID: node, conversationID: conv, runToken: token)

        // A second await must NOT find a second buffered request — it parks (and is cancelled).
        let secondWaiter = Task { @MainActor in
            try await WorkflowNodeSkipStore.shared.awaitRunningSkip(nodeID: node, conversationID: conv, runToken: token)
        }
        try await Task.sleep(for: .milliseconds(50))
        secondWaiter.cancel()
        do {
            try await secondWaiter.value
            XCTFail("the duplicate request must not have buffered a second firing")
        } catch is CancellationError { /* expected */ }
    }
}

// MARK: - Composer resolver (pure)

final class ComposerSkipResolverTests: XCTestCase {

    private func node(_ id: UUID = UUID(), name: String = "Node", skippable: Bool = true) -> ComposerSkipResolver.RunningNode {
        ComposerSkipResolver.RunningNode(nodeID: id, displayName: name, isRunningSkippable: skippable)
    }

    func testNoLiveRunHides() {
        XCTAssertEqual(
            ComposerSkipResolver.resolve(runIsLive: false, runningNodes: [node()], inFlightNodeIDs: []),
            .hidden)
    }

    func testNoRunningNodesHides() {
        XCTAssertEqual(
            ComposerSkipResolver.resolve(runIsLive: true, runningNodes: [], inFlightNodeIDs: []),
            .hidden)
    }

    /// Structural / sub-workflow rows are running but not skippable — the button must not render
    /// for them (the engine cannot honour it).
    func testOnlyUnskippableRunningNodesHide() {
        XCTAssertEqual(
            ComposerSkipResolver.resolve(runIsLive: true,
                                         runningNodes: [node(skippable: false), node(skippable: false)],
                                         inFlightNodeIDs: []),
            .hidden)
    }

    func testExactlyOneCandidateEnablesWithItsName() {
        let id = UUID()
        XCTAssertEqual(
            ComposerSkipResolver.resolve(runIsLive: true,
                                         runningNodes: [node(id, name: "Research Agent"), node(skippable: false)],
                                         inFlightNodeIDs: []),
            .enabled(nodeID: id, nodeName: "Research Agent"))
    }

    /// NEVER silently pick one (owner rule): several candidates disable the button, pointing at
    /// the timeline.
    func testSeveralCandidatesDisable() {
        let v = ComposerSkipResolver.resolve(runIsLive: true,
                                             runningNodes: [node(), node()],
                                             inFlightNodeIDs: [])
        guard case .disabled(let reason) = v else {
            return XCTFail("expected .disabled, got \(v)")
        }
        XCTAssertTrue(reason.contains("timeline"))
    }

    /// The single candidate's skip is already in flight: a distinct feedback state so a second
    /// click cannot run teardown twice and the press visibly took.
    func testInFlightCandidateShowsSkipping() {
        let id = UUID()
        XCTAssertEqual(
            ComposerSkipResolver.resolve(runIsLive: true,
                                         runningNodes: [node(id, name: "Research Agent")],
                                         inFlightNodeIDs: [id]),
            .inFlight(nodeName: "Research Agent"))
    }
}

// MARK: - Display data: running-row skippability

@MainActor
final class RunningSkippabilityDisplayTests: XCTestCase {

    /// The mandatory data-side fact: a RUNNING bot row is user-skippable AND running-skippable;
    /// a RUNNING sub-workflow row is user-skippable (pending semantics would have allowed it) but
    /// NOT running-skippable; a structural row is neither. Widening the view gate without these
    /// flags is a provable no-op — running nodes never take the placeholder branch.
    func testLiveResultBranchSetsSkippabilityByKind() {
        let scenario = WorkflowTestScenario()
        let bot = scenario.addBotNode(name: "Bot")
        let sub = scenario.addSubWorkflowNode(name: "Nested", workflowProfileID: UUID())
        let code = scenario.addCodeNode(name: "Transform")

        let state = WorkflowExecutionState()
        state.isRunning = true
        state.handleNodeStarted(nodeID: bot, profileName: "Bot", index: 1, total: 3)
        state.handleNodeStarted(nodeID: sub, profileName: "Nested", index: 2, total: 3)
        state.handleNodeStarted(nodeID: code, profileName: "Transform", index: 3, total: 3)

        let data = WorkflowRunDisplayData.from(live: state, layout: scenario.layout)
        let rows = Dictionary(uniqueKeysWithValues: data.nodeResults.map { ($0.nodeID, $0) })

        XCTAssertEqual(rows[bot]?.status, .running)
        XCTAssertEqual(rows[bot]?.isUserSkippable, true)
        XCTAssertEqual(rows[bot]?.isRunningSkippable, true)

        XCTAssertEqual(rows[sub]?.isUserSkippable, true, "a sub-workflow node is pending-skippable")
        XCTAssertEqual(rows[sub]?.isRunningSkippable, false,
                       "but NEVER running-skippable — it executes down the structural path the racer never enters")

        XCTAssertEqual(rows[code]?.isUserSkippable, false)
        XCTAssertEqual(rows[code]?.isRunningSkippable, false)
    }

    /// The pending placeholder keeps its Phase A shape (and never claims running-skippability).
    func testPendingPlaceholderUnchanged() {
        let scenario = WorkflowTestScenario()
        let bot = scenario.addBotNode(name: "Bot")

        let state = WorkflowExecutionState()
        state.isRunning = true

        let data = WorkflowRunDisplayData.from(live: state, layout: scenario.layout)
        let row = data.nodeResults.first { $0.nodeID == bot }
        XCTAssertEqual(row?.status, .pending)
        XCTAssertEqual(row?.isUserSkippable, true)
        XCTAssertEqual(row?.isRunningSkippable, false,
                       "a pending row has nothing in flight to skip — its button is the Phase A toggle")
    }
}

// MARK: - State handler: skip closes the node's dangling tool rows

// MARK: - "Not run" vs "Skipped" — the mid-run skip mislabel (2026-08-23)

@MainActor
final class RanBeforeSkipLabellingTests: XCTestCase {

    private func state(startFirst: Bool, reason: NodeSkipReason, ranBeforeSkip: Bool) -> (WorkflowExecutionState, UUID) {
        let state = WorkflowExecutionState()
        state.isRunning = true
        let node = UUID()
        if startFirst { state.handleNodeStarted(nodeID: node, profileName: "Agent 3", index: 1, total: 1) }
        state.handleNodeSkipped(nodeID: node, profileName: "Agent 3", reason: reason, ranBeforeSkip: ranBeforeSkip)
        return (state, node)
    }

    /// The observed defect: a node skipped MID-FLIGHT had started, spent model time and produced
    /// output that was discarded — yet every surface tagged it "Not run".
    func testMidRunSkipIsLabelledSkippedNotNotRun() throws {
        let (st, node) = state(startFirst: true, reason: .byUser, ranBeforeSkip: true)
        let data = WorkflowRunDisplayData.from(live: st)
        let row = try XCTUnwrap(data.nodeResults.first { $0.nodeID == node })

        XCTAssertEqual(row.ranBeforeSkip, true)
        XCTAssertEqual(data.skipTagLabel(for: row), "Skipped",
                       "the node ran — 'Not run' asserts three things that are all false")
        XCTAssertEqual(row.status, .skipped, "it is still a skip; only the wording changes")
    }

    /// The twin: a skip that landed before dispatch genuinely never ran.
    func testPreDispatchSkipKeepsNotRun() throws {
        let (st, node) = state(startFirst: false, reason: .byUser, ranBeforeSkip: false)
        let data = WorkflowRunDisplayData.from(live: st)
        let row = try XCTUnwrap(data.nodeResults.first { $0.nodeID == node })

        XCTAssertEqual(row.ranBeforeSkip, false)
        XCTAssertEqual(data.skipTagLabel(for: row), "Not run")
    }

    /// Cascade skips are unaffected — they never dispatched.
    func testCascadeSkipKeepsNotRun() throws {
        let (st, node) = state(startFirst: false, reason: .notChosen, ranBeforeSkip: false)
        let data = WorkflowRunDisplayData.from(live: st)
        let row = try XCTUnwrap(data.nodeResults.first { $0.nodeID == node })
        XCTAssertEqual(data.skipTagLabel(for: row), "Not run")
    }

    /// ⚠️ THE ANTI-PROSE TEST. This codebase's recidivist defect is deciding structure by matching
    /// English out of `detail` — nine surfaces re-derived one such rule and three got it wrong. An
    /// implementation that sniffed `detail.contains("Skipped by you")` would pass the tests above
    /// and die here, where the detail is empty and then actively misleading.
    func testLabelIgnoresDetailProseEntirely() throws {
        for misleading in ["", "Model returned an error", "Not run — the workflow branched away"] {
            let st = WorkflowExecutionState()
            let node = UUID()
            st.handleNodeStarted(nodeID: node, profileName: "Agent 3", index: 1, total: 1)
            st.handleNodeSkipped(nodeID: node, profileName: "Agent 3", reason: .byUser, ranBeforeSkip: true)
            if let i = st.nodeResults.firstIndex(where: { $0.nodeID == node }) {
                let p = st.nodeResults[i]
                st.nodeResults[i] = WorkflowNodeResult(
                    id: p.id, nodeID: p.nodeID, profileName: p.profileName, status: p.status,
                    detail: misleading, startTime: p.startTime, endTime: p.endTime,
                    hasWarnings: p.hasWarnings, ranBeforeSkip: p.ranBeforeSkip)
            }
            let data = WorkflowRunDisplayData.from(live: st)
            let row = try XCTUnwrap(data.nodeResults.first { $0.nodeID == node })
            XCTAssertEqual(data.skipTagLabel(for: row), "Skipped",
                           "the STRUCTURAL fact decides, not the prose — detail was: '\(misleading)'")
        }
    }

    /// ⚠️ THE TWIN-PATH GUARD. Live and historical are two adapters; this repo's recorded failure
    /// mode is fixing one and leaving the other, so the flag must survive freeze AND come back out.
    func testRanBeforeSkipSurvivesFreezeAndTheRecordAdapter() throws {
        let (st, node) = state(startFirst: true, reason: .byUser, ranBeforeSkip: true)
        st.handleFinalOutput("done")

        let record = WorkflowRunRecord.freeze(
            from: st, conversationID: UUID(), workflowProfileID: UUID(),
            workflowName: "wf", userInput: "go", timestamp: st.startedAt)

        let snapshot = try XCTUnwrap(record.nodeResults.first { $0.nodeID == node })
        XCTAssertEqual(snapshot.ranBeforeSkip, true, "freeze must carry it — it replaces the whole struct")

        let data = WorkflowRunDisplayData.from(record: record)
        let row = try XCTUnwrap(data.nodeResults.first { $0.nodeID == node })
        XCTAssertEqual(data.skipTagLabel(for: row), "Skipped",
                       "the historical view must say what the live view said")
    }

    /// ⚠️ OLD RECORDS. A strict `decode` of the new key throws on every already-persisted run, and
    /// the resilient tier answers a failed snapshot by DROPPING THE WHOLE NODE — status, duration
    /// and up to 400 timeline events. This pins that a snapshot without the key still decodes.
    func testSnapshotWrittenBeforeTheFieldStillDecodesIntact() throws {
        let json = """
        {"id":"\(UUID().uuidString)","nodeID":"\(UUID().uuidString)","profileName":"Old Node",
         "status":"skipped:byUser","detail":"Skipped by you","duration":1.7}
        """
        let snap = try JSONDecoder().decode(
            WorkflowRunRecord.WorkflowNodeResultSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.profileName, "Old Node", "the node must survive, not be dropped")
        XCTAssertNil(snap.ranBeforeSkip, "absent means unknown, not false")
        XCTAssertEqual(snap.duration, 1.7)
    }

    /// A snapshot without the field never claims the node ran: unknown reads as "Not run",
    /// whatever its duration. (The duration/trace heuristic for pre-field records was removed
    /// with the rest of the legacy-record handling, 2026-10-03.)
    func testASnapshotWithoutTheFieldReadsAsNotRun() {
        func row(duration: TimeInterval) -> WorkflowRunDisplayData.NodeDisplayData {
            .init(id: UUID(), nodeID: UUID(), profileName: "n", status: .skipped, detail: "d",
                  duration: duration, input: nil, inputSourceLabel: nil, nodeTimeline: [],
                  isStreaming: false, ranBeforeSkip: nil, supportsTimeline: false)
        }
        let data = WorkflowRunDisplayData.from(live: WorkflowExecutionState())
        XCTAssertEqual(data.skipTagLabel(for: row(duration: 1.7)), "Not run")
        XCTAssertEqual(data.skipTagLabel(for: row(duration: 0.0)), "Not run")
    }
}

@MainActor
final class HandleNodeSkippedToolRowTests: XCTestCase {

    private func executingRow() -> TimelineEvent {
        .toolExecution(ToolExecutionData(
            id: UUID(), name: "execute_shell", params: "{}", output: nil,
            isSuccess: nil, isExecuting: true))
    }

    /// A `.byUser` skip closes the node's still-executing tool rows with skip semantics —
    /// nothing else does until run-end settling (cancel/failure only) or freeze (which paints
    /// them RED). Without this the row spins for the rest of the run.
    func testUserSkipClosesTheNodesOpenToolRows() {
        let state = WorkflowExecutionState()
        let node = UUID()
        state.nodeTimelines[node] = [executingRow()]

        state.handleNodeSkipped(nodeID: node, profileName: "Agent", reason: .byUser, ranBeforeSkip: true)

        guard case .toolExecution(let data)? = state.nodeTimelines[node]?.first else { return XCTFail() }
        XCTAssertFalse(data.isExecuting)
        XCTAssertNil(data.isSuccess, "skip semantics: no verdict, no red capsule, no failed-tool count")
        XCTAssertEqual(data.output, "Interrupted — the node was skipped by you.")
    }

    /// A CASCADE skip never ran, so it has no rows of its own — touching rows under its nodeID
    /// would hide a real defect (rows for a node that never started).
    func testCascadeSkipLeavesToolRowsAlone() {
        let state = WorkflowExecutionState()
        let node = UUID()
        state.nodeTimelines[node] = [executingRow()]

        state.handleNodeSkipped(nodeID: node, profileName: "Agent", reason: .notChosen, ranBeforeSkip: false)

        guard case .toolExecution(let data)? = state.nodeTimelines[node]?.first else { return XCTFail() }
        XCTAssertTrue(data.isExecuting, "only .byUser closes rows — a cascade skip closing them would mask the anomaly")
    }
}

// MARK: - Tool-row closing with skip semantics

final class DanglingToolRowCloserUserSkipTests: XCTestCase {

    private func executingRow(name: String = "execute_shell") -> TimelineEvent {
        .toolExecution(ToolExecutionData(
            id: UUID(), name: name, params: "{}", output: nil,
            isSuccess: nil, isExecuting: true))
    }

    /// Skip semantics: the row settles with NO verdict (`isSuccess` stays nil — no red capsule,
    /// no failed-tool count) and an output that says what happened.
    func testUserSkipCloseIsNeutral() {
        var events = [executingRow()]
        let closed = DanglingToolRowCloser.closeForUserSkip(&events)

        XCTAssertEqual(closed, 1)
        guard case .toolExecution(let data) = events[0] else { return XCTFail() }
        XCTAssertFalse(data.isExecuting)
        XCTAssertNil(data.isSuccess,
                     "a skipped node's abandoned tool is neither a success nor a failure — isSuccess=false would paint it red and count it failed")
        XCTAssertNil(data.failureCategory)
        XCTAssertEqual(data.output, "Interrupted — the node was skipped by you.")
    }

    /// A row that already finished is untouched — only still-executing rows are dangling.
    func testFinishedRowsUntouched() {
        var data = ToolExecutionData(id: UUID(), name: "t", params: "{}", output: "real output",
                                     isSuccess: true, isExecuting: false)
        data.durationMs = 12
        var events: [TimelineEvent] = [.toolExecution(data)]
        let closed = DanglingToolRowCloser.closeForUserSkip(&events)

        XCTAssertEqual(closed, 0)
        guard case .toolExecution(let after) = events[0] else { return XCTFail() }
        XCTAssertEqual(after.isSuccess, true)
        XCTAssertEqual(after.output, "real output")
    }

    /// Regression pin for the shared-walk refactor: the close's coverage, category and synthetic
    /// output must survive the extraction of the walk.
    ///
    /// [CF-51] `isSuccess` no longer goes to `false` on a CANCELLED close — a user Stop is not a
    /// tool failure, and asserting one badged the row red and counted it in the header's
    /// "N failed". Every other outcome still writes `false` — pinned by
    /// `CancelledToolRowSettlementTests.testAFailedCloseStillAssertsFailure`.
    func testExistingCloseSemanticsUnchangedByRefactor() {
        var events = [executingRow(), executingRow()]
        let closed = DanglingToolRowCloser.close(&events, outcome: .cancelled)

        XCTAssertEqual(closed, 2)
        for event in events {
            guard case .toolExecution(let data) = event else { return XCTFail() }
            XCTAssertFalse(data.isExecuting)
            XCTAssertNil(data.isSuccess)
            XCTAssertEqual(data.failureCategory, .cancelled)
            XCTAssertEqual(data.output, "Cancelled before the tool finished.")
        }
    }
}
