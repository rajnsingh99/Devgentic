// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MockLLMProvider.swift
//  DevgenticTests
//
//  Scriptable mock LLMProvider for integration tests.
//  Supports both generate() (used by PlanGeneratorStrategy) and
//  generateCognitiveStep() (used by ReAct executor).
//  Deterministic, sub-second, no real model inference.
//

import Foundation
@testable import devgentic

/// A scriptable LLM provider that returns pre-configured responses.
///
/// - `generateCognitiveStep()` returns the next `ModernCognitiveStep` from the `steps` array.
/// - `generate()` returns the next string from the `generateResponses` array.
///
/// Both sequences advance independently — planning calls use `generate()`,
/// ReAct iterations use `generateCognitiveStep()`.
final class MockLLMProvider: LLMProvider, @unchecked Sendable {

    let modelName = "mock-test-model"

    // MARK: - Scripted Sequences

    private let steps: [ModernCognitiveStep]
    private var stepIndex = 0

    private let generateResponses: [String]
    private var generateIndex = 0

    /// Track messages received for assertion in tests.
    private(set) var receivedCognitiveMessages: [[[String: String]]] = []
    private(set) var receivedGenerateMessages: [[[String: String]]] = []

    /// Full initializer for tests that need both generate() and generateCognitiveStep().
    init(steps: [ModernCognitiveStep] = [], generateResponses: [String] = []) {
        self.steps = steps
        self.generateResponses = generateResponses
    }

    // MARK: - CognitiveStep (Used by ReAct Executor)

    func generateCognitiveStep(
        messages: [[String: String]],
        tools: [[String: Any]]?
    ) async throws -> ModernCognitiveStep {
        receivedCognitiveMessages.append(messages)

        guard stepIndex < steps.count else {
            return ModernCognitiveStep(reasoning: "No more scripted steps.")
        }

        let step = steps[stepIndex]
        stepIndex += 1
        return step
    }

    // MARK: - Generate (Used by PlanGeneratorStrategy)

    func generate(messages: [[String: String]], tools: [[String: Any]]?, responseSchema: Any?) async throws -> String {
        receivedGenerateMessages.append(messages)

        guard generateIndex < generateResponses.count else {
            return "[]" // Empty plan fallback
        }

        let response = generateResponses[generateIndex]
        generateIndex += 1
        return response
    }

    // MARK: - Stream (Not used in integration tests)

    func stream(messages: [[String: String]], tools: [[String: Any]]?) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { $0.finish() }
    }
}
