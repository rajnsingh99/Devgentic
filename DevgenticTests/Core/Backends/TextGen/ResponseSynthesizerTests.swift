//
//  ResponseSynthesizerTests.swift
//  DevgenticTests
//
//  Fast-path behavior after the final_answer-as-evidence fix: final_answer is a
//  control signal and is no longer recorded into ExecutionSummary.toolResults,
//  so conclusion-only runs must return the answer directly (no IC synthesis),
//  and the deterministic fallback must stay honest about failed evidence.
//
//  Deliberately NO tests for the IC LLM synthesis branch — it requires a loaded
//  IntelligenceCore model and would flake in CI.
//

import XCTest
@testable import devgentic

final class ResponseSynthesizerTests: XCTestCase {

    // MARK: - Conclusion-Only Fast Path (legacy flow)

    /// Regression: a final_answer-only run leaves toolResults empty. Pre-fix this
    /// shape carried a fake "final_answer (Success)" result and took the
    /// single-success deterministic path; post-fix the conclusion-only fast path
    /// must return the answer verbatim WITHOUT attempting IC synthesis.
    func testConclusionOnly_LegacyFlow_ReturnsAnswerDirectly() async {
        var summary = ExecutionSummary(originalGoal: "Say hi")
        summary.finalAgentThought = "Hello! How can I help you today?"
        summary.markComplete() // empty toolResults → .partialSuccess

        let response = await ResponseSynthesizer.synthesize(
            summary: summary,
            originalQuery: "Say hi",
            isNativeFlow: false
        )
        XCTAssertEqual(response, "Hello! How can I help you today?")
    }

    // MARK: - Native Fast Path (unchanged contract)

    func testNativeFastPath_ReturnsFinalThoughtVerbatim() async {
        var summary = ExecutionSummary(originalGoal: "g")
        summary.finalAgentThought = "Direct native answer."
        summary.markComplete()

        let response = await ResponseSynthesizer.synthesize(
            summary: summary,
            originalQuery: "g",
            isNativeFlow: true
        )
        XCTAssertEqual(response, "Direct native answer.")
    }

    // MARK: - R1: Single-Tool Runs Must Not Drop the Final Answer

    /// Regression: after final_answer stopped being recorded as a tool result,
    /// a [tool, final_answer] run reaches Fast Path 1 with count == 1 — pre-fix
    /// it returned the RAW tool output and silently discarded the answer.
    func testSingleToolSuccess_WithFinalAnswer_ReturnsAnswerNotRawOutput() async {
        var summary = ExecutionSummary(originalGoal: "Check the port")
        summary.record(toolCallId: "1", toolName: "read_file", params: "{}",
                       output: "{\"port\": 8080}", isSuccess: true)
        summary.finalAgentThought = "Port 8080 is wrong — it should be 443."
        summary.markComplete()

        let response = await ResponseSynthesizer.synthesize(
            summary: summary,
            originalQuery: "Check the port",
            isNativeFlow: false
        )
        XCTAssertEqual(response, "Port 8080 is wrong — it should be 443.")
    }

    /// Control: single success WITHOUT a final answer keeps the deterministic format.
    func testSingleToolSuccess_NoFinalAnswer_ReturnsFormattedOutput() async {
        var summary = ExecutionSummary(originalGoal: "Read it")
        summary.record(toolCallId: "1", toolName: "read_file", params: "{}",
                       output: "plain file contents", isSuccess: true)
        summary.markComplete()

        let response = await ResponseSynthesizer.synthesize(
            summary: summary,
            originalQuery: "Read it",
            isNativeFlow: false
        )
        XCTAssertEqual(response, "plain file contents")
    }

    // MARK: - R2: Fallback Preserves the Answer

    /// Regression: the .success/.partialSuccess fallback branch dropped
    /// finalAgentThought entirely when IC synthesis was unavailable.
    func testFallback_PartialSuccess_LeadsWithAnswerAndNotesFailures() {
        var summary = ExecutionSummary(originalGoal: "g")
        summary.record(toolCallId: "1", toolName: "search", params: "{}",
                       output: "found 3 results", isSuccess: true)
        summary.record(toolCallId: "2", toolName: "fetch_page", params: "{}",
                       output: "Error: timeout", isSuccess: false, failureCategory: .timeout)
        summary.finalAgentThought = "The top result answers your question: use flag X."
        summary.markComplete()
        XCTAssertEqual(summary.completionStatus, .partialSuccess)

        let text = ResponseSynthesizer.buildDeterministicFallback(summary: summary)
        XCTAssertTrue(text.hasPrefix("The top result answers your question"),
                      "The agent's answer must lead the fallback, got: \(text)")
        XCTAssertTrue(text.contains("fetch_page"), "Evidence failures must be noted")
    }

    /// User denials are decisions, not failures — no failure note for them.
    func testFallback_DenialOnly_NoFailureNote() {
        var summary = ExecutionSummary(originalGoal: "g")
        summary.record(toolCallId: "1", toolName: "search", params: "{}",
                       output: "found it", isSuccess: true)
        summary.record(toolCallId: "2", toolName: "write_file", params: "{}",
                       output: "Denied", isSuccess: false, failureCategory: .userDenied)
        summary.finalAgentThought = "Done — here's the summary."
        summary.markComplete()
        XCTAssertEqual(summary.completionStatus, .success,
                       "A denial must not demote an otherwise-successful run")

        let text = ResponseSynthesizer.buildDeterministicFallback(summary: summary)
        XCTAssertTrue(text.hasPrefix("Done — here's the summary."))
        XCTAssertFalse(text.contains("did not succeed"), "Denials are not failures")
    }

    // MARK: - Cross-consumer: all-failed run surfaces a framed failure, not raw errors

    /// Regression (verifier cross-consumer finding): a run whose only content is a
    /// failureReason digest of internal "Error:" strings (Planning all-subtasks-fail)
    /// must not echo them as an answer — the fallback frames them as a failure.
    func testFallback_NoThoughtNoSuccess_SurfacesFramedFailureReason() {
        var summary = ExecutionSummary(originalGoal: "Do plan")
        // No tool results recorded, no finalAgentThought — mirrors Planning all-fail.
        summary.markComplete(failureReason: "Error: The operation couldn't be completed.\nError: capability disabled")
        let text = ResponseSynthesizer.buildDeterministicFallback(summary: summary)
        XCTAssertTrue(text.hasPrefix("I couldn't complete the task"),
                      "All-failed run must read as a failure, not an answer; got: \(text)")
        XCTAssertTrue(text.contains("capability disabled"))
    }

    // MARK: - Deterministic Fallback (failed evidence)

    /// Native flow with NO final thought and all-failed evidence falls to the
    /// deterministic fallback, which must name the failed tools (honest framing)
    /// and — with no claim present — must NOT emit the unverified-conclusion line.
    func testFallback_AllEvidenceFailed_NoThought_NamesFailedTools() async {
        var summary = ExecutionSummary(originalGoal: "List files")
        summary.record(toolCallId: "1", toolName: "list_directory", params: "{}",
                       output: "Error: no such file", isSuccess: false)
        summary.record(toolCallId: "2", toolName: "list_directory", params: "{}",
                       output: "Error: no such file", isSuccess: false)
        summary.markComplete() // all failed → .failed (post markComplete fix)

        let response = await ResponseSynthesizer.synthesize(
            summary: summary,
            originalQuery: "List files",
            isNativeFlow: true // no finalAgentThought → PATH A deterministic fallback
        )
        XCTAssertTrue(response.contains("did not succeed"), "Fallback must state the failure")
        XCTAssertTrue(response.contains("list_directory"), "Fallback must name the failed tool")
        XCTAssertFalse(response.contains("Unverified conclusion"), "No claim recorded → no caveat line")
    }

    // MARK: - Wrapper-Run Suppression (no IC synthesis in Planning/Reflexion inner loops)

    /// A multi-tool summary takes the IC LLM path by default. Wrapper-run inner
    /// loops (Planning subtasks, Reflexion trials) pass `suppressLLM: true` and
    /// must route to the deterministic builder instead — even under
    /// `forceSynthesis: true` (the circuit-breaker abort path), which otherwise
    /// always attempts an IC load.
    func testSuppressLLM_MultiToolRun_UsesDeterministicBuilder_EvenWhenForced() async {
        var summary = ExecutionSummary(originalGoal: "Do two things")
        summary.record(toolCallId: "1", toolName: "step_one", params: "{}",
                       output: "first result", isSuccess: true)
        summary.record(toolCallId: "2", toolName: "step_two", params: "{}",
                       output: "second result", isSuccess: true)
        summary.markComplete()

        let expected = ResponseSynthesizer.buildDeterministicFallback(summary: summary)
        let response = await ResponseSynthesizer.synthesize(
            summary: summary,
            originalQuery: "Do two things",
            isNativeFlow: false,
            forceSynthesis: true,
            suppressLLM: true
        )
        XCTAssertEqual(response, expected, "Suppressed runs must use the deterministic builder, never IC")
    }

    /// Suppression must NOT disturb the free paths: a native-flow run with a final
    /// thought still returns the model's own answer verbatim.
    func testSuppressLLM_NativeFastPath_Unaffected() async {
        var summary = ExecutionSummary(originalGoal: "g")
        summary.finalAgentThought = "Direct native answer."
        summary.markComplete()

        let response = await ResponseSynthesizer.synthesize(
            summary: summary,
            originalQuery: "g",
            isNativeFlow: true,
            suppressLLM: true
        )
        XCTAssertEqual(response, "Direct native answer.")
    }
}
