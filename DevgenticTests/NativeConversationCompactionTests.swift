// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeConversationCompactionTests.swift
//  DevgenticTests
//
//  Unit tests for finding #22 — native-path conversation compaction.
//
//  The native ReAct path sends `liveConversationTurns` (an append-only [[String: Any]]
//  array), which previously grew unbounded; the scratchpad budget only governs the
//  legacy <working_memory> path. These tests exercise the three new seams:
//    1. `ToolTurnAdapter.classifyTurn` — the universal turn classifier that lets the
//       compactor find exchange boundaries without per-provider dict-walking.
//    2. `approximateTurnChars` — the char-footprint estimator that drives the budget.
//    3. `compactNativeConversation` — drops the OLDEST whole tool exchanges past budget,
//       preserving the protected prefix, the keep-recent floor, and tool-call/result
//       pairing (orphaning a tool_use id 400s Claude/OpenAI and count-mismatches Gemini).
//

import XCTest
@testable import devgentic

final class NativeConversationCompactionTests: XCTestCase {

    // MARK: - Helpers

    private func call(_ id: String) -> PendingToolCall {
        PendingToolCall(id: id, name: "search", arguments: ["q": .string("query for \(id)")])
    }

    private func observation(_ id: String, resultChars: Int) -> ToolObservation {
        ToolObservation(
            stepId: 0,
            toolCallId: id,
            toolName: "search",
            result: String(repeating: "x", count: resultChars),
            summary: "",
            isSuccess: true,
            params: "",
            output: "",
            artifacts: []
        )
    }

    /// Builds [assistant(tool_call id) , tool_result(id)] for the given adapter.
    private func exchange(id: String, resultChars: Int, adapter: any ToolTurnAdapter) -> [[String: Any]] {
        let assistant = adapter.assistantTurn(toolCalls: [call(id)], reasoning: "reasoning \(id)")
        let results = adapter.toolResultTurns(observations: [observation(id, resultChars: resultChars)])
        return [assistant] + results
    }

    /// Builds an exchange where ONE assistant turn emits `calls` parallel tool calls, paired
    /// with `calls` result turns (OpenAI/Ollama → N role:tool turns; Claude/Gemini → 1 turn
    /// with N blocks/parts). This is the higher-risk shape for pairing-safe compaction.
    private func multiCallExchange(index i: Int, calls: Int, resultChars: Int, adapter: any ToolTurnAdapter) -> [[String: Any]] {
        let ids = (0..<calls).map { "c\(i)-\($0)" }
        let assistant = adapter.assistantTurn(toolCalls: ids.map { call($0) }, reasoning: "reasoning \(i)")
        let results = adapter.toolResultTurns(observations: ids.map { observation($0, resultChars: resultChars) })
        return [assistant] + results
    }

    private func systemPrefix(_ adapter: any ToolTurnAdapter) -> [[String: Any]] {
        [
            adapter.normalizeCanonical(message: ["role": "system", "content": "You are a helpful agent."]),
            adapter.userTurn(text: "Original user query.", images: [])
        ]
    }

    /// Returns the marker turn count (turns whose serialized text mentions the marker).
    private func markerCount(in turns: [[String: Any]]) -> Int {
        turns.filter { approxText($0).contains("earlier tool exchange(s) were summarized out") }.count
    }

    /// Flattens a turn's text content (works across provider shapes) for assertions.
    private func approxText(_ turn: [String: Any]) -> String {
        func walk(_ v: Any) -> String {
            switch v {
            case let s as String: return s
            case let d as [String: Any]: return d.values.map(walk).joined(separator: " ")
            case let a as [Any]: return a.map(walk).joined(separator: " ")
            default: return ""
            }
        }
        return walk(turn)
    }

    // MARK: - classifyTurn (all four native adapters)

    func testClassifyTurn_OpenAIShapes() {
        let adapter = OpenAIToolTurnAdapter()
        XCTAssertEqual(adapter.classifyTurn(adapter.assistantTurn(toolCalls: [call("a")], reasoning: nil)), .toolCallAssistant)
        XCTAssertEqual(adapter.classifyTurn(adapter.toolResultTurns(observations: [observation("a", resultChars: 4)])[0]), .toolResult)
        XCTAssertEqual(adapter.classifyTurn(adapter.userTurn(text: "hi", images: [])), .other)
        XCTAssertEqual(adapter.classifyTurn(adapter.systemAlertTurn(message: "alert")), .other)
    }

    func testClassifyTurn_OllamaShapes() {
        let adapter = OllamaToolTurnAdapter()
        XCTAssertEqual(adapter.classifyTurn(adapter.assistantTurn(toolCalls: [call("a")], reasoning: nil)), .toolCallAssistant)
        XCTAssertEqual(adapter.classifyTurn(adapter.toolResultTurns(observations: [observation("a", resultChars: 4)])[0]), .toolResult)
        XCTAssertEqual(adapter.classifyTurn(adapter.systemAlertTurn(message: "alert")), .other)
    }

    func testClassifyTurn_ClaudeShapes() {
        let adapter = ClaudeToolTurnAdapter()
        XCTAssertEqual(adapter.classifyTurn(adapter.assistantTurn(toolCalls: [call("a")], reasoning: "think")), .toolCallAssistant)
        XCTAssertEqual(adapter.classifyTurn(adapter.toolResultTurns(observations: [observation("a", resultChars: 4)])[0]), .toolResult)
        XCTAssertEqual(adapter.classifyTurn(adapter.userTurn(text: "hi", images: [])), .other)
        XCTAssertEqual(adapter.classifyTurn(adapter.systemAlertTurn(message: "alert")), .other)
    }

    func testClassifyTurn_GeminiShapes() {
        let adapter = GeminiToolTurnAdapter()
        XCTAssertEqual(adapter.classifyTurn(adapter.assistantTurn(toolCalls: [call("a")], reasoning: "think")), .toolCallAssistant)
        XCTAssertEqual(adapter.classifyTurn(adapter.toolResultTurns(observations: [observation("a", resultChars: 4)])[0]), .toolResult)
        XCTAssertEqual(adapter.classifyTurn(adapter.userTurn(text: "hi", images: [])), .other)
        // Gemini overrides systemAlertTurn to its parts shape — still classified .other.
        XCTAssertEqual(adapter.classifyTurn(adapter.systemAlertTurn(message: "alert")), .other)
    }

    // MARK: - approximateTurnChars

    func testApproximateTurnChars_SumsStringsAndKeys() {
        // {"role": "user", "content": "hello"} → keys (4 + 7) + values (4 + 5) = 20
        let turn: [String: Any] = ["role": "user", "content": "hello"]
        XCTAssertEqual(approximateTurnChars(turn), 4 + 4 + 7 + 5)
    }

    func testApproximateTurnChars_RecursesNestedArraysAndDicts() {
        let nested: [String: Any] = ["content": [["type": "text", "text": "abcd"]]]
        // "content"(7) + ["type"(4)+"text"(4) + "text"(4)+"abcd"(4)] = 7 + 16 = 23
        XCTAssertEqual(approximateTurnChars(nested), 7 + 4 + 4 + 4 + 4)
    }

    // MARK: - compactNativeConversation

    func testCompaction_UnderBudget_IsNoOp() {
        let adapter = OpenAIToolTurnAdapter()
        var turns = systemPrefix(adapter)
        for i in 0..<4 { turns += exchange(id: "c\(i)", resultChars: 50, adapter: adapter) }
        let before = turns.count

        let dropped = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 10_000_000, // far above payload
            protectedPrefixCount: 2, keepRecentExchanges: 3, cumulativeDropped: 0
        )
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(turns.count, before, "Under budget → array unchanged")
        XCTAssertEqual(markerCount(in: turns), 0)
    }

    func testCompaction_BudgetDisabled_IsNoOp() {
        let adapter = OpenAIToolTurnAdapter()
        var turns = systemPrefix(adapter)
        for i in 0..<8 { turns += exchange(id: "c\(i)", resultChars: 5000, adapter: adapter) }
        let before = turns.count
        let dropped = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 0, // disabled
            protectedPrefixCount: 2, keepRecentExchanges: 3, cumulativeDropped: 0
        )
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(turns.count, before)
    }

    func testCompaction_AtKeepRecentFloor_DoesNotDrop() {
        let adapter = OpenAIToolTurnAdapter()
        var turns = systemPrefix(adapter)
        for i in 0..<3 { turns += exchange(id: "c\(i)", resultChars: 5000, adapter: adapter) } // exactly keepRecent
        let before = turns.count
        let dropped = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 100, // way over budget
            protectedPrefixCount: 2, keepRecentExchanges: 3, cumulativeDropped: 0
        )
        XCTAssertEqual(dropped, 0, "Only keepRecent exchanges exist — nothing safely droppable")
        XCTAssertEqual(turns.count, before)
    }

    func testCompaction_OverBudget_DropsOldest_PreservesPrefix_AndKeepsRecent() {
        let adapter = OpenAIToolTurnAdapter()
        var turns = systemPrefix(adapter)
        let prefix = turns
        for i in 0..<8 { turns += exchange(id: "c\(i)", resultChars: 2000, adapter: adapter) }

        // Each exchange ≈ 2000+ chars; budget fits roughly 4 of them.
        let dropped = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 9000,
            protectedPrefixCount: 2, keepRecentExchanges: 3, cumulativeDropped: 0
        )

        XCTAssertGreaterThan(dropped, 0, "Over budget → should drop oldest exchanges")

        // Prefix untouched.
        XCTAssertEqual(turns[0]["role"] as? String, prefix[0]["role"] as? String)
        XCTAssertEqual(turns[1]["content"] as? String, prefix[1]["content"] as? String)

        // Exactly one marker, sitting immediately after the prefix.
        XCTAssertEqual(markerCount(in: turns), 1)
        XCTAssertTrue(approxText(turns[2]).contains("earlier tool exchange(s) were summarized out"))

        // At least keepRecent exchanges survive.
        let remainingAssistants = turns.filter { adapter.classifyTurn($0) == .toolCallAssistant }.count
        XCTAssertGreaterThanOrEqual(remainingAssistants, 3)
        XCTAssertEqual(remainingAssistants, 8 - dropped)

        // The most recent exchange (c7) must survive.
        XCTAssertTrue(turns.contains { ($0["tool_calls"] as? [[String: Any]])?.contains { $0["id"] as? String == "c7" } ?? false })

        // Payload is now within budget.
        let total = turns.reduce(0) { $0 + approximateTurnChars($1) }
        XCTAssertLessThanOrEqual(total, 9000)
    }

    /// Pairing safety (OpenAI id-based): every surviving tool-result turn's
    /// `tool_call_id` must match a surviving assistant `tool_calls` id.
    func testCompaction_OpenAIPairingPreserved_NoOrphanedToolResults() {
        let adapter = OpenAIToolTurnAdapter()
        var turns = systemPrefix(adapter)
        for i in 0..<10 { turns += exchange(id: "c\(i)", resultChars: 1500, adapter: adapter) }

        _ = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 6000,
            protectedPrefixCount: 2, keepRecentExchanges: 2, cumulativeDropped: 0
        )

        var keptCallIds = Set<String>()
        for t in turns where adapter.classifyTurn(t) == .toolCallAssistant {
            for c in (t["tool_calls"] as? [[String: Any]] ?? []) {
                if let id = c["id"] as? String { keptCallIds.insert(id) }
            }
        }
        for t in turns where t["role"] as? String == "tool" {
            let id = t["tool_call_id"] as? String
            XCTAssertNotNil(id)
            XCTAssertTrue(keptCallIds.contains(id!), "Orphaned tool_result for \(id!) — its assistant turn was dropped")
        }
    }

    /// Pairing safety (Claude content-block based): every surviving tool_result block's
    /// `tool_use_id` must match a surviving tool_use block's id.
    func testCompaction_ClaudePairingPreserved_NoOrphanedToolResults() {
        let adapter = ClaudeToolTurnAdapter()
        var turns = systemPrefix(adapter)
        for i in 0..<10 { turns += exchange(id: "c\(i)", resultChars: 1500, adapter: adapter) }

        _ = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 6000,
            protectedPrefixCount: 2, keepRecentExchanges: 2, cumulativeDropped: 0
        )

        var keptUseIds = Set<String>()
        for t in turns where adapter.classifyTurn(t) == .toolCallAssistant {
            for b in (t["content"] as? [[String: Any]] ?? []) where (b["type"] as? String) == "tool_use" {
                if let id = b["id"] as? String { keptUseIds.insert(id) }
            }
        }
        for t in turns where adapter.classifyTurn(t) == .toolResult {
            for b in (t["content"] as? [[String: Any]] ?? []) where (b["type"] as? String) == "tool_result" {
                let id = b["tool_use_id"] as? String
                XCTAssertNotNil(id)
                XCTAssertTrue(keptUseIds.contains(id!), "Orphaned tool_result block for \(id!)")
            }
        }
    }

    /// The marker reports the CUMULATIVE dropped count across successive compactions.
    func testCompaction_MarkerReportsCumulativeCount() {
        let adapter = OpenAIToolTurnAdapter()
        var turns = systemPrefix(adapter)
        for i in 0..<6 { turns += exchange(id: "c\(i)", resultChars: 2000, adapter: adapter) }

        let firstDropped = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 9000,
            protectedPrefixCount: 2, keepRecentExchanges: 3, cumulativeDropped: 0
        )
        XCTAssertGreaterThan(firstDropped, 0)

        // Add more exchanges, compact again with the running total threaded in.
        for i in 6..<10 { turns += exchange(id: "c\(i)", resultChars: 2000, adapter: adapter) }
        let secondDropped = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 9000,
            protectedPrefixCount: 2, keepRecentExchanges: 3, cumulativeDropped: firstDropped
        )
        XCTAssertGreaterThan(secondDropped, 0)

        // Still exactly one marker, and it reports the cumulative total.
        XCTAssertEqual(markerCount(in: turns), 1)
        let markerTurn = try? XCTUnwrap(turns.first { approxText($0).contains("earlier tool exchange(s) were summarized out") })
        let text = markerTurn.map { approxText($0) } ?? ""
        XCTAssertTrue(text.contains("\(firstDropped + secondDropped) earlier"), "Marker should report cumulative \(firstDropped + secondDropped); got: \(text)")
    }

    /// Parallel-tools shape: one assistant turn with N tool calls paired with N result turns.
    /// Compaction must drop these as whole units — never leaving an assistant call without its
    /// result (half-dropped exchange) or a result without its assistant call (orphan).
    func testCompaction_MultiCallExchange_PairingPreserved_NoHalfDrop() {
        let adapter = OpenAIToolTurnAdapter()
        var turns = systemPrefix(adapter)
        for i in 0..<8 { turns += multiCallExchange(index: i, calls: 2, resultChars: 1200, adapter: adapter) }

        let dropped = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 7000,
            protectedPrefixCount: 2, keepRecentExchanges: 2, cumulativeDropped: 0
        )
        XCTAssertGreaterThan(dropped, 0)

        var keptCallIds = Set<String>()
        for t in turns where adapter.classifyTurn(t) == .toolCallAssistant {
            for c in (t["tool_calls"] as? [[String: Any]] ?? []) {
                if let id = c["id"] as? String { keptCallIds.insert(id) }
            }
        }
        var keptResultIds = Set<String>()
        for t in turns where t["role"] as? String == "tool" {
            if let id = t["tool_call_id"] as? String { keptResultIds.insert(id) }
        }
        // (a) no orphaned result; (b) no half-dropped exchange — the two id sets must match exactly.
        XCTAssertEqual(keptCallIds, keptResultIds, "Multi-call exchanges must be dropped atomically (no orphan / no half-drop)")
        // Each surviving exchange must retain BOTH of its calls.
        XCTAssertEqual(keptCallIds.count % 2, 0, "Surviving call ids should come in pairs (whole exchanges)")
    }

    /// A keep-recent floor of 0 must be clamped to 1 internally — no out-of-bounds crash,
    /// and at least one recent exchange survives.
    func testCompaction_KeepRecentZero_ClampedNoCrash() {
        let adapter = OpenAIToolTurnAdapter()
        var turns = systemPrefix(adapter)
        for i in 0..<4 { turns += exchange(id: "c\(i)", resultChars: 2000, adapter: adapter) }

        let dropped = compactNativeConversation(
            &turns, adapter: adapter,
            budgetChars: 1000,
            protectedPrefixCount: 2, keepRecentExchanges: 0, cumulativeDropped: 0
        )
        XCTAssertGreaterThan(dropped, 0)
        let remainingAssistants = turns.filter { adapter.classifyTurn($0) == .toolCallAssistant }.count
        XCTAssertGreaterThanOrEqual(remainingAssistants, 1, "Clamp keeps at least one recent exchange")
    }
}
