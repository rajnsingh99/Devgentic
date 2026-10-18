// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeSeedingIntegrationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
        // Layout B: the kickoff turn leads with the per-message turn context (no history or
        // retrieval here, so just the time line), then the user input — and nothing else: an
        // unseeded run adds no `<prior_context>` and no other bytes.
        let content = try XCTUnwrap(kickoff["content"])
        let parts = content.components(separatedBy: "\n\n")
        XCTAssertEqual(parts.count, 2, "Unseeded runs must carry only the turn context and the user input — got: \(content)")
        XCTAssertTrue(parts.first?.hasPrefix("Current time: ") ?? false, "The turn context must lead the kickoff turn")
        XCTAssertEqual(parts.last, "What is 2+2?", "The user input must close the kickoff turn, byte-identical")
        XCTAssertFalse(firstRequest.first?["content"]?.contains("Current time") ?? true,
                       "The time must ride the kickoff turn, never the system message")
    }
}
