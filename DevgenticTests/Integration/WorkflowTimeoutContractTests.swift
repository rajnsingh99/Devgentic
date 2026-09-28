// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowTimeoutContractTests.swift
//  DevgenticTests
//
//  HITL Waiting Contract — workflow slice (rollout step 5). The Timeout inventory's probes P5 and
//  P10, kept as tests asserting the NEW behaviour against the real `WorkflowExecutor`.
//

import XCTest
@testable import devgentic

/// Counts starts and completions of a tool body that IGNORES cancellation.
private final class InvocationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var completions = 0
    func started() { lock.lock(); starts += 1; lock.unlock() }
    func completed() { lock.lock(); completions += 1; lock.unlock() }
    var counts: (starts: Int, completions: Int) { lock.lock(); defer { lock.unlock() }; return (starts, completions) }
}

private func ignoringCancellation(_ seconds: Double) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
    }
}

/// Resolves every Action node's tool to `tool`; everything else goes to the stock mock.
private final class SingleToolProvider: WorkflowStreamProvider, @unchecked Sendable {
    let base = MockWorkflowStreamProvider()
    let tool: AgentTool
    init(tool: AgentTool) { self.tool = tool }

    func streamAgentResponse(for profile: BackendProfileModel, userInput: String, chatHistory: [ChatMessage],
                             conversationID: UUID, ragContext: String?, attachmentContext: String?,
                             knowledgeBaseContext: String?, toolGuidanceContext: String?, userPayload: Payload?,
                             resumeState: TimelineReconstruction?, traceContext: TraceContext,
                             onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        base.streamAgentResponse(for: profile, userInput: userInput, chatHistory: chatHistory,
                                 conversationID: conversationID, ragContext: ragContext,
                                 attachmentContext: attachmentContext, knowledgeBaseContext: knowledgeBaseContext,
                                 toolGuidanceContext: toolGuidanceContext, userPayload: userPayload,
                                 resumeState: resumeState, traceContext: traceContext, onTraceUpdate: onTraceUpdate)
    }

    func streamWorkflowNodeResponse(for profile: BackendProfileModel, workflowContext: WorkflowExecutionContext,
                                    conversationID: UUID, traceContext: TraceContext,
                                    onTraceUpdate: (@Sendable (AgentTraceLog) -> Void)?) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        base.streamWorkflowNodeResponse(for: profile, workflowContext: workflowContext, conversationID: conversationID,
                                        traceContext: traceContext, onTraceUpdate: onTraceUpdate)
    }

    func resolveWorkflowTool(_ tool: Tool, conversationID: UUID) async -> AgentTool? { self.tool }
}

@MainActor
final class WorkflowTimeoutContractTests: XCTestCase {

    private func run(_ scenario: WorkflowTestScenario, provider: WorkflowStreamProvider) async throws -> [AgentStreamEvent] {
        let stream = WorkflowExecutor(workflowProfileID: UUID()).executeWorkflow(
            userInput: "go", conversationID: UUID(), traceContext: TestTraceContext.make(),
            onTraceUpdate: { _ in }, layout: scenario.layout, profileMap: scenario.profileMap,
            streamProvider: provider)
        var events: [AgentStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func failures(_ events: [AgentStreamEvent], node: UUID) -> [String] {
        events.compactMap { if case .workflowNodeFailed(let id, _, let error, _) = $0, id == node { return error }; return nil }
    }

    // MARK: - P10: a timed-out tool is NEVER re-run (decision F)

    func testATimedOutActionToolRunsOnceAndIsReportedAsATimeout() async throws {
        let log = InvocationLog()
        let tool = AgentTool(name: "deploy", description: "",
                             parameters: ToolParameters(type: "object", properties: [:], required: []),
                             textOnlyRun: { _ in
            log.started()
            await ignoringCancellation(1.3)   // completes AFTER the 1 s limit — the side effect happened
            log.completed()
            return "DEPLOYED"
        })
        let scenario = WorkflowTestScenario()
        let action = scenario.addActionNode(name: "Deploy", toolName: "deploy")
        var config = WorkflowNodeConfig()
        config.hardTimeout = 1
        config.maxNodeRetries = 1
        scenario.setNodeConfig(config, for: action)

        let events = try await run(scenario, provider: SingleToolProvider(tool: tool))

        XCTAssertEqual(log.counts.starts, 1,
                       "the timed-out tool was run AGAIN — its side effect happened twice (P10: 2 starts, 2 completions)")
        let failed = try XCTUnwrap(failures(events, node: action).first, "the node must fail")
        XCTAssertTrue(failed.localizedCaseInsensitiveContains("timeout"),
                      "the failure must say it timed out, not blame the model: \(failed)")
        XCTAssertFalse(failed.contains("credentials"))
    }

    // MARK: - P5: the structural bound returns at its limit and reports real compute

    func testTheStructuralBoundReturnsAtItsLimit() async {
        let start = ContinuousClock.now
        do {
            _ = try await WorkflowExecutor.withComputeTimeout(0.5, conversationID: UUID(), nodeName: "probe") {
                await ignoringCancellation(20)
                return "WORK-DONE"
            }
            XCTFail("the bound never fired")
        } catch let error as AgentExecutionError {
            guard case .executionTimeout(let elapsed, let limit) = error.reason else { return XCTFail("\(error)") }
            XCTAssertEqual(limit, 0.5)
            XCTAssertEqual(elapsed, 0.5, accuracy: 0.3, "elapsed must be the real compute at the bound")
        } catch {
            XCTFail("unexpected \(error)")
        }
        let waited = ContinuousClock.now - start
        XCTAssertLessThan(waited, .seconds(0.5 + WorkflowExecutor.structuralStopGrace + 1.5),
                          "the bound waited \(waited) for work that ignores cancellation (P5 held until the work finished)")
    }

    // MARK: - Action attempt limit (decision 2 + D-28)

    func testTheActionAttemptLimitHonoursTheToolLibraryAndIsNeverUnbounded() {
        let plain = TestToolFactory.make(name: "plain", output: "x")
        let overridden = TestToolFactory.makeWithTimeout(name: "o", timeout: 20, output: "x")
        let terminal = AgentToolFactory.wrap(RunCommandTool(conversationID: UUID()), requiresConfirmation: false)

        XCTAssertEqual(WorkflowExecutor.actionAttemptLimit(for: overridden, nodeTimeout: 120), 20,
                       "the Tool Library override must be honoured on the Action path")
        XCTAssertEqual(WorkflowExecutor.actionAttemptLimit(for: plain, nodeTimeout: 120), 120,
                       "the node's per-attempt limit caps the tool's 15-min default")
        XCTAssertEqual(WorkflowExecutor.actionAttemptLimit(for: plain, nodeTimeout: nil),
                       ToolExecutionMediator.globalDefaultToolTimeout,
                       "node timeout OFF must not make a tool call unbounded")
        XCTAssertGreaterThan(WorkflowExecutor.actionAttemptLimit(for: terminal, nodeTimeout: nil),
                             TimeInterval(BatchCommandTool.maxTimeoutSeconds))
    }

    func testTimeoutsAreNeverTransientButNetworkDropsStillAre() {
        XCTAssertFalse(WorkflowRetryPolicy.isTransientToolError(
            AgentExecutionError(reason: .executionTimeout(elapsed: 1, limit: 1))))
        XCTAssertFalse(WorkflowRetryPolicy.isTransientToolError(URLError(.timedOut)))
        XCTAssertTrue(WorkflowRetryPolicy.isTransientToolError(URLError(.networkConnectionLost)))
        XCTAssertFalse(WorkflowRetryPolicy.shouldRetryToolFailure(
            AgentExecutionError(reason: .executionTimeout(elapsed: 1, limit: 1)),
            attempt: 0, maxRetries: 3, isCancelled: false))
    }

    // MARK: - Gate: its own timer EXPIRES onto the error port (decision B)

    func testAGateTimerExpiresHonestly() async throws {
        let scenario = WorkflowTestScenario()
        let gate = scenario.addGateNode(name: "Approve deploy", timeout: 0.3)
        let events = try await run(scenario, provider: MockWorkflowStreamProvider())

        let failed = try XCTUnwrap(failures(events, node: gate).first, "an unanswered timed gate must fail onto its error port")
        XCTAssertTrue(failed.contains("Gate expired"), "got: \(failed)")
        XCTAssertFalse(failed.contains("credentials"), "the model-error remediation must not appear for an unanswered gate")
        XCTAssertFalse(AgentFailureReason.gateExpired(limit: 1).isRetryable, "asking again does not answer an unanswered question")
    }
}
