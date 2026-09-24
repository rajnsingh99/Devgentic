// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CognitiveCircuitBreakerTests.swift
//  DevgenticTests
//
//  Tests for CognitiveCircuitBreaker. Contract under test (post G2/G3 + audit #3):
//  - Iteration-level fingerprint: warn (.proceedWithWarning) on the 2nd identical
//    iteration, abort on the 3rd.
//  - Global per-tool frequency: 3× same tool+args+output across ANY iterations
//    aborts — catches alternating-combo evasion; checked BEFORE the warning tier
//    so aborts outrank warnings.
//  - primeReplayedIteration: G1-resume priming counts toward caps without emitting actions.
//    (evaluateAskUser/idle counters were REMOVED — clarification loops are governed by
//    RunInteractionMemory replay + the repetition fingerprint, not a dedicated counter.)
//  - Hooks without production callers (evaluateToolAttempt, evaluateMemoryHydration,
//    recordClarificationResponse) were removed in the audit-#3 cleanup.
//

import XCTest
@testable import devgentic

final class CognitiveCircuitBreakerTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a mock ToolObservation with the given parameters.
    private func makeObservation(
        toolName: String,
        params: String = "{}",
        output: String = "mock output",
        isSuccess: Bool = true
    ) -> ToolObservation {
        ToolObservation(
            stepId: 1,
            toolCallId: UUID().uuidString,
            toolName: toolName,
            result: output,
            summary: isSuccess ? "Succeeded" : "Failed",
            isSuccess: isSuccess,
            params: params,
            output: output,
            artifacts: []
        )
    }

    // MARK: - Repetitive Action Detection

    func testRepetitiveActions_UniqueObservations_Proceeds() {
        var breaker = CognitiveCircuitBreaker()

        let action1 = breaker.evaluateRepetitiveActions([makeObservation(toolName: "list_directory", output: "file1.txt")])
        let action2 = breaker.evaluateRepetitiveActions([makeObservation(toolName: "read_file", output: "contents")])
        let action3 = breaker.evaluateRepetitiveActions([makeObservation(toolName: "fs_smart_search", output: "found it")])

        if case .proceed = action1 {} else { XCTFail("Expected .proceed for unique action 1") }
        if case .proceed = action2 {} else { XCTFail("Expected .proceed for unique action 2") }
        if case .proceed = action3 {} else { XCTFail("Expected .proceed for unique action 3") }
    }

    func testRepetitiveActions_WarningAtSecondIdenticalIteration() {
        // G2 dual-channel warning: the 2nd identical iteration warns (UI + model
        // alert) so the model can course-correct before the 3rd-strike abort.
        var breaker = CognitiveCircuitBreaker()
        let identicalObs = [makeObservation(toolName: "fs_smart_search", output: "No results")]

        _ = breaker.evaluateRepetitiveActions(identicalObs)
        let action2 = breaker.evaluateRepetitiveActions(identicalObs)

        if case .proceedWithWarning(let uiMessage, let modelAlert) = action2 {
            XCTAssertTrue(uiMessage.contains("fs_smart_search"), "UI warning should name the tool")
            XCTAssertTrue(modelAlert.contains("final_answer"), "Model alert should offer the final_answer escape hatch")
        } else {
            XCTFail("Expected .proceedWithWarning on 2nd identical iteration, got \(action2)")
        }
    }

    func testRepetitiveActions_IdenticalObservations_AbortsAtThreshold() {
        var breaker = CognitiveCircuitBreaker()
        let identicalObs = [makeObservation(toolName: "fs_smart_search", params: "{\"search_term\":\"\"}", output: "No results found matching ''.")]

        let action1 = breaker.evaluateRepetitiveActions(identicalObs)
        let action2 = breaker.evaluateRepetitiveActions(identicalObs)
        let action3 = breaker.evaluateRepetitiveActions(identicalObs)

        if case .proceed = action1 {} else { XCTFail("Expected .proceed on 1st occurrence") }
        if case .proceedWithWarning = action2 {} else { XCTFail("Expected .proceedWithWarning on 2nd occurrence, got \(action2)") }

        // 3rd identical iteration should abort
        if case .abort(let trigger) = action3 {
            XCTAssertTrue(trigger.reason.contains("fs_smart_search"), "Abort reason should mention the tool name")
            XCTAssertTrue(trigger.reason.contains("3"), "Abort reason should mention the count")
        } else {
            XCTFail("Expected .abort on 3rd identical iteration, got \(action3)")
        }
    }

    func testRepetitiveActions_BreaksWhenOutputChanges() {
        var breaker = CognitiveCircuitBreaker()
        let emptyResult = [makeObservation(toolName: "fs_smart_search", output: "No results")]
        let successResult = [makeObservation(toolName: "fs_smart_search", output: "Found: document.pdf")]

        _ = breaker.evaluateRepetitiveActions(emptyResult) // 1st
        _ = breaker.evaluateRepetitiveActions(emptyResult) // 2nd (warns)

        // Now a different output — fingerprint counter resets, no warning
        let action3 = breaker.evaluateRepetitiveActions(successResult)
        if case .proceed = action3 {} else { XCTFail("Expected .proceed after output changed, got \(action3)") }

        // 2nd occurrence of the new pattern → warning tier again, not abort
        let action4 = breaker.evaluateRepetitiveActions(successResult)
        if case .proceedWithWarning = action4 {} else { XCTFail("Expected .proceedWithWarning on 2nd occurrence of new pattern, got \(action4)") }
    }

    func testRepetitiveActions_MultipleToolsSameIteration() {
        var breaker = CognitiveCircuitBreaker()
        let multiToolObs = [
            makeObservation(toolName: "fs_smart_search", output: "No results"),
            makeObservation(toolName: "recall_conversation_history", output: "No context found")
        ]

        let action1 = breaker.evaluateRepetitiveActions(multiToolObs)
        let action2 = breaker.evaluateRepetitiveActions(multiToolObs)
        let action3 = breaker.evaluateRepetitiveActions(multiToolObs)

        if case .proceed = action1 {} else { XCTFail("Expected .proceed on 1st") }
        if case .proceedWithWarning = action2 {} else { XCTFail("Expected .proceedWithWarning on 2nd, got \(action2)") }
        if case .abort = action3 {
            // pass — multi-tool repetition also detected
        } else {
            XCTFail("Expected .abort on 3rd identical multi-tool iteration")
        }
    }

    func testRepetitiveActions_AlternatingEvasion_CaughtByGlobalLimit() {
        // A model that interleaves a different action to reset the iteration-level
        // fingerprint still trips the global per-tool cap: the same tool+args+output
        // appearing 3× across ANY iterations aborts. (This pattern used to slip
        // through before the G3 global-frequency check.)
        var breaker = CognitiveCircuitBreaker()
        let obs1 = [makeObservation(toolName: "fs_smart_search", output: "No results")]

        _ = breaker.evaluateRepetitiveActions(obs1) // global count 1
        _ = breaker.evaluateRepetitiveActions(obs1) // global count 2 (warns)

        // Interrupt with a different tool — resets the iteration counter only
        _ = breaker.evaluateRepetitiveActions([makeObservation(toolName: "list_directory", output: "/Users/alice")])

        // Back to obs1: 3rd global occurrence → abort despite the interruption
        let action4 = breaker.evaluateRepetitiveActions(obs1)
        if case .abort(let trigger) = action4 {
            XCTAssertTrue(trigger.reason.contains("fs_smart_search"), "Abort should name the repeated tool, got: \(trigger.reason)")
            XCTAssertTrue(trigger.reason.contains("3"), "Abort should mention the global count, got: \(trigger.reason)")
        } else {
            XCTFail("Expected .abort via global frequency cap on 3rd occurrence, got \(action4)")
        }
    }

    func testGlobalToolFrequency_AbortOutranksWarning() {
        // The global check runs BEFORE the limit-1 warning tier. Construct an
        // iteration that sits exactly on the warning tier (2nd identical multi-tool
        // fingerprint) while a tool inside it hits the global cap (3rd occurrence):
        // the abort must win. Under the old ordering this returned the warning and
        // masked the abort until the next iteration.
        var breaker = CognitiveCircuitBreaker()
        let coreObs = makeObservation(toolName: "read_file", params: "{\"path\":\"a.txt\"}", output: "contents")
        let extraObs = makeObservation(toolName: "list_dir", output: "files")

        _ = breaker.evaluateRepetitiveActions([coreObs])            // core global 1
        _ = breaker.evaluateRepetitiveActions([coreObs, extraObs])  // core global 2, new fingerprint (counter 1)
        let action3 = breaker.evaluateRepetitiveActions([coreObs, extraObs]) // core global 3, fingerprint counter 2 (warning tier)

        if case .abort(let trigger) = action3 {
            XCTAssertTrue(trigger.reason.contains("read_file"), "Abort should mention the capped tool, got: \(trigger.reason)")
            XCTAssertTrue(trigger.reason.contains("3"), "Abort should mention the count, got: \(trigger.reason)")
        } else {
            XCTFail("Expected global-cap .abort to outrank the fingerprint warning, got \(action3)")
        }
    }

    // MARK: - Hallucination Tracking

    func testRecordHallucination_TracksToolName() {
        var breaker = CognitiveCircuitBreaker()
        breaker.recordHallucination("fake_tool")
        XCTAssertTrue(breaker.hallucinatedTools.contains("fake_tool"))
        XCTAssertFalse(breaker.hallucinatedTools.contains("real_tool"))
    }

    // MARK: - Replay Priming (G1 resume)

    /// Priming replayed iterations must count toward the global per-tool cap exactly like live
    /// evaluation: two replayed identical iterations + one live one hit the cap (3) and abort.
    func testPrimeReplayedIteration_CountsTowardGlobalCap() {
        var breaker = CognitiveCircuitBreaker(maxRepetitiveActions: 3)
        let obs = [makeObservation(toolName: "read_file", params: "{\"path\":\"/a\"}", output: "same")]

        breaker.primeReplayedIteration(obs)   // count 1 (silent)
        breaker.primeReplayedIteration(obs)   // count 2 (silent)

        let action = breaker.evaluateRepetitiveActions(obs)   // count 3 → abort
        if case .abort(let trigger) = action {
            XCTAssertTrue(trigger.reason.contains("read_file"), "Abort should mention the capped tool, got: \(trigger.reason)")
        } else {
            XCTFail("Expected .abort after 2 primed + 1 live identical call, got \(action)")
        }
    }

    /// Priming never returns an action — it only restores counters (the original run already
    /// reacted to those iterations), so a resumed run with sub-cap history proceeds normally.
    func testPrimeReplayedIteration_SubCapHistoryProceeds() {
        var breaker = CognitiveCircuitBreaker(maxRepetitiveActions: 3)
        let obs = [makeObservation(toolName: "read_file", params: "{\"path\":\"/a\"}", output: "same")]

        breaker.primeReplayedIteration(obs)   // count 1

        let fresh = [makeObservation(toolName: "list_directory", params: "{\"path\":\"/b\"}", output: "listing")]
        let action = breaker.evaluateRepetitiveActions(fresh)
        if case .proceed = action {} else {
            XCTFail("Expected .proceed for a non-repeated live call after sub-cap priming, got \(action)")
        }
    }

    // MARK: - Tool Result Recording

    func testRecordToolResult_SuccessResetsConsecutiveFailures() {
        var breaker = CognitiveCircuitBreaker()
        _ = breaker.recordToolResult(isSuccess: false)  // failures = 1
        _ = breaker.recordToolResult(isSuccess: false)  // failures = 2
        _ = breaker.recordToolResult(isSuccess: true)   // failures = 0
        XCTAssertEqual(breaker.consecutiveToolFailures, 0)
    }

    func testRecordToolResult_AbortsAtConsecutiveFailureLimit() {
        var breaker = CognitiveCircuitBreaker(maxConsecutiveToolFailures: 3)
        _ = breaker.recordToolResult(isSuccess: false)
        _ = breaker.recordToolResult(isSuccess: false)
        let action = breaker.recordToolResult(isSuccess: false)

        if case .abort(let trigger) = action {
            XCTAssertTrue(trigger.reason.contains("3") || trigger.reason.contains("consecutive"),
                          "Abort reason should mention failure count")
        } else {
            XCTFail("Expected .abort on 3rd consecutive failure, got \(action)")
        }
    }
}
