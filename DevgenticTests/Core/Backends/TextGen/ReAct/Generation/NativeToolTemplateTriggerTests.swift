// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeToolTemplateTriggerTests.swift
//  devgenticTests
//
//  The MLX chat-template path appends a trigger as the last user turn of EVERY request. It used
//  to end "Respond with one or more <tool_call> blocks…", so the last thing a small model read
//  each turn was an order to call a tool. A plain reply has been accepted as the final answer
//  since the answer-vs-call verdict, yet on 2026-10-05 Qwen2.5-3B explored the project on all
//  three prompts that needed no tools, two of which said "Don't use any tools".
//
//  ⚠️ Not wording tests. They guard that the trigger offers a plain answer on every dialect, that
//  the dialect's own format hint still reaches the model, and that the trigger is actually sent.
//

import XCTest
@testable import devgentic

final class NativeToolTemplateTriggerTests: XCTestCase {

    /// Every factory `AgentConnect` routes an MLX chat-template model to.
    private let generators: [NativeToolTemplateGenerator] = [
        .qwenHermes(), .llama3Json(), .mistralV3(), .mistralV11(), .phiFunctools(), .deepseekV3(),
        .pythonic(), .graniteLegacy(), .granite4(), .commandR(), .commandR7B(), .qwen3Coder(),
        .deepseekV31(), .deepseekV32(),
    ]

    func testEveryDialectsTriggerOffersAPlainAnswer() {
        XCTAssertEqual(Set(generators.map(\.dialect)).count, generators.count,
                       "fixture precondition: one generator per dialect")
        for generator in generators {
            for iteration in [1, 2] {
                let trigger = generator.promptTrigger(for: iteration).lowercased()
                XCTAssertTrue(trigger.contains("plain text"),
                              "\(generator.logTag) iteration \(iteration): the trigger demands a call and never offers a plain answer")
            }
        }
    }

    func testEveryDialectsFormatHintStillReachesTheTrigger() {
        // The answer offer must not replace the format reinforcement small models rely on.
        for generator in generators {
            let trigger = generator.promptTrigger(for: 2)
            XCTAssertTrue(trigger.contains(generator.triggerSuffix),
                          "\(generator.logTag): the dialect's call format is missing from the trigger")
            XCTAssertFalse(trigger.lowercased().contains("respond with respond"),
                           "\(generator.logTag): the format hint repeats the trigger's own lead-in")
        }
    }

    /// ⚠️ THE CALL SITE: the trigger must be the request's last user turn, and a plain reply must
    /// come back as the answer — a unit test of `promptTrigger` passes even if nothing sends it.
    func testThePlainAnswerOfferIsSentAndAPlainReplyIsTheAnswer() async throws {
        let generator = NativeToolTemplateGenerator.qwenHermes()
        let model = MockLLMProvider(generateResponses: ["A list comprehension builds a list from an iterable in one expression."])

        let step = try await generator.generateCognitiveStep(model: model, context: Self.context(), iteration: 2)

        let request = try XCTUnwrap(model.receivedGenerateMessages.last)
        XCTAssertEqual(request.last?["role"], "user")
        XCTAssertEqual(request.last?["content"], generator.promptTrigger(for: 2),
                       "the request does not end on the iteration trigger")
        guard case .genuineCompletion = step.parseOutcome else {
            return XCTFail("a plain reply was not accepted as the answer: \(step.parseOutcome)")
        }
        XCTAssertTrue(step.toolCalls.isEmpty)
    }

    /// Every text-format generator ends on the shared base, which names no "analyze / decide" step:
    /// Qwen2.5-3B answered T1 with a narration of that step instead of the answer (2026-10-06).
    func testNoGeneratorsTriggerAsksTheModelToNarrateADecision() {
        let all: [(String, any CognitiveGenerator)] = [
            ("XMLStructured", XMLStructuredGenerator()), ("MLXNativeStructured", MLXNativeStructuredGenerator()),
            ("JsonStructured", JsonStructuredGenerator()), ("XMLNativeStructured", XMLNativeStructuredGenerator()),
            ("MarkdownStructured", MarkdownStructuredGenerator()),
        ] + generators.map { ($0.logTag, $0 as any CognitiveGenerator) }
        for (name, generator) in all {
            for iteration in [1, 2] {
                let trigger = generator.promptTrigger(for: iteration)
                XCTAssertTrue(trigger.hasPrefix(IterationTrigger.base(for: iteration)),
                              "\(name) iteration \(iteration) no longer starts from the shared trigger: \(trigger)")
                let lower = trigger.lowercased()
                XCTAssertFalse(lower.contains("decide your next action") || lower.contains("analyze the task"),
                               "\(name) iteration \(iteration) asks for a decision step small models narrate: \(trigger)")
            }
        }
    }

    private static func context() -> SemanticContext {
        SemanticContext(
            instructions: "You are a helpful agent.",
            environmentFacts: EnvironmentFacts(osVersion: "macOS", shellType: "zsh", userName: "t", homeDirectory: "/Users/t", currentDate: "01/01/2026"),
            longTermMemory: StaticGroundingMemory(ragContext: ""),
            recentHistory: nil,
            nativeHistoryTurns: nil,
            originalQuery: "In two sentences, what does a Python list comprehension do? Don't use any tools.",
            currentIteration: 2,
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
}
