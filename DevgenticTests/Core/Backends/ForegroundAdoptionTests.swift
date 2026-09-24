// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ForegroundAdoptionTests.swift
//  DevgenticTests
//
//  A foreground `batch_command` used to be invisible and unreachable while it ran:
//
//    - no card, so a 15-minute build showed nothing
//    - not stoppable — `Stop` cancels the Swift Task, but `ProcessRunner.run` is synchronous on a
//      GCD queue and never notices
//    - ORPHANED at quit, because `terminateAll()` walks registry entries and this path had none
//
//  That last one is the same launchd-orphan defect the background path was fixed for on
//  2026-09-21; it was simply still live on the other branch.
//

import XCTest
@testable import devgentic

final class ForegroundAdoptionTests: XCTestCase {

    private let conversation = UUID()

    override func tearDown() {
        BackgroundProcessRegistry.shared.discard(conversationID: conversation)
        super.tearDown()
    }

    private func arguments(_ json: String) throws -> ShellCommandArguments {
        try JSONDecoder().decode(ShellCommandArguments.self, from: Data(json.utf8))
    }

    /// THE WIRING. A foreground run must appear in the registry — that is what makes it
    /// stoppable and what quit-time teardown walks.
    func testAForegroundRunIsRegistered() async throws {
        let tool = RunCommandTool(conversationID: conversation)
        let output = try await tool.call(arguments: arguments(
            #"{"command":"echo foreground-registered","working_directory":"/tmp"}"#))

        XCTAssertTrue(output.contains("foreground-registered"), "the result still reaches the caller")

        let tasks = BackgroundProcessRegistry.shared.snapshots(conversationID: conversation)
        XCTAssertEqual(tasks.count, 1, "the foreground run left no registry entry, so nothing can "
                       + "stop it and quit-time teardown cannot see it")
        XCTAssertEqual(tasks.first?.command, "echo foreground-registered")
    }

    /// It must also REACH a terminal state. An entry stuck at `.running` would make `terminateAll`
    /// signal a long-dead pid at quit and would render a finished command as live.
    func testAForegroundRunReachesATerminalStatus() async throws {
        _ = try await RunCommandTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"exit 3","working_directory":"/tmp"}"#))

        let task = try XCTUnwrap(BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first)
        XCTAssertEqual(task.status, .exited(code: 3))
        XCTAssertNotNil(task.finishedAt)
    }

    /// The log is written once from the finished result — see `adopt`. It is not live, but it must
    /// not be empty either, or "Open full log" on the card opens nothing.
    func testTheOutputIsWrittenToTheLogOnCompletion() async throws {
        _ = try await RunCommandTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"echo written-to-log","working_directory":"/tmp"}"#))

        let task = try XCTUnwrap(BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first)
        let log = try XCTUnwrap(BackgroundProcessRegistry.shared.readLog(
            conversationID: conversation, taskID: task.id))
        XCTAssertTrue(log.text.contains("written-to-log"), "the card has nothing to show: \(log.text)")
    }

    /// A timeout kill is still reported as a kill, not as an exit code the command chose.
    func testATimedOutForegroundRunIsRecordedAsTimedOut() async throws {
        _ = try await RunCommandTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"sleep 30","working_directory":"/tmp","timeout_seconds":1}"#))

        let task = try XCTUnwrap(BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first)
        XCTAssertEqual(task.status, .timedOut)
    }

    /// ⚠️ Guards the hook itself. `ProcessRunner` attaches its pipes BEFORE `run()` — or the output
    /// is lost — and there is no pid before it, so the adoption must happen in `onStarted`, inside
    /// `execute`. Doing it around the call instead silently loses either the output or the handle.
    func testAdoptionUsesTheOnStartedHook() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = "Devgentic/Interfaces/Main/Views/Tooling/Local/CodingAssistantTools.swift"
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("CodingAssistantTools.swift not reachable — running outside a checkout")
        }
        XCTAssertTrue(source.contains("onStarted: adopt"),
                      "the foreground path no longer adopts through onStarted; a handle taken "
                      + "outside ProcessRunner is taken before the pid exists or after the pipes "
                      + "are gone")
    }
}
