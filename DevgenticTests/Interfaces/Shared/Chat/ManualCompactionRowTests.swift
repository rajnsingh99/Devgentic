// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ManualCompactionRowTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class ManualCompactionRowTests: XCTestCase {

    private let conversation = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func compacted(_ checkpoint: UUID = UUID()) -> HistoryCompactionService.ManualOutcome {
        .compacted(turnPairs: 6, originalChars: 48_000, summaryChars: 4_000,
                   usedIntelligenceCore: false, checkpointID: checkpoint)
    }

    // MARK: - What the row says

    func testNothingIsShownWithoutACompaction() {
        XCTAssertNil(ManualCompactionActivity.presentation(for: nil, newestMessageAt: t0))
    }

    func testARunningCompactionShowsASpinner() throws {
        let p = try XCTUnwrap(ManualCompactionActivity.presentation(for: .running(startedAt: t0), newestMessageAt: t0))
        XCTAssertTrue(p.inProgress)
        XCTAssertEqual(p.kind, .compactionStarted)
    }

    /// A running row stays even if a message arrives meanwhile — it is still running.
    func testARunningRowIsNotRetiredByANewerMessage() {
        XCTAssertNotNil(ManualCompactionActivity.presentation(
            for: .running(startedAt: t0), newestMessageAt: t0.addingTimeInterval(60)))
    }

    func testASuccessOffersTheCheckpoint() throws {
        let checkpoint = UUID()
        let p = try XCTUnwrap(ManualCompactionActivity.presentation(
            for: .finished(compacted(checkpoint), finishedAt: t0), newestMessageAt: t0.addingTimeInterval(-5)))
        XCTAssertFalse(p.inProgress)
        XCTAssertEqual(p.kind, .compactionCompleted)
        XCTAssertEqual(p.checkpointID, checkpoint, "'Show summary' has nothing to jump to")
        XCTAssertTrue(p.text.contains("Summarized 6"), p.text)
    }

    func testAFailureSaysSoAndThatNothingChanged() throws {
        let p = try XCTUnwrap(ManualCompactionActivity.presentation(
            for: .finished(.failed("model unavailable"), finishedAt: t0), newestMessageAt: nil))
        XCTAssertEqual(p.kind, .compactionFailed)
        XCTAssertTrue(p.text.contains("model unavailable"), p.text)
        XCTAssertTrue(p.text.contains("History is unchanged"), p.text)
        XCTAssertNil(p.checkpointID)
    }

    /// Once the conversation moves on, the row is history — the checkpoint card is the record.
    func testAFinishedRowRetiresOnceANewerMessageExists() {
        XCTAssertNil(ManualCompactionActivity.presentation(
            for: .finished(compacted(), finishedAt: t0), newestMessageAt: t0.addingTimeInterval(1)))
    }

    // MARK: - State

    func testASecondStartInTheSameConversationIsRefused() {
        let activity = ManualCompactionActivity()
        XCTAssertTrue(activity.begin(conversation, now: t0))
        XCTAssertFalse(activity.begin(conversation, now: t0.addingTimeInterval(1)),
                       "a second run would paint 'already running' over the real one")
        XCTAssertEqual(activity.phase(for: conversation), .running(startedAt: t0))
    }

    func testStateIsPerConversation() {
        let activity = ManualCompactionActivity()
        activity.begin(conversation, now: t0)
        XCTAssertNil(activity.phase(for: UUID()), "another conversation showed this one's compaction")
    }

    func testFinishThenDismissClears() {
        let activity = ManualCompactionActivity()
        activity.begin(conversation, now: t0)
        activity.finish(conversation, outcome: .nothingToCompact, now: t0)
        XCTAssertEqual(activity.phase(for: conversation), .finished(.nothingToCompact, finishedAt: t0))
        activity.dismiss(conversation)
        XCTAssertNil(activity.phase(for: conversation))
    }

    // MARK: - Wiring

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }

    /// The gauge action must report to the row — else the row never appears.
    func testTheGaugeActionReportsStartAndOutcome() throws {
        let text = try source("Devgentic/Interfaces/Shared/ChatInput/ChatInputAreaView.swift")
        XCTAssertTrue(text.contains("let ownsRow = activity.begin(conversationID)"), "the start is not reported")
        XCTAssertTrue(text.contains("if ownsRow { activity.finish(conversationID, outcome: outcome) }"),
                      "the outcome is not reported")
    }

    func testTheTranscriptMountsTheRow() throws {
        let text = try source("Devgentic/Interfaces/Shared/Chat/ChatHistoryView.swift")
        XCTAssertTrue(text.contains("ManualCompactionRow("), "the transcript no longer shows the row")
    }
}
