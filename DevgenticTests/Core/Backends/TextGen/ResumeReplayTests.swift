// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ResumeReplayTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ResumeReplayTests: XCTestCase {

    private func tool(_ name: String, step: Int, output: String) -> TimelineEvent {
        .toolExecution(ToolExecutionData(
            id: UUID(), name: name, params: "{}", output: output,
            isSuccess: true, isExecuting: false, stepId: step
        ))
    }

    func testLegacyReplayRebuildsScratchpadFromReconstruction() {
        let timeline: [TimelineEvent] = [
            .reasoning(id: UUID(), text: "Read the config first."),
            tool("read_file", step: 1, output: "PORT=8080"),
            tool("code_search", step: 2, output: "found 3 matches")
        ]
        let recon = TimelineTurnReconstructor.reconstruct(from: timeline, parkedOperationID: nil)
        XCTAssertEqual(recon.completedSteps.count, 2)

        // Mirror exactly what the unified resume preamble does for the legacy path.
        var memory = WindowedLinearMemory(config: .derive(contextWindow: 8192, tier: .medium))
        for step in recon.completedSteps {
            if let reasoning = step.reasoning, !reasoning.isEmpty {
                memory.recordReasoning(stepId: step.stepId, text: reasoning)
            }
            for obs in step.observations {
                memory.recordObservation(
                    stepId: obs.stepId, toolCallId: obs.toolCallId, toolName: obs.toolName,
                    params: obs.params, result: obs.result, artifacts: obs.artifacts
                )
            }
        }

        let scratchpad = memory.compileForPrompt()
        // The prior tool work must be visible to the resumed legacy model.
        XCTAssertNotEqual(scratchpad, "No actions taken yet.", "Replay must populate the scratchpad.")
        XCTAssertTrue(scratchpad.contains("read_file"), "Scratchpad should contain the first tool name.")
        XCTAssertTrue(scratchpad.contains("PORT=8080"), "Scratchpad should contain the first tool's output.")
        XCTAssertTrue(scratchpad.contains("code_search"), "Scratchpad should contain the second tool name.")
        XCTAssertTrue(scratchpad.contains("found 3 matches"), "Scratchpad should contain the second tool's output.")
    }

    func testEmptyReconstructionLeavesScratchpadEmpty() {
        // Sanity: with nothing to replay, the scratchpad is the empty sentinel (a fresh run).
        let memory = WindowedLinearMemory(config: .derive(contextWindow: 8192, tier: .medium))
        XCTAssertEqual(memory.compileForPrompt(), "No actions taken yet.")
    }
}
