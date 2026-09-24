// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundProcessRegistryTests.swift
//  DevgenticTests
//
//  Tier 1 of the background-task work. Four defects are pinned here, each of which shipped:
//  output discarded to /dev/null, `timeout_seconds` computed and never applied on the background
//  branch, no handle retained so nothing could be polled or stopped, and no quit-time teardown.
//
//  ⚠️ Every test builds its OWN registry against a scratch directory. Sharing `.shared` would
//  leak live children into the next test — the exact failure this type exists to prevent.
//

import XCTest
@testable import devgentic

final class BackgroundProcessRegistryTests: XCTestCase {

    private var root: URL!
    private var registry: BackgroundProcessRegistry!
    private let conversation = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgproc-tests-\(UUID().uuidString)", isDirectory: true)
        registry = BackgroundProcessRegistry(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        registry?.terminateAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func launch(_ command: String, timeout: TimeInterval = 30) throws -> BackgroundProcessRegistry.Snapshot {
        try registry.launch(command: command,
                            workingDirectory: NSTemporaryDirectory(),
                            timeout: timeout,
                            conversationID: conversation)
    }

    /// `terminationHandler` fires on its own queue, so a status is never immediate. Polls rather
    /// than sleeping a fixed amount: a fixed sleep either flakes or wastes the whole suite's time.
    private func waitForTerminal(_ taskID: String, within seconds: TimeInterval = 10)
        -> BackgroundProcessRegistry.Snapshot? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let snapshot = registry.snapshot(conversationID: conversation, taskID: taskID),
               snapshot.status.isTerminal {
                return snapshot
            }
            usleep(20_000)
        }
        return registry.snapshot(conversationID: conversation, taskID: taskID)
    }

    // MARK: - Output is captured (was /dev/null)

    func testOutputIsWrittenToTheLogRatherThanDiscarded() throws {
        let task = try launch("echo hello-from-background")
        guard let done = waitForTerminal(task.id) else { return XCTFail("never finished") }
        XCTAssertEqual(done.status, .exited(code: 0))

        let log = try XCTUnwrap(registry.readLog(conversationID: conversation, taskID: task.id))
        XCTAssertTrue(log.text.contains("hello-from-background"),
                      "background output went nowhere — this is the /dev/null defect returning")
    }

    /// ONE descriptor for both streams, so the two interleave in true order. Two handles on one
    /// path would each carry their own offset and overwrite each other; separate files would lose
    /// the ordering that makes a build log readable.
    func testStdoutAndStderrInterleaveInOneLog() throws {
        let task = try launch("echo first; echo second >&2; echo third")
        guard let done = waitForTerminal(task.id) else { return XCTFail("never finished") }
        XCTAssertEqual(done.status, .exited(code: 0))

        let log = try XCTUnwrap(registry.readLog(conversationID: conversation, taskID: task.id))
        XCTAssertEqual(log.text, "first\nsecond\nthird",
                       "stderr must land between the stdout lines that bracket it")
    }

    func testARealExitCodeIsReported() throws {
        let task = try launch("exit 3")
        guard let done = waitForTerminal(task.id) else { return XCTFail("never finished") }
        XCTAssertEqual(done.status, .exited(code: 3))
    }

    // MARK: - The bound (was computed and dropped)

    func testAnOverrunningTaskIsKilledAtItsBound() throws {
        let task = try launch("sleep 30", timeout: 1)
        guard let done = waitForTerminal(task.id) else { return XCTFail("never finished") }

        XCTAssertEqual(done.status, .timedOut,
                       "the background branch computed `timeout_seconds` and never applied it — "
                       + "a caller asking for a bound got an unbounded process")
        XCTAssertLessThan(done.elapsed(), 10, "killed at the bound, not left to run")
    }

    /// ⚠️ THE PRECEDENCE. Killing the child triggers `terminationHandler`, which would otherwise
    /// overwrite `.timedOut` with `.exited(15)` and report a signal number as though the command
    /// had chosen to exit 15 — the same false statement `ProcessRunner.TimedResult` keeps
    /// `timedOut` separate to avoid.
    func testATimeoutKillIsNotReportedAsAChosenExit() throws {
        let task = try launch("sleep 30", timeout: 1)
        guard let done = waitForTerminal(task.id) else { return XCTFail("never finished") }

        XCTAssertEqual(done.status, .timedOut)
        if case .exited = done.status {
            XCTFail("a kill was reported as an exit code the command chose")
        }
        // The handler fires slightly after the watchdog; give it room to (wrongly) win.
        usleep(300_000)
        XCTAssertEqual(registry.snapshot(conversationID: conversation, taskID: task.id)?.status,
                       .timedOut, "the terminationHandler overwrote the kill status afterwards")
    }

    func testAFastTaskIsNotKilledByItsWatchdog() throws {
        let task = try launch("echo quick", timeout: 2)
        guard let done = waitForTerminal(task.id) else { return XCTFail("never finished") }
        XCTAssertEqual(done.status, .exited(code: 0))

        // Past the bound: a watchdog that fired anyway would flip a finished task to `.timedOut`.
        usleep(2_500_000)
        XCTAssertEqual(registry.snapshot(conversationID: conversation, taskID: task.id)?.status,
                       .exited(code: 0))
    }

    // MARK: - Stop

    func testStopTerminatesAndIsNotReportedAsAnExit() throws {
        let task = try launch("sleep 30")
        let stopped = try XCTUnwrap(registry.stop(conversationID: conversation, taskID: task.id))
        XCTAssertEqual(stopped.status, .stopped)

        usleep(300_000)
        XCTAssertEqual(registry.snapshot(conversationID: conversation, taskID: task.id)?.status,
                       .stopped, "the terminationHandler overwrote the stop status")
    }

    /// The normal race: a build finishes while the model is deciding to cancel it. Not an error.
    func testStoppingAnAlreadyFinishedTaskIsNotAnErrorAndKeepsItsStatus() throws {
        let task = try launch("echo done")
        guard waitForTerminal(task.id) != nil else { return XCTFail("never finished") }

        let stopped = try XCTUnwrap(registry.stop(conversationID: conversation, taskID: task.id))
        XCTAssertEqual(stopped.status, .exited(code: 0),
                       "a task that finished on its own must not be relabelled as stopped")
    }

    func testStoppingAnUnknownTaskReturnsNil() {
        XCTAssertNil(registry.stop(conversationID: conversation, taskID: "bg_99"))
    }

    /// End to end: `command_stop` must stop the JOB, not just the shell. A background build is
    /// `zsh -c "xcodebuild …"`, and signalling only the zsh left the compiler running and
    /// re-parented to launchd while the model was told the task had stopped.
    func testStopKillsSubProcessesNotJustTheShell() throws {
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bgreg-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let task = try launch("sleep 60 & echo $! > \(pidFile.path); wait")

        var child: pid_t?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, child == nil {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
                child = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            usleep(20_000)
        }
        let subProcess = try XCTUnwrap(child, "the shell never reported its background pid")
        XCTAssertEqual(kill(subProcess, 0), 0, "precondition: the sub-process is running")

        registry.stop(conversationID: conversation, taskID: task.id)

        let gone = Date().addingTimeInterval(5)
        while Date() < gone, kill(subProcess, 0) == 0 { usleep(20_000) }
        XCTAssertNotEqual(kill(subProcess, 0), 0,
                          "the sub-process outlived command_stop — the machine stays busy while "
                          + "the model has been told the task is stopped")
    }

    /// Same, for the bound rather than an explicit stop.
    func testTheTimeoutKillsSubProcessesToo() throws {
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bgreg-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        // ⚠️⚠️ THE FOUR-WRONG-GUESSES TEST. Red for hours; the cause was none of the things
        // the symptom suggested, and every guess was disproven by measurement rather than argument.
        //
        //   1. "The fork is slow under load."          — no: reproduces on an idle machine.
        //   2. "Widen the bound, 1s → 3s."             — no: 3s failed identically.
        //   3. "The shell exits first, so the child is orphaned." — no: capturing descendants every
        //      second showed `fresh=1` on EVERY tick; the ppid chain was intact throughout.
        //   4. "A shell sets SIGTERM to SIG_IGN for background jobs." — no: reading the child's
        //      actual `p_sigignore` showed it ignores INT and QUIT only, and it dies to SIGTERM.
        //
        // THE CAUSE, found by timestamping the watchdog: `finish()` blocked for **7.489 seconds**
        // inside `NotificationCenter.post`. The observer that draws the task's card is registered
        // on `.main`, and `post` waits for delivery — so it took exactly as long as the main thread
        // stayed busy. `finish` runs in the watchdog BETWEEN marking the task `.timedOut` and
        // killing it, so the kill ran 7.5s late, by which time the shell had exited on its own and
        // the tree was empty. It killed nothing while reporting "killed at its timeout".
        //
        // Not a test artifact: in a real Code run the main thread is busy rendering the streaming
        // response, which is precisely when a background task's bound needs to fire.
        //
        // ⚠️ The lesson is the ORDER OF OPERATIONS, not the notification: nothing slow may sit
        // between deciding to kill and killing. `testAnnounceDoesNotBlockTheKillPath` pins it.
        let task = try launch("sleep 60 & echo $! > \(pidFile.path); wait", timeout: 3)

        var child: pid_t?
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, child == nil {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
                child = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            usleep(20_000)
        }
        let subProcess = try XCTUnwrap(child)

        guard let done = waitForTerminal(task.id) else { return XCTFail("never finished") }
        XCTAssertEqual(done.status, .timedOut)

        let gone = Date().addingTimeInterval(5)
        while Date() < gone, kill(subProcess, 0) == 0 { usleep(20_000) }
        XCTAssertNotEqual(kill(subProcess, 0), 0,
                          "a bound that does not stop the work it started is not a bound")
    }

    /// ⚠️ A STRUCTURAL GUARD for an ordering nothing else can hold.
    ///
    /// `announce` is called from `finish`, which the watchdog calls immediately before killing the
    /// process. Posting inline blocked that path for 7.489 measured seconds while the main thread
    /// was busy, and the kill then found nothing left to kill. A behavioural test cannot catch it
    /// reliably — it only manifests when the main thread happens to be busy — so the async hop is
    /// pinned here instead.
    func testAnnounceDoesNotBlockTheKillPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let path = "Devgentic/Interfaces/Main/Views/Tooling/Local/utils/BackgroundProcessRegistry.swift"
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("BackgroundProcessRegistry.swift not reachable — running outside a checkout")
        }

        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("private func announce(") }) else {
            return XCTFail("announce(…) not found — this guard is checking nothing")
        }
        let body = lines[start..<min(start + 25, lines.count)]
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        guard let post = body.range(of: "NotificationCenter.default.post") else {
            return XCTFail("announce no longer posts — this guard is checking nothing")
        }
        let dispatched = body.range(of: ".async")
        XCTAssertNotNil(dispatched,
                        "announce posts synchronously. NotificationCenter.post waits for a `.main` "
                        + "observer, and this runs between marking a task timed out and killing it "
                        + "— a busy main thread delays every timeout kill by exactly that long.")
        if let dispatched {
            XCTAssertLessThan(dispatched.lowerBound, post.lowerBound,
                              "the post must be INSIDE the async hop, not before it")
        }
    }

    // MARK: - Reading incrementally

    func testReadLogIsIncrementalBySinceLine() throws {
        let task = try launch("echo one; echo two; echo three")
        guard waitForTerminal(task.id) != nil else { return XCTFail("never finished") }

        let first = try XCTUnwrap(registry.readLog(conversationID: conversation, taskID: task.id))
        XCTAssertEqual(first.text, "one\ntwo\nthree")
        XCTAssertEqual(first.nextLine, 3)

        let second = try XCTUnwrap(
            registry.readLog(conversationID: conversation, taskID: task.id, sinceLine: first.nextLine))
        XCTAssertEqual(second.text, "", "polling from the last line must not re-deliver the log")
        XCTAssertEqual(second.nextLine, 3)
    }

    func testReadLogPastTheEndDoesNotCrashOrUnderflow() throws {
        let task = try launch("echo only")
        guard waitForTerminal(task.id) != nil else { return XCTFail("never finished") }

        let read = try XCTUnwrap(
            registry.readLog(conversationID: conversation, taskID: task.id, sinceLine: 999))
        XCTAssertEqual(read.text, "")
        XCTAssertEqual(read.nextLine, 1)
    }

    /// nil means "no such task". An empty log is `("", 0)` — a different fact, and one a model
    /// must be able to distinguish from a bad id.
    func testAnUnknownTaskReadsNilRatherThanEmpty() {
        XCTAssertNil(registry.readLog(conversationID: conversation, taskID: "bg_42"))
    }

    // MARK: - Identity and scoping

    func testIDsAreSequentialAndScopedPerConversation() throws {
        let a = try launch("echo a")
        let b = try launch("echo b")
        XCTAssertEqual([a.id, b.id], ["bg_1", "bg_2"])

        let other = UUID()
        let c = try registry.launch(command: "echo c", workingDirectory: NSTemporaryDirectory(),
                                    timeout: 30, conversationID: other)
        XCTAssertEqual(c.id, "bg_1", "ids are per-conversation, so this is not a collision")

        // ⚠️ The assertion that matters. Two live tasks now share the id `bg_1`, so every lookup
        // has to take the conversation as well — a registry keyed on the id alone would answer
        // one conversation's poll with the other's build.
        XCTAssertEqual(registry.snapshot(conversationID: conversation, taskID: "bg_1")?.command, "echo a")
        XCTAssertEqual(registry.snapshot(conversationID: other, taskID: "bg_1")?.command, "echo c")

        registry.discard(conversationID: other)
    }

    func testSnapshotsListEveryTaskInLaunchOrder() throws {
        let a = try launch("true")
        let b = try launch("true")
        XCTAssertEqual(registry.snapshots(conversationID: conversation).map(\.id), [a.id, b.id])
    }

    func testAnUnknownConversationHasNoTasks() {
        XCTAssertTrue(registry.snapshots(conversationID: UUID()).isEmpty)
    }

    // MARK: - Teardown (was: orphaned to launchd)

    func testTerminateAllKillsLiveTasks() throws {
        let task = try launch("sleep 30")
        XCTAssertEqual(registry.snapshot(conversationID: conversation, taskID: task.id)?.status, .running)

        registry.terminateAll()

        XCTAssertEqual(registry.snapshot(conversationID: conversation, taskID: task.id)?.status,
                       .stopped,
                       "quitting left the process re-parented to launchd as an orphan")
    }

    func testDiscardRemovesTheRecordsAndTheLogs() throws {
        let task = try launch("echo bye")
        guard waitForTerminal(task.id) != nil else { return XCTFail("never finished") }
        let directory = root.appendingPathComponent(conversation.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        registry.discard(conversationID: conversation)

        XCTAssertTrue(registry.snapshots(conversationID: conversation).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testClearFinishedRemovesOnlyTerminalTasksAndTheirLogs() throws {
        let finishedTask = try launch("echo done")
        guard waitForTerminal(finishedTask.id) != nil else { return XCTFail("task never finished") }
        let runningTask = try launch("sleep 30")

        XCTAssertEqual(registry.snapshots(conversationID: conversation).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finishedTask.logURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runningTask.logURL.path))

        registry.clearFinished(conversationID: conversation)

        let remaining = registry.snapshots(conversationID: conversation)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, runningTask.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedTask.logURL.path), "finished log file must be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: runningTask.logURL.path), "running log file must survive")
    }

    // MARK: - Launch failure

    func testAFailedLaunchThrowsAndRegistersNothing() {
        XCTAssertThrowsError(try registry.launch(command: "true",
                                                 workingDirectory: "/no/such/directory",
                                                 timeout: 30,
                                                 conversationID: conversation))
        XCTAssertTrue(registry.snapshots(conversationID: conversation).isEmpty,
                      "a task that never started must not be pollable")
    }
}
