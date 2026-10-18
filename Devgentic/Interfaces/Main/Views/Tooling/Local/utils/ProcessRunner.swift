// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProcessRunner.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "ProcessRunner")

// Why: draining only after waitUntilExit() deadlocks once a pipe fills (~64 KB);
// EOF never arrives while a backgrounded descendant holds the write end.
/// One correct way to run a subprocess and collect both of its streams.
/// Both pipes are drained concurrently, and completion is the child being reaped, never EOF.
enum ProcessRunner {

    /// Both streams plus the exit status, with the streams kept separate — callers that need
    /// to distinguish "the command printed to stderr" from "the command failed" can, and the
    /// ones that don't can take `combinedOutput`.
    struct Result: Sendable {
        let standardOutput: String
        let standardError: String
        let exitCode: Int32

        /// False when a descendant still held the pipe after the child was reaped and the grace expired.
        /// Reading then stopped with bytes possibly still to come, so "that was all of it" is not guaranteed.
        let outputComplete: Bool

        /// Bytes dropped from the middle of stdout by the head/tail capture cap; 0 when stdout is whole.
        /// Independent of `outputComplete`. For callers that parse stdout: the gap is otherwise marked only by inline text.
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

    /// A bounded run's outcome. `timedOut` is reported separately from the exit code because a killed child still has one,
    /// and "we killed it" differs from "it exited non-zero".
    struct TimedResult: Sendable {
        let result: Result
        let timedOut: Bool
    }

    // MARK: - Tuning

    /// How long SIGTERM gets before SIGKILL. Long enough for a well-behaved child to flush and
    /// unwind, short enough that a wedged one cannot extend the caller's bound noticeably.
    private static let sigkillGrace: TimeInterval = 2

    /// How long to keep reading after the child is reaped, for descendants that inherited the write end.
    /// A forked worker writing within this window is captured; past it reading stops and `outputComplete` is false.
    /// 0.25 s covers pipe scheduling latency (at most ~64 KB is in flight), not a throughput number.
    static let descendantGrace: TimeInterval = 0.25

    /// Ceiling on the join after we cancel the sources. Cancellation is prompt, so reaching
    /// this means something is badly wrong; returning beats hanging.
    private static let joinBackstop: TimeInterval = 1.0

    /// Per-stream capture cap, split head/tail so unbounded output cannot exhaust memory.
    /// Head and tail rather than head-only: under a flooding descendant the newest bytes are the child's own final lines.
    private static let headKeep = 8 << 20
    private static let tailKeep = 8 << 20

    /// Bytes one wake may consume before yielding, so `cancel()` stays responsive under a
    /// firehose instead of being starved by an event handler that keeps finding more.
    private static let perWakeCap = 4 << 20

    // MARK: - Drain

    /// One pipe read end, drained continuously on its own serial queue.
    /// `@unchecked Sendable`: `bytes`/`tail`/`elided`/`sawEOF` are guarded by `lock` on every path, snapshots included.
    /// `fd` and `buf` are immutable after init and touched only on `queue`.
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
            // Our own descriptor: arming a source on the FileHandle's number risks the handle deinitialising, the number being
            // recycled, and the source reading an unrelated file.
            fd = dup(handle.fileDescriptor)
            buf = .allocate(byteCount: 65_536, alignment: 1)
            // Read end only. `pipe(2)` gives the two ends separate open file descriptions, so
            // the child's `write(2)` stays blocking and back-pressure still works.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            // Its own serial queue: sharing one lets a busy stdout handler starve stderr until its pipe fills and blocks the writer.
            // `.userInitiated` to match the caller: `run` blocks on `group.wait`, so a lower QoS here is a priority inversion.
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

        // After `run()` (there is no pid before it) and after the pipes are attached. The only moment a caller can take a
        // handle on a running foreground process, since `execute` blocks until the command finishes.
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
                // The guard stays first: it covers the race where the item had already started when `cancel()` arrived (cancel only
                // prevents a start), so a command finishing at its bound is not marked `timedOut` with its descendants killed.
                guard process.isRunning else { return }
                killed.set()

                // The whole job tree, not just the shell: `zsh -c "xcodebuild …"` puts the compiler in a separate process.
                // SIGTERM is a request; `ProcessTree` escalates to SIGKILL after `sigkillGrace` so the bound fires on time.
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

        // Lossy, never nil: `String(data:encoding:.utf8)` returns nil for any invalid UTF-8, which would hand a caller an
        // empty string for binary or mixed-encoding output.
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
            // On a non-zero exit print the head of stderr (200 chars) since it says why; the command itself is already logged
            // in full at the dispatch site.
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
    /// Synchronous and blocking; the caller's threading is unchanged.
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

    /// Runs an already-configured process (executable, arguments and working directory set by the caller).
    /// Collects both streams; any `standardOutput` / `standardError` the caller assigned is replaced.
    /// A caller-assigned `Pipe()` would buffer into 64 KB that nobody drains and then hang.
    static func run(_ process: Process) throws -> Result {
        try execute(process, timeout: nil, label: process.executableURL?.lastPathComponent ?? "process").result
    }

    /// A bounded run: the same concurrent drain, plus a watchdog that kills the child.
    /// Reading stops once the child is reaped (plus `descendantGrace`); a surviving descendant gets SIGPIPE on write,
    /// so redirect it (`cmd > log 2>&1 &`) to outlive the call.
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
