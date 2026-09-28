// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ParkScopeCreditTests.swift
//  DevgenticTests
//
//  HITL Waiting Contract — slice 2: OWNER-CHAIN park credit (decision A) and "a human is never
//  timed", including inside a tool call (decision 1). Replaces per-conversation credit, under which
//  any open banner in a conversation froze every clock in it (Timeout inventory D-18).
//

import XCTest
@testable import devgentic

@MainActor
final class ParkScopeCreditTests: XCTestCase {

    private let suspension = ExecutionSuspensionService.shared

    /// Parks a gate from a task created INSIDE `chain` and waits until it is installed.
    private func park(_ op: UUID, in conversation: UUID, chain: [UUID]) async throws -> Task<String?, Never> {
        let before = await suspension.pendingSuspensionCount()
        let task = Task.detached {
            await ParkScope.$chain.withValue(chain) {
                await ExecutionSuspensionService.shared.suspendForGate(for: op, conversationID: conversation)
            }
        }
        for _ in 0..<400 {
            if await suspension.pendingSuspensionCount() > before { return task }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("gate \(op) never parked")
        return task
    }

    private func release(_ op: UUID, _ task: Task<String?, Never>) async {
        await suspension.resumeGate(for: op, chosenOption: "X", resolvedBy: .localUI)
        _ = await task.value
    }

    // MARK: - Decision A: only the owner chain is credited

    func testAParkPausesOnlyTheBoundsInItsOwnChain() async throws {
        let conversation = UUID(), mine = UUID(), sibling = UUID(), op = UUID()
        await suspension.registerScope(mine, conversationID: conversation)
        await suspension.registerScope(sibling, conversationID: conversation)
        defer { Task { await self.suspension.unregisterScope(mine); await self.suspension.unregisterScope(sibling) } }

        let parked = try await park(op, in: conversation, chain: [mine])
        try await Task.sleep(for: .milliseconds(300))
        await release(op, parked)

        let credited = await suspension.parkedTime(forScope: mine)
        let leaked = await suspension.parkedTime(forScope: sibling)
        XCTAssertGreaterThan(credited, 0.25, "the park's own bound was not paused")
        XCTAssertEqual(leaked, 0, accuracy: 0.001,
                       "a SIBLING bound in the same conversation was paused by a park it does not own — the D-18 freeze")
    }

    /// A park from outside every chain — an MCP question arrives on the transport's own task —
    /// cannot name its owner, so every bound open in its conversation is paused (and only there).
    func testAnOutOfChainParkPausesEveryOpenBoundInItsConversationOnly() async throws {
        let conversation = UUID(), other = UUID(), open = UUID(), elsewhere = UUID(), op = UUID()
        await suspension.registerScope(open, conversationID: conversation)
        await suspension.registerScope(elsewhere, conversationID: other)
        defer { Task { await self.suspension.unregisterScope(open); await self.suspension.unregisterScope(elsewhere) } }

        let parked = try await park(op, in: conversation, chain: [])
        try await Task.sleep(for: .milliseconds(300))
        await release(op, parked)

        let openParked = await suspension.parkedTime(forScope: open)
        let elsewhereParked = await suspension.parkedTime(forScope: elsewhere)
        XCTAssertGreaterThan(openParked, 0.25)
        XCTAssertEqual(elsewhereParked, 0, accuracy: 0.001)
    }

    /// A tool call's bound registers under its turn, so an out-of-chain MCP question raised during
    /// the call pauses the TOOL's clock too, not just the turn's.
    func testANestedBoundInheritsItsParentsConversation() async throws {
        let conversation = UUID(), turn = UUID(), tool = UUID(), op = UUID()
        await suspension.registerScope(turn, conversationID: conversation)
        await suspension.registerScope(tool, under: [turn])
        defer { Task { await self.suspension.unregisterScope(turn); await self.suspension.unregisterScope(tool) } }

        let parked = try await park(op, in: conversation, chain: [])
        try await Task.sleep(for: .milliseconds(300))
        await release(op, parked)

        let toolParked = await suspension.parkedTime(forScope: tool)
        XCTAssertGreaterThan(toolParked, 0.25)
    }

    // MARK: - Decision 1: a human inside a tool call is not timed

    /// THE WIRING through the real dispatcher: a tool that asks a human mid-call and waits longer
    /// than its own limit must still succeed. Before slice 2 the per-tool clock was wall-clock, so
    /// the answer arrived after the call had been reported timed out.
    func testAHumanWaitInsideAToolDoesNotCountAgainstItsLimit() async throws {
        let op = UUID(), conversation = UUID(), turn = UUID()
        await suspension.registerScope(turn, conversationID: conversation)
        defer { Task { await self.suspension.unregisterScope(turn) } }

        let tool = AgentTool(name: "asks_human", description: "",
                             parameters: ToolParameters(type: "object", properties: [:], required: []),
                             textOnlyRun: { _ in
            let answer = await ExecutionSuspensionService.shared.suspendForGate(for: op, conversationID: conversation)
            return "answered \(answer ?? "nil")"
        })
        let mediator = ToolExecutionMediator(defaultToolTimeout: 0.5)

        let call = Task.detached {
            await ParkScope.$chain.withValue([turn]) {
                await mediator.executePreparedTool(toolName: "asks_human", arguments: [:], availableTools: [tool],
                                                   parentContext: TestTraceContext.make())
            }
        }
        for _ in 0..<400 {
            if await suspension.pendingSuspensionCount() > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(1200))   // the human takes 2.4× the tool's limit
        await suspension.resumeGate(for: op, chosenOption: "yes", resolvedBy: .localUI)

        let result = await call.value
        XCTAssertEqual(result, .success(output: "answered yes"),
                       "the tool was timed while a human was answering it: \(result)")
    }

    // MARK: - D-18 end to end: a sibling's open gate must not freeze a node's timeout

    /// ⚠️ The sibling must run CONCURRENTLY with the gate. Within a level, structural nodes run
    /// before profile nodes, so a gate beside a profile node only ever QUEUES it — the first draft
    /// of this test put them side by side and measured the queue, not the freeze. A gate and a
    /// sub-workflow node share one structural lane, and the sub-workflow is bounded only by its
    /// outer COMPUTE budget, which is exactly the clock a foreign park used to freeze.
    func testASiblingsOpenGateDoesNotFreezeANodesTimeout() async throws {
        let provider = MockWorkflowStreamProvider()
        let scenario = WorkflowTestScenario()
        let inner = InnerWorkflowBuilder()
        let innerBot = inner.addBotNode(name: "Slow Inner")
        inner.save()
        defer { inner.cleanup() }
        for (id, profile) in inner.profileMap { scenario.profileMap[id] = profile }

        let hung = scenario.addSubWorkflowNode(name: "Hung", workflowProfileID: inner.workflowProfileID)
        _ = scenario.addGateNode(name: "Hold")       // no timeout: waits for a human indefinitely
        var config = WorkflowNodeConfig()
        config.hardTimeout = 0.5
        scenario.setNodeConfig(config, for: hung)
        provider.scriptDelayedStream(for: inner.profileID(for: innerBot)!, events: [.content("late")], milliseconds: 10_000)

        let stream = WorkflowExecutor(workflowProfileID: UUID()).executeWorkflow(
            userInput: "go", conversationID: UUID(), traceContext: TestTraceContext.make(),
            onTraceUpdate: { _ in }, layout: scenario.layout, profileMap: scenario.profileMap,
            streamProvider: provider)

        let start = ContinuousClock.now
        var hungFailedAt: Duration?
        var gateOp: UUID?
        for try await event in stream {
            if case .requestGate(_, _, let op, _, _, _, _, _) = event {
                gateOp = op
                // Fallback: answer the gate after 4 s regardless, so a regression FAILS rather than
                // hanging on a gate nobody answers.
                Task.detached {
                    try? await Task.sleep(for: .seconds(4))
                    await ExecutionSuspensionService.shared.resumeGate(for: op, chosenOption: "Approve", resolvedBy: .localUI)
                }
            }
            if case .workflowNodeFailed(let id, _, _, _) = event, id == hung, hungFailedAt == nil {
                hungFailedAt = ContinuousClock.now - start
                // The node failed while the gate was still open — now let the run finish.
                if let gateOp {
                    await ExecutionSuspensionService.shared.resumeGate(for: gateOp, chosenOption: "Approve", resolvedBy: .localUI)
                }
            }
        }

        let failedAt = try XCTUnwrap(hungFailedAt, "the hung node never timed out")
        XCTAssertLessThan(failedAt, .seconds(3),
                          "the hung node timed out only after the sibling gate was answered (\(failedAt)) — its clock was frozen by a park it does not own (D-18)")
    }

    // MARK: - Wiring pins (paths a behavioural test cannot drive without a live backend)

    /// A turn's executor stream must be CREATED inside the turn's scope, and its budget must read
    /// that scope — otherwise the turn's own banners fall back to crediting every open bound in the
    /// conversation, and the budget reads a scope nothing parks in.
    func testTheAgentTurnAndProfileNodesRunInsideTheirOwnScope() throws {
        let agent = try source("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        XCTAssertTrue(agent.contains("ParkScope.bind(turnScope) {\n                        ExecutionBudget.bind(turnFrame) {\n                            executor.execute(model: model, input: input, onTraceUpdate: traceHandler)"),
                      "the chat/Code turn's executor no longer runs inside its park scope")
        XCTAssertTrue(agent.contains("scope: turnScope,"), "the turn budget no longer reads the turn's scope")

        let workflow = try source("Devgentic/Core/Backends/WorkflowGen/WorkflowExecutor.swift")
        XCTAssertTrue(workflow.contains("ParkScope.bind(nodeScope) {\n                        ExecutionBudget.bind(nodeFrame) {\n                            agentConnect.streamWorkflowNodeResponse("),
                      "a profile node's inner run no longer runs inside the node's park scope")
        XCTAssertTrue(workflow.contains("computeTimeoutSentinel(nodeTimeout, scope: nodeScope"),
                      "a profile node's budget no longer reads the node's scope")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}
