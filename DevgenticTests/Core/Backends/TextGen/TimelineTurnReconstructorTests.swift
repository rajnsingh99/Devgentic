// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TimelineTurnReconstructorTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class TimelineTurnReconstructorTests: XCTestCase {

    // MARK: - Helpers

    private func tool(_ name: String,
                      step: Int?,
                      params: String = "{}",
                      output: String? = "ok",
                      success: Bool? = true,
                      executing: Bool = false,
                      failure: ToolFailureCategory? = nil) -> TimelineEvent {
        .toolExecution(ToolExecutionData(
            id: UUID(), name: name, params: params, output: output,
            isSuccess: success, failureCategory: failure, isExecuting: executing, stepId: step
        ))
    }

    private func reasoning(_ text: String) -> TimelineEvent {
        .reasoning(id: UUID(), text: text)
    }

    // MARK: - Grouping & pairing

    func testGroupsToolsByStepWithPairedIds() {
        let events: [TimelineEvent] = [
            tool("read_file", step: 1, params: "{\"path\":\"/a\"}", output: "data"),
            tool("write_file", step: 2, params: "{\"path\":\"/b\"}", output: "wrote")
        ]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil)

        XCTAssertEqual(r.completedSteps.count, 2)

        let s1 = r.completedSteps[0]
        XCTAssertEqual(s1.stepId, 1)
        XCTAssertEqual(s1.toolCalls.first?.name, "read_file")
        XCTAssertEqual(s1.toolCalls.first?.arguments["path"]?.stringValue, "/a")
        // Pairing: the observation shares the assistant call's synthesized id.
        XCTAssertEqual(s1.observations.first?.toolCallId, s1.toolCalls.first?.id)
        XCTAssertEqual(s1.observations.first?.output, "data")
        XCTAssertEqual(s1.observations.first?.isSuccess, true)

        XCTAssertEqual(r.completedSteps[1].stepId, 2)
        XCTAssertEqual(r.completedSteps[1].toolCalls.first?.name, "write_file")
        XCTAssertEqual(r.completedSteps[1].toolCalls.first?.arguments["path"]?.stringValue, "/b")
    }

    func testMultipleToolsInSameStepArePaired() {
        let events: [TimelineEvent] = [
            tool("read_file", step: 1, output: "a"),
            tool("code_search", step: 1, output: "b")
        ]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil)
        XCTAssertEqual(r.completedSteps.count, 1)
        let step = r.completedSteps[0]
        XCTAssertEqual(step.toolCalls.count, 2)
        XCTAssertEqual(step.observations.count, 2)
        // Each observation matches its own call by id.
        XCTAssertEqual(Set(step.toolCalls.map(\.id)), Set(step.observations.map(\.toolCallId)))
    }

    // MARK: - Parked tool

    func testParkedToolIsDanglingExecutingTool() {
        let opID = UUID()
        let events: [TimelineEvent] = [
            tool("read_file", step: 1, output: "data"),
            tool("delete_file", step: 1, params: "{\"path\":\"/x\"}", output: nil, success: nil, executing: true)
        ]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: opID)

        // The completed step holds only the finished autonomous tool; the dangling tool is excluded.
        XCTAssertEqual(r.completedSteps.count, 1)
        XCTAssertEqual(r.completedSteps[0].toolCalls.count, 1)
        XCTAssertEqual(r.completedSteps[0].toolCalls.first?.name, "read_file")

        XCTAssertEqual(r.parkedTool?.name, "delete_file")
        XCTAssertEqual(r.parkedTool?.arguments["path"]?.stringValue, "/x")
        XCTAssertEqual(r.parkedTool?.id, opID.uuidString, "Parked tool reuses the persisted operationID.")
        XCTAssertFalse(r.parkedToolIsClarification)
    }

    func testParkedClarificationDetection() {
        let events: [TimelineEvent] = [
            tool("ask_user", step: 1, params: "{\"question\":\"which file?\"}", output: nil, success: nil, executing: true)
        ]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: UUID())
        XCTAssertEqual(r.parkedTool?.name, "ask_user")
        XCTAssertTrue(r.parkedToolIsClarification)
        XCTAssertTrue(r.completedSteps.isEmpty)
    }

    func testNoParkedToolWhenAllCompleted() {
        let events: [TimelineEvent] = [tool("read_file", step: 1, output: "x")]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil)
        XCTAssertNil(r.parkedTool)
        XCTAssertFalse(r.parkedToolIsClarification)
    }

    func testDropDanglingToolForStreamingResume() {
        let events: [TimelineEvent] = [
            tool("read_file", step: 1, output: "data"),
            tool("delete_file", step: 2, params: "{\"path\":\"/x\"}", output: nil, success: nil, executing: true)
        ]

        // Streaming resume: the dangling mid-execution tool is DROPPED (not re-run), completed work stays.
        let dropped = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil, dropDanglingTool: true)
        XCTAssertNil(dropped.parkedTool, "Dangling tool must be dropped for a streaming resume.")
        XCTAssertFalse(dropped.parkedToolIsClarification)
        XCTAssertEqual(dropped.completedSteps.count, 1, "Completed tools are still replayed.")
        XCTAssertEqual(dropped.completedSteps.first?.toolCalls.first?.name, "read_file")
        XCTAssertEqual(dropped.resumeIteration, 2, "resumeIteration still reflects the dangling tool's iteration, so the loop continues at N+1.")

        // Parked resume (default): the dangling tool IS returned, to be re-raised.
        let kept = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil, dropDanglingTool: false)
        XCTAssertEqual(kept.parkedTool?.name, "delete_file")
        XCTAssertEqual(kept.completedSteps.count, 1)
    }

    // MARK: - Loop bookkeeping

    func testReasoningAttachedToStep() {
        let events: [TimelineEvent] = [
            reasoning("I should read the file first."),
            tool("read_file", step: 1, output: "data")
        ]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil)
        XCTAssertEqual(r.completedSteps.first?.reasoning, "I should read the file first.")
    }

    func testResumeIterationIsMaxStep() {
        let events: [TimelineEvent] = [
            tool("read_file", step: 1, output: "a"),
            tool("code_search", step: 2, output: "b"),
            tool("file_overview", step: 3, output: "c")
        ]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil)
        XCTAssertEqual(r.resumeIteration, 3)
    }

    // MARK: - Argument parsing

    func testArgsParsedFromParamsJSON() {
        let events: [TimelineEvent] = [
            tool("x", step: 1, params: "{\"a\":1,\"b\":\"hello\"}", output: "ok")
        ]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil)
        let args = r.completedSteps.first?.toolCalls.first?.arguments
        XCTAssertEqual(args?["b"]?.stringValue, "hello")
        XCTAssertNotNil(args?["a"])
    }

    func testMalformedParamsYieldEmptyArgsWithoutCrashing() {
        let events: [TimelineEvent] = [
            tool("x", step: 1, params: "not json at all", output: "ok")
        ]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil)
        XCTAssertEqual(r.completedSteps.first?.toolCalls.first?.arguments.isEmpty, true)
    }

    // MARK: - Failed / denied tools are preserved as history

    func testDeniedToolReconstructsAsFailedObservation() {
        let events: [TimelineEvent] = [
            tool("delete_file", step: 1, output: "User DENIED tool 'delete_file'.", success: false, failure: .userDenied)
        ]
        let r = TimelineTurnReconstructor.reconstruct(from: events, parkedOperationID: nil)
        let obs = r.completedSteps.first?.observations.first
        XCTAssertEqual(obs?.isSuccess, false)
        XCTAssertEqual(obs?.failureCategory, .userDenied)
        XCTAssertEqual(obs?.output, "User DENIED tool 'delete_file'.")
    }
}
