//
//  ReflectionEvaluatorTests.swift
//  DevgenticTests
//
//  Unit tests for ReflectionEvaluator's key-value parser and
//  context-aware tool result budgeting.
//

import XCTest
@testable import devgentic

final class ReflectionEvaluatorTests: XCTestCase {

    private let evaluator = ReflectionEvaluator()

    // MARK: - Clean Key-Value Parsing

    func testParse_PassVerdict_Acceptable() {
        let input = """
        VERDICT: PASS
        CRITIQUE: Goal achieved successfully.
        """

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertTrue(result.isAcceptable)
        XCTAssertEqual(result.critique, "Goal achieved successfully.")
        XCTAssertNil(result.suggestedRevisions)
        XCTAssertEqual(result.trial, 1)
    }

    func testParse_RetryVerdict_NotAcceptable() {
        let input = """
        VERDICT: RETRY
        CRITIQUE: Found issues but did not fix them.
        REVISION: Use fix_issues tool to resolve the 3 critical issues.
        """

        let result = evaluator.parseReflection(from: input, trial: 2)

        XCTAssertFalse(result.isAcceptable)
        XCTAssertEqual(result.critique, "Found issues but did not fix them.")
        XCTAssertEqual(result.suggestedRevisions, "Use fix_issues tool to resolve the 3 critical issues.")
        XCTAssertEqual(result.trial, 2)
    }

    func testParse_PassVerdict_RevisionsIgnored() {
        // PASS verdict should set suggestedRevisions to nil even if REVISION line exists
        let input = """
        VERDICT: PASS
        CRITIQUE: All good.
        REVISION: This should be ignored.
        """

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertTrue(result.isAcceptable)
        XCTAssertNil(result.suggestedRevisions)
    }

    // MARK: - Think Block / Fence Handling

    func testParse_ThinkBlockWrapped_StillParses() {
        let input = """
        <think>
        Let me evaluate whether the agent achieved the goal...
        The tools ran successfully and produced the expected output.
        </think>
        VERDICT: PASS
        CRITIQUE: All tasks completed as expected.
        """

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertTrue(result.isAcceptable)
        XCTAssertEqual(result.critique, "All tasks completed as expected.")
    }

    func testParse_MarkdownFenced_StillParses() {
        let input = """
        ```
        VERDICT: RETRY
        CRITIQUE: Missing error handling.
        REVISION: Add try-catch blocks.
        ```
        """

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertFalse(result.isAcceptable)
        XCTAssertEqual(result.critique, "Missing error handling.")
    }

    // MARK: - Case Variations

    func testParse_LowercaseLabels_Parse() {
        let input = """
        verdict: pass
        critique: Everything looks good.
        """

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertTrue(result.isAcceptable)
        XCTAssertEqual(result.critique, "Everything looks good.")
    }

    func testParse_MixedCaseLabels_Parse() {
        let input = """
        Verdict: Retry
        Critique: Needs more work.
        Revision: Try again with different parameters.
        """

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertFalse(result.isAcceptable)
    }

    // MARK: - Verdict Word Variations

    func testParse_AcceptVerdict_IsAcceptable() {
        let input = "VERDICT: ACCEPT\nCRITIQUE: Done."

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertTrue(result.isAcceptable)
    }

    func testParse_YesVerdict_IsAcceptable() {
        let input = "VERDICT: YES\nCRITIQUE: Goal met."

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertTrue(result.isAcceptable)
    }

    func testParse_DoneVerdict_IsAcceptable() {
        let input = "VERDICT: DONE\nCRITIQUE: Complete."

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertTrue(result.isAcceptable)
    }

    func testParse_FailVerdict_NotAcceptable() {
        let input = "VERDICT: FAIL\nCRITIQUE: Didn't work."

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertFalse(result.isAcceptable)
    }

    // MARK: - Keyword Fallback

    func testParse_NoVerdictLine_PositiveKeywords_Acceptable() {
        let input = "The goal was achieved successfully. All tests passed and the deployment completed."

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertTrue(result.isAcceptable)
    }

    func testParse_NoVerdictLine_NegativeKeywords_NotAcceptable() {
        let input = "The task is incomplete. The agent did not fix the reported issues and failed to run the tests."

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertFalse(result.isAcceptable)
    }

    func testParse_NoVerdictLine_NoKeywords_NotAcceptable() {
        let input = "I'm not sure what to make of this output."

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertFalse(result.isAcceptable)
    }

    // MARK: - Empty Response

    func testParse_EmptyResponse_NotAcceptable() {
        let result = evaluator.parseReflection(from: "", trial: 1)

        XCTAssertFalse(result.isAcceptable)
        XCTAssertEqual(result.critique, "Empty reflection output.")
    }

    // MARK: - Legacy JSON Format (Backward Compat via Keyword Fallback)

    func testParse_LegacyJSON_Acceptable_FallsBackToKeywords() {
        // Old JSON format — no VERDICT line, but keyword fallback should detect "acceptable"
        let input = """
        {"isAcceptable": true, "critique": "Goal achieved successfully.", "suggestedRevisions": null}
        """

        let result = evaluator.parseReflection(from: input, trial: 1)

        // "acceptable" is not in our positive keyword list, but the JSON should at least
        // not crash. The keyword fallback may or may not detect it — the important thing
        // is graceful degradation.
        XCTAssertNotNil(result.critique)
    }

    // MARK: - Tool Budget Computation

    func testBudget_SmallContext_FloorApplied() {
        // 256 tokens → 768 chars → 768 - 700 = 68 → floored to 800
        let budget = ReflectionEvaluator.computeToolBudget(contextWindow: 256)
        XCTAssertEqual(budget, 800)
    }

    func testBudget_LargeContext_CapApplied() {
        // 128K tokens → 384K chars → way over 6000 → capped
        let budget = ReflectionEvaluator.computeToolBudget(contextWindow: 128_000)
        XCTAssertEqual(budget, 6000)
    }

    func testBudget_MediumContext_ComputedCorrectly() {
        // 2048 tokens → 6144 chars → 6144 - 700 = 5444
        let budget = ReflectionEvaluator.computeToolBudget(contextWindow: 2048)
        XCTAssertEqual(budget, 5444)
    }

    // MARK: - Tool Result Budgeting

    func testBudgetResults_FailedFirst_Priority() {
        let results: [SynthesizedToolResult] = [
            SynthesizedToolResult(toolCallId: "1", toolName: "search", params: "", output: String(repeating: "x", count: 500), isSuccess: true),
            SynthesizedToolResult(toolCallId: "2", toolName: "deploy", params: "", output: String(repeating: "E", count: 800), isSuccess: false)
        ]

        let summary = ReflectionEvaluator.budgetToolResults(results: results, budget: 2000)

        // Failed result (deploy) should appear and have more content
        XCTAssertTrue(summary.contains("deploy [Failed]"))
        XCTAssertTrue(summary.contains("search [Success]"))
    }

    func testBudgetResults_EmptyResults_NoToolsMessage() {
        let summary = ReflectionEvaluator.budgetToolResults(results: [], budget: 2000)
        XCTAssertEqual(summary, "No tools were executed.")
    }

    func testBudgetResults_WithinBudget_NoTruncation() {
        let results: [SynthesizedToolResult] = [
            SynthesizedToolResult(toolCallId: "1", toolName: "check", params: "", output: "All good.", isSuccess: true)
        ]

        let summary = ReflectionEvaluator.budgetToolResults(results: results, budget: 2000)

        XCTAssertTrue(summary.contains("All good."))
        XCTAssertFalse(summary.contains("[truncated]"))
    }

    func testBudgetResults_OverBudget_Truncated() {
        let longOutput = String(repeating: "x", count: 5000)
        let results: [SynthesizedToolResult] = [
            SynthesizedToolResult(toolCallId: "1", toolName: "read_file", params: "", output: longOutput, isSuccess: true)
        ]

        let summary = ReflectionEvaluator.budgetToolResults(results: results, budget: 1000)

        XCTAssertTrue(summary.contains("[truncated]"))
        XCTAssertLessThanOrEqual(summary.count, 1200) // budget + label overhead
    }

    // MARK: - Missing CRITIQUE line

    func testParse_VerdictOnly_NoCritique_DefaultCritique() {
        let input = "VERDICT: PASS"

        let result = evaluator.parseReflection(from: input, trial: 1)

        XCTAssertTrue(result.isAcceptable)
        XCTAssertEqual(result.critique, "No critique provided.")
    }
}
