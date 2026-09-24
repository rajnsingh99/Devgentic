// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    //
    // ⚠️ Since 2026-09-24 the scratchpad gets WHATEVER ROOM THE FIXED PROMPT LEAVES (payload budget
    // minus instructions/history/context/tool text), and one entry may use all of it. These assert
    // that rule, not snapshots of percentages: the old 8–15%-of-window budget ÷ maxIterations put
    // every 8K model at a 200-char cap.

    func testDerive_TotalIsThePayloadBudgetMinusTheFixedPrompt() {
        let config = MemoryBudgetConfig.derive(contextWindow: 32_768, tier: .medium, reservedChars: 20_000)
        XCTAssertEqual(config.totalBudgetChars,
                       PromptFitCheck.nativePayloadCharBudget(forContextWindow: 32_768) - 20_000)
        XCTAssertEqual(config.fullFidelityWindow, 3) // not frontier
    }

    /// No limit below what fits: a single result may use the whole room.
    func testDerive_OneEntryMayUseAllTheRoom() {
        let config = MemoryBudgetConfig.derive(contextWindow: 8_192, tier: .small, reservedChars: 10_000)
        XCTAssertEqual(config.perEntryCap, config.totalBudgetChars)
    }

    /// ⚠️ THE REGRESSION GUARD. An 8K model with a typical fixed prompt must get thousands of
    /// characters per result, not the old 200.
    func testAn8KModelIsNotPinnedToTheFloor() {
        let config = MemoryBudgetConfig.derive(contextWindow: 8_192, tier: .small, reservedChars: 10_000)
        XCTAssertGreaterThan(config.perEntryCap, 5_000,
                             "an 8K model is back near the old 200-char cap — the scratchpad is no longer sized by the free room")
    }

    func testDerive_AFixedPromptOverBudgetHitsTheFloor() {
        let config = MemoryBudgetConfig.derive(contextWindow: 8_192, tier: .small, reservedChars: 1_000_000)
        XCTAssertEqual(config.totalBudgetChars, MemoryBudgetConfig.minimumTotalChars)
    }

    func testDerive_FrontierTiersKeepMoreEntriesInFull() {
        XCTAssertEqual(MemoryBudgetConfig.derive(contextWindow: 200_000, tier: .ultra).fullFidelityWindow, 5)
        XCTAssertEqual(MemoryBudgetConfig.derive(contextWindow: 128_000, tier: .large).fullFidelityWindow, 5)
    }

    /// ⚠️ THE WIRING. Every derive test passes if `AgentConnect` stops telling it how big the fixed
    /// prompt is — and then the scratchpad claims the whole payload budget and overflows the window.
    func testAgentConnectSizesTheScratchpadAroundTheFixedPrompt() throws {
        // EIGHT components: file → Memory → Components → ReAct → TextGen → Backends → Core → DevgenticTests → root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 { root = root.deletingLastPathComponent() }
        let source = root.appendingPathComponent("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path), "running outside a checkout")
        let code = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("reservedChars: reservedPromptChars"),
                      "the chat/code path no longer sizes the scratchpad around its fixed prompt")
        XCTAssertEqual(code.components(separatedBy: "MemoryBudgetConfig.derive(").count - 1, 2,
                       "expected exactly the chat/code and workflow call sites")
        XCTAssertEqual(code.components(separatedBy: "reservedChars:").count - 1, 2,
                       "a derive call site lost its reservedChars — it would claim the whole payload budget")
    }

    func testDerive_ZeroContextWindow_FloorsAt2048() {
        let config = MemoryBudgetConfig.derive(contextWindow: 0, tier: .tiny)
        XCTAssertGreaterThan(config.totalBudgetChars, 0, "Budget should not be zero")
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
        XCTAssertTrue(compiled.contains("truncated") || compiled.contains("omitted"), "Long results should be cut, and say so")
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

    /// ⚠️ REWRITTEN 2026-09-13. This asserted `compiled.contains("(id: call_4)")` and had been RED
    /// against committed code: the prompt render deliberately stopped emitting `(id: <UUID>)`
    /// (WorkingMemoryStrategy.swift:423 — small-capacity Q4 3B/8B models parrot the UUID into
    /// subsequent tool-call content, polluting `write_file` args; the id stays in memory for log
    /// correlation only). The test's NAME is about full fidelity, so it now asserts full fidelity:
    /// a recent entry renders its result verbatim on its own line, which is the property the window
    /// exists to provide.
    func testFullFidelityWindow_RecentEntriesRenderedFully() {
        var memory = makeMemory(fullFidelityWindow: 2)
        // Record 5 observations — last 2 should be full fidelity
        for i in 1...5 {
            memory.recordObservation(stepId: i, toolCallId: "call_\(i)", toolName: "tool_\(i)", params: "", result: "Result for step \(i)", artifacts: [])
        }

        let compiled = memory.compileForPrompt()

        // Recent format is "- [Step N] <signature>:\n<full result>" — the colon-newline is what
        // distinguishes it from the compressed "→" one-liner used for old entries.
        XCTAssertTrue(compiled.contains("- [Step 4] tool_4:\nResult for step 4"),
                      "Step 4 must render at full fidelity. Got:\n\(compiled)")
        XCTAssertTrue(compiled.contains("- [Step 5] tool_5:\nResult for step 5"),
                      "Step 5 must render at full fidelity. Got:\n\(compiled)")
        // …and the entries outside the window must NOT.
        XCTAssertFalse(compiled.contains("- [Step 3] tool_3:\n"),
                       "Step 3 is outside a 2-entry window and must be compressed")
    }

    func testOldEntries_CompressedToOneLiner() {
        var memory = makeMemory(fullFidelityWindow: 2)
        for i in 1...5 {
            memory.recordObservation(stepId: i, toolCallId: "call_\(i)", toolName: "tool_\(i)", params: "", result: "Result \(i)", artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        // Old entries should use compressed format with → arrow
        XCTAssertTrue(compiled.contains("[Step 1] tool_1 \u{2192}"), "Old entries should be compressed one-liners")
        // ⚠️ The second assertion here used to be `XCTAssertFalse(compiled.contains("(id: call_1)"))`,
        // which became VACUOUS when the render stopped emitting ids at all — it could no longer fail
        // for any input. Replaced with the distinction that is actually load-bearing: an old entry
        // must not use the recent entries' colon-newline full-fidelity form.
        XCTAssertFalse(compiled.contains("- [Step 1] tool_1:\n"),
                       "an old entry must be compressed, not rendered at full fidelity")
    }

    /// ⚠️ NEW. Pins the decision that broke three tests in this file, and which nothing asserted:
    /// the compiled PROMPT never carries a `toolCallId`. The reason is behavioural, not cosmetic —
    /// small-capacity models copy the UUID into later tool arguments — so a well-meaning "restore
    /// the id for traceability" edit needs to fail here rather than in the field.
    func testToolCallIdsAreNeverSurfacedToTheModel() {
        var memory = makeMemory(fullFidelityWindow: 2)
        for i in 1...5 {
            memory.recordObservation(stepId: i, toolCallId: "call_UUID_\(i)", toolName: "tool_\(i)", params: "", result: "Result \(i)", artifacts: [])
        }

        let compiled = memory.compileForPrompt()
        XCTAssertFalse(compiled.contains("call_UUID_"),
                       "tool call ids must stay in memory for log correlation and never reach the "
                       + "prompt — models parrot them into tool arguments. Got:\n\(compiled)")
        XCTAssertFalse(compiled.contains("(id:"), "no id form may reach the prompt")
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

    /// ⚠️ REWRITTEN 2026-09-13. Asserted `contains("(id: c7)")`, a render detail the prompt
    /// deliberately no longer emits, so it had been RED while the rule it is named for went
    /// unprotected. The rule itself is structural: eviction drains `oldLines` only, and the
    /// full-fidelity window lives in `protectedLines`, which the eviction loop never touches
    /// (WorkingMemoryStrategy.swift:472-485). Asserting the RESULT CONTENT is what catches a
    /// regression — if the most recent tool results were ever evicted the agent would "forget"
    /// what it just learned, and that is invisible in an id check.
    func testEviction_NeverEvictsRecentObservations() {
        var memory = makeMemory(totalBudget: 200, perEntryCap: 80, fullFidelityWindow: 2)
        for i in 1...8 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "t\(i)", params: "", result: "R\(i) data", artifacts: [])
        }

        let compiled = memory.compileForPrompt()

        XCTAssertTrue(compiled.contains("evicted"), "the fixture must actually trigger eviction")
        // Both window entries survive, with their results intact and at full fidelity.
        XCTAssertTrue(compiled.contains("- [Step 7] t7:\nR7 data"),
                      "the second-newest observation was lost to eviction. Got:\n\(compiled)")
        XCTAssertTrue(compiled.contains("- [Step 8] t8:\nR8 data"),
                      "the newest observation was lost to eviction. Got:\n\(compiled)")
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

    /// ⚠️ RENAMED AND REWRITTEN 2026-09-13. It was called
    /// `testEviction_SeparatorRemovedWhenAllOldEvicted` and asserted `contains("(id: c5)")` — so it
    /// was red for a render detail, AND its name described behaviour that cannot occur.
    ///
    /// ⚠️ The separator is NOT removed when every old entry is evicted, and verifying that was the
    /// point of rewriting rather than patching. `compileForPrompt` drops the separator only when
    /// `allParts.isEmpty` (WorkingMemoryStrategy.swift:494-498), but the eviction branch INSERTS the
    /// `[SYSTEM: N earlier observation(s) evicted…]` marker into `oldLines` before that check, so
    /// after any eviction `allParts` holds at least the marker and the branch is unreachable.
    /// Confirmed by rendering the old test's exact fixture. That is also the correct OUTPUT — the
    /// marker occupies the compressed section, so a separator between it and the recent block is
    /// meaningful — it is only the old test's name that was wrong.
    func testEviction_MarkerReplacesTheOldBlockAndRecentSurvives() {
        // Budget so tiny that ALL old entries are evicted, leaving marker + recent.
        var memory = makeMemory(totalBudget: 100, perEntryCap: 50, fullFidelityWindow: 1)
        let payload = String(repeating: "y", count: 30)
        for i in 1...5 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "t\(i)", params: "", result: payload, artifacts: [])
        }

        let compiled = memory.compileForPrompt()

        XCTAssertTrue(compiled.contains("earlier observation(s) evicted for memory efficiency"),
                      "eviction must be announced, not silent. Got:\n\(compiled)")
        // Every old entry is gone — only the marker stands in for them.
        XCTAssertFalse(compiled.contains("- [Step 1] t1"), "step 1 should have been evicted")
        XCTAssertFalse(compiled.contains("- [Step 4] t4"), "step 4 should have been evicted")
        // The window entry survives with its content.
        XCTAssertTrue(compiled.contains("- [Step 5] t5:\n\(payload)"),
                      "the newest observation must survive any budget pressure. Got:\n\(compiled)")
        // The separator still separates the marker from the recent block.
        XCTAssertTrue(compiled.contains("--- Recent observations ---"),
                      "the marker occupies the compressed section, so the separator is still correct")
    }

    /// ⚠️ NEW. System alerts share `protectedLines` with the full-fidelity window, so they are
    /// un-evictable by the same mechanism — but nothing asserted it. An alert silently dropped under
    /// budget pressure is the corrective-alert path failing exactly when the run is in trouble.
    func testEviction_NeverEvictsSystemAlerts() {
        var memory = makeMemory(totalBudget: 100, perEntryCap: 50, fullFidelityWindow: 1)
        for i in 1...5 {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "t\(i)", params: "", result: String(repeating: "z", count: 30), artifacts: [])
        }
        memory.recordSystemAlert(msg: "CANARY_ALERT_TEXT")

        let compiled = memory.compileForPrompt()
        XCTAssertTrue(compiled.contains("evicted"), "the fixture must actually trigger eviction")
        XCTAssertTrue(compiled.contains("CANARY_ALERT_TEXT"),
                      "a system alert must survive eviction — it is how the model is told to "
                      + "course-correct. Got:\n\(compiled)")
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
