// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTailDrainTests.swift
//  DevgenticTests
//
//  The incremental tail — what replaced reading the whole log file on a 1 Hz timer.
//
//  ── The defect these pin ────────────────────────────────────────────────────────────────
//
//  `BackgroundTaskObserver` refreshed a live task's row by calling `String(contentsOf:)` on its
//  log, on the MainActor, once a SECOND, per live task — then took `String.count` (an O(n)
//  grapheme walk) of the result twice. `BackgroundTasksListView` did the same read inside a
//  `@ViewBuilder`, so it ran on every body evaluation.
//
//  For a short build that is invisible. For the workload `start_background_task`'s own description
//  recommends — "something you will not wait for, such as a dev server" — the log reaches tens of
//  MB and the main thread stalls on every tick. The feature broke on precisely its advertised case.
//
//  ⚠️ The assertions that matter here are about what is NOT re-read. A test that only checks the
//  tail's CONTENT passes just as happily against a whole-file read, which is why nearly every test
//  below also pins `logCharacterCount` — an accumulator that double-counts the instant a drain
//  re-reads ground it already covered.
//

import XCTest
@testable import devgentic

final class BackgroundTailDrainTests: XCTestCase {

    private var root: URL!
    private var registry: BackgroundProcessRegistry!
    private let conversation = UUID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bgtail-tests-\(UUID().uuidString)", isDirectory: true)
        registry = BackgroundProcessRegistry(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        registry?.terminateAll()
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// A task that stays alive and writes NOTHING, so the test owns every byte in the log.
    ///
    /// Driving the drain through a real command's output would make each assertion depend on
    /// shell buffering and scheduling. Appending by hand makes "what was written, and when" exact,
    /// which is the whole subject of this suite.
    private func launchIdle() throws -> BackgroundProcessRegistry.Snapshot {
        try registry.launch(command: "sleep 30",
                            workingDirectory: NSTemporaryDirectory(),
                            timeout: 30,
                            conversationID: conversation)
    }

    private func append(_ bytes: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    private func append(_ text: String, to url: URL) throws {
        try append(Data(text.utf8), to: url)
    }

    @discardableResult
    private func drain(_ taskID: String) throws -> BackgroundProcessRegistry.Snapshot {
        try XCTUnwrap(registry.refreshTail(conversationID: conversation, taskID: taskID))
    }

    private func waitForTerminal(_ taskID: String, within seconds: TimeInterval = 10)
        -> BackgroundProcessRegistry.Snapshot? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let snapshot = registry.snapshot(conversationID: conversation, taskID: taskID),
               snapshot.status.isTerminal { return snapshot }
            usleep(20_000)
        }
        return registry.snapshot(conversationID: conversation, taskID: taskID)
    }

    // MARK: - Reading only the delta

    /// THE test. Everything else is a refinement of this one claim.
    func testASecondDrainReadsOnlyWhatWasAddedSinceTheFirst() throws {
        let task = try launchIdle()

        try append("alpha\n", to: task.logURL)
        let first = try drain(task.id)
        XCTAssertEqual(first.tail, "alpha")
        XCTAssertEqual(first.logCharacterCount, 6, "six characters written, six counted")

        try append("beta\n", to: task.logURL)
        let second = try drain(task.id)
        XCTAssertEqual(second.tail, "alpha\nbeta")

        // ⚠️ THE ASSERTION THAT KILLS THE OLD IMPLEMENTATION. A drain that re-reads the whole file
        // sees "alpha\nbeta\n" the second time and lands on 6 + 11 = 17. Only a drain that resumes
        // from its byte offset produces 11.
        XCTAssertEqual(second.logCharacterCount, 11,
                       "the second drain re-read ground it had already covered — this is the "
                       + "whole-file read the incremental tail replaced")
    }

    func testADrainWithNothingNewAddedChangesNothing() throws {
        let task = try launchIdle()
        try append("one\n", to: task.logURL)
        let first = try drain(task.id)

        let second = try drain(task.id)
        XCTAssertEqual(second.tail, first.tail)
        XCTAssertEqual(second.logCharacterCount, first.logCharacterCount,
                       "an idle drain must be a no-op, not a re-count")
    }

    func testAnEmptyLogDrainsToAnEmptyTail() throws {
        let task = try launchIdle()
        let drained = try drain(task.id)
        XCTAssertEqual(drained.tail, "")
        XCTAssertEqual(drained.logCharacterCount, 0)
    }

    // MARK: - Line boundaries

    /// Incremental reads are only correct if an incomplete line is held back. A build writing
    /// "error: expected '}'" one buffer at a time must not surface as two half-lines.
    func testAPartialLineIsHeldBackUntilItsNewlineArrives() throws {
        let task = try launchIdle()

        try append("half", to: task.logURL)
        let partial = try drain(task.id)
        XCTAssertEqual(partial.tail, "", "a line with no newline yet is not a line")
        XCTAssertEqual(partial.logCharacterCount, 0, "and it has not been counted yet either")

        try append("-a-line\n", to: task.logURL)
        let whole = try drain(task.id)
        XCTAssertEqual(whole.tail, "half-a-line", "the two halves must rejoin, not appear as two lines")
        XCTAssertEqual(whole.logCharacterCount, 12)
    }

    /// `printf "done"` with no trailing newline puts the verdict in exactly the position a
    /// line-buffered reader throws away.
    func testTheFinalDrainFlushesATrailingLineWithNoNewline() throws {
        let task = try registry.launch(command: "printf 'working\\ndone'",
                                       workingDirectory: NSTemporaryDirectory(),
                                       timeout: 30, conversationID: conversation)
        let finished = try XCTUnwrap(waitForTerminal(task.id))
        XCTAssertEqual(finished.tail, "working\ndone",
                       "the last line carried no newline and was dropped")
    }

    /// ⚠️ THE GAP MUTATION FOUND. `testTheFinalDrainFlushesATrailingLineWithNoNewline` looks like
    /// it covers the final flush, and does not: its output CONTAINS a newline, so it exercises the
    /// "trailing partial after a newline" arm and never reaches the arm that handles a buffer with
    /// no newline in it at all. Removing `final` from that second arm left the whole suite green.
    ///
    /// A one-line command that does not terminate its line — `printf 'done'`, a script ending in a
    /// bare `echo -n` — would have had its ENTIRE output dropped, silently.
    func testATaskWhoseEntireOutputHasNoNewlineIsStillCaptured() throws {
        let task = try registry.launch(command: "printf 'done'",
                                       workingDirectory: NSTemporaryDirectory(),
                                       timeout: 30, conversationID: conversation)
        let finished = try XCTUnwrap(waitForTerminal(task.id))
        XCTAssertEqual(finished.tail, "done",
                       "output with no newline ANYWHERE was held as an incomplete line and never "
                       + "published — the task's whole result vanished")
        XCTAssertEqual(finished.logCharacterCount, 4)
    }

    /// ⚠️ The reason `pending` is `Data` and not `String`. Decoding each delta on its own turns a
    /// character split across two reads into two replacement glyphs — and a drain boundary lands
    /// wherever the OS happened to flush, so this is a live hazard for any non-ASCII log.
    func testAMultiByteCharacterSplitAcrossTwoDrainsIsNotCorrupted() throws {
        let task = try launchIdle()

        // "é" is 0xC3 0xA9. Deliver the two bytes in separate writes, draining between them.
        try append(Data([0xC3]), to: task.logURL)
        _ = try drain(task.id)
        try append(Data([0xA9, 0x0A]), to: task.logURL)
        let drained = try drain(task.id)

        XCTAssertEqual(drained.tail, "é")
        XCTAssertFalse(drained.tail.unicodeScalars.contains("\u{FFFD}"),
                       "the character was decoded in halves")
    }

    // MARK: - Bounds

    func testTheTailKeepsTheLastLinesAndDropsTheOldest() throws {
        let task = try launchIdle()
        let written = (1...500).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try append(written, to: task.logURL)

        let drained = try drain(task.id)
        let lines = drained.tail.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 200, "the tail is bounded")
        XCTAssertEqual(lines.first, "line-301", "and it is the LAST 200, not the first")
        XCTAssertEqual(lines.last, "line-500")
    }

    /// The count describes the LOG, the tail describes what is shown. `BackgroundTaskCard` prints
    /// "showing the last N of M characters" from exactly this difference — collapse the two and it
    /// silently claims the whole log is on screen.
    func testTheCharacterCountCoversTheWholeLogNotJustTheTail() throws {
        let task = try launchIdle()
        let written = (1...500).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        try append(written, to: task.logURL)

        let drained = try drain(task.id)
        XCTAssertEqual(drained.logCharacterCount, written.count)
        XCTAssertGreaterThan(drained.logCharacterCount, drained.tail.count,
                             "a bounded tail that reports the log's full size is what lets the UI "
                             + "admit it is truncating")
    }

    /// ⚠️ NEW EXPOSURE, introduced BY the incremental design. Re-reading the whole file each time
    /// accumulated nothing between calls. Holding an incomplete line does — and `npm`, `pip` and
    /// `xcodebuild -quiet` redraw progress with CARRIAGE RETURNS, emitting megabytes that contain
    /// no `\n` at all. Without a force-flush, `pending` grows for the life of the task.
    func testOutputCarryingNoNewlineIsForceFlushedRatherThanBuffered() throws {
        let task = try launchIdle()
        try append(String(repeating: "x", count: 70_000), to: task.logURL)

        let drained = try drain(task.id)
        XCTAssertFalse(drained.tail.isEmpty,
                       "70 KB with no newline was still being held as an incomplete line")
        XCTAssertEqual(drained.logCharacterCount, 70_000)
    }

    /// A task nobody watched for an hour must not make the next drain pay for all of it.
    func testADrainSkipsAheadRatherThanReadingAnEnormousBacklog() throws {
        let task = try launchIdle()
        // Comfortably past `maxDrainBytes` (1 MB), in lines so the result is checkable.
        let line = String(repeating: "y", count: 99) + "\n"
        try append(String(repeating: line, count: 20_000), to: task.logURL)   // 2 MB

        let drained = try drain(task.id)
        XCTAssertFalse(drained.tail.isEmpty)
        XCTAssertLessThanOrEqual(drained.logCharacterCount, 1_100_000,
                                 "the drain read the whole 2 MB backlog instead of skipping to "
                                 + "the last MB of it")
        XCTAssertEqual(drained.tail.components(separatedBy: "\n").last, String(repeating: "y", count: 99),
                       "skipping must land on the END of the file — the tail is what anyone wants "
                       + "from a log that big")
    }

    // MARK: - Wiring: the task's own lifecycle

    /// Without this, everything above is a library nothing calls.
    func testARealTasksOutputReachesTheTailWhenItFinishes() throws {
        let task = try registry.launch(command: "echo first; echo second; echo VERDICT",
                                       workingDirectory: NSTemporaryDirectory(),
                                       timeout: 30, conversationID: conversation)
        let finished = try XCTUnwrap(waitForTerminal(task.id))
        XCTAssertEqual(finished.tail, "first\nsecond\nVERDICT")
        XCTAssertEqual(finished.logCharacterCount, 21)
    }

    /// The foreground path uses the same live log, and `waitUntilEnded` must not return before the
    /// final drain — its caller reads the tail and the file the moment it is woken.
    func testAForegroundTaskIsDrainedBeforeItsWaiterWakes() async throws {
        let task = try registry.launch(command: "echo Compiling; printf 'Build complete!'",
                                       workingDirectory: NSTemporaryDirectory(),
                                       timeout: 30, conversationID: conversation, foreground: true)
        let ended = await registry.waitUntilEnded(conversationID: conversation, taskID: task.id)
        let done = try XCTUnwrap(ended)
        XCTAssertEqual(done.tail, "Compiling\nBuild complete!",
                       "the waiter woke before the final drain — the unterminated last line is missing")
        XCTAssertEqual(done.status, .exited(code: 0))
    }

    /// A log rewritten shorter than what was already consumed must reset rather than read garbage
    /// or silently stop updating.
    func testALogTruncatedUnderTheDrainRestartsCleanly() throws {
        let task = try launchIdle()
        try append("a long first generation of output\n", to: task.logURL)
        let first = try drain(task.id)
        XCTAssertEqual(first.logCharacterCount, 34)

        try Data("short\n".utf8).write(to: task.logURL, options: .atomic)
        let second = try drain(task.id)
        XCTAssertEqual(second.tail, "short", "the tail still described a file that no longer exists")
        XCTAssertEqual(second.logCharacterCount, 6, "and its count was never reset")
    }

    func testRefreshTailOnAnUnknownTaskIsNilRatherThanACrash() {
        XCTAssertNil(registry.refreshTail(conversationID: conversation, taskID: "bg_nope"))
        XCTAssertNil(registry.refreshTail(conversationID: UUID(), taskID: "bg_1"))
    }

    // MARK: - Wiring: ordering, pinned structurally

    /// ⚠️ A BEHAVIOURAL TEST CANNOT HOLD THIS LINE, which is exactly why it is pinned in source —
    /// the same argument as `testAnnounceDoesNotBlockTheKillPath`.
    ///
    /// `announce` hops to the main queue, so a drain running AFTER `finish` would usually still
    /// win the race and the row would look correct. It loses when the main queue is idle and the
    /// file is large, and when it loses the terminal row is permanently short of the verdict —
    /// there is no second announcement for a task that has already ended.
    func testTheFinalDrainIsOrderedBeforeTheAnnouncement() throws {
        let source = try registrySource()
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("process.terminationHandler = {") }) else {
            return XCTFail("terminationHandler not found — this guard is checking nothing")
        }
        let body = lines[start..<min(start + 25, lines.count)]
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        guard let drainAt = body.range(of: "drainTail(") else {
            return XCTFail("the termination handler no longer drains — a finished task's last "
                           + "output would never reach its row")
        }
        guard let finishAt = body.range(of: ".finish(") else {
            return XCTFail("finish(…) not found — this guard is checking nothing")
        }
        XCTAssertLessThan(drainAt.lowerBound, finishAt.lowerBound,
                          "the final drain must run BEFORE finish announces, or the row can be "
                          + "published one delta short of the verdict")

        guard let closeAt = body.range(of: "handle.close()") else {
            return XCTFail("the handler no longer closes the write handle")
        }
        XCTAssertLessThan(closeAt.lowerBound, drainAt.lowerBound,
                          "the drain must run AFTER the write handle is closed, or the child's "
                          + "last buffered writes are not on disk yet")
    }

    /// The hot path this whole change exists to remove. A single `String(contentsOf:)` reappearing
    /// in the observer restores a whole-file read on the MainActor once per task update.
    func testTheObserverNeverReadsTheLogFileAndHasNoTimer() throws {
        let source = try sourceFile("Devgentic/Core/Utils/BackgroundTaskObserver.swift")
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(code.contains("contentsOf:"),
                       "the observer reads the log file again — this ran on the MainActor for "
                       + "every live task and is the defect the incremental tail replaced")
        XCTAssertFalse(code.contains("Timer"),
                       "the observer polls again. Completion is ANNOUNCED — every terminal "
                       + "transition goes through finish() — so a timer re-discovers a fact it "
                       + "has already been told, and pays a file read for it")
        XCTAssertTrue(code.contains("snapshot.tail"),
                      "the observer must take its output from the registry's bounded tail")
    }

    /// `output(_:)` is a `@ViewBuilder`: anything in it runs on every body evaluation, so a read
    /// there is a whole-file read per re-render, not per open.
    func testTheTasksListReadsItsLogIntoStateRatherThanInsideItsViewBuilder() throws {
        let source = try sourceFile("Devgentic/Interfaces/Shared/Chat/BackgroundTasksListView.swift")
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("private func output(") }) else {
            return XCTFail("output(_:) not found — this guard is checking nothing")
        }
        let body = lines[start..<min(start + 20, lines.count)]
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(body.contains("readLog"),
                       "the log is read inside the view builder again — that is once per render, "
                       + "not once per open")
        XCTAssertTrue(body.contains("logs["), "it must render from the cache")
    }

    /// With the observer no longer polling, an OPEN card is the only thing that can show live
    /// output — and it can only do that if it refreshes itself.
    func testTheCardRefreshesItsOwnTailWhileOpen() throws {
        let source = try sourceFile("Devgentic/Interfaces/Shared/Chat/BackgroundTaskCard.swift")
        let code = source.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertTrue(code.contains("refreshTail("),
                      "nothing drives live output any more: the observer stopped polling, so a "
                      + "card left open during a build would sit on its launch-time tail")
        XCTAssertTrue(code.contains(".onReceive(tick)") && code.contains("refreshLiveTail()"),
                      "the refresh must be driven by the card's tick while it is on screen")
        XCTAssertTrue(code.contains("|| data.status == .running"),
                      "the Output button is gated on the character count, which stays 0 for a "
                      + "running task now that the observer does not poll — a running build "
                      + "would have no way to be opened or closed")
    }

    // MARK: - Source access

    private func registrySource() throws -> String {
        try sourceFile("Devgentic/Interfaces/Main/Views/Tooling/Local/utils/BackgroundProcessRegistry.swift")
    }

    private func sourceFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return source
    }
}
