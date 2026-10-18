// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ManualCompactionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ManualCompactionTests: XCTestCase {

    private let conversation = UUID()
    private let model = ProviderConfig(apiProvider: .anthropic, modelName: "claude-test", supportedModalities: .textOnly)

    /// `pairs` user/agent turns of SHORT text — far under the automatic trigger.
    private func history(pairs: Int) -> [ChatMessage] {
        (0..<pairs).flatMap { i in [
            ChatMessage(id: UUID(), conversationId: conversation,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(i * 2)),
                        sender: .user, content: .plainText("question \(i)")),
            ChatMessage(id: UUID(), conversationId: conversation,
                        timestamp: Date(timeIntervalSince1970: TimeInterval(i * 2 + 1)),
                        sender: .agent, content: .plainText("answer \(i)")),
        ] }
    }

    /// Records what the fake summarizer was asked and what was delivered.
    private actor Recorder {
        var prompts: [[[String: String]]] = []
        var delivered: [ChatMessage] = []
        func prompt(_ m: [[String: String]]) { prompts.append(m) }
        func deliver(_ m: ChatMessage) { delivered.append(m) }
    }

    /// ⚠️ THE POINT OF THE BUTTON: it compacts when the user asks, even though the history is far
    /// below the automatic trigger. The automatic planner refuses this exact history.
    func testCompactNowSummarizesAHistoryTheAutomaticTriggerWouldSkip() async throws {
        let history = history(pairs: 8)
        XCTAssertNil(HistoryCompactionService.planCompaction(
            chatHistory: history, charBudget: PromptFitCheck.historyCharBudget(forContextWindow: 8_192),
            icContextWindow: 8_192, charBudgetTriggerRatio: 0.6, icPromptOverheadChars: 800),
            "premise: the automatic trigger skips this history")

        let recorder = Recorder()
        let outcome = await HistoryCompactionService.shared.compactNow(
            chatHistory: history, conversationID: conversation, contextWindow: 8_192, fallbackModel: model,
            summarizerOverride: { messages in await recorder.prompt(messages); return "- earlier turns summarized" },
            deliverOverride: { message, _ in await recorder.deliver(message) })

        guard case .compacted(let pairs, _, _, _, _) = outcome else { return XCTFail("expected a compaction, got \(outcome)") }
        XCTAssertGreaterThan(pairs, 0)
        let delivered = await recorder.delivered
        XCTAssertEqual(delivered.count, 1, "the checkpoint was not delivered")
        if case .checkpoint(let summary) = delivered.first?.content {
            XCTAssertEqual(summary, "- earlier turns summarized")
        } else {
            XCTFail("the delivered message is not a checkpoint")
        }
    }

    /// The summarizer gets the same prompt automatic compaction uses — system + turns.
    func testTheSummarizerIsAskedWithTheCompactionPrompt() async {
        let recorder = Recorder()
        _ = await HistoryCompactionService.shared.compactNow(
            chatHistory: history(pairs: 8), conversationID: conversation, contextWindow: 8_192, fallbackModel: model,
            summarizerOverride: { messages in await recorder.prompt(messages); return "summary" },
            deliverOverride: { _, _ in })

        let prompt = await recorder.prompts.first
        XCTAssertEqual(prompt?.first?["role"], "system")
        XCTAssertTrue(prompt?.last?["content"]?.contains("question 0") ?? false,
                      "the oldest turn was not in what the model was asked to summarize")
    }

    /// Too little history: the 5 most recent messages are always kept and at least 4 older ones
    /// are needed. Nothing is summarized and the model is never called.
    func testAShortHistoryHasNothingToCompact() async {
        let recorder = Recorder()
        let outcome = await HistoryCompactionService.shared.compactNow(
            chatHistory: history(pairs: 3), conversationID: conversation, contextWindow: 8_192, fallbackModel: model,
            summarizerOverride: { messages in await recorder.prompt(messages); return "x" },
            deliverOverride: { _, _ in })

        XCTAssertEqual(outcome, .nothingToCompact)
        let calls = await recorder.prompts.count
        XCTAssertEqual(calls, 0, "the model was called for a history with nothing to compact")
    }

    /// An empty summary must not land as a blank checkpoint that silently replaces history.
    func testAnEmptySummaryFailsAndDeliversNothing() async {
        let recorder = Recorder()
        let outcome = await HistoryCompactionService.shared.compactNow(
            chatHistory: history(pairs: 8), conversationID: conversation, contextWindow: 8_192, fallbackModel: model,
            summarizerOverride: { _ in "   " },
            deliverOverride: { message, _ in await recorder.deliver(message) })

        guard case .failed = outcome else { return XCTFail("expected a failure, got \(outcome)") }
        let delivered = await recorder.delivered.count
        XCTAssertEqual(delivered, 0)
    }

    // MARK: - The wiring

    /// ⚠️ Everything above passes if the gauge's button calls nothing. This fails if the composer
    /// stops routing the button to `compactNow`.
    func testTheGaugeButtonReachesCompactNow() throws {
        // FOUR components: file → Service → Core → DevgenticTests → root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root = root.deletingLastPathComponent() }
        let url = root.appendingPathComponent("Devgentic/Interfaces/Shared/ChatInput/ChatInputAreaView.swift")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "running outside a checkout")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("onCompact: { await compactHistoryNow() }"), "the gauge's Compact button is not wired")
        XCTAssertTrue(code.contains("HistoryCompactionService.shared.compactNow("), "the composer no longer calls compactNow")
    }
}
