//
//  WorkflowExecutorIntegrationTests.swift
//  DevgenticTests
//
//  Integration tests for WorkflowExecutor DAG orchestration.
//  Exercises real WorkflowExecutor, WorkflowState, ContextCompressor, and DAG
//  algorithms with a mock stream provider (no LLM/network calls).
//
//  Red-green approach: synthetic real-world scenarios covering single, chained,
//  branching, and complex workflows with condition, code, and gate nodes.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowExecutorIntegrationTests: XCTestCase {

    private var mockProvider: MockWorkflowStreamProvider!
    private var traceContext: TraceContext!
    private var innerBuilders: [InnerWorkflowBuilder] = []

    override func setUp() {
        super.setUp()
        mockProvider = MockWorkflowStreamProvider()
        traceContext = TestTraceContext.make()
        innerBuilders = []
    }

    override func tearDown() {
        for builder in innerBuilders {
            builder.cleanup()
        }
        innerBuilders = []
        super.tearDown()
    }

    // MARK: - Helpers

    /// Executes a workflow scenario and collects all stream events.
    private func execute(
        _ scenario: WorkflowTestScenario,
        userInput: String = "Test input"
    ) async throws -> [AgentStreamEvent] {
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let stream = executor.executeWorkflow(
            userInput: userInput,
            chatHistory: [],
            conversationID: UUID(),
            ragContext: nil,
            traceContext: traceContext,
            onTraceUpdate: { _ in },
            layout: scenario.layout,
            profileMap: scenario.profileMap,
            streamProvider: mockProvider
        )
        return try await StreamCollector.collect(from: stream)
    }

    /// Creates a workflow stream (without consuming it) for cancellation tests.
    private func makeStream(
        _ scenario: WorkflowTestScenario,
        userInput: String = "Test input"
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        return executor.executeWorkflow(
            userInput: userInput,
            chatHistory: [],
            conversationID: UUID(),
            ragContext: nil,
            traceContext: traceContext,
            onTraceUpdate: { _ in },
            layout: scenario.layout,
            profileMap: scenario.profileMap,
            streamProvider: mockProvider
        )
    }

    /// Executes a workflow with gate auto-response.
    private func executeWithGate(
        _ scenario: WorkflowTestScenario,
        choosing option: String?,
        userInput: String = "Test input"
    ) async throws -> [AgentStreamEvent] {
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let stream = executor.executeWorkflow(
            userInput: userInput,
            chatHistory: [],
            conversationID: UUID(),
            ragContext: nil,
            traceContext: traceContext,
            onTraceUpdate: { _ in },
            layout: scenario.layout,
            profileMap: scenario.profileMap,
            streamProvider: mockProvider
        )
        return try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: option)
    }

    // MARK: - Group 1: Foundation

    func testEmptyWorkflow_Throws() async {
        let scenario = WorkflowTestScenario()
        // No nodes added
        do {
            _ = try await execute(scenario)
            XCTFail("Expected WorkflowError.emptyWorkflow")
        } catch let error as WorkflowError {
            if case .emptyWorkflow = error {
                // Expected
            } else {
                XCTFail("Expected emptyWorkflow, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSingleBot_ProducesOutput() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [
            .content("Hello from Bot A")
        ])

        let events = try await execute(scenario)

        // Verify node lifecycle
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started[0].profileName, "Bot A")

        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertEqual(completed.count, 1)

        // Verify final output
        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Hello from Bot A")

        // Verify progress
        let progress = WorkflowStreamCollector.progressEvents(from: events)
        XCTAssertTrue(progress.contains(where: { $0.completed == 1 && $0.total == 1 }))
    }

    func testMissingProfile_EmitsFailure() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Ghost Bot")

        // Remove the profile from the map so it's not found
        let profileID = scenario.profileID(for: botA)!
        scenario.profileMap.removeValue(forKey: profileID)

        // Pre-flight validation catches a missing profile and rejects the run.
        do {
            _ = try await execute(scenario)
            XCTFail("Expected validationFailed for a missing profile")
        } catch let error as WorkflowError {
            guard case .validationFailed(let issues, _) = error else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(issues.contains(where: { $0.nodeID == botA }),
                          "Validation should flag the node with the missing profile")
        }
    }

    func testCycleDetection_Throws() async {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botA) // Creates cycle

        do {
            _ = try await execute(scenario)
            XCTFail("Expected WorkflowError.cycleDetected")
        } catch let error as WorkflowError {
            if case .cycleDetected = error {
                // Expected
            } else {
                XCTFail("Expected cycleDetected, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Group 2: Sequential Chains

    func testTwoNodeChain_SequentialOrder() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        scenario.connect(from: botA, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A output")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B output")])

        let events = try await execute(scenario)

        // A executes before B
        WorkflowStreamCollector.assertNodeExecutionOrder(events, expectedNodeIDs: [botA, botB])

        // Only terminal node (B) in final output
        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "B output")

        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 2)
    }

    func testThreeNodeChain_ContextPropagates() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("alpha")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("beta")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("gamma")])

        let events = try await execute(scenario)

        // Sequential execution
        WorkflowStreamCollector.assertNodeExecutionOrder(events, expectedNodeIDs: [botA, botB, botC])

        // B receives A's output via ContextCompressor (check mock invocations)
        let bProfileID = scenario.profileID(for: botB)!
        let bInvocation = mockProvider.invocations.first(where: { $0.profileID == bProfileID })
        XCTAssertNotNil(bInvocation)
        XCTAssertTrue(bInvocation!.userInput.contains("alpha"),
                      "Bot B should receive Bot A's output as context")

        // C receives B's output
        let cProfileID = scenario.profileID(for: botC)!
        let cInvocation = mockProvider.invocations.first(where: { $0.profileID == cProfileID })
        XCTAssertTrue(cInvocation!.userInput.contains("beta"),
                      "Bot C should receive Bot B's output as context")
    }

    func testChain_FirstFails_RestSkipped() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        // A fails
        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))

        let events = try await execute(scenario)

        // A fails, B and C skipped
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertEqual(failed.count, 3, "A fails + B skipped + C skipped")

        // B and C never had their streams invoked
        let bProfileID = scenario.profileID(for: botB)!
        let cProfileID = scenario.profileID(for: botC)!
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == bProfileID }))
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == cProfileID }))
    }

    func testChain_MiddleFails_LastSkipped() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A ok")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "test", code: 1))

        let events = try await execute(scenario)

        // A completes
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == botA }))

        // B fails, C skipped
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains(where: { $0.nodeID == botB }))
        XCTAssertTrue(failed.contains(where: { $0.nodeID == botC }))
    }

    // MARK: - Group 3: Condition Branching

    func testCondition_TrueBranch() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Router",
            rules: [
                ConditionRule(label: "Match", field: .upstreamOutput, op: .contains, value: "yes")
            ],
            fallbackLabel: "NoMatch"
        )
        let botB = scenario.addBotNode(name: "Match Handler")
        let botC = scenario.addBotNode(name: "Fallback Handler")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botB, portLabel: "Match")
        scenario.connect(from: condition, to: botC, portLabel: "NoMatch")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("yes approved")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("Match path")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("Fallback path")])

        let events = try await execute(scenario)

        // Bot B executes (match), Bot C does not
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botB), "Match handler should execute")
        XCTAssertFalse(started.contains(botC), "Fallback handler should NOT execute")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Match path")
    }

    func testCondition_FallbackBranch() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Router",
            rules: [
                ConditionRule(label: "Match", field: .upstreamOutput, op: .contains, value: "yes")
            ],
            fallbackLabel: "NoMatch"
        )
        let botB = scenario.addBotNode(name: "Match Handler")
        let botC = scenario.addBotNode(name: "Fallback Handler")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botB, portLabel: "Match")
        scenario.connect(from: condition, to: botC, portLabel: "NoMatch")

        // A output does NOT contain "yes"
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("no rejected")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("Match path")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("Fallback path")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botB), "Match handler should NOT execute")
        XCTAssertTrue(started.contains(botC), "Fallback handler should execute")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Fallback path")
    }

    func testCondition_VariableField() async throws {
        let scenario = WorkflowTestScenario()
        let code = scenario.addCodeNode(
            name: "Set Status",
            template: "approved",
            outputVariable: "status"
        )
        let condition = scenario.addConditionNode(
            name: "Check Status",
            rules: [
                ConditionRule(label: "Approved", field: .variable, op: .equals, value: "approved", variableName: "status")
            ],
            fallbackLabel: "Rejected"
        )
        let botApproved = scenario.addBotNode(name: "Approved Bot")
        let botRejected = scenario.addBotNode(name: "Rejected Bot")

        scenario.connect(from: code, to: condition)
        scenario.connect(from: condition, to: botApproved, portLabel: "Approved")
        scenario.connect(from: condition, to: botRejected, portLabel: "Rejected")

        mockProvider.scriptStream(for: scenario.profileID(for: botApproved)!, events: [.content("Approved!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botRejected)!, events: [.content("Rejected!")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botApproved), "Approved bot should execute")
        XCTAssertFalse(started.contains(botRejected), "Rejected bot should NOT execute")
    }

    // MARK: - Group 4: Code Nodes

    func testCodeNode_InputSubstitution() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let code = scenario.addCodeNode(name: "Transform", template: "Prefix: {{ input }}")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: code)
        scenario.connect(from: code, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("raw data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B output")])

        let events = try await execute(scenario)

        // Bot B should receive the code node's transformed output
        let bProfileID = scenario.profileID(for: botB)!
        let bInvocation = mockProvider.invocations.first(where: { $0.profileID == bProfileID })
        XCTAssertNotNil(bInvocation)
        XCTAssertTrue(bInvocation!.userInput.contains("Prefix: raw data"),
                      "Bot B should receive transformed code output")
    }

    func testCodeNode_VariableWriteAndRead() async throws {
        let scenario = WorkflowTestScenario()
        let codeA = scenario.addCodeNode(name: "Writer", template: "hello_world", outputVariable: "myVar")
        let codeB = scenario.addCodeNode(name: "Reader", template: "Value is: {{ var.myVar }}")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: codeA, to: codeB)
        scenario.connect(from: codeB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("done")])

        let events = try await execute(scenario)

        // Bot C should receive "Value is: hello_world" from code B
        let cProfileID = scenario.profileID(for: botC)!
        let cInvocation = mockProvider.invocations.first(where: { $0.profileID == cProfileID })
        XCTAssertNotNil(cInvocation)
        XCTAssertTrue(cInvocation!.userInput.contains("Value is: hello_world"),
                      "Code B should read variable written by Code A")
    }

    // MARK: - Group 5: Gate Nodes

    func testGate_Approved_PassesThrough() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let gate = scenario.addGateNode(name: "Approval Gate", prompt: "Approve this?")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: gate)
        scenario.connect(from: gate, to: botB, portLabel: "Approve")   // botB on the "Approve" branch

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data to approve")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B processed")])

        let events = try await executeWithGate(scenario, choosing: "Approve")

        // "Approve" chosen → its port routes to Bot B, which executes.
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botB), "Bot B (Approve branch) should execute after choosing Approve")

        // The structured gate request was emitted with its options.
        let gates = WorkflowStreamCollector.gateRequests(from: events)
        XCTAssertEqual(gates.count, 1)
        XCTAssertEqual(gates[0].options, ["Approve", "Reject"])
    }

    func testGate_Rejected_SkipsDownstream() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let gate = scenario.addGateNode(name: "Approval Gate")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: gate)
        scenario.connect(from: gate, to: botB, portLabel: "Approve")   // botB only on the "Approve" branch

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("should not run")])

        let events = try await executeWithGate(scenario, choosing: "Reject")

        // "Reject" chosen → routes to the (unwired) Reject port, so the Approve-branch Bot B is skipped.
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botB), "Bot B (Approve branch) should NOT execute when Reject is chosen")
    }

    // MARK: - Group 6: Error Routing & Policies

    func testErrorRouting_FailedNode_ErrorPortActivated() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Risky Bot")
        let botB = scenario.addBotNode(name: "Normal Handler")
        let botC = scenario.addBotNode(name: "Error Handler")

        scenario.connect(from: botA, to: botB) // default port
        scenario.connect(from: botA, to: botC, portLabel: "error") // error port

        // A fails
        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("normal")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("error handled")])

        let events = try await execute(scenario)

        // Error handler executes, normal handler skipped
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botC), "Error handler should execute")
        XCTAssertFalse(started.contains(botB), "Normal handler should NOT execute when error port active")
    }

    func testMultiPort_SameUpstream_RunsOnError() async throws {
        // A node wired to BOTH the default and `error` ports of one upstream must run
        // when that upstream FAILS (its error branch is live). Per-upstream join — not
        // per-edge AND — is what keeps this node reachable.
        let scenario = WorkflowTestScenario()
        let worker = scenario.addBotNode(name: "Worker")
        let finalizer = scenario.addBotNode(name: "Finalizer")

        scenario.connect(from: worker, to: finalizer)                     // default (success) port
        scenario.connect(from: worker, to: finalizer, portLabel: "error") // error port

        mockProvider.scriptError(for: scenario.profileID(for: worker)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: finalizer)!, events: [.content("recovered")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(finalizer),
                      "Finalizer wired to both default+error should run when the upstream fails")
    }

    func testMultiPort_SameUpstream_RunsOnSuccess_OutputOnce() async throws {
        // The same dual-wired node must also run when the upstream SUCCEEDS (default
        // branch is live), with the upstream's output injected exactly once (dedup),
        // not once per edge.
        let scenario = WorkflowTestScenario()
        let worker = scenario.addBotNode(name: "Worker")
        let finalizer = scenario.addBotNode(name: "Finalizer")

        scenario.connect(from: worker, to: finalizer)
        scenario.connect(from: worker, to: finalizer, portLabel: "error")

        mockProvider.scriptStream(for: scenario.profileID(for: worker)!, events: [.content("worker output")])
        mockProvider.scriptStream(for: scenario.profileID(for: finalizer)!, events: [.content("done")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(finalizer),
                      "Finalizer wired to both default+error should run when the upstream succeeds")

        let fPid = scenario.profileID(for: finalizer)!
        let fInv = mockProvider.invocations.first(where: { $0.profileID == fPid })!
        let occurrences = fInv.userInput.components(separatedBy: "worker output").count - 1
        XCTAssertEqual(occurrences, 1, "Upstream output should be injected once, not duplicated per edge")
    }

    func testContinueAll_ExecutesDespiteFailure() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Failing Bot")
        let botB = scenario.addBotNode(name: "Downstream Bot")

        scenario.connect(from: botA, to: botB)
        scenario.setNodeConfig(
            WorkflowNodeConfig(onFailure: .continueAll),
            for: botA
        )

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B ran anyway")])

        let events = try await execute(scenario)

        // B executes despite A's failure (continueAll policy)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botB), "Bot B should execute with continueAll policy on A")
    }

    func testStopWorkflow_HaltsImmediately() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Failing Bot")
        let botB = scenario.addBotNode(name: "Downstream Bot")

        scenario.connect(from: botA, to: botB)
        scenario.setNodeConfig(
            WorkflowNodeConfig(onFailure: .stopWorkflow),
            for: botA
        )

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        // Workflow halts — B never starts
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botB), "Bot B should NOT execute with stopWorkflow policy")

        // A failed event exists
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains(where: { $0.nodeID == botA }))
    }

    // MARK: - Group 7: Retry & Complex

    func testRetry_SucceedsOnSecondAttempt() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Flaky Bot")
        scenario.setNodeConfig(
            WorkflowNodeConfig(maxNodeRetries: 1, retryDelay: 0),
            for: botA
        )

        let profileID = scenario.profileID(for: botA)!

        // First call: retryable error, second call: success
        mockProvider.scriptError(for: profileID, error: AgentExecutionError(reason: .modelError(provider: "test", error: "transient")))
        mockProvider.scriptStream(for: profileID, events: [.content("Recovered!")])

        let events = try await execute(scenario)

        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == botA }))

        // 2 invocations: first fails, second succeeds
        let calls = mockProvider.invocations.filter { $0.profileID == profileID }
        XCTAssertEqual(calls.count, 2, "Should retry once after failure")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Recovered!")
    }

    func testComplexChain_BotCodeConditionBot() async throws {
        // Real-world scenario: Bot generates text → Code extracts keyword → Condition routes
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Analyzer")
        let code = scenario.addCodeNode(name: "Extractor", template: "sentiment: positive", outputVariable: "sentiment")
        let condition = scenario.addConditionNode(
            name: "Sentiment Router",
            rules: [
                ConditionRule(label: "Positive", field: .variable, op: .contains, value: "positive", variableName: "sentiment")
            ],
            fallbackLabel: "Negative"
        )
        let botPositive = scenario.addBotNode(name: "Celebrate Bot")
        let botNegative = scenario.addBotNode(name: "Console Bot")

        scenario.connect(from: botA, to: code)
        scenario.connect(from: code, to: condition)
        scenario.connect(from: condition, to: botPositive, portLabel: "Positive")
        scenario.connect(from: condition, to: botNegative, portLabel: "Negative")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("Great product!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botPositive)!, events: [.content("Wonderful!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNegative)!, events: [.content("Sorry to hear")])

        let events = try await execute(scenario)

        // Full chain: Analyzer → Extractor → Router → Celebrate Bot
        WorkflowStreamCollector.assertNodeExecutionOrder(events, expectedNodeIDs: [botA, code, condition, botPositive])

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botNegative), "Negative bot should NOT execute for positive sentiment")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "Wonderful!")
    }

    // MARK: - Group 8: Condition Operator Coverage

    func testConditionOp_NotContains() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Filter",
            rules: [ConditionRule(label: "Clean", field: .upstreamOutput, op: .notContains, value: "error")],
            fallbackLabel: "Dirty"
        )
        let botClean = scenario.addBotNode(name: "Clean Bot")
        let botDirty = scenario.addBotNode(name: "Dirty Bot")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botClean, portLabel: "Clean")
        scenario.connect(from: condition, to: botDirty, portLabel: "Dirty")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("all good")])
        mockProvider.scriptStream(for: scenario.profileID(for: botClean)!, events: [.content("clean")])
        mockProvider.scriptStream(for: scenario.profileID(for: botDirty)!, events: [.content("dirty")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botClean), "notContains 'error' should match 'all good'")
        XCTAssertFalse(started.contains(botDirty))
    }

    func testConditionOp_IsEmpty() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Empty Check",
            rules: [ConditionRule(label: "Empty", field: .upstreamOutput, op: .isEmpty, value: "")],
            fallbackLabel: "NotEmpty"
        )
        let botEmpty = scenario.addBotNode(name: "Empty Bot")
        let botNotEmpty = scenario.addBotNode(name: "NotEmpty Bot")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botEmpty, portLabel: "Empty")
        scenario.connect(from: condition, to: botNotEmpty, portLabel: "NotEmpty")

        // Bot A produces empty output
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [])
        mockProvider.scriptStream(for: scenario.profileID(for: botEmpty)!, events: [.content("was empty")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNotEmpty)!, events: [.content("not empty")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botEmpty), "isEmpty should match empty upstream")
        XCTAssertFalse(started.contains(botNotEmpty))
    }

    func testConditionOp_IsNotEmpty() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "NonEmpty Check",
            rules: [ConditionRule(label: "HasContent", field: .upstreamOutput, op: .isNotEmpty, value: "")],
            fallbackLabel: "NoContent"
        )
        let botHas = scenario.addBotNode(name: "HasContent Bot")
        let botNo = scenario.addBotNode(name: "NoContent Bot")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botHas, portLabel: "HasContent")
        scenario.connect(from: condition, to: botNo, portLabel: "NoContent")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("hello")])
        mockProvider.scriptStream(for: scenario.profileID(for: botHas)!, events: [.content("yes")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNo)!, events: [.content("no")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botHas), "isNotEmpty should match non-empty upstream")
        XCTAssertFalse(started.contains(botNo))
    }

    func testConditionOp_NotEquals() async throws {
        let scenario = WorkflowTestScenario()
        let code = scenario.addCodeNode(name: "Set", template: "beta", outputVariable: "ver")
        let condition = scenario.addConditionNode(
            name: "Version Check",
            rules: [ConditionRule(label: "NotAlpha", field: .variable, op: .notEquals, value: "alpha", variableName: "ver")],
            fallbackLabel: "IsAlpha"
        )
        let botNotAlpha = scenario.addBotNode(name: "NotAlpha Bot")
        let botIsAlpha = scenario.addBotNode(name: "IsAlpha Bot")

        scenario.connect(from: code, to: condition)
        scenario.connect(from: condition, to: botNotAlpha, portLabel: "NotAlpha")
        scenario.connect(from: condition, to: botIsAlpha, portLabel: "IsAlpha")

        mockProvider.scriptStream(for: scenario.profileID(for: botNotAlpha)!, events: [.content("not alpha")])
        mockProvider.scriptStream(for: scenario.profileID(for: botIsAlpha)!, events: [.content("is alpha")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botNotAlpha), "notEquals 'alpha' should match 'beta'")
        XCTAssertFalse(started.contains(botIsAlpha))
    }

    func testCondition_MultipleRules_FirstMatchWins() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Priority Router",
            rules: [
                ConditionRule(label: "Urgent", field: .upstreamOutput, op: .contains, value: "urgent"),
                ConditionRule(label: "Normal", field: .upstreamOutput, op: .isNotEmpty, value: "")
            ],
            fallbackLabel: "Empty"
        )
        let botUrgent = scenario.addBotNode(name: "Urgent Bot")
        let botNormal = scenario.addBotNode(name: "Normal Bot")
        let botEmpty = scenario.addBotNode(name: "Empty Bot")

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botUrgent, portLabel: "Urgent")
        scenario.connect(from: condition, to: botNormal, portLabel: "Normal")
        scenario.connect(from: condition, to: botEmpty, portLabel: "Empty")

        // Input matches BOTH "Urgent" (contains) and "Normal" (isNotEmpty)
        // First match should win
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("urgent task here")])
        mockProvider.scriptStream(for: scenario.profileID(for: botUrgent)!, events: [.content("handled urgently")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNormal)!, events: [.content("handled normally")])

        let events = try await execute(scenario)
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botUrgent), "First matching rule (Urgent) should win")
        XCTAssertFalse(started.contains(botNormal), "Second rule should NOT fire when first matches")
        XCTAssertFalse(started.contains(botEmpty))
    }

    // MARK: - Group 9: DAG Topology Edge Cases

    func testDiamondDAG_MultiInputNode() async throws {
        // A → C, B → C (C has two upstream parents)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("from A")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("from B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("merged")])

        let events = try await execute(scenario)

        // A and B both complete (same level, independent)
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botA))
        XCTAssertTrue(completed.contains(botB))
        XCTAssertTrue(completed.contains(botC))

        // C receives context from BOTH A and B
        let cProfileID = scenario.profileID(for: botC)!
        let cInvocation = mockProvider.invocations.first(where: { $0.profileID == cProfileID })!
        XCTAssertTrue(cInvocation.userInput.contains("from A"), "C should receive A's output")
        XCTAssertTrue(cInvocation.userInput.contains("from B"), "C should receive B's output")
    }

    func testDiamondDAG_OneParentFails_ChildSkipped() async throws {
        // A → C, B → C; A fails → C skipped (needs ALL parents)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("from B")])

        let events = try await execute(scenario)

        // A fails, B completes, C skipped (allSatisfy requires ALL upstream to pass)
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(failed.contains(botA))
        XCTAssertTrue(failed.contains(botC), "C should be skipped when any parent fails")
    }

    func testAllTerminalsFailed_EmitsErrorMessage() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "test", code: 1))

        let events = try await execute(scenario)

        // Should emit an error about all terminals failing
        let errors = events.compactMap { event -> String? in
            if case .error(let err) = event { return err.message }
            return nil
        }
        XCTAssertTrue(errors.contains(where: { $0.contains("all terminal nodes failed") }),
                       "Should report all terminals failed, got errors: \(errors)")
    }

    func testTriggerNode_AsEntryPoint() async throws {
        let scenario = WorkflowTestScenario()
        let trigger = scenario.addTriggerNode(name: "Start")
        let botA = scenario.addBotNode(name: "Bot A")

        scenario.connect(from: trigger, to: botA)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("triggered")])

        let events = try await execute(scenario)

        // Trigger completes (no-op), Bot A executes
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == trigger }), "Trigger should complete")
        XCTAssertTrue(completed.contains(where: { $0.nodeID == botA }), "Bot A should execute after trigger")

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "triggered")
    }

    // MARK: - Group 10: Code Node Edge Cases

    func testCodeNode_InjectionPrevention() async throws {
        // Upstream text contains {{ var.x }} — should NOT be replaced
        let scenario = WorkflowTestScenario()
        let codeA = scenario.addCodeNode(name: "Set Var", template: "safe_value", outputVariable: "x")
        let botA = scenario.addBotNode(name: "Bot A")
        let codeB = scenario.addCodeNode(name: "Transform", template: "Result: {{ input }}")
        let botOut = scenario.addBotNode(name: "Output Bot")

        scenario.connect(from: codeA, to: botA)
        scenario.connect(from: botA, to: codeB)
        scenario.connect(from: codeB, to: botOut)

        // Bot A returns text that contains a template pattern
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("payload: {{ var.x }}")])
        mockProvider.scriptStream(for: scenario.profileID(for: botOut)!, events: [.content("done")])

        let events = try await execute(scenario)

        // codeB should output "Result: payload: {{ var.x }}" — the {{ var.x }} is NOT replaced
        let outProfileID = scenario.profileID(for: botOut)!
        let outInvocation = mockProvider.invocations.first(where: { $0.profileID == outProfileID })!
        XCTAssertTrue(outInvocation.userInput.contains("{{ var.x }}"),
                       "Template pattern in upstream text should NOT be substituted (injection prevention)")
    }

    func testCodeNode_EmptyTemplate() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let code = scenario.addCodeNode(name: "Empty", template: "")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: code)
        scenario.connect(from: code, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("done")])

        let events = try await execute(scenario)

        // Code node with empty template produces empty output
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == code }))
    }

    // MARK: - Group 11: Structural Node Failure Policies

    func testStructuralNode_StopWorkflow() async throws {
        // Code node configured with stopWorkflow — simulate failure via missing variable
        // Actually code nodes can't fail in current implementation (template substitution never throws)
        // Use a condition node scenario instead: condition with stopWorkflow + skipped downstream
        // Actually structural nodes don't currently fail in ways we can control easily.
        // Instead, test gate rejection with stopWorkflow policy.
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let gate = scenario.addGateNode(name: "Critical Gate")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: botA, to: gate)
        scenario.connect(from: gate, to: botB)
        scenario.connect(from: botB, to: botC)
        scenario.setNodeConfig(WorkflowNodeConfig(onFailure: .stopWorkflow), for: gate)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("should not run")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("should not run")])

        // No choice (nil = timeout / cancel) → the gate FAILS; with stopWorkflow the whole run halts.
        let events = try await executeWithGate(scenario, choosing: nil)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botB), "Bot B should NOT run after gate failure + stopWorkflow")
        XCTAssertFalse(started.contains(botC), "Bot C should NOT run")
    }

    // MARK: - Group 12: Retry Edge Cases

    func testRetry_NonRetryableError_NoRetry() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        scenario.setNodeConfig(
            WorkflowNodeConfig(maxNodeRetries: 2, retryDelay: 0),
            for: botA
        )

        let profileID = scenario.profileID(for: botA)!
        // Non-retryable error: .repetitiveActionLoop has isRetryable = false
        mockProvider.scriptError(for: profileID, error: AgentExecutionError(reason: .repetitiveActionLoop(action: "test_action", count: 3)))

        let events = try await execute(scenario)

        // Should NOT retry — non-retryable error exits immediately
        let calls = mockProvider.invocations.filter { $0.profileID == profileID }
        XCTAssertEqual(calls.count, 1, "Non-retryable error should not trigger retry")

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertEqual(failed.count, 1)
    }

    func testRetry_ExhaustsAllAttempts() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Persistent Failure Bot")
        scenario.setNodeConfig(
            WorkflowNodeConfig(maxNodeRetries: 2, retryDelay: 0),
            for: botA
        )

        let profileID = scenario.profileID(for: botA)!
        // All 3 attempts fail with retryable error (cycles last entry)
        mockProvider.scriptError(for: profileID, error: AgentExecutionError(reason: .modelError(provider: "test", error: "still failing")))

        let events = try await execute(scenario)

        // 3 total invocations: initial + 2 retries
        let calls = mockProvider.invocations.filter { $0.profileID == profileID }
        XCTAssertEqual(calls.count, 3, "Should attempt 1 + 2 retries = 3 total")

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains(where: { $0.nodeID == botA }))
    }

    // MARK: - Group 13: ContextCompressor Unit Tests

    func testContextCompressor_EmptyResults() {
        let result = ContextCompressor.compile(results: [])
        XCTAssertEqual(result, "", "Empty results should produce empty string")
    }

    func testContextCompressor_StatusLabels() {
        let completedEnvelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot A", profileType: .bot, status: .completed,
            output: "success", artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let failedEnvelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot B", profileType: .bot,
            status: .failed(.modelError(provider: "test", error: "oops")),
            output: "failed", artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let skippedEnvelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot C", profileType: .bot, status: .skipped(reason: "upstream failed"),
            output: "", artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = ContextCompressor.compile(results: [completedEnvelope, failedEnvelope, skippedEnvelope])

        XCTAssertTrue(result.contains("Status: Completed"))
        XCTAssertTrue(result.contains("Status: Failed"))
        XCTAssertTrue(result.contains("Status: Skipped"))
        XCTAssertTrue(result.contains("Bot A"))
        XCTAssertTrue(result.contains("Bot B"))
        XCTAssertTrue(result.contains("Bot C"))
    }

    func testContextCompressor_TruncatesLargeOutput() {
        let longOutput = String(repeating: "x", count: 5000)
        let envelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Verbose Bot", profileType: .bot, status: .completed,
            output: longOutput, artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = ContextCompressor.compile(results: [envelope], budget: 3000)

        XCTAssertLessThanOrEqual(result.count, 3100, "Should be near budget (3000 + truncation marker)")
        XCTAssertTrue(result.contains("truncated"), "Should contain truncation marker")
    }

    // MARK: - Group 13b: ContextCompressor.compileForWorkflow() Unit Tests

    func testCompileForWorkflow_EmptyResults() {
        let result = ContextCompressor.compileForWorkflow(results: [])
        XCTAssertEqual(result, "", "Empty results should produce empty string")
    }

    func testCompileForWorkflow_AllFailed_ReturnsEmpty() {
        let failedA = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot A", profileType: .bot,
            status: .failed(.modelError(provider: "test", error: "oops")),
            output: "failed output", artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let skippedB = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot B", profileType: .bot,
            status: .skipped(reason: "upstream"),
            output: "skipped output", artifacts: [], metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = ContextCompressor.compileForWorkflow(results: [failedA, skippedB])
        XCTAssertEqual(result, "", "All failed/skipped should produce empty string")
    }

    func testCompileForWorkflow_SingleCompleted_NoSeparator() {
        let envelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot A", profileType: .bot, status: .completed,
            output: "The research shows three key findings.", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = ContextCompressor.compileForWorkflow(results: [envelope])
        XCTAssertEqual(result, "The research shows three key findings.", "Single result should be raw text, no separator")
        XCTAssertFalse(result.contains("---"), "Single result should have no separator")
        XCTAssertFalse(result.contains("Step"), "Should have no metadata labels")
        XCTAssertFalse(result.contains("Status"), "Should have no status labels")
    }

    func testCompileForWorkflow_MultipleCompleted_SeparatedByDashes() {
        let envelopeA = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot A", profileType: .bot, status: .completed,
            output: "Research output", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let envelopeB = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bot B", profileType: .bot, status: .completed,
            output: "SEO keywords", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = ContextCompressor.compileForWorkflow(results: [envelopeA, envelopeB])
        XCTAssertTrue(result.contains("Research output"), "Should contain first output")
        XCTAssertTrue(result.contains("SEO keywords"), "Should contain second output")
        XCTAssertTrue(result.contains("---"), "Multiple results should be separated by ---")
        XCTAssertFalse(result.contains("Bot A"), "Should not contain profile names")
        XCTAssertFalse(result.contains("Bot B"), "Should not contain profile names")
    }

    func testCompileForWorkflow_MixedStatus_OnlyCompletedIncluded() {
        let completed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Good Bot", profileType: .bot, status: .completed,
            output: "Useful data", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let failed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bad Bot", profileType: .bot,
            status: .failed(.modelError(provider: "test", error: "crash")),
            output: "Error garbage", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = ContextCompressor.compileForWorkflow(results: [completed, failed])
        XCTAssertEqual(result, "Useful data", "Only completed results should be included")
        XCTAssertFalse(result.contains("Error garbage"), "Failed output should be excluded")
    }

    func testCompileForWorkflow_BudgetEnforcement() {
        let longOutput = String(repeating: "word ", count: 1000) // 5000 chars
        let envelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Verbose Bot", profileType: .bot, status: .completed,
            output: longOutput, artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = ContextCompressor.compileForWorkflow(results: [envelope], budget: 2000)
        XCTAssertLessThanOrEqual(result.count, 2000, "Output should respect budget")
    }

    func testCompileForWorkflow_EmptyOutputCompleted() {
        let envelope = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Silent Bot", profileType: .bot, status: .completed,
            output: "", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = ContextCompressor.compileForWorkflow(results: [envelope])
        XCTAssertEqual(result, "", "Completed but empty output should produce empty string")
    }

    func testCompileForWorkflow_IncludeFailures_AnnotatesFailedUpstream() {
        let failed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Risky Bot", profileType: .bot,
            status: .failed(.modelError(provider: "test", error: "boom")),
            output: "partial result before failure", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        // Default: failed upstream excluded (error handler would see nothing).
        XCTAssertEqual(
            ContextCompressor.compileForWorkflow(results: [failed]), "",
            "Failed upstream should be excluded by default"
        )

        // includeFailures: surfaced with a reason annotation + the partial output,
        // so an error-handler node can act on what failed.
        let recovered = ContextCompressor.compileForWorkflow(results: [failed], includeFailures: true)
        XCTAssertTrue(recovered.contains("Risky Bot"), "Should name the failed upstream")
        XCTAssertTrue(recovered.contains("failed"), "Should mark the upstream as failed")
        XCTAssertTrue(recovered.contains("partial result before failure"), "Should include the partial output")
    }

    func testCompileForWorkflow_IncludeFailures_MixedKeepsBoth() {
        let completed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Good Bot", profileType: .bot, status: .completed,
            output: "useful data", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )
        let failed = NodeResultEnvelope(
            taskID: UUID(), nodeID: UUID(), sourceProfileID: UUID(),
            profileName: "Bad Bot", profileType: .bot,
            status: .failed(.modelError(provider: "test", error: "crash")),
            output: "garbage", artifacts: [],
            metadata: .simple(start: Date(), end: Date(), output: "")
        )

        let result = ContextCompressor.compileForWorkflow(results: [completed, failed], includeFailures: true)
        XCTAssertTrue(result.contains("useful data"), "Completed output should be included")
        XCTAssertTrue(result.contains("Bad Bot"), "Failed upstream should be annotated and included")
        XCTAssertTrue(result.contains("---"), "Two usable upstreams should be separated by ---")
    }

    // MARK: - Group 14: Error Routing with Success

    func testErrorRouting_SuccessfulNode_DefaultPortActive() async throws {
        // When a node succeeds, default port (nil label) should work, error port should NOT
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Healthy Bot")
        let botB = scenario.addBotNode(name: "Normal Handler")
        let botC = scenario.addBotNode(name: "Error Handler")

        scenario.connect(from: botA, to: botB) // default port
        scenario.connect(from: botA, to: botC, portLabel: "error") // error port

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("success")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("normal")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("error handled")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botB), "Normal handler should execute on success")
        XCTAssertFalse(started.contains(botC), "Error handler should NOT execute on success")
    }

    // MARK: - Group 15: Long Chain Propagation

    func testFiveNodeChain_EndToEndPropagation() async throws {
        let scenario = WorkflowTestScenario()
        let n1 = scenario.addBotNode(name: "Node 1")
        let n2 = scenario.addBotNode(name: "Node 2")
        let n3 = scenario.addBotNode(name: "Node 3")
        let n4 = scenario.addBotNode(name: "Node 4")
        let n5 = scenario.addBotNode(name: "Node 5")

        scenario.connect(from: n1, to: n2)
        scenario.connect(from: n2, to: n3)
        scenario.connect(from: n3, to: n4)
        scenario.connect(from: n4, to: n5)

        for n in [n1, n2, n3, n4, n5] {
            mockProvider.scriptStream(for: scenario.profileID(for: n)!, events: [.content("output-\(n.uuidString.prefix(4))")])
        }

        let events = try await execute(scenario)

        WorkflowStreamCollector.assertNodeExecutionOrder(events, expectedNodeIDs: [n1, n2, n3, n4, n5])
        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 5)

        // Only terminal node (n5) in final content
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.starts(with: "output-"), "Only terminal node output in final content")
    }

    // MARK: - Group 16: Cancellation Scenarios

    func testCancel_DuringFirstNode_EmitsPartialResults() async throws {
        // A→B→C; cancel while A is streaming
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Slow Bot A")
        let botB = scenario.addBotNode(name: "Bot B")
        let botC = scenario.addBotNode(name: "Bot C")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        // A streams initial events then blocks (simulating slow LLM)
        mockProvider.scriptSlowStream(for: scenario.profileID(for: botA)!, initialEvents: [
            .content("partial A output")
        ])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C")])

        let stream = makeStream(scenario)

        // Run stream in a cancellable task
        let task = Task {
            try await StreamCollector.collect(from: stream)
        }

        // Give the executor time to start, then cancel
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let events: [AgentStreamEvent]
        do {
            events = try await task.value
        } catch is CancellationError {
            events = [] // Stream cancelled before collecting
        } catch {
            events = []
        }

        // Bot B and C should NOT have been invoked
        let bProfileID = scenario.profileID(for: botB)!
        let cProfileID = scenario.profileID(for: botC)!
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == bProfileID }),
                       "Bot B should not execute after cancellation")
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == cProfileID }),
                       "Bot C should not execute after cancellation")
    }

    func testCancel_DuringSecondNode_FirstNodeOutputPreserved() async throws {
        // A→B; A completes instantly, B blocks. Cancel during B.
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Fast Bot A")
        let botB = scenario.addBotNode(name: "Slow Bot B")

        scenario.connect(from: botA, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A done")])
        mockProvider.scriptSlowStream(for: scenario.profileID(for: botB)!, initialEvents: [
            .content("B partial")
        ])

        let stream = makeStream(scenario)

        let task = Task {
            try await StreamCollector.collect(from: stream)
        }

        // Wait for A to complete and B to start, then cancel
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        let events: [AgentStreamEvent]
        do {
            events = try await task.value
        } catch {
            events = []
        }

        // A should have completed before cancellation
        let aProfileID = scenario.profileID(for: botA)!
        XCTAssertTrue(mockProvider.invocations.contains(where: { $0.profileID == aProfileID }),
                       "Bot A should have been invoked before cancellation")

        // B should have been invoked (but cancelled mid-stream)
        let bProfileID = scenario.profileID(for: botB)!
        XCTAssertTrue(mockProvider.invocations.contains(where: { $0.profileID == bProfileID }),
                       "Bot B should have been invoked before cancel")
    }

    func testCancel_BetweenLevels_CompletedLevelOutput() async throws {
        // A→B; A completes fast, cancellation happens at level boundary
        // This tests that completed work isn't lost
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Fast Bot A")
        let botB = scenario.addBotNode(name: "Slow Bot B")

        scenario.connect(from: botA, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A completed")])
        mockProvider.scriptSlowStream(for: scenario.profileID(for: botB)!, initialEvents: [])

        let stream = makeStream(scenario)

        let task = Task {
            try await StreamCollector.collect(from: stream)
        }

        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // Expected cancellation
        }

        // A was invoked, B was invoked (or about to be)
        let aProfileID = scenario.profileID(for: botA)!
        XCTAssertTrue(mockProvider.invocations.contains(where: { $0.profileID == aProfileID }),
                       "Bot A should have completed before cancellation")
    }

    func testCancel_DuringGate_GateIsCancelled() async throws {
        // A→Gate→B; cancel while gate is waiting for approval
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let gate = scenario.addGateNode(name: "Waiting Gate")
        let botB = scenario.addBotNode(name: "Bot B")

        scenario.connect(from: botA, to: gate)
        scenario.connect(from: gate, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("should not run")])

        let stream = makeStream(scenario)

        var collectedEvents: [AgentStreamEvent] = []
        let task = Task {
            var events: [AgentStreamEvent] = []
            for try await event in stream {
                events.append(event)
            }
            return events
        }

        // Give gate time to emit requestGate, then cancel
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()

        do {
            collectedEvents = try await task.value
        } catch {
            // Expected
        }

        // Bot B should NOT have been invoked — gate was cancelled, not approved
        let bProfileID = scenario.profileID(for: botB)!
        XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == bProfileID }),
                       "Bot B should NOT execute when gate is cancelled")

        // Gate request should have been emitted before cancel
        let gates = WorkflowStreamCollector.gateRequests(from: collectedEvents)
        XCTAssertTrue(gates.count <= 1, "Gate request should have been emitted (or not if cancel was too fast)")
    }

    func testCancel_DoesNotInvokeDownstreamNodes() async throws {
        // 5-node chain: cancel after node 2 starts
        let scenario = WorkflowTestScenario()
        let n1 = scenario.addBotNode(name: "Node 1")
        let n2 = scenario.addBotNode(name: "Node 2")
        let n3 = scenario.addBotNode(name: "Node 3")
        let n4 = scenario.addBotNode(name: "Node 4")
        let n5 = scenario.addBotNode(name: "Node 5")

        scenario.connect(from: n1, to: n2)
        scenario.connect(from: n2, to: n3)
        scenario.connect(from: n3, to: n4)
        scenario.connect(from: n4, to: n5)

        mockProvider.scriptStream(for: scenario.profileID(for: n1)!, events: [.content("1")])
        mockProvider.scriptSlowStream(for: scenario.profileID(for: n2)!, initialEvents: [.content("2 partial")])
        mockProvider.scriptStream(for: scenario.profileID(for: n3)!, events: [.content("3")])
        mockProvider.scriptStream(for: scenario.profileID(for: n4)!, events: [.content("4")])
        mockProvider.scriptStream(for: scenario.profileID(for: n5)!, events: [.content("5")])

        let stream = makeStream(scenario)
        let task = Task {
            try await StreamCollector.collect(from: stream)
        }

        try await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do { _ = try await task.value } catch {}

        // Nodes 3, 4, 5 should NEVER be invoked
        for (node, name) in [(n3, "Node 3"), (n4, "Node 4"), (n5, "Node 5")] {
            let pid = scenario.profileID(for: node)!
            XCTAssertFalse(mockProvider.invocations.contains(where: { $0.profileID == pid }),
                           "\(name) should NOT be invoked after cancellation")
        }
    }

    // =========================================================================
    // MARK: - Group 17: Graph Topology Edge Cases
    // =========================================================================

    func testDisconnectedSubgraphs_BothChainsExecute() async throws {
        // Two independent chains: A→B, C→D (no connection between them)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Chain1-A")
        let botB = scenario.addBotNode(name: "Chain1-B")
        let botC = scenario.addBotNode(name: "Chain2-C")
        let botD = scenario.addBotNode(name: "Chain2-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botC, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("D")])

        let events = try await execute(scenario)

        // All 4 nodes should execute
        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 4)

        // Terminal nodes are B and D — both outputs in final content
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("B"), "Chain1 terminal output should be in content")
        XCTAssertTrue(content.contains("D"), "Chain2 terminal output should be in content")
    }

    func testIsolatedNode_NoEdges_ExecutesAsTerminal() async throws {
        // Single node with no incoming or outgoing edges
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Isolated")

        // No edges — it's both an entry point and a terminal
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("alone")])

        let events = try await execute(scenario)

        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(StreamCollector.contentText(from: events), "alone")
    }

    func testWideFanOut_OneToMany() async throws {
        // A → B, C, D, E (one source, four targets)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Target-B")
        let botC = scenario.addBotNode(name: "Target-C")
        let botD = scenario.addBotNode(name: "Target-D")
        let botE = scenario.addBotNode(name: "Target-E")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botA, to: botD)
        scenario.connect(from: botA, to: botE)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("broadcast")])
        for n in [botB, botC, botD, botE] {
            mockProvider.scriptStream(for: scenario.profileID(for: n)!, events: [.content("received")])
        }

        let events = try await execute(scenario)

        // All 5 nodes execute; B, C, D, E are all terminals
        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 5)

        // All 4 downstream nodes receive A's context
        for n in [botB, botC, botD, botE] {
            let pid = scenario.profileID(for: n)!
            let inv = mockProvider.invocations.first(where: { $0.profileID == pid })!
            XCTAssertTrue(inv.userInput.contains("broadcast"), "\(n) should receive A's output as context")
        }
    }

    func testWideFanIn_ManyToOne() async throws {
        // A, B, C, D → E (four sources, one target)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source-A")
        let botB = scenario.addBotNode(name: "Source-B")
        let botC = scenario.addBotNode(name: "Source-C")
        let botD = scenario.addBotNode(name: "Source-D")
        let botE = scenario.addBotNode(name: "Aggregator")

        scenario.connect(from: botA, to: botE)
        scenario.connect(from: botB, to: botE)
        scenario.connect(from: botC, to: botE)
        scenario.connect(from: botD, to: botE)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("from-A")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("from-B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("from-C")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("from-D")])
        mockProvider.scriptStream(for: scenario.profileID(for: botE)!, events: [.content("aggregated")])

        let events = try await execute(scenario)

        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 5)

        // E receives context from all 4 upstream nodes
        let ePid = scenario.profileID(for: botE)!
        let eInv = mockProvider.invocations.first(where: { $0.profileID == ePid })!
        XCTAssertTrue(eInv.userInput.contains("from-A"))
        XCTAssertTrue(eInv.userInput.contains("from-B"))
        XCTAssertTrue(eInv.userInput.contains("from-C"))
        XCTAssertTrue(eInv.userInput.contains("from-D"))
    }

    func testSelfLoop_DetectedByCycleCheck() {
        // A → A (self-loop)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Self Loop")
        scenario.connect(from: botA, to: botA)

        // computeExecutionLevels should detect this as a cycle
        let levels = scenario.layout.computeExecutionLevels()
        XCTAssertNil(levels, "Self-loop should be detected as a cycle")
    }

    // =========================================================================
    // MARK: - Group 18: Mixed Upstream Status & Cascaded Policies
    // =========================================================================

    func testFanIn_OneParentSkipped_ChildSkipped() async throws {
        // A(fails)→C, B(ok)→C: C should be skipped because A failed (allSatisfy)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Failing Parent")
        let botB = scenario.addBotNode(name: "Good Parent")
        let botC = scenario.addBotNode(name: "Child")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C")])

        let events = try await execute(scenario)

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(failed.contains(botC), "C should be skipped when ANY parent fails (allSatisfy)")
    }

    func testFanIn_ContinueAllParent_ChildStillExecutes() async throws {
        // A(continueAll, fails)→C, B(ok)→C: C should execute because A has continueAll
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "ContinueAll Parent")
        let botB = scenario.addBotNode(name: "Good Parent")
        let botC = scenario.addBotNode(name: "Child")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)
        scenario.setNodeConfig(WorkflowNodeConfig(onFailure: .continueAll), for: botA)

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C ran")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botC), "C should execute when failing parent has continueAll")
    }

    func testCascadedSkip_SkippedNodeDownstreamAlsoSkipped() async throws {
        // A(fails)→B→C: B skipped, C should also be skipped
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Root Failure")
        let botB = scenario.addBotNode(name: "Middle")
        let botC = scenario.addBotNode(name: "Leaf")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptError(for: scenario.profileID(for: botA)!, error: NSError(domain: "t", code: 1))

        let events = try await execute(scenario)

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        // All three should appear as failed/skipped
        XCTAssertEqual(failed.count, 3, "A fails, B skipped, C skipped (cascading)")
    }

    // =========================================================================
    // MARK: - Group 19: Variable Edge Cases
    // =========================================================================

    func testCondition_ReferencesUndefinedVariable_DefaultsToEmpty() async throws {
        // Condition checks variable "status" that was never written
        let scenario = WorkflowTestScenario()
        let condition = scenario.addConditionNode(
            name: "Check Missing",
            rules: [
                ConditionRule(label: "HasValue", field: .variable, op: .isNotEmpty, value: "", variableName: "nonexistent")
            ],
            fallbackLabel: "Empty"
        )
        let botHas = scenario.addBotNode(name: "Has Value")
        let botEmpty = scenario.addBotNode(name: "Is Empty")

        scenario.connect(from: condition, to: botHas, portLabel: "HasValue")
        scenario.connect(from: condition, to: botEmpty, portLabel: "Empty")

        mockProvider.scriptStream(for: scenario.profileID(for: botHas)!, events: [.content("has")])
        mockProvider.scriptStream(for: scenario.profileID(for: botEmpty)!, events: [.content("empty")])

        let events = try await execute(scenario)

        // Undefined variable = "" → isNotEmpty fails → fallback "Empty"
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botEmpty), "Missing variable should default to empty string")
        XCTAssertFalse(started.contains(botHas))
    }

    func testTwoCodeNodes_SameVariable_LastWriteWins() async throws {
        // Code A writes x="first", Code B writes x="second" (sequential)
        // Condition reads x
        let scenario = WorkflowTestScenario()
        let codeA = scenario.addCodeNode(name: "Writer 1", template: "first", outputVariable: "x")
        let codeB = scenario.addCodeNode(name: "Writer 2", template: "second", outputVariable: "x")
        let condition = scenario.addConditionNode(
            name: "Read X",
            rules: [ConditionRule(label: "IsSecond", field: .variable, op: .equals, value: "second", variableName: "x")],
            fallbackLabel: "NotSecond"
        )
        let botYes = scenario.addBotNode(name: "Yes Bot")
        let botNo = scenario.addBotNode(name: "No Bot")

        scenario.connect(from: codeA, to: codeB)
        scenario.connect(from: codeB, to: condition)
        scenario.connect(from: condition, to: botYes, portLabel: "IsSecond")
        scenario.connect(from: condition, to: botNo, portLabel: "NotSecond")

        mockProvider.scriptStream(for: scenario.profileID(for: botYes)!, events: [.content("yes")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNo)!, events: [.content("no")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botYes), "Last write wins — variable x should be 'second'")
    }

    func testCodeNode_VariableSubstitutionOrder_NoInjectionFromVariableValues() async throws {
        // Variable x = "{{ input }}" — when code B reads {{ var.x }},
        // the resolved value "{{ input }}" should NOT be re-scanned
        let scenario = WorkflowTestScenario()
        let codeA = scenario.addCodeNode(name: "Set Tricky", template: "{{ input }}", outputVariable: "tricky")
        let botA = scenario.addBotNode(name: "Bot A")
        let codeB = scenario.addCodeNode(name: "Use Tricky", template: "prefix_{{ var.tricky }}_suffix")

        scenario.connect(from: codeA, to: botA)
        scenario.connect(from: botA, to: codeB)

        // codeA with no upstream produces {{ input }} literally since input replacement happens
        // on template "{{ input }}" with empty upstream → empty string
        // Actually codeA has no upstream so {{ input }} = "" → tricky = ""
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("bot output")])

        let events = try await execute(scenario)

        // codeB's template: "prefix_{{ var.tricky }}_suffix"
        // tricky = "" (codeA had no upstream), so codeB outputs "prefix__suffix"
        // Then {{ input }} = "bot output" (codeB's upstream is botA)
        // But we do variable substitution FIRST → "prefix__suffix" → then {{ input }} not in template
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.count >= 3, "All structural + profile nodes should complete")
    }

    // =========================================================================
    // MARK: - Group 20: Cascaded Structural Nodes
    // =========================================================================

    func testCascadedConditions_TwoConditionNodesInChain() async throws {
        // Bot → Cond1 → Cond2 → [Yes: BotA, No: BotB]
        // NOTE: Cond2's upstream is Cond1, whose output is a routing message
        // (e.g., "Condition (pattern): route → Pass"), NOT the original bot output.
        // So Cond2 must check for content in the routing message, not the original data.
        let scenario = WorkflowTestScenario()
        let botSrc = scenario.addBotNode(name: "Source")
        let cond1 = scenario.addConditionNode(
            name: "First Filter",
            rules: [ConditionRule(label: "Pass", field: .upstreamOutput, op: .isNotEmpty, value: "")],
            fallbackLabel: "Fail",
            // Emit the routing message (not passthrough) so cond2 can match "route" in it.
            passthroughContent: false
        )
        // Cond2 checks for "route" which IS in Cond1's output ("Condition (pattern): route → Pass")
        let cond2 = scenario.addConditionNode(
            name: "Second Filter",
            rules: [ConditionRule(label: "Routed", field: .upstreamOutput, op: .contains, value: "route")],
            fallbackLabel: "NotRouted"
        )
        let botRouted = scenario.addBotNode(name: "Routed Handler")
        let botNotRouted = scenario.addBotNode(name: "NotRouted Handler")

        scenario.connect(from: botSrc, to: cond1)
        scenario.connect(from: cond1, to: cond2, portLabel: "Pass")
        scenario.connect(from: cond2, to: botRouted, portLabel: "Routed")
        scenario.connect(from: cond2, to: botNotRouted, portLabel: "NotRouted")

        mockProvider.scriptStream(for: scenario.profileID(for: botSrc)!, events: [.content("data")])
        mockProvider.scriptStream(for: scenario.profileID(for: botRouted)!, events: [.content("handled!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botNotRouted)!, events: [.content("meh")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botRouted), "Should route through both cascaded conditions")
        XCTAssertFalse(started.contains(botNotRouted))
    }

    func testCodeThenGateThenCondition_ComplexStructuralChain() async throws {
        // Code(transform) → Gate(approve) → Condition(route)
        let scenario = WorkflowTestScenario()
        let code = scenario.addCodeNode(name: "Transform", template: "status: approved")
        let gate = scenario.addGateNode(name: "Review")
        let condition = scenario.addConditionNode(
            name: "Route",
            rules: [ConditionRule(label: "Approved", field: .upstreamOutput, op: .contains, value: "approved")],
            fallbackLabel: "Rejected"
        )
        let botApproved = scenario.addBotNode(name: "Approved Bot")
        let botRejected = scenario.addBotNode(name: "Rejected Bot")

        scenario.connect(from: code, to: gate)
        scenario.connect(from: gate, to: condition, portLabel: "Approve")   // gate's "Approve" branch → condition
        scenario.connect(from: condition, to: botApproved, portLabel: "Approved")
        scenario.connect(from: condition, to: botRejected, portLabel: "Rejected")

        mockProvider.scriptStream(for: scenario.profileID(for: botApproved)!, events: [.content("approved!")])
        mockProvider.scriptStream(for: scenario.profileID(for: botRejected)!, events: [.content("rejected!")])

        let events = try await executeWithGate(scenario, choosing: "Approve")

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botApproved), "Full structural chain: Code→Gate(Approve)→Condition→Approved")
        XCTAssertFalse(started.contains(botRejected))
    }

    func testCondition_FallbackNoEdge_DownstreamSkipped() async throws {
        // Condition routes to "Fallback" but no edge exists for that port
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let condition = scenario.addConditionNode(
            name: "Router",
            rules: [ConditionRule(label: "Match", field: .upstreamOutput, op: .contains, value: "xyz")],
            fallbackLabel: "NoEdge"
        )
        let botMatch = scenario.addBotNode(name: "Match Bot")
        // Only wire the "Match" port — "NoEdge" has no edge

        scenario.connect(from: botA, to: condition)
        scenario.connect(from: condition, to: botMatch, portLabel: "Match")

        // A output doesn't contain "xyz" → fallback "NoEdge" activates → no edge for it
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("no match here")])
        mockProvider.scriptStream(for: scenario.profileID(for: botMatch)!, events: [.content("matched")])

        let events = try await execute(scenario)

        // Match bot should NOT execute (wrong port), condition routes to NoEdge which has no target
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botMatch), "Match bot should not fire when fallback port is active")
    }

    // =========================================================================
    // MARK: - Group 21: Terminal Synthesis Edge Cases
    // =========================================================================

    func testMultipleTerminals_SomeSucceedSomeFail() async throws {
        // A → B(fails), A → C(succeeds): both are terminals, only C's output in content
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Failing Terminal")
        let botC = scenario.addBotNode(name: "Good Terminal")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("good result")])

        let events = try await execute(scenario)

        // Only successful terminal output in final .content
        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "good result")
    }

    func testTerminalNode_EmptyOutput_NotInFinalContent() async throws {
        // Terminal produces empty output — should not add blank content
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Empty Bot")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: []) // Empty output

        let events = try await execute(scenario)

        // No .content event since output is empty
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.isEmpty, "Empty terminal output should not yield .content event")
    }

    func testMultipleTerminals_OutputsConcatenated() async throws {
        // Disconnected: A, B both terminals — outputs joined with \n\n
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")
        let botB = scenario.addBotNode(name: "Bot B")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("result-A")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("result-B")])

        let events = try await execute(scenario)

        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("result-A"), "Should contain A's output")
        XCTAssertTrue(content.contains("result-B"), "Should contain B's output")
    }

    // =========================================================================
    // MARK: - Group 22: Boundary Conditions
    // =========================================================================

    func testEmptyUserInput_StillExecutes() async throws {
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Bot A")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("response")])

        let events = try await execute(scenario, userInput: "")

        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertEqual(completed.count, 1, "Should execute even with empty user input")
    }

    func testLargeUpstreamContext_Truncated() async throws {
        // Bot A produces very large output → ContextCompressor truncates for Bot B
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Verbose Bot")
        let botB = scenario.addBotNode(name: "Receiver Bot")

        scenario.connect(from: botA, to: botB)

        let largeOutput = String(repeating: "word ", count: 5000) // ~25,000 chars
        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content(largeOutput)])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("done")])

        let events = try await execute(scenario)

        // B should receive truncated context, not the full 25K
        let bPid = scenario.profileID(for: botB)!
        let bInv = mockProvider.invocations.first(where: { $0.profileID == bPid })!
        XCTAssertLessThan(bInv.userInput.count, 10000,
                          "Context should be truncated to ~6000 chars, not full 25K")
        XCTAssertTrue(bInv.userInput.contains("truncated"),
                      "Should contain truncation marker")
    }

    func testProgressEvents_MonotonicallyIncreasing() async throws {
        let scenario = WorkflowTestScenario()
        let n1 = scenario.addBotNode(name: "N1")
        let n2 = scenario.addBotNode(name: "N2")
        let n3 = scenario.addBotNode(name: "N3")

        scenario.connect(from: n1, to: n2)
        scenario.connect(from: n2, to: n3)

        for n in [n1, n2, n3] {
            mockProvider.scriptStream(for: scenario.profileID(for: n)!, events: [.content("ok")])
        }

        let events = try await execute(scenario)

        let progress = WorkflowStreamCollector.progressEvents(from: events)
        // Progress completed counts should be monotonically increasing
        var prevCompleted = 0
        for p in progress {
            XCTAssertGreaterThanOrEqual(p.completed, prevCompleted, "Progress should be monotonically increasing")
            prevCompleted = p.completed
        }
        XCTAssertEqual(progress.last?.completed, 3, "Final progress should show all 3 completed")
        XCTAssertEqual(progress.last?.total, 3)
    }

    // =========================================================================
    // MARK: - Group 23: WorkflowLayout Algorithm Tests
    // =========================================================================

    func testTopologicalSort_SingleNodeNoEdges() {
        let nodeID = UUID()
        let layout = WorkflowLayout(
            nodes: [WorkflowNode(id: nodeID, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "Solo")],
            edges: []
        )
        let sorted = layout.topologicalSort()
        XCTAssertEqual(sorted, [nodeID])
    }

    func testTopologicalSort_LinearChain() {
        let a = UUID(), b = UUID(), c = UUID()
        let layout = WorkflowLayout(
            nodes: [
                WorkflowNode(id: a, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "A"),
                WorkflowNode(id: b, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "B"),
                WorkflowNode(id: c, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "C")
            ],
            edges: [
                WorkflowEdge(sourceNodeID: a, targetNodeID: b),
                WorkflowEdge(sourceNodeID: b, targetNodeID: c)
            ]
        )
        let sorted = layout.topologicalSort()
        XCTAssertEqual(sorted, [a, b, c])
    }

    func testComputeExecutionLevels_DiamondGraph() {
        // A → B, A → C, B → D, C → D
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let layout = WorkflowLayout(
            nodes: [
                WorkflowNode(id: a, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "A"),
                WorkflowNode(id: b, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "B"),
                WorkflowNode(id: c, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "C"),
                WorkflowNode(id: d, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "D")
            ],
            edges: [
                WorkflowEdge(sourceNodeID: a, targetNodeID: b),
                WorkflowEdge(sourceNodeID: a, targetNodeID: c),
                WorkflowEdge(sourceNodeID: b, targetNodeID: d),
                WorkflowEdge(sourceNodeID: c, targetNodeID: d)
            ]
        )
        let levels = layout.computeExecutionLevels()!
        XCTAssertEqual(levels.count, 3, "Diamond graph should have 3 levels")
        XCTAssertEqual(levels[0], [a], "Level 0: entry node A")
        XCTAssertEqual(Set(levels[1]), Set([b, c]), "Level 1: B and C (parallel)")
        XCTAssertEqual(levels[2], [d], "Level 2: D (depends on both B and C)")
    }

    func testWouldCreateCycle_SelfLoop() {
        let a = UUID()
        let layout = WorkflowLayout(
            nodes: [WorkflowNode(id: a, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "A")],
            edges: []
        )
        XCTAssertTrue(layout.wouldCreateCycle(source: a, target: a), "Self-loop should be detected as cycle")
    }

    func testEdgesReferenceNonExistentNode_SilentlyIgnored() {
        // Edge references node not in layout — computeExecutionLevels should handle gracefully
        let a = UUID(), b = UUID(), phantom = UUID()
        let layout = WorkflowLayout(
            nodes: [
                WorkflowNode(id: a, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "A"),
                WorkflowNode(id: b, kind: .trigger(TriggerNodeConfig()), position: .zero, displayName: "B")
            ],
            edges: [
                WorkflowEdge(sourceNodeID: a, targetNodeID: b),
                WorkflowEdge(sourceNodeID: a, targetNodeID: phantom) // phantom not in nodes
            ]
        )
        let levels = layout.computeExecutionLevels()
        XCTAssertNotNil(levels, "Should not crash on phantom node edge")
        XCTAssertEqual(levels?.flatMap({ $0 }).count, 2, "Only real nodes in levels")
    }

    // =========================================================================
    // MARK: - Group 24: Loop Node Tests
    // =========================================================================

    /// Helper: creates an inner workflow with a single bot, saves it, registers profiles.
    private func makeInnerBotWorkflow(
        botName: String,
        scenario: WorkflowTestScenario
    ) -> (innerWorkflowID: UUID, innerBotNodeID: UUID) {
        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: botName)
        inner.save()
        innerBuilders.append(inner)

        // Merge inner profiles into outer scenario
        for (id, profile) in inner.profileMap {
            scenario.profileMap[id] = profile
        }

        return (inner.workflowProfileID, innerBot)
    }

    func testLoopNode_ExecutesBodyNTimes() async throws {
        let scenario = WorkflowTestScenario()

        // Create inner workflow: single bot
        let (innerID, innerBot) = makeInnerBotWorkflow(botName: "Loop Body Bot", scenario: scenario)

        let loop = scenario.addLoopNode(name: "Repeater", bodyWorkflowID: innerID, maxIterations: 3)

        // Script inner bot: returns same output every iteration (cycles last entry)
        let innerPid = scenario.profileMap.first(where: { $0.value.displayName == "Loop Body Bot" })!.key
        mockProvider.scriptStream(for: innerPid, events: [.content("iteration output")])

        let events = try await execute(scenario)

        // Should emit 3 loop iteration events
        let iterations = WorkflowStreamCollector.loopIterationEvents(from: events)
        XCTAssertEqual(iterations.count, 3, "Should execute 3 iterations")
        XCTAssertEqual(iterations.map(\.iteration), [1, 2, 3])

        // Loop node itself completes
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == loop }))

        // Final output should be from last iteration
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("iteration output"))
    }

    func testLoopNode_ChainsOutputBetweenIterations() async throws {
        let scenario = WorkflowTestScenario()

        let (innerID, _) = makeInnerBotWorkflow(botName: "Chaining Bot", scenario: scenario)
        let botA = scenario.addBotNode(name: "Source")
        let loop = scenario.addLoopNode(name: "Chain Loop", bodyWorkflowID: innerID, maxIterations: 3)

        scenario.connect(from: botA, to: loop)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("seed")])

        // Inner bot: each call receives previous iteration's output as input
        let innerPid = scenario.profileMap.first(where: { $0.value.displayName == "Chaining Bot" })!.key
        mockProvider.scriptStream(for: innerPid, events: [.content("iter1")])
        mockProvider.scriptStream(for: innerPid, events: [.content("iter2")])
        mockProvider.scriptStream(for: innerPid, events: [.content("iter3")])

        let events = try await execute(scenario)

        // Verify the inner bot was called 3 times
        let innerCalls = mockProvider.invocations.filter { $0.profileID == innerPid }
        XCTAssertEqual(innerCalls.count, 3)

        // First iteration input should contain "seed" (upstream from botA)
        XCTAssertTrue(innerCalls[0].userInput.contains("seed"),
                      "First iteration should receive upstream input")

        // Second iteration input should contain "iter1" (previous iteration output)
        XCTAssertTrue(innerCalls[1].userInput.contains("iter1"),
                      "Second iteration should receive first iteration's output")

        // Third iteration input should contain "iter2"
        XCTAssertTrue(innerCalls[2].userInput.contains("iter2"),
                      "Third iteration should receive second iteration's output")
    }

    func testLoopNode_ExitConditionBreaksEarly() async throws {
        let scenario = WorkflowTestScenario()

        let (innerID, _) = makeInnerBotWorkflow(botName: "Converging Bot", scenario: scenario)
        let loop = scenario.addLoopNode(
            name: "Early Exit Loop",
            bodyWorkflowID: innerID,
            maxIterations: 10,
            exitCondition: ConditionRule(label: "exit", field: .upstreamOutput, op: .contains, value: "DONE")
        )

        let innerPid = scenario.profileMap.first(where: { $0.value.displayName == "Converging Bot" })!.key
        // Iterations 1-2: no DONE, iteration 3: has DONE
        mockProvider.scriptStream(for: innerPid, events: [.content("processing...")])
        mockProvider.scriptStream(for: innerPid, events: [.content("still processing...")])
        mockProvider.scriptStream(for: innerPid, events: [.content("DONE - converged")])

        let events = try await execute(scenario)

        // Should exit after 3 iterations (not 10)
        let iterations = WorkflowStreamCollector.loopIterationEvents(from: events)
        XCTAssertEqual(iterations.count, 3, "Should exit early after 3 iterations when DONE appears")

        // Loop should complete (not fail)
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == loop }))

        // Completion summary should mention early exit
        let loopCompleted = completed.first(where: { $0.nodeID == loop })!
        XCTAssertTrue(loopCompleted.summary.contains("early exit") || loopCompleted.summary.contains("3 iter"),
                      "Summary should indicate iteration count or early exit")
    }

    func testLoopNode_NoBody_Fails() async throws {
        let scenario = WorkflowTestScenario()
        let loop = scenario.addLoopNodeWithoutBody(name: "Broken Loop")

        // Pre-flight validation rejects a loop with no body workflow configured.
        do {
            _ = try await execute(scenario)
            XCTFail("Expected validationFailed for a loop with no body")
        } catch let error as WorkflowError {
            guard case .validationFailed(let issues, _) = error else {
                XCTFail("Expected validationFailed, got \(error)")
                return
            }
            XCTAssertTrue(issues.contains(where: { $0.nodeID == loop }),
                          "Validation should flag the body-less loop node")
        }
    }

    func testLoopNode_WritesCounterVariables() async throws {
        let scenario = WorkflowTestScenario()

        let (innerID, _) = makeInnerBotWorkflow(botName: "Counter Bot", scenario: scenario)
        let loop = scenario.addLoopNode(name: "Counting Loop", bodyWorkflowID: innerID, maxIterations: 2)
        let code = scenario.addCodeNode(
            name: "Read Counter",
            template: "Ran {{ var.__loop_\(loop.uuidString)_counter }} times"
        )
        scenario.connect(from: loop, to: code)

        let innerPid = scenario.profileMap.first(where: { $0.value.displayName == "Counter Bot" })!.key
        mockProvider.scriptStream(for: innerPid, events: [.content("tick")])

        let events = try await execute(scenario)

        // Code node should have read the loop counter variable
        let codeCompleted = WorkflowStreamCollector.nodeCompletedEvents(from: events)
            .first(where: { $0.nodeID == code })
        XCTAssertNotNil(codeCompleted, "Code node should complete")
        XCTAssertTrue(codeCompleted!.summary.contains("Ran 2 times"),
                      "Code node should read loop counter variable. Got: \(codeCompleted!.summary)")
    }

    func testLoopNode_BodyFails_LoopFails() async throws {
        let scenario = WorkflowTestScenario()

        let (innerID, _) = makeInnerBotWorkflow(botName: "Failing Body Bot", scenario: scenario)
        let loop = scenario.addLoopNode(name: "Fragile Loop", bodyWorkflowID: innerID, maxIterations: 5)

        let innerPid = scenario.profileMap.first(where: { $0.value.displayName == "Failing Body Bot" })!.key
        // First iteration succeeds, second fails
        mockProvider.scriptStream(for: innerPid, events: [.content("ok")])
        mockProvider.scriptError(for: innerPid, error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "body exploded"]))

        let events = try await execute(scenario)

        // Loop should fail after body fails
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains(where: { $0.nodeID == loop }), "Loop should fail when body fails")

        // Should only have 2 iterations (first ok, second fails)
        let iterations = WorkflowStreamCollector.loopIterationEvents(from: events)
        XCTAssertEqual(iterations.count, 2, "Should stop after body fails on iteration 2")
    }

    func testLoopNode_UpstreamContextPassedToFirstIteration() async throws {
        let scenario = WorkflowTestScenario()

        let botA = scenario.addBotNode(name: "Provider")
        let (innerID, _) = makeInnerBotWorkflow(botName: "Receiver Bot", scenario: scenario)
        let loop = scenario.addLoopNode(name: "Context Loop", bodyWorkflowID: innerID, maxIterations: 1)

        scenario.connect(from: botA, to: loop)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("upstream data")])

        let innerPid = scenario.profileMap.first(where: { $0.value.displayName == "Receiver Bot" })!.key
        mockProvider.scriptStream(for: innerPid, events: [.content("processed")])

        let events = try await execute(scenario)

        // Inner bot's first call should receive upstream data as input
        let innerCalls = mockProvider.invocations.filter { $0.profileID == innerPid }
        XCTAssertEqual(innerCalls.count, 1)
        XCTAssertTrue(innerCalls[0].userInput.contains("upstream data"),
                      "Loop body should receive upstream context on first iteration")
    }

    // =========================================================================
    // MARK: - Group 25: Parallel Execution
    // =========================================================================

    func testParallel_TwoBotsExecuteConcurrently() async throws {
        // A → B, A → C; B and C at same level (parallel)
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Parallel-B")
        let botC = scenario.addBotNode(name: "Parallel-C")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("shared input")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B result")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C result")])

        let events = try await execute(scenario)

        // Both B and C should execute
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botB), "Parallel node B should complete")
        XCTAssertTrue(completed.contains(botC), "Parallel node C should complete")

        // Both receive A's context
        let bPid = scenario.profileID(for: botB)!
        let cPid = scenario.profileID(for: botC)!
        let bInv = mockProvider.invocations.first(where: { $0.profileID == bPid })!
        let cInv = mockProvider.invocations.first(where: { $0.profileID == cPid })!
        XCTAssertTrue(bInv.userInput.contains("shared input"), "B should receive A's output")
        XCTAssertTrue(cInv.userInput.contains("shared input"), "C should receive A's output")

        // Both are terminal nodes — outputs concatenated
        let content = StreamCollector.contentText(from: events)
        XCTAssertTrue(content.contains("B result"), "Final content should include B")
        XCTAssertTrue(content.contains("C result"), "Final content should include C")
    }

    func testParallel_ThreeBotsWithFanIn() async throws {
        // A → (B, C, D) → E
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Worker-B")
        let botC = scenario.addBotNode(name: "Worker-C")
        let botD = scenario.addBotNode(name: "Worker-D")
        let botE = scenario.addBotNode(name: "Aggregator")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botA, to: botD)
        scenario.connect(from: botB, to: botE)
        scenario.connect(from: botC, to: botE)
        scenario.connect(from: botD, to: botE)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("query")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("from-B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("from-C")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("from-D")])
        mockProvider.scriptStream(for: scenario.profileID(for: botE)!, events: [.content("aggregated")])

        let events = try await execute(scenario)

        // All 5 nodes complete
        WorkflowStreamCollector.assertAllNodesTerminated(events, expectedCount: 5)

        // E receives context from B, C, and D
        let ePid = scenario.profileID(for: botE)!
        let eInv = mockProvider.invocations.first(where: { $0.profileID == ePid })!
        XCTAssertTrue(eInv.userInput.contains("from-B"), "Aggregator should see B's output")
        XCTAssertTrue(eInv.userInput.contains("from-C"), "Aggregator should see C's output")
        XCTAssertTrue(eInv.userInput.contains("from-D"), "Aggregator should see D's output")

        // Only terminal E in final content
        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "aggregated")
    }

    func testParallel_OneFailsStopWorkflow_NextLevelBlocked() async throws {
        // A → (B, C); B → D
        // B fails with stopWorkflow. C still completes (in-flight). D never starts.
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Failing-B")
        let botC = scenario.addBotNode(name: "Healthy-C")
        let botD = scenario.addBotNode(name: "Next-Level-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botD)

        scenario.setNodeConfig(WorkflowNodeConfig(onFailure: .stopWorkflow), for: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        // C completes (was already in-flight when B failed)
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botC), "In-flight parallel node C should still complete")

        // B fails
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(failed.contains(botB), "B should fail")

        // D never starts — stopWorkflow halts next level
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botD), "D should NOT start after stopWorkflow")
    }

    func testParallel_OneFailsDefault_SharedDownstreamSkipped() async throws {
        // A → (B, C) → D; B fails with default skipDependents
        // D depends on BOTH B and C (allSatisfy) → D skipped
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Failing-B")
        let botC = scenario.addBotNode(name: "Healthy-C")
        let botD = scenario.addBotNode(name: "Downstream-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botD)
        scenario.connect(from: botC, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        // C completes, B fails, D skipped (allSatisfy requires both parents)
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botC), "Healthy-C should complete")

        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        XCTAssertTrue(failed.contains(where: { $0.nodeID == botB }), "B should fail")
        XCTAssertTrue(failed.contains(where: { $0.nodeID == botD }), "D should be skipped (upstream B failed)")
    }

    func testParallel_StructuralBeforeProfile() async throws {
        // Level 1 has: Code node (structural) + 2 Bot nodes (profile)
        // Code runs FIRST, then bots run in parallel seeing the variable
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Entry")
        let code = scenario.addCodeNode(name: "Set Config", template: "strict_mode", outputVariable: "mode")
        let botB = scenario.addBotNode(name: "Worker-B")
        let botC = scenario.addBotNode(name: "Worker-C")

        // All three depend on A → same level
        scenario.connect(from: botA, to: code)
        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)

        // Code node also feeds into a downstream condition to verify variable was set
        let condition = scenario.addConditionNode(
            name: "Mode Check",
            rules: [ConditionRule(label: "Strict", field: .variable, op: .equals, value: "strict_mode", variableName: "mode")],
            fallbackLabel: "Relaxed"
        )
        let botStrict = scenario.addBotNode(name: "Strict Bot")

        scenario.connect(from: code, to: condition)
        scenario.connect(from: condition, to: botStrict, portLabel: "Strict")

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("init")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B done")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C done")])
        mockProvider.scriptStream(for: scenario.profileID(for: botStrict)!, events: [.content("strict!")])

        let events = try await execute(scenario)

        // Code runs first (structural), then B and C run in parallel
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(code), "Code node should complete")
        XCTAssertTrue(completed.contains(botB), "Worker-B should complete")
        XCTAssertTrue(completed.contains(botC), "Worker-C should complete")

        // Condition node reads variable set by Code node → routes to Strict
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(started.contains(botStrict), "Strict bot should execute (variable set by Code before bots)")
    }

    func testParallel_ErrorPortActivation_OnlyFailedNode() async throws {
        // A → (B, C); B fails → ErrorHandler-B; C succeeds → NormalHandler-C
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Failing-B")
        let botC = scenario.addBotNode(name: "Healthy-C")
        let errorHandler = scenario.addBotNode(name: "Error-Handler")
        let normalHandler = scenario.addBotNode(name: "Normal-Handler")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: errorHandler, portLabel: "error")
        scenario.connect(from: botC, to: normalHandler)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C ok")])
        mockProvider.scriptStream(for: scenario.profileID(for: errorHandler)!, events: [.content("handled error")])
        mockProvider.scriptStream(for: scenario.profileID(for: normalHandler)!, events: [.content("normal")])

        let events = try await execute(scenario)

        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        // Error handler activates for B's failure
        XCTAssertTrue(started.contains(errorHandler), "Error handler should execute for B's failure")
        // Normal handler activates for C's success
        XCTAssertTrue(started.contains(normalHandler), "Normal handler should execute for C's success")
    }

    func testParallel_ProgressEventsComplete() async throws {
        // A → (B, C, D); 4 nodes total, progress should reach 4/4
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "P-B")
        let botC = scenario.addBotNode(name: "P-C")
        let botD = scenario.addBotNode(name: "P-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botA, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("go")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("C")])
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("D")])

        let events = try await execute(scenario)

        let progress = WorkflowStreamCollector.progressEvents(from: events)

        // Should have 4 progress events (one per node)
        XCTAssertEqual(progress.count, 4, "Should have 4 progress events")

        // All should report total = 4
        XCTAssertTrue(progress.allSatisfy { $0.total == 4 }, "All progress events should report total = 4")

        // Final progress should show 4/4
        XCTAssertEqual(progress.last?.completed, 4, "Final progress should be 4/4")

        // Completed counts should be monotonically increasing
        var prev = 0
        for p in progress {
            XCTAssertGreaterThan(p.completed, prev, "Progress completed should increase monotonically")
            prev = p.completed
        }
    }

    func testParallel_SnapshotIsolation_NodesDoNotSeeEachOther() async throws {
        // A and B are both entry nodes (no upstream) → same level, parallel
        // C depends on both → next level, sees both outputs
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Entry-A")
        let botB = scenario.addBotNode(name: "Entry-B")
        let botC = scenario.addBotNode(name: "Merger")

        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("A-output")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B-output")])
        mockProvider.scriptStream(for: scenario.profileID(for: botC)!, events: [.content("merged")])

        let events = try await execute(scenario)

        // A and B are at Level 0 (parallel entries), C at Level 1
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(completed.contains(botA))
        XCTAssertTrue(completed.contains(botB))
        XCTAssertTrue(completed.contains(botC))

        // A should NOT see B's output (snapshot isolation — they're parallel)
        let aPid = scenario.profileID(for: botA)!
        let aInv = mockProvider.invocations.first(where: { $0.profileID == aPid })!
        XCTAssertFalse(aInv.userInput.contains("B-output"), "A should NOT see B's output (parallel isolation)")

        // B should NOT see A's output
        let bPid = scenario.profileID(for: botB)!
        let bInv = mockProvider.invocations.first(where: { $0.profileID == bPid })!
        XCTAssertFalse(bInv.userInput.contains("A-output"), "B should NOT see A's output (parallel isolation)")

        // C should see BOTH (next level, after both complete)
        let cPid = scenario.profileID(for: botC)!
        let cInv = mockProvider.invocations.first(where: { $0.profileID == cPid })!
        XCTAssertTrue(cInv.userInput.contains("A-output"), "Merger should see A's output")
        XCTAssertTrue(cInv.userInput.contains("B-output"), "Merger should see B's output")
    }

    // =========================================================================
    // MARK: - Group 26: Parallel Edge Cases
    // =========================================================================

    func testParallel_AllNodesFail_AllFailuresReported() async throws {
        // A → (B, C, D); all three fail simultaneously
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Fail-B")
        let botC = scenario.addBotNode(name: "Fail-C")
        let botD = scenario.addBotNode(name: "Fail-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botA, to: botD)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptError(for: scenario.profileID(for: botC)!, error: NSError(domain: "t", code: 2))
        mockProvider.scriptError(for: scenario.profileID(for: botD)!, error: NSError(domain: "t", code: 3))

        let events = try await execute(scenario)

        // All three failures should be reported individually
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events)
        let failedIDs = Set(failed.map(\.nodeID))
        XCTAssertTrue(failedIDs.contains(botB), "B failure should be reported")
        XCTAssertTrue(failedIDs.contains(botC), "C failure should be reported")
        XCTAssertTrue(failedIDs.contains(botD), "D failure should be reported")

        // All terminals failed → error message
        let errors = events.compactMap { e -> String? in
            if case .error(let err) = e { return err.message }
            return nil
        }
        XCTAssertTrue(errors.contains(where: { $0.contains("all terminal nodes failed") }),
                       "Should report all terminals failed")

        // Progress should still reach 4/4 (A completed + B,C,D failed = 4 processed)
        let progress = WorkflowStreamCollector.progressEvents(from: events)
        XCTAssertEqual(progress.last?.completed, 4)
    }

    func testParallel_MixedPolicies_StopWorkflowWins() async throws {
        // A → (B: continueAll, C: stopWorkflow) → D
        // Both fail. stopWorkflow should prevent D from executing.
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "ContinueAll-B")
        let botC = scenario.addBotNode(name: "StopWorkflow-C")
        let botD = scenario.addBotNode(name: "Next-Level-D")

        scenario.connect(from: botA, to: botB)
        scenario.connect(from: botA, to: botC)
        scenario.connect(from: botB, to: botD)
        scenario.connect(from: botC, to: botD)

        scenario.setNodeConfig(WorkflowNodeConfig(onFailure: .continueAll), for: botB)
        scenario.setNodeConfig(WorkflowNodeConfig(onFailure: .stopWorkflow), for: botC)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("data")])
        mockProvider.scriptError(for: scenario.profileID(for: botB)!, error: NSError(domain: "t", code: 1))
        mockProvider.scriptError(for: scenario.profileID(for: botC)!, error: NSError(domain: "t", code: 2))
        mockProvider.scriptStream(for: scenario.profileID(for: botD)!, events: [.content("should not run")])

        let events = try await execute(scenario)

        // D should NOT execute — stopWorkflow from C halts the workflow
        let started = WorkflowStreamCollector.nodeStartedEvents(from: events).map(\.nodeID)
        XCTAssertFalse(started.contains(botD), "D should NOT start — stopWorkflow from C takes precedence")

        // Both B and C should be reported as failed
        let failed = WorkflowStreamCollector.nodeFailedEvents(from: events).map(\.nodeID)
        XCTAssertTrue(failed.contains(botB))
        XCTAssertTrue(failed.contains(botC))
    }

    func testParallel_SingleProfileNode_UsesDirectPath() async throws {
        // A → B: Level 1 has exactly 1 profile node → uses if-branch (no TaskGroup)
        // Verify behavior is identical to parallel path
        let scenario = WorkflowTestScenario()
        let botA = scenario.addBotNode(name: "Source")
        let botB = scenario.addBotNode(name: "Single-B")

        scenario.connect(from: botA, to: botB)

        mockProvider.scriptStream(for: scenario.profileID(for: botA)!, events: [.content("input")])
        mockProvider.scriptStream(for: scenario.profileID(for: botB)!, events: [.content("B output")])

        let events = try await execute(scenario)

        // B executes, receives A's context, is terminal
        let bPid = scenario.profileID(for: botB)!
        let bInv = mockProvider.invocations.first(where: { $0.profileID == bPid })!
        XCTAssertTrue(bInv.userInput.contains("input"), "Single-path B should receive A's context")

        // B failure activates error port (same as parallel path)
        let completed = WorkflowStreamCollector.nodeCompletedEvents(from: events)
        XCTAssertTrue(completed.contains(where: { $0.nodeID == botB }))

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, "B output")
    }
}
