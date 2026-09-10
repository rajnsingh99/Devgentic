// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PerToolTimeoutTests.swift
//  DevgenticTests
//
//  Tests for per-tool timeout enforcement implemented in
//  ToolExecutionMediator.executePreparedTool().
//  Verifies that AgentTool.timeout and AgentTool.timeoutMessage are honored.
//

import XCTest
@testable import devgentic

final class PerToolTimeoutTests: XCTestCase {

    private let mediator = ToolExecutionMediator()
    private let traceContext = TestTraceContext.make()

    /// Helper: Serializes arguments to JSON-encoded data format expected by the mediator.
    private func makeArgs(_ input: String = "test") -> [String: JSONValue] {
        ["input": .string(input)]
    }

    // MARK: - Timeout Enforcement

    func testToolCompletesWithinTimeout_ReturnsSuccess() async {
        // Tool with 5s timeout that completes instantly
        let tool = TestToolFactory.makeWithTimeout(
            name: "fast_tool",
            timeout: 5.0,
            output: "Done quickly"
        )

        let result = await mediator.executePreparedTool(
            toolName: "fast_tool",
            arguments: makeArgs(),
            availableTools: [tool],
            parentContext: traceContext
        )

        XCTAssertTrue(result.isSuccess, "Tool completing within timeout should succeed")
        XCTAssertTrue(result.llmObservation.contains("Done quickly"))
    }

    func testToolExceedsTimeout_ReturnsTimedOut() async {
        // Tool that sleeps 10s but has 0.1s timeout → timeout wins
        let tool = TestToolFactory.makeSlowWithTimeout(
            name: "slow_tool",
            delay: 10.0,
            timeout: 0.1
        )

        let result = await mediator.executePreparedTool(
            toolName: "slow_tool",
            arguments: makeArgs(),
            availableTools: [tool],
            parentContext: traceContext
        )

        if case .timedOut(let name, let duration, _) = result {
            XCTAssertEqual(name, "slow_tool")
            XCTAssertEqual(duration, 0.1, accuracy: 0.01)
        } else {
            XCTFail("Expected .timedOut, got \(result)")
        }
    }

    func testToolExceedsTimeout_CustomMessage_ReturnsFailureWithMessage() async {
        // Tool that sleeps 10s, 0.1s timeout, with a custom timeout message. The message is
        // surfaced to the LLM, but the result must stay a FAILURE (.timedOut), not .success (#20).
        let tool = TestToolFactory.makeSlowWithTimeout(
            name: "custom_timeout_tool",
            delay: 10.0,
            timeout: 0.1,
            timeoutMessage: "This tool ran too long, try smaller input."
        )

        let result = await mediator.executePreparedTool(
            toolName: "custom_timeout_tool",
            arguments: makeArgs(),
            availableTools: [tool],
            parentContext: traceContext
        )

        XCTAssertFalse(result.isSuccess, "A timeout must be a failure even with a custom message (#20)")
        XCTAssertTrue(result.llmObservation.contains("ran too long"),
                      "The custom timeout message should still be surfaced to the LLM")
        guard case .timedOut = result else {
            return XCTFail("Expected .timedOut (not .success), got \(result)")
        }
    }

    func testToolWithNilTimeout_CompletesUnderDefault() async {
        // Tool with NO explicit timeout that takes 0.2s. A default timeout now applies on the
        // agent path (#20), but 0.2s is well under it, so the tool completes normally.
        let tool = TestToolFactory.makeSlow(
            name: "no_timeout_tool",
            delay: 0.2,
            output: "Completed after delay"
        )

        let result = await mediator.executePreparedTool(
            toolName: "no_timeout_tool",
            arguments: makeArgs(),
            availableTools: [tool],
            parentContext: traceContext
        )

        XCTAssertTrue(result.isSuccess, "Tool completing under the default timeout should succeed")
        XCTAssertTrue(result.llmObservation.contains("Completed after delay"))
    }

    func testToolWithNilTimeout_DefaultTimeoutFires() async {
        // Inject a tiny default so we can verify the agent-path default timeout actually bounds
        // a hung tool that sets no explicit timeout (#20) — without a real 60s wait.
        let mediator = ToolExecutionMediator(defaultToolTimeout: 0.1)
        let tool = TestToolFactory.makeSlow(
            name: "hung_tool",
            delay: 10.0,
            output: "should never be returned"
        )

        let result = await mediator.executePreparedTool(
            toolName: "hung_tool",
            arguments: makeArgs(),
            availableTools: [tool],
            parentContext: traceContext
        )

        XCTAssertFalse(result.isSuccess, "A tool with no explicit timeout must still be bounded by the default")
        guard case .timedOut = result else {
            return XCTFail("Expected .timedOut from the default timeout, got \(result)")
        }
    }

    func testToolTimeout_LlmObservation_ContainsToolInfo() async {
        let tool = TestToolFactory.makeSlowWithTimeout(
            name: "observation_test_tool",
            delay: 10.0,
            timeout: 0.05
        )

        let result = await mediator.executePreparedTool(
            toolName: "observation_test_tool",
            arguments: makeArgs(),
            availableTools: [tool],
            parentContext: traceContext
        )

        if case .timedOut = result {
            XCTAssertTrue(result.llmObservation.contains("observation_test_tool") ||
                          result.llmObservation.lowercased().contains("timed out"),
                          "LLM observation should contain tool name or timeout info")
        } else {
            XCTFail("Expected .timedOut, got \(result)")
        }
    }
}
