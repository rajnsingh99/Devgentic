// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolResultRoomTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ToolResultRoomTests: XCTestCase {

    private let adapter = OpenAIToolTurnAdapter()
    private let keep = 3

    private func observation(_ id: String, _ result: String) -> ToolObservation {
        ToolObservation(stepId: 0, toolCallId: id, toolName: "read_file", result: result, summary: "",
                        isSuccess: true, params: "", output: "", artifacts: [])
    }

    private func exchange(_ id: String, result: String) -> [[String: Any]] {
        [adapter.assistantTurn(toolCalls: [PendingToolCall(id: id, name: "read_file", arguments: ["path": .string("/p/\(id)")])],
                               reasoning: "reading \(id)")]
            + adapter.toolResultTurns(observations: [observation(id, result)])
    }

    private func prefix() -> [[String: Any]] {
        [adapter.normalizeCanonical(message: ["role": "system", "content": "You are an agent."]),
         adapter.userTurn(text: "Summarise the three files.", images: [])]
    }

    private func chars(_ turns: some Sequence<[String: Any]>) -> Int { turns.reduce(0) { $0 + approximateTurnChars($1) } }

    // MARK: - The helper says exactly what compaction keeps (from the invariant, not the code)

    /// Append the next exchange, then compact as hard as compaction is allowed to: whatever survives
    /// between the prefix and the new exchange (bar the marker) is what the helper must have counted.
    func testTheUnremovableCountMatchesWhatCompactionActuallyKeeps() {
        for existing in 0...5 {
            var turns = prefix()
            for i in 0..<existing { turns += exchange("e\(i)", result: String(repeating: "x", count: 400 + i)) }
            let predicted = unremovableRecentExchangeChars(turns, adapter: adapter, protectedPrefixCount: 2,
                                                           keepRecentExchanges: keep)
            let next = exchange("new", result: "y")
            turns += next
            _ = compactNativeConversation(&turns, adapter: adapter, budgetChars: 1, protectedPrefixCount: 2,
                                          keepRecentExchanges: keep, cumulativeDropped: 0)
            let survivors = turns[2..<(turns.count - next.count)].filter {
                !String(describing: $0).contains("compacted") && !String(describing: $0).contains("earlier tool")
            }
            XCTAssertEqual(chars(survivors), predicted, "\(existing) existing exchange(s)")
        }
    }

    // MARK: - The CR-12 property, composed the way the executor composes it

    /// ⚠️⚠️ Three large results in a row on a small budget: with the room counted correctly the payload
    /// stays within the budget (plus the per-turn scaffolding); counting only the prefix gave ~3×.
    func testThreeLargeResultsInARowStayWithinTheBudget() {
        let budget = 30_000
        var turns = prefix()
        let prefixChars = chars(turns)
        for step in 0..<3 {
            let kept = unremovableRecentExchangeChars(turns, adapter: adapter, protectedPrefixCount: 2,
                                                      keepRecentExchanges: keep)
            let limit = ToolResultBudget.limit(payloadBudgetChars: budget, protectedChars: prefixChars + kept, resultsInBatch: 1)
            let fitted = ToolResultBudget.fit(String(repeating: "z", count: 50_000), limit: limit)
            turns += exchange("s\(step)", result: fitted)
        }
        // ⚠️ The bound allows ToolResultBudget's deliberate floor: once the room is gone, each later result
        // still keeps `minimumChars` (a smaller cut is useless). So the overshoot is at most
        // (keep − 1) × floor + per-turn scaffolding — not ~3× the budget, which is what the bug produced.
        let allowance = (keep - 1) * ToolResultBudget.minimumChars + 1_500
        XCTAssertLessThan(chars(turns), budget + allowance,
                          "the payload overflowed its budget — a result was given room the earlier results already held")
    }

    // MARK: - Scratchpad (legacy text path)

    func testThreeLargeObservationsDoNotOverflowTheScratchpad() {
        let budget = 6_000
        var memory = WindowedLinearMemory(config: MemoryBudgetConfig(totalBudgetChars: budget, perEntryCap: budget,
                                                                      fullFidelityWindow: 3, maxSystemAlerts: 3))
        // ⚠️ DISTINCT results and params. Identical (tool, params, output) collapses to "IDENTICAL TO
        // Step 1" in the scratchpad, which made an earlier draft of this test pass on the defective code.
        for (i, letter) in zip(1...3, ["q", "r", "s"]) {
            memory.recordObservation(stepId: i, toolCallId: "c\(i)", toolName: "read_file", params: #"{"path":"/p/\#(i)"}"#,
                                     result: String(repeating: letter, count: 20_000), artifacts: [])
        }
        // Same floor allowance as the native test: at most 2 × minimumChars over, plus line scaffolding.
        XCTAssertLessThan(memory.compileForPrompt().count, budget + 2 * ToolResultBudget.minimumChars + 600,
                          "the full-fidelity window is never evicted, so each entry must leave room for the others")
    }

    /// The control: one result alone still gets all of the room (no limit below what fits).
    func testASingleResultStillGetsAllTheRoom() {
        let budget = 6_000
        var memory = WindowedLinearMemory(config: MemoryBudgetConfig(totalBudgetChars: budget, perEntryCap: budget,
                                                                      fullFidelityWindow: 3, maxSystemAlerts: 3))
        memory.recordObservation(stepId: 1, toolCallId: "c1", toolName: "read_file", params: "",
                                 result: String(repeating: "q", count: 5_500), artifacts: [])
        XCTAssertTrue(memory.compileForPrompt().contains(String(repeating: "q", count: 5_500)), "a result that fits was cut")
    }

    // MARK: - The wiring

    /// The executor must feed the kept-exchange count into the limit — the helper is useless uncalled.
    func testTheExecutorCountsTheKeptExchangesInTheLimit() throws {
        let source = try Self.read("Devgentic/Core/Backends/TextGen/ReAct/ReActAgentExecutor.swift")
        let helperCall = try XCTUnwrap(source.range(of: "let keptRecentChars = unremovableRecentExchangeChars("))
        let sum = try XCTUnwrap(source.range(of: "let protectedChars = prefixChars + keptRecentChars"))
        let limit = try XCTUnwrap(source.range(of: "protectedChars: protectedChars,", range: sum.upperBound..<source.endIndex))
        XCTAssertTrue(helperCall.lowerBound < sum.lowerBound && sum.lowerBound < limit.lowerBound)
        XCTAssertTrue(source[sum.upperBound..<limit.lowerBound].contains("ToolResultBudget.limit("),
                      "the protected total must be what `ToolResultBudget.limit` receives")
    }

    private static func read(_ relativePath: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return try String(contentsOf: candidate, encoding: .utf8) }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("Could not locate \(relativePath)")
    }
}
