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
    static let shared = BackgroundProcessRegistry(
        rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("devgentic-bg", isDirectory: true))

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

    /// How old a log directory must be before a launch-time sweep removes it.
    ///
    /// Not a correctness requirement — everything under the root IS orphaned at launch (see
    /// `sweepOrphanedLogs`). Deliberate conservatism: a crash-and-relaunch within the day keeps its
    /// files readable on disk, at the cost of one extra day of them.
    static let defaultOrphanedLogMaxAge: TimeInterval = 24 * 60 * 60

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
    private var refreshTimer: DispatchSourceTimer?
    private let rootDirectory: URL

    /// ⚠️ INSTANCE, not static, purely so tests can use small values. Writing 32 MB to prove a
    /// 32 MB cap works would put a multi-second disk write in the suite for no extra confidence —
    /// the ROTATION is the behaviour under test, and the threshold is a number. `shared` and every
    /// production caller take the defaults, which `testTheShippedCapsAreTheOnesProductionUses` pins
    /// so a convenient test value can never quietly become the shipped one.
    private let maxLogBytes: UInt64
    private let orphanedLogMaxAge: TimeInterval

    init(rootDirectory: URL,
         maxLogBytes: UInt64 = BackgroundProcessRegistry.defaultMaxLogBytes,
         orphanedLogMaxAge: TimeInterval = BackgroundProcessRegistry.defaultOrphanedLogMaxAge) {
        self.rootDirectory = rootDirectory
        self.maxLogBytes = maxLogBytes
        self.orphanedLogMaxAge = orphanedLogMaxAge
        // Off the caller's thread: `shared` is built lazily on first use, which can be a UI event.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.sweepOrphanedLogs() }
    }

    // MARK: - Launch

    /// Starts `command` detached, bounds it at `timeout`, and returns its record.
    ///
    /// The caller gets a task id, never a pid. That is not decoration: a pid is the thing that
    /// cannot be safely handed back (see the type comment).
    @discardableResult
    func launch(command: String,
                workingDirectory: String,
                timeout: TimeInterval,
                conversationID: UUID,
                name: String? = nil,
                notifyOnCompletion: Bool = false) throws -> Snapshot {

        let directory = rootDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = nextID(for: conversationID)
        let logURL = directory.appendingPathComponent("\(id).log")

        // ⚠️ O_APPEND IS WHAT MAKES ROTATION POSSIBLE, and it is not incidental. `FileHandle(
        // forWritingTo:)` opens WITHOUT it, so the child carries its own file offset — truncating
        // the file under it would leave that offset untouched and the next write would land at the
        // old position, producing a SPARSE file whose head reads back as megabytes of NUL. With
        // O_APPEND every write goes to the current end atomically, so `enforceLogCap` can truncate
        // to zero and the child simply carries on from there.
        //
        // It also strengthens the property the single shared handle exists for: two streams
        // appending atomically to one description interleave in true chronological order.
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
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
                          startedAt: Date(), logURL: logURL, process: process,
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
            let cancelled = self.finish(entry, status: .exited(code: finished.terminationStatus))
            cancelled?.cancel()
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

        logger.info("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(id) launched (pid \(process.processIdentifier)), bounded at \(Int(timeout))s, log: \(logURL.path). CONSEQUENCE: output is collectable via command_output and the task is killed at its bound whether or not the model checks back.")
        announce(taskID: id, conversationID: conversationID)
        return snapshot
    }

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
            _ = self.finish(entry, status: .timedOut)

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
    @discardableResult
    private func finish(_ entry: Entry, status: Status) -> DispatchWorkItem? {
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
        if accepted { announce(taskID: entry.id, conversationID: conversationID) }
        return watchdog
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
        let payload: [String: Any] = [
            BackgroundTaskNotificationKey.taskID: taskID,
            BackgroundTaskNotificationKey.conversationID: conversationID,
        ]
        DispatchQueue.global(qos: .utility).async {
            NotificationCenter.default.post(name: .backgroundTaskChanged, object: nil, userInfo: payload)
        }
    }

    private func nextID(for conversationID: UUID) -> String {
        lock.lock()
        defer { lock.unlock() }
        let next = (counters[conversationID] ?? 0) + 1
        counters[conversationID] = next
        // Short because a small model has to echo it back. Scoped per conversation, so `bg_1`
        // in two conversations is not a collision — every lookup takes the conversation too.
        return "bg_\(next)"
    }

    // MARK: - Adopting a foreground run

    /// Registers a process the caller is ALREADY running and waiting on, so it gets the same
    /// lifecycle the background path has: a card, a stop control, and quit-time teardown.
    ///
    /// ⚠️ This does NOT arm a watchdog and does NOT set a `terminationHandler`. `ProcessRunner`
    /// owns both for a foreground run — it installs its own handler and the bound is its
    /// `timeout:` argument — and taking either over here would break the drain it depends on.
    /// The caller reports the outcome with `complete(…)`.
    ///
    /// ⚠️ NO LIVE OUTPUT. A foreground run's output goes through `ProcessRunner`'s pipes, and
    /// mirroring it here would put file I/O on the drain queue — the one place that must never
    /// block, because back-pressure there is the ~64 KB pipe wedge that type exists to prevent.
    /// The log is written once, from the finished result, in `complete(…)`.
    func adopt(process: Process,
               command: String,
               workingDirectory: String,
               conversationID: UUID,
               name: String? = nil) -> Snapshot? {
        let directory = rootDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return nil }

        let id = nextID(for: conversationID)
        let logURL = directory.appendingPathComponent("\(id).log")
        let entry = Entry(id: id, conversationID: conversationID, name: name, command: command,
                          workingDirectory: workingDirectory,
                          startedAt: Date(), logURL: logURL, process: process)

        lock.lock()
        entries[conversationID, default: []].append(entry)
        let snapshot = entry.snapshot
        lock.unlock()

        startDescendantRefreshIfNeeded()
        announce(taskID: id, conversationID: conversationID)
        logger.info("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(id) adopted (foreground, pid \(process.processIdentifier)). CONSEQUENCE: it is stoppable and is killed at quit, which a foreground command previously was not — it was orphaned to launchd exactly as background commands used to be.")
        return snapshot
    }

    /// Records a foreground run's outcome and its output. Paired with `adopt`.
    func complete(conversationID: UUID, taskID: String, output: String, status: Status) {
        lock.lock()
        let entry = entries[conversationID]?.first { $0.id == taskID }
        lock.unlock()
        guard let entry else { return }

        // Written once, from the finished result — see `adopt`.
        try? output.data(using: .utf8)?.write(to: entry.logURL, options: .atomic)
        // Through the same drain as the background path rather than assigning the string we
        // already hold: one implementation of "what is the tail" means one set of line-splitting,
        // bounding and counting rules, tested once. A foreground log is bounded by
        // `ProcessRunner` before it ever gets here, so the one-shot read is small.
        drainTail(entry, final: true)
        finish(entry, status: status)?.cancel()
    }

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

    /// Removes log directories left behind by PREVIOUS runs of the app.
    ///
    /// ⚠️ EVERY directory under the root is orphaned at launch, by construction: entries live only
    /// in memory, and `terminateAll` kills every task at quit, so nothing on disk here belongs to a
    /// live process or is reachable from any surface — `BackgroundTasksListView` lists registry
    /// entries, and after a restart there are none.
    ///
    /// They were previously removed ONLY by `discard`, which fires on conversation deletion. A user
    /// who never deletes a conversation accumulated one directory per conversation that ever ran a
    /// command, permanently. That is the second half of "uncapped logs", and the quieter half: the
    /// per-file cap does nothing about a thousand small files.
    private func sweepOrphanedLogs() {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return }   // no root yet is the normal first-launch case, not a failure

        let cutoff = Date().addingTimeInterval(-orphanedLogMaxAge)
        var removed = 0
        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true,
                  let modified = values?.contentModificationDate,
                  modified < cutoff
            else { continue }
            if (try? fileManager.removeItem(at: directory)) != nil { removed += 1 }
        }
        guard removed > 0 else { return }
        logger.info("[BGPROC] Swept \(removed) log director(ies) from earlier runs, older than \(Int(orphanedLogMaxAge / 3600))h. CONSEQUENCE: disk reclaimed; nothing live was touched — every directory here predates this process, which kills all its own tasks at quit.")
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

        let cancelled = finish(entry, status: .stopped)
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
        let live = entries.values.flatMap { $0 }.filter { !$0.status.isTerminal }
        lock.unlock()

        guard !live.isEmpty else { return }
        logger.info("[BGPROC] Quit — terminating \(live.count) live background task(s). CONSEQUENCE: they do not survive as launchd orphans; work in flight is lost, which is what quitting means.")

        var roots: [pid_t] = []
        for entry in live where entry.process.isRunning {
            finish(entry, status: .stopped)?.cancel()
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

    /// Drops a conversation's records and log files. Not called on the quit path — the temp
    /// directory outlives a crash, and a log the user never read is worth more than the bytes.
    func discard(conversationID: UUID) {
        lock.lock()
        let removed = entries.removeValue(forKey: conversationID) ?? []
        counters.removeValue(forKey: conversationID)
        lock.unlock()

        for entry in removed where entry.process.isRunning {
            ProcessTree.terminateTree(root: entry.process.processIdentifier,
                                      grace: Self.sigkillGrace,
                                      isRootRunning: { entry.process.isRunning },
                                      alsoKnown: remembered(for: entry))
        }
        let directory = rootDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Clears all terminal (finished, timed out, or stopped) tasks for this conversation,
    /// removing their records and deleting their log files.
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

        for entry in finished {
            try? FileManager.default.removeItem(at: entry.logURL)
        }
        announce(taskID: "", conversationID: conversationID)
    }
}
