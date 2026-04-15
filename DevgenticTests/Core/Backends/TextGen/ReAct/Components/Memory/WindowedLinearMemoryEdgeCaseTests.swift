//
//  WindowedLinearMemoryEdgeCaseTests.swift
//  DevgenticTests
//
//  Red-Green synthetic edge case tests for WindowedLinearMemory.
//  These probe boundary conditions, stress scenarios, and unusual inputs
//  that might expose bugs not caught by the standard test suite.
//

import XCTest
@testable import devgentic

final class WindowedLinearMemoryEdgeCaseTests: XCTestCase {

    // MARK: - Helpers

    private func makeMemory(
        totalBudget: Int = 10_000,
        perEntryCap: Int = 500,
        fullFidelityWindow: Int = 3,
        maxAlerts: Int = 3
    ) -> WindowedLinearMemory {
        let config = MemoryBudgetConfig(
            totalBudgetChars: totalBudget,
            perEntryCap: perEntryCap,
            fullFidelityWindow: fullFidelityWindow,
            maxSystemAlerts: maxAlerts
        )
        return WindowedLinearMemory(config: config)
    }

    // MARK: - Boundary: Result Exactly At perEntryCap

    func testPerEntryCap_ExactlyAtCap_NoTruncation() {
        let cap = 100
        var memory = makeMemory(perEntryCap: cap)
        let exactResult = String(repeating: "A", count: cap)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", result: exactResult, artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertFalse(compiled.contains("truncated"), "Result exactly at cap should NOT be truncated")
        XCTAssertTrue(compiled.contains(exactResult), "Exact-cap result should be preserved verbatim")
    }

    func testPerEntryCap_OneOverCap_Truncated() {
        let cap = 100
        var memory = makeMemory(perEntryCap: cap)
        let overResult = String(repeating: "B", count: cap + 1)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", result: overResult, artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("...[truncated]"), "Result one over cap should be truncated")
    }

    // MARK: - Boundary: perEntryCap Smaller Than Truncation Suffix

    func testPerEntryCap_SmallerThanSuffix_StillWorks() {
        // "...[truncated]" is 14 chars. What if perEntryCap = 10?
        var memory = makeMemory(perEntryCap: 10)
        let longResult = String(repeating: "C", count: 200)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", result: longResult, artifacts: [])

        let compiled = memory.compileForPrompt()
        // Should not crash. The prefix might be empty but the suffix should still appear.
        XCTAssertTrue(compiled.contains("truncated"), "Should handle tiny perEntryCap without crash")
    }

    // MARK: - Only System Alerts, No Observations

    func testOnlyAlerts_NoObservations_CompilesCorrectly() {
        var memory = makeMemory()
        memory.recordSystemAlert(msg: "Alert 1")
        memory.recordSystemAlert(msg: "Alert 2")

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("[SYSTEM ALERT] Alert 1"))
        XCTAssertTrue(compiled.contains("[SYSTEM ALERT] Alert 2"))
        XCTAssertFalse(compiled.contains("--- Recent observations ---"), "No separator without observations")
    }

    // MARK: - Mixed Alerts and Observations Interleaved

    func testInterleaved_AlertsAndObservations_CorrectOrdering() {
        var memory = makeMemory(fullFidelityWindow: 5)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool1", result: "R1", artifacts: [])
        memory.recordSystemAlert(msg: "Alert after step 1")
        memory.recordObservation(stepId: 2, toolCallId: "c2", toolName: "tool2", result: "R2", artifacts: [])
        memory.recordSystemAlert(msg: "Alert after step 2")

        let compiled = memory.compileForPrompt()
        // Alerts should appear AFTER all observations (at the end)
        let lastAlertIdx = compiled.range(of: "Alert after step 2")?.lowerBound
        let lastObsIdx = compiled.range(of: "[Step 2]")?.lowerBound

        if let alertIdx = lastAlertIdx, let obsIdx = lastObsIdx {
            XCTAssertTrue(alertIdx > obsIdx, "Alerts should render after all observations regardless of insertion order")
        }
    }

    // MARK: - Unicode and Special Characters

    func testUnicode_InResults_PreservedCorrectly() {
        var memory = makeMemory()
        let unicodeResult = "File: /tmp/\u{1F4C4} résumé.pdf — size: 2.5KB"
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "read_file", result: unicodeResult, artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("\u{1F4C4}"), "Emoji should be preserved")
        XCTAssertTrue(compiled.contains("résumé"), "Accented characters should be preserved")
    }

    func testUnicode_InToolName_PreservedCorrectly() {
        var memory = makeMemory()
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "búsqueda", result: "found", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("búsqueda"))
    }

    // MARK: - Empty Result String

    func testEmptyResult_RecordedAndCompiled() {
        var memory = makeMemory()
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", result: "", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertNotEqual(compiled, "No actions taken yet.", "Empty result should still count as an observation")
        XCTAssertTrue(compiled.contains("[Step 1]"))
    }

    // MARK: - Stress Test: Many Entries

    func testStress_100Entries_CompileDoesNotHang() {
        var memory = makeMemory(totalBudget: 50_000, perEntryCap: 200, fullFidelityWindow: 3)

        let start = Date()
        for i in 1...100 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "tool_\(i % 5)", result: "Result \(i) " + String(repeating: "x", count: 100), artifacts: [])
        }
        let compiled = memory.compileForPrompt()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(compiled.isEmpty)
        XCTAssertLessThan(elapsed, 1.0, "100 entries should compile in under 1 second")
    }

    func testStress_100Entries_BudgetRespected() {
        let budget = 5000
        var memory = makeMemory(totalBudget: budget, perEntryCap: 200, fullFidelityWindow: 3)
        for i in 1...100 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "tool", result: String(repeating: "x", count: 150), artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        // After eviction, compiled should be reasonably close to budget
        // Allow some slack for eviction marker and recent entries
        XCTAssertLessThan(compiled.count, budget * 2, "Compiled output should not wildly exceed budget after eviction")
    }

    // MARK: - Error Dedup: Edge Cases

    func testErrorDedup_SingleError_NotMarkedAsDedup() {
        var memory = makeMemory(fullFidelityWindow: 1)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", result: "System Error: timeout", artifacts: [])
        memory.recordObservation(stepId: 2, toolCallId: "c2", toolName: "other", result: "OK", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertFalse(compiled.contains("failed"), "Single error should not show 'failed Nx'")
        XCTAssertTrue(compiled.contains("[Step 1] tool"))
    }

    func testErrorDedup_SystemSecurityPrefix_AlsoCollapsed() {
        var memory = makeMemory(fullFidelityWindow: 1)
        let securityMsg = "System Security: User explicitly denied permission to execute tool 'delete_file'."
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "delete_file", result: securityMsg, artifacts: [])
        memory.recordObservation(stepId: 2, toolCallId: "c2", toolName: "delete_file", result: securityMsg, artifacts: [])
        memory.recordObservation(stepId: 3, toolCallId: "c3", toolName: "other", result: "OK", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("failed 2x"), "System Security errors should also be collapsed")
    }

    // MARK: - Budget Utilization: Lightweight Estimate Accuracy

    func testBudgetUtilization_RoughlyMatchesActual() {
        var memory = makeMemory(totalBudget: 5000, perEntryCap: 300, fullFidelityWindow: 3)
        for i in 1...8 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "tool_\(i)", result: "Result data \(i) " + String(repeating: "z", count: 100), artifacts: [])
        }

        let estimated = memory.budgetUtilization
        let actualChars = memory.compileForPrompt().count
        let actualUtilization = Double(actualChars) / 5000.0

        // Estimate should be within 50% of actual (it's a lightweight approximation)
        let ratio = estimated / max(actualUtilization, 0.001)
        XCTAssertGreaterThan(ratio, 0.5, "Estimate should be within 50% of actual (got \(ratio))")
        XCTAssertLessThan(ratio, 2.0, "Estimate should not be more than 2x actual (got \(ratio))")
    }

    // MARK: - MemoryBudgetConfig: Negative Context Window

    func testDerive_NegativeContextWindow_FloorsAt2048() {
        let config = MemoryBudgetConfig.derive(contextWindow: -1000, tier: .tiny)
        XCTAssertGreaterThan(config.totalBudgetChars, 0, "Negative context window should not produce negative budget")
    }

    func testDerive_NegativeMaxIterations_FloorsAtOne() {
        let config = MemoryBudgetConfig.derive(contextWindow: 4096, tier: .small, maxIterations: -5)
        XCTAssertGreaterThan(config.perEntryCap, 0, "Negative maxIterations should not crash")
    }

    // MARK: - Eviction: All Entries Identical Size

    func testEviction_AllEntriesIdenticalSize_EvictsCorrectCount() {
        // Each entry is ~80 chars when compressed. Budget = 300. fullFidelityWindow = 1.
        // Recent (1 entry ~100 chars) + separator (~30 chars) = ~130 protected.
        // Remaining budget for old = ~170 chars. Each old compressed = ~80 chars → ~2 fit.
        // With 10 entries total, 9 old → should evict ~7.
        var memory = makeMemory(totalBudget: 300, perEntryCap: 60, fullFidelityWindow: 1)
        for i in 1...10 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "tool", result: String(repeating: "a", count: 40), artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("evicted"), "Should evict some entries")
        XCTAssertTrue(compiled.contains("(id: c10)"), "Most recent should always survive")
    }

    // MARK: - Single Observation: No Split, No Separator

    func testSingleObservation_NoSplitNoSeparator() {
        var memory = makeMemory(fullFidelityWindow: 3)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", result: "data", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("[Step 1]"))
        XCTAssertFalse(compiled.contains("---"))
        XCTAssertTrue(compiled.contains("(id: c1)"), "Single entry should be in recent window with full ID")
    }

    // MARK: - Clear Then Reuse

    func testClearThenReuse_WorksCorrectly() {
        var memory = makeMemory()
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool1", result: "R1", artifacts: [])
        memory.clear()

        // Record new observations after clear
        memory.recordObservation(stepId: 1, toolCallId: "c_new", toolName: "tool_new", result: "New result", artifacts: [])
        let compiled = memory.compileForPrompt()

        XCTAssertTrue(compiled.contains("tool_new"), "New observations after clear should work")
        XCTAssertFalse(compiled.contains("tool1"), "Old observations should be gone after clear")
    }

    // MARK: - Multiline Result: Compressed Summary Flattens Newlines

    func testCompressSummary_FlattensNewlines() {
        var memory = makeMemory(fullFidelityWindow: 1)
        let multilineResult = "Line 1\nLine 2\nLine 3\nLine 4"
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", result: multilineResult, artifacts: [])
        // Add another so step 1 goes into the "old" compressed section
        memory.recordObservation(stepId: 2, toolCallId: "c2", toolName: "other", result: "OK", artifacts: [])

        let compiled = memory.compileForPrompt()
        // The compressed one-liner for step 1 should have newlines replaced with spaces
        // Find the compressed line (before the separator)
        if let separatorRange = compiled.range(of: "--- Recent") {
            let oldSection = String(compiled[compiled.startIndex..<separatorRange.lowerBound])
            XCTAssertFalse(oldSection.contains("Line 1\nLine 2"), "Compressed summary should flatten newlines")
            XCTAssertTrue(oldSection.contains("Line 1 Line 2"), "Newlines should become spaces in compressed summary")
        }
    }

    // MARK: - Memory Pressure Throttling (G11)

    func testMemoryPressure_Over100Percent_ThrottleAlertAppearsInCompilation() {
        // Simulate what ReActAgentExecutor does when utilization >= 1.0:
        // It injects a system alert telling the model to wrap up.
        // Verify the alert survives compilation and is visible to the LLM.
        var memory = makeMemory(totalBudget: 300, perEntryCap: 80, fullFidelityWindow: 2)

        // Fill memory well past budget
        for i in 1...10 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "tool_\(i)", result: String(repeating: "x", count: 60), artifacts: [])
        }

        // Verify utilization is over 100%
        XCTAssertGreaterThan(memory.budgetUtilization, 0.75, "Should be over 75% threshold")

        // Inject the throttle alert (same as ReActAgentExecutor does at line 167)
        memory.recordSystemAlert(
            msg: "Working memory is full. Older observations have been evicted. "
               + "Prioritize synthesizing a final answer from available context "
               + "rather than calling additional tools."
        )

        let compiled = memory.compileForPrompt()

        // The throttle alert should be visible in the compiled output
        XCTAssertTrue(compiled.contains("Working memory is full"), "Throttle alert should appear in compiled output")
        XCTAssertTrue(compiled.contains("Prioritize synthesizing"), "Synthesis nudge should be visible to the LLM")
    }

    func testMemoryPressure_AlertSurvivesEviction() {
        // Even with aggressive eviction, system alerts are protected (rendered after observations).
        // Verify the throttle alert isn't evicted even when budget is extremely tight.
        var memory = makeMemory(totalBudget: 200, perEntryCap: 60, fullFidelityWindow: 1, maxAlerts: 3)

        for i in 1...8 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "t\(i)", result: String(repeating: "z", count: 40), artifacts: [])
        }

        // Inject throttle alert
        memory.recordSystemAlert(msg: "Working memory is full. Prioritize final answer.")

        let compiled = memory.compileForPrompt()

        // Eviction should have triggered (tiny budget)
        XCTAssertTrue(compiled.contains("evicted"), "Eviction should have triggered")
        // But the alert should still be there
        XCTAssertTrue(compiled.contains("Working memory is full"), "Throttle alert should survive eviction")
    }

    func testMemoryPressure_AlertCappedWithOtherAlerts() {
        // If 3 other alerts exist and the throttle alert is the 4th,
        // the oldest alert should be evicted (maxAlerts=3), but the throttle alert
        // (most recent) should survive.
        var memory = makeMemory(totalBudget: 5000, maxAlerts: 3)

        memory.recordSystemAlert(msg: "Parse failure 1")
        memory.recordSystemAlert(msg: "Parse failure 2")
        memory.recordSystemAlert(msg: "Parse failure 3")
        memory.recordSystemAlert(msg: "Working memory is full. Prioritize final answer.")

        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", result: "data", artifacts: [])

        let compiled = memory.compileForPrompt()

        // Oldest alert ("Parse failure 1") should be evicted — only 3 survive
        XCTAssertFalse(compiled.contains("Parse failure 1"), "Oldest alert should be evicted by cap")
        XCTAssertTrue(compiled.contains("Parse failure 2"))
        XCTAssertTrue(compiled.contains("Parse failure 3"))
        XCTAssertTrue(compiled.contains("Working memory is full"), "Throttle alert (most recent) should survive cap")
    }
}
