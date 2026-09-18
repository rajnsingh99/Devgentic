// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DialectCorrectiveWiringIntegrationTests.swift
//  DevgenticTests
//
//  Executor-level proof that the parse-failure corrective carries THIS RUN's dialect.
//
//  ⚠️ WHY THIS FILE EXISTS SEPARATELY FROM `DialectCorrectiveAlertTests`. That file proves
//  `LLMRetryStrategy.correctiveAlert(dialect:…)` says the right thing for every dialect. Every one
//  of those assertions passes with `dialect:` hard-wired to nil at the construction site — the
//  policy would be perfect and the feature dead, which is exactly how a fix ships non-functional
//  with a green suite. This file reads what actually reaches the MODEL'S OWN CONTEXT on the retry,
//  so it fails if `ReActAgentExecutor` stops passing `input.generatorStrategy.expectedDialect`.
//

import XCTest
@testable import devgentic

/// A generator that declares a dialect, records the scratchpad it is handed each iteration, and
/// then fails in a way the retry strategy has no typed arm for — the one remaining route to
/// `.parseRetry`, and therefore to the corrective.
private final class DialectDeclaringThrowingGenerator: CognitiveGenerator, @unchecked Sendable {

    let toolAdapter: ToolSchemaAdapter = LegacyPromptAdapter()
    let dialectRules: String? = "test rules"

    private let declared: ModelDialect
    /// The `<working_memory>` the executor compiled for each iteration, in order.
    private(set) var scratchpadPerIteration: [String] = []

    init(declaring dialect: ModelDialect) {
        self.declared = dialect
    }

    var expectedDialect: ModelDialect? { declared }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        [["role": "user", "content": context.originalQuery]]
    }

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        scratchpadPerIteration.append(context.compiledScratchpad)
        // Deliberately untyped: transport errors, empty responses and MLX slot races all have
        // typed arms that route AWAY from `.parseRetry`. This is the unclassified fall-through.
        throw NSError(domain: "UnrecognisedByAnyTypedArm", code: 42,
                      userInfo: [NSLocalizedDescriptionKey: "not a transport, empty or slot error"])
    }
}

/// A generator that declares a dialect and RETURNS a typed `.failed` step rather than throwing —
/// the path a real parse failure takes (`CognitiveParsePipeline.parse` never throws). This drives
/// `ParseFailureReason.modelCorrectiveAlert`, the sibling of the strategy's own corrective.
private final class DialectDeclaringFailingGenerator: CognitiveGenerator, @unchecked Sendable {

    let toolAdapter: ToolSchemaAdapter = LegacyPromptAdapter()
    let dialectRules: String? = "test rules"

    private let declared: ModelDialect
    private let reason: ParseFailureReason
    private(set) var scratchpadPerIteration: [String] = []

    init(declaring dialect: ModelDialect, failingWith reason: ParseFailureReason) {
        self.declared = dialect
        self.reason = reason
    }

    var expectedDialect: ModelDialect? { declared }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        [["role": "user", "content": context.originalQuery]]
    }

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        scratchpadPerIteration.append(context.compiledScratchpad)
        // Reasoning varies per iteration so the executor's identical-output abort
        // (ReActAgentExecutor.swift:812-837) does not end the run before the retry we came to read.
        return ModernCognitiveStep(
            reasoning: "attempt \(iteration)",
            toolCalls: [],
            parseOutcome: .failed(reason)
        )
    }
}

final class DialectCorrectiveWiringIntegrationTests: XCTestCase {

    /// Real budgets, millisecond backoff — same shape as `ResilienceBoundedRetryIntegrationTests`.
    private func fastPolicy() -> ResolvedResiliencePolicy {
        ResolvedResiliencePolicy(
            transport: TransportResiliencePolicy(
                providerClass: .mlx,
                maxTransientRetries: 0,
                maxThrottleRetries: 2,
                baseBackoff: 0.01,
                maxBackoff: 0.02,
                connectionRefusedIsFatal: false,
                endpointHint: nil,
                backoffStrategy: .fixed
            ),
            cognitive: CognitiveResiliencePolicy(maxParseFailures: 3),
            loop: LoopResiliencePolicy(maxConsecutiveToolFailures: 3, maxRepetitiveActions: 3, maxConsecutiveDenials: 2)
        )
    }

    /// Runs the executor against a generator that always fails, and returns the scratchpads the
    /// generator was handed. Index 0 is the first iteration (no corrective yet); index 1 is the
    /// first retry — the one carrying the alert.
    private func scratchpads(forDialect dialect: ModelDialect) async throws -> [String] {
        let generator = DialectDeclaringThrowingGenerator(declaring: dialect)
        let executor = ReActAgentExecutor(maxIterations: 4)
        var input = TestAgentInputFactory.make(query: "Do something", generatorStrategy: generator)
        input.resiliencePolicy = fastPolicy()

        let stream = executor.execute(model: MockLLMProvider(), input: input) { _ in }
        // The run is expected to abort on the parse cap; the corrective is what we came for.
        _ = try? await StreamCollector.collect(from: stream)

        return generator.scratchpadPerIteration
    }

    /// ⚠️ THE WIRING ASSERTION. A Mistral-v11 run must be told the `[TOOL_CALLS]…[ARGS]…` shape.
    /// Before the fix it was told to emit `{"reasoning": …, "toolCalls": […]}` — a format
    /// `MistralV11Parser` cannot read, so complying made the next iteration fail identically.
    func testMistralV11RunIsToldTheMistralV11Format() async throws {
        let compiled = try await scratchpads(forDialect: .mistralV11Flat)

        XCTAssertGreaterThanOrEqual(compiled.count, 2,
                                    "the run must retry at least once for a corrective to exist")
        let afterFirstFailure = compiled[1]

        XCTAssertTrue(
            afterFirstFailure.contains(ModelDialect.mistralV11Flat.formatReminder),
            "the corrective that reached the model did not name the v11 format. "
            + "If this fails while DialectCorrectiveAlertTests passes, the executor is no longer "
            + "handing the generator's dialect to LLMRetryStrategy. Got: \(afterFirstFailure)"
        )
        XCTAssertFalse(
            afterFirstFailure.contains("toolCalls"),
            "the model was told to emit the nativeJSON envelope its parser rejects: \(afterFirstFailure)"
        )
    }

    /// A second dialect, so the test cannot pass on a constant. If the wiring were hard-wired to
    /// one dialect, one of these two must fail.
    func testQwenHermesRunIsToldTheQwenHermesFormat() async throws {
        let compiled = try await scratchpads(forDialect: .qwenHermesToolCall)

        XCTAssertGreaterThanOrEqual(compiled.count, 2)
        let afterFirstFailure = compiled[1]

        XCTAssertTrue(
            afterFirstFailure.contains(ModelDialect.qwenHermesToolCall.formatReminder),
            "expected the <tool_call> shape, got: \(afterFirstFailure)"
        )
        XCTAssertFalse(afterFirstFailure.contains("[TOOL_CALLS]"),
                       "a Qwen run must not be told Mistral's markers: \(afterFirstFailure)")
    }

    /// The first iteration has nothing to correct — the corrective must not be pre-seeded.
    func testNoCorrectiveBeforeTheFirstFailure() async throws {
        let compiled = try await scratchpads(forDialect: .mistralV11Flat)

        let first = try XCTUnwrap(compiled.first)
        XCTAssertFalse(first.contains(ModelDialect.mistralV11Flat.formatReminder),
                       "iteration 1 has no failed output to correct: \(first)")
    }

    // MARK: - The typed-parse-failure path (ParseFailureReason.modelCorrectiveAlert)

    /// Same shape as `scratchpads(forDialect:)` but drives a RETURNED `.failed` step, which is
    /// how a real parse failure reaches the model — generators do not throw on one.
    private func scratchpads(
        forDialect dialect: ModelDialect,
        failingWith reason: ParseFailureReason
    ) async throws -> [String] {
        let generator = DialectDeclaringFailingGenerator(declaring: dialect, failingWith: reason)
        let executor = ReActAgentExecutor(maxIterations: 4)
        var input = TestAgentInputFactory.make(
            query: "Do something",
            tools: [TestToolFactory.make(name: "read_file")],
            generatorStrategy: generator
        )
        input.resiliencePolicy = fastPolicy()

        let stream = executor.execute(model: MockLLMProvider(), input: input) { _ in }
        _ = try? await StreamCollector.collect(from: stream)

        return generator.scratchpadPerIteration
    }

    /// ⚠️ THE WIRING ASSERTION for the typed path. Before the fix this told a Qwen3-Coder model
    /// `Correct shape: {"name": "...", "arguments": {...}}` — an envelope
    /// `Qwen3CoderDeepXMLParser` cannot read, so complying guaranteed the next failure.
    func testTypedSchemaFailureNamesTheRunsFormat() async throws {
        let compiled = try await scratchpads(
            forDialect: .qwen3CoderDeepXml,
            failingWith: .schemaKeyMismatch(expectedKeys: ["name"], foundKeys: ["fn"], rawSnippet: "{}")
        )

        XCTAssertGreaterThanOrEqual(compiled.count, 2, "the run must retry for a corrective to exist")
        let afterFirstFailure = compiled[1]

        XCTAssertTrue(
            afterFirstFailure.contains(ModelDialect.qwen3CoderDeepXml.formatReminder),
            "the typed corrective did not name the run's format. If this fails while "
            + "ParseFailureCorrectiveTests passes, the executor stopped passing `runDialect` to "
            + "modelCorrectiveAlert. Got: \(afterFirstFailure)"
        )
        XCTAssertFalse(
            afterFirstFailure.contains("\"arguments\": {...}"),
            "the model was told to emit the nativeJSON envelope: \(afterFirstFailure)"
        )
    }

    /// A second dialect and a second reason, so neither can pass on a constant.
    func testTypedProseFailureNamesTheRunsFormat() async throws {
        let compiled = try await scratchpads(
            forDialect: .pythonicBracketList,
            failingWith: .toolNameInProse(toolName: "read_file", snippet: "read_file path: \"/tmp\"")
        )

        XCTAssertGreaterThanOrEqual(compiled.count, 2)
        let afterFirstFailure = compiled[1]

        XCTAssertTrue(afterFirstFailure.contains(ModelDialect.pythonicBracketList.formatReminder),
                      "expected the pythonic shape, got: \(afterFirstFailure)")
        XCTAssertTrue(afterFirstFailure.contains("read_file"),
                      "the targeting that justifies this case existing was lost: \(afterFirstFailure)")
        XCTAssertFalse(afterFirstFailure.contains("[TOOL_CALLS]"),
                       "a pythonic run must not be told Mistral's markers: \(afterFirstFailure)")
    }
}
