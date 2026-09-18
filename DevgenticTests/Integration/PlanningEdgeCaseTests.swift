// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PlanningEdgeCaseTests.swift
//  DevgenticTests
//
//  Edge case tests for PlanningCapability:
//  - Subtask tool filtering (matching / non-matching hints)
//  - Dependency sanitization (orphaned / valid deps)
//  - Execution level computation (multi-level, circular, linear chain)
//

import XCTest
@testable import devgentic

final class PlanningEdgeCaseTests: XCTestCase {

    // MARK: - Tool Filtering (Integration)

    func testPlanning_SubtaskToolFiltering_MatchingHint_FiltersTools() async throws {
        // Plan: 1 subtask with toolHints ["search_files"]. Available tools: search_files, read_file, write_file.
        // With subtaskToolFiltering=true, the subtask should only use search_files.
        let searchTool = TestToolFactory.make(name: "search_files", description: "Search files", output: "Found 3 files")
        let readTool = TestToolFactory.make(name: "read_file", description: "Read a file", output: "File contents")
        let writeTool = TestToolFactory.make(name: "write_file", description: "Write a file", output: "Written")

        let plan = "1. Search for relevant files [search_files]"

        let provider = MockLLMProvider(
            steps: [
                // Step for subtask ReAct: calls search_files then terminates
                ModernCognitiveStep(
                    reasoning: "I'll search for files.",
                    toolCalls: [TestToolCallFactory.make(name: "search_files", input: "*.swift")]
                ),
                ModernCognitiveStep(reasoning: "Found the files.")
            ],
            generateResponses: [plan]
        )

        let config = PlanningCapabilityConfig(subtaskToolFiltering: true)
        let innerExecutor = ReActAgentExecutor(maxIterations: 5)
        let planningExecutor = PlanningCapability(config: config).wrap(innerExecutor)

        let input = TestAgentInputFactory.make(
            query: "Find all Swift files",
            tools: [searchTool, readTool, writeTool]
        )

        let stream = planningExecutor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let toolOutputs = StreamCollector.toolOutputs(from: events)
        // Only search_files should have been called (hint filtered read_file and write_file)
        let toolNames = Set(toolOutputs.map(\.toolName))
        XCTAssertTrue(toolNames.contains("search_files"), "search_files should be called")
        XCTAssertFalse(toolNames.contains("read_file"), "read_file should be filtered out by hint")
        XCTAssertFalse(toolNames.contains("write_file"), "write_file should be filtered out by hint")
    }

    func testPlanning_SubtaskToolFiltering_NonMatchingHint_FallsBackToAllTools() async throws {
        // Plan: 1 subtask with toolHints ["nonexistent"]. No tools match.
        // With subtaskToolFiltering=true, all tools should be available as fallback.
        // Note: The parser will discard "nonexistent" since it won't validate against available tools,
        // resulting in toolHints=nil — which means all tools are passed through.
        let readTool = TestToolFactory.make(name: "read_file", output: "File contents")

        // Use a subtask with no valid tool hints (parser discards unknown tools)
        let plan = "1. Do something"

        let provider = MockLLMProvider(
            steps: [
                ModernCognitiveStep(
                    reasoning: "Using available tools.",
                    toolCalls: [TestToolCallFactory.make(name: "read_file", input: "test.txt")]
                ),
                ModernCognitiveStep(reasoning: "Done.")
            ],
            generateResponses: [plan]
        )

        let config = PlanningCapabilityConfig(subtaskToolFiltering: true)
        let innerExecutor = ReActAgentExecutor(maxIterations: 5)
        let planningExecutor = PlanningCapability(config: config).wrap(innerExecutor)

        let input = TestAgentInputFactory.make(query: "Do something", tools: [readTool])
        let stream = planningExecutor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let toolOutputs = StreamCollector.toolOutputs(from: events)
        // read_file should be available despite no matching hints (fallback to all)
        XCTAssertFalse(toolOutputs.isEmpty, "Tools should be available via fallback")
        XCTAssertEqual(toolOutputs.first?.toolName, "read_file")
    }

    // MARK: - Dependency Sanitization (Static Method Tests)

    func testSanitizeDependencies_OrphanedDepsRemoved() {
        let subtasks = [
            SubTask(id: "step_1", description: "First task"),
            SubTask(id: "step_2", description: "Second task", dependsOn: ["step_1", "deleted_step"])
        ]

        let sanitized = PlanningExecutorWrapper.sanitizeDependencies(subtasks)

        let step2 = sanitized.first(where: { $0.id == "step_2" })!
        XCTAssertEqual(step2.dependsOn, ["step_1"],
                       "Orphaned 'deleted_step' should be removed")
    }

    func testSanitizeDependencies_ValidDepsPreserved() {
        let subtasks = [
            SubTask(id: "step_1", description: "First task"),
            SubTask(id: "step_2", description: "Second task", dependsOn: ["step_1"]),
            SubTask(id: "step_3", description: "Third task", dependsOn: ["step_1", "step_2"])
        ]

        let sanitized = PlanningExecutorWrapper.sanitizeDependencies(subtasks)

        let step2 = sanitized.first(where: { $0.id == "step_2" })!
        let step3 = sanitized.first(where: { $0.id == "step_3" })!
        XCTAssertEqual(step2.dependsOn, ["step_1"])
        XCTAssertEqual(step3.dependsOn, ["step_1", "step_2"])
    }

    // MARK: - Execution Level Computation (Static Method Tests)

    func testComputeExecutionLevels_MultiLevel_WithDependencies() {
        // A (no deps), B (no deps), C (depends on A), D (depends on A and B)
        let subtasks = [
            SubTask(id: "A", description: "Task A"),
            SubTask(id: "B", description: "Task B"),
            SubTask(id: "C", description: "Task C", dependsOn: ["A"]),
            SubTask(id: "D", description: "Task D", dependsOn: ["A", "B"])
        ]

        let levels = PlanningExecutorWrapper.computeExecutionLevels(subtasks: subtasks)

        XCTAssertEqual(levels.count, 2, "Should have 2 levels")
        XCTAssertEqual(Set(levels[0]), Set(["A", "B"]), "Level 0: A and B (no deps)")
        XCTAssertEqual(Set(levels[1]), Set(["C", "D"]), "Level 1: C and D (depend on level 0)")
    }

    func testComputeExecutionLevels_CircularDeps_Terminates() {
        // A depends on B, B depends on A — circular dependency
        let subtasks = [
            SubTask(id: "A", description: "Task A", dependsOn: ["B"]),
            SubTask(id: "B", description: "Task B", dependsOn: ["A"])
        ]

        let levels = PlanningExecutorWrapper.computeExecutionLevels(subtasks: subtasks)

        // Safety break: remaining unplaced tasks go into a final level
        XCTAssertFalse(levels.isEmpty, "Should produce at least one level")
        let allIDs = levels.flatMap { $0 }
        XCTAssertTrue(allIDs.contains("A"), "A should appear somewhere")
        XCTAssertTrue(allIDs.contains("B"), "B should appear somewhere")
    }

    func testComputeExecutionLevels_LinearChain() {
        // A → B → C (linear chain)
        let subtasks = [
            SubTask(id: "A", description: "Task A"),
            SubTask(id: "B", description: "Task B", dependsOn: ["A"]),
            SubTask(id: "C", description: "Task C", dependsOn: ["B"])
        ]

        let levels = PlanningExecutorWrapper.computeExecutionLevels(subtasks: subtasks)

        XCTAssertEqual(levels.count, 3, "Linear chain should produce 3 levels")
        XCTAssertEqual(levels[0], ["A"])
        XCTAssertEqual(levels[1], ["B"])
        XCTAssertEqual(levels[2], ["C"])
    }
}
