// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ForegroundAdoptionTests.swift
//  DevgenticTests
//
//  2026-09-24: foreground runs now write their log LIVE through the registry, exactly as background
//  tasks do — see the tests below `testAForegroundRunReachesATerminalStatus`.
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

    /// The log is written LIVE (2026-09-24), not once at the end: it exists while the command runs,
    /// so a crash mid-build still leaves it on disk.
    func testTheLogExistsWhileTheCommandIsStillRunning() async throws {
        let tool = RunCommandTool(conversationID: conversation)
        async let result = tool.call(arguments: arguments(
            #"{"command":"echo early-line; sleep 2","working_directory":"/tmp"}"#))

        var sawLive = false
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !sawLive {
            if let task = BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first,
               task.status == .running,
               let text = try? String(contentsOf: task.logURL, encoding: .utf8),
               text.contains("early-line") {
                sawLive = true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await result
        XCTAssertTrue(sawLive, "the log did not hold the command's output while it was running — "
                      + "it is being written only at the end again, so a crash leaves nothing")
    }

    /// stdout and stderr land in ONE log in the order they happened, and that is what the model
    /// gets back. The old path returned stdout, then a separate `[stderr]` block.
    func testStdoutAndStderrComeBackInterleavedInOrder() async throws {
        let output = try await RunCommandTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"echo one; echo two >&2; echo three","working_directory":"/tmp"}"#))
        let one = try XCTUnwrap(output.range(of: "one")), two = try XCTUnwrap(output.range(of: "two")),
            three = try XCTUnwrap(output.range(of: "three"))
        XCTAssertTrue(one.lowerBound < two.lowerBound && two.lowerBound < three.lowerBound,
                      "stderr was not interleaved with stdout: \(output)")
        XCTAssertFalse(output.contains("[stderr]"), "the streams were split: \(output)")
    }

    func testAForegroundRunIsNamedAsOneAndItsLogFileSaysWhatItRan() async throws {
        _ = try await RunCommandTool(conversationID: conversation).call(arguments: arguments(
            #"{"command":"echo hi","working_directory":"/tmp","task_name":"Say Hello"}"#))
        let task = try XCTUnwrap(BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first)
        XCTAssertTrue(task.id.hasPrefix("fg_"), "a foreground run carried the background prefix: \(task.id)")
        XCTAssertTrue(task.logURL.lastPathComponent.hasSuffix("_\(task.id)_say-hello.log"),
                      "unexpected log name: \(task.logURL.lastPathComponent)")
    }

    /// A timeout kill is still reported as a kill, not as an exit code the command chose.
    func testATimedOutForegroundRunIsRecordedAsTimedOut() async throws {
        // D-17: THROWN as a timeout (so it is not recorded as a successful call), output inside.
        let output: String
        do {
            _ = try await RunCommandTool(conversationID: conversation).call(arguments: arguments(
                #"{"command":"echo before-kill; sleep 30","working_directory":"/tmp","timeout_seconds":1}"#))
            return XCTFail("a command killed at its own timeout must be reported as a timeout")
        } catch ShellCommandError.timedOut(_, let observation) {
            output = observation
        }

        let task = try XCTUnwrap(BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).first)
        XCTAssertEqual(task.status, .timedOut)
        XCTAssertTrue(output.contains("timed out after 1s"), output)
        XCTAssertTrue(output.contains("before-kill"), "the output written before the kill was lost: \(output)")
    }

    /// `run_command` opts out of output sniffing, so a REFUSAL returned as a string would be recorded
    /// as a successful call. It must throw. (`execute_shell` held this until its removal.)
    func testARefusedCommandThrowsRatherThanReturning() async throws {
        do {
            let output = try await RunCommandTool(conversationID: conversation).call(arguments: arguments(
                #"{"command":"vim","working_directory":"/tmp"}"#))
            XCTFail("a refused command must throw, not return: \(output)")
        } catch let error as ShellCommandError {
            guard case .refused = error else { return XCTFail("expected .refused, got \(error)") }
        }
        XCTAssertTrue(BackgroundProcessRegistry.shared.snapshots(conversationID: conversation).isEmpty,
                      "a refused command must not have run")
    }

    /// ⚠️ THE WIRING. The foreground path must go through the registry's live-log launch and wait on
    /// it — not back through `ProcessRunner`'s pipes.
    func testTheForegroundPathLaunchesThroughTheRegistryAndWaits() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = "Devgentic/Interfaces/Main/Views/Tooling/Local/CodingAssistantTools.swift"
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("CodingAssistantTools.swift not reachable — running outside a checkout")
        }
        XCTAssertTrue(source.contains("foreground: true)"), "the foreground path no longer launches through the registry")
        XCTAssertTrue(source.contains("await registry.waitUntilEnded(conversationID: conversationID, taskID: stopID)"),
                      "the foreground path no longer waits on the registry")
        // The stop hook (HITL Waiting Contract, slice 1): a cancelled wait must STOP the command.
        // Without it Stop and every timeout left a foreground command running to its full bound
        // (Timeout inventory D-02). `ToolTimeoutContractTests` proves the behaviour; this pins
        // that the handler is wired on the wait itself.
        XCTAssertTrue(source.contains("} onCancel: {\n            _ = registry.stop(conversationID: conversationID, taskID: stopID)"),
                      "the foreground wait no longer stops the command when it is cancelled")
    }
}

/// The log file name — `<yyyyMMdd-HHmmss>_<id>_<slug>.log` (2026-09-24).
final class CommandLogNamingTests: XCTestCase {

    private var root: URL!
    private var registry: BackgroundProcessRegistry!
    private let conversation = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lognaming-tests-\(UUID().uuidString)", isDirectory: true)
        registry = BackgroundProcessRegistry(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        registry?.terminateAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    func testTheNameCarriesTheTimeTheIdAndASlug() {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 9; parts.day = 24; parts.hour = 13; parts.minute = 22; parts.second = 5
        let date = Calendar.current.date(from: parts)!
        XCTAssertEqual(BackgroundProcessRegistry.logFileName(id: "bg_1", startedAt: date, name: nil, command: "npm run dev"),
                       "20260924-132205_bg_1_npm-run-dev.log")
        XCTAssertEqual(BackgroundProcessRegistry.logFileName(id: "fg_2", startedAt: date, name: "Build & Test", command: "swift test"),
                       "20260924-132205_fg_2_build-test.log", "the task name wins over the command")
    }

    func testTheSlugIsSafeForAFileNameAndBounded() {
        XCTAssertEqual(BackgroundProcessRegistry.logSlug("cd /tmp && ls -la | grep \"x\""), "cd-tmp-ls-la-grep-x")
        XCTAssertEqual(BackgroundProcessRegistry.logSlug("  ~/..//  "), "")
        XCTAssertLessThanOrEqual(BackgroundProcessRegistry.logSlug(String(repeating: "abc ", count: 50)).count, 40)
    }

    /// ⚠️ THE BUG THIS NAMING FIXES. The counter restarts every launch while the folder survives, so
    /// the first task after a relaunch APPENDED to the previous run's `bg_1.log`.
    func testATaskAfterARelaunchNeverWritesIntoAnEarlierRunsLog() throws {
        let first = try registry.launch(command: "echo from-the-first-run", workingDirectory: NSTemporaryDirectory(),
                                        timeout: 30, conversationID: conversation)
        _ = try XCTUnwrap(waitForEnd(first.id, in: registry))
        registry.terminateAll()

        let relaunched = BackgroundProcessRegistry(rootDirectory: root)    // counters start over
        defer { relaunched.terminateAll() }
        let second = try relaunched.launch(command: "echo from-the-second-run", workingDirectory: NSTemporaryDirectory(),
                                           timeout: 30, conversationID: conversation)
        XCTAssertEqual(second.id, first.id, "fixture: the id must repeat for this to test anything")
        XCTAssertNotEqual(second.logURL, first.logURL, "the relaunched task reused the earlier log file")
        let done = try XCTUnwrap(waitForEnd(second.id, in: relaunched))
        XCTAssertFalse(done.tail.contains("from-the-first-run"), "the new task's log holds the old run's output: \(done.tail)")
    }

    func testForegroundAndBackgroundShareOneCounter() throws {
        let bg = try registry.launch(command: "true", workingDirectory: NSTemporaryDirectory(),
                                     timeout: 30, conversationID: conversation)
        let fg = try registry.launch(command: "true", workingDirectory: NSTemporaryDirectory(),
                                     timeout: 30, conversationID: conversation, foreground: true)
        XCTAssertEqual(bg.id, "bg_1")
        XCTAssertEqual(fg.id, "fg_2")
    }

    private func waitForEnd(_ id: String, in registry: BackgroundProcessRegistry) -> BackgroundProcessRegistry.Snapshot? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let task = registry.snapshot(conversationID: conversation, taskID: id), task.status.isTerminal {
                usleep(100_000)     // let the final drain land
                return registry.snapshot(conversationID: conversation, taskID: id)
            }
            usleep(50_000)
        }
        return nil
    }
}
