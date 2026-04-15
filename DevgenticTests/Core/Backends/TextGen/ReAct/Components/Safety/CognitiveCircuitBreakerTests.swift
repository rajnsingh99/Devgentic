//
//  CognitiveCircuitBreakerTests.swift
//  DevgenticTests
//
//  Tests for CognitiveCircuitBreaker — Gap B: Repetitive Action Detection.
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

    func testRepetitiveActions_IdenticalObservations_AbortsAtThreshold() {
        var breaker = CognitiveCircuitBreaker()
        let identicalObs = [makeObservation(toolName: "fs_smart_search", params: "{\"search_term\":\"\"}", output: "No results found matching ''.")]

        let action1 = breaker.evaluateRepetitiveActions(identicalObs)
        let action2 = breaker.evaluateRepetitiveActions(identicalObs)
        let action3 = breaker.evaluateRepetitiveActions(identicalObs)

        if case .proceed = action1 {} else { XCTFail("Expected .proceed on 1st occurrence") }
        if case .proceed = action2 {} else { XCTFail("Expected .proceed on 2nd occurrence") }

        // 3rd identical iteration should abort
        if case .abort(let reason) = action3 {
            XCTAssertTrue(reason.contains("fs_smart_search"), "Abort reason should mention the tool name")
            XCTAssertTrue(reason.contains("3"), "Abort reason should mention the count")
        } else {
            XCTFail("Expected .abort on 3rd identical iteration, got \(action3)")
        }
    }

    func testRepetitiveActions_BreaksWhenOutputChanges() {
        var breaker = CognitiveCircuitBreaker()
        let emptyResult = [makeObservation(toolName: "fs_smart_search", output: "No results")]
        let successResult = [makeObservation(toolName: "fs_smart_search", output: "Found: document.pdf")]

        _ = breaker.evaluateRepetitiveActions(emptyResult) // 1st
        _ = breaker.evaluateRepetitiveActions(emptyResult) // 2nd

        // Now a different output — should reset the counter
        let action3 = breaker.evaluateRepetitiveActions(successResult)
        if case .proceed = action3 {} else { XCTFail("Expected .proceed after output changed") }

        // One more identical (successResult) should be fine
        let action4 = breaker.evaluateRepetitiveActions(successResult)
        if case .proceed = action4 {} else { XCTFail("Expected .proceed on 2nd occurrence of new pattern") }
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
        if case .proceed = action2 {} else { XCTFail("Expected .proceed on 2nd") }
        if case .abort = action3 {
            // pass — multi-tool repetition also detected
        } else {
            XCTFail("Expected .abort on 3rd identical multi-tool iteration")
        }
    }

    func testRepetitiveActions_CounterResetAfterDifferentAction() {
        var breaker = CognitiveCircuitBreaker()
        let obs1 = [makeObservation(toolName: "fs_smart_search", output: "No results")]

        _ = breaker.evaluateRepetitiveActions(obs1) // 1
        _ = breaker.evaluateRepetitiveActions(obs1) // 2

        // Interrupt with a different tool
        _ = breaker.evaluateRepetitiveActions([makeObservation(toolName: "list_directory", output: "/Users/alice")])

        // Back to obs1 — counter should have reset
        let action4 = breaker.evaluateRepetitiveActions(obs1) // 1 (reset)
        let action5 = breaker.evaluateRepetitiveActions(obs1) // 2
        if case .proceed = action4 {} else { XCTFail("Expected .proceed after counter reset") }
        if case .proceed = action5 {} else { XCTFail("Expected .proceed on 2nd after reset") }

        // Now 3rd consecutive — should abort
        let action6 = breaker.evaluateRepetitiveActions(obs1) // 3
        if case .abort = action6 {} else { XCTFail("Expected .abort on 3rd consecutive") }
    }

    // MARK: - Existing Behavior Preserved

    func testToolRetries_StillWorksAfterRepetitiveAddition() {
        var breaker = CognitiveCircuitBreaker()

        // evaluateToolAttempt should still work independently
        let action1 = breaker.evaluateToolAttempt(toolName: "read_file", paramsHash: 123)
        let action2 = breaker.evaluateToolAttempt(toolName: "read_file", paramsHash: 123)
        let action3 = breaker.evaluateToolAttempt(toolName: "read_file", paramsHash: 123)

        if case .proceed = action1 {} else { XCTFail("Expected .proceed on 1st attempt") }
        if case .proceed = action2 {} else { XCTFail("Expected .proceed on 2nd attempt") }
        if case .intervene = action3 {
            // pass — existing behavior preserved
        } else {
            XCTFail("Expected .intervene on 3rd attempt with same params")
        }
    }

    // MARK: - Ask User Evaluation

    func testEvaluateAskUser_ProceedsBelowLimit() {
        var breaker = CognitiveCircuitBreaker(maxConsecutiveAskUser: 3, maxConsecutiveIdle: 5)
        let action = breaker.evaluateAskUser()
        if case .proceed = action {} else {
            XCTFail("Expected .proceed on first ask_user call, got \(action)")
        }
    }

    func testEvaluateAskUser_IntervenesAtAskUserLimit() {
        var breaker = CognitiveCircuitBreaker(maxConsecutiveAskUser: 2, maxConsecutiveIdle: 10)

        // 2 calls within limit
        _ = breaker.evaluateAskUser()
        _ = breaker.evaluateAskUser()

        // 3rd exceeds maxConsecutiveAskUser (2)
        let action = breaker.evaluateAskUser()
        if case .intervene(let msg) = action {
            XCTAssertTrue(msg.contains("ask_user") || msg.contains("asked the user"),
                          "Intervene message should mention ask_user")
        } else {
            XCTFail("Expected .intervene on exceeding ask_user limit, got \(action)")
        }
    }

    func testEvaluateAskUser_AbortsAtIdleLimit() {
        // maxConsecutiveIdle < maxConsecutiveAskUser, so idle abort fires first
        var breaker = CognitiveCircuitBreaker(maxConsecutiveAskUser: 10, maxConsecutiveIdle: 3)

        _ = breaker.evaluateAskUser() // idle = 1
        _ = breaker.evaluateAskUser() // idle = 2
        let action = breaker.evaluateAskUser() // idle = 3 → abort

        if case .abort(let reason) = action {
            XCTAssertTrue(reason.contains("idle"), "Abort reason should mention idle steps")
        } else {
            XCTFail("Expected .abort at idle limit, got \(action)")
        }
    }

    // MARK: - Memory Hydration Evaluation

    func testEvaluateMemoryHydration_ProceedsBelowLimit() {
        var breaker = CognitiveCircuitBreaker(maxConsecutiveIdle: 5)
        let action = breaker.evaluateMemoryHydration()
        if case .proceed = action {} else {
            XCTFail("Expected .proceed on first memory hydration, got \(action)")
        }
    }

    func testEvaluateMemoryHydration_AbortsAtIdleLimit() {
        var breaker = CognitiveCircuitBreaker(maxConsecutiveIdle: 2)
        _ = breaker.evaluateMemoryHydration() // idle = 1
        let action = breaker.evaluateMemoryHydration() // idle = 2 → abort

        if case .abort(let reason) = action {
            XCTAssertTrue(reason.contains("idle") || reason.contains("memory"),
                          "Abort should mention idle or memory")
        } else {
            XCTFail("Expected .abort at idle limit for memory hydration, got \(action)")
        }
    }

    // MARK: - Clarification Response

    func testRecordClarificationResponse_VagueTwice_Intervenes() {
        var breaker = CognitiveCircuitBreaker()
        _ = breaker.recordClarificationResponse(isVague: true)  // friction = 1
        let action = breaker.recordClarificationResponse(isVague: true)  // friction = 2

        if case .intervene(let msg) = action {
            XCTAssertTrue(msg.contains("vague") || msg.contains("specific"),
                          "Should ask for specific data")
        } else {
            XCTFail("Expected .intervene on 2nd vague response, got \(action)")
        }
    }

    func testRecordClarificationResponse_VagueThenClear_Resets() {
        var breaker = CognitiveCircuitBreaker()
        _ = breaker.recordClarificationResponse(isVague: true)   // friction = 1
        _ = breaker.recordClarificationResponse(isVague: false)  // friction = 0

        // Next vague should be treated as first vague (friction starts at 1 again)
        let action = breaker.recordClarificationResponse(isVague: true)  // friction = 1
        if case .proceed = action {} else {
            XCTFail("Expected .proceed after friction reset, got \(action)")
        }
    }

    func testRecordClarificationResponse_ClearAlways_Proceeds() {
        var breaker = CognitiveCircuitBreaker()
        let action = breaker.recordClarificationResponse(isVague: false)
        if case .proceed = action {} else {
            XCTFail("Expected .proceed for clear response, got \(action)")
        }
        XCTAssertEqual(breaker.clarificationFriction, 0)
    }

    // MARK: - Global Tool Frequency

    func testGlobalToolFrequency_AbortsAtGlobalLimit() {
        var breaker = CognitiveCircuitBreaker()

        // The global frequency limit is 5 (maxGlobalToolRepetitions).
        // We need the SAME tool+args+output combo to appear 5 times across iterations.
        // To avoid triggering iteration-level fingerprint (maxRepetitiveActions=3),
        // we alternate the iteration fingerprint by adding a different secondary tool.
        let coreObs = makeObservation(toolName: "read_file", params: "{\"path\":\"a.txt\"}", output: "contents")

        // Iterations 1-2: same fingerprint (core only)
        _ = breaker.evaluateRepetitiveActions([coreObs])
        _ = breaker.evaluateRepetitiveActions([coreObs])

        // Iteration 3: different fingerprint (core + extra)
        let extraObs = makeObservation(toolName: "list_dir", output: "files")
        _ = breaker.evaluateRepetitiveActions([coreObs, extraObs])

        // Iteration 4: back to core only (resets iteration counter)
        _ = breaker.evaluateRepetitiveActions([coreObs])

        // Iteration 5: core appears for 5th time globally → should abort
        let action = breaker.evaluateRepetitiveActions([coreObs])

        if case .abort(let reason) = action {
            XCTAssertTrue(reason.contains("read_file") || reason.contains("5"),
                          "Abort should mention tool name or count, got: \(reason)")
        } else {
            XCTFail("Expected .abort on 5th global repetition, got \(action)")
        }
    }

    // MARK: - Hallucination Tracking

    func testRecordHallucination_TracksToolName() {
        var breaker = CognitiveCircuitBreaker()
        breaker.recordHallucination("fake_tool")
        XCTAssertTrue(breaker.hallucinatedTools.contains("fake_tool"))
        XCTAssertFalse(breaker.hallucinatedTools.contains("real_tool"))
    }

    // MARK: - Reset

    func testResetCountersOnSuccess_ResetsAskUserAndIdle() {
        var breaker = CognitiveCircuitBreaker(maxConsecutiveAskUser: 10, maxConsecutiveIdle: 10)
        _ = breaker.evaluateAskUser()  // askUser = 1, idle = 1
        _ = breaker.evaluateAskUser()  // askUser = 2, idle = 2
        XCTAssertGreaterThan(breaker.consecutiveAskUserCalls, 0)
        XCTAssertGreaterThan(breaker.consecutiveIdleSteps, 0)

        breaker.resetCountersOnSuccess()
        XCTAssertEqual(breaker.consecutiveAskUserCalls, 0)
        XCTAssertEqual(breaker.consecutiveIdleSteps, 0)
        XCTAssertEqual(breaker.clarificationFriction, 0)
    }

    // MARK: - Tool Attempt Evaluation

    func testEvaluateToolAttempt_DifferentParams_Proceeds() {
        var breaker = CognitiveCircuitBreaker()
        let action1 = breaker.evaluateToolAttempt(toolName: "read_file", paramsHash: 100)
        let action2 = breaker.evaluateToolAttempt(toolName: "read_file", paramsHash: 200)
        let action3 = breaker.evaluateToolAttempt(toolName: "read_file", paramsHash: 300)

        if case .proceed = action1 {} else { XCTFail("Expected .proceed for unique params") }
        if case .proceed = action2 {} else { XCTFail("Expected .proceed for unique params") }
        if case .proceed = action3 {} else { XCTFail("Expected .proceed for unique params") }
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

        if case .abort(let reason) = action {
            XCTAssertTrue(reason.contains("3") || reason.contains("consecutive"),
                          "Abort reason should mention failure count")
        } else {
            XCTFail("Expected .abort on 3rd consecutive failure, got \(action)")
        }
    }
}
