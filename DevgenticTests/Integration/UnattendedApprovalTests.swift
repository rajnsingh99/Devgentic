// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UnattendedApprovalTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class UnattendedApprovalTests: XCTestCase {

    private var mockProvider: MockWorkflowStreamProvider!
    private var traceContext: TraceContext!
    private let conversationID = UUID()

    override func setUp() {
        super.setUp()
        // ⚠️ See PlanningFailureIntegrationTests.setUp — a non-fatal assert falling through into
        // an unguarded subscript crashes the HOST instead of failing the test. The regression this
        // suite guards (the confirmation parks again) leaves `failedTools` EMPTY, which is exactly
        // the shape that would trap.
        continueAfterFailure = false
        mockProvider = MockWorkflowStreamProvider()
        traceContext = TestTraceContext.make()
    }

    override func tearDown() {
        let cid = conversationID
        Task { @MainActor in WorkflowNodeSkipStore.shared.clear(conversationID: cid, reason: "test teardown") }
        Task { await SessionToolApprovals.shared.clear(conversationID: cid) }
        super.tearDown()
    }

    private func execute(
        _ scenario: WorkflowTestScenario,
        attended: Bool,
        remoteResponder: Bool = false
    ) async throws -> [AgentStreamEvent] {
        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let makeStream = {
            executor.executeWorkflow(
                userInput: "Test input",
                conversationID: self.conversationID,
                traceContext: self.traceContext,
                onTraceUpdate: { _ in },
                layout: scenario.layout,
                profileMap: scenario.profileMap,
                streamProvider: self.mockProvider
            )
        }
        let stream = WorkflowRunAttendance.$hasRemoteResponder.withValue(remoteResponder) {
            WorkflowRunAttendance.$isAttended.withValue(attended, operation: makeStream)
        }
        return try await WorkflowStreamCollector.collectWithGateChoice(from: stream, choosing: nil)
    }

    private func failedTools(_ events: [AgentStreamEvent]) -> [(name: String, output: String, category: ToolFailureCategory)] {
        events.compactMap {
            if case .toolFailed(let output, let category, _, _) = $0 {
                return (output.toolName, output.output, category)
            }
            return nil
        }
    }

    private func succeededToolNames(_ events: [AgentStreamEvent]) -> [String] {
        events.compactMap { if case .toolSucceeded(let output, _, _) = $0 { return output.toolName }; return nil }
    }

    // MARK: - SE11: refuse fast, never park

    /// Unattended + confirming tool + no standing config: the tool is refused immediately (this
    /// test completing at all — instead of hanging on the park — is half the assertion), the node
    /// fails with a reason naming the remedy, and the category is honest (`permissionRejected`,
    /// not `userDenied` — no user denied anything).
    func testUnattendedConfirmation_IsRefusedFastNotParked() async throws {
        let scenario = WorkflowTestScenario()
        let action = scenario.addActionNode(name: "Deploy", toolName: "send_webhook", requiresConfirmation: true)
        mockProvider.scriptTool(name: "send_webhook", output: "sent", requiresConfirmation: true)

        let events = try await execute(scenario, attended: false)

        let failures = failedTools(events)
        guard failures.count == 1, let failure = failures.first else {
            return XCTFail("the refusal must surface as exactly one failed tool, got \(failures.count): \(failures.map(\.name))")
        }
        XCTAssertEqual(failure.name, "send_webhook")
        XCTAssertEqual(failure.category, .permissionRejected,
                       "no user denied anything — .userDenied would charge denial machinery for a policy refusal")
        XCTAssertTrue(failure.output.contains("unattended"), "the reason names the cause: \(failure.output)")

        let failed = events.compactMap { if case .workflowNodeFailed(let id, _, _, _) = $0 { return id }; return nil }
        XCTAssertTrue(failed.contains(action), "the node fails onto its wireable error port")
        XCTAssertTrue(succeededToolNames(events).isEmpty, "the tool must NOT have executed")
    }

    // MARK: - SE6: the explicit node setting is the sanctioned unattended path

    func testUnattendedWithExplicitNodeConfig_AutoApprovesAndRuns() async throws {
        let scenario = WorkflowTestScenario()
        _ = scenario.addActionNode(name: "Deploy", toolName: "send_webhook",
                                   requiresConfirmation: true, unattendedAutoApprove: true)
        mockProvider.scriptTool(name: "send_webhook", output: "sent", requiresConfirmation: true)

        let events = try await execute(scenario, attended: false)

        XCTAssertEqual(succeededToolNames(events), ["send_webhook"],
                       "the EXPLICIT per-node setting is the configured intent — the tool runs unattended")
        XCTAssertTrue(failedTools(events).isEmpty)
    }

    // MARK: - SE6 core: an interactive grant is never served to an unattended run

    /// The filed harm: the user clicked "Allow for this chat" during an attended run, and the
    /// durable grant then auto-approved every SCHEDULED fire of the same conversation+node
    /// forever. The grant must now be invisible to unattended runs — with no explicit node
    /// config, the confirmation is refused, not silently approved.
    func testInteractiveGrantIsNotServedToAnUnattendedRun() async throws {
        let scenario = WorkflowTestScenario()
        let action = scenario.addActionNode(name: "Deploy", toolName: "send_webhook", requiresConfirmation: true)
        mockProvider.scriptTool(name: "send_webhook", output: "sent", requiresConfirmation: true)

        // The attended-session grant, exactly as the banner writes it (conversation + node scope).
        await SessionToolApprovals.shared.allow(
            toolName: "send_webhook", risk: .moderate, conversationID: conversationID, nodeID: action)

        let events = try await execute(scenario, attended: false)

        XCTAssertTrue(succeededToolNames(events).isEmpty,
                      "the attended banner grant must NOT auto-approve a scheduled fire — that leak was the permanent unattended auto-approve")
        XCTAssertEqual(failedTools(events).count, 1, "with no explicit node config the refusal path applies")
    }

    /// …and the same grant still works where it was given: an ATTENDED run auto-approves with no
    /// banner, exactly as before.
    func testInteractiveGrantStillServesAttendedRuns() async throws {
        let scenario = WorkflowTestScenario()
        let action = scenario.addActionNode(name: "Deploy", toolName: "send_webhook", requiresConfirmation: true)
        mockProvider.scriptTool(name: "send_webhook", output: "sent", requiresConfirmation: true)

        await SessionToolApprovals.shared.allow(
            toolName: "send_webhook", risk: .moderate, conversationID: conversationID, nodeID: action)

        let events = try await execute(scenario, attended: true)

        XCTAssertEqual(succeededToolNames(events), ["send_webhook"],
                       "attended behaviour is unchanged — the grant skips the banner")
        XCTAssertTrue(failedTools(events).isEmpty)
    }

    // MARK: - [WF-SE11, corrected on review] ChatOps is NOT "nobody"

    /// A ChatOps run binds `isAttended = false` (for WF-EX5's Router reason) but a human IS
    /// reachable: `RemoteMirrorService` mirrors the confirmation to Telegram/Slack/Discord with
    /// tappable Approve/Deny and resolves it through `handleApproval`. The first version of this
    /// fix keyed the refusal on `isAttended` alone and silently deleted that shipped flow — for a
    /// plain ChatOps agent chat the only remaining remedy was disabling Ask-first globally.
    ///
    /// Pinned by the tool NOT being refused: the run instead parks and mirrors (the park is
    /// resolved here by the collector's gate/HITL handling, so the assertion is on the absence of
    /// the refusal, which is the regression that matters).
    func testChatOpsRunIsNotRefused_ItStillAsksRemotely() async throws {
        let scenario = WorkflowTestScenario()
        _ = scenario.addActionNode(name: "Deploy", toolName: "send_webhook", requiresConfirmation: true)
        mockProvider.scriptTool(name: "send_webhook", output: "sent", requiresConfirmation: true)

        let executor = WorkflowExecutor(workflowProfileID: UUID())
        let makeStream = {
            executor.executeWorkflow(
                userInput: "Test input", conversationID: self.conversationID,
                traceContext: self.traceContext, onTraceUpdate: { _ in },
                layout: scenario.layout, profileMap: scenario.profileMap, streamProvider: self.mockProvider
            )
        }
        // ChatOps shape: no local banner, but a remote responder exists — the run must genuinely
        // PARK (an immediate refusal would be the regression), so this collector answers the
        // confirmation directly via `ExecutionSuspensionService` the moment it is raised — the
        // same seam `RemoteMirrorService.handleApproval` uses — proving the request really
        // reached the suspend point rather than being refused before ever asking.
        let stream = WorkflowRunAttendance.$hasRemoteResponder.withValue(true) {
            WorkflowRunAttendance.$isAttended.withValue(false, operation: makeStream)
        }
        // Bounded: if a future change makes this park unanswerable again, fail the test in
        // seconds instead of hanging the whole suite (the crash-diagnosis lesson from this
        // fix's own review — a test that can hang must never be allowed to). `events` is built
        // ENTIRELY inside the racer child and returned — a `var` captured mutably across the two
        // group children would not compile under strict concurrency.
        let collected: [AgentStreamEvent]? = try await withThrowingTaskGroup(of: [AgentStreamEvent]?.self) { group in
            group.addTask {
                var collectedEvents: [AgentStreamEvent] = []
                for try await event in stream {
                    collectedEvents.append(event)
                    if case .requestConfirmation(_, _, let operationID, _, _) = event {
                        // The producer yields this event and THEN calls `suspend`, which is what
                        // actually registers the continuation `resume` needs to find — resuming
                        // immediately races that registration. `collectWithGateChoice` (the gate
                        // twin) sleeps for exactly this reason; same fix here.
                        try? await Task.sleep(for: .milliseconds(50))
                        await ExecutionSuspensionService.shared.resume(for: operationID, approved: true, resolvedBy: .localUI)
                    }
                }
                return collectedEvents
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return nil
            }
            guard let first = try await group.next(), let result = first else {
                group.cancelAll()
                return nil
            }
            group.cancelAll()
            return result
        }
        guard let events = collected else {
            return XCTFail("the confirmation was never raised (or never resolved) within 10s — the run parked with nothing answering it")
        }

        XCTAssertTrue(events.contains { if case .requestConfirmation = $0 { return true }; return false },
                      "a ChatOps run must still ASK (park + mirror) — refusing it immediately deletes the working remote Approve/Deny flow, whose only alternative is disabling Ask-first globally")
        XCTAssertEqual(succeededToolNames(events), ["send_webhook"],
                       "resolving the mirrored confirmation must let the tool run, exactly as a real Telegram/Slack/Discord tap would")
    }

    /// The predicate that keeps the three decision sites from drifting apart.
    func testCanReachAHumanCoversLocalAndRemote() {
        XCTAssertTrue(WorkflowRunAttendance.isAttended, "default is attended")
        XCTAssertTrue(WorkflowRunAttendance.canReachAHuman)

        WorkflowRunAttendance.$isAttended.withValue(false) {
            XCTAssertFalse(WorkflowRunAttendance.canReachAHuman, "scheduled: nobody to ask")
            WorkflowRunAttendance.$hasRemoteResponder.withValue(true) {
                XCTAssertTrue(WorkflowRunAttendance.canReachAHuman, "ChatOps: a remote human can answer")
            }
        }
    }

    // MARK: - [WF-SE6] The AGENT path, which had no cover at all

    /// The review found every test landed on the Action-node arm, leaving the whole agent-path
    /// plumbing — `WorkflowNodeConfig` → `WorkflowExecutionContext.unattendedAutoApprove` →
    /// `ReActAgentExecutor` → `ToolExecutionLoop` — defended by nothing: blanking either
    /// `?? false` default left the suite green.
    ///
    /// ⚠️ Driven through the REAL `ReActAgentExecutor`, not the workflow mock: the mock stream
    /// provider REPLACES the inner executor, so a workflow-level test can never reach
    /// `ToolExecutionLoop`'s confirmation arm — which is precisely why this path had no cover.
    private func runAgentNode(unattendedAutoApprove: Bool) async throws -> [AgentStreamEvent] {
        let tool = TestToolFactory.make(name: "send_webhook", output: "sent", requiresConfirmation: true)
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(reasoning: "Posting.",
                                toolCalls: [TestToolCallFactory.make(name: "send_webhook", input: "payload")]),
            ModernCognitiveStep(reasoning: "Done.")
        ])
        let context = WorkflowExecutionContext(
            input: "post it",
            isFirstNode: true,
            nodeName: "Worker",
            nodeID: UUID(),
            unattendedAutoApprove: unattendedAutoApprove
        )
        let input = TestAgentInputFactory.make(query: "post the payload", tools: [tool], workflowContext: context)
        let stream = WorkflowRunAttendance.$isAttended.withValue(false) {
            ReActAgentExecutor(maxIterations: 3).execute(model: provider, input: input) { _ in }
        }
        return try await StreamCollector.collect(from: stream)
    }

    func testAgentNodeUnattended_RefusesConfirmationAndDoesNotRunTheTool() async throws {
        let events = try await runAgentNode(unattendedAutoApprove: false)

        XCTAssertTrue(succeededToolNames(events).isEmpty,
                      "the confirming tool must not run in a run nobody can answer")
        let refusals = failedTools(events).filter { $0.output.contains("unattended") }
        XCTAssertEqual(refusals.count, 1, "the agent must be TOLD, so it can finish honestly")
        XCTAssertEqual(refusals.first?.category, .permissionRejected)
    }

    /// …and the node's explicit setting reaches the agent path too — the half that no test touched.
    func testAgentNodeUnattendedWithExplicitConfig_RunsTheTool() async throws {
        let events = try await runAgentNode(unattendedAutoApprove: true)

        XCTAssertEqual(succeededToolNames(events), ["send_webhook"],
                       "the per-node setting must reach ToolExecutionLoop through WorkflowExecutionContext")
    }

    // MARK: - [Found on adversarial audit] ask_user's unattended-refusal must close its timeline row

    /// `ask_user` is the CLOSEST twin of the confirmation refusal — same function, ~80 lines
    /// above it — and is unconditionally present on every agent profile
    /// (`AgentConnect.wrapTool(AskUserTool(...), requiresConfirmation: false)`), so an unattended
    /// run is one model decision away from hitting it. The refusal arm returned a
    /// `ToolObservation` WITHOUT ever closing the `.toolCall` event opened at tool-dispatch time —
    /// the timeline showed the step as perpetually running (or, once a settle pass closes
    /// dangling rows, as an "Interrupted" failure) for a run that in fact completed cleanly on
    /// its own assumptions.
    func testUnattendedAskUser_ClosesItsTimelineRowHonestly() async throws {
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Need input.",
                toolCalls: [PendingToolCall(id: "1", name: "ask_user",
                                            arguments: ["question": .string("What should I deploy?")])]
            ),
            ModernCognitiveStep(reasoning: "Proceeding on my own judgment.")
        ])
        let context = WorkflowExecutionContext(
            input: "deploy something", isFirstNode: true,
            nodeName: "Worker", nodeID: UUID()
        )
        let input = TestAgentInputFactory.make(query: "deploy it", tools: [], workflowContext: context)
        let stream = WorkflowRunAttendance.$isAttended.withValue(false) {
            ReActAgentExecutor(maxIterations: 3).execute(model: provider, input: input) { _ in }
        }
        let events = try await StreamCollector.collect(from: stream)

        XCTAssertTrue(succeededToolNames(events).contains("ask_user"),
                      "the ask_user row must close with a terminal event — a run that completed cleanly must not leave its timeline showing a step still running or interrupted")
        XCTAssertTrue(failedTools(events).filter { $0.name == "ask_user" }.isEmpty,
                      "an unattended skip is not a failure — the agent proceeded on its own assumptions, which is success, not error")
    }
}
