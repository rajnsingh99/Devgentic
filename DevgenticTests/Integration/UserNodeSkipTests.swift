//
//  UserNodeSkipTests.swift
//  DevgenticTests
//
//  Phase A of per-node SKIP (`LLM_Execution_Concurrency_Design.md` §0.6 D2.1, owner-ratified
//  2026-08-21): a user-requested skip records `.skipped(.byUser)`, forwards the node's INPUT
//  downstream unchanged, activates no ports, and keeps every default edge below it LIVE.
//
//  ⚠️ TIMING TRICK, load-bearing in every end-to-end test here: requests can only exist MID-run
//  (the button renders only on a live run's pending rows), and the executor CLEARS the store at
//  ROOT-run start precisely so stale requests can't leak in. Pre-loading the store and running at
//  `startingDepth: 1` (a nested run, which must NOT clear — it would wipe the outer run's
//  requests) is how a mid-run request is simulated deterministically. The root-run staleness
//  clear gets its own test, at root depth.
//

import XCTest
@testable import devgentic

final class UserNodeSkipTests: XCTestCase {

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

    private func requestSkip(_ nodeID: UUID) async {
        let cid = conversationID
        await MainActor.run { WorkflowNodeSkipStore.shared.toggle(nodeID: nodeID, conversationID: cid) }
    }

    /// Runs the scenario with a FIXED conversationID (the store keys on it) at the given depth.
    private func execute(
        _ scenario: WorkflowTestScenario,
        userInput: String = "Test input",
        startingDepth: Int? = 1
    ) async throws -> [AgentStreamEvent] {
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let makeStream = {
            executor.executeWorkflow(
                userInput: userInput,
                chatHistory: [],
                conversationID: self.conversationID,
                ragContext: nil,
                traceContext: self.traceContext,
                onTraceUpdate: { _ in },
                layout: scenario.layout,
                profileMap: scenario.profileMap,
                streamProvider: self.mockProvider
            )
        }
        let stream = startingDepth.map { WorkflowDepth.$current.withValue($0, operation: makeStream) }
            ?? makeStream()
        return try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: nil)
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

    // MARK: - The core contract: pass-through + downstream runs

    /// A → B → C, user skips B. Before this feature, ANY `.skipped` upstream killed everything
    /// downstream (`edgeIsLive` demanded `.completed`) — the button would have been skipAll
    /// wearing a Skip label. The assertions that matter: C RAN, and C received A's output
    /// (B's INPUT, passed through), not B's output.
    func testUserSkipMiddleNode_PassesInputThroughAndDownstreamRuns() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let b = scenario.addBotNode(name: "Bot B")
        let c = scenario.addBotNode(name: "Bot C")
        scenario.connect(from: a, to: b)
        scenario.connect(from: b, to: c)

        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("alpha")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("SHOULD NEVER RUN")])
        mockProvider.scriptStream(for: scenario.profileID(for: c)!, events: [.content("gamma")])

        await requestSkip(b)
        let events = try await execute(scenario)

        XCTAssertEqual(skipReasons(in: events)[b], .byUser, "B must be skipped with the user reason")
        XCTAssertFalse(mockProvider.invocations.contains { $0.profileID == scenario.profileID(for: b)! },
                       "a skipped node's model must never be invoked")

        let cInvocation = mockProvider.invocations.first { $0.profileID == scenario.profileID(for: c)! }
        XCTAssertNotNil(cInvocation, "downstream of a user skip must RUN — that is the whole feature")
        XCTAssertTrue(cInvocation?.userInput.contains("alpha") == true,
                      "C must receive B's INPUT (A's output), passed through unchanged")
        XCTAssertFalse(cInvocation?.userInput.contains("SHOULD NEVER RUN") == true)

        XCTAssertEqual(StreamCollector.contentText(from: events), "gamma",
                       "the run's answer is C's output — the run COMPLETED")
    }

    /// Skipping the ENTRY node forwards the user's query itself: an entry node's input IS the
    /// query, and forwarding "" would hand downstream a blank task.
    func testUserSkipEntryNode_ForwardsTheUserQuery() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let b = scenario.addBotNode(name: "Bot B")
        scenario.connect(from: a, to: b)

        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("SHOULD NEVER RUN")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("beta")])

        await requestSkip(a)
        let events = try await execute(scenario, userInput: "  translate the moon speech  ")

        XCTAssertEqual(skipReasons(in: events)[a], .byUser)
        let bInvocation = mockProvider.invocations.first { $0.profileID == scenario.profileID(for: b)! }
        XCTAssertTrue(bInvocation?.userInput.contains("translate the moon speech") == true,
                      "the entry node's pass-through is the user's query")
        XCTAssertEqual(StreamCollector.contentText(from: events), "beta")
    }

    // MARK: - Fan-in (owner-ratified: a skipped branch COUNTS as an arrival)

    /// A + B → C (join), user skips B. The join must fire — with A's output AND B's pass-through
    /// input — never deadlock or drop the branch. A join requiring all inputs must not turn a
    /// skip into a silent run-killer.
    func testUserSkipFanInBranch_CountsAsArrival() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let b = scenario.addBotNode(name: "Bot B")
        let c = scenario.addBotNode(name: "Join C")
        scenario.connect(from: a, to: c)
        scenario.connect(from: b, to: c)

        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("alpha")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("SHOULD NEVER RUN")])
        mockProvider.scriptStream(for: scenario.profileID(for: c)!, events: [.content("joined")])

        await requestSkip(b)
        let events = try await execute(scenario, userInput: "the shared query")

        XCTAssertEqual(skipReasons(in: events)[b], .byUser)
        // The twin of the running-skip assertion: this skip landed BEFORE dispatch, so the node
        // genuinely never started and "Not run" is the honest word for it.
        XCTAssertEqual(ranBeforeSkipFlags(in: events)[b], false,
                       "a pre-dispatch skip must report that the node never started")
        let cInvocation = mockProvider.invocations.first { $0.profileID == scenario.profileID(for: c)! }
        XCTAssertNotNil(cInvocation, "the join must fire — the skipped branch counts as an arrival")
        XCTAssertTrue(cInvocation?.userInput.contains("alpha") == true, "the live branch contributes its output")
        XCTAssertTrue(cInvocation?.userInput.contains("the shared query") == true,
                      "the skipped entry branch contributes its pass-through INPUT")
        XCTAssertEqual(StreamCollector.contentText(from: events), "joined")
    }

    // MARK: - No error port, no cascade alarm

    /// A --error--> Handler, A skipped by user. A user skip is an instruction, not a failure: the
    /// handler must stand down, and its reason must NOT be the problem-indicating cascade
    /// (`upstreamSkipped` reads "something upstream went wrong" — nothing did).
    func testUserSkip_ErrorHandlerStandsDownWithoutCascadeAlarm() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let handler = scenario.addBotNode(name: "Handler")
        scenario.connect(from: a, to: handler, portLabel: WorkflowEdge.errorPortLabel)

        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("SHOULD NEVER RUN")])
        mockProvider.scriptStream(for: scenario.profileID(for: handler)!, events: [.content("SHOULD NEVER RUN EITHER")])

        await requestSkip(a)
        let events = try await execute(scenario)

        let reasons = skipReasons(in: events)
        XCTAssertEqual(reasons[a], .byUser)
        if let handlerReason = reasons[handler] {
            XCTAssertNotEqual(handlerReason, .upstreamSkipped,
                              "a user skip must never cascade as the problem-indicating reason")
            XCTAssertFalse(handlerReason.indicatesProblem,
                           "nothing went wrong — the handler's reason must not read as a problem")
        } else {
            XCTFail("the error handler must be reported (as a benign skip), not silently dropped")
        }
        XCTAssertFalse(events.contains { if case .error = $0 { return true }; return false },
                       "no failure occurred anywhere in this run")
    }

    // MARK: - The staleness guard

    /// At ROOT depth the executor clears the store before dispatch: a request left over from a
    /// previous run must never skip a node in a fresh one. (Requests can only legitimately be
    /// created mid-run; anything present at root start is stale by construction.)
    func testRootRunStart_ClearsStaleRequests_NodeRunsNormally() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("ran normally")])

        await requestSkip(a)
        let events = try await execute(scenario, startingDepth: nil)   // ROOT run

        XCTAssertNil(skipReasons(in: events)[a], "the stale request must be cleared, not honoured")
        XCTAssertEqual(StreamCollector.contentText(from: events), "ran normally")
        let cid = conversationID
        let residual = await MainActor.run { WorkflowNodeSkipStore.shared.isRequested(nodeID: a, conversationID: cid) }
        XCTAssertFalse(residual, "the stale request must be gone from the store")
    }

    // MARK: - Phase A debt (Increment 4)

    /// A node with retries CONFIGURED is still dispatched exactly zero times when skipped.
    ///
    /// ⚠️ READ THIS BEFORE TRUSTING IT TO COVER THE RETRY GUARD — IT DOES NOT. What actually holds
    /// here is Phase A's dispatch pre-flight: the skip is consumed BEFORE
    /// `executeProfileNodeWithRetry` is entered, so the attempt loop is never reached and the
    /// retry-count setting is irrelevant to the outcome. A mutation deleting the loop's `.skipped`
    /// arm SURVIVED this test — it was written believing it covered that guard, and it did not.
    /// The guard is unreachable through the executor by construction (both `.skipped` envelopes are
    /// built in the pre-flight) and is verified as pure policy instead, by
    /// `WorkflowRetryPolicyTests.testEverySkipReasonStopsTheLoop`.
    ///
    /// Kept because it pins something real and different: that a retry SETTING cannot resurrect a
    /// skipped node through the pre-flight path.
    func testUserSkipWithRetriesConfigured_PreflightStillPreventsAnyDispatch() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let b = scenario.addBotNode(name: "Bot B")
        scenario.connect(from: a, to: b)
        scenario.setNodeConfig(WorkflowNodeConfig(maxNodeRetries: 2), for: a)

        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("SHOULD NEVER RUN")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("beta")])

        await requestSkip(a)
        let events = try await execute(scenario)

        XCTAssertEqual(skipReasons(in: events)[a], .byUser)
        XCTAssertEqual(mockProvider.invocations.filter { $0.profileID == scenario.profileID(for: a)! }.count, 0,
                       "a skipped node must not be dispatched — not once, and not on a retry")
        let startedA = events.filter { event in
            if case .workflowNodeStarted(let nodeID, _, _, _) = event { return nodeID == a }
            return false
        }
        XCTAssertTrue(startedA.isEmpty, "no second start event may be emitted for a skipped node")
    }

    /// THE LIVE PHASE A DEFECT. Skipping the ONLY terminal dropped the run into the
    /// "zero successes AND zero failures" branch, which answers "The workflow finished without
    /// producing an answer" — while the pass-through content sat unused in the node's envelope.
    /// A linear workflow's last node is the terminal, so this is the ordinary case, not a corner.
    func testUserSkipOnlyTerminal_AnswersWithThePassThrough() async throws {
        let scenario = WorkflowTestScenario()
        let a = scenario.addBotNode(name: "Bot A")
        let b = scenario.addBotNode(name: "Bot B")
        scenario.connect(from: a, to: b)

        mockProvider.scriptStream(for: scenario.profileID(for: a)!, events: [.content("alpha answer")])
        mockProvider.scriptStream(for: scenario.profileID(for: b)!, events: [.content("SHOULD NEVER RUN")])

        await requestSkip(b)
        let events = try await execute(scenario)

        XCTAssertEqual(skipReasons(in: events)[b], .byUser)
        XCTAssertEqual(StreamCollector.contentText(from: events), "alpha answer",
                       "the skipped terminal's forwarded input IS the run's answer")
        XCTAssertFalse(StreamCollector.contentText(from: events).contains("without producing an answer"),
                       "the run produced an answer — reporting otherwise discards real content")
        XCTAssertFalse(events.contains { if case .error = $0 { return true }; return false },
                       "a user skip is not a failure")
    }

    /// The single-node case: the entry node IS the only terminal, so the answer is the user's own
    /// query passed through. Proves the fix does not depend on an upstream node existing.
    func testUserSkipSingleNodeWorkflow_AnswersWithTheUserQuery() async throws {
        let scenario = WorkflowTestScenario()
        let only = scenario.addBotNode(name: "Only Node")
        mockProvider.scriptStream(for: scenario.profileID(for: only)!, events: [.content("SHOULD NEVER RUN")])

        await requestSkip(only)
        let events = try await execute(scenario, userInput: "summarise the moon speech")

        XCTAssertEqual(StreamCollector.contentText(from: events), "summarise the moon speech")
        XCTAssertFalse(events.contains { if case .error = $0 { return true }; return false })
    }

    /// ⚠️ MISATTRIBUTION GUARD. With several terminals the answer is labeled per node — so a
    /// skipped terminal's forwarded INPUT would appear under a heading naming a node that never
    /// ran, attributing an upstream node's words to the one the user skipped.
    func testUserSkipOneOfTwoTerminals_MarksThePassThroughInTheLabeledAnswer() async throws {
        let scenario = WorkflowTestScenario()
        let seed = scenario.addBotNode(name: "Seed")
        let left = scenario.addBotNode(name: "Left")
        let right = scenario.addBotNode(name: "Right")
        scenario.connect(from: seed, to: left)
        scenario.connect(from: seed, to: right)

        mockProvider.scriptStream(for: scenario.profileID(for: seed)!, events: [.content("seed text")])
        mockProvider.scriptStream(for: scenario.profileID(for: left)!, events: [.content("left answer")])
        mockProvider.scriptStream(for: scenario.profileID(for: right)!, events: [.content("SHOULD NEVER RUN")])

        await requestSkip(right)
        let events = try await execute(scenario)

        let answer = StreamCollector.contentText(from: events)
        XCTAssertTrue(answer.contains("left answer"), "the completed terminal still contributes")
        XCTAssertTrue(answer.contains("## Right"), "the skipped terminal is still listed")
        XCTAssertTrue(answer.lowercased().contains("skipped by you"),
                      "its content must be marked as the input it would have processed, not passed off as its output")
    }

    // MARK: - Engine-side profile-only guard

    /// A stray store entry for a STRUCTURAL node must be ignored by the engine (the UI never
    /// renders the button there, but the engine guard is the independent twin).
    func testStructuralNodeIgnoresStrayStoreEntry() async throws {
        let scenario = WorkflowTestScenario()
        // A seed bot feeds the condition so its default "True on non-empty upstream output"
        // rule fires (an ENTRY condition sees empty upstream output and routes False).
        let seed = scenario.addBotNode(name: "Seed")
        let condition = scenario.addConditionNode(name: "Router")
        let yes = scenario.addBotNode(name: "Yes Bot")
        scenario.connect(from: seed, to: condition)
        scenario.connect(from: condition, to: yes, portLabel: "True")
        mockProvider.scriptStream(for: scenario.profileID(for: seed)!, events: [.content("seed output")])
        mockProvider.scriptStream(for: scenario.profileID(for: yes)!, events: [.content("routed")])

        await requestSkip(condition)
        let events = try await execute(scenario)

        XCTAssertNil(skipReasons(in: events)[condition], "a structural node must never be user-skipped")
        XCTAssertEqual(StreamCollector.contentText(from: events), "routed",
                       "the router must have executed and routed normally")
    }
}

// MARK: - Store unit tests

@MainActor
final class WorkflowNodeSkipStoreTests: XCTestCase {

    private let conv = UUID()
    private let node = UUID()

    override func tearDown() {
        WorkflowNodeSkipStore.shared.clear(conversationID: conv, reason: "test teardown")
        super.tearDown()
    }

    func testToggleFlipsTheRequest() {
        let store = WorkflowNodeSkipStore.shared
        XCTAssertFalse(store.isRequested(nodeID: node, conversationID: conv))
        store.toggle(nodeID: node, conversationID: conv)
        XCTAssertTrue(store.isRequested(nodeID: node, conversationID: conv))
        store.toggle(nodeID: node, conversationID: conv)
        XCTAssertFalse(store.isRequested(nodeID: node, conversationID: conv), "toggle is the undo — no dialog needed")
    }

    /// Consume is single-shot BY DESIGN: a request must not linger and silently skip the same
    /// node in a later run.
    func testConsumeIsSingleShot() {
        let store = WorkflowNodeSkipStore.shared
        store.toggle(nodeID: node, conversationID: conv)
        XCTAssertTrue(store.consume(nodeID: node, conversationID: conv))
        XCTAssertFalse(store.consume(nodeID: node, conversationID: conv), "second consume must find nothing")
        XCTAssertFalse(store.isRequested(nodeID: node, conversationID: conv))
    }

    func testRequestsAreConversationScoped() {
        let store = WorkflowNodeSkipStore.shared
        let otherConv = UUID()
        store.toggle(nodeID: node, conversationID: conv)
        XCTAssertFalse(store.isRequested(nodeID: node, conversationID: otherConv))
        XCTAssertFalse(store.consume(nodeID: node, conversationID: otherConv))
        XCTAssertTrue(store.consume(nodeID: node, conversationID: conv))
    }

    func testClearRemovesOnlyThatConversation() {
        let store = WorkflowNodeSkipStore.shared
        let otherConv = UUID()
        let otherNode = UUID()
        store.toggle(nodeID: node, conversationID: conv)
        store.toggle(nodeID: otherNode, conversationID: otherConv)
        store.clear(conversationID: conv, reason: "test")
        XCTAssertFalse(store.isRequested(nodeID: node, conversationID: conv))
        XCTAssertTrue(store.isRequested(nodeID: otherNode, conversationID: otherConv),
                      "a sibling conversation's requests must survive")
        store.clear(conversationID: otherConv, reason: "test")
    }
}

// MARK: - Reason + persistence tests

final class NodeSkipReasonByUserTests: XCTestCase {

    /// The tolerant decoder (D2.1): an unknown rawValue from a NEWER build must decode to the
    /// neutral `.notChosen`, never throw — a throw takes the whole containing record down
    /// (the loop-node deletion is the cautionary tale).
    func testUnknownReasonDecodesToNeutralInsteadOfThrowing() throws {
        let decoded = try JSONDecoder().decode([NodeSkipReason].self,
                                               from: Data(#"["someFutureCase"]"#.utf8))
        XCTAssertEqual(decoded, [.notChosen])
    }

    func testByUserRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode([NodeSkipReason.byUser])
        XCTAssertEqual(try JSONDecoder().decode([NodeSkipReason].self, from: data), [.byUser])
    }

    /// The owner-decided sentence, pinned: it is the ONE place the wording lives, and it must say
    /// the consequence (input passed through — downstream RAN) rather than "Not run".
    func testDisplayTextStatesThePassThroughConsequence() {
        XCTAssertEqual(NodeSkipReason.byUser.displayText,
                       "Skipped by you — its input was passed downstream unchanged.")
        XCTAssertFalse(NodeSkipReason.byUser.displayText.hasPrefix("Not run"),
                       "byUser is the one skip whose downstream runs — 'Not run' framing would lie about the branch")
    }

    func testByUserIsNeverAProblemAndLeastAlarming() {
        XCTAssertFalse(NodeSkipReason.byUser.indicatesProblem, "the user asked for it")
        for other in NodeSkipReason.allCases where other != .byUser {
            XCTAssertLessThan(other.severityRank, NodeSkipReason.byUser.severityRank,
                              "when a dead branch is fed by a crash AND a user skip, the crash must win the report")
        }
    }

    /// The persisted run-record status: `skipped:byUser` must round-trip, and the record layer's
    /// own tolerance must keep treating unknown reasons as neutral.
    func testRunRecordStatusRoundTripsByUser() {
        let status = WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus.skipped(.byUser)
        XCTAssertEqual(status.rawValue, "skipped:byUser")
        XCTAssertEqual(WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus(rawValue: "skipped:byUser"), status)
        XCTAssertEqual(WorkflowRunRecord.WorkflowNodeResultSnapshot.NodeStatus(rawValue: "skipped:futureCase"),
                       .skipped(.notChosen))
    }
}
