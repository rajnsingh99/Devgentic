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
}
