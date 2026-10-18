// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PlanningCapabilityIntegrationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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

    // MARK: - Structured-event helpers
    // Subtask boundaries are STRUCTURED events now (the plan card consumes them);
    // the "[step_N]" thought prefixes were removed with the attribution refactor.

    private func startedSubtaskIDs(_ events: [AgentStreamEvent]) -> [String] {
        events.compactMap { if case .subtaskStarted(let id, _, _, _) = $0 { return id }; return nil }
    }

    private func completedSubtaskIDs(_ events: [AgentStreamEvent]) -> [String] {
        events.compactMap { if case .subtaskCompleted(let id, _, _, _, _, _) = $0 { return id }; return nil }
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
            environmentFacts: EnvironmentFacts(osVersion: "macOS", shellType: "zsh", userName: "t", homeDirectory: "/Users/t", currentDate: "2026-06-20"),
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

    func testPlanPrompt_IncludesEnvironment() async throws {
        // The planner must see the environment (home dir + absolute-path guidance) so
        // its steps anchor a consistent base directory — the execution stage already
        // gets this; previously the planner did not, causing cross-subtask location drift.
        let provider = MockLLMProvider(generateResponses: ["1. Step"])
        let strategy = PlanGeneratorStrategy()
        let context = makePlanContext(instructions: nil, recentHistory: nil, query: "Make a folder")

        _ = try await strategy.generatePlan(model: provider, context: context)

        let prompt = provider.receivedGenerateMessages.first?.first?["content"] ?? ""
        XCTAssertTrue(prompt.contains("<environment>"), "Plan prompt should carry the environment block")
        XCTAssertTrue(prompt.contains("/Users/t"), "Plan prompt should include the home directory from env facts")
        XCTAssertTrue(prompt.contains("absolute paths"), "Plan prompt should carry the absolute-path guidance")
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

        // Both subtasks should run to completion (structured boundary events)
        XCTAssertEqual(startedSubtaskIDs(events), ["step_1", "step_2"], "Both subtasks should start in order")
        XCTAssertEqual(completedSubtaskIDs(events), ["step_1", "step_2"], "Both subtasks should complete in order")

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
        let started = startedSubtaskIDs(events)
        XCTAssertTrue(started.contains("step_1"), "Subtask 1 should execute")
        XCTAssertTrue(started.contains("step_2"), "Subtask 2 should execute")

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
        let started = startedSubtaskIDs(events)
        XCTAssertTrue(started.contains("step_1"), "Subtask 1 should execute")
        XCTAssertTrue(started.contains("step_2"), "Subtask 2 should execute")

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

    // MARK: - Forced-Termination Subtask Demotes Plan Outcome (manual Run-1 defect)

    func testPlanning_ForcedTerminationSubtask_DemotesPlanToCompletedWithWarnings() async throws {
        // A circuit-breaker abort inside a subtask doesn't throw — the inner run
        // synthesizes a best-effort answer and finishes `.completedWithWarnings`.
        // The plan level must not report a clean `.completed` with a nil reason
        // (observed live: a 5×-identical-call abort printed "Outcome: SUCCESS ✅").
        let plan = makeNumberedPlan([(description: "Search for the marker", tools: nil)])
        let repeated = ModernCognitiveStep(
            reasoning: "Searching again.",
            toolCalls: [TestToolCallFactory.make(name: "search", input: "same-args")]
        )
        let provider = MockLLMProvider(
            steps: Array(repeating: repeated, count: 6),
            generateResponses: [plan]
        )
        let tool = TestToolFactory.make(name: "search", output: "Same result every time")

        // Iteration ceiling above the breaker's threshold so the abort path —
        // not max-iterations — terminates the subtask.
        let executor = PlanningCapability(config: PlanningCapabilityConfig(
            maxSubtasks: 3,
            parallelSubtasks: false,
            subtaskToolFiltering: false,
            requiresPlanApproval: false
        )).wrap(ReActAgentExecutor(maxIterations: 10))
        let input = TestAgentInputFactory.make(query: "Loop forever", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let terminal: (outcome: ExecutionOutcome, reason: String?)? = events.compactMap { event -> (ExecutionOutcome, String?)? in
            if case .executionFinished(let outcome, let reason) = event { return (outcome, reason) }
            return nil
        }.last
        XCTAssertEqual(terminal?.outcome, .completedWithWarnings,
                       "A forced-termination subtask must demote the plan-level outcome")
        XCTAssertTrue(terminal?.reason?.contains("step_1") == true,
                      "Terminal reason should identify the degraded subtask — got: \(terminal?.reason ?? "nil")")
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

    // MARK: - Pre-Plan Clarification (CLARIFY contract)

    func testDiagnostic_ClarifyLineParses() {
        // Whole-response CLARIFY → question extracted (case-insensitive).
        XCTAssertEqual(
            PlanGeneratorStrategy.extractClarificationQuestion(from: "CLARIFY: Which folder should I use?"),
            "Which folder should I use?"
        )
        XCTAssertEqual(
            PlanGeneratorStrategy.extractClarificationQuestion(from: "clarify: What size limit applies?"),
            "What size limit applies?"
        )
        // A numbered plan → nil (plan wins).
        XCTAssertNil(PlanGeneratorStrategy.extractClarificationQuestion(from: "1. Do the thing\n2. Verify it"))
        // Mixed CLARIFY + numbered list → nil (the model planned anyway).
        XCTAssertNil(PlanGeneratorStrategy.extractClarificationQuestion(from: "CLARIFY: Really?\n1. Do it regardless"))
        // Plain prose without the contract line → nil.
        XCTAssertNil(PlanGeneratorStrategy.extractClarificationQuestion(from: "The task is a bit unclear to me."))
    }

    /// Consumes the stream, answering the FIRST pre-plan clarification with `answer`
    /// (nil = skip) after the same 50ms settle delay the resume tests use.
    private func collectAnsweringClarification(
        _ stream: AsyncThrowingStream<AgentStreamEvent, Error>,
        answer: String?
    ) async throws -> (events: [AgentStreamEvent], clarificationCount: Int) {
        var events: [AgentStreamEvent] = []
        var count = 0
        for try await event in stream {
            events.append(event)
            if case .requestClarification(_, let opID, _, _, _, _) = event {
                count += 1
                try await Task.sleep(for: .milliseconds(50))
                await ExecutionSuspensionService.shared.resumeClarification(for: opID, userInput: answer, resolvedBy: .localUI)
            }
        }
        return (events, count)
    }

    func testPlanning_VagueTask_ClarifiesThenPlans_AndReplaysInsideSubtask() async throws {
        // Round 1 → CLARIFY question; user answers; round 2 → 1-step plan. The subtask
        // then asks the IDENTICAL question via ask_user — it must be REPLAYED from the
        // shared RunInteractionMemory (no second banner), proving the pre-plan Q&A was
        // recorded and threaded into subtask execution.
        let question = "Which folder should I create the file in?"
        let tool = TestToolFactory.make(name: "write_file", output: "File written.")

        let provider = MockLLMProvider(
            steps: [
                // Subtask 1, iter 1: re-ask the planner's exact question.
                ModernCognitiveStep(
                    reasoning: "I need the target folder.",
                    toolCalls: [PendingToolCall(
                        id: UUID().uuidString,
                        name: "ask_user",
                        arguments: ["question": .string(question)]
                    )]
                ),
                // iter 2: act on the (replayed) answer, iter 3: terminate.
                ModernCognitiveStep(
                    reasoning: "Writing the file.",
                    toolCalls: [TestToolCallFactory.make(name: "write_file", input: "/tmp/target/x.txt")]
                ),
                ModernCognitiveStep(reasoning: "File created as requested.")
            ],
            generateResponses: [
                "CLARIFY: \(question)",
                "1. Create the file in the folder the user specified"
            ]
        )

        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(query: "Make the file", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let (events, clarificationCount) = try await collectAnsweringClarification(stream, answer: "Use /tmp/target")

        XCTAssertEqual(clarificationCount, 1,
                       "One pre-plan question; the subtask's identical ask_user must replay, not re-raise")

        // Round-2 plan prompt carries the Q&A and forbids a second question.
        XCTAssertEqual(provider.receivedGenerateMessages.count, 2, "Two plan-gen calls (clarify round + re-plan)")
        let secondPrompt = provider.receivedGenerateMessages[1].compactMap { $0["content"] }.joined(separator: " ")
        XCTAssertTrue(secondPrompt.contains(question), "Re-plan prompt should carry the question")
        XCTAssertTrue(secondPrompt.contains("Use /tmp/target"), "Re-plan prompt should carry the answer")
        XCTAssertTrue(secondPrompt.contains("Do not ask for clarification"), "Re-plan must forbid a second question")

        // The subtask ran and its ask_user resolved from replay with the user's answer.
        XCTAssertEqual(startedSubtaskIDs(events), ["step_1"])
        let askOutputs = events.compactMap { event -> String? in
            if case .toolSucceeded(let output, _, _) = event, output.toolName == "ask_user" { return output.output }
            return nil
        }
        XCTAssertTrue(askOutputs.contains { $0.contains("Use /tmp/target") },
                      "ask_user must resolve from the replayed pre-plan answer; outputs: \(askOutputs)")

        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Run should complete with synthesized content")
    }

    func testPlanning_ClarificationSkipped_PlansWithAssumptions() async throws {
        // The user skips the pre-plan question → round 2 still plans (with the
        // no-questions instruction) and the run completes.
        let tool = TestToolFactory.make(name: "search", output: "Found it.")
        let provider = MockLLMProvider(
            steps: [
                ModernCognitiveStep(
                    reasoning: "Searching.",
                    toolCalls: [TestToolCallFactory.make(name: "search", input: "anything")]
                ),
                ModernCognitiveStep(reasoning: "Done searching.")
            ],
            generateResponses: [
                "CLARIFY: Which corpus should I search?",
                "1. Search the default corpus"
            ]
        )

        let executor = makePlanningExecutor()
        let input = TestAgentInputFactory.make(query: "Search it", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let (events, clarificationCount) = try await collectAnsweringClarification(stream, answer: nil)

        XCTAssertEqual(clarificationCount, 1)
        XCTAssertEqual(provider.receivedGenerateMessages.count, 2, "Skip still re-plans (round 2)")
        XCTAssertEqual(startedSubtaskIDs(events), ["step_1"], "Skip must not stall the run")
        let skippedThought = StreamCollector.thoughts(from: events).contains { $0.contains("Clarification skipped") }
        XCTAssertTrue(skippedThought, "Timeline should record that planning proceeded on assumptions")
    }

    func testPlanning_ClarifyDisabled_FallsBackInsteadOfAsking() async throws {
        // Feature off → the CLARIFY offer never enters the prompt, and a stray CLARIFY
        // response is NOT honored: no numbered lines parse → single-task fallback,
        // zero clarification banners.
        let tool = TestToolFactory.make(name: "search", output: "Found it.")
        let provider = MockLLMProvider(
            steps: [
                ModernCognitiveStep(
                    reasoning: "Searching.",
                    toolCalls: [TestToolCallFactory.make(name: "search", input: "anything")]
                ),
                ModernCognitiveStep(reasoning: "Done.")
            ],
            generateResponses: ["CLARIFY: Which corpus?"]
        )

        let executor = makePlanningExecutor(config: PlanningCapabilityConfig(
            maxSubtasks: 5,
            parallelSubtasks: false,
            subtaskToolFiltering: false,
            requiresPlanApproval: false,
            clarifyBeforePlanning: false
        ))
        let input = TestAgentInputFactory.make(query: "Search it", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let clarifications = events.filter { if case .requestClarification = $0 { return true }; return false }
        XCTAssertTrue(clarifications.isEmpty, "Disabled feature must never raise a pre-plan question")
        XCTAssertEqual(provider.receivedGenerateMessages.count, 1, "No re-plan round when disabled")
        let firstPrompt = provider.receivedGenerateMessages[0].compactMap { $0["content"] }.joined(separator: " ")
        XCTAssertFalse(firstPrompt.contains("CLARIFY:"), "Prompt must not offer the CLARIFY contract when disabled")
        // The un-honored CLARIFY response degrades to the single-task fallback.
        XCTAssertEqual(startedSubtaskIDs(events), ["step_1"])
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
