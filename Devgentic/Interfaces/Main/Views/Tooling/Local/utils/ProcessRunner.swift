// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProcessRunner.swift
//  Devgentic
//
//  One correct way to run a subprocess and collect BOTH its streams.
//
//  Every tool that shelled out had hand-rolled this, and 28 of those hand-rolls drained the
//  pipe only after `waitUntilExit()`. A pipe holds ~64 KB; once it fills, the child blocks in
//  `write()` while the parent blocks in `wait()`, and nothing breaks the tie. Reproduced at
//  288 KB: indefinite that way, 0.027 s the correct way.
//
//  Sites with SEPARATE stdout and stderr pipes have a second, sharper version of the same
//  bug — reading one to EOF while the other fills simply relocates the deadlock to stderr, so
//  the obvious "swap the two lines" fix looks right and is not. Both handles must be drained
//  CONCURRENTLY. That is the whole reason this type exists rather than a comment telling 13
//  call sites to be careful.
//
//  ── Why this does not wait for EOF ──────────────────────────────────────────────────────
//
//  The first version of this type drained concurrently and then waited for EOF on both pipes.
//  EOF arrives only when EVERY holder of the write end closes it, and a command that
//  backgrounds a descendant (`cmd &`) hands that write end to the descendant. Measured:
//
//      zsh -c "echo hello"           0.07 s
//      zsh -c "echo done; sleep 4 &" 4.08 s   ← the parent exited instantly
//
//  It also defeated the bound outright: `run(_:timeout: 1)` on `"echo done; sleep 6 &"`
//  returned after 6.08 s with `timedOut == false`. The watchdog is guarded on
//  `process.isRunning`, the child had already exited, so the watchdog correctly no-oped —
//  and nothing else was bounding anything. The join was holding the call, not the child.
//
//  So the completion signal is the CHILD BEING REAPED, never EOF. `terminationHandler` +
//  a semaphore, deliberately not `waitUntilExit()`: on Darwin that polls the caller's run
//  loop, and there are real main-thread call sites (`DeviceControlTools`, `SystemToggleTools`,
//  `MacOSUtilityTools`). Measured on the main thread during a 5 s command — `waitUntilExit()`
//  delivered 101 re-entrant run-loop callbacks; this delivers 0.
//
//  After the child is reaped we keep draining for `descendantGrace`, because a forked worker
//  that writes its result 50 ms later is a normal shape and dropping it silently would be a
//  content bug, not a performance win. Past that we stop, and `Result.outputComplete` says so.
//  Truncation that does not announce itself is the failure this codebase has already paid for
//  three times.
//

import Foundation
import os

private let logger = DGLogger(category: "ProcessRunner")

enum ProcessRunner {

    /// Both streams plus the exit status, with the streams kept separate — callers that need
    /// to distinguish "the command printed to stderr" from "the command failed" can, and the
    /// ones that don't can take `combinedOutput`.
    struct Result: Sendable {
        let standardOutput: String
        let standardError: String
        let exitCode: Int32

        /// False when a descendant still held the pipe after the child was reaped and the
        /// grace expired, so reading stopped with bytes possibly still to come.
        ///
        /// Exists because the alternative is lying. The old behaviour was to block until the
        /// descendant exited, which is why `execute_shell` could hang forever; the new
        /// behaviour returns promptly, and this is how a caller can tell the difference
        /// between "that was all of it" and "that was all of it so far".
        let outputComplete: Bool

        /// Bytes dropped from the MIDDLE of stdout by the head/tail capture cap; 0 when stdout is
        /// whole. Independent of `outputComplete` (that one is about descendants holding the pipe).
        ///
        /// Exists for callers that PARSE stdout. The gap is otherwise marked only by inline text,
        /// and a structured parser reading across it sees a corrupted record and a plausible-looking
        /// partial list — the Git Changes panel would present some files as all of them.
        let standardOutputElidedBytes: Int

        var succeeded: Bool { exitCode == 0 }

        /// stdout, then stderr under a marker when both are present — the shape most callers
        /// were already assembling by hand.
        var combinedOutput: String {
            switch (standardOutput.isEmpty, standardError.isEmpty) {
            case (true, true):   return ""
            case (false, true):  return standardOutput
            case (true, false):  return standardError
            case (false, false): return standardOutput + "\n[stderr]\n" + standardError
            }
        }
    }

    /// A bounded run's outcome. `timedOut` is reported SEPARATELY from the exit code because a
    /// killed child still has one (SIGTERM/SIGKILL), and "we killed it" is a different fact
    /// from "it chose to exit non-zero" — collapsing them is how a timeout gets misread as a
    /// command failure.
    struct TimedResult: Sendable {
        let result: Result
        let timedOut: Bool
    }

    // MARK: - Tuning

    /// How long SIGTERM gets before SIGKILL. Long enough for a well-behaved child to flush and
    /// unwind, short enough that a wedged one cannot extend the caller's bound noticeably.
    private static let sigkillGrace: TimeInterval = 2

    /// How long we keep reading after the child is reaped, for descendants that inherited the
    /// write end. A forked worker writing within this window is captured; past it we stop and
    /// report `outputComplete == false`.
    ///
    /// 0.25 s is not tuned to a throughput number — at most ~64 KB can be in flight in a pipe,
    /// so this is about scheduling latency, and it was never the limiting factor in any
    /// measured case. It is the price of not silently dropping a forked worker's output, and
    /// it still returns 16× faster than waiting for the descendant.
    static let descendantGrace: TimeInterval = 0.25

    /// Ceiling on the join after we cancel the sources. Cancellation is prompt, so reaching
    /// this means something is badly wrong; returning beats hanging.
    private static let joinBackstop: TimeInterval = 1.0

    /// Per-stream capture cap, split head/tail. Unbounded accumulation is not theoretical:
    /// `yes` under a 2 s bound captured 7.2 GB and grew RSS by 1.9 GB on the old code — enough
    /// to take the app down. Head AND tail rather than head-only because under a flooding
    /// descendant the newest bytes are the child's own final lines, which is exactly the
    /// evidence worth keeping.
    private static let headKeep = 8 << 20
    private static let tailKeep = 8 << 20

    /// Bytes one wake may consume before yielding, so `cancel()` stays responsive under a
    /// firehose instead of being starved by an event handler that keeps finding more.
    private static let perWakeCap = 4 << 20

    // MARK: - Drain

    /// One pipe read end, drained continuously on its own serial queue.
    ///
    /// `@unchecked Sendable`: `bytes`/`tail`/`elided`/`sawEOF` are guarded by `lock` on EVERY
    /// path — including the caller's snapshot — because the backstop is the one path that can
    /// read without a completed join, so the group cannot be used as the barrier the way the
    /// old code did. `fd` and `buf` are immutable after init and touched only on `queue`: by
    /// the event handler, and by the cancel handler, which libdispatch guarantees runs after
    /// the last event handler and never concurrently with one.
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        private var tail: [Data] = []
        private var tailBytes = 0
        private var elided = 0
        private var sawEOF = false
        private let fd: Int32
        private let buf: UnsafeMutableRawPointer
        private var source: DispatchSourceRead!

        init(reading handle: FileHandle, label: String, group: DispatchGroup) {
            // OUR descriptor. Arming a source on the FileHandle's own number risks the handle
            // deinitialising, the allocator recycling that number, and the source then reading
            // an unrelated file — observed at 400/400 in a probe, not a theoretical race.
            fd = dup(handle.fileDescriptor)
            buf = .allocate(byteCount: 65_536, alignment: 1)
            // Read end only. `pipe(2)` gives the two ends separate open file descriptions, so
            // the child's `write(2)` stays blocking and back-pressure still works.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            // Its OWN serial queue. Sharing one between the two streams lets a busy stdout
            // handler starve stderr until stderr's 64 KB fills and its writer blocks — the
            // original deadlock, relocated.
            // ⚠️ `.userInitiated`, matching the caller. `run` blocks on `group.wait` until these
            // pumps finish, so a default-QoS queue here makes a user-initiated thread wait on
            // lower-priority work — which Thread Performance Checker reports as a priority
            // inversion on every `git` call, and which genuinely slows the wait under load.
            source = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: DispatchQueue(label: label, qos: .userInitiated))
            group.enter()

            source.setEventHandler { [self] in
                var budget = ProcessRunner.perWakeCap
                while budget > 0 {
                    if source.isCancelled { return }
                    let n = read(fd, buf, min(65_536, budget))
                    if n > 0 {
                        append(UnsafeRawBufferPointer(start: buf, count: n))
                        budget -= n
                        continue
                    }
                    if n == 0 {
                        // A read source on a fully-closed pipe stays permanently readable with
                        // zero bytes; without cancelling here it would spin the queue forever.
                        lock.lock(); sawEOF = true; lock.unlock()
                        source.cancel()
                        return
                    }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { return }
                    source.cancel()
                    return
                }
            }
            source.setCancelHandler { [self] in
                close(fd)
                buf.deallocate()
                group.leave()
                // The handlers retain self and self retains the source; nil them here or the
                // drain outlives every invocation.
                source.setEventHandler(handler: nil)
                source.setCancelHandler(handler: nil)
            }
            source.resume()
        }

        private func append(_ chunk: UnsafeRawBufferPointer) {
            lock.lock(); defer { lock.unlock() }
            if bytes.count < ProcessRunner.headKeep {
                let take = min(chunk.count, ProcessRunner.headKeep - bytes.count)
                bytes.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[0..<take]))
                if take == chunk.count { return }
                pushTail(Data(UnsafeRawBufferPointer(rebasing: chunk[take...])))
            } else {
                pushTail(Data(chunk))
            }
        }

        private func pushTail(_ chunk: Data) {
            tail.append(chunk)
            tailBytes += chunk.count
            while let first = tail.first, tailBytes - first.count >= ProcessRunner.tailKeep {
                tail.removeFirst()
                tailBytes -= first.count
                elided += first.count
            }
        }

        /// Stop reading. Used when a descendant is still holding the pipe past the grace.
        func stop() { source.cancel() }

        /// Head, an elision marker if the middle was dropped, then the tail ring.
        func snapshot() -> (data: Data, elided: Int) {
            lock.lock(); defer { lock.unlock() }
            var out = bytes
            if elided > 0 {
                out.append(Data("\n…[ProcessRunner elided \(elided) bytes: output exceeded the \(ProcessRunner.headKeep + ProcessRunner.tailKeep)-byte capture cap]…\n".utf8))
            }
            for chunk in tail { out.append(chunk) }
            return (out, elided)
        }
    }

    /// One-way flag set from the watchdog queue and read by the caller. The watchdog is not a
    /// group member, so nothing else orders those two — this needs real synchronisation.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    // MARK: - Core

    /// The one implementation. `timeout == nil` is an unbounded run.
    private static func execute(_ process: Process, timeout: TimeInterval?, label: String,
                                descendantGrace: TimeInterval = descendantGrace,
                                onStarted: ((Process) -> Void)? = nil) throws -> TimedResult {
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // BEFORE `run()`. Setting it afterwards is a race against a child that exits instantly,
        // and the loser waits forever.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        // ⚠️ AFTER `run()` — there is no pid before it — and after the pipes are attached, which
        // must happen first or the output is lost. This is the only moment a caller can take a
        // handle on a running foreground process: `execute` blocks until the command finishes, so
        // anything wanting to stop it, or clean it up at quit, has to be handed it here.
        onStarted?(process)

        let group = DispatchGroup()
        let outDrain = PipeDrain(reading: outPipe.fileHandleForReading, label: "processrunner.out", group: group)
        let errDrain = PipeDrain(reading: errPipe.fileHandleForReading, label: "processrunner.err", group: group)
        // The dup'd descriptors are independent, so these can go now. Leaving them open leaked
        // two file descriptors per invocation — measured at +80 across 40 runs.
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        let killed = Flag()
        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem {
                // ⚠️ THE GUARD STAYS FIRST — but NOT for the reason it looks like, and the
                // difference was established by mutation rather than argued.
                //
                // Removing it passes all 28 ProcessRunnerTests, including the one that pins a
                // deliberately-backgrounded daemon surviving. That case never reaches here: the
                // command's own process exits, `exited.wait` returns, and `watchdog?.cancel()`
                // lands long before the deadline, so this item simply never runs. Watchdog
                // CANCELLATION is what protects `cmd &`, not this line.
                //
                // What this line does cover is the narrow race where the item had already begun
                // executing when `cancel()` arrived — `cancel()` only prevents a start. Without
                // it, a command that finished right at its bound would be marked `timedOut` AND
                // have its descendants killed: a false statement plus a real side effect, on a
                // run that actually succeeded. Too narrow for a behavioural test to reach
                // reliably, so the order is pinned in `testTheWatchdogChecksLivenessBeforeActing`.
                guard process.isRunning else { return }
                killed.set()

                // The whole job tree, not just the shell. `zsh -c "xcodebuild …"` puts the
                // compiler in a separate process, so signalling only the zsh left the build
                // running past a bound that had already expired — the foreground twin of the
                // defect `ProcessTree` was written for on the background path. A 900 s
                // `batch_command` that times out used to leave the build burning CPU.
                //
                // SIGTERM is a request; `ProcessTree` escalates to SIGKILL after `sigkillGrace`
                // on its own queue, for the same reason the old inline version did — the caller
                // is blocked on `exited` with a bound that depends on this firing on time.
                ProcessTree.terminateTree(root: process.processIdentifier,
                                          grace: sigkillGrace,
                                          isRootRunning: { process.isRunning })
            }
            watchdog = item
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: item)
            // Hard ceiling, so even an unkillable (D-state) child cannot hold the caller.
            if exited.wait(timeout: .now() + timeout + sigkillGrace + 1) == .timedOut { killed.set() }
        } else {
            exited.wait()
        }
        watchdog?.cancel()

        // The child is gone. Keep draining briefly for descendants that inherited the write
        // end — then stop, and record that we stopped.
        var complete = true
        if group.wait(timeout: .now() + descendantGrace) != .success {
            complete = false
            outDrain.stop()
            errDrain.stop()
            _ = group.wait(timeout: .now() + joinBackstop)
        }

        let out = outDrain.snapshot()
        let err = errDrain.snapshot()
        // `terminationStatus` raises on a live process, which the hard ceiling can reach.
        let exitCode = process.isRunning ? -1 : process.terminationStatus

        // Lossy, never nil. `String(data:encoding:.utf8)` returns nil for ANY invalid UTF-8, so
        // a tool emitting binary or mixed-encoding bytes handed its caller an empty string —
        // measured: 100,000 bytes read, 0 characters returned.
        let result = Result(
            standardOutput: String(decoding: out.data, as: UTF8.self),
            standardError: String(decoding: err.data, as: UTF8.self),
            exitCode: exitCode,
            outputComplete: complete,
            standardOutputElidedBytes: out.elided
        )

        if !complete {
            logger.info("[PROC] '\(label.prefix(120))' — child exited but a descendant still held the pipe after \(descendantGrace)s (a backgrounded `cmd &`). Stopped reading and returned \(out.data.count)B/\(err.data.count)B; anything the descendant writes from here is NOT captured and it will take SIGPIPE on its next write. Redirect it (`cmd > log 2>&1 &`) to keep its output.")
        }
        if out.elided > 0 || err.elided > 0 {
            logger.info("[PROC] '\(label.prefix(120))' — output exceeded the capture cap: elided \(out.elided)B of stdout and \(err.elided)B of stderr from the MIDDLE. Head and tail are intact and the gap is marked inline.")
        }
        if killed.isSet {
            logger.info("[PROC] '\(label.prefix(120))' — killed at the \(Int(timeout ?? 0))s bound; \(out.data.count)B stdout, \(err.data.count)B stderr collected before the kill. Partial output is returned rather than discarded.")
        } else if !result.succeeded {
            // ⚠️ On a NON-ZERO exit, print the head of stderr — that is the line that says WHY.
            // This logged sizes only, so a device log read "exited 1 — 0B stdout, 57B stderr" and
            // the 57 bytes carrying the reason never appeared anywhere. Bounded to 200 chars: enough
            // for a shell diagnostic, short enough that a chatty command cannot flood the log. The
            // command itself is already logged in full at the dispatch site, so this reveals nothing
            // the log did not already carry.
            let stderrHead: String = {
                guard exitCode != 0, !err.data.isEmpty else { return "" }
                let text = String(decoding: err.data.prefix(200), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ⏎ ")
                guard !text.isEmpty else { return "" }
                return " stderr: \"\(text)\(err.data.count > 200 ? "…" : "")\""
            }()
            logger.info("[PROC] '\(label.prefix(120))' exited \(exitCode) — \(out.data.count)B stdout, \(err.data.count)B stderr.\(stderrHead) The caller decides whether a non-zero exit is a tool failure or a result.")
        }

        return TimedResult(result: result, timedOut: killed.isSet)
    }

    // MARK: - API

    /// Runs `executable` to completion, draining stdout and stderr concurrently.
    ///
    /// Synchronous and blocking, matching the call sites it replaces — this fixes the deadlock,
    /// it does not alter anyone's threading.
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        if let environment { process.environment = environment }
        return try execute(process, timeout: nil,
                           label: "\(executable) \(arguments.joined(separator: " "))").result
    }

    /// Runs an ALREADY-CONFIGURED process — executable, arguments, working directory already
    /// set by the caller — and collects both streams correctly.
    ///
    /// Exists for the migration: most call sites build their own `Process` and only got the
    /// *collection* wrong, so this lets them keep their setup and drop the broken part. Any
    /// `standardOutput` / `standardError` the caller assigned is REPLACED, which is the point:
    /// the common `process.standardError = Pipe()` idiom looks like "discard stderr" and is
    /// actually "buffer stderr into 64 KB that nobody ever drains, then hang".
    static func run(_ process: Process) throws -> Result {
        try execute(process, timeout: nil, label: process.executableURL?.lastPathComponent ?? "process").result
    }

    /// A bounded run: same concurrent drain, plus a watchdog that actually kills the child.
    ///
    /// The bound applies to the PROCESS. Reading stops when the child is reaped (plus
    /// `descendantGrace`), so a backgrounded descendant can no longer hold the call open past
    /// the deadline — the failure that made the first version of this bound decorative.
    ///
    /// - Warning: a descendant that inherited the write end keeps running, and loses its reader.
    ///   It will take SIGPIPE on its next write. Redirect it (`cmd > log 2>&1 &`) if it is meant
    ///   to outlive the call.
    ///
    /// - Parameter descendantGrace: how long to keep draining after the child is reaped. Callers
    ///   leave the default; a test widens it to pin the MECHANISM (drain past exit, stop at EOF)
    ///   without racing the scheduler against a 0.25 s window.
    static func run(_ process: Process, timeout: TimeInterval,
                    descendantGrace: TimeInterval = descendantGrace,
                    onStarted: ((Process) -> Void)? = nil) throws -> TimedResult {
        try execute(process, timeout: timeout,
                    label: process.executableURL?.lastPathComponent ?? "process",
                    descendantGrace: descendantGrace,
                    onStarted: onStarted)
    }

    /// Convenience for the common `/bin/zsh -c` shape.
    static func zsh(_ command: String, currentDirectory: URL? = nil) throws -> Result {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        return try run(executable: "/bin/zsh", arguments: ["-c", command],
                       currentDirectory: currentDirectory, environment: env)
    }
}
