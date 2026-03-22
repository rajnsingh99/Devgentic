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
}
