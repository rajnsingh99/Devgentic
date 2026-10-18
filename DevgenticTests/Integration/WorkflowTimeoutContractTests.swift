// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowTimeoutContractTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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

/// Occupies every cooperative-pool thread at the CALLER's priority for `seconds` — a process-wide
/// scheduling stall — and returns once it holds (or after 2 s). Blocking is the point: no async work
/// at that priority can start until it ends.
///
/// ⚠️ The priority matters. The pool keeps a thread budget per QoS, so a stall at the default
/// priority leaves a test running from the main actor (`.high`) entirely untouched.
private func stallTheCooperativePool(for seconds: Double) {
    final class Started: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    let started = Started()
    let width = ProcessInfo.processInfo.activeProcessorCount
    let priority = Task.currentPriority
    for _ in 0..<width {
        Task.detached(priority: priority) { started.increment(); blockThisThread(for: seconds) }
    }
    let deadline = Date().addingTimeInterval(2)
    while started.value < width, Date() < deadline { blockThisThread(for: 0.005) }
}

private func blockThisThread(for seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

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
        await assertTheStructuralBoundReturnsAtItsLimit()
    }

    /// ⚠️ 2026-10-10: P5 failed at 7.6 s, 8.55 s and 23.6 s against a 7 s stopwatch while the bound was
    /// correct — its own clock (`elapsed`) passed each time and the work was still running. The time
    /// was lost to the PROCESS (the bound could not even start), which a stopwatch cannot tell apart
    /// from a bound that holds. A 3 s stall reproduces the 8.55 s failure exactly.
    func testTheStructuralBoundReturnsAtItsLimitThroughAStall() async {
        stallTheCooperativePool(for: 3)
        await assertTheStructuralBoundReturnsAtItsLimit()
    }

    private func assertTheStructuralBoundReturnsAtItsLimit() async {
        // ⚠️ The gap between this and `limit + structuralStopGrace` (5.5 s) is the whole signal: a bound
        // that holds returns after it, one that does not returns long before it.
        let workSeconds: Double = 60
        let log = InvocationLog()
        let start = ContinuousClock.now
        do {
            _ = try await WorkflowExecutor.withComputeTimeout(0.5, conversationID: UUID(), nodeName: "probe") {
                log.started()
                await ignoringCancellation(workSeconds)
                log.completed()
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
        XCTAssertEqual(log.counts.starts, 1)
        // ⚠️ THE DISCRIMINATOR: the work's own state when the bound returned, not a stopwatch.
        XCTAssertEqual(log.counts.completions, 0,
                       "the bound returned only after its work finished (\(waited)) — P5 held until the work finished")
        XCTAssertLessThan(waited, .seconds(workSeconds / 2),
                          "the bound waited \(waited) for work that ignores cancellation (P5 held)")
    }

    /// The suspicion of 2026-10-10, kept as a guard: another run's open local-model queue wait must not
    /// pause THIS bound's compute clock. Queue-wait credit goes only to the waiter's own `ParkScope`
    /// chain — never process-wide (see `ExecutionSuspensionService.beginQueueWait`).
    func testAnotherRunsQueueWaitDoesNotPauseThisBound() async throws {
        let service = ExecutionSuspensionService.shared
        let otherRun = UUID()
        await service.registerScope(otherRun, conversationID: UUID(), attended: true)
        let wait = UUID()
        await ParkScope.$chain.withValue([otherRun]) { await service.beginQueueWait(wait) }

        // Honours cancellation, so a correct bound returns at once; a paused one returns its result
        // after 30 s. The OUTCOME tells them apart, not a stopwatch.
        let outcome: String
        do {
            outcome = try await WorkflowExecutor.withComputeTimeout(0.5, conversationID: UUID(), nodeName: "probe") {
                try await Task.sleep(for: .seconds(30))
                return "WORK-DONE"
            }
        } catch let error as AgentExecutionError {
            guard case .executionTimeout = error.reason else { throw error }
            outcome = "TIMED-OUT"
        }
        await service.endQueueWait(wait)
        await service.unregisterScope(otherRun)

        XCTAssertEqual(outcome, "TIMED-OUT", "another run's queue wait paused this bound until its work finished")
    }

    // MARK: - The [WF_TIMEOUT] line tells a stall from a bound that held

    func testTheTimeoutLineReportsWallClockAndTheTimeBeforeTheBoundStarted() {
        let line = WorkflowExecutor.timeoutReport(nodeName: "probe", limit: 0.5, compute: 0.52,
                                                  wall: 8.55, beforeStart: 3.04, abandoned: true)
        XCTAssertTrue(line.hasPrefix("[WF_TIMEOUT] Node 'probe' exceeded its 0.5s compute budget"), line)
        XCTAssertTrue(line.contains("0.5s compute, time awaiting a human excluded"), line)
        XCTAssertTrue(line.contains("8.6s wall-clock from entering the bound, 3.0s of it before its clock started"), line)
        XCTAssertTrue(line.contains("did not stop within 5s of being cancelled and is abandoned"), line)
        XCTAssertTrue(WorkflowExecutor.timeoutReport(nodeName: "n", limit: 1, compute: 1, wall: 1, beforeStart: 0,
                                                     abandoned: false).contains("its work was stopped."))
    }

    /// ⚠️ WIRING. The unit test above passes with the call cut. Source-scanned, comment-stripped.
    func testTheStructuralBoundLogsTheTimeoutReport() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = repoRoot.appendingPathComponent("Devgentic/Core/Backends/WorkflowGen/WorkflowExecutor.swift")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw XCTSkip("sources not reachable — running outside a checkout")
        }
        let code = try String(contentsOf: file, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let pattern = #"static func withComputeTimeout<[\s\S]{0,200}?let called = ContinuousClock\.now[\s\S]{0,1200}?let raceCalled = ContinuousClock\.now\s*let outcome = try await DeadlineRace\.run[\s\S]{0,800}?case \.timedOut\(let elapsed, let afterStop\):\s*logger\.error\(timeoutReport\(nodeName: nodeName, limit: limit, compute: elapsed,\s*wall: DeadlineRace\.seconds\(ContinuousClock\.now - called\),\s*beforeStart: DeadlineRace\.seconds\(raceCalled - called\)"#
        XCTAssertNotNil(code.range(of: pattern, options: .regularExpression),
                        "withComputeTimeout's timeout must log timeoutReport with wall-clock measured from entering the bound")
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
