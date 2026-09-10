// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PlanningValidationTests.swift
//  DevgenticTests
//
//  Red-green validation tests for PlanningCapability production fixes.
//
//  G4: Subtask tool results now aggregated into synthesis ExecutionSummary
//  G5: Episode duplication prevented via suppressEpisodeManagement
//

import XCTest
@testable import devgentic

@MainActor
final class PlanningValidationTests: XCTestCase {

    // MARK: - Helpers

    private func makeNumberedPlan(_ steps: [(description: String, tools: [String]?)]) -> String {
        steps.enumerated().map { index, step in
            var line = "\(index + 1). \(step.description)"
            if let tools = step.tools, !tools.isEmpty {
                line += " [\(tools.joined(separator: ", "))]"
            }
            return line
        }.joined(separator: "\n")
    }

    private func makePlanningExecutor() -> any Executor {
        let innerExecutor = ReActAgentExecutor(maxIterations: 5)
        let config = PlanningCapabilityConfig(
            maxSubtasks: 5,
            parallelSubtasks: false,
            subtaskToolFiltering: false,
            requiresPlanApproval: false
        )
        return PlanningCapability(config: config).wrap(innerExecutor)
    }

    // MARK: - G4: Subtask Tool Results Forwarded to Outer Stream

    func testG4_ToolOutputEvents_ForwardedFromSubtasks() async throws {
        // Before fix: .toolOutput events from subtask inner executors were dropped.
        // After fix: They should be forwarded to the Planning outer stream.
        let plan = makeNumberedPlan([
            (description: "Run the linter", tools: nil)
        ])

        let lintTool = TestToolFactory.make(name: "lint", output: "No lint errors found.")

        let provider = MockLLMProvider(
            steps: [
                // Subtask 1 ReAct loop
                ModernCognitiveStep(
                    reasoning: "Running linter.",
                    toolCalls: [TestToolCallFactory.make(name: "lint", input: "src/")]
                ),
                ModernCognitiveStep(reasoning: "Linting complete, no errors.")
            ],
            generateResponses: [plan]
        )

        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(query: "Lint the source code", tools: [lintTool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // G4 assertion: .toolOutput events should be present in the outer stream
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertGreaterThan(toolOutputs.count, 0,
                             "Planning stream should forward .toolOutput events from subtask executors (G4)")
        XCTAssertEqual(toolOutputs[0].toolName, "lint")
        XCTAssertTrue(toolOutputs[0].isSuccess)
    }

    // MARK: - G4: Multiple Subtask Tool Results Aggregated

    func testG4_MultipleSubtaskToolResults_AllForwarded() async throws {
        // 2 subtasks, each using a different tool.
        // Both tool outputs should appear in the outer stream.
        let plan = makeNumberedPlan([
            (description: "Check formatting", tools: nil),
            (description: "Run tests", tools: nil)
        ])

        let formatTool = TestToolFactory.make(name: "format_check", output: "All files formatted.")
        let testTool = TestToolFactory.make(name: "run_tests", output: "15 tests passed.")

        let provider = MockLLMProvider(
            steps: [
                // Subtask 1
                ModernCognitiveStep(
                    reasoning: "Checking format.",
                    toolCalls: [TestToolCallFactory.make(name: "format_check", input: "src/")]
                ),
                ModernCognitiveStep(reasoning: "Format OK."),
                // Subtask 2
                ModernCognitiveStep(
                    reasoning: "Running tests.",
                    toolCalls: [TestToolCallFactory.make(name: "run_tests", input: "all")]
                ),
                ModernCognitiveStep(reasoning: "All tests passed.")
            ],
            generateResponses: [plan]
        )

        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(
            query: "Check formatting and run tests",
            tools: [formatTool, testTool]
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // G4 assertion: both tools should produce outputs
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.count, 2,
                       "Both subtask tools should produce forwarded outputs (G4)")

        let toolNames = Set(toolOutputs.map(\.toolName))
        XCTAssertTrue(toolNames.contains("format_check"), "format_check output should be forwarded")
        XCTAssertTrue(toolNames.contains("run_tests"), "run_tests output should be forwarded")
    }

    // MARK: - Phase-3 Composition (user-visible once synthesis is opt-in)

    /// Phase 3's IC call used to BE the composition step. With synthesis strictly
    /// opt-in, this text reaches the user verbatim on an un-opted run, so subtasks
    /// must be labeled and separated by a BLANK line — a single newline let markdown
    /// lazily continue the previous subtask's bullet list, running them together.
    func testComposeSubtaskResults_MultipleSubtasks_LabelsAndSeparatesWithBlankLine() {
        let subtasks = [
            SubTask(id: "s1", description: "List the files"),
            SubTask(id: "s2", description: "Check the port")
        ]
        let results = [
            "s1": "Here's what I found:\n• fs_list: a.swift, b.swift",
            "s2": "The port is 8080."
        ]

        let composed = PlanningExecutorWrapper.composeSubtaskResults(subtasks: subtasks, results: results)

        XCTAssertTrue(composed.contains("### List the files"), "Each subtask should be labeled")
        XCTAssertTrue(composed.contains("### Check the port"))
        XCTAssertTrue(composed.contains("\n\n### Check the port"),
                      "A blank line must separate subtasks so the previous bullet list terminates")
        XCTAssertFalse(composed.contains("b.swift\n### "),
                       "A bare newline between a bullet list and the next heading is the run-together bug")
    }

    /// Order follows the plan, not the dictionary's arbitrary iteration order.
    func testComposeSubtaskResults_PreservesPlanOrder() {
        let subtasks = [
            SubTask(id: "s1", description: "First"),
            SubTask(id: "s2", description: "Second"),
            SubTask(id: "s3", description: "Third")
        ]
        let results = ["s3": "third result", "s1": "first result", "s2": "second result"]

        let composed = PlanningExecutorWrapper.composeSubtaskResults(subtasks: subtasks, results: results)

        guard let firstIdx = composed.range(of: "first result")?.lowerBound,
              let secondIdx = composed.range(of: "second result")?.lowerBound,
              let thirdIdx = composed.range(of: "third result")?.lowerBound else {
            return XCTFail("All three results should appear; got: \(composed)")
        }
        XCTAssertTrue(firstIdx < secondIdx && secondIdx < thirdIdx, "Results must follow plan order")
    }

    /// A single-subtask plan has nothing to disambiguate — a heading over the only
    /// answer is noise, and would leak plan scaffolding into a simple reply.
    func testComposeSubtaskResults_SingleSubtask_ReturnsAnswerBare() {
        let subtasks = [SubTask(id: "s1", description: "Say hi")]
        let composed = PlanningExecutorWrapper.composeSubtaskResults(
            subtasks: subtasks, results: ["s1": "Hello there."]
        )
        XCTAssertEqual(composed, "Hello there.")
    }

    /// Missing / empty results contribute nothing rather than blank labeled sections.
    func testComposeSubtaskResults_SkipsMissingAndEmptyResults() {
        let subtasks = [
            SubTask(id: "s1", description: "Ran"),
            SubTask(id: "s2", description: "Never ran"),
            SubTask(id: "s3", description: "Blank"),
            SubTask(id: "s4", description: "Also ran")
        ]
        let results = ["s1": "first", "s3": "   \n  ", "s4": "second"]

        let composed = PlanningExecutorWrapper.composeSubtaskResults(subtasks: subtasks, results: results)

        XCTAssertFalse(composed.contains("Never ran"), "A subtask with no result contributes nothing")
        XCTAssertFalse(composed.contains("Blank"), "A whitespace-only result contributes nothing")
        XCTAssertTrue(composed.contains("first") && composed.contains("second"))
    }

    /// All subtasks empty → empty string, which the caller maps to a nil
    /// finalAgentThought so the deterministic fallback owns the response.
    func testComposeSubtaskResults_NoResults_ReturnsEmpty() {
        let subtasks = [SubTask(id: "s1", description: "A"), SubTask(id: "s2", description: "B")]
        XCTAssertTrue(PlanningExecutorWrapper.composeSubtaskResults(subtasks: subtasks, results: [:]).isEmpty)
    }
}
