// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReActExecutorIntegrationTests.swift
//  DevgenticTests
//
//  End-to-end integration tests for the ReAct execution pipeline.
//  Uses MockLLMProvider with scripted ModernCognitiveStep responses.
//  Everything downstream of the LLM — tool execution, working memory,
//  eviction, circuit breaker, response synthesis — runs with real implementations.
//

import XCTest
@testable import devgentic

final class ReActExecutorIntegrationTests: XCTestCase {

    // MARK: - Basic Execution

    func testReAct_NoToolCalls_TerminatesImmediately() async throws {
        // LLM returns reasoning but no tool calls → loop terminates on first iteration.
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(reasoning: "I can answer this directly without tools.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "What is 2+2?")

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce a content response")

        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertTrue(toolOutputs.isEmpty, "No tool outputs when LLM doesn't call tools")
    }

    func testReAct_SingleToolCall_ProducesToolAndContentEvents() async throws {
        // Iteration 1: LLM calls read_file → Iteration 2: LLM produces final answer.
        let tool = TestToolFactory.make(name: "read_file", output: "File contents: Hello World")

        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "I need to read the file.",
                toolCalls: [TestToolCallFactory.make(name: "read_file", input: "test.txt")]
            ),
            ModernCognitiveStep(reasoning: "The file contains Hello World.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "Read test.txt", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should have tool output event
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.count, 1, "Should have exactly 1 tool output")
        XCTAssertEqual(toolOutputs[0].toolName, "read_file")
        XCTAssertTrue(toolOutputs[0].isSuccess)

        // Should have content event
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce final content")
    }

    func testReAct_MultipleIterations_MemoryAccumulates() async throws {
        // 3 iterations with tool calls → memory should accumulate observations.
        let tool = TestToolFactory.make(name: "search", output: "Found 5 results")

        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Searching step 1.",
                toolCalls: [TestToolCallFactory.make(name: "search", input: "query1")]
            ),
            ModernCognitiveStep(
                reasoning: "Searching step 2.",
                toolCalls: [TestToolCallFactory.make(name: "search", input: "query2")]
            ),
            ModernCognitiveStep(
                reasoning: "Searching step 3.",
                toolCalls: [TestToolCallFactory.make(name: "search", input: "query3")]
            ),
            ModernCognitiveStep(reasoning: "Done searching. Here are the results.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 10)
        let input = TestAgentInputFactory.make(query: "Search for data", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.count, 3, "Should have 3 tool outputs from 3 iterations")

        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce final content after all iterations")
    }

    // MARK: - Working Memory Integration

    func testReAct_TinyBudget_MemoryPressureWarning() async throws {
        // Tiny memory budget + multiple tool calls with large outputs → memory pressure warning should fire.
        // Each tool output is ~500 chars, budget is 200 chars → utilization estimate exceeds 75% by iteration 2.
        let tool = TestToolFactory.make(name: "fetch", output: String(repeating: "data ", count: 100))

        var steps: [ModernCognitiveStep] = []
        for _ in 1...6 {
            steps.append(ModernCognitiveStep(
                reasoning: "Fetching more data.",
                toolCalls: [TestToolCallFactory.make(name: "fetch")]
            ))
        }
        steps.append(ModernCognitiveStep(reasoning: "Done."))

        let provider = MockLLMProvider(steps: steps)
        let executor = ReActAgentExecutor(maxIterations: 10)

        // Extremely tiny budget: 200 chars total, perEntryCap also tiny → guaranteed overflow
        let tinyMemory = WindowedLinearMemory(
            config: MemoryBudgetConfig(totalBudgetChars: 200, perEntryCap: 80, fullFidelityWindow: 1, maxSystemAlerts: 3)
        )
        let input = TestAgentInputFactory.make(query: "Fetch all data", tools: [tool], workingMemory: tinyMemory)

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // This run uses MockCognitiveGenerator → the LEGACY <working_memory> path
        // (nativeGenerator == nil), so the scratchpad budgetUtilization > 0.75 drives the
        // pressure signal. The executor emits it as a `.warning(.memoryPressure, …)`, NOT a
        // `.thought` — assert on the warning channel (#22 / chip task_64f22dd2).
        let hasMemoryWarning = StreamCollector.hasWarningContaining("Memory pressure", in: events)
        XCTAssertTrue(hasMemoryWarning, "Should emit memory pressure warning with tiny budget")
    }

    // MARK: - Error Scenarios

    func testReAct_HallucinatedTool_HandledGracefully() async throws {
        // LLM calls a tool that doesn't exist → should get hallucination error, not crash.
        let realTool = TestToolFactory.make(name: "real_tool", output: "OK")

        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "I'll use the imaginary tool.",
                toolCalls: [TestToolCallFactory.make(name: "nonexistent_tool")]
            ),
            ModernCognitiveStep(reasoning: "That didn't work. Let me answer directly.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "Do something", tools: [realTool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should have a tool output with the hallucination error
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.count, 1)
        XCTAssertFalse(toolOutputs[0].isSuccess, "Hallucinated tool should fail")
        XCTAssertTrue(toolOutputs[0].output.contains("not found") || toolOutputs[0].output.contains("does not exist"),
                      "Error should mention tool not found")

        // Should still produce final content (graceful recovery)
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should recover and produce content after hallucination")
    }

    func testReAct_ToolFailure_RecordedAsFailedOutput() async throws {
        // Tool throws an error → should be recorded as failed in the stream.
        let failingTool = TestToolFactory.makeFailing(name: "dangerous_tool", error: "Permission denied")

        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Running the dangerous tool.",
                toolCalls: [TestToolCallFactory.make(name: "dangerous_tool")]
            ),
            ModernCognitiveStep(reasoning: "Tool failed. I'll answer without it.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "Run dangerous operation", tools: [failingTool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.count, 1)
        XCTAssertFalse(toolOutputs[0].isSuccess, "Failed tool should be marked as not successful")
    }

    // MARK: - Termination

    func testReAct_MaxIterations_Terminates() async throws {
        // Script infinite tool calls — executor should stop at maxIterations.
        let tool = TestToolFactory.make(name: "loop_tool", output: "Still going...")

        // Create more steps than maxIterations
        var steps: [ModernCognitiveStep] = []
        for _ in 1...20 {
            steps.append(ModernCognitiveStep(
                reasoning: "Keep going.",
                toolCalls: [TestToolCallFactory.make(name: "loop_tool")]
            ))
        }

        let provider = MockLLMProvider(steps: steps)
        let executor = ReActAgentExecutor(maxIterations: 3)
        let input = TestAgentInputFactory.make(query: "Loop forever", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Should have at most 3 tool outputs (maxIterations = 3)
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertLessThanOrEqual(toolOutputs.count, 3, "Should stop at maxIterations")

        // Should still produce some content (best-effort synthesis)
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce content even when max iterations reached")
    }

    func testReAct_EmptyToolCalls_TerminatesLoop() async throws {
        // Step 1: tool call. Step 2: empty tool calls → loop should end.
        let tool = TestToolFactory.make(name: "check", output: "All good")

        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Checking...",
                toolCalls: [TestToolCallFactory.make(name: "check")]
            ),
            ModernCognitiveStep(reasoning: "Everything looks fine.", toolCalls: [])
        ])

        let executor = ReActAgentExecutor(maxIterations: 10)
        let input = TestAgentInputFactory.make(query: "Check status", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.count, 1, "Only first iteration should produce tool output")

        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty)
    }

    // MARK: - Parallel Tool Execution

    func testReAct_ParallelToolCalls_BothExecuteInSameIteration() async throws {
        // Single cognitive step with 2 tool calls → both execute in the same iteration.
        // ToolExecutionLoop dispatches parallel calls via TaskGroup.
        let readTool = TestToolFactory.make(name: "read_file", output: "File A contents")
        let listTool = TestToolFactory.make(name: "list_directory", output: "file1.txt, file2.txt")

        let provider = MockLLMProvider(steps: [
            // Iteration 1: 2 parallel tool calls
            ModernCognitiveStep(
                reasoning: "I need to read the file and list the directory simultaneously.",
                toolCalls: [
                    TestToolCallFactory.make(name: "read_file", input: "fileA.txt"),
                    TestToolCallFactory.make(name: "list_directory", input: "/src")
                ]
            ),
            // Iteration 2: terminate with combined results
            ModernCognitiveStep(reasoning: "Got both results. File A has content and directory has 2 files.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(
            query: "Read fileA.txt and list /src",
            tools: [readTool, listTool]
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Both tools should produce outputs in the same iteration
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.count, 2, "Both parallel tool calls should produce outputs")

        let toolNames = Set(toolOutputs.map(\.toolName))
        XCTAssertTrue(toolNames.contains("read_file"), "read_file should execute")
        XCTAssertTrue(toolNames.contains("list_directory"), "list_directory should execute")

        // Both should succeed
        XCTAssertTrue(toolOutputs.allSatisfy(\.isSuccess), "Both parallel tools should succeed")

        // Only 2 cognitive step calls (1 iteration with tools + 1 terminal)
        XCTAssertEqual(provider.receivedCognitiveMessages.count, 2,
                       "Parallel tools in single step should be 1 iteration, not 2")

        // Working memory should contain both observations for the second cognitive step
        // (MockCognitiveGenerator includes scratchpad in messages)
        if provider.receivedCognitiveMessages.count >= 2 {
            let secondCallContent = provider.receivedCognitiveMessages[1]
                .compactMap { $0["content"] }
                .joined(separator: " ")

            let hasReadResult = secondCallContent.contains("File A contents") || secondCallContent.contains("read_file")
            let hasListResult = secondCallContent.contains("file1.txt") || secondCallContent.contains("list_directory")
            XCTAssertTrue(hasReadResult, "Second iteration should see read_file observation in memory")
            XCTAssertTrue(hasListResult, "Second iteration should see list_directory observation in memory")
        }

        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce final content")
    }

    func testReAct_ParallelToolCalls_MixedSuccess() async throws {
        // 1 tool succeeds, 1 fails in the same iteration.
        // Both results should be recorded. Execution should continue.
        let goodTool = TestToolFactory.make(name: "read_file", output: "File contents OK")
        let badTool = TestToolFactory.makeFailing(name: "write_file", error: "Permission denied")

        let provider = MockLLMProvider(steps: [
            // Iteration 1: 2 parallel calls (1 succeeds, 1 fails)
            ModernCognitiveStep(
                reasoning: "Reading and writing simultaneously.",
                toolCalls: [
                    TestToolCallFactory.make(name: "read_file", input: "config.txt"),
                    TestToolCallFactory.make(name: "write_file", input: "output.txt")
                ]
            ),
            // Iteration 2: agent reacts to mixed results
            ModernCognitiveStep(reasoning: "Read succeeded but write failed. Reporting results.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(
            query: "Read config and write output",
            tools: [goodTool, badTool]
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // Both tool outputs should be present
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.count, 2, "Both parallel tools should produce outputs")

        // One success, one failure
        let successes = toolOutputs.filter(\.isSuccess)
        let failures = toolOutputs.filter { !$0.isSuccess }
        XCTAssertEqual(successes.count, 1, "1 tool should succeed")
        XCTAssertEqual(failures.count, 1, "1 tool should fail")
        XCTAssertEqual(successes[0].toolName, "read_file")

        // Execution should continue (1 failure doesn't trigger circuit breaker)
        let content = StreamCollector.contentText(from: events)
        XCTAssertFalse(content.isEmpty, "Should produce content even with 1 failure in parallel batch")
    }

    // MARK: - Synthesis Routing (opt-in only)

    /// **Finding #1 regression — the executor's synthesis routing.**
    ///
    /// A real on-device run produced a complete 7-row markdown table; ONE dead
    /// `fs_read_metadata` call made the call site compute
    /// `forceSynthesis: responseSynthesisEnabled || !effectiveFailures.isEmpty`
    /// → true, which handed the finished answer to the IC model (system prompt:
    /// "Maximum 3 sentences for simple tasks") and the user received 3 rows.
    ///
    /// `TestAgentInputFactory` leaves `responseSynthesisEnabled` false — the
    /// un-opted default — so an unrecovered tool failure must NOT reroute the
    /// answer through synthesis. Pinned at the executor, not the synthesizer:
    /// the synthesizer's own gate is not what regressed here.
    ///
    /// ⚠️ The scripted tool name must NOT be a real permission-gated tool name.
    /// The incident's tool (`fs_read_metadata` then, `read_file_metadata` now) is mapped by
    /// `ToolExecutionMediator.getRequiredPermissions` to
    /// [.desktop, .documents, .downloads], so a mock run with that name routes
    /// through `PermissionManager.shared.ensurePermissions` — real TCC-gated
    /// `contentsOfDirectory` reads of ~/Desktop, ~/Documents, ~/Downloads. While
    /// the test host's TCC decision is undetermined (true after every rebuild —
    /// this app is signed ad-hoc, so its code identity changes each build), that
    /// call blocks inside tccd's prompt flow for minutes and intermittently hung
    /// these tests (observed 2026-09-25/26: the two gated tests cost ~180s each).
    /// The `-probe` suffix keeps the incident's semantics — one unrecovered
    /// metadata-read failure — off the real permission seam.
    func testReAct_UnrecoveredToolFailure_NotOptedIn_DoesNotRerouteAnswerThroughSynthesis() async throws {
        let table = """
        | File | Size |
        | --- | --- |
        | a.swift | 1 KB |
        | b.swift | 2 KB |
        | c.swift | 3 KB |
        """

        let failingTool = TestToolFactory.makeFailing(name: "fs_read_metadata_probe", error: "No such file")

        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Fetching metadata.",
                toolCalls: [TestToolCallFactory.make(name: "fs_read_metadata_probe")]
            ),
            ModernCognitiveStep(reasoning: table)
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "List the files", tools: [failingTool])
        XCTAssertFalse(input.responseSynthesisEnabled, "Precondition: this run is NOT opted into synthesis")

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let content = StreamCollector.contentText(from: events)
        XCTAssertEqual(content, table,
                       "A failed tool must not trigger a rewrite of the model's finished answer")

        // The failure must still be reported honestly — the amber path is what
        // communicates it now, and removing the force must not have muted it.
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.filter { !$0.isSuccess }.count, 1, "The failed tool row must survive")
    }

    /// TRAP: `effectiveFailures` does double duty — it fed BOTH the old
    /// `forceSynthesis` expression and the terminal-outcome derivation. Removing it
    /// from synthesis routing must leave the outcome honest, or every partially
    /// failed run would silently record green.
    ///
    /// Same naming constraint as the test above: the real metadata tool is
    /// permission-gated and would drag real TCC checks into this mock run. (The
    /// same incident name with a failing tool and no opt-in must still amber the
    /// run — that is what `fs_read_metadata_probe` pins here.)
    func testReAct_UnrecoveredToolFailure_StillReportsCompletedWithWarnings() async throws {
        let failingTool = TestToolFactory.makeFailing(name: "fs_read_metadata_probe", error: "No such file")

        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Fetching metadata.",
                toolCalls: [TestToolCallFactory.make(name: "fs_read_metadata_probe")]
            ),
            ModernCognitiveStep(reasoning: "Here is the answer anyway.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "List the files", tools: [failingTool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        let outcomes: [ExecutionOutcome] = events.compactMap { event in
            if case .executionFinished(let outcome, _) = event { return outcome }
            return nil
        }
        XCTAssertEqual(outcomes.last, .completedWithWarnings,
                       "An unrecovered evidence failure must still amber the run")
    }
}
