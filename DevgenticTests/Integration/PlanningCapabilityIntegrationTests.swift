//
//  PlanningCapabilityIntegrationTests.swift
//  DevgenticTests
//
//  End-to-end integration tests for PlanningCapability with cross-subtask
//  memory seeding (P4). Verifies that dependency results from completed subtasks
//  flow into dependent subtasks' working memory via the real execution pipeline.
//
//  Mock: LLMProvider (scripted plan + scripted ReAct steps)
//  Real: PlanningCapability → ReActAgentExecutor → ToolExecutionLoop → WindowedLinearMemory
//
//  Note: PlanningCapability does NOT forward .toolOutput events from subtask streams.
//  It accumulates .content and forwards .thought events prefixed with [subtask_id].
//  Assertions check thoughts and final content, not tool outputs.
//

import XCTest
@testable import devgentic

@MainActor
final class PlanningCapabilityIntegrationTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a numbered-list plan string for MockLLMProvider.generate().
    private func makeNumberedPlan(_ steps: [(description: String, tools: [String]?)]) -> String {
        steps.enumerated().map { index, step in
            var line = "\(index + 1). \(step.description)"
            if let tools = step.tools, !tools.isEmpty {
                line += " [\(tools.joined(separator: ", "))]"
            }
            return line
        }.joined(separator: "\n")
    }

    private func makePlanningExecutor(config: PlanningCapabilityConfig? = nil) -> any Executor {
        let innerExecutor = ReActAgentExecutor(maxIterations: 5)
        let planConfig = config ?? PlanningCapabilityConfig(
            maxSubtasks: 5,
            parallelSubtasks: false,
            subtaskToolFiltering: false,
            requiresPlanApproval: false
        )
        return PlanningCapability(config: planConfig).wrap(innerExecutor)
    }

    // MARK: - Diagnostic: Numbered List Parsing

    func testDiagnostic_NumberedListParses() {
        let plan = makeNumberedPlan([
            (description: "Find the config file", tools: ["search"]),
            (description: "Read the config file", tools: ["read"])
        ])

        let strategy = PlanGeneratorStrategy()
        let parsed = strategy.parsePlan(from: plan, availableToolNames: ["search", "read"])
        XCTAssertEqual(parsed.count, 2, "Should parse 2 subtasks")
        XCTAssertEqual(parsed[0].id, "step_1")
        XCTAssertEqual(parsed[0].description, "Find the config file")
        XCTAssertEqual(parsed[0].toolHints, ["search"])
        XCTAssertEqual(parsed[1].id, "step_2")
        XCTAssertEqual(parsed[1].description, "Read the config file")
        XCTAssertEqual(parsed[1].toolHints, ["read"])
    }

    // MARK: - #16: plan prompt carries instructions + history

    /// Minimal SemanticContext for exercising PlanGeneratorStrategy.generatePlan directly.
    private func makePlanContext(instructions: String?, recentHistory: String?, query: String) -> SemanticContext {
        SemanticContext(
            instructions: instructions,
            environmentFacts: EnvironmentFacts(osVersion: "macOS", shellType: "zsh", userName: "t", currentDate: "2026-06-20"),
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            recentHistory: recentHistory,
            nativeHistoryTurns: nil,
            originalQuery: query,
            currentIteration: 0,
            compiledScratchpad: "",
            latestClarification: nil,
            negativeConstraints: [],
            hallucinatedTools: [],
            availableTools: [],
            userProfile: nil,
            skillManifests: nil,
            taskDescription: nil,
            promptLayerConfig: .agent,
            workflowContext: nil
        )
    }

    func testPlanPrompt_IncludesInstructionsAndHistory() async throws {
        // #16: the plan-generation prompt must carry the agent's instructions + recent history so
        // the planner has the same context the executor will (e.g. to resolve "the other folder").
        let provider = MockLLMProvider(generateResponses: ["1. First step\n2. Second step"])
        let strategy = PlanGeneratorStrategy()
        let context = makePlanContext(
            instructions: "PLAN_SENTINEL_INSTRUCTIONS",
            recentHistory: "PLAN_SENTINEL_HISTORY",
            query: "Now do the same for the other folder"
        )

        _ = try await strategy.generatePlan(model: provider, context: context)

        let prompt = provider.receivedGenerateMessages.first?.first?["content"] ?? ""
        XCTAssertTrue(prompt.contains("PLAN_SENTINEL_INSTRUCTIONS"), "Plan prompt should include the agent's instructions")
        XCTAssertTrue(prompt.contains("PLAN_SENTINEL_HISTORY"), "Plan prompt should include the recent conversation history")
        XCTAssertTrue(prompt.contains("Now do the same for the other folder"), "Plan prompt should still include the task")
    }

    func testPlanPrompt_OmitsContextSectionsWhenAbsent() async throws {
        // Control: no instructions/history → no section tags (context-free prompt unchanged).
        let provider = MockLLMProvider(generateResponses: ["1. Step"])
        let strategy = PlanGeneratorStrategy()
        let context = makePlanContext(instructions: nil, recentHistory: "   ", query: "Do a thing")

        _ = try await strategy.generatePlan(model: provider, context: context)

        let prompt = provider.receivedGenerateMessages.first?.first?["content"] ?? ""
        XCTAssertFalse(prompt.contains("<instructions>"), "No instructions → no instructions section")
        XCTAssertFalse(prompt.contains("<conversation_history>"), "Blank history → no history section")
        XCTAssertTrue(prompt.contains("Do a thing"))
    }

    // MARK: - Basic Planning Execution

    func testPlanning_TwoSequentialSubtasks_BothExecute() async throws {
        let plan = makeNumberedPlan([
            (description: "Find the config file", tools: nil),
            (description: "Read the config file", tools: nil)
        ])

        let searchTool = TestToolFactory.make(name: "search", output: "Found: /etc/config.yaml")
        let readTool = TestToolFactory.make(name: "read_file", output: "port=5432\nhost=localhost")

        let provider = MockLLMProvider(
            steps: [
                // Subtask 1 ReAct loop
                ModernCognitiveStep(
                    reasoning: "Searching for config file.",
                    toolCalls: [TestToolCallFactory.make(name: "search", input: "config")]
                ),
                ModernCognitiveStep(reasoning: "Found the file at /etc/config.yaml."),
                // Subtask 2 ReAct loop
                ModernCognitiveStep(
                    reasoning: "Reading the config file.",
                    toolCalls: [TestToolCallFactory.make(name: "read_file", input: "/etc/config.yaml")]
                ),
                ModernCognitiveStep(reasoning: "Config contains port=5432, host=localhost.")
            ],
            generateResponses: [plan]
        )

        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(
            query: "Find and read the config file",
            tools: [searchTool, readTool]
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // PlanningCapability forwards thoughts prefixed with [subtask_id]
        let thoughts = StreamCollector.thoughts(from: events)

        // Both subtasks should have produced thoughts
        let step1Thoughts = thoughts.filter { $0.contains("[step_1]") }
        let step2Thoughts = thoughts.filter { $0.contains("[step_2]") }
        XCTAssertFalse(step1Thoughts.isEmpty, "Subtask 1 should produce thoughts")
        XCTAssertFalse(step2Thoughts.isEmpty, "Subtask 2 should produce thoughts")

        // Should produce final content
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce synthesized response")
    }

    // MARK: - Cross-Subtask Memory Seeding (P4)

    func testPlanning_DependentSubtask_ReceivesPriorResult() async throws {
        // Key P4 test: step_1 produces a distinctive result → step_2
        // should have context from step_1 via sequential execution seeding.
        let plan = makeNumberedPlan([
            (description: "Find the database config", tools: nil),
            (description: "Update the port to 5433", tools: nil)
        ])

        let findTool = TestToolFactory.make(name: "find_file", output: "Located: /var/db/postgres.conf")
        let editTool = TestToolFactory.make(name: "edit_file", output: "File updated successfully.")

        let provider = MockLLMProvider(
            steps: [
                // Subtask 1: find_file → done
                ModernCognitiveStep(
                    reasoning: "Finding the database config.",
                    toolCalls: [TestToolCallFactory.make(name: "find_file", input: "postgres")]
                ),
                ModernCognitiveStep(reasoning: "Found at /var/db/postgres.conf."),
                // Subtask 2: edit_file → done
                ModernCognitiveStep(
                    reasoning: "Updating the port.",
                    toolCalls: [TestToolCallFactory.make(name: "edit_file", input: "port=5433")]
                ),
                ModernCognitiveStep(reasoning: "Port updated to 5433.")
            ],
            generateResponses: [plan]
        )

        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(
            query: "Find the database config and update the port to 5433",
            tools: [findTool, editTool]
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Both subtasks should execute
        let thoughts = StreamCollector.thoughts(from: events)
        let step1Ran = thoughts.contains { $0.contains("[step_1]") }
        let step2Ran = thoughts.contains { $0.contains("[step_2]") }
        XCTAssertTrue(step1Ran, "Subtask 1 should execute")
        XCTAssertTrue(step2Ran, "Subtask 2 should execute")

        // Final content should be produced
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce synthesized response")
    }

    // MARK: - Independent Subtasks (No Dependencies)

    func testPlanning_IndependentSubtasks_NoSeeding() async throws {
        let plan = makeNumberedPlan([
            (description: "Check disk space", tools: nil),
            (description: "Check memory usage", tools: nil)
        ])

        let diskTool = TestToolFactory.make(name: "check_disk", output: "80% used")
        let memTool = TestToolFactory.make(name: "check_memory", output: "4GB free")

        let provider = MockLLMProvider(
            steps: [
                // Subtask 1
                ModernCognitiveStep(reasoning: "Checking disk.", toolCalls: [TestToolCallFactory.make(name: "check_disk")]),
                ModernCognitiveStep(reasoning: "Disk is 80% full."),
                // Subtask 2
                ModernCognitiveStep(reasoning: "Checking memory.", toolCalls: [TestToolCallFactory.make(name: "check_memory")]),
                ModernCognitiveStep(reasoning: "4GB free.")
            ],
            generateResponses: [plan]
        )

        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(
            query: "Check system health",
            tools: [diskTool, memTool]
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Both should execute
        let thoughts = StreamCollector.thoughts(from: events)
        let step1Ran = thoughts.contains { $0.contains("[step_1]") }
        let step2Ran = thoughts.contains { $0.contains("[step_2]") }
        XCTAssertTrue(step1Ran, "Subtask 1 should execute")
        XCTAssertTrue(step2Ran, "Subtask 2 should execute")

        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce synthesized response")
    }

    // MARK: - Plan Generation Failure Fallback

    func testPlanning_PlanGenerationFails_FallsBackToSingleTask() async throws {
        let tool = TestToolFactory.make(name: "search", output: "Found it")

        let provider = MockLLMProvider(
            steps: [
                ModernCognitiveStep(reasoning: "Searching.", toolCalls: [TestToolCallFactory.make(name: "search")]),
                ModernCognitiveStep(reasoning: "Done.")
            ],
            generateResponses: ["this is not a valid numbered list or anything useful"]
        )

        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(query: "Find something", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce content even when plan generation fails")
    }

    // MARK: - Plan Generation Cancellation (chip task_61dd9583)

    func testPlanning_CancelDuringPlanGen_PropagatesNotSwallowed() async throws {
        // chip task_61dd9583 (#18-B class): a Stop during plan generation must PROPAGATE — the
        // plan-gen catch must not fold CancellationError into a single-task fallback and keep
        // running. The run should end cancelled and never execute any subtask.
        let tool = TestToolFactory.make(name: "search", output: "Found it")
        let provider = PlanGenCancellingMock()

        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(query: "Find something", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        XCTAssertEqual(provider.cognitiveCallCount, 0,
                       "Plan-gen cancel must not proceed to subtask execution")
        let cancelled = events.contains { if case .executionFinished(.cancelled, _) = $0 { return true }; return false }
        XCTAssertTrue(cancelled, "Cancel during plan generation must end the run cancelled, not continue")
    }
}

/// Throws `CancellationError` on the plan-generation `generate` call (simulating Stop during
/// plan gen), and counts cognitive-step calls to prove no subtask ran. (chip task_61dd9583)
private final class PlanGenCancellingMock: LLMProvider, @unchecked Sendable {
    let modelName = "plangen-cancel-mock"
    private(set) var cognitiveCallCount = 0

    func generateCognitiveStep(messages: [[String: String]], tools: [[String: Any]]?) async throws -> ModernCognitiveStep {
        cognitiveCallCount += 1
        return ModernCognitiveStep(reasoning: "No more scripted steps.")
    }

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        throw CancellationError()
    }

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
