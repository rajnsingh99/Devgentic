// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TimeoutStatusSweepTests.swift
//  DevgenticTests
//
//  HITL Waiting Contract — status sweep (§3–4) and the MCP slice. A timeout is its own status with
//  its own wording and category everywhere, never "Failed", "Response Error", "Provider 5xx" or
//  "Cancelled by user".
//

import XCTest
@testable import devgentic

final class TimeoutStatusSweepTests: XCTestCase {

    // MARK: - The outcome

    func testTimedOutIsItsOwnOutcomeAndCountsAsAFailureWhereFailuresRender() {
        XCTAssertEqual(ExecutionOutcome.timedOut.displayName, "Timed out")
        XCTAssertTrue(ExecutionOutcome.timedOut.isFailureLike)
        XCTAssertTrue(ExecutionOutcome.failed.isFailureLike)
        XCTAssertFalse(ExecutionOutcome.cancelled.isFailureLike)
        XCTAssertFalse(ExecutionOutcome.completedWithWarnings.isFailureLike)
        XCTAssertEqual(EpisodeLifecycle(.timedOut), .failed, "episodic memory keeps the failure signal")
    }

    func testTheExecutionTimeoutWordingIsTheContracts() {
        XCTAssertEqual(ActiveStreamManager.executionTimeoutMessage(limit: 3600),
                       "Run stopped: it exceeded its 60 min execution limit. Time spent waiting for your approval was not counted.")
    }

    /// The chat/Code turn's execution limit lands as `.timedOut` with a "Timed out" card — pinned at
    /// the finalize chokepoint, which cannot be driven without a live backend.
    func testFinalizeRecordsAnExecutionLimitAsTimedOut() throws {
        let asm = try source("Devgentic/Core/Utils/ActiveStreamManager.swift")
        XCTAssertTrue(asm.contains("case .executionTimeout(_, let limit) = agentError.reason {\n            message.terminalOutcome = .timedOut"),
                      "an execution limit no longer finalizes as .timedOut")
        XCTAssertTrue(asm.contains("errorCard = .error(title: \"Timed out\""),
                      "an execution limit shows as a generic Response Error card again")
    }

    // MARK: - Categories: the timeout buckets finally have producers (D-16)

    func testAnLLMRequestThatKeepsTimingOutIsFiledAsAProviderTimeout() {
        var strategy = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        var action = strategy.handleError(URLError(.timedOut))
        for _ in 0..<10 {
            if case .fatal = action { break }
            action = strategy.handleError(URLError(.timedOut))
        }
        guard case .fatal(_, let category) = action else { return XCTFail("never gave up: \(action)") }
        XCTAssertEqual(category, .providerTimeout, "an exhausted timeout was filed as \(category)")

        var other = LLMRetryStrategy(maxConsecutiveParseFailures: 3)
        var serverAction = other.handleError(URLError(.networkConnectionLost))
        for _ in 0..<10 {
            if case .fatal = serverAction { break }
            serverAction = other.handleError(URLError(.networkConnectionLost))
        }
        guard case .fatal(_, let serverCategory) = serverAction else { return XCTFail("never gave up") }
        XCTAssertEqual(serverCategory, .providerServerError, "a non-timeout keeps its category")
    }

    func testToolTimeoutsReachTracesAsToolTimeout() throws {
        let mediator = try source("Devgentic/Core/Backends/TextGen/ReAct/Components/Execution/ToolExecutionMediator.swift")
        XCTAssertTrue(mediator.contains("failureCategory: result.failureCategory == .timeout ? .toolTimeout : nil"),
                      "the dispatcher no longer files a tool timeout as .toolTimeout")
        let recorder = try source("Devgentic/Observaliblity/TraceRecorder.swift")
        XCTAssertTrue(recorder.contains("(failureCategory ?? .toolSemanticFail)"),
                      "the recorder ignores the caller's category again — every failure becomes toolSemanticFail")
    }

    // MARK: - MCP: a cancelled call ends, the server is told, and it is never re-run

    func testMCPCancellationReachesTheServerAndIsNeverRetried() throws {
        let client = try source("Devgentic/Interfaces/Main/Views/Tooling/Mcp/MCPClientService.swift")
        guard let wait = client.range(of: "try await context.value") else {
            return XCTFail("the MCP call wait moved — this pin checks nothing")
        }
        let window = client[wait.lowerBound...].prefix(400)
        XCTAssertTrue(window.contains("} onCancel: {") && window.contains("client.cancelRequest(requestID"),
                      "a cancelled MCP call no longer sends notifications/cancelled — it waits on the server forever")

        let tool = try source("Devgentic/Interfaces/Main/Views/Tooling/Mcp/DynamicMCPTool.swift")
        XCTAssertTrue(tool.contains("if Task.isCancelled || initialError is CancellationError {"),
                      "a cancelled MCP call is reconnected and re-run again")
        XCTAssertTrue(tool.contains("if WorkflowRetryPolicy.isTimeout(initialError) {"),
                      "a timed-out MCP call is re-run again (decision F)")
        XCTAssertFalse(tool.contains("try? await Task.sleep"),
                       "the reconnect backoff swallows cancellation again")
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
