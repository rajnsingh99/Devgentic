//
//  ExecutionSummaryTests.swift
//  DevgenticTests
//
//  Tests for ExecutionSummary outcome classification logic.
//  Validates CompletionStatus transitions: success, partialSuccess, failed, stalled.
//

import XCTest
@testable import devgentic

final class ExecutionSummaryTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState_IsStalled() {
        let summary = ExecutionSummary(originalGoal: "Test goal")
        XCTAssertEqual(summary.completionStatus, .stalled)
        XCTAssertTrue(summary.toolResults.isEmpty)
        XCTAssertNil(summary.failureReason)
    }

    // MARK: - markComplete() with No Tools

    func testMarkComplete_NoTools_ReturnsPartialSuccess() {
        var summary = ExecutionSummary(originalGoal: "Find files")
        summary.markComplete()
        XCTAssertEqual(summary.completionStatus, .partialSuccess)
    }

    func testMarkComplete_NoTools_WithFailureReason() {
        var summary = ExecutionSummary(originalGoal: "Find files")
        summary.markComplete(failureReason: "Parser dropped tool calls")
        XCTAssertEqual(summary.completionStatus, .partialSuccess)
        XCTAssertEqual(summary.failureReason, "Parser dropped tool calls")
    }

    // MARK: - markComplete() with All Successful Tools

    func testMarkComplete_AllSuccess_ReturnsSuccess() {
        var summary = ExecutionSummary(originalGoal: "List and read files")
        summary.record(toolCallId: "1", toolName: "list_directory", params: "{}", output: "file1.txt", isSuccess: true)
        summary.record(toolCallId: "2", toolName: "read_file", params: "{}", output: "contents", isSuccess: true)
        summary.markComplete()
        XCTAssertEqual(summary.completionStatus, .success)
    }

    // MARK: - markComplete() with Mixed Results

    func testMarkComplete_MixedResults_ReturnsPartialSuccess() {
        var summary = ExecutionSummary(originalGoal: "Run multiple tools")
        summary.record(toolCallId: "1", toolName: "list_directory", params: "{}", output: "ok", isSuccess: true)
        summary.record(toolCallId: "2", toolName: "read_file", params: "{}", output: "Error: not found", isSuccess: false)
        summary.markComplete()
        XCTAssertEqual(summary.completionStatus, .partialSuccess)
    }

    // MARK: - record() Status Recomputation

    func testRecord_SingleSuccess_StatusIsSuccess() {
        var summary = ExecutionSummary(originalGoal: "Test")
        summary.record(toolCallId: "1", toolName: "list_directory", params: "{}", output: "ok", isSuccess: true)
        XCTAssertEqual(summary.completionStatus, .success)
    }

    func testRecord_SingleFailure_StatusIsFailed() {
        var summary = ExecutionSummary(originalGoal: "Test")
        summary.record(toolCallId: "1", toolName: "list_directory", params: "{}", output: "error", isSuccess: false)
        XCTAssertEqual(summary.completionStatus, .failed)
    }

    func testRecord_SuccessThenFailure_StatusIsPartialSuccess() {
        var summary = ExecutionSummary(originalGoal: "Test")
        summary.record(toolCallId: "1", toolName: "list_directory", params: "{}", output: "ok", isSuccess: true)
        XCTAssertEqual(summary.completionStatus, .success)
        summary.record(toolCallId: "2", toolName: "read_file", params: "{}", output: "error", isSuccess: false)
        XCTAssertEqual(summary.completionStatus, .partialSuccess)
    }

    func testRecord_AllFailed_StatusIsFailed() {
        var summary = ExecutionSummary(originalGoal: "Test")
        summary.record(toolCallId: "1", toolName: "list_directory", params: "{}", output: "err1", isSuccess: false)
        summary.record(toolCallId: "2", toolName: "read_file", params: "{}", output: "err2", isSuccess: false)
        XCTAssertEqual(summary.completionStatus, .failed)
    }

    // MARK: - finalAgentThought

    func testFinalAgentThought_SetAndRead() {
        var summary = ExecutionSummary(originalGoal: "Test")
        XCTAssertNil(summary.finalAgentThought)
        summary.finalAgentThought = "The agent decided to terminate."
        XCTAssertEqual(summary.finalAgentThought, "The agent decided to terminate.")
    }

    // MARK: - Tool Results Accumulation

    func testToolResults_Accumulated() {
        var summary = ExecutionSummary(originalGoal: "Test")
        summary.record(toolCallId: "a", toolName: "tool1", params: "{}", output: "out1", isSuccess: true)
        summary.record(toolCallId: "b", toolName: "tool2", params: "{}", output: "out2", isSuccess: true)
        summary.record(toolCallId: "c", toolName: "tool3", params: "{}", output: "out3", isSuccess: false)
        XCTAssertEqual(summary.toolResults.count, 3)
        XCTAssertEqual(summary.toolResults[0].toolName, "tool1")
        XCTAssertEqual(summary.toolResults[1].toolName, "tool2")
        XCTAssertEqual(summary.toolResults[2].toolName, "tool3")
    }
}
