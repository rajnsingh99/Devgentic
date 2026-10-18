// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ContextGaugeBreakdownTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class ContextCutLogTests: XCTestCase {

    private let conversation = UUID()

    override func setUp() async throws {
        try await super.setUp()
        // The log is a process-wide singleton; a fresh conversation id per test keeps them apart.
    }

    private func cut(_ tool: String, _ from: Int, _ to: Int) -> ContextCutLog.ResultCut {
        .init(toolName: tool, originalChars: from, keptChars: to)
    }

    func testCutsInOneTurnAccumulate() {
        let log = ContextCutLog()
        log.recordCut(cut("read_file", 40_000, 6_000), conversationID: conversation, traceID: "t1")
        log.recordCut(cut("run_command", 90_000, 6_000), conversationID: conversation, traceID: "t1")
        XCTAssertEqual(log.lastTurn(for: conversation)?.cuts.count, 2)
    }

    /// ⚠️ "Last turn", not "ever": a new trace REPLACES the record. Without this the gauge would keep
    /// reporting a cut from a turn the user has long since moved past.
    func testANewTurnReplacesThePreviousOne() {
        let log = ContextCutLog()
        log.recordCut(cut("read_file", 40_000, 6_000), conversationID: conversation, traceID: "t1")
        log.recordCompaction(droppedExchanges: 2, conversationID: conversation, traceID: "t2")

        let record = log.lastTurn(for: conversation)
        XCTAssertEqual(record?.traceID, "t2")
        XCTAssertEqual(record?.cuts.count, 0, "the previous turn's cut leaked into this one")
        XCTAssertEqual(record?.compactedExchanges, 2)
    }

    func testConversationsAreKeptApart() {
        let log = ContextCutLog()
        let other = UUID()
        log.recordCut(cut("read_file", 40_000, 6_000), conversationID: conversation, traceID: "t1")
        XCTAssertNil(log.lastTurn(for: other))
    }

    func testNothingCutShowsNothing() {
        let log = ContextCutLog()
        log.recordCompaction(droppedExchanges: 0, conversationID: conversation, traceID: "t1")
        XCTAssertNil(log.lastTurn(for: conversation), "an empty record must not render a cut line")
        XCTAssertNil(log.lastTurn(for: nil))
    }

    /// The executor posts from off the main actor; the post must land.
    func testAPostFromTheExecutorLands() async throws {
        let conversation = UUID()
        ContextCutLog.post(cut: cut("git", 20_000, 5_000), conversationID: conversation, traceID: "tX")
        for _ in 0..<50 where ContextCutLog.shared.lastTurn(for: conversation) == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(ContextCutLog.shared.lastTurn(for: conversation)?.cuts.first?.toolName, "git")
    }
}

final class ContextGaugeWiringTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        // FIVE components: file → ChatInput → Shared → Interfaces → DevgenticTests → root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root = root.deletingLastPathComponent() }
        let url = root.appendingPathComponent(relative)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "running outside a checkout")
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// ⚠️ THE WIRING, producer side. Every `ContextCutLog` test passes with the executor never
    /// posting — and then the gauge's cut line simply never appears.
    func testTheExecutorReportsEveryKindOfCut() throws {
        let code = try source("Devgentic/Core/Backends/TextGen/ReAct/ReActAgentExecutor.swift")
        XCTAssertEqual(code.components(separatedBy: "ContextCutLog.post(").count - 1, 4,
                       "expected four reports: the native fit, native compaction, the scratchpad path, and a provider-reported overflow")
        XCTAssertTrue(code.contains("if let overflow = ContextCutLog.overflow(in: usage, step: currentIteration, windowTokens: input.contextWindowTokens) {"),
                      "overflow is no longer decided from the provider's real count")
        XCTAssertTrue(code.contains("ContextCutLog.post(overflow: overflow,"), "a detected overflow no longer reaches the gauge")
        XCTAssertTrue(code.contains("ContextCutLog.post(compactedExchanges: droppedNow"),
                      "native compaction no longer reaches the gauge")
    }

    /// Consumer side: the breakdown must actually read the log and render the rows.
    func testTheBreakdownRendersRowsAndTheCutLine() throws {
        let code = try source("Devgentic/Interfaces/Shared/ChatInput/ContextWindowGauge.swift")
        XCTAssertTrue(code.contains("ContextCutLog.shared.lastTurn(for: usage.conversationID)"),
                      "the breakdown no longer shows what the last turn cut")
        XCTAssertTrue(code.contains("if let breakdown = usage.breakdown { usageRows(breakdown) }"),
                      "the breakdown no longer shows what is using the window")
        XCTAssertTrue(code.contains("breakdown: occupancy?.breakdown"),
                      "resolve() no longer passes the breakdown through")
    }
}
