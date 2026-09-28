// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundProcessRegistry.swift
//  Devgentic
//
//  The owner of every process a conversation started and did not wait for.
//
//  `batch_command(background: true)` used to be fire-and-forget in the literal sense: both
//  streams to `FileHandle.nullDevice`, `run()`, and a pid in a sentence. Nothing survived the
//  call, so there was no id to name, no output to read, nothing to stop, and nothing to clean up
//  at quit — `applicationShouldTerminate` disconnects MCP children precisely so they are not
//  "re-parented to launchd as orphans", and these were.
//
//  It also computed `timeout_seconds` and then never applied it on that branch, so a caller
//  asking for a bound got an unbounded process.
//
//  ── Why the bound lives HERE and not in a tool ──────────────────────────────────────────
//
//  The obvious alternative is a `timer_tool` the model starts alongside the task, killing the
//  pid when it expires. Rejected on three counts:
//
//    1. The guarantee would exist only when the model pairs two calls correctly, every time.
//       `ProcessRunner.run(_:timeout:)` applies the foreground bound whether or not the model
//       asked; a bound conditional on the model not deviating is not a bound.
//    2. A tool-shaped timer has nowhere to run. Blocking parks the agent for the duration,
//       which defeats `background`; non-blocking makes the timer itself a long-lived process
//       needing its own watchdog.
//    3. ⚠️ A pid in a string is not a safe target. macOS RECYCLES pids. This registry retains
//       the `Process` OBJECT and asks `isRunning` before every signal, exactly as
//       `ProcessRunner`'s watchdog does. A model-supplied number has none of that: a command
//       that finished at minute 3 leaves a minute-15 kill to hit whatever inherited the
//       number. Same class as `kill_process`'s non-positive-pid refusal — signalling something
//       other than what you meant.
//
//  ── Why a file rather than a pipe ───────────────────────────────────────────────────────
//
//  The old comment was right that an unread pipe wedges the child the moment it writes ~64 KB.
//  The answer is a file, which never blocks — and it removes the EOF problem that shaped
//  `ProcessRunner` too: a descendant holding the write end can keep appending after the child
//  is reaped without holding anything open, because there is no reader to join.
//
//  ONE `FileHandle` is assigned to BOTH streams, so the child receives the same descriptor
//  twice and the two interleave in true chronological order — `cmd > log 2>&1`. For a build log
//  that ordering IS the content: a compiler error on stderr belongs between the stdout lines
//  that bracket it. Two handles on one path would each carry their own offset and overwrite
//  each other.
//
//  ── Killing the job, not just the shell ────────────────────────────────────────────────
//
//  `zsh -c "xcodebuild …"` puts the compiler in a SEPARATE process from the zsh, so signalling
//  the zsh alone left the build running and re-parented to launchd — `stop` reported "stopped"
//  while the machine stayed busy. Every kill here goes through `ProcessTree`, which snapshots
//  the descendants first and then signals them; its type comment carries the reasoning, including
//  why `killpg` is not available (a `Process` child inherits the APP's process group, so killing
//  that group would kill Devgentic).
//
//  ⚠️ Still best-effort: a process forked between the snapshot and the signal is missed. Only a
//  real process group closes that, and getting one means giving up `Process.isRunning` — the
//  pid-reuse guard every signal in this file depends on.
//

import Foundation
import os

private let logger = DGLogger(category: "BackgroundProcessRegistry")

extension Notification.Name {
    /// A background task was launched, or its status changed. Carries `taskID` and
    /// `conversationID`. Observed by `BackgroundTaskObserver`, which owns the timeline row.
    ///
    /// ⚠️ A notification rather than a direct call, for the same reason the HITL resolutions use
    /// one: this registry is lock-based and off the MainActor, and the thing that wants to know is
    /// a `@MainActor` view model. Posting decouples them without this type learning about the UI.
    static let backgroundTaskChanged = Notification.Name("backgroundTaskChanged")
}

enum BackgroundTaskNotificationKey {
    static let taskID = "taskID"
    static let conversationID = "conversationID"
}

final class BackgroundProcessRegistry: @unchecked Sendable {

    /// Process-wide instance. Tests construct their own against a scratch directory rather than
    /// sharing this one — a registry that outlives a test would leak children into the next.
    static let shared = BackgroundProcessRegistry(rootDirectory: defaultRootDirectory)

    /// Where command logs live: `~/Library/Application Support/Devgentic/Logs/Commands/<conversation>/`.
    ///
    /// ⚠️ NOT the temporary directory, which is where they lived until 2026-09-24. macOS cleans
    /// `$TMPDIR` on its own schedule (files unused for about three days, and at restart), so a
    /// retention period set here could never be honoured there — the OS would delete logs this
    /// type had promised to keep. Application Support is removed only by us.
    ///
    /// A test host is redirected to a temp directory, as `TraceStore` is: the suite runs real
    /// commands through `shared`, and must never write into the user's real log folder.
    static var defaultRootDirectory: URL {
        if TestHost.isRunning {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("devgentic-command-logs-testhost", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Devgentic/Logs/Commands", isDirectory: true)
    }

    // MARK: - Types

    /// ⚠️ `timedOut` and `stopped` are kept SEPARATE from `exited`, for the reason
    /// `ProcessRunner.TimedResult` keeps `timedOut` beside the exit code: a killed child still
    /// has a termination status, and reporting a signal number as a chosen exit code is a false
    /// statement about what the command did. The first terminal status wins — see `finish`.
    enum Status: Sendable, Equatable {
        case running
        case exited(code: Int32)
        case timedOut
        case stopped

        var isTerminal: Bool {
            if case .running = self { return false }
            return true
        }

        /// Model-facing wording. A status line the model has to interpret is worth more than a
        /// raw enum name, and phrasing it once keeps three tools from each inventing their own.
        var label: String {
            switch self {
            case .running:            return "running"
            case .exited(let code):   return code == 0 ? "finished (exit 0)" : "finished (exit \(code))"
            case .timedOut:           return "killed — it reached its timeout"
            case .stopped:            return "killed — stopped on request"
            }
        }
    }

    /// The read model. Deliberately carries no `Process` and no file handle: everything a caller
    /// outside this type is allowed to see, and `Sendable` because of what it leaves out.
    struct Snapshot: Sendable, Equatable {
        let id: String
        /// What the caller called this task, when it said. `bg_1` is a handle, not a description —
        /// a list of tasks is only worth opening if the rows say what they are.
        let name: String?
        let command: String
        let workingDirectory: String
        let startedAt: Date
        let finishedAt: Date?
        let status: Status
        let logURL: URL
        /// The last `maxTailLines` lines of the log, held in memory by the registry.
        ///
        /// ⚠️ THE WHOLE POINT OF THIS TYPE'S REWRITE. Every reader used to `String(contentsOf:)`
        /// the log file — `BackgroundTaskObserver` did it on the MainActor once a SECOND, per live
        /// task, and then took `.count` of the result twice (Swift's `String.count` is an O(n)
        /// grapheme walk). A dev server — the workload `start_background_task`'s own description
        /// points the model at — reaches tens of MB in an hour, so the UI froze on exactly the
        /// case the feature exists for. This is fed by `drainTail`, which reads only the bytes
        /// added since last time.
        let tail: String
        /// Whether the caller asked to be told when this finishes.
        ///
        /// ⚠️ Carried on the RECORD, not remembered by whatever wants to act on it. The task
        /// outlives the turn that started it — that is the whole premise — so the intent has to
        /// live where the task does, or a wake would depend on some other object surviving too.
        let notifyOnCompletion: Bool
        /// Characters the log holds in total, so a reader can say how much is not shown above.
        ///
        /// Accumulated one delta at a time rather than measured, so it never costs a pass over
        /// the file. Characters, not bytes: `BackgroundTaskCard` compares it against
        /// `outputTail.count` and the two must be the same unit or a non-ASCII log over-reports.
        let logCharacterCount: Int

        /// Wall-clock, frozen once the task ends.
        func elapsed(now: Date = Date()) -> TimeInterval {
            (finishedAt ?? now).timeIntervalSince(startedAt)
        }
    }

    // MARK: - Tuning

    /// SIGTERM's grace before SIGKILL. Same value and same reasoning as `ProcessRunner`: long
    /// enough for a well-behaved child to flush and unwind, short enough not to extend a bound
    /// that has already expired.
    private static let sigkillGrace: TimeInterval = 2

    /// ⚠️ Quit teardown runs inside `applicationShouldTerminate`, which carries a 3 s watchdog.
    /// One SHORT grace shared by every task — never a per-task serial 2 s, which would blow the
    /// budget on four tasks and get the app killed mid-teardown instead of exiting cleanly.
    private static let quitGrace: TimeInterval = 0.4

    /// How often live tasks' descendants are re-captured. The window this leaves is the window in
    /// which a child can be forked AND orphaned without ever being seen — a second is short
    /// against a build, and the walk is one `sysctl` shared by every live task.
    private static let descendantRefreshInterval: TimeInterval = 1.0

    /// Lines the in-memory tail keeps per task.
    ///
    /// Sized for the MODEL, not the card. The card wants the last handful; `command_output` is a
    /// model reading why a build failed, and a Swift compile error with its context notes, or a
    /// crash backtrace, runs well past twenty lines. Cutting there would lose the actual error —
    /// the same defect class the head+tail cut (now `ToolResultBudget.fit`) exists to close.
    private static let maxTailLines = 200

    /// Ceiling on a single drain.
    ///
    /// A task left unwatched for an hour can grow its log without bound; the next drain must not
    /// then read all of it. Past this, the drain SKIPS to the last `maxDrainBytes` — the tail is
    /// what anyone wants from a log that big, and the whole file is still on disk for `readLog`.
    private static let maxDrainBytes: UInt64 = 1 << 20

    /// A run of bytes carrying no newline is force-flushed past this.
    ///
    /// ⚠️ NOT belt-and-braces. Progress output (`npm`, `pip`, `xcodebuild -quiet`) redraws with
    /// CARRIAGE RETURNS and can emit megabytes without ever writing `\n`. Holding an incomplete
    /// line until its newline arrives — which is what makes incremental reads correct — would
    /// otherwise grow `pending` for the life of the task. This is new exposure: re-reading the
    /// whole file each time, as the old code did, accumulated nothing.
    private static let maxPendingBytes = 64 * 1024

    /// Ceiling on ONE task's log file before it is rotated.
    ///
    /// The file was previously unbounded. `start_background_task` recommends itself for a dev
    /// server, and a dev server appends for as long as it runs — hours of output with nothing
    /// watching the size. Bounded here rather than by killing the task: a build that talks a lot is
    /// not misbehaving, and terminating it would make a disk-space policy into a work-loss policy.
    ///
    /// 32 MB keeps essentially every real build whole while capping a runaway at a size no disk
    /// notices.
    static let defaultMaxLogBytes: UInt64 = 32 * 1024 * 1024

    /// How long a log is kept after it was last written. User decision 2026-09-24: 7 days.
    ///
    /// Measured per FILE from its modification date, not per conversation directory: a directory's
    /// date moves only when a file is added or removed, so one fresh command kept a week-old
    /// sibling alive, and a long-running task's directory looked old while its log was current.
    static let defaultLogRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Ceiling on ALL command logs together. User decision 2026-09-24: 1 GB.
    ///
    /// The age limit alone does not bound disk use: one log may reach `defaultMaxLogBytes` before it
    /// rotates, and a busy week of dev servers and builds could add up to many GB. Past this, the
    /// oldest logs go first.
    static let defaultTotalLogBytes: UInt64 = 1024 * 1024 * 1024

    /// How often the sweep runs while the app stays open. Launch alone is not enough: an app left
    /// running for weeks would never apply the retention period at all.
    static let sweepInterval: TimeInterval = 24 * 60 * 60

    // MARK: - State

    private final class Entry {
        let id: String
        let conversationID: UUID
        let name: String?
        let command: String
        let workingDirectory: String
        let startedAt: Date
        let logURL: URL
        let process: Process
        let notifyOnCompletion: Bool
        var finishedAt: Date?
        var status: Status = .running
        var watchdog: DispatchWorkItem?

        /// The shell has exited and its final drain is done. Distinct from `status.isTerminal`:
        /// a timeout or a stop sets the status FIRST, while the process is still being killed.
        var ended = false
        /// Callers waiting in `waitUntilEnded` — the foreground path. Resumed once, after `ended`.
        var waiters: [CheckedContinuation<Void, Never>] = []

        /// Descendants seen WHILE this task's shell was alive.
        ///
        /// ⚠️ THE ORPHAN FIX. Walking the tree only at kill time fails when the shell has already
        /// exited: its children are re-parented to launchd and the ppid chain identifying them as
        /// ours is gone, so the walk returns nothing and the bound kills a process that had
        /// already left while the real work runs on. Captured every second while the chain is
        /// intact, this list stays usable afterwards. Identities, not pids — see `ProcessTree`.
        var knownDescendants: Set<ProcessTree.ProcessIdentity> = []

        // ── Incremental tail ────────────────────────────────────────────────────────────
        /// Bytes of `logURL` already folded into `tailLines`. The drain resumes from here.
        var consumed: UInt64 = 0
        /// Bytes read but not yet a complete line. Held back so a delta ending mid-line does not
        /// publish half of it, and — because a newline byte can never appear inside a multi-byte
        /// UTF-8 sequence — so a character split across two reads is never decoded in halves.
        var pending = Data()
        /// The rolling window. Bounded by `maxTailLines`.
        var tailLines: [String] = []
        /// Running total, accumulated per delta. See `Snapshot.logCharacterCount`.
        var totalCharacters = 0

        init(id: String, conversationID: UUID, name: String?, command: String,
             workingDirectory: String, startedAt: Date, logURL: URL, process: Process,
             notifyOnCompletion: Bool = false) {
            self.id = id
            self.conversationID = conversationID
            self.name = name
            self.command = command
            self.workingDirectory = workingDirectory
            self.startedAt = startedAt
            self.logURL = logURL
            self.process = process
            self.notifyOnCompletion = notifyOnCompletion
        }

        var snapshot: Snapshot {
            Snapshot(id: id, name: name, command: command, workingDirectory: workingDirectory,
                     startedAt: startedAt, finishedAt: finishedAt, status: status, logURL: logURL,
                     tail: tailLines.joined(separator: "\n"),
                     notifyOnCompletion: notifyOnCompletion,
                     logCharacterCount: totalCharacters)
        }
    }

    /// `NSLock` rather than an actor, deliberately. `terminationHandler` and the watchdog fire on
    /// GCD queues with no async context; an actor would force a hop from each of them to guard
    /// what is a small map. `ToolSchemaSizes` is locked for the same reason.
    private let lock = NSLock()
    private var entries: [UUID: [Entry]] = [:]
    private var counters: [UUID: Int] = [:]
    /// Set by `terminateAll`. From then on nothing is announced (D-29): a quit-time `.stopped`
    /// used to reach `BackgroundTaskWakeCoordinator`, which could start an unattended run while the
    /// app was quitting — one that then told the model the task was "stopped on request".
    private var isQuitting = false
    private var refreshTimer: DispatchSourceTimer?
    private var sweepTimer: DispatchSourceTimer?
    /// Log paths `launch` has created but not yet registered. The sweep treats them as live:
    /// between the file's creation and `entries.append` there is a process spawn, and a sweep in
    /// that window would otherwise see an unowned file and could delete it under the new task.
    private var reservedLogPaths: Set<String> = []
    /// One sweep at a time. Two overlapping passes would each total the same files and each delete
    /// enough to get under the cap — together removing roughly twice what was needed.
    private let sweepLock = NSLock()
    private let rootDirectory: URL

    /// ⚠️ INSTANCE, not static, purely so tests can use small values. Writing 32 MB to prove a
    /// 32 MB cap works would put a multi-second disk write in the suite for no extra confidence —
    /// the ROTATION is the behaviour under test, and the threshold is a number. `shared` and every
    /// production caller take the defaults, which `testTheShippedCapsAreTheOnesProductionUses` pins
    /// so a convenient test value can never quietly become the shipped one.
    private let maxLogBytes: UInt64
    private let logRetention: TimeInterval
    private let maxTotalLogBytes: UInt64

    init(rootDirectory: URL,
         maxLogBytes: UInt64 = BackgroundProcessRegistry.defaultMaxLogBytes,
         logRetention: TimeInterval = BackgroundProcessRegistry.defaultLogRetention,
         maxTotalLogBytes: UInt64 = BackgroundProcessRegistry.defaultTotalLogBytes) {
        self.rootDirectory = rootDirectory
        self.maxLogBytes = maxLogBytes
        self.logRetention = logRetention
        self.maxTotalLogBytes = maxTotalLogBytes
        startSweeping()
    }

    deinit { sweepTimer?.cancel() }

    // MARK: - Launch

    /// Starts `command` detached, bounds it at `timeout`, and returns its record.
    ///
    /// The caller gets a task id, never a pid. That is not decoration: a pid is the thing that
    /// cannot be safely handed back (see the type comment).
    ///
    /// `foreground` is a caller that will WAIT, through `waitUntilEnded` — `run_command`. It runs
    /// exactly as a background task does, writing its log live; only the id prefix (`fg_`) and the
    /// log line differ. One mechanism for both means a foreground build's log exists from its first
    /// second, survives a crash mid-run, and interleaves stdout and stderr as they happened.
    @discardableResult
    func launch(command: String,
                workingDirectory: String,
                timeout: TimeInterval,
                conversationID: UUID,
                name: String? = nil,
                notifyOnCompletion: Bool = false,
                foreground: Bool = false) throws -> Snapshot {

        let directory = rootDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let startedAt = Date()
        let id = nextID(for: conversationID, foreground: foreground)

        // ⚠️ O_APPEND IS WHAT MAKES ROTATION POSSIBLE, and it is not incidental. `FileHandle(
        // forWritingTo:)` opens WITHOUT it, so the child carries its own file offset — truncating
        // the file under it would leave that offset untouched and the next write would land at the
        // old position, producing a SPARSE file whose head reads back as megabytes of NUL. With
        // O_APPEND every write goes to the current end atomically, so `enforceLogCap` can truncate
        // to zero and the child simply carries on from there.
        //
        // It also strengthens the property the single shared handle exists for: two streams
        // appending atomically to one description interleave in true chronological order.
        //
        // ⚠️ O_EXCL: a log is only ever a NEW file. Before 2026-09-24 the name was just `bg_N`, and
        // the counter restarts every launch while the folder does not — so the first task after a
        // relaunch APPENDED to the previous run's `bg_1.log` and its card opened on someone else's
        // output. The timestamped name makes a clash near-impossible; O_EXCL makes it impossible.
        // Reserved BEFORE the file exists — see `reservedLogPaths` — and released once the entry is
        // registered (or the launch fails), by which point `entries` covers it.
        var reserved: [String] = []
        func reserve(_ url: URL) {
            lock.lock()
            reserved.append(url.standardizedFileURL.path)
            reservedLogPaths.insert(url.standardizedFileURL.path)
            lock.unlock()
        }
        defer {
            lock.lock()
            reservedLogPaths.subtract(reserved)
            lock.unlock()
        }

        var logURL = directory.appendingPathComponent(Self.logFileName(id: id, startedAt: startedAt,
                                                                       name: name, command: command))
        reserve(logURL)
        var fd = open(logURL.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o644)
        if fd < 0, errno == EEXIST {
            let retry = Self.logFileName(id: id, startedAt: startedAt, name: name, command: command,
                                         disambiguator: String(UUID().uuidString.prefix(6)))
            logURL = directory.appendingPathComponent(retry)
            reserve(logURL)
            fd = open(logURL.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o644)
        }
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        // The same descriptor twice — `> log 2>&1`. See the type comment.
        process.standardOutput = handle
        process.standardError = handle

        let entry = Entry(id: id, conversationID: conversationID, name: name, command: command,
                          workingDirectory: workingDirectory,
                          startedAt: startedAt, logURL: logURL, process: process,
                          notifyOnCompletion: notifyOnCompletion)

        // Installed BEFORE `run()`. A command that exits immediately would otherwise finish
        // before anything was watching, and the entry would sit at `.running` forever.
        process.terminationHandler = { [weak self] finished in
            try? handle.close()
            guard let self else { return }
            // ⚠️ ORDER IS LOAD-BEARING, twice over.
            //
            // After `close()`, so the child's last writes have landed and the final drain sees a
            // complete file — this is the read that captures output no `\n` ever terminated.
            //
            // BEFORE `finish`, because `finish` announces and `BackgroundTaskObserver` reads the
            // snapshot the instant that notification arrives.
            //
            // ⚠️ Draining afterwards is a RACE, not a certain failure, and the distinction matters
            // because it is why no behavioural test can hold this line. `announce` hops to the main
            // queue (see it for the 7.489 s measurement that forced that), so a drain running after
            // it would USUALLY still win. It loses when the main queue is idle and the file is
            // large — and when it loses, the terminal row is short of the verdict permanently:
            // there is no second announcement for a task that has already ended. Ordering closes
            // the window outright, and `testTheFinalDrainIsOrderedBeforeTheAnnouncement` pins it
            // structurally for exactly the reason `testAnnounceDoesNotBlockTheKillPath` does.
            self.drainTail(entry, final: true)
            let settledEarlier = self.isSettled(entry)
            let cancelled = self.finish(entry, status: .exited(code: finished.terminationStatus))
            cancelled?.cancel()
            // ⚠️ D-29: a stop or timeout SETS the verdict before the kill lands but does not
            // announce it (see `finish(announce:)`); this is the announcement, now that the final
            // drain has the output the command wrote while it was being signalled. Announcing at
            // the verdict published a stale tail — on the card and in a woken run's prompt — and
            // no second announcement ever followed.
            if settledEarlier { self.announceIfStillRegistered(entry) }
            // LAST: a foreground caller reads the log the moment it is woken, so the handle must be
            // closed and the status settled first.
            self.markEnded(entry)
        }

        do {
            try process.run()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: logURL)
            logger.error("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(id) failed to launch: \(error.localizedDescription). CONSEQUENCE: nothing is registered, so the caller sees the failure now rather than polling a task that never existed.")
            throw error
        }

        arm(entry, timeout: timeout, conversationID: conversationID)
        startDescendantRefreshIfNeeded()

        lock.lock()
        entries[conversationID, default: []].append(entry)
        let snapshot = entry.snapshot
        lock.unlock()

        if foreground {
            logger.info("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(id) launched in the FOREGROUND (pid \(process.processIdentifier)), bounded at \(Int(timeout))s, log: \(logURL.path). CONSEQUENCE: the caller waits for it; the log is written live, so it is readable while the command runs and survives a crash.")
        } else {
            logger.info("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(id) launched (pid \(process.processIdentifier)), bounded at \(Int(timeout))s, log: \(logURL.path). CONSEQUENCE: output is collectable via command_output and the task is killed at its bound whether or not the model checks back.")
        }
        announce(taskID: id, conversationID: conversationID)
        return snapshot
    }

    /// Suspends until the task's shell has exited and its log is complete. Returns the final
    /// record, or nil if the id is unknown.
    ///
    /// Waits for the process to EXIT, not merely for a terminal status: a timeout or a stop sets
    /// the status before the kill lands, and reading the log at that moment would miss the last
    /// lines the command wrote while it was being signalled.
    func waitUntilEnded(conversationID: UUID, taskID: String) async -> Snapshot? {
        lock.lock()
        let entry = entries[conversationID]?.first { $0.id == taskID }
        lock.unlock()
        guard let entry else { return nil }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if entry.ended {
                lock.unlock()
                continuation.resume()
            } else {
                entry.waiters.append(continuation)
                lock.unlock()
            }
        }
        lock.lock()
        defer { lock.unlock() }
        return entry.snapshot
    }

    private func markEnded(_ entry: Entry) {
        lock.lock()
        entry.ended = true
        let waiters = entry.waiters
        entry.waiters = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    /// `<yyyyMMdd-HHmmss>_<id>_<slug>.log`, e.g. `20260924-132205_bg_1_npm-run-dev.log`.
    ///
    /// The timestamp makes every file unique across launches (the id alone restarts at 1), and
    /// sorts a folder chronologically. The slug is the task's name, or the command when it has
    /// none, so a folder listing says what each log is without opening it.
    static func logFileName(id: String, startedAt: Date, name: String?, command: String,
                            disambiguator: String? = nil) -> String {
        let stamp = logTimestampFormatter.string(from: startedAt)
        let slug = logSlug(name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? command)
        var parts = [stamp, id]
        if !slug.isEmpty { parts.append(slug) }
        if let disambiguator { parts.append(disambiguator) }
        return parts.joined(separator: "_") + ".log"
    }

    /// Lowercase ASCII letters and digits, runs of anything else collapsed to one `-`, at most 40
    /// characters. A file name has to survive every tool that will ever touch it; a command line
    /// carries slashes, quotes, pipes and spaces, none of which should.
    static func logSlug(_ text: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                let dash = pendingDash && !slug.isEmpty
                // Room for the dash AND the character, or stop — a slug never ends on a dash.
                guard slug.count + (dash ? 2 : 1) <= 40 else { break }
                if dash { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return slug
    }

    /// Local time, fixed POSIX locale so the digits are always Western and the layout never
    /// follows the user's region settings.
    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// Arms the bound that the background path silently dropped.
    ///
    /// The `isRunning` guards are the pid-reuse protection and are load-bearing — the pid is
    /// captured only after the first one, and re-checked before SIGKILL. Lifted unchanged in
    /// shape from `ProcessRunner.execute`.
    private func arm(_ entry: Entry, timeout: TimeInterval, conversationID: UUID) {
        guard timeout > 0 else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard entry.process.isRunning else { return }
            // Status FIRST, so "we killed it" wins the race against the `terminationHandler`
            // that this very `terminate()` is about to trigger.
            _ = self.finish(entry, status: .timedOut, announce: false)   // announced after the final drain (D-29)

            // The whole job tree, not just the shell. `zsh -c "xcodebuild …"` leaves the compiler
            // running if only the zsh is signalled, and a bound that does not stop the work is
            // not a bound. `ProcessTree` snapshots descendants BEFORE signalling, because killing
            // the root re-parents them to launchd and loses the chain that identifies them.
            let descendants = ProcessTree.terminateTree(
                root: entry.process.processIdentifier,
                grace: Self.sigkillGrace,
                isRootRunning: { entry.process.isRunning },
                alsoKnown: self.remembered(for: entry))

            // ⚠️ "signalled", not "killed". Device test 2026-09-21 surfaced the overclaim: at this
            // point SIGTERM has been sent and the SIGKILL escalation is still pending on
            // `ProcessTree`'s queue, so nothing here has been confirmed dead. The count is what the
            // snapshot FOUND, which is a third distinct fact. A log that states an outcome it has
            // not observed is the thing the bracket-tag standard exists to prevent.
            logger.notice("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(entry.id) reached its \(Int(timeout))s bound: it and \(descendants) descendant process(es) found under it were sent SIGTERM, with SIGKILL to follow in \(Int(Self.sigkillGrace))s for anything still running. CONSEQUENCE: whatever it had written to its log is kept; anything it would have produced later is lost. A process forked after the tree was snapshotted is not in that count and can survive.")
        }

        lock.lock()
        // The command may already have exited — `terminationHandler` can fire before we get
        // here. Arming anyway would be harmless (the `isRunning` guard no-ops) but recording a
        // watchdog on a finished task would leave something to cancel that nobody cancels.
        let alreadyDone = entry.status.isTerminal
        if !alreadyDone { entry.watchdog = item }
        lock.unlock()

        guard !alreadyDone else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Records a terminal status, FIRST ONE WINS, and hands back the watchdog to cancel.
    ///
    /// The precedence is the point. A timeout kill triggers `terminationHandler`, which would
    /// otherwise overwrite `.timedOut` with `.exited(15)` and report a signal number as though
    /// the command had chosen to exit 15.
    /// - Parameter announce: false when the process is still running and about to be killed — the
    ///   termination handler announces once the final drain is done (D-29).
    @discardableResult
    private func finish(_ entry: Entry, status: Status, announce shouldAnnounce: Bool = true) -> DispatchWorkItem? {
        lock.lock()
        var accepted = false
        var watchdog: DispatchWorkItem?
        if !entry.status.isTerminal {
            entry.status = status
            entry.finishedAt = Date()
            watchdog = entry.watchdog
            entry.watchdog = nil
            accepted = true
        }
        let conversationID = entry.conversationID
        lock.unlock()

        // ⚠️ OUTSIDE the lock. `announce` hops to the MainActor, and posting from inside would
        // hold this lock across that boundary — the observer then reads the registry on arrival
        // and would deadlock against a writer that had not yet released.
        if accepted, shouldAnnounce { announce(taskID: entry.id, conversationID: conversationID) }
        return watchdog
    }

    /// Whether a terminal status is already recorded.
    private func isSettled(_ entry: Entry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entry.status.isTerminal
    }

    /// Announces `entry`'s ending — unless its conversation was discarded (deleted), in which case
    /// there is nobody to tell, and a wake would start a run in a conversation that no longer exists.
    private func announceIfStillRegistered(_ entry: Entry) {
        lock.lock()
        let registered = entries[entry.conversationID]?.contains { $0 === entry } ?? false
        lock.unlock()
        guard registered else { return }
        announce(taskID: entry.id, conversationID: entry.conversationID)
    }

    /// Tells whoever is rendering this task that something changed. Fire-and-forget: a task with
    /// no observer (a workflow node, a run whose conversation is closed) is not an error.
    ///
    /// ⚠️⚠️ THE `async` IS LOAD-BEARING. `NotificationCenter.post` does NOT return promptly when an
    /// observer is registered on `.main` — it waits for that observer to be delivered. Measured
    /// 2026-09-21: **7.489 seconds**, exactly as long as the main thread stayed busy.
    ///
    /// That matters far beyond a slow log line, because `finish` is called from the WATCHDOG,
    /// between marking the task `.timedOut` and actually killing it. Posting inline meant a busy
    /// main thread delayed every timeout kill for as long as it stayed busy — and in a real Code
    /// run the main thread is busy rendering the streaming response. By the time the kill ran, the
    /// shell had exited on its own and the process tree was empty, so it killed nothing. The task
    /// reported "killed at its timeout" while the work carried on.
    ///
    /// This cost four wrong diagnoses (slow fork, widen the bound, orphaned child, SIGTERM
    /// ignored) before the delay was simply measured. Nothing about the symptom pointed at a
    /// notification.
    private func announce(taskID: String, conversationID: UUID) {
        lock.lock()
        let quitting = isQuitting
        lock.unlock()
        guard !quitting else { return }
        let payload: [String: Any] = [
            BackgroundTaskNotificationKey.taskID: taskID,
            BackgroundTaskNotificationKey.conversationID: conversationID,
        ]
        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(name: .backgroundTaskChanged, object: nil, userInfo: payload)
        }
    }

    private func nextID(for conversationID: UUID, foreground: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        let next = (counters[conversationID] ?? 0) + 1
        counters[conversationID] = next
        // Short because a small model has to echo it back. Scoped per conversation, so `bg_1`
        // in two conversations is not a collision — every lookup takes the conversation too.
        // One counter for both prefixes, so `fg_2` and `bg_2` never coexist in one conversation
        // and the number alone still orders the conversation's commands.
        return "\(foreground ? "fg" : "bg")_\(next)"
    }

    // ⚠️ `adopt(process:…)` / `complete(…)` WERE REMOVED 2026-09-24. A foreground run used to go
    // through `ProcessRunner`'s pipes and was registered here only for its card, stop control and
    // quit teardown; its log was written ONCE, from the finished result. So a crash mid-build left
    // no log at all, and stdout and stderr arrived as two separate blocks with their relative order
    // lost. Foreground runs now use `launch(foreground: true)` + `waitUntilEnded` — the same live,
    // interleaved log a background task has.

    // MARK: - Remembering descendants

    private func remembered(for entry: Entry) -> Set<ProcessTree.ProcessIdentity> {
        lock.lock()
        defer { lock.unlock() }
        return entry.knownDescendants
    }

    /// Starts the capture loop if anything is live. Idempotent.
    private func startDescendantRefreshIfNeeded() {
        lock.lock()
        let alreadyRunning = refreshTimer != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Self.descendantRefreshInterval,
                       repeating: Self.descendantRefreshInterval)
        timer.setEventHandler { [weak self] in self?.captureDescendants() }

        lock.lock()
        refreshTimer = timer
        lock.unlock()
        timer.resume()
    }

    /// One pass: for every live task, fold this moment's tree into what we already knew.
    ///
    /// ⚠️ Pruned to what is still alive on every pass, so a long build does not accumulate every
    /// compiler process it ever spawned. A descendant whose CHAIN broke is still alive and stays —
    /// that is the entire point of remembering it.
    private func captureDescendants() {
        lock.lock()
        let live = entries.values.flatMap { $0 }.filter { !$0.status.isTerminal }
        lock.unlock()

        guard !live.isEmpty else {
            lock.lock()
            refreshTimer?.cancel()
            refreshTimer = nil
            lock.unlock()
            return
        }

        for entry in live where entry.process.isRunning {
            // ⚠️ PIGGYBACKED ON THIS TICK ON PURPOSE. The tail rewrite removed every periodic read,
            // and a size cap needs SOMETHING periodic — but this timer already runs once a second
            // while anything is live, on a utility queue, and stops itself when nothing is. Adding
            // a second timer would give back the cost that rewrite removed. A `stat` is not a read:
            // it costs nothing close to what `String(contentsOf:)` did.
            enforceLogCap(entry)

            let fresh = Set(ProcessTree.descendantIdentities(of: entry.process.processIdentifier))
            lock.lock()
            let merged = entry.knownDescendants.union(fresh)
            lock.unlock()
            let pruned = ProcessTree.stillAlive(merged)
            lock.lock()
            entry.knownDescendants = pruned
            lock.unlock()
        }
    }

    // MARK: - Read

    func snapshots(conversationID: UUID) -> [Snapshot] {
        lock.lock()
        defer { lock.unlock() }
        return (entries[conversationID] ?? []).map(\.snapshot)
    }

    func snapshot(conversationID: UUID, taskID: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return entries[conversationID]?.first { $0.id == taskID }?.snapshot
    }

    /// Log text from `sinceLine` onward, plus the line to ask for next time.
    ///
    /// Incremental by line rather than by byte offset: a caller polling a growing build log
    /// should not re-read what it has already seen, and a line number is something a model can
    /// carry across turns without arithmetic. Returns nil only when the task is unknown — an
    /// empty log is `("", 0)`, which is a different fact.
    func readLog(conversationID: UUID, taskID: String, sinceLine: Int = 0) -> (text: String, nextLine: Int)? {
        guard let snapshot = snapshot(conversationID: conversationID, taskID: taskID) else { return nil }
        guard let raw = try? String(contentsOf: snapshot.logURL, encoding: .utf8) else { return ("", sinceLine) }

        var lines = raw.components(separatedBy: "\n")
        // A trailing newline yields an empty final component that is not a line.
        if lines.last == "" { lines.removeLast() }

        let start = max(0, min(sinceLine, lines.count))
        return (lines[start...].joined(separator: "\n"), lines.count)
    }

    /// Folds everything written since the last call into the in-memory tail.
    ///
    /// The core of the no-polling design. Seeks to `consumed` and reads ONLY the delta, so cost
    /// tracks what the task just wrote rather than everything it has ever written. Cheap enough
    /// to call on demand — which is what replaced the once-a-second whole-file read.
    ///
    /// `final` flushes a trailing line that carries no newline. A command whose last write is
    /// `printf "done"` has its verdict in exactly that position.
    ///
    /// Silent on a missing or unreadable log: a task whose file was removed keeps the tail it
    /// already had, which is a better answer than emptying it.
    ///
    /// ⚠️ TAKES `lock`, and callers must NOT already hold it — `NSLock` is not recursive, so
    /// draining from inside a locked section deadlocks. `refreshTail` and `complete` both drop the
    /// lock before calling.
    ///
    /// ⚠️ The file read happens INSIDE the lock, deliberately. Every other mutation of an `Entry`
    /// is serialised by it, and tail state is read by `Entry.snapshot` under the same lock — doing
    /// the I/O outside and applying the result after would be a read-modify-write race between a
    /// terminating task and an expanded card refreshing. The cost bought is bounded: a drain reads
    /// the DELTA, which is kilobytes at demand cadence, and `maxDrainBytes` caps the worst case.
    private func drainTail(_ entry: Entry, final: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: entry.logURL) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }

        // The log was replaced or truncated under us — `complete` rewrites it atomically, which
        // swaps the inode. Anything counted before describes a file that is gone.
        if size < entry.consumed {
            entry.consumed = 0
            entry.pending = Data()
            entry.tailLines = []
            entry.totalCharacters = 0
        }

        var start = entry.consumed
        if size > start, size - start > Self.maxDrainBytes {
            // Skip the middle. See `maxDrainBytes` — the alternative is one drain paying for an
            // hour of unwatched output, which is the cost this rewrite exists to remove.
            start = size - Self.maxDrainBytes
            entry.pending = Data()
            logger.notice("[BGPROC] \(entry.id) tail drain skipped \(start - entry.consumed) bytes it had not read. CONSEQUENCE: the in-memory tail jumps a gap; the full log is intact on disk and `readLog` still returns all of it.")
        }

        if start < size {
            try? handle.seek(toOffset: start)
            let delta = (try? handle.readToEnd()) ?? Data()
            entry.consumed = start + UInt64(delta.count)
            entry.pending.append(delta)
        }

        // What can be published: everything up to the last newline. Past `maxPendingBytes` —
        // or on the final drain — publish regardless, or `\r`-only progress output never would.
        var flushable: Data
        if let lastNewline = entry.pending.lastIndex(of: 0x0A) {
            flushable = Data(entry.pending[...lastNewline])
            entry.pending = Data(entry.pending[(lastNewline + 1)...])
            if final, !entry.pending.isEmpty {
                flushable.append(entry.pending)
                entry.pending = Data()
            }
        } else if final || entry.pending.count > Self.maxPendingBytes {
            flushable = entry.pending
            entry.pending = Data()
        } else {
            return
        }
        guard !flushable.isEmpty else { return }

        // Lossy by construction, never nil. Splitting at a newline keeps valid UTF-8 whole; only
        // the force-flush above can cut a character, and one replacement glyph in a progress bar
        // is a better outcome than an unbounded buffer.
        let text = String(decoding: flushable, as: UTF8.self)
        entry.totalCharacters += text.count

        var lines = text.components(separatedBy: "\n")
        // A trailing newline yields an empty final component that is not a line.
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return }

        entry.tailLines.append(contentsOf: lines)
        if entry.tailLines.count > Self.maxTailLines {
            entry.tailLines.removeFirst(entry.tailLines.count - Self.maxTailLines)
        }
    }

    /// Rotates a log that has outgrown `maxLogBytes`: keeps the tail, discards the file, says so.
    ///
    /// ⚠️ ORDER MATTERS. The drain runs FIRST, so the last 200 lines are already in memory before
    /// the bytes holding them are thrown away — the card and `command_output` see no gap at all
    /// across a rotation. Truncating first would discard output that had never been read.
    ///
    /// Rotation rather than "stop at N bytes": a log capped by refusing further writes would go
    /// stale at exactly the moment a long-running task started failing, which is the moment its
    /// output matters most. The RECENT end is the useful end.
    ///
    /// ⚠️ `consumed` is reset to 0 rather than to the marker's length, so the next drain picks the
    /// marker up and it lands IN the tail. A gap that announces itself is a very different object
    /// from a gap.
    ///
    /// ⚠️ Does NOT reset `tailLines` or `totalCharacters`, unlike the truncation branch in
    /// `drainTail`. That branch handles a file REPLACED underneath us, where what came before
    /// described a different file. This is the same file, deliberately shortened: the tail is still
    /// this task's output and the count is still how much it has produced.
    private func enforceLogCap(_ entry: Entry) {
        // `stat`, never a read — this runs once a second per live task.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: entry.logURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size > maxLogBytes
        else { return }

        drainTail(entry)            // takes `lock` itself — must not be held here

        guard truncate(entry.logURL.path, 0) == 0 else {
            logger.error("[BGPROC] \(entry.id) log exceeded \(size / 1_048_576) MB and could NOT be truncated (errno \(errno)). CONSEQUENCE: the file keeps growing unbounded; the in-memory tail is unaffected.")
            return
        }
        let marker = "--- log rotated: \(size / 1_048_576) MB of earlier output discarded; the most recent \(Self.maxTailLines) lines were kept ---\n"
        if let handle = try? FileHandle(forWritingTo: entry.logURL) {
            try? handle.write(contentsOf: Data(marker.utf8))
            try? handle.close()
        }

        lock.lock()
        entry.consumed = 0
        entry.pending = Data()
        lock.unlock()

        logger.notice("[BGPROC] \(entry.id) log rotated at \(size / 1_048_576) MB. CONSEQUENCE: earlier output is gone from disk — the last \(Self.maxTailLines) lines survive in the task's card and in command_output, and the file keeps growing from here.")
    }

    /// Sweeps now, then once every `sweepInterval` for as long as this registry lives. Off the
    /// caller's thread: `shared` is built lazily on first use, which can be a UI event.
    private func startSweeping() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: Self.sweepInterval, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.sweepLogs() }
        lock.lock()
        sweepTimer = timer
        lock.unlock()
        timer.resume()
    }

    /// Applies the retention rules: logs untouched for `logRetention` go, then — if everything left
    /// still exceeds `maxTotalLogBytes` — the oldest go until it fits. Empty conversation folders
    /// are removed after.
    ///
    /// Per FILE, by modification date. See `defaultLogRetention` for why not per directory.
    ///
    /// ⚠️ A log whose command is still RUNNING is never touched, whatever its age or size: deleting
    /// it would cut the card and `command_output` off from a live task, and its bytes are already
    /// bounded by `enforceLogCap`. At launch nothing is running, so this skips nothing then.
    ///
    /// Internal rather than private so tests can run one pass without waiting for the timer.
    func sweepLogs(now: Date = Date()) {
        sweepLock.lock()
        defer { sweepLock.unlock() }
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return }   // no root yet is the normal first-launch case, not a failure

        lock.lock()
        let live = Set(entries.values.flatMap { $0 }.filter { !$0.ended }.map { $0.logURL.standardizedFileURL.path })
            .union(reservedLogPaths)
        lock.unlock()

        struct LogFile { let url: URL; let modified: Date; let bytes: UInt64 }
        var files: [LogFile] = []
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let contents = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            else { continue }
            for url in contents {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true,
                      !live.contains(url.standardizedFileURL.path)
                else { continue }
                let bytes = UInt64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                files.append(LogFile(url: url, modified: values.contentModificationDate ?? .distantPast, bytes: bytes))
            }
        }

        let cutoff = now.addingTimeInterval(-logRetention)
        var expired = 0
        var overCap = 0
        var freed: UInt64 = 0
        var kept: [LogFile] = []
        for file in files {
            if file.modified < cutoff, (try? fileManager.removeItem(at: file.url)) != nil {
                expired += 1
                freed += file.bytes
            } else {
                kept.append(file)
            }
        }

        // Oldest first until the rest fits. Live logs are not in `kept`, so they neither count
        // against the cap nor get removed for it — a running dev server cannot evict itself.
        var total = kept.reduce(UInt64(0)) { $0 + $1.bytes }
        if total > maxTotalLogBytes {
            for file in kept.sorted(by: { $0.modified < $1.modified }) {
                guard total > maxTotalLogBytes else { break }
                if (try? fileManager.removeItem(at: file.url)) != nil {
                    overCap += 1
                    freed += file.bytes
                    total -= file.bytes
                }
            }
        }

        // A conversation folder with nothing left in it is noise in Finder.
        //
        // ⚠️ Only one that has been empty a while. `launch` creates the folder and THEN opens the
        // log in it; a daily sweep landing between those two steps would remove the folder and the
        // open would fail. Removing a file updates the folder's date, so one this sweep just emptied
        // is left for the next pass — a day of an empty folder costs nothing.
        let emptyFolderGrace: TimeInterval = 60 * 60
        for directory in directories {
            guard let remaining = try? fileManager.contentsOfDirectory(atPath: directory.path), remaining.isEmpty,
                  let modified = (try? fileManager.attributesOfItem(atPath: directory.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > emptyFolderGrace
            else { continue }
            try? fileManager.removeItem(at: directory)
        }

        guard expired + overCap > 0 else { return }
        logger.info("[BGPROC] Log sweep removed \(expired) log(s) older than \(Int(logRetention / 86_400)) day(s) and \(overCap) more to stay under \(maxTotalLogBytes / 1_048_576) MB in total, freeing \(freed / 1_048_576) MB. CONSEQUENCE: those commands' output is gone from disk; running tasks' logs were not touched.")
    }

    /// Drains on demand and returns the refreshed record.
    ///
    /// For a surface that is ACTUALLY SHOWING output — an expanded card, the tasks panel. Nothing
    /// calls this on a timer at rest, which is the design: a task nobody is looking at costs no
    /// file I/O at all between its launch and its completion.
    @discardableResult
    func refreshTail(conversationID: UUID, taskID: String) -> Snapshot? {
        lock.lock()
        let entry = entries[conversationID]?.first { $0.id == taskID }
        lock.unlock()
        guard let entry else { return nil }
        drainTail(entry)            // takes `lock` itself — must not be held here
        lock.lock()
        defer { lock.unlock() }
        return entry.snapshot
    }

    // MARK: - Stop

    /// Terminates a task on request. Returns its record, or nil if the id is unknown.
    ///
    /// Terminating something already finished is not an error — it is the normal race when a
    /// build completes while the model is deciding to cancel it. The snapshot says which
    /// happened.
    @discardableResult
    func stop(conversationID: UUID, taskID: String) -> Snapshot? {
        lock.lock()
        let entry = entries[conversationID]?.first { $0.id == taskID }
        lock.unlock()

        guard let entry else { return nil }
        guard entry.process.isRunning else { return entry.snapshot }

        let cancelled = finish(entry, status: .stopped, announce: false)   // announced after the final drain (D-29)
        cancelled?.cancel()

        let descendants = ProcessTree.terminateTree(
            root: entry.process.processIdentifier,
            grace: Self.sigkillGrace,
            isRootRunning: { entry.process.isRunning },
            alsoKnown: remembered(for: entry))

        logger.info("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(taskID) stopped on request: it and \(descendants) descendant process(es) found under it were sent SIGTERM, with SIGKILL to follow in \(Int(Self.sigkillGrace))s for anything still running. CONSEQUENCE: its log keeps whatever it wrote and stays readable via command_output.")
        return entry.snapshot
    }

    // MARK: - Teardown

    /// Every live task, killed. Called from `applicationShouldTerminate` beside
    /// `MCPClientService.disconnectAll()`, and bounded by `quitGrace` so it fits that method's
    /// 3 s watchdog.
    func terminateAll() {
        lock.lock()
        isQuitting = true
        let live = entries.values.flatMap { $0 }.filter { !$0.status.isTerminal }
        lock.unlock()

        guard !live.isEmpty else { return }
        logger.info("[BGPROC] Quit — terminating \(live.count) live background task(s). CONSEQUENCE: they do not survive as launchd orphans; work in flight is lost, which is what quitting means.")

        var roots: [pid_t] = []
        for entry in live where entry.process.isRunning {
            finish(entry, status: .stopped, announce: false)?.cancel()
            roots.append(entry.process.processIdentifier)
        }

        // ⚠️ Two-phase, with the grace paid ONCE. Per-task snapshot→TERM→sleep→KILL would spend
        // `quitGrace` for every task and blow this method's 3 s watchdog on four of them.
        var remembered: Set<ProcessTree.ProcessIdentity> = []
        for entry in live { remembered.formUnion(self.remembered(for: entry)) }
        let signalled = ProcessTree.requestTermination(roots: roots, alsoKnown: remembered)
        Thread.sleep(forTimeInterval: Self.quitGrace)
        ProcessTree.forceTermination(signalled)

        logger.info("[BGPROC] Quit — signalled \(signalled.count) process(es) across \(roots.count) task(s), including descendants.")
    }

    /// Drops a conversation's records and log files — the conversation was deleted, so its logs go
    /// with it rather than waiting out the retention period. Not called on the quit path: a log
    /// the user never read is worth more than the bytes, and the sweep bounds them anyway.
    func discard(conversationID: UUID) {
        lock.lock()
        let removed = entries.removeValue(forKey: conversationID) ?? []
        counters.removeValue(forKey: conversationID)
        lock.unlock()

        for entry in removed where entry.process.isRunning {
            // ⚠️ D-29: the verdict FIRST. Without it the termination handler recorded the kill as
            // `.exited(15)`, and a foreground call still waiting on this command reported "Exit
            // code: 15" as the command's own result. Not announced: the conversation is gone.
            finish(entry, status: .stopped, announce: false)?.cancel()
            ProcessTree.terminateTree(root: entry.process.processIdentifier,
                                      grace: Self.sigkillGrace,
                                      isRootRunning: { entry.process.isRunning },
                                      alsoKnown: remembered(for: entry))
        }
        let directory = rootDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Clears all terminal (finished, timed out, or stopped) tasks for this conversation from the
    /// list.
    ///
    /// ⚠️ The LOG FILES STAY (2026-09-24). Clearing tidies the task list; it is not a request to
    /// destroy output, and the logs are kept for `defaultLogRetention` precisely so a finished
    /// command can still be looked at later. The sweep removes them on schedule.
    func clearFinished(conversationID: UUID) {
        lock.lock()
        guard var list = entries[conversationID] else {
            lock.unlock()
            return
        }
        let finished = list.filter { $0.status.isTerminal }
        list.removeAll { $0.status.isTerminal }
        entries[conversationID] = list
        lock.unlock()

        logger.info("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — cleared \(finished.count) finished task(s) from the list. CONSEQUENCE: their cards are gone; their log files stay on disk until the retention sweep removes them.")
        announce(taskID: "", conversationID: conversationID)
    }
}
