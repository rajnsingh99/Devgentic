// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkingMemoryFeedbackLoopTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

/// Returns a scripted step per iteration and records the scratchpad it was handed each time.
private final class ScriptedStepGenerator: CognitiveGenerator, @unchecked Sendable {

    let toolAdapter: ToolSchemaAdapter = LegacyPromptAdapter()
    let dialectRules: String? = "test rules"
    var expectedDialect: ModelDialect? { .heuristicJson }

    private let steps: [ModernCognitiveStep]
    private(set) var scratchpadPerIteration: [String] = []

    init(steps: [ModernCognitiveStep]) { self.steps = steps }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        [["role": "user", "content": context.originalQuery]]
    }

    func generateCognitiveStep(
        model: any LLMProvider,
        context: SemanticContext,
        iteration: Int
    ) async throws -> ModernCognitiveStep {
        scratchpadPerIteration.append(context.compiledScratchpad)
        return steps[min(iteration - 1, steps.count - 1)]
    }
}

final class WorkingMemoryFeedbackLoopTests: XCTestCase {

    /// A blob shaped like the real thing: wrong keys, smart quotes, unterminated.
    private let malformed = #"{" content":"Executing `ls -R`",  "tool”: ":",   “arguments”:{ “path"#

    private func fastPolicy() -> ResolvedResiliencePolicy {
        ResolvedResiliencePolicy(
            transport: TransportResiliencePolicy(
                providerClass: .ollama, maxTransientRetries: 0, maxThrottleRetries: 2,
                baseBackoff: 0.01, maxBackoff: 0.02, connectionRefusedIsFatal: false,
                endpointHint: nil, backoffStrategy: .fixed
            ),
            cognitive: CognitiveResiliencePolicy(maxParseFailures: 3),
            loop: LoopResiliencePolicy(maxConsecutiveToolFailures: 3, maxRepetitiveActions: 3, maxConsecutiveDenials: 2)
        )
    }

    private func run(steps: [ModernCognitiveStep],
                     tools: [AgentTool] = [],
                     memory: (any WorkingMemoryStrategy)? = nil) async -> [String] {
        let generator = ScriptedStepGenerator(steps: steps)
        let executor = ReActAgentExecutor(maxIterations: 6)
        var input = TestAgentInputFactory.make(query: "Do something",
                                               tools: tools,
                                               workingMemory: memory,
                                               generatorStrategy: generator)
        input.resiliencePolicy = fastPolicy()
        let stream = executor.execute(model: MockLLMProvider(), input: input) { _ in }
        _ = try? await StreamCollector.collect(from: stream)
        return generator.scratchpadPerIteration
    }

    /// ⚠️ THE ASSERTION THAT MATTERS MOST, and the one that fails on the old code.
    func testAFailedParsesRawOutputNeverReachesTheNextPrompt() async throws {
        // Vary the text slightly so the identical-output abort doesn't end the run early.
        let steps = (1...4).map { i in
            ModernCognitiveStep(
                reasoning: malformed + " attempt\(i)",
                toolCalls: [],
                parseOutcome: .failed(.schemaKeyMismatch(expectedKeys: ["name"], foundKeys: [], rawSnippet: "{}"))
            )
        }
        let scratchpads = await run(steps: steps)

        XCTAssertGreaterThanOrEqual(scratchpads.count, 2, "the run must retry for a scratchpad to exist")
        for (i, pad) in scratchpads.enumerated() {
            XCTAssertFalse(
                pad.contains("“arguments”"),
                "iteration \(i + 1) was shown the model's own malformed output. That is the feedback "
                + "loop: the model copies it, outputs go byte-identical, the run dies. Got:\n\(pad)"
            )
            XCTAssertFalse(pad.contains(#""tool”"#), "iteration \(i + 1) carried the broken keys:\n\(pad)")
        }
    }

    /// ⚠️ The inverse. A fix that simply stopped recording reasoning would pass the test above while
    /// re-creating the reasoning amnesia `recordReasoning` exists to prevent.
    func testSuccessfulReasoningIsStillCarriedForward() async throws {
        let tool = TestToolFactory.make(name: "test_tool", output: "tool ran")
        let steps = [
            ModernCognitiveStep(
                reasoning: "DISTINCTIVE_GOOD_REASONING about what to do next",
                toolCalls: [PendingToolCall(id: "c1", name: "test_tool", arguments: ["input": .string("x")])],
                parseOutcome: .success
            ),
            ModernCognitiveStep(reasoning: "All done.", toolCalls: [], parseOutcome: .genuineCompletion),
        ]

        let scratchpads = await run(steps: steps, tools: [tool])

        XCTAssertGreaterThanOrEqual(scratchpads.count, 2,
                                    "the successful tool call must lead to a second iteration")
        XCTAssertTrue(
            scratchpads[1].contains("DISTINCTIVE_GOOD_REASONING"),
            "a SUCCESSFUL step's reasoning must still reach the next prompt — dropping it "
            + "re-creates the reasoning amnesia. Got:\n\(scratchpads[1])"
        )
    }

    /// The corrective must still land — the fix removes the garbage, not the guidance.
    func testTheCorrectiveAlertStillReachesTheModel() async throws {
        let steps = (1...3).map { i in
            ModernCognitiveStep(
                reasoning: malformed + " attempt\(i)",
                toolCalls: [],
                parseOutcome: .failed(.schemaKeyMismatch(expectedKeys: ["name"], foundKeys: [], rawSnippet: "{}"))
            )
        }
        let scratchpads = await run(steps: steps)

        let afterFirstFailure = scratchpads[1]
        XCTAssertTrue(afterFirstFailure.contains("SYSTEM ALERT"),
                      "the scratchpad must still carry the corrective:\n\(afterFirstFailure)")
        XCTAssertTrue(
            afterFirstFailure.contains(ModelDialect.heuristicJson.formatReminder),
            "and it must name THIS run's format (invariant 80):\n\(afterFirstFailure)"
        )
    }

    /// ⚠️ The budget consequence, which is what actually killed the real run. Repeated failures must
    /// not grow the scratchpad — the old code added a full blob per iteration until eviction started
    /// discarding the entries that mattered (176% of budget, carrying only garbage).
    func testRepeatedFailuresDoNotGrowTheScratchpadWithModelOutput() async throws {
        let steps = (1...4).map { i in
            ModernCognitiveStep(
                reasoning: String(repeating: "GARBAGE\(i) ", count: 40),
                toolCalls: [],
                parseOutcome: .failed(.schemaKeyMismatch(expectedKeys: ["name"], foundKeys: [], rawSnippet: "{}"))
            )
        }
        let scratchpads = await run(steps: steps)

        for (i, pad) in scratchpads.enumerated() {
            XCTAssertFalse(pad.contains("GARBAGE"),
                           "iteration \(i + 1) carried model output into the budget:\n\(pad)")
        }
        // Alerts are capped, so the scratchpad must plateau rather than grow per failure.
        if let last = scratchpads.last {
            XCTAssertLessThan(last.count, 2_000,
                              "the scratchpad should plateau on repeated failures, got \(last.count) chars")
        }
    }

    // MARK: - The second feedback loop: the memory-pressure nudge

    /// ⚠️ The nudge had NO once-guard on the legacy path, while the native path has carried
    /// `didInjectFullBudgetAlert` all along — whose own declaration comment says it "gates the
    /// synthesis nudge to once (re-appending it every iteration was the bug this fixes)". The fix
    /// simply never reached this path.
    ///
    /// Un-guarded it was self-reinforcing, not merely noisy: the message is a CONSTANT, so every
    /// over-budget iteration recorded a byte-identical alert, each adding ~183 chars to
    /// `budgetUtilization`, pushing utilization higher, re-firing the branch. In the 2026-09-13 run
    /// the figure climbed 78 → 90 → 101 → 120 → 138 → 157 → 175%, and three copies of this one
    /// sentence were enough to fill every `maxSystemAlerts` slot — evicting the format correctives.
    ///
    /// ⚠️ Its observable signature is the ABSENCE of a repeat marker: with dedupe in place a
    /// re-recorded nudge would still render as one line, but tagged `(repeated Nx)`.
    func testTheMemoryPressureNudgeIsRecordedOncePerRun() async throws {
        let tool = TestToolFactory.make(name: "test_tool", output: String(repeating: "z", count: 400))
        // Budget small enough that the first observation pushes utilization past 1.0.
        let tiny = WindowedLinearMemory(config: MemoryBudgetConfig(
            totalBudgetChars: 300, perEntryCap: 200, fullFidelityWindow: 1, maxSystemAlerts: 3))

        let steps = (1...5).map { i in
            ModernCognitiveStep(
                reasoning: "step \(i)",
                toolCalls: [PendingToolCall(id: "c\(i)", name: "test_tool",
                                            arguments: ["input": .string("call-\(i)")])],
                parseOutcome: .success)
        }

        let scratchpads = await run(steps: steps, tools: [tool], memory: tiny)
        let all = scratchpads.joined(separator: "\n----\n")

        // ⚠️ Vacuity guard. If the budget never crossed 1.0 the nudge never fires and the
        // assertion below would pass for the wrong reason.
        XCTAssertTrue(all.contains("Working memory is full"),
                      "the fixture must actually drive the run over budget:\n\(all)")

        for (i, pad) in scratchpads.enumerated() where pad.contains("Working memory is full") {
            XCTAssertFalse(
                pad.contains("Working memory is full. Older observations have been evicted. "
                             + "Prioritize synthesizing a final answer from available context "
                             + "rather than calling additional tools. (repeated"),
                "iteration \(i + 1) shows the nudge recorded more than once — the once-guard is "
                + "not holding, and each extra copy inflates the very utilization that triggers "
                + "it:\n\(pad)"
            )
        }
    }

    // MARK: - The alert channel vs the reasoning channel

    /// ⚠️ The boundary this file's headline test depends on. The `.schemaKeyMismatch` corrective
    /// now QUOTES up to 80 chars of the model's output — deliberately, in the alert channel,
    /// framed as the wrong thing and followed by the right shape. That is not the feedback loop:
    /// the loop was the WHOLE blob recorded as the model's own `[Step N thought]` with no framing,
    /// one more copy per iteration until it filled the budget.
    ///
    /// So the snippet reaches the prompt ONLY inside a `[SYSTEM ALERT]` line, and the reasoning
    /// channel stays closed. If the first assertion fails the corrective lost its discriminator;
    /// if the second fails the feedback loop is back.
    func testTheSnippetReachesThePromptOnlyThroughTheAlertChannel() async throws {
        let steps = (1...3).map { i in
            ModernCognitiveStep(
                reasoning: malformed + " attempt\(i)",   // the blob, as the model's "reasoning"
                toolCalls: [],
                parseOutcome: .failed(.schemaKeyMismatch(
                    expectedKeys: ["name"], foundKeys: [],
                    rawSnippet: "SNIPPET_MARKER_\(i) " + malformed))
            )
        }
        let scratchpads = await run(steps: steps)
        XCTAssertGreaterThanOrEqual(scratchpads.count, 2, "the run must retry for a scratchpad to exist")

        let afterFirstFailure = scratchpads[1]
        let lines = afterFirstFailure.components(separatedBy: "\n")
        let alertLines = lines.filter { $0.contains("[SYSTEM ALERT]") }
        let thoughtLines = lines.filter { $0.contains("thought]") }

        XCTAssertTrue(alertLines.contains { $0.contains("SNIPPET_MARKER_1") },
                      "the quoted output must reach the model inside the alert:\n\(afterFirstFailure)")
        XCTAssertTrue(thoughtLines.isEmpty,
                      "a failed parse must record NO thought — that is the feedback loop:\n\(afterFirstFailure)")
        // Every copy of the blob that IS present sits inside a framed alert line.
        for line in lines where line.contains("“arguments”") {
            XCTAssertTrue(line.contains("[SYSTEM ALERT]") && line.contains("you emitted"),
                          "model output reached the prompt outside the framed alert:\n\(line)")
        }
    }
}
