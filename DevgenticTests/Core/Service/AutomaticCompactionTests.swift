// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AutomaticCompactionTests.swift
//  DevgenticTests
//
//  Owner decisions 2026-09-27:
//  - automatic compaction has NO time limit;
//  - it is shown in the transcript like a manual one;
//  - both manual and automatic summarize with the conversation's own model by default, and with
//    the Intelligence Core only when it and its History Compaction feature are on.
//  Also the quit teardown's real bound (HITL Waiting Contract, quit item).
//

import XCTest
@testable import devgentic

final class AutomaticCompactionTests: XCTestCase {

    private let conversation = UUID()
    private let model = ProviderConfig(apiProvider: .anthropic, modelName: "claude-test", supportedModalities: .textOnly)

    private func history(pairs: Int) -> [ChatMessage] {
        (0..<pairs).flatMap { i in [
            ChatMessage(id: UUID(), conversationId: conversation, timestamp: Date(timeIntervalSince1970: TimeInterval(i * 2)),
                        sender: .user, content: .plainText("question \(i)")),
            ChatMessage(id: UUID(), conversationId: conversation, timestamp: Date(timeIntervalSince1970: TimeInterval(i * 2 + 1)),
                        sender: .agent, content: .plainText("answer \(i)")),
        ] }
    }

    // MARK: - Which model summarizes

    func testTheIntelligenceCoreSummarizesOnlyWhenItAndItsFeatureAreOn() throws {
        let suite = "AutomaticCompactionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(HistoryCompactionService.useIntelligenceCore(defaults: defaults, icModelSelected: true),
                       "IC off (the default) → the conversation's own model")
        defaults.set(true, forKey: AppSettings.isIntelligenceCoreEnabledKey)
        XCTAssertTrue(HistoryCompactionService.useIntelligenceCore(defaults: defaults, icModelSelected: true),
                      "IC on, feature unset (defaults on), model selected → IC")
        XCTAssertFalse(HistoryCompactionService.useIntelligenceCore(defaults: defaults, icModelSelected: false),
                       "no IC model → the conversation's own model")
        defaults.set(false, forKey: AppSettings.ciFeatureHistoryCompactionKey)
        XCTAssertFalse(HistoryCompactionService.useIntelligenceCore(defaults: defaults, icModelSelected: true),
                       "IC on but its History Compaction feature off → the conversation's own model")
    }

    // MARK: - An automatic run is shown in the transcript, start to finish

    @MainActor
    func testAnAutomaticRunIsShownRunningThenFinished() async throws {
        let activity = ManualCompactionActivity.shared
        defer { activity.dismiss(conversation) }
        // The production registration (MessagingCoordinator), re-registered so this test does not
        // depend on the host having built a coordinator.
        await HistoryCompactionService.shared.setActivitySink(
            begin: { id in await MainActor.run { ManualCompactionActivity.shared.begin(id, automatic: true) } },
            finish: { id, outcome in await MainActor.run { ManualCompactionActivity.shared.finish(id, outcome: outcome) } })

        let plan = try XCTUnwrap(HistoryCompactionService.planCompaction(
            chatHistory: history(pairs: 8), charBudget: 100_000, icContextWindow: 8_192,
            charBudgetTriggerRatio: 0, icPromptOverheadChars: 800))

        let release = AsyncGate()
        await HistoryCompactionService.shared.scheduleExecution(
            plan: plan, conversationID: conversation, conversationModel: model,
            summarizerOverride: { _ in await release.wait(); return "SUMMARY" },
            deliverOverride: { _, _ in })

        try await waitUntil { if case .running = activity.phase(for: self.conversation) { return true }; return false }
        XCTAssertTrue(activity.isAutomatic(conversation))
        let running = ManualCompactionActivity.presentation(for: activity.phase(for: conversation), newestMessageAt: nil,
                                                            automatic: activity.isAutomatic(conversation))
        XCTAssertEqual(running?.inProgress, true)
        XCTAssertTrue(running?.text.contains("automatically") == true, running?.text ?? "nil")

        await release.open()
        try await waitUntil { if case .finished = activity.phase(for: self.conversation) { return true }; return false }
        guard case .finished(.compacted, _) = activity.phase(for: conversation) else {
            return XCTFail("the finished row must report the compaction: \(String(describing: activity.phase(for: conversation)))")
        }
    }

    // MARK: - No time limit; planned in the turn, run after the answer, never gated on the IC

    func testCompactionHasNoTimeLimitAndIsNotGatedOnTheIntelligenceCore() throws {
        let service = try source("Devgentic/Core/Service/HistoryCompactionService.swift")
        XCTAssertFalse(service.contains("icTimeoutSeconds"), "the 30 s compaction limit is back")
        guard let callIC = service.range(of: "private func callIC(") else { return XCTFail("callIC moved") }
        let body = service[callIC.lowerBound...].prefix(1200)
        XCTAssertFalse(body.contains("Task.sleep") || body.contains("withThrowingTaskGroup"),
                       "callIC races a timer again")

        let agent = try source("Devgentic/Core/Backends/TextGen/AgentConnect.swift")
        XCTAssertFalse(agent.contains("if compactionEnabled, icMasterEnabled, icModelSelected {"),
                       "automatic compaction is gated on the Intelligence Core again")
        guard let finish = agent.range(of: "continuation.finish()\n\n                    // The answer is out — now summarize") else {
            return XCTFail("automatic compaction no longer starts AFTER the turn's answer")
        }
        XCTAssertTrue(agent[finish.upperBound...].prefix(400).contains("conversationModel: llmConfig"),
                      "automatic compaction does not default to the conversation's own model")

        let coordinator = try source("Devgentic/Interfaces/Main/MessagingCoordinator.swift")
        XCTAssertTrue(coordinator.contains("registerCompactionActivitySink()"),
                      "automatic compaction is no longer shown in the transcript")
    }

    // MARK: - Quit: a real bound, processes first

    func testQuitIsReallyBoundedAndKillsProcessesFirst() throws {
        XCTAssertEqual(AppDelegate.quitTeardownLimit, 5)
        XCTAssertLessThan(AppDelegate.quitPersistLimit, AppDelegate.quitTeardownLimit)
        let app = try source("Devgentic/AppDelegate.swift")
        XCTAssertTrue(app.contains("try? await DeadlineRace.run(limit: Self.quitTeardownLimit"),
                      "quit is back on a task-group 'watchdog' that waits for a hung step")
        guard let kill = app.range(of: "BackgroundProcessRegistry.shared.terminateAll()"),
              let mcp = app.range(of: "await MCPClientService.shared.disconnectAll()") else {
            return XCTFail("a teardown step moved — this pin checks nothing")
        }
        XCTAssertLessThan(kill.lowerBound, mcp.lowerBound,
                          "shell tasks must be killed BEFORE the MCP disconnect, which can hang")
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never became true")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}

/// Holds a fake summarizer "running" until the test opens it.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
