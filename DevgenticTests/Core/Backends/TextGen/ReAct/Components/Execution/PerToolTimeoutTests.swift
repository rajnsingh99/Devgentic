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

        if case .timedOut(let name, let duration) = result {
            XCTAssertEqual(name, "slow_tool")
            XCTAssertEqual(duration, 0.1, accuracy: 0.01)
        } else {
            XCTFail("Expected .timedOut, got \(result)")
        }
    }

    func testToolExceedsTimeout_CustomMessage_ReturnsSuccessWithMessage() async {
        // Tool that sleeps 10s, 0.1s timeout, but has a custom timeout message
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

        // Custom timeout message returns as .success, not .timedOut
        XCTAssertTrue(result.isSuccess, "Custom timeout message should produce success result")
        XCTAssertTrue(result.llmObservation.contains("ran too long"),
                      "Should use custom timeout message")
    }

    func testToolWithNilTimeout_NoTimeoutEnforced() async {
        // Tool with NO timeout that takes 0.2s — should complete normally
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

        XCTAssertTrue(result.isSuccess, "Tool with nil timeout should complete normally")
        XCTAssertTrue(result.llmObservation.contains("Completed after delay"))
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
