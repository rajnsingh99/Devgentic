// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeZeroCallVerdictTests.swift
//  DevgenticTests
//
//  Invariant: on a native-tools API, a reply with ZERO tool calls is the final
//  answer — unless its content declares an attempted call to one of the run's
//  tools. Braces and brackets in prose decide nothing.
//
//  And: format failures are bounded whatever the output — the run never retries
//  more than `maxConsecutiveFormatFailures` times in a row.
//
//  Field case (2026-10-04): gemma4 and deepseek-r1 wrote correct answers containing
//  `{7, 1, 5, 3, 6, 4}` / `int[] prices`; the Ollama content fallback classified
//  them `malformedJSON` and the executor retried 3× and 6× (the second until the
//  user pressed Stop, losing everything).
//

import XCTest
@testable import devgentic

final class NativeZeroCallVerdictTests: XCTestCase {

    // MARK: - Fixtures (verbatim shapes from the 2026-10-04 log)

    /// gemma4 iteration 9 — a correct final answer with a Java array literal.
    private let javaArrayAnswer = """
    I have successfully implemented the `maxProfit` method.

    2.  **Updated Usage:** Modified the `main` method to demonstrate calling it with a sample array `{7, 1, 5, 3, 6, 4}` (Expected output: 7).

    The task is complete.
    """

    /// gemma4 iteration 11 — no braces at all, only `int[]`.
    private let bracketOnlyAnswer = """
    I have successfully added a static method `maxProfit` to `January2026.java`.
    *   **New Method:** `public static int maxProfit(int[] prices)`
    """

    /// deepseek-r1 iteration 4 — prose followed by a ```json analysis block.
    private let jsonAnalysisAnswer = """
    The `maxProfit` method correctly sums all positive price differences.

    ```json
    {
      "analysis": {
        "main_method_usage": { "example_input": [7, 1, 5, 3, 6, 4], "expected_output": 7 }
      }
    }
    ```
    """

    private var tools: [AgentTool] {
        ["final_answer", "read_file", "git"].map { TestToolFactory.make(name: $0) }
    }

    /// What the Ollama provider hands up for `content` with `tool_calls=[]`.
    private func providerStep(_ content: String) -> ModernCognitiveStep {
        OllamaLLMProvider.contentFallbackStep(
            content: content, thinking: nil, usage: nil, modelName: "gemma4:latest")
    }

    private func verdict(_ content: String, runToolNames: Set<String> = []) -> ModernCognitiveStep {
        NativeParsePipeline(registeredTools: tools, runToolNames: runToolNames)
            .validate(step: providerStep(content))
    }

    private func isCompletion(_ step: ModernCognitiveStep) -> Bool {
        if case .genuineCompletion = step.parseOutcome { return true }
        return false
    }

    private func isFailure(_ step: ModernCognitiveStep) -> Bool {
        if case .failed = step.parseOutcome { return true }
        return false
    }

    // MARK: - Attempted-call grammar

    func testBracesAndBracketsAreNotAnAttemptedCall() {
        let names: Set<String> = ["read_file", "final_answer"]
        for text in [javaArrayAnswer, bracketOnlyAnswer, jsonAnalysisAnswer, #"{"name": "Raj"}"#] {
            XCTAssertNil(AttemptedToolCallGrammar.attemptedCallName(in: text, callableNames: names), text)
        }
    }

    func testANameKeyDeclaringARunToolIsAnAttemptedCall() {
        let names: Set<String> = ["read_file", "git"]
        XCTAssertEqual(AttemptedToolCallGrammar.attemptedCallName(
            in: #"{"name":"read_file","arguments":{"path":"#, callableNames: names), "read_file")
        XCTAssertEqual(AttemptedToolCallGrammar.attemptedCallName(
            in: #"{"function": {"name": "READ_FILE"}}"#, callableNames: names), "read_file")
        XCTAssertEqual(AttemptedToolCallGrammar.attemptedCallName(
            in: #"{"tool_name": "git", "args": "#, callableNames: names), "git")
    }

    // MARK: - Provider → NativeParsePipeline (Part 1)

    /// The precondition the fix exists for: the content cascade STILL calls these failures.
    /// If this ever stops holding, the cascade changed and the cases below prove less.
    func testTheContentCascadeStillJudgesTheseAnswersByShape() {
        XCTAssertTrue(isFailure(providerStep(javaArrayAnswer)))
        XCTAssertTrue(isFailure(providerStep(bracketOnlyAnswer)))
    }

    func testProseWithBracketsIsTheFinalAnswer_WholeText() {
        for answer in [javaArrayAnswer, bracketOnlyAnswer, jsonAnalysisAnswer] {
            let step = verdict(answer)
            guard isCompletion(step) else {
                // The json-analysis reply may be parsed as completion upstream already;
                // either way it must not be a failure.
                XCTFail("answer was not accepted (\(step.parseOutcome)):\n\(answer)"); continue
            }
            XCTAssertTrue(step.toolCalls.isEmpty)
        }
        // The provider must hand up the WHOLE content on a failed cascade — not the
        // prose prefix cut at the first `{`.
        XCTAssertEqual(verdict(javaArrayAnswer).reasoning, javaArrayAnswer)
        // ⚠️ The case that actually truncated: prose, then a ```json block. The old
        // provider handed up only the prose before the first `{`.
        XCTAssertTrue(isFailure(providerStep(jsonAnalysisAnswer)), "fixture precondition: the cascade must fail it")
        XCTAssertTrue(verdict(jsonAnalysisAnswer).reasoning.contains(#""expected_output": 7"#),
                      "the answer was cut at its first brace")
    }

    func testALeakedValidCallIsStillRecovered() {
        let step = verdict(#"{"name":"read_file","arguments":{"input":"a.java"}}"#)
        XCTAssertEqual(step.toolCalls.map(\.name), ["read_file"])
    }

    func testALeakedFinalAnswerCallIsStillAFinalAnswerCall() {
        let step = verdict(#"{"name":"final_answer","arguments":{"input":"Done."}}"#)
        XCTAssertEqual(step.toolCalls.map(\.name), ["final_answer"],
                       "a final_answer leaked into content must stay a terminal call, not become prose")
    }

    /// A call that does not decode (unquoted value, balanced braces) is still retried.
    private let brokenReadFile = #"{"name":"read_file","arguments":{"input": a.java}}"#

    /// A call CUT OFF mid-object is retried too. It used to be classified `.genuineCompletion`
    /// upstream — no closing brace, so the content cascade never looked for a call — and shown
    /// as the answer. The cascade now asks the grammar first (CallRecoveryGateTests).
    func testACutOffLeakedCallIsRetried() {
        let cut = #"{"name":"read_file","arguments":{"input":"#
        XCTAssertTrue(isFailure(providerStep(cut)), "the content cascade accepted a cut-off call")
        XCTAssertTrue(isFailure(verdict(cut)))
    }

    func testAnUndecodableLeakedCallIsStillRetried() {
        XCTAssertTrue(isFailure(providerStep(brokenReadFile)), "fixture precondition: the cascade must fail it")
        XCTAssertTrue(isFailure(verdict(brokenReadFile)))
    }

    /// A hallucinated tool behind a wrong schema key is a call, not an answer — even though
    /// its name is not registered. (Gap in the first cut, which recognised registered names only.)
    func testAWrongSchemaKeyCallIsRetriedNotAccepted() {
        let call = #"{"function_name": "final_summary", "arguments": {"summary": "done"}}"#
        XCTAssertTrue(isFailure(providerStep(call)), "fixture precondition: the cascade must fail it")
        XCTAssertTrue(isFailure(verdict(call)), "a wrong-schema call was shown as the answer")
    }

    /// A broken call to a tool withheld from THIS iteration's schema is still a call:
    /// the generator passes the run's full loadout as `runToolNames`.
    func testABrokenCallToAWithheldToolIsRetried_OnlyWithRunToolNames() {
        let broken = #"{"name":"save_notes","content": draft}"#
        XCTAssertTrue(isFailure(providerStep(broken)), "fixture precondition: the cascade must fail it")
        XCTAssertTrue(isFailure(verdict(broken, runToolNames: ["read_file", "save_notes"])))
        XCTAssertTrue(isCompletion(verdict(broken)),
                      "without the run's loadout the withheld name is unknown — this is why runToolNames is threaded through")
    }

    // MARK: - Wiring: provider step → NativeStructuredGenerator → executor

    /// The generator must forward the run's loadout: a withheld tool is absent from
    /// this iteration's `availableTools`, so only `runToolNames` can name it.
    func testTheGeneratorForwardsRunToolNames() async throws {
        let broken = #"{"name":"save_notes","content": draft}"#
        let step = try await NativeStructuredGenerator(toolTurnAdapter: OllamaToolTurnAdapter()).generateNativeStep(
            model: MockLLMProvider(steps: [providerStep(broken)]),
            nativeMessages: [["role": "user", "content": "go"]],
            availableTools: tools,
            iteration: 1,
            runToolNames: Set(tools.map(\.name)).union(["save_notes"])
        )
        XCTAssertTrue(isFailure(step), "a broken call to a withheld tool was accepted as the answer")
    }


    /// Fails if the zero-call verdict is cut anywhere between the provider and the
    /// executor: the run must END on the first reply, with that reply as the answer.
    func testNativeRunEndsOnAProseAnswerWithBrackets() async throws {
        let provider = MockLLMProvider(steps: [providerStep(javaArrayAnswer)])
        let input = TestAgentInputFactory.make(
            query: "write maxProfit", tools: tools,
            generatorStrategy: NativeStructuredGenerator(toolTurnAdapter: OllamaToolTurnAdapter()))

        let events = try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 10).execute(model: provider, input: input) { _ in })

        XCTAssertFalse(StreamCollector.hasWarningContaining("Format correction", in: events),
                       "a correct answer was sent back for format correction")
        XCTAssertTrue(StreamCollector.contentText(from: events).contains("{7, 1, 5, 3, 6, 4}"),
                      "the answer must reach the user verbatim")
    }

    /// Executor → generator: a broken call to a tool in the run's loadout must be retried,
    /// never shown as the answer — which needs the executor to pass that loadout through.
    func testTheExecutorPassesTheRunLoadoutToTheVerdict() async throws {
        let broken = #"{"name":"save_notes","content": draft}"#
        let provider = MockLLMProvider(steps: [
            providerStep(broken),
            ModernCognitiveStep(reasoning: "Done.", parseOutcome: .genuineCompletion),
        ])
        let input = TestAgentInputFactory.make(
            query: "analyse", tools: tools + [TestToolFactory.make(name: "save_notes")],
            generatorStrategy: NativeStructuredGenerator(toolTurnAdapter: OllamaToolTurnAdapter()))

        let events = try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 10).execute(model: provider, input: input) { _ in })

        XCTAssertTrue(StreamCollector.hasWarningContaining("Format correction", in: events),
                      "the broken call was not retried")
        XCTAssertFalse(StreamCollector.contentText(from: events).contains("save_notes"),
                       "a broken call was shown to the user as the answer")
    }

    // MARK: - Part 2: consecutive-failure bound (legacy path, failures reach the executor)

    private func failedStep(_ text: String, _ reason: ParseFailureReason) -> ModernCognitiveStep {
        ModernCognitiveStep(reasoning: text, toolCalls: [], parseOutcome: .failed(reason))
    }

    /// If the bound fails to stop the run, this step is requested and becomes the answer.
    private func neverRequested(_ label: String) -> ModernCognitiveStep {
        ModernCognitiveStep(reasoning: "\(label) — must never be requested", parseOutcome: .genuineCompletion)
    }

    private struct Run {
        let events: [AgentStreamEvent]
        let conversationID: UUID
        var content: String { StreamCollector.contentText(from: events) }
        var outcome: ExecutionOutcome? {
            events.compactMap { if case .executionFinished(let outcome, _) = $0 { return outcome }; return nil }.last
        }
        var reason: String? {
            events.compactMap { if case .executionFinished(_, let reason) = $0 { return reason }; return nil }.last ?? nil
        }
    }

    private func runLegacy(
        _ steps: [ModernCognitiveStep],
        tools: [AgentTool]? = nil,
        maxParseFailures: Int? = nil,
        onExhaustion: ExhaustionPolicy = .synthesizeBestEffort
    ) async throws -> Run {
        var input = TestAgentInputFactory.make(
            query: "analyse", tools: tools ?? self.tools,
            errorRecovery: ErrorRecovery(onIterationExhaustion: onExhaustion))
        if let maxParseFailures {
            input.resiliencePolicy = ResolvedResiliencePolicy(
                transport: input.resiliencePolicy.transport,
                cognitive: CognitiveResiliencePolicy(maxParseFailures: maxParseFailures),
                loop: input.resiliencePolicy.loop)
        }
        let events = try await StreamCollector.collect(
            from: ReActAgentExecutor(maxIterations: 20).execute(model: MockLLMProvider(steps: steps), input: input) { _ in })
        return Run(events: events, conversationID: input.conversationID)
    }

    private func lastEpisodeStatus(_ run: Run) async -> EpisodeLifecycle? {
        await SessionGraphStore.shared.getActiveState(for: run.conversationID).episodes.last?.status
    }

    private let malformed = ParseFailureReason.malformedJSON(syntaxDetail: "x", rawSnippet: "x")

    private var brokenCalls: [ModernCognitiveStep] {[
        failedStep(#"{"name":"git","arguments":{"cmd":"#, malformed),
        failedStep(#"{"name":"git","args":"#, malformed),
        failedStep(#"{"name":"git""#, malformed),
    ]}

    /// Example A: three DIFFERENT prose replies the parser rejects → the third is the answer,
    /// flagged — the parser never accepted it.
    /// (The identical-output trigger never fires: no two replies match.)
    func testThreeRephrasedTextFailuresEndWithTheLastReplyAsTheAnswer() async throws {
        let run = try await runLegacy([
            failedStep("Analysis one {7,1}", malformed),
            failedStep("Analysis two {7,1,5}", malformed),
            failedStep("Analysis three {7,1,5,3}", malformed),
            neverRequested("FOURTH"),
        ])
        XCTAssertTrue(run.content.contains("Analysis three"))
        XCTAssertFalse(run.content.contains("FOURTH"))
        XCTAssertTrue(StreamCollector.hasWarningContaining("didn't take after 3 tries", in: run.events))
        XCTAssertEqual(run.outcome, .completedWithWarnings)
    }

    /// Example B: a success in between resets the count — 2 + 2 failures never trip it.
    func testASuccessfulStepResetsTheCount() async throws {
        let reason = ParseFailureReason.noStructuredOutput(snippet: "x")
        let call = ModernCognitiveStep(reasoning: "", toolCalls: [TestToolCallFactory.make(name: "read_file", input: "a")])
        let run = try await runLegacy([
            failedStep("slip 1", reason),
            failedStep("slip 2", reason),
            call,
            failedStep("slip 3", reason),
            failedStep("slip 4", reason),
            ModernCognitiveStep(reasoning: "Real answer.", parseOutcome: .genuineCompletion),
        ])
        XCTAssertTrue(run.content.contains("Real answer."))
        XCTAssertFalse(StreamCollector.hasWarningContaining("didn't take", in: run.events))
    }

    /// Example C: the latest reply is an attempted call → it is never shown; the run stops with
    /// the profile's best-effort response (default "On Budget Exhausted" policy), flagged.
    func testThreeAttemptedCallFailuresStopWithABestEffortResponse() async throws {
        let run = try await runLegacy(brokenCalls + [neverRequested("FOURTH")])
        XCTAssertFalse(run.content.contains("FOURTH"))
        XCTAssertFalse(run.content.contains(#""name":"git""#), "a broken call must never be shown as the answer")
        XCTAssertEqual(run.outcome, .completedWithWarnings)
        XCTAssertTrue(run.reason?.contains("could not be read 3 times in a row") == true, run.reason ?? "nil")
    }

    /// ⚠️ THE WIRING ASSERTION for the stop. Work done before the format failures — files read,
    /// edits made — is still reported. A hard fail (the first version) discarded it.
    func testTheStopStillReportsWhatTheRunFound() async throws {
        let reader = TestToolFactory.make(name: "read_file", output: "maxProfit returns 7")
        let run = try await runLegacy(
            [ModernCognitiveStep(reasoning: "", toolCalls: [TestToolCallFactory.make(name: "read_file", input: "a")])]
                + brokenCalls + [neverRequested("FIFTH")],
            tools: [TestToolFactory.make(name: "final_answer"), reader, TestToolFactory.make(name: "git")])
        XCTAssertTrue(run.content.contains("maxProfit returns 7"), run.content)
        XCTAssertFalse(run.content.contains("FIFTH"))
        XCTAssertEqual(run.outcome, .completedWithWarnings)
    }

    /// "On Budget Exhausted: Fail" applies to the stop too.
    func testAFailHardProfileFailsTheRun() async throws {
        let run = try await runLegacy(brokenCalls + [neverRequested("FOURTH")], onExhaustion: .failHard)
        XCTAssertEqual(run.outcome, .failed)
        XCTAssertFalse(run.content.contains("FOURTH"))
        // A workflow node classifies the run from this text: it must read as a parse failure,
        // not `.modelError` and its "check credentials" advice.
        guard case .consecutiveParseFailures(let count, _) = AgentFailureReason.classify(agentReasonText: run.reason ?? "") else {
            return XCTFail("the stop was not classified as a parse failure: \(run.reason ?? "nil")")
        }
        XCTAssertEqual(count, 3)
    }

    func testBothStopMessagesClassifyAsParseFailures() {
        for identical in [false, true] {
            let text = AgentFailureReason.formatCorrectionsExhaustedMessage(
                count: 4, last: "attempted call '<|python_tag|>' (cut off)", identicalReplies: identical)
            let reason = AgentFailureReason.classify(agentReasonText: text)
            XCTAssertEqual(reason, .consecutiveParseFailures(count: 4, lastError: "attempted call '<|python_tag|>' (cut off)"), text)
            XCTAssertFalse(reason.remediation?.lowercased().contains("credential") ?? true, text)
        }
    }

    /// The stop closes the run's memory episode — the first version returned with it still active.
    func testTheStopClosesTheEpisode() async throws {
        for policy: ExhaustionPolicy in [.synthesizeBestEffort, .failHard] {
            let run = try await runLegacy(brokenCalls, onExhaustion: policy)
            let status = await lastEpisodeStatus(run)
            XCTAssertNotNil(status, "\(policy): no episode recorded")
            XCTAssertNotEqual(status, .active, "\(policy): the episode was left active")
        }
    }

    /// The limit is the profile's "On Parse Failure" setting, not a constant.
    func testTheLimitFollowsTheProfileSetting() async throws {
        let run = try await runLegacy([
            failedStep(#"{"name":"git","arguments":{"cmd":"#, malformed),
            failedStep(#"{"name":"git","args":"#, malformed),
            neverRequested("THIRD"),
        ], maxParseFailures: 2)
        XCTAssertFalse(run.content.contains("THIRD"))
        XCTAssertTrue(StreamCollector.hasWarningContaining("didn't take after 2 tries", in: run.events))
    }

    /// With a higher setting, the byte-identical reply still stops the run at its 4th repeat.
    func testIdenticalRepliesStopEarlyWhenTheSettingIsHigher() async throws {
        let same = failedStep(#"{"name":"git","arguments":{"cmd":"#, malformed)
        let run = try await runLegacy([same, same, same, same, neverRequested("FIFTH")], maxParseFailures: 5)
        XCTAssertFalse(run.content.contains("FIFTH"))
        XCTAssertTrue(run.reason?.contains("same unreadable reply 4 times") == true, run.reason ?? "nil")
    }

    /// Tool-channel failures (an unknown tool) are attempts too — counted, never shown.
    func testUnknownToolFailuresCountAndStop() async throws {
        let reason = ParseFailureReason.unknownToolName(attempted: "save_notes", suggestions: ["remember"])
        let run = try await runLegacy([
            failedStep("I will save the notes.", reason),
            failedStep("Saving the notes now.", reason),
            failedStep("Saving notes.", reason),
            neverRequested("FOURTH"),
        ])
        XCTAssertFalse(run.content.contains("FOURTH"))
        XCTAssertFalse(run.content.contains("Saving notes."), "an unknown-tool attempt must never be shown as the answer")
        XCTAssertEqual(run.outcome, .completedWithWarnings)
    }
}
