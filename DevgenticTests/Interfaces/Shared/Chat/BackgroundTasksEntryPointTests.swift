// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTasksEntryPointTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class BackgroundTasksEntryPointTests: XCTestCase {

    // MARK: - The pill's rule

    func testThePillIsHiddenWithNoConversation() {
        XCTAssertFalse(BackgroundTasksFloatingButton.shouldShow(
            hasConversation: false, taskCount: 3, panelIsOpen: false))
    }

    func testThePillIsHiddenWhenNothingHasEverRun() {
        XCTAssertFalse(BackgroundTasksFloatingButton.shouldShow(
            hasConversation: true, taskCount: 0, panelIsOpen: false),
            "a pill offering an empty list is noise in a contested corner")
    }

    func testThePillIsHiddenWhileThePanelIsAlreadyOpen() {
        XCTAssertFalse(BackgroundTasksFloatingButton.shouldShow(
            hasConversation: true, taskCount: 3, panelIsOpen: true),
            "it would be pointing at itself")
    }

    func testThePillIsShownWhenThereAreTasksAndThePanelIsClosed() {
        XCTAssertTrue(BackgroundTasksFloatingButton.shouldShow(
            hasConversation: true, taskCount: 1, panelIsOpen: false))
    }

    /// ⚠️ DELIBERATE, and the reason the rule counts tasks rather than RUNNING tasks. "What did
    /// that build actually print" is asked after the run, not during. A pill that disappeared on
    /// completion would take the answer with it — and the card that could otherwise reopen the
    /// panel has scrolled away by then, which is the whole reason this pill exists.
    func testThePillSurvivesEveryTaskFinishing() {
        XCTAssertTrue(BackgroundTasksFloatingButton.shouldShow(
            hasConversation: true, taskCount: 4, panelIsOpen: false),
            "the list is history; history does not stop being worth reading")
    }

    // MARK: - The pill is actually mounted

    /// Without this the pill is a file nothing renders — the F2-shipped-dead shape.
    func testTheMainViewMountsThePill() throws {
        let source = try sourceFile("Devgentic/Interfaces/Main/Views/MainApplicationView.swift")
        let code = stripComments(source)
        XCTAssertTrue(code.contains("BackgroundTasksFloatingButton("),
                      "nothing mounts the pill, so the panel is back to one entry point")
        XCTAssertTrue(code.contains("floatingPills"),
                      "the pill must be mounted through the shared stack, not independently")
    }

    /// Both pills want the same top-trailing corner. Two independent corner mounts draw on top of
    /// each other — which is what happened before they were stacked.
    func testBothPillsShareOneStackedContainer() throws {
        let source = try sourceFile("Devgentic/Interfaces/Main/Views/MainApplicationView.swift")
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("private var floatingPills") }) else {
            return XCTFail("floatingPills not found — this guard is checking nothing")
        }
        let body = stripComments(lines[start..<min(start + 25, lines.count)].joined(separator: "\n"))

        XCTAssertTrue(body.contains("VStack"), "the two pills must be stacked, not overlaid")
        XCTAssertTrue(body.contains("CodeViewerFloatingButton("))
        XCTAssertTrue(body.contains("BackgroundTasksFloatingButton("))
        XCTAssertEqual(body.components(separatedBy: "alignment: .topTrailing").count - 1, 1,
                       "one corner anchor for the pair — a second would reintroduce the overlap")
    }

    func testThePillOpensThePanel() throws {
        let source = try sourceFile("Devgentic/Interfaces/Shared/Chat/BackgroundTasksFloatingButton.swift")
        XCTAssertTrue(stripComments(source).contains("showBackgroundTasks("),
                      "the pill renders but does nothing")
    }

    // MARK: - `discard` is wired into deletion

    /// ⚠️ Pinned in `drainLiveExecution` specifically. `deleteMultipleConversations` is a SECOND
    /// teardown that re-lists the same side stores by hand, and a cleanup added to one path and
    /// not the other is how this file grows a leak. Both call `drainLiveExecution`; neither calls
    /// the other's body.
    func testConversationDeletionDiscardsBackgroundTasks() throws {
        let source = try sourceFile("Devgentic/Interfaces/Main/ConversationManagementCoordinator.swift")
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("private func drainLiveExecution(") }) else {
            return XCTFail("drainLiveExecution not found — this guard is checking nothing")
        }
        let body = stripComments(lines[start..<min(start + 40, lines.count)].joined(separator: "\n"))
        XCTAssertTrue(body.contains("BackgroundProcessRegistry.shared.discard("),
                      "a deleted conversation's background tasks run on, writing to a log no "
                      + "surface can reach, until the app quits")
    }

    func testBothDeletePathsDrain() throws {
        let source = try sourceFile("Devgentic/Interfaces/Main/ConversationManagementCoordinator.swift")
        let code = stripComments(source)
        for site in ["func deleteConversation(conversationID:", "func deleteMultipleConversations("] {
            guard let start = code.range(of: site) else {
                return XCTFail("\(site) not found — this guard is checking nothing")
            }
            let body = String(code[start.lowerBound...].prefix(2_000))
            XCTAssertTrue(body.contains("drainLiveExecution("),
                          "\(site) does not drain, so nothing in drainLiveExecution — including "
                          + "the background-task discard — runs for it")
        }
    }

    // MARK: - What `discard` does to a LIVE task

    /// The existing coverage discards a FINISHED task, where killing nothing looks identical to
    /// killing correctly. Deletion is the case that matters: the process is usually still running.
    ///
    /// ⚠️ THE PROCESS IS OBSERVED THROUGH A MARKER FILE OUTSIDE THE REGISTRY ROOT, not through the
    /// registry. Asserting only that the records and the log directory are gone would have named
    /// this test after a kill it never checked — `discard` can empty its map and delete a folder
    /// while leaving the process running, which is exactly the leak it exists to close. The log
    /// itself cannot serve as the witness: `discard` deletes it.
    func testDiscardingKillsATaskThatIsStillRunning() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgdiscard-\(UUID().uuidString)", isDirectory: true)
        let marker = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgdiscard-marker-\(UUID().uuidString).txt")
        let registry = BackgroundProcessRegistry(rootDirectory: root)
        defer {
            registry.terminateAll()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: marker)
        }
        let conversation = UUID()
        let task = try registry.launch(
            command: "while true; do echo tick >> \(marker.path); sleep 0.05; done",
            workingDirectory: NSTemporaryDirectory(),
            timeout: 60, conversationID: conversation)
        XCTAssertEqual(registry.snapshot(conversationID: conversation, taskID: task.id)?.status, .running)

        // It has to be demonstrably alive first, or "it stopped writing" proves nothing.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, size(of: marker) == 0 { usleep(20_000) }
        XCTAssertGreaterThan(size(of: marker), 0, "the task never started writing — bad fixture")

        registry.discard(conversationID: conversation)

        XCTAssertTrue(registry.snapshots(conversationID: conversation).isEmpty,
                      "the records survived the discard")
        let directory = root.appendingPathComponent(conversation.uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                       "the log directory survived the discard")

        // Long enough for several more ticks had anything survived. The `echo` is a child of the
        // zsh, so this also covers the tree kill: signalling the shell alone leaves the loop.
        let settled = size(of: marker)
        usleep(400_000)
        XCTAssertEqual(size(of: marker), settled,
                       "the process kept writing after its conversation was deleted — discard "
                       + "emptied its records and removed its log while the work ran on")
    }

    private func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) .flatMap { $0 } ?? 0
    }

    /// Ids restart after a discard — the counter goes with the records, or the next task in a
    /// re-created conversation is `bg_7` with no `bg_1`..`bg_6` to explain it.
    func testDiscardingResetsTheTaskCounter() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgcounter-\(UUID().uuidString)", isDirectory: true)
        let registry = BackgroundProcessRegistry(rootDirectory: root)
        defer {
            registry.terminateAll()
            try? FileManager.default.removeItem(at: root)
        }
        let conversation = UUID()
        _ = try registry.launch(command: "true", workingDirectory: NSTemporaryDirectory(),
                                timeout: 30, conversationID: conversation)
        let second = try registry.launch(command: "true", workingDirectory: NSTemporaryDirectory(),
                                         timeout: 30, conversationID: conversation)
        XCTAssertEqual(second.id, "bg_2")

        registry.discard(conversationID: conversation)

        let afterwards = try registry.launch(command: "true", workingDirectory: NSTemporaryDirectory(),
                                             timeout: 30, conversationID: conversation)
        XCTAssertEqual(afterwards.id, "bg_1", "the counter outlived the records it numbered")
    }

    // MARK: - Source access

    private func stripComments(_ source: String) -> String {
        source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return source
    }
}
