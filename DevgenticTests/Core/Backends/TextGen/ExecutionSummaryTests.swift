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

    // MARK: - R2 (verifier): recovery is order-sensitive

    /// The recovered-failure filter used by the terminal block must only treat a
    /// LATER success as recovery. Here we assert the underlying data shape the
    /// filter depends on: an earlier success + later failure with identical args
    /// are two distinct records (not deduped), so the terminal block's index-based
    /// check can tell success-then-failure from failure-then-success.
    func testToolResults_SameArgsSuccessThenFailure_BothRecorded() {
        var summary = ExecutionSummary(originalGoal: "g")
        summary.record(toolCallId: "1", toolName: "list_directory", params: "{\"path\":\"/tmp\"}", output: "ok", isSuccess: true)
        summary.record(toolCallId: "2", toolName: "list_directory", params: "{\"path\":\"/tmp\"}", output: "Error: gone", isSuccess: false, failureCategory: .executionThrew)
        XCTAssertEqual(summary.toolResults.count, 2, "Same-args success then failure must both be recorded (not deduped)")
        XCTAssertEqual(summary.completionStatus, .partialSuccess)
        // The trailing failure is at index 1; no success exists AFTER it → the
        // terminal block's `allResults[(index+1)...]` recovery check yields false,
        // so this failure correctly counts as an unrecovered evidence failure.
        let trailingFailureIndex = 1
        let laterSuccess = summary.toolResults[(trailingFailureIndex + 1)...].contains {
            $0.isSuccess && $0.toolName == "list_directory" && $0.params == "{\"path\":\"/tmp\"}"
        }
        XCTAssertFalse(laterSuccess, "No success after the trailing failure → not recovered")
    }

    // MARK: - R3: User Decisions Are Not Evidence Failures

    func testMarkComplete_DeniedPlusSuccess_ReturnsSuccess() {
        // Regression: a denied write_file demoted an otherwise-successful run to
        // partialSuccess → amber chip + FAILED episode. Denials are decisions.
        var summary = ExecutionSummary(originalGoal: "Do the task")
        summary.record(toolCallId: "1", toolName: "write_file", params: "{}",
                       output: "Denied by user", isSuccess: false, failureCategory: .userDenied)
        summary.record(toolCallId: "2", toolName: "read_file", params: "{}",
                       output: "contents", isSuccess: true)
        summary.markComplete()
        XCTAssertEqual(summary.completionStatus, .success)
    }

    func testMarkComplete_AllDenied_ReturnsPartialSuccess() {
        // Everything the agent tried was declined — no evidence either way.
        var summary = ExecutionSummary(originalGoal: "Do the task")
        summary.record(toolCallId: "1", toolName: "write_file", params: "{}",
                       output: "Denied", isSuccess: false, failureCategory: .userDenied)
        summary.record(toolCallId: "2", toolName: "ask_user", params: "{}",
                       output: "Skipped by user.", isSuccess: false, failureCategory: .cancelled)
        summary.markComplete()
        XCTAssertEqual(summary.completionStatus, .partialSuccess,
                       "All-denied must not read as .failed — the user said no, nothing broke")
    }

    func testEvidenceResults_ExcludesDenialsAndSkips() {
        var summary = ExecutionSummary(originalGoal: "g")
        summary.record(toolCallId: "1", toolName: "a", params: "{}", output: "ok", isSuccess: true)
        summary.record(toolCallId: "2", toolName: "b", params: "{}", output: "denied", isSuccess: false, failureCategory: .userDenied)
        summary.record(toolCallId: "3", toolName: "c", params: "{}", output: "skipped", isSuccess: false, failureCategory: .cancelled)
        summary.record(toolCallId: "4", toolName: "d", params: "{}", output: "boom", isSuccess: false, failureCategory: .executionThrew)
        XCTAssertEqual(summary.evidenceResults.count, 2, "Only the success and the real failure are evidence")
    }

    // MARK: - markComplete() with All Failed Tools

    func testMarkComplete_AllFailed_ReturnsFailed() {
        // Regression: markComplete used to ceiling all-failed runs at
        // .partialSuccess, overwriting the honest .failed from recomputeStatus —
        // the run then shipped outcome=completed ("status lies").
        var summary = ExecutionSummary(originalGoal: "List files in Acme")
        summary.record(toolCallId: "1", toolName: "list_directory", params: "{}", output: "Error: no such file", isSuccess: false)
        summary.markComplete()
        XCTAssertEqual(summary.completionStatus, .failed)
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
