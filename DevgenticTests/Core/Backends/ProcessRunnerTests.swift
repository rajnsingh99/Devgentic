// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProcessRunnerTests.swift
//  DevgenticTests
//
//  The two-pipe deadlock is the one the obvious fix misses. Draining stdout to EOF while
//  stderr fills just relocates the hang, so "swap the two lines" — correct for a single-pipe
//  site — leaves these broken while looking fixed.
//
//  Every size below is chosen to exceed the ~64 KB pipe buffer. Before `ProcessRunner`, the
//  both-streams-large test would never return.
//

import XCTest
@testable import devgentic

final class ProcessRunnerTests: XCTestCase {

    // MARK: - The deadlock

    /// THE case. Both streams past the buffer at once: whichever handle is read second fills
    /// and blocks its writer while the reader waits on the first. Only concurrent draining
    /// survives this.
    func testBothStreamsLargerThanTheBufferDoNotDeadlock() throws {
        let result = try ProcessRunner.zsh("seq 1 40000; seq 1 40000 >&2")

        XCTAssertGreaterThan(result.standardOutput.count, 200_000, "stdout truncated or lost")
        XCTAssertGreaterThan(result.standardError.count, 200_000, "stderr truncated or lost")
        XCTAssertTrue(result.standardOutput.contains("40000"), "stdout tail must arrive")
        XCTAssertTrue(result.standardError.contains("40000"), "stderr tail must arrive")
        XCTAssertTrue(result.succeeded)
    }

    /// stderr large, stdout empty — the asymmetric case a stdout-only drain would hang on.
    func testLargeStderrAloneDoesNotDeadlock() throws {
        let result = try ProcessRunner.zsh("seq 1 50000 >&2")
        XCTAssertTrue(result.standardOutput.isEmpty)
        XCTAssertGreaterThan(result.standardError.count, 200_000)
    }

    func testLargeStdoutAloneDoesNotDeadlock() throws {
        let result = try ProcessRunner.zsh("seq 1 50000")
        XCTAssertGreaterThan(result.standardOutput.count, 200_000)
        XCTAssertTrue(result.standardError.isEmpty)
    }

    // MARK: - Streams stay separate

    /// Callers that need to tell "printed to stderr" from "failed" must be able to. A tool
    /// that merges them before the caller sees them cannot.
    func testStreamsAreNotConflated() throws {
        let result = try ProcessRunner.zsh("echo OUT_SENTINEL; echo ERR_SENTINEL >&2")

        XCTAssertTrue(result.standardOutput.contains("OUT_SENTINEL"))
        XCTAssertFalse(result.standardOutput.contains("ERR_SENTINEL"))
        XCTAssertTrue(result.standardError.contains("ERR_SENTINEL"))
        XCTAssertFalse(result.standardError.contains("OUT_SENTINEL"))
    }

    func testCombinedOutputMarksTheStderrSection() throws {
        let result = try ProcessRunner.zsh("echo hello; echo oops >&2")
        XCTAssertTrue(result.combinedOutput.contains("hello"))
        XCTAssertTrue(result.combinedOutput.contains("[stderr]"))
        XCTAssertTrue(result.combinedOutput.contains("oops"))
    }

    func testCombinedOutputOmitsTheMarkerWhenOnlyOneStreamIsUsed() throws {
        let clean = try ProcessRunner.zsh("echo only-stdout")
        XCTAssertFalse(clean.combinedOutput.contains("[stderr]"), "no empty section: \(clean.combinedOutput)")

        let quiet = try ProcessRunner.zsh("true")
        XCTAssertTrue(quiet.combinedOutput.isEmpty)
    }

    // MARK: - Exit status

    func testExitCodeIsReported() throws {
        XCTAssertEqual(try ProcessRunner.zsh("exit 7").exitCode, 7)
        XCTAssertFalse(try ProcessRunner.zsh("exit 7").succeeded)
        XCTAssertTrue(try ProcessRunner.zsh("true").succeeded)
    }

    /// A failing command still has its output collected — that IS the diagnostic.
    func testOutputSurvivesANonZeroExit() throws {
        let result = try ProcessRunner.zsh("echo before-failure; echo why >&2; exit 2")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.standardOutput.contains("before-failure"))
        XCTAssertTrue(result.standardError.contains("why"))
    }

    // MARK: - Process configuration

    func testWorkingDirectoryIsHonoured() throws {
        let result = try ProcessRunner.zsh("pwd", currentDirectory: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(result.standardOutput.contains("tmp"), "\(result.standardOutput)")
    }

    func testDirectExecutableInvocation() throws {
        let result = try ProcessRunner.run(executable: "/bin/echo", arguments: ["direct"])
        XCTAssertTrue(result.standardOutput.contains("direct"))
        XCTAssertTrue(result.succeeded)
    }

    /// A missing executable must throw rather than report a phantom success.
    func testMissingExecutableThrows() {
        XCTAssertThrowsError(
            try ProcessRunner.run(executable: "/nonexistent/binary", arguments: [])
        )
    }

    // MARK: - Bounded runs

    private func zshProcess(_ command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        return process
    }

    /// THE regression. `batch_command` waited on `waitUntilExit()` and read its two pipes
    /// afterwards, so a command past the ~64 KB buffer blocked in `write()`, never exited, and
    /// tripped the timeout — reporting "timed out after 30s" for a command that had finished
    /// its work and was only waiting to be read. A timeout that fires on VOLUME rather than
    /// DURATION is worse than a hang: it is a confident false statement.
    func testLargeOutputCompletesInsteadOfBeingMisreportedAsATimeout() throws {
        let started = Date()
        let run = try ProcessRunner.run(zshProcess("seq 1 40000; seq 1 40000 >&2"), timeout: 20)

        XCTAssertFalse(run.timedOut, "finished fast; only the un-drained pipe ever made this look slow")
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "should complete promptly, not ride the bound")
        XCTAssertGreaterThan(run.result.standardOutput.count, 200_000)
        XCTAssertGreaterThan(run.result.standardError.count, 200_000)
        XCTAssertTrue(run.result.succeeded)
    }

    /// The bound must still bind — the fix removes a false positive, it must not remove the
    /// timeout itself.
    func testAGenuinelySlowCommandIsKilledAtTheBound() throws {
        let started = Date()
        let run = try ProcessRunner.run(zshProcess("sleep 30"), timeout: 1)

        XCTAssertTrue(run.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the bound must actually bind")
    }

    /// A command killed at the bound usually produced the evidence for WHY it was slow before
    /// it was killed. Discarding that leaves the agent with nothing to act on.
    func testPartialOutputSurvivesTheKill() throws {
        let run = try ProcessRunner.run(zshProcess("echo partial-marker; sleep 30"), timeout: 1)

        XCTAssertTrue(run.timedOut)
        XCTAssertTrue(run.result.combinedOutput.contains("partial-marker"),
                      "output before the kill must not be thrown away: \(run.result.combinedOutput)")
    }

    /// SIGTERM is a request, not a guarantee. A child that ignores it would otherwise hold the
    /// caller past a bound that has already expired — the very thing the bound exists to stop.
    func testAChildIgnoringSIGTERMIsStillKilled() throws {
        let started = Date()
        let run = try ProcessRunner.run(zshProcess("trap '' TERM; sleep 30"), timeout: 1)

        XCTAssertTrue(run.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 12,
                          "SIGKILL escalation must bound a child that refuses SIGTERM")
    }

    // MARK: - Backgrounded descendants

    /// THE hazard. EOF arrives only when every holder of the write end closes it, and `cmd &`
    /// hands that write end to a descendant. Waiting for EOF meant the call outlived the child
    /// by the descendant's entire lifetime — 4.08s here, unbounded in general.
    func testADescendantDoesNotHoldTheCallOpen() throws {
        let started = Date()
        let result = try ProcessRunner.zsh("echo done; sleep 4 &")

        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "the child exited immediately; only the descendant's grip on the pipe was slow")
        XCTAssertTrue(result.standardOutput.contains("done"), "the child's own output must survive")
    }

    /// The sharper case: it defeated the BOUND. The watchdog is guarded on `isRunning`, the
    /// child had already exited, so the watchdog correctly no-oped and nothing was bounding
    /// anything — a 1s bound returned at 6.08s with `timedOut == false`.
    func testADescendantDoesNotDefeatTheBound() throws {
        let started = Date()
        let run = try ProcessRunner.run(zshProcess("echo done; sleep 6 &"), timeout: 1)

        XCTAssertLessThan(Date().timeIntervalSince(started), 2,
                          "a bound that returns after the descendant is not a bound")
        XCTAssertTrue(run.result.standardOutput.contains("done"))
    }

    /// The counterweight, and the reason this waits a moment rather than cutting at exit. A
    /// forked worker writing its result a few ms after the parent returns is an ordinary shape;
    /// stopping the instant the child is reaped drops it, and drops it NONDETERMINISTICALLY —
    /// whether it survives depends on the scheduler. Silent, timing-dependent truncation of
    /// tool output is the same class of defect as the path-normalisation corruption.
    func testDescendantOutputInsideTheGraceIsKept() throws {
        let result = try ProcessRunner.zsh("echo parent-ok; (sleep 0.05; echo WORKER_RESULT) &")

        XCTAssertTrue(result.standardOutput.contains("parent-ok"))
        XCTAssertTrue(result.standardOutput.contains("WORKER_RESULT"),
                      "a worker writing 50ms later is not a daemon: \(result.standardOutput)")
        XCTAssertTrue(result.outputComplete)
    }

    /// And when output IS dropped, the caller is told. The old behaviour blocked instead, so
    /// there was never a truncated-but-successful result to report; now there is, and a caller
    /// that believes it received everything would be wrong.
    func testTruncationIsNeverSilent() throws {
        let result = try ProcessRunner.zsh("echo early; (sleep 3; echo LATE) &")

        XCTAssertTrue(result.standardOutput.contains("early"))
        XCTAssertFalse(result.standardOutput.contains("LATE"), "we did not wait for the daemon")
        XCTAssertFalse(result.outputComplete, "and we must SAY we did not")
    }

    // MARK: - The bound reaches the whole job

    /// The foreground twin of the background defect. `zsh -c "xcodebuild …"` puts the compiler in
    /// a SEPARATE process, so signalling only the shell left the build running past a bound that
    /// had already expired — a 900 s `batch_command` timeout that stopped nothing.
    func testTheBoundKillsSubProcessesNotJustTheShell() throws {
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("procrunner-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        // `wait` keeps the shell alive, so the bound is what ends this — not the command finishing.
        let run = try ProcessRunner.run(
            zshProcess("sleep 60 & echo $! > \(pidFile.path); wait"), timeout: 1)
        XCTAssertTrue(run.timedOut, "precondition: the bound fired rather than the command ending")

        let text = try XCTUnwrap(try? String(contentsOf: pidFile, encoding: .utf8),
                                 "the shell never recorded its background pid")
        let child = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, kill(child, 0) == 0 { usleep(20_000) }
        XCTAssertNotEqual(kill(child, 0), 0,
                          "the sub-process outlived the bound — the caller was told the command "
                          + "was killed while its real work kept running")
    }

    /// ⚠️ THE COUNTERWEIGHT to the tree kill: "kill the tree on timeout" must not grow into
    /// "kill anything the command ever started". When the command's own process FINISHED,
    /// nothing was being bounded, and `cmd &` is a deliberate launch.
    ///
    /// ⚠️⚠️ This pins the BEHAVIOUR, not the mechanism, and the distinction was found by
    /// mutation: removing the watchdog's `isRunning` guard leaves this test GREEN. The daemon
    /// survives because the shell exits, `exited.wait` returns, and the watchdog is CANCELLED
    /// before its deadline — the guard is never reached on this path. Do not read a pass here as
    /// evidence that the guard works; `testTheWatchdogChecksLivenessBeforeActing` covers that.
    func testADeliberatelyBackgroundedDescendantOfAFinishedCommandSurvives() throws {
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("procrunner-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        // No `wait`: the shell exits immediately and the descendant is deliberately left running.
        let run = try ProcessRunner.run(
            zshProcess("sleep 5 & echo $! > \(pidFile.path); echo done"), timeout: 1)
        XCTAssertFalse(run.timedOut, "precondition: the command finished on its own")

        let text = try XCTUnwrap(try? String(contentsOf: pidFile, encoding: .utf8))
        let child = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))

        // Past the bound, and the watchdog has had its chance to fire and no-op.
        usleep(1_500_000)
        XCTAssertEqual(kill(child, 0), 0,
                       "a descendant the command deliberately backgrounded was killed. The bound "
                       + "had nothing to enforce — the command itself had already finished.")
        kill(child, SIGKILL)
    }

    /// ⚠️ A STRUCTURAL GUARD, for a race a behavioural test cannot reach.
    ///
    /// `DispatchWorkItem.cancel()` only prevents a start, so an item that had already begun when
    /// the command finished runs to completion. If it acts before checking liveness, a run that
    /// SUCCEEDED at its bound is reported as `timedOut` and has its descendants killed — a false
    /// statement plus a real side effect. Mutation-tested: deleting the guard passes every other
    /// test in this file, which is precisely why the order is asserted here.
    func testTheWatchdogChecksLivenessBeforeActing() throws {
        let source = try Self.readProcessRunnerSource()
        let body = try XCTUnwrap(Self.watchdogBody(in: source),
                                 "could not find the timeout DispatchWorkItem — this checks nothing")

        let liveness = try XCTUnwrap(body.range(of: "process.isRunning"),
                                     "the watchdog no longer checks whether the child is alive")
        let firstAction = try XCTUnwrap(
            [body.range(of: "killed.set()"), body.range(of: "ProcessTree.")]
                .compactMap { $0 }.map(\.lowerBound).min(),
            "the watchdog no longer does anything")

        XCTAssertLessThan(liveness.lowerBound, firstAction,
            "the watchdog acts before checking `process.isRunning`. A command that finished right "
            + "at its bound would be reported as timed out and have its sub-processes killed, on "
            + "a run that actually succeeded.")
    }

    private static func readProcessRunnerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Backends
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        let path = "Devgentic/Interfaces/Main/Views/Tooling/Local/utils/ProcessRunner.swift"
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("ProcessRunner.swift not reachable — running outside a checkout")
        }
        return text
    }

    /// The timeout `DispatchWorkItem`'s body, comments stripped so the prose explaining the
    /// ordering cannot be mistaken for the code implementing it.
    private static func watchdogBody(in source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("let item = DispatchWorkItem {") }) else {
            return nil
        }
        var depth = 0
        var started = false
        var body: [String] = []
        for line in lines[start...] {
            depth += line.filter { $0 == "{" }.count
            depth -= line.filter { $0 == "}" }.count
            if depth > 0 { started = true }
            if !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { body.append(line) }
            if started && depth == 0 { break }
        }
        return body.joined(separator: "\n")
    }

    /// Guards the flag against degrading into always-false, which would make it useless noise.
    func testCompleteOutputReportsComplete() throws {
        let result = try ProcessRunner.zsh("seq 1 40000; seq 1 40000 >&2")
        XCTAssertTrue(result.outputComplete)
        XCTAssertGreaterThan(result.standardOutput.count, 200_000)
    }

    // MARK: - Bounds on what one command can cost

    /// Capture was unbounded: `yes` under a 2s bound captured 7.2 GB and grew RSS by 1.9 GB,
    /// which takes the app down rather than the command. The cap keeps the head AND the tail —
    /// head-only drops the newest bytes, which under a flood are the child's own last lines.
    func testRunawayOutputIsCappedRatherThanUnbounded() throws {
        let run = try ProcessRunner.run(zshProcess("echo KEEP_ME_FIRST; yes SPAM"), timeout: 2)

        XCTAssertTrue(run.result.standardOutput.hasPrefix("KEEP_ME_FIRST"),
                      "the head is what the child said before the flood started")
        XCTAssertLessThan(run.result.standardOutput.count, 40 << 20,
                          "captured \(run.result.standardOutput.count) bytes — the cap did not hold")
        XCTAssertTrue(run.result.standardOutput.contains("elided"),
                      "a dropped middle must be marked, not silently closed over")
    }

    /// `String(data:encoding:.utf8)` returns nil for ANY invalid byte, so the old code read
    /// 100,000 bytes of binary and handed the caller an empty string — a tool reporting
    /// nothing at all, indistinguishable from a command that printed nothing.
    func testBinaryOutputIsNotSwallowed() throws {
        let result = try ProcessRunner.zsh("head -c 100000 /dev/urandom")
        XCTAssertFalse(result.standardOutput.isEmpty,
                       "invalid UTF-8 must decode lossily, never to nothing")
    }

    /// Two descriptors leaked per invocation — +80 across 40 runs — which eventually exhausts
    /// the process limit and makes unrelated file operations start failing.
    func testFileDescriptorsAreNotLeaked() throws {
        func openCount() -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
        }
        for _ in 0..<5 { _ = try ProcessRunner.zsh("echo warmup") }
        let before = openCount()
        for _ in 0..<40 { _ = try ProcessRunner.zsh("echo x") }
        let after = openCount()

        XCTAssertLessThan(after - before, 10,
                          "fd count went \(before) → \(after) across 40 runs")
    }

    /// Each run has its own pipes and its own drains; parallel callers must not see each
    /// other's bytes.
    func testConcurrentInvocationsDoNotConflate() {
        // Sentinels are BRACKETED so they cannot prefix-collide: a bare `OUT_1` is a substring
        // of `OUT_10`, which reads as cross-talk when nothing is actually wrong.
        DispatchQueue.concurrentPerform(iterations: 12) { i in
            guard let result = try? ProcessRunner.zsh("echo 'OUT[\(i)]'; echo 'ERR[\(i)]' >&2") else {
                return XCTFail("run \(i) threw")
            }
            XCTAssertTrue(result.standardOutput.contains("OUT[\(i)]"))
            XCTAssertTrue(result.standardError.contains("ERR[\(i)]"))
            for other in 0..<12 where other != i {
                XCTAssertFalse(result.standardOutput.contains("OUT[\(other)]"),
                               "run \(i) saw run \(other)'s stdout")
                XCTAssertFalse(result.standardOutput.contains("ERR[\(i)]"),
                               "run \(i) got its own stderr on stdout")
            }
        }
    }

    /// `waitUntilExit()` polls the caller's RUN LOOP on Darwin — 101 re-entrant callbacks
    /// during a 5s command. There are real main-thread call sites (`DeviceControlTools`,
    /// `SystemToggleTools`, `MacOSUtilityTools` all call this inside `MainActor.run`), so using
    /// it as the wait primitive would let timers and AppKit events fire re-entrantly for the
    /// whole duration of a `networksetup` call. This is what stops it being reintroduced.
    @MainActor
    func testTheMainThreadRunLoopIsNotSpun() throws {
        var timerFired = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in timerFired = true }
        defer { timer.invalidate() }

        _ = try ProcessRunner.zsh("sleep 1")

        XCTAssertFalse(timerFired,
                       "the run loop ran during a synchronous call — waitUntilExit() is back")
    }

    /// `timedOut` is reported separately from the exit code precisely so a normal non-zero
    /// exit is never read as a timeout.
    func testNormalCompletionReportsItsRealExitCodeAndNoTimeout() throws {
        let run = try ProcessRunner.run(zshProcess("echo fine; exit 3"), timeout: 10)

        XCTAssertFalse(run.timedOut, "it chose to exit 3; nobody killed it")
        XCTAssertEqual(run.result.exitCode, 3)
        XCTAssertTrue(run.result.standardOutput.contains("fine"))
    }
}
