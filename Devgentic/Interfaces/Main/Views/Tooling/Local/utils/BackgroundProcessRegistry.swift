// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundProcessRegistry.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "BackgroundProcessRegistry")

/// Notification names for background-task events.
extension Notification.Name {
    // Why: a notification, not a direct call: this registry is lock-based and off the MainActor, its observer is `@MainActor`
    /// A background task was launched, or its status changed. Carries `taskID` and `conversationID`.
    /// Observed by `BackgroundTaskObserver`, which owns the timeline row.
    static let backgroundTaskChanged = Notification.Name("backgroundTaskChanged")
}

enum BackgroundTaskNotificationKey {
    static let taskID = "taskID"
    static let conversationID = "conversationID"
}

/// Owns every process a conversation started and did not wait for, so each can be named, read, stopped, and cleaned up at quit.
/// Also enforces the `timeout_seconds` bound on those processes.
final class BackgroundProcessRegistry: @unchecked Sendable {

    /// Process-wide instance. Tests construct their own against a scratch directory rather than
    /// sharing this one — a registry that outlives a test would leak children into the next.
    static let shared = BackgroundProcessRegistry(rootDirectory: defaultRootDirectory)

    // Why: not `$TMPDIR`: macOS cleans it on its own schedule, so a retention period could never be honoured there
    /// Where command logs live: `~/Library/Application Support/Devgentic/Logs/Commands/<conversation>/`.
    /// A test host is redirected to a temp directory so the suite never writes into the real log folder.
    static var defaultRootDirectory: URL {
        if TestHost.isRunning {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("devgentic-command-logs-testhost", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Devgentic/Logs/Commands", isDirectory: true)
    }

    // MARK: - Types

    /// `timedOut` and `stopped` are separate from `exited`: a killed child still has a termination status,
    /// and a signal number is not a chosen exit code. The first terminal status wins; see `finish`.
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

    /// The read model: everything a caller outside this type may see, with no `Process` or file handle, so it is `Sendable`.
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
        /// The last `maxTailLines` lines of the log, held in memory by the registry and fed by `drainTail`,
        /// which reads only the bytes added since the last drain.
        let tail: String
        // Why: kept on the record because the task outlives the turn that started it, and the intent must live with the task
        /// Whether the caller asked to be told when this finishes.
        let notifyOnCompletion: Bool
        /// Characters the log holds in total, so a reader can say how much is not shown.
        /// Accumulated per delta, never measured; characters not bytes, matching `outputTail.count` in `BackgroundTaskCard`.
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

    // Why: a per-task serial grace would blow the budget on a few tasks and get the app killed mid-teardown
    /// One short grace shared by every task, since quit teardown runs inside `applicationShouldTerminate`'s 3 s watchdog.
    private static let quitGrace: TimeInterval = 0.4

    /// How often live tasks' descendants are re-captured. The window this leaves is the window in
    /// which a child can be forked AND orphaned without ever being seen — a second is short
    /// against a build, and the walk is one `sysctl` shared by every live task.
    private static let descendantRefreshInterval: TimeInterval = 1.0

    /// Lines the in-memory tail keeps per task, sized for the model reading `get_task_output`, not the card.
    /// A compile error with context notes or a backtrace runs well past twenty lines.
    private static let maxTailLines = 200

    /// Ceiling on a single drain: past this, the drain skips to the last `maxDrainBytes`;
    /// the whole file stays on disk for `readLog`.
    private static let maxDrainBytes: UInt64 = 1 << 20

    // Why: progress output redraws with carriage returns and can emit megabytes without `\n`, growing `pending` unbounded
    /// A run of bytes carrying no newline is force-flushed past this.
    private static let maxPendingBytes = 64 * 1024

    /// Ceiling on one task's log file before it is rotated. Bounded here instead of killing the task,
    /// since a chatty build is not misbehaving. 32 MB keeps real builds whole while capping a runaway.
    static let defaultMaxLogBytes: UInt64 = 32 * 1024 * 1024

    /// How long a log is kept after it was last written: 7 days.
    /// Measured per file from its modification date, not per conversation directory, whose date moves only on add or remove.
    static let defaultLogRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Ceiling on all command logs together: 1 GB. The age limit alone does not bound disk use;
    /// past this, the oldest logs go first.
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

        // Why: once the shell exits its children are re-parented to launchd and a kill-time walk finds nothing
        /// Descendants seen while this task's shell was alive, kept as identities rather than pids; see `ProcessTree`.
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

    /// `NSLock` rather than an actor: `terminationHandler` and the watchdog fire on GCD queues with no async context.
    private let lock = NSLock()
    private var entries: [UUID: [Entry]] = [:]
    private var counters: [UUID: Int] = [:]
    // Why: a quit-time `.stopped` could wake an unattended run while the app is quitting
    /// Set by `terminateAll`; from then on nothing is announced.
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

    /// Instance, not static, so tests can use small values; `shared` and production callers take the defaults.
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

    /// Starts `command` detached, bounds it at `timeout`, and returns its record; the caller gets a task id, never a pid.
    /// `foreground` marks a caller that waits through `waitUntilEnded`; it writes its log live like a background task.
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

        // Why: without O_APPEND the child keeps its own offset, and truncation leaves a sparse file of NULs
        // The log opens with O_APPEND, so every write goes to the current end and `enforceLogCap` can truncate under the child,
        // and with O_EXCL so a log is always a new file; the path is reserved before it exists (`reservedLogPaths`).
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
            // Why: draining after the announcement races the observer and can leave the terminal row short of the verdict
            // Final drain runs after `close()`, so the child's last writes have landed, and before `finish`, which announces.
            self.drainTail(entry, final: true)
            let settledEarlier = self.isSettled(entry)
            let cancelled = self.finish(entry, status: .exited(code: finished.terminationStatus))
            cancelled?.cancel()
            // A stop or timeout sets the verdict before the kill lands without announcing; this announces once the final drain ran.
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
            logger.info("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(id) launched (pid \(process.processIdentifier)), bounded at \(Int(timeout))s, log: \(logURL.path). CONSEQUENCE: output is collectable via get_task_output and the task is killed at its bound whether or not the model checks back.")
        }
        announce(taskID: id, conversationID: conversationID)
        return snapshot
    }

    /// Suspends until the task's shell has exited and its log is complete; returns the final record, or nil if unknown.
    /// Waits for the process to exit, not just a terminal status, so the last lines written while signalled are read.
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
    /// The timestamp keeps files unique across launches and sorted; the slug is the task name, or the command.
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

    // Why: the `isRunning` guards are the pid-reuse protection: capture the pid after the first and re-check before SIGKILL
    /// Arms the execution bound for a background task, with the same shape as `ProcessRunner.execute`.
    private func arm(_ entry: Entry, timeout: TimeInterval, conversationID: UUID) {
        guard timeout > 0 else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard entry.process.isRunning else { return }
            // Status FIRST, so "we killed it" wins the race against the `terminationHandler`
            // that this very `terminate()` is about to trigger.
            _ = self.finish(entry, status: .timedOut, announce: false)

            // Why: killing the root re-parents descendants to launchd and loses the chain that identifies them
            // Terminates the whole job tree, not just the shell; `ProcessTree` snapshots descendants before signalling.
            let descendants = ProcessTree.terminateTree(
                root: entry.process.processIdentifier,
                grace: Self.sigkillGrace,
                isRootRunning: { entry.process.isRunning },
                alsoKnown: self.remembered(for: entry))

            // Logs "signalled", not "killed": SIGTERM is sent and the SIGKILL escalation is still pending.
            // The count is what the snapshot found.
            logger.notice("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(entry.id) reached its \(Int(timeout))s bound: it and \(descendants) descendant process(es) found under it were sent SIGTERM, with SIGKILL to follow in \(Int(Self.sigkillGrace))s for anything still running. CONSEQUENCE: whatever it had written to its log is kept; anything it would have produced later is lost. A process forked after the tree was snapshotted is not in that count and can survive.")
        }

        lock.lock()
        // The command may already have exited, so no watchdog is recorded on a finished task.
        let alreadyDone = entry.status.isTerminal
        if !alreadyDone { entry.watchdog = item }
        lock.unlock()

        guard !alreadyDone else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: item)
    }

    // Why: a timeout kill triggers `terminationHandler`, which would overwrite `.timedOut` with `.exited(15)`
    /// Records a terminal status, first one wins, and hands back the watchdog to cancel.
    /// announce: false when the process is about to be killed; the termination handler announces after the final drain.
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

        // Why: posting while holding the lock across that boundary deadlocks against the observer
        // Announces outside the lock: `announce` hops to the MainActor and the observer reads the registry on arrival.
        if accepted, shouldAnnounce { announce(taskID: entry.id, conversationID: conversationID) }
        return watchdog
    }

    /// Whether a terminal status is already recorded.
    private func isSettled(_ entry: Entry) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entry.status.isTerminal
    }

    /// Announces `entry`'s ending unless its conversation was discarded; a wake would start a run in a deleted conversation.
    private func announceIfStillRegistered(_ entry: Entry) {
        lock.lock()
        let registered = entries[entry.conversationID]?.contains { $0 === entry } ?? false
        lock.unlock()
        guard registered else { return }
        announce(taskID: entry.id, conversationID: entry.conversationID)
    }

    // Why: must stay `async`: posting waits for a `.main` observer and would delay timeout kills on a busy main thread
    /// Tells whoever renders this task that something changed. Fire-and-forget: a task with no observer is not an error.
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
        // Short because a small model echoes it back; scoped per conversation, with one counter for both prefixes
        // so `fg_2` and `bg_2` never coexist and the number alone orders the commands.
        return "\(foreground ? "fg" : "bg")_\(next)"
    }

    // Foreground runs use `launch(foreground: true)` and `waitUntilEnded`, with the same live interleaved log.

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

    /// One pass: for every live task, folds this moment's tree into what is already known, pruned to what is still alive.
    /// A descendant whose chain broke is still alive and stays.
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
            // Why: a second timer would return the periodic cost the tail design removed; a `stat` is not a read
            // The log-cap check piggybacks on this tick, which runs once a second while anything is live and stops itself when idle.
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

    /// Log text from `sinceLine` onward, plus the line to ask for next time, so a poller never re-reads what it has seen.
    /// Returns nil only when the task is unknown; an empty log is `("", 0)`.
    func readLog(conversationID: UUID, taskID: String, sinceLine: Int = 0) -> (text: String, nextLine: Int)? {
        guard let snapshot = snapshot(conversationID: conversationID, taskID: taskID) else { return nil }
        guard let raw = try? String(contentsOf: snapshot.logURL, encoding: .utf8) else { return ("", sinceLine) }

        var lines = raw.components(separatedBy: "\n")
        // A trailing newline yields an empty final component that is not a line.
        if lines.last == "" { lines.removeLast() }

        let start = max(0, min(sinceLine, lines.count))
        return (lines[start...].joined(separator: "\n"), lines.count)
    }

    // Why: takes `lock`, which is not recursive, so callers must not hold it; the read stays inside the lock to avoid a race
    /// Folds everything written since the last call into the in-memory tail by reading only the delta from `consumed`.
    /// `final` flushes a trailing line with no newline. A missing or unreadable log leaves the existing tail intact.
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

        // Lossy by construction, never nil: splitting at a newline keeps UTF-8 whole; only the force-flush can cut a character.
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

    // Why: drain first so the last lines are in memory before truncation; `consumed` resets to 0 so the marker lands in the tail
    /// Rotates a log that has outgrown `maxLogBytes`: keeps the tail, discards the file, and says so.
    /// Keeps `tailLines` and `totalCharacters`, since this is the same file deliberately shortened.
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

        logger.notice("[BGPROC] \(entry.id) log rotated at \(size / 1_048_576) MB. CONSEQUENCE: earlier output is gone from disk — the last \(Self.maxTailLines) lines survive in the task's card and in get_task_output, and the file keeps growing from here.")
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

    /// Applies retention per file by modification date, then removes the oldest logs until under `maxTotalLogBytes`;
    /// a log whose command is still running is never touched. Internal so tests can run one pass.
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

        // Why: `launch` creates the folder and then opens the log, so removing a fresh empty folder would fail that open
        // Removes conversation folders with nothing left in them, but only ones empty for a while.
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

    /// Drains on demand and returns the refreshed record, for a surface that is actually showing output.
    /// Nothing calls this on a timer, so an unwatched task costs no file I/O.
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

    /// Terminates a task on request; returns its record, or nil if the id is unknown.
    /// Terminating a finished task is not an error, and the snapshot says which happened.
    @discardableResult
    func stop(conversationID: UUID, taskID: String) -> Snapshot? {
        lock.lock()
        let entry = entries[conversationID]?.first { $0.id == taskID }
        lock.unlock()

        guard let entry else { return nil }
        guard entry.process.isRunning else { return entry.snapshot }

        let cancelled = finish(entry, status: .stopped, announce: false)
        cancelled?.cancel()

        let descendants = ProcessTree.terminateTree(
            root: entry.process.processIdentifier,
            grace: Self.sigkillGrace,
            isRootRunning: { entry.process.isRunning },
            alsoKnown: remembered(for: entry))

        logger.info("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(taskID) stopped on request: it and \(descendants) descendant process(es) found under it were sent SIGTERM, with SIGKILL to follow in \(Int(Self.sigkillGrace))s for anything still running. CONSEQUENCE: its log keeps whatever it wrote and stays readable via get_task_output.")
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

        // Why: per-task snapshot, TERM, sleep, KILL would spend `quitGrace` per task and blow the 3 s quit watchdog
        // Two-phase teardown with the grace paid once.
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
            // Why: otherwise the termination handler records the kill as `.exited(15)` and a waiting foreground call reports it
            // The verdict is set first and not announced (the conversation is gone).
            finish(entry, status: .stopped, announce: false)?.cancel()
            ProcessTree.terminateTree(root: entry.process.processIdentifier,
                                      grace: Self.sigkillGrace,
                                      isRootRunning: { entry.process.isRunning },
                                      alsoKnown: remembered(for: entry))
        }
        let directory = rootDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Clears all terminal (finished, timed out or stopped) tasks for this conversation from the list.
    /// The log files stay until the retention sweep removes them.
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
