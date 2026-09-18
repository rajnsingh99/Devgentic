// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeSeedingIntegrationTests.swift
//  DevgenticTests
//
//  Regression tests for capability-seeded working memory on the native (G12)
//  turn path. PlanningCapability and SelfReflectionCapability seed pre-run
//  observations (dependency results / prior-trial output) into workingMemory;
//  the native path excludes the scratchpad from compileMessages, so the seeds
//  must reach the model via the kickoff user turn instead. Unseeded runs must
//  keep the kickoff turn byte-identical to the raw user input (KV-cache prefix).
//
//  MockLLMProvider doesn't override generateCognitiveStep(nativeMessages:), so
//  the native turn array arrives through the protocol's default downgrade into
//  receivedCognitiveMessages — string content (system, kickoff user) survives
//  the coercion verbatim, which is exactly what these tests assert on.
//

import XCTest
@testable import devgentic

final class NativeSeedingIntegrationTests: XCTestCase {

    /// Seeds memory the way PlanningCapability.executeSubtask does for a dependency.
    private func makeSeededMemory(result: String) -> WindowedLinearMemory {
        var memory = WindowedLinearMemory(
            config: MemoryBudgetConfig.derive(contextWindow: 8192, tier: .small)
        )
        memory.recordObservation(
            stepId: 0,
            toolCallId: "dep_step_1",
            toolName: "prior_subtask",
            params: "",
            result: result,
            artifacts: []
        )
        return memory
    }

    func testNativePath_SeededMemory_ReachesKickoffUserTurn() async throws {
        let seedText = "[Find the largest file]: /tmp/big.bin (4.2 GB)"
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(reasoning: "Summarized using the prior result.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(
            query: "Summarize the file found in step 1",
            workingMemory: makeSeededMemory(result: seedText),
            generatorStrategy: NativeStructuredGenerator()
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        _ = try await StreamCollector.collect(from: stream)

        let firstRequest = try XCTUnwrap(
            provider.receivedCognitiveMessages.first,
            "Native path should have issued a cognitive step request"
        )
        let kickoff = try XCTUnwrap(firstRequest.last, "Request should end with the kickoff user turn")

        XCTAssertEqual(kickoff["role"], "user")
        let content = try XCTUnwrap(kickoff["content"])
        XCTAssertTrue(content.contains("<prior_context>"), "Kickoff turn should carry the seeded context section")
        XCTAssertTrue(content.contains(seedText), "Seeded dependency result must reach the model")
        XCTAssertTrue(content.contains("Summarize the file found in step 1"), "User task must remain in the kickoff turn")

        // The seeds belong to the kickoff turn only — compileMessages must keep
        // excluding the scratchpad from the system prompt and history turns.
        for message in firstRequest.dropLast() {
            XCTAssertFalse(
                message["content"]?.contains(seedText) ?? false,
                "Seeded context must not leak into earlier turns (role: \(message["role"] ?? "?"))"
            )
        }
    }

    func testNativePath_UnseededMemory_KickoffTurnByteIdentical() async throws {
        let provider = MockLLMProvider(steps: [
            ModernCognitiveStep(reasoning: "Answering directly.")
        ])

        let executor = ReActAgentExecutor(maxIterations: 5)
        let input = TestAgentInputFactory.make(
            query: "What is 2+2?",
            generatorStrategy: NativeStructuredGenerator()
        )

        let stream = executor.execute(model: provider, input: input) { _ in }
        _ = try await StreamCollector.collect(from: stream)

        let firstRequest = try XCTUnwrap(provider.receivedCognitiveMessages.first)
        let kickoff = try XCTUnwrap(firstRequest.last)

        XCTAssertEqual(kickoff["role"], "user")
        XCTAssertEqual(
            kickoff["content"], "What is 2+2?",
            "Unseeded runs must keep the kickoff turn byte-identical to the user input"
        )
    }
}
