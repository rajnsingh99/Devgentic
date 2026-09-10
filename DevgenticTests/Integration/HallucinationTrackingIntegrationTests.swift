// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  HallucinationTrackingIntegrationTests.swift
//  DevgenticTests
//
//  Regression tests for the hallucinated-tools guardrail. Only genuinely
//  hallucinated names (ToolFailureCategory.notFound — the tool isn't in the
//  registry) may enter the "DO NOT USE" prompt ban; ordinary failures, rejected
//  final_answer attempts, etc. are retryable and must NOT ban the tool.
//
//  MockCognitiveGenerator mirrors PromptBuilder's <hallucinated_tools> section,
//  so the ban list is observable through the messages the mock provider captures
//  on the NEXT iteration.
//

import XCTest
@testable import devgentic

final class HallucinationTrackingIntegrationTests: XCTestCase {

    func testOrdinaryToolFailure_DoesNotEnterDoNotUseList() async throws {
        // Iteration 1: read_file exists but throws (file not found) → retryable
        // failure. Iteration 2's prompt must NOT ban the tool.
        let tool = TestToolFactory.makeFailing(name: "read_file", error: "File not found at /tmp/missing.txt")
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Reading the file.",
                toolCalls: [TestToolCallFactory.make(name: "read_file", input: "/tmp/missing.txt")]
            ),
            ModernCognitiveStep(reasoning: "The file is missing. Answering with what I know.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "Read the report", tools: [tool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        let events = try await StreamCollector.collect(from: stream)

        // The failure itself is still recorded and surfaced…
        let toolOutputs = StreamCollector.toolOutputs(from: events)
        XCTAssertEqual(toolOutputs.count, 1)
        XCTAssertFalse(toolOutputs[0].isSuccess)

        // …but the tool is NOT prompt-banned on the next iteration.
        XCTAssertEqual(provider.receivedCognitiveMessages.count, 2)
        let secondPrompt = provider.receivedCognitiveMessages[1].first?["content"] ?? ""
        XCTAssertFalse(
            secondPrompt.contains("<hallucinated_tools>"),
            "An ordinary tool failure must not enter the DO NOT USE ban list. Prompt was:\n\(secondPrompt)"
        )
    }

    func testHallucinatedToolName_EntersDoNotUseList() async throws {
        // Iteration 1: model invents a tool that isn't registered → .notFound.
        // Iteration 2's prompt MUST carry the ban so the model stops retrying it.
        let realTool = TestToolFactory.make(name: "real_tool", output: "OK")
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Using my imaginary tool.",
                toolCalls: [TestToolCallFactory.make(name: "imaginary_tool")]
            ),
            ModernCognitiveStep(reasoning: "That tool doesn't exist. Answering directly.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "Do something", tools: [realTool])

        let stream = executor.execute(model: provider, input: input) { _ in }
        _ = try await StreamCollector.collect(from: stream)

        XCTAssertEqual(provider.receivedCognitiveMessages.count, 2)
        let secondPrompt = provider.receivedCognitiveMessages[1].first?["content"] ?? ""
        XCTAssertTrue(
            secondPrompt.contains("<hallucinated_tools>"),
            "A genuinely hallucinated tool name must enter the DO NOT USE ban list. Prompt was:\n\(secondPrompt)"
        )
        XCTAssertTrue(secondPrompt.contains("- imaginary_tool"))
    }

    func testRejectedFinalAnswer_DoesNotBanFinalAnswer() async throws {
        // Iteration 1: final_answer with an empty answer → rejected with a
        // "retry final_answer" observation. Banning final_answer here would
        // contradict that instruction and lock the loop's only clean exit.
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(
                reasoning: "Finishing up.",
                toolCalls: [PendingToolCall(id: UUID().uuidString, name: "final_answer", arguments: ["answer": .string("")])]
            ),
            ModernCognitiveStep(reasoning: "Here is my actual answer.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(query: "Summarize the plan")

        let stream = executor.execute(model: provider, input: input) { _ in }
        _ = try await StreamCollector.collect(from: stream)

        XCTAssertEqual(provider.receivedCognitiveMessages.count, 2)
        let secondPrompt = provider.receivedCognitiveMessages[1].first?["content"] ?? ""
        XCTAssertFalse(
            secondPrompt.contains("<hallucinated_tools>"),
            "A rejected final_answer must not ban final_answer — the observation explicitly asks the model to retry it. Prompt was:\n\(secondPrompt)"
        )
    }
}
