// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TurnFileChangesTests.swift
//  DevgenticTests
//
//  The "Edited N files" card under a Code turn (2026-10-04). Built from each write's persisted
//  `ActionEffect`; the session-only snapshots only sharpen counts for a file edited twice.
//

import XCTest
@testable import devgentic

final class TurnFileChangesTests: XCTestCase {

    /// A real write row: params carry the content, and the effect is derived exactly as
    /// `ActiveStreamManager` derives it on completion.
    private func write(_ path: String, content: String, before: String?, success: Bool = true,
                       keepSnapshot: Bool = true) -> ToolExecutionData {
        var data = ToolExecutionData(id: UUID(), name: "write_file", params: "{}", output: "ok",
                                     isSuccess: success, isExecuting: false)
        let params = try! JSONSerialization.data(withJSONObject: ["path": path, "content": content])
        data.params = String(data: params, encoding: .utf8)!
        data.preWriteContent = before
        data.effect = ActionEffect.from(toolExecution: data)
        // A relaunch drops the snapshot (it is never persisted); the effect stays.
        if !keepSnapshot { data.preWriteContent = nil }
        return data
    }

    private func call(_ name: String) -> ToolExecutionData {
        ToolExecutionData(id: UUID(), name: name, params: "{}", output: "ok", isSuccess: true, isExecuting: false)
    }

    func testOneRowPerFileWithItsCounts() throws {
        let summary = TurnFileChanges.summarize([
            write("/p/A.swift", content: "a\nb\nc", before: "a"),
            call("read_file"),
            write("/p/B.swift", content: "x", before: ""),
        ])
        XCTAssertEqual(summary.files.map(\.fileName), ["A.swift", "B.swift"], "first-seen order, reads excluded")
        let a = try XCTUnwrap(summary.files.first)
        XCTAssertEqual(a.added, 2)
        XCTAssertEqual(a.removed, 0)
        XCTAssertTrue(a.isNet)
        XCTAssertTrue(summary.files[1].isNew, "a file that did not exist before is marked new")
        XCTAssertEqual(summary.added, 3)
    }

    /// ⚠️ Edited twice in one turn: one row, and — while both ends are in memory — the NET change,
    /// so a line added and then removed again is not reported as two changes.
    func testAFileEditedTwiceIsOneRowWithItsNetChange() throws {
        let summary = TurnFileChanges.summarize([
            write("/p/A.swift", content: "a\ntemp", before: "a"),
            write("/p/A.swift", content: "a", before: "a\ntemp"),
        ])
        let a = try XCTUnwrap(summary.files.first)
        XCTAssertEqual(summary.files.count, 1, "one file edited twice became two rows")
        XCTAssertEqual(a.writeCount, 2)
        XCTAssertEqual(a.added, 0, "the temporary line was counted although it is gone")
        XCTAssertEqual(a.removed, 0)
        XCTAssertTrue(a.isNet)
    }

    /// After a relaunch the snapshots are gone: the per-write counts are summed, and SAID to be.
    func testWithoutSnapshotsTheCountsAreSummedAndMarked() throws {
        let summary = TurnFileChanges.summarize([
            write("/p/A.swift", content: "a\ntemp", before: "a", keepSnapshot: false),
            write("/p/A.swift", content: "a", before: "a\ntemp", keepSnapshot: false),
        ])
        let a = try XCTUnwrap(summary.files.first)
        XCTAssertEqual(a.added, 1)
        XCTAssertEqual(a.removed, 1)
        XCTAssertFalse(a.isNet, "a summed count must not claim to be the net change")
    }

    func testFailedWritesAndNoOpWritesAreNotListed() {
        // A failed row normally carries no effect (the resolver needs a success). The card still
        // filters on the outcome itself, so a row that ended failed AFTER its effect was derived
        // — or one stored by another path — is never listed as an edit.
        var failed = write("/p/A.swift", content: "new", before: "old")
        failed.isSuccess = false
        XCTAssertNotNil(failed.effect, "the fixture must carry an effect, or the outcome filter is untested")
        let summary = TurnFileChanges.summarize([
            failed,
            write("/p/B.swift", content: "same", before: "same"),
        ])
        XCTAssertTrue(summary.isEmpty, "a failed or byte-identical write is not an edit")
    }

    func testTwoSpellingsOfOnePathAreOneRow() {
        let summary = TurnFileChanges.summarize([
            write("/p/./A.swift", content: "a\nb", before: "a"),
            write("/p/A.swift", content: "a\nb\nc", before: "a\nb"),
        ])
        XCTAssertEqual(summary.files.count, 1)
    }

    /// Commands can change files no edit recorded — the card must say so, not imply completeness.
    func testACommandOrBackgroundTaskIsFlagged() {
        let edit = write("/p/A.swift", content: "a\nb", before: "a")
        XCTAssertFalse(TurnFileChanges.summarize([edit]).ranCommands)
        XCTAssertTrue(TurnFileChanges.summarize([edit, call("run_command")]).ranCommands)
        XCTAssertTrue(TurnFileChanges.summarize([edit, call("git")]).ranCommands)
        XCTAssertTrue(TurnFileChanges.summarize([edit], startedTasks: true).ranCommands)
    }

    // MARK: - Where it shows

    @MainActor
    func testShownUnderAFinishedCodeTurnOnly() {
        let code = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("done"))
        code.profileType = .code
        XCTAssertTrue(TurnFileChanges.showsCard(for: code))

        code.isStreaming = true
        XCTAssertFalse(TurnFileChanges.showsCard(for: code), "the card must wait for the run to finish")

        let chat = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("done"))
        chat.profileType = .agent
        XCTAssertFalse(TurnFileChanges.showsCard(for: chat), "scope is the Code interface")
    }

    @MainActor
    func testTheTurnsCallsAreReadFromItsTimeline() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(""))
        message.timelineEvents = [.toolExecution(write("/p/A.swift", content: "a\nb", before: "a"))]
        let (calls, startedTasks) = TurnFileChanges.toolCalls(in: message)
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(startedTasks)
    }

    func testTheBubbleMountsTheCard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = "Devgentic/Interfaces/Shared/Chat/AgentBubbleContentView.swift"
        guard let code = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        XCTAssertTrue(code.contains("if TurnFileChanges.showsCard(for: message) {\n                TurnFileChangesCard(message: message)"),
                      "the Code turn no longer shows what it edited")
    }
}
