// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolTimeoutContractTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ToolTimeoutContractTests: XCTestCase {

    private let conversation = UUID()

    override func tearDown() {
        BackgroundProcessRegistry.shared.discard(conversationID: conversation)
        super.tearDown()
    }

    private func shellArgs(_ command: String, timeout: Int) -> [String: JSONValue] {
        ["command": .string(command), "working_directory": .string("/tmp"), "timeout_seconds": .number(Double(timeout))]
    }

    private func status() -> BackgroundProcessRegistry.Status? {
        BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first?.status
    }

    // MARK: - P1: the tool timeout returns at its limit, stops the command, keeps its output

    func testAToolTimeoutStopsARunningCommandAndKeepsItsOutput() async {
        // A user override of 1 s on a command that would run 20 s.
        let tool = AgentToolFactory.wrap(RunCommandTool(conversationID: conversation),
                                         requiresConfirmation: false, timeout: 1)
        let start = ContinuousClock.now
        let result = await ToolExecutionMediator().executePreparedTool(
            toolName: "run_command", arguments: shellArgs("echo EARLY-LINE; sleep 20; echo NEVER", timeout: 30),
            availableTools: [tool], parentContext: TestTraceContext.make())
        let elapsed = ContinuousClock.now - start

        XCTAssertLessThan(elapsed, .seconds(5),
                          "the dispatcher held the call for \(elapsed) — it must return at its limit (P1 held 4.01 s on a 1 s bound)")
        guard case .timedOut = result else { return XCTFail("expected .timedOut, got \(result)") }
        let observation = result.llmObservation
        XCTAssertTrue(observation.contains("was stopped"), "the model must be told the work was STOPPED: \(observation)")
        XCTAssertTrue(observation.contains("EARLY-LINE"), "the partial output was discarded: \(observation)")
        XCTAssertFalse(observation.contains("NEVER"))
        XCTAssertEqual(status(), .stopped, "the command must actually be killed, not left to run to its own bound")
    }

    // MARK: - D-17: run_command's OWN outcome is classified, not recorded as a success

    /// Mutation that must turn this red: have `RunCommandTool.call` return the timed-out text.
    func testACommandKilledAtItsOwnTimeoutIsATimeout() async {
        let tool = AgentToolFactory.wrap(RunCommandTool(conversationID: conversation), requiresConfirmation: false)
        let result = await ToolExecutionMediator().executePreparedTool(
            toolName: "run_command", arguments: shellArgs("echo EARLY-LINE; sleep 20", timeout: 1),
            availableTools: [tool], parentContext: TestTraceContext.make())

        guard case .timedOut = result else { return XCTFail("a command killed at its own bound was recorded as \(result)") }
        XCTAssertEqual(result.failureCategory, .timeout)
        XCTAssertTrue(result.llmObservation.contains("timed out after 1s"), result.llmObservation)
        XCTAssertTrue(result.llmObservation.contains("EARLY-LINE"), "the partial output must still reach the model")
    }

    /// The user stops just the command (task panel) while the run goes on: cancelled, with output.
    /// Mutation that must turn this red: drop the `.stopped` catch in the mediator.
    func testACommandStoppedByTheUserIsCancelledWithItsOutput() async throws {
        let tool = AgentToolFactory.wrap(RunCommandTool(conversationID: conversation), requiresConfirmation: false)
        let call = Task {
            await ToolExecutionMediator().executePreparedTool(
                toolName: "run_command", arguments: shellArgs("echo EARLY-LINE; sleep 20", timeout: 60),
                availableTools: [tool], parentContext: TestTraceContext.make())
        }
        var taskID: String?
        for _ in 0..<100 where taskID == nil {
            try await Task.sleep(for: .milliseconds(20))
            taskID = BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first?.id
        }
        try await Task.sleep(for: .milliseconds(300))
        _ = BackgroundProcessRegistry.shared.stop(conversationID: conversation, taskID: try XCTUnwrap(taskID))
        let result = await call.value

        guard case .cancelled(_, let message?) = result else { return XCTFail("expected cancelled with output, got \(result)") }
        XCTAssertTrue(message.contains("EARLY-LINE"), message)
        XCTAssertFalse(result.isSuccess)
    }

    // MARK: - P2: Stop kills a foreground command

    func testCancellingTheCallerStopsAForegroundCommand() async throws {
        let tool = RunCommandTool(conversationID: conversation)
        let args = try JSONDecoder().decode(ShellCommandArguments.self, from: Data(
            #"{"command":"sleep 20; echo NEVER","working_directory":"/tmp","timeout_seconds":60}"#.utf8))
        let start = ContinuousClock.now
        let task = Task { try await tool.call(arguments: args) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        // D-17: a stopped command is THROWN as such (with its partial output), not returned as text.
        let output: String
        do {
            output = try await task.value
            XCTFail("a stopped command must be reported as stopped, not as a finished result")
        } catch ShellCommandError.stopped(let observation) {
            output = observation
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(4),
                          "Stop left the command running to its bound (P2: returned only when it finished)")
        XCTAssertEqual(status(), .stopped)
        XCTAssertFalse(output.contains("NEVER"))
    }

    // MARK: - P7: Stop mid-tool is a cancellation, not a crash

    func testStopDuringAToolIsRecordedAsCancelled() async throws {
        let tool = TestToolFactory.makeSlow(name: "slow_tool", delay: 5)
        let task = Task {
            await ToolExecutionMediator().executePreparedTool(
                toolName: "slow_tool", arguments: ["input": .string("x")],
                availableTools: [tool], parentContext: TestTraceContext.make())
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled(toolName: "slow_tool"),
                       "a Stop was recorded as \(result) — it used to be a .systemError tool crash")
        XCTAssertEqual(result.failureCategory, .cancelled)
    }

    // MARK: - Work that cannot be stopped is reported as such, not waited for

    func testANonStoppableToolIsReportedAsStillRunning() async {
        let tool = AgentTool(name: "stuck", description: "", parameters: ToolParameters(type: "object", properties: [:], required: []),
                             textOnlyRun: { _ in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume(returning: "late") }
            }
        })
        var mediator = ToolExecutionMediator(defaultToolTimeout: 0.3)
        mediator.stopGrace = 0.2
        let start = ContinuousClock.now
        let result = await mediator.executePreparedTool(toolName: "stuck", arguments: [:], availableTools: [tool],
                                                        parentContext: TestTraceContext.make())
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(1500))
        guard case .timedOut = result else { return XCTFail("expected .timedOut, got \(result)") }
        XCTAssertTrue(result.llmObservation.contains("may still be running"), result.llmObservation)
    }

    // MARK: - Limits (Contract decision 2 + "No limit" rule)

    /// P9: 0 and negative used to mean "time out instantly".
    func testAnUnusableOverrideFallsBackInsteadOfTimingOutInstantly() async {
        for bad in [0.0, -1.0, .infinity, .nan] {
            let tool = TestToolFactory.makeSlowWithTimeout(name: "t", delay: 0.05, timeout: bad)
            let result = await ToolExecutionMediator(defaultToolTimeout: 5).executePreparedTool(
                toolName: "t", arguments: ["input": .string("x")], availableTools: [tool],
                parentContext: TestTraceContext.make())
            XCTAssertTrue(result.isSuccess, "timeout \(bad) produced \(result)")
        }
    }

    func testTheDefaultsAreTheContractsDefaults() {
        XCTAssertEqual(ToolExecutionMediator.globalDefaultToolTimeout, 15 * 60)
        XCTAssertEqual(BatchCommandTool.maxTimeoutSeconds, 30 * 60)
        XCTAssertEqual(CodeSessionManager.presetExecutionTimeout, 60 * 60)
    }

    /// A terminal tool bounds ITSELF; the dispatcher must sit above that, or it cuts in first and
    /// discards the partial output the tool's own kill returns (D-01). Checked through the real
    /// wrapping path, which is where the ceiling could be dropped.
    func testTerminalToolsAreBoundJustAboveTheirOwnCeiling() {
        let ceiling = TimeInterval(BatchCommandTool.maxTimeoutSeconds)
        for tool in [AgentToolFactory.wrap(RunCommandTool(conversationID: conversation), requiresConfirmation: false),
                     AgentToolFactory.wrap(StartBackgroundTaskTool(conversationID: conversation), requiresConfirmation: false),
                     AgentToolFactory.wrap(BatchCommandTool(conversationID: conversation), requiresConfirmation: false)] {
            let limit = ToolExecutionMediator.effectiveTimeout(for: tool, defaultTimeout: ToolExecutionMediator.globalDefaultToolTimeout)
            XCTAssertGreaterThan(limit, ceiling, "\(tool.name) would be cut off by the dispatcher before its own bound")
        }
        let plain = TestToolFactory.make(name: "plain", output: "x")
        XCTAssertEqual(ToolExecutionMediator.effectiveTimeout(for: plain, defaultTimeout: 900), 900)
    }

    /// Every limit lives inside the one above it (decision D): a Code turn must outlast a
    /// full-length terminal command plus the dispatcher's headroom.
    func testTheCodeRunBudgetOutlastsAFullLengthCommand() {
        XCTAssertGreaterThan(CodeSessionManager.presetExecutionTimeout,
                             TimeInterval(BatchCommandTool.maxTimeoutSeconds) + ToolExecutionMediator.selfBoundHeadroom)
    }
}
