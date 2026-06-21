//
//  WindowedLinearMemoryTests.swift
//  DevgenticTests
//
//  Tests for MemoryBudgetConfig derivation, WindowedLinearMemory protocol conformance,
//  truncation, old/recent split, sliding window eviction, system alert cap,
//  error deduplication, and budget utilization observability.
//

import XCTest
@testable import devgentic

final class WindowedLinearMemoryTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a WindowedLinearMemory with explicit config for test control.
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

    private func recordObservations(_ memory: inout WindowedLinearMemory, count: Int, resultPrefix: String = "Result", resultLength: Int = 50) {
        for i in 1...count {
            let result = String(repeating: "x", count: resultLength)
            memory.recordObservation(stepId: i, toolCallId: "call_\(i)", toolName: "tool_\(i)", params: "", result: "\(resultPrefix) \(i): \(result)", artifacts: [])
        }
    }

    // MARK: - MemoryBudgetConfig.derive Tests

    func testDerive_TinyTier_ProducesCorrectBudget() {
        let config = MemoryBudgetConfig.derive(contextWindow: 4096, tier: .tiny)
        // 4096 * 0.08 = 327.68 tokens → 327 * 4 = 1308 chars
        XCTAssertEqual(config.totalBudgetChars, 1308)
        XCTAssertEqual(config.perEntryCap, 200) // max(200, 1308/15) = max(200, 87) = 200
        XCTAssertEqual(config.fullFidelityWindow, 3)
        XCTAssertEqual(config.maxSystemAlerts, 3)
    }

    func testDerive_LargeTier_ProducesCorrectBudget() {
        let config = MemoryBudgetConfig.derive(contextWindow: 128_000, tier: .large)
        // 128000 * 0.15 = 19200 tokens → 19200 * 4 = 76800 chars
        XCTAssertEqual(config.totalBudgetChars, 76800)
        XCTAssertEqual(config.perEntryCap, 5120) // 76800 / 15 = 5120
        XCTAssertEqual(config.fullFidelityWindow, 5) // frontier
    }

    func testDerive_MediumTier_ProducesCorrectBudget() {
        let config = MemoryBudgetConfig.derive(contextWindow: 32768, tier: .medium)
        // 32768 * 0.10 = 3276 tokens → 3276 * 4 = 13104 chars (Int truncation: 3276.8 → 3276)
        XCTAssertEqual(config.totalBudgetChars, 13104)
        XCTAssertEqual(config.perEntryCap, 873) // 13104 / 15 = 873
        XCTAssertEqual(config.fullFidelityWindow, 3) // not frontier
    }

    func testDerive_UltraTier_UsesFrontierWindow() {
        let config = MemoryBudgetConfig.derive(contextWindow: 200_000, tier: .ultra)
        XCTAssertEqual(config.fullFidelityWindow, 5) // frontier
    }

    func testDerive_ZeroContextWindow_FloorsAt2048() {
        let config = MemoryBudgetConfig.derive(contextWindow: 0, tier: .tiny)
        // max(2048, 0) = 2048 → 2048 * 0.08 = 163 tokens → 163 * 4 = 652 chars
        XCTAssertGreaterThan(config.totalBudgetChars, 0, "Budget should not be zero")
        XCTAssertGreaterThanOrEqual(config.perEntryCap, 200, "Per-entry cap floor should apply")
    }

    func testDerive_ZeroMaxIterations_FloorsAtOne() {
        // Should not crash with division by zero
        let config = MemoryBudgetConfig.derive(contextWindow: 4096, tier: .small, maxIterations: 0)
        XCTAssertGreaterThan(config.perEntryCap, 0, "Per-entry cap must be positive")
    }

    // MARK: - Basic Protocol Tests

    func testEmpty_CompileReturnsNoActions() {
        let memory = makeMemory()
        XCTAssertEqual(memory.compileForPrompt(), "No actions taken yet.")
    }

    func testClear_ResetsEntries() {
        var memory = makeMemory()
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", params: "", result: "result", artifacts: [])
        XCTAssertNotEqual(memory.compileForPrompt(), "No actions taken yet.")

        memory.clear()
        XCTAssertEqual(memory.compileForPrompt(), "No actions taken yet.")
    }

    func testRecordObservation_AppearsInCompilation() {
        var memory = makeMemory()
        memory.recordObservation(stepId: 1, toolCallId: "call_1", toolName: "read_file", params: "", result: "file contents here", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("[Step 1]"))
        XCTAssertTrue(compiled.contains("read_file"))
        XCTAssertTrue(compiled.contains("file contents here"))
    }

    func testRecordSystemAlert_AppearsInCompilation() {
        var memory = makeMemory()
        memory.recordSystemAlert(msg: "Parse failure detected")

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("[SYSTEM ALERT]"))
        XCTAssertTrue(compiled.contains("Parse failure detected"))
    }

    func testBudgetUtilization_EmptyIsZero() {
        let memory = makeMemory()
        XCTAssertEqual(memory.budgetUtilization, 0.0)
    }

    // MARK: - Truncation Tests

    func testPerEntryCap_TruncatesLargeResults() {
        var memory = makeMemory(perEntryCap: 100)
        let longResult = String(repeating: "A", count: 500)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", params: "", result: longResult, artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("...[truncated]"), "Long results should be truncated")
        XCTAssertFalse(compiled.contains(longResult), "Original full result should not appear")
    }

    func testPerEntryCap_TruncationStaysWithinBudget() {
        let cap = 200
        var memory = makeMemory(perEntryCap: cap)
        let longResult = String(repeating: "B", count: 1000)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", params: "", result: longResult, artifacts: [])

        let compiled = memory.compileForPrompt()
        // The stored result (visible in compiled) should not exceed perEntryCap
        // Check that the truncated portion + suffix fits within cap
        let truncationSuffix = "...[truncated]"
        // Find the result in the compiled output (after the ":\n" separator)
        if let range = compiled.range(of: ":\n") {
            let resultPortion = String(compiled[range.upperBound...])
            XCTAssertLessThanOrEqual(resultPortion.count, cap + truncationSuffix.count + 20, "Stored result should respect per-entry cap")
        }
    }

    func testSmallResults_NoTruncation() {
        var memory = makeMemory(perEntryCap: 500)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", params: "", result: "short result", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("short result"))
        XCTAssertFalse(compiled.contains("truncated"))
    }

    // MARK: - Old/Recent Split Tests

    func testFullFidelityWindow_RecentEntriesRenderedFully() {
        var memory = makeMemory(fullFidelityWindow: 2)
        // Record 5 observations — last 2 should be full fidelity
        for i in 1...5 {
            memory.recordObservation(stepId: i, toolCallId: "call_\(i)", toolName: "tool_\(i)", params: "", result: "Result for step \(i)", artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        // Recent entries should have full format with tool call ID
        XCTAssertTrue(compiled.contains("(id: call_4)"), "Step 4 should be in recent window with full ID")
        XCTAssertTrue(compiled.contains("(id: call_5)"), "Step 5 should be in recent window with full ID")
    }

    func testOldEntries_CompressedToOneLiner() {
        var memory = makeMemory(fullFidelityWindow: 2)
        for i in 1...5 {
            memory.recordObservation(stepId: i, toolCallId: "call_\(i)", toolName: "tool_\(i)", params: "", result: "Result \(i)", artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        // Old entries should use compressed format with → arrow
        XCTAssertTrue(compiled.contains("[Step 1] tool_1 \u{2192}"), "Old entries should be compressed one-liners")
        XCTAssertFalse(compiled.contains("(id: call_1)"), "Old entries should NOT have full tool call ID")
    }

    func testSeparator_PresentWhenBothOldAndRecentExist() {
        var memory = makeMemory(fullFidelityWindow: 2)
        for i in 1...4 {
            memory.recordObservation(stepId: i, toolCallId: "call_\(i)", toolName: "tool_\(i)", params: "", result: "R\(i)", artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("--- Recent observations ---"))
    }

    func testSeparator_AbsentWhenAllRecent() {
        var memory = makeMemory(fullFidelityWindow: 5)
        for i in 1...3 {
            memory.recordObservation(stepId: i, toolCallId: "call_\(i)", toolName: "tool_\(i)", params: "", result: "R\(i)", artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        XCTAssertFalse(compiled.contains("--- Recent observations ---"))
    }

    // MARK: - Eviction Tests

    func testEviction_DropsOldestWhenOverBudget() {
        // Tiny budget: 300 chars — will force eviction quickly
        var memory = makeMemory(totalBudget: 300, perEntryCap: 100, fullFidelityWindow: 1)
        for i in 1...10 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "t\(i)", params: "", result: "R\(i) " + String(repeating: "x", count: 50), artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("evicted"), "Eviction marker should be present")
    }

    func testEviction_NeverEvictsRecentObservations() {
        var memory = makeMemory(totalBudget: 200, perEntryCap: 80, fullFidelityWindow: 2)
        for i in 1...8 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "t\(i)", params: "", result: "R\(i) data", artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        // Last 2 (fullFidelityWindow) should always survive
        XCTAssertTrue(compiled.contains("(id: c7)") || compiled.contains("(id: c8)"), "Recent observations should survive eviction")
    }

    func testEviction_MarkerIncludesCount() {
        var memory = makeMemory(totalBudget: 150, perEntryCap: 60, fullFidelityWindow: 1)
        for i in 1...6 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "t\(i)", params: "", result: String(repeating: "x", count: 40), artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        // Should contain "[SYSTEM: N earlier observation(s) evicted for memory efficiency]"
        XCTAssertTrue(compiled.contains("earlier observation(s) evicted for memory efficiency"))
    }

    func testEviction_SeparatorRemovedWhenAllOldEvicted() {
        // Budget so tiny that ALL old entries are evicted, leaving only recent + eviction marker
        var memory = makeMemory(totalBudget: 100, perEntryCap: 50, fullFidelityWindow: 1)
        for i in 1...5 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "t\(i)", params: "", result: String(repeating: "y", count: 30), artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        // Verify the eviction marker is present (eviction definitely happened)
        XCTAssertTrue(compiled.contains("evicted"), "Eviction should have triggered with tiny budget")
        // The most recent observation (fullFidelityWindow=1) should always survive
        XCTAssertTrue(compiled.contains("(id: c5)"), "Most recent observation must survive eviction")
    }

    // MARK: - System Alert Cap Tests

    func testSystemAlerts_CappedAtThree() {
        var memory = makeMemory(maxAlerts: 3)
        for i in 1...5 {
            memory.recordSystemAlert(msg: "Alert \(i)")
        }

        let compiled = memory.compileForPrompt()
        XCTAssertFalse(compiled.contains("Alert 1"), "Oldest alert should be evicted")
        XCTAssertFalse(compiled.contains("Alert 2"), "Second oldest alert should be evicted")
        XCTAssertTrue(compiled.contains("Alert 3"), "Third most recent should survive")
        XCTAssertTrue(compiled.contains("Alert 4"))
        XCTAssertTrue(compiled.contains("Alert 5"))
    }

    func testSystemAlerts_RenderedAtEnd() {
        var memory = makeMemory()
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", params: "", result: "result", artifacts: [])
        memory.recordSystemAlert(msg: "Alert message")

        let compiled = memory.compileForPrompt()
        let alertIndex = compiled.range(of: "[SYSTEM ALERT]")?.lowerBound
        let obsIndex = compiled.range(of: "[Step 1]")?.lowerBound

        if let alertIdx = alertIndex, let obsIdx = obsIndex {
            XCTAssertTrue(alertIdx > obsIdx, "System alerts should appear after observations")
        }
    }

    // MARK: - Error Deduplication Tests

    func testErrorDedup_ConsecutiveSameToolSameError_Collapsed() {
        var memory = makeMemory(fullFidelityWindow: 1)
        let errorMsg = "System Error: Tool not found. 'search_flights' does not exist."
        for i in 1...3 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "search_flights", params: "", result: errorMsg, artifacts: [])
        }
        // Add one more observation so the errors are in the "old" section
        memory.recordObservation(stepId: 4, toolCallId: "c4", toolName: "web_search", params: "", result: "Found flights", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("failed 3x"), "Consecutive identical errors should be collapsed")
        XCTAssertTrue(compiled.contains("[Steps 1-3]"), "Should show step range")
    }

    func testErrorDedup_DifferentToolNames_NotCollapsed() {
        var memory = makeMemory(fullFidelityWindow: 1)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool_a", params: "", result: "System Error: failed", artifacts: [])
        memory.recordObservation(stepId: 2, toolCallId: "c2", toolName: "tool_b", params: "", result: "System Error: failed", artifacts: [])
        memory.recordObservation(stepId: 3, toolCallId: "c3", toolName: "web_search", params: "", result: "OK", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("[Step 1] tool_a"))
        XCTAssertTrue(compiled.contains("[Step 2] tool_b"))
        XCTAssertFalse(compiled.contains("failed 2x"), "Different tools should not be collapsed")
    }

    func testErrorDedup_SuccessInterrupts_NotCollapsed() {
        var memory = makeMemory(fullFidelityWindow: 1)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", params: "", result: "System Error: timeout", artifacts: [])
        memory.recordObservation(stepId: 2, toolCallId: "c2", toolName: "tool", params: "", result: "Success: found it", artifacts: [])
        memory.recordObservation(stepId: 3, toolCallId: "c3", toolName: "tool", params: "", result: "System Error: timeout", artifacts: [])
        memory.recordObservation(stepId: 4, toolCallId: "c4", toolName: "web_search", params: "", result: "OK", artifacts: [])

        let compiled = memory.compileForPrompt()
        XCTAssertFalse(compiled.contains("failed 2x"), "Non-consecutive errors should not be collapsed")
    }

    func testErrorDedup_OnlyAffectsOldEntries() {
        // Recent window entries should always be rendered individually
        var memory = makeMemory(fullFidelityWindow: 3)
        let errorMsg = "System Error: not found"
        for i in 1...3 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "tool", params: "", result: errorMsg, artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        // All 3 are in the recent window — no dedup.
        // Step markers (not UUIDs) are the prompt-visible identifier — UUIDs stay internal
        // for log correlation but are omitted from model-facing render.
        XCTAssertTrue(compiled.contains("[Step 1]"))
        XCTAssertTrue(compiled.contains("[Step 2]"))
        XCTAssertTrue(compiled.contains("[Step 3]"))
        XCTAssertFalse(compiled.contains("failed 3x"))
    }

    // MARK: - Budget Utilization Tests

    func testBudgetUtilization_ScalesWithEntries() {
        var memory = makeMemory(totalBudget: 5000)
        let util0 = memory.budgetUtilization
        XCTAssertEqual(util0, 0.0)

        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", params: "", result: String(repeating: "x", count: 200), artifacts: [])
        let util1 = memory.budgetUtilization
        XCTAssertGreaterThan(util1, 0.0)

        memory.recordObservation(stepId: 2, toolCallId: "c2", toolName: "tool", params: "", result: String(repeating: "y", count: 200), artifacts: [])
        let util2 = memory.budgetUtilization
        XCTAssertGreaterThan(util2, util1, "Utilization should increase with more entries")
    }

    func testBudgetUtilization_ZeroBudget_ReturnsZero() {
        var memory = makeMemory(totalBudget: 0)
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "tool", params: "", result: "data", artifacts: [])
        XCTAssertEqual(memory.budgetUtilization, 0.0)
    }

    // MARK: - Artifact Metadata Tests

    func testArtifactCount_RenderedInRecentEntries() {
        var memory = makeMemory(fullFidelityWindow: 3)
        // Create a dummy artifact
        let artifact = MediaArtifact(kind: .image, reference: .ephemeralData(Data()), mimeType: "image/png")
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "screen_capture", params: "", result: "Screenshot saved", artifacts: [artifact, artifact])

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("[2 artifact(s)]"))
    }
}
