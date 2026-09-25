// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskObserver.swift
//  Devgentic
//
//  Owns the `.backgroundTask` timeline row: creates it when a task launches, keeps its output and
//  status current while the task runs, and finalises it when the task ends.
//
//  ── Why this is not part of the stream ──────────────────────────────────────────────────
//
//  Every other timeline row is written by `ActiveStreamManager` from an `AgentStreamEvent` as the
//  run produces it. A background task cannot work that way: it OUTLIVES the stream. The device
//  test on 2026-09-21 is the whole argument — the model started a build, said it would "check
//  periodically and notify you", then emitted `final_answer`. The stream closed. The loop ended.
//  Any update arriving afterwards has no stream to arrive on.
//
//  So this observer holds the message directly and writes to it after the run is over.
//
//  ⚠️ THE MESSAGE IS CAPTURED AT LAUNCH, and it has to be. `ActiveStreamManager.activeStreams`
//  holds only STREAMING messages and `finalizeMessage` removes them, so by the time a build
//  finishes there is nothing left to look the message up by. At launch the turn is still live, so
//  the message is there — that is the one moment it can be found.
//
//  The reference is WEAK. A conversation the user closed should not be kept alive by a build, and
//  dropping LIVE updates for a message nobody is looking at is the correct outcome, not a failure.
//
//  ⚠️⚠️ THE ENDING IS THE EXCEPTION — IT IS WRITTEN TO DISK. Until 2026-09-23 it only reached the
//  in-memory message, and nothing saved that message again: the turn that launched the task had
//  finished streaming long before the task did, so its last flush carried `running`. The row came
//  back `running` on the next load, `reconcile` papered over it while the process still remembered
//  the task, and after a relaunch it read "ended when the app restarted" — for a build that had
//  exited 0 and been reported. Found on the first device run of the wake flow, where a task always
//  outlives its turn. See `persistEnding`.
//
//  ── Why there is no timer ───────────────────────────────────────────────────────────────
//
//  There used to be one, at 1 Hz, and it did two jobs. Both were wrong.
//
//  It watched for COMPLETION, which was already redundant: every terminal transition in the
//  registry — natural exit, timeout kill, `stop` — runs through `finish`, which announces. The
//  `Status` enum has no non-terminal transitions, so status changes exactly twice in a task's
//  life and BOTH are pushed. The timer was re-discovering a fact it had already been told.
//
//  And it re-read the WHOLE log file to refresh `outputTail`, on the MainActor, once a second,
//  per live task — then took `String.count` (an O(n) grapheme walk) of the result twice. For the
//  dev server that `start_background_task` explicitly recommends, that is tens of MB a second on
//  the main thread.
//
//  Live output is now the registry's bounded in-memory tail, and a surface that is actually
//  SHOWING output drives its own refresh while it is on screen (`BackgroundProcessRegistry
//  .refreshTail`). A task nobody is looking at costs no file I/O between launch and completion.
//

import Foundation
import Combine
import os

private let logger = DGLogger(category: "BackgroundTaskObserver")

@MainActor
final class BackgroundTaskObserver {

    static let shared = BackgroundTaskObserver()

    private final class Tracked {
        weak var message: ChatMessage?
        /// Kept STRONGLY, unlike the message: the ending must still be written to disk after the
        /// conversation is unloaded and `message` has gone nil.
        let messageID: UUID
        let eventID: UUID
        let conversationID: UUID
        init(message: ChatMessage, eventID: UUID, conversationID: UUID) {
            self.message = message
            self.messageID = message.id
            self.eventID = eventID
            self.conversationID = conversationID
        }
    }

    private var tracked: [String: Tracked] = [:]
    private var observation: NSObjectProtocol?
    private let registry: BackgroundProcessRegistry
    private let persistence: any ChatPersistenceProtocol

    /// The ending's in-flight disk writes, exposed so a test can await them instead of sleeping.
    private(set) var pendingWrites: [Task<Void, Never>] = []

    /// How the observer finds the message a conversation is currently streaming into.
    ///
    /// Injected rather than reached for: `ActiveStreamManager` is built in `DevgenticApp` and
    /// passed down, with no singleton to grab. A closure also means this type is testable without
    /// constructing a stream manager, a profile store and a live backend.
    private var liveMessage: (@MainActor (UUID) -> ChatMessage?)?

    /// - Parameter persistence: `nil` means the app's store. Resolved in the body rather than as a
    ///   default argument so the main-actor singleton is only touched on the main actor.
    init(registry: BackgroundProcessRegistry = .shared, persistence: (any ChatPersistenceProtocol)? = nil) {
        self.registry = registry
        self.persistence = persistence ?? ChatPersistenceStore.shared
    }

    /// Begins observing. Idempotent; called once from app launch, where the stream manager exists.
    func start(liveMessage: @escaping @MainActor (UUID) -> ChatMessage?) {
        self.liveMessage = liveMessage
        start()
    }

    /// Begins observing. Idempotent; called once from app launch.
    func start() {
        guard observation == nil else { return }
        observation = NotificationCenter.default.addObserver(
            forName: .backgroundTaskChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard
                let taskID = note.userInfo?[BackgroundTaskNotificationKey.taskID] as? String,
                let conversationID = note.userInfo?[BackgroundTaskNotificationKey.conversationID] as? UUID
            else { return }
            MainActor.assumeIsolated { self?.handle(taskID: taskID, conversationID: conversationID) }
        }
        logger.info("[BGTASK] Observer armed. CONSEQUENCE: background tasks get a live timeline row; without this they would start, run and finish with nothing on screen after the launch line.")
    }

    // MARK: - Reconciliation after a load

    /// Corrects `running` rows that came off DISK but are not running.
    ///
    /// ⚠️ A persisted row keeps whatever status was last flushed, and the card renders `.running`
    /// as live: a spinner, a ticking clock, and an auto-expanded output pane. After a relaunch that
    /// is always a lie — `terminateAll` kills every task inside `applicationShouldTerminate`, and
    /// this registry does not survive the process — so a build from yesterday showed as "running"
    /// with an elapsed time counting up from the moment it started.
    ///
    /// THREE outcomes, and the middle one is why this is not a blanket "running → interrupted":
    ///
    /// 1. **The registry knows it and it is still running** — leave it. Switching conversations away
    ///    and back re-reads the blob while the task is genuinely live; rewriting that row would
    ///    declare a running build dead. (`case .running: continue` in the switch below — see the
    ///    note there for why there is no separate guard.)
    /// 2. **The registry knows it and it FINISHED** — adopt the real outcome, not `.interrupted`.
    ///    ⚠️ This case is not exotic. `Tracked.message` is a WEAK reference (deliberately — a
    ///    conversation the user closed must not be kept alive by a build), so unloading a
    ///    conversation mid-task drops the tracking, and the ending never reaches the row. The
    ///    registry has the truth; the row just never heard it.
    /// 3. **The registry has never heard of it** — `.interrupted`. The process is gone.
    ///
    /// Returns how many rows were corrected, which is what the caller logs.
    @discardableResult
    static func reconcile(_ messages: [ChatMessage],
                          registry: BackgroundProcessRegistry = .shared) -> Int {
        reconciledMessages(messages, registry: registry).rows
    }

    /// `reconcile`, also returning the MESSAGES it changed — the ones the caller must save.
    ///
    /// ⚠️⚠️ THE CALLER MUST PERSIST `messages`. This used to deliberately not save, reasoning that
    /// recomputing on every load was cheaper than a write. It was not only a cost trade: outcome (2)
    /// is information that exists ONLY while this process remembers the task. Left unsaved, the next
    /// relaunch finds the row still `running`, the registry empty, and turns a task that exited 0
    /// into outcome (3), "interrupted". Saving is also self-limiting — a corrected row is no longer
    /// `running`, so the same row is never corrected, or written, twice.
    static func reconciledMessages(_ messages: [ChatMessage],
                                   registry: BackgroundProcessRegistry = .shared) -> (rows: Int, messages: [ChatMessage]) {
        var corrected = 0
        var changed: [ChatMessage] = []
        for message in messages {
            let before = corrected
            for (index, event) in message.timelineEvents.enumerated() {
                guard case .backgroundTask(let data) = event, data.status == .running else { continue }
                let snapshot = registry.snapshot(conversationID: message.conversationId, taskID: data.taskID)

                var updated = data
                if let snapshot {
                    switch snapshot.status {
                    // (1) ⚠️ GENUINELY LIVE, and this `continue` is the ONLY thing protecting it.
                    //
                    // There used to be an `if let snapshot, !snapshot.status.isTerminal { continue }`
                    // guard above as well, with a comment here calling this case "unreachable". Both
                    // halves of that were wrong: `continue` inside a `switch` continues the enclosing
                    // LOOP, so the two were exactly redundant — mutation removed the guard and every
                    // test stayed green, because this line had been doing the work all along. Two
                    // mechanisms for one decision means neither can be tested, so the guard is gone.
                    case .running:          continue
                    // (2) the registry has the real ending
                    case .exited(let code): updated.status = .exited; updated.exitCode = code
                    case .timedOut:         updated.status = .timedOut
                    case .stopped:          updated.status = .stopped
                    }
                    updated.finishedAt = snapshot.finishedAt
                    updated.outputTail = snapshot.tail.count > BackgroundTaskData.maxOutputTail
                        ? String(snapshot.tail.suffix(BackgroundTaskData.maxOutputTail))
                        : snapshot.tail
                    updated.logCharacterCount = snapshot.logCharacterCount
                    logger.notice("[BGTASK] Reconciled row for \(data.taskID) in conversation \(message.conversationId.uuidString.prefix(8)) from 'running' to its REAL outcome (\(snapshot.status.label)). CONSEQUENCE: the task finished while its conversation was unloaded — the observer's message reference is weak, so the ending never reached the row — and the row now shows what actually happened rather than a spinner.")
                } else {
                    // (3) nothing knows this task any more.
                    //
                    // ⚠️ `finishedAt` is left NIL on purpose. We do not know when it died, and the
                    // card's `.interrupted` label is written to claim no duration ("ended when the
                    // app restarted") precisely so nothing has to invent one. Stamping `now` would
                    // report an overnight quit as a task that ran for fourteen hours.
                    updated.status = .interrupted
                    logger.notice("[BGTASK] Row for \(data.taskID) in conversation \(message.conversationId.uuidString.prefix(8)) loaded as 'running' but the registry has never heard of it — marked INTERRUPTED. CONSEQUENCE: it no longer renders as a live task with a clock counting up from whenever it started; quit kills every task, so a persisted 'running' row is always stale.")
                }
                message.timelineEvents[index] = .backgroundTask(updated)
                corrected += 1
            }
            if corrected > before { changed.append(message) }
        }
        return (corrected, changed)
    }

    // MARK: - Arrival

    private func handle(taskID: String, conversationID: UUID) {
        guard let snapshot = registry.snapshot(conversationID: conversationID, taskID: taskID) else { return }

        if let existing = tracked[taskID] {
            apply(snapshot, to: existing)
        } else {
            adopt(snapshot, conversationID: conversationID)
        }
    }

    /// First sight of a task: find the message this run is streaming into and add its row.
    ///
    /// ⚠️ This is the ONLY moment the message is findable (see the type comment). A task whose
    /// conversation has no live stream — a workflow node, a scheduled run — gets no row, which is
    /// a gap rather than a defect: the registry still bounds and kills it, and `get_task_output`
    /// still answers. Logged so the absence is visible rather than silent.
    private func adopt(_ snapshot: BackgroundProcessRegistry.Snapshot, conversationID: UUID) {
        guard let message = liveMessage?(conversationID) else {
            logger.notice("[BGTASK] \(snapshot.id) started in conversation \(conversationID.uuidString.prefix(8)) with no live stream to attach a row to. CONSEQUENCE: no timeline card for this task — it still runs, is still bounded, and get_task_output still reports it, but nobody watching the conversation will see it.")
            return
        }

        let data = makeData(from: snapshot, eventID: UUID())
        message.timelineEvents.append(.backgroundTask(data))
        // A task first seen ALREADY ENDED (it finished before its launch notice was handled) gets
        // its final row and nothing else: no update will follow, so tracking it would only leak an
        // entry. No save either — adoption needs a STREAMING message, and that stream's own final
        // flush carries this row.
        guard !snapshot.status.isTerminal else {
            logger.info("[BGTASK] \(snapshot.id) adopted onto message \(message.id.uuidString.prefix(8)) already ended (\(snapshot.status.label)).")
            return
        }
        tracked[snapshot.id] = Tracked(message: message, eventID: data.id, conversationID: conversationID)
        logger.info("[BGTASK] \(snapshot.id) adopted onto message \(message.id.uuidString.prefix(8)).")
    }

    // MARK: - Updates

    private func apply(_ snapshot: BackgroundProcessRegistry.Snapshot, to entry: Tracked) {
        let updated = makeData(from: snapshot, eventID: entry.eventID)
        let isEnding = snapshot.status.isTerminal
        if isEnding { tracked.removeValue(forKey: snapshot.id) }

        guard let message = entry.message else {
            // ⚠️ The conversation was unloaded. A LIVE update has nobody to show it to and is
            // dropped — but the ENDING still has to reach disk, or the row loads as `running`
            // forever. The entry stays tracked until then (a task is bounded, so this is too).
            if isEnding { persistEnding(updated, of: entry, liveMessage: nil) }
            return
        }
        guard let index = message.timelineEvents.firstIndex(where: { $0.id == entry.eventID }) else { return }

        // Identity-compared rather than blind-assigned: `timelineEvents.didSet` bumps the revision
        // SwiftUI diffs on, so writing an unchanged value would re-render the whole timeline once
        // a second for the life of every build.
        if case .backgroundTask(let current) = message.timelineEvents[index], current == updated { return }
        message.timelineEvents[index] = .backgroundTask(updated)

        if isEnding { persistEnding(updated, of: entry, liveMessage: message) }
    }

    // MARK: - Persisting the ending

    /// Writes a task's final row to disk. Once per task — only the terminal transition calls this.
    ///
    /// ⚠️ ONLY A MESSAGE THAT IS ALREADY STORED IS WRITTEN. The save is an upsert that INSERTS when
    /// the row is absent, conversation or no conversation — so a blind save could mint an orphan
    /// message. Absent means the stream has not flushed this turn yet; it still owns the message, and
    /// its final flush carries the row just set in memory. Nothing is lost by stepping aside.
    ///
    /// With no live instance (the conversation was unloaded), the stored copy is updated and saved
    /// instead. If the stored copy has not got the row at all — it was adopted after the last flush,
    /// which that flush would normally have carried — it is appended, so the ending is not dropped.
    private func persistEnding(_ row: BackgroundTaskData, of entry: Tracked, liveMessage: ChatMessage?) {
        let persistence = self.persistence
        let messageID = entry.messageID
        let conversationID = entry.conversationID
        let eventID = entry.eventID
        let write = Task { @MainActor in
            guard let stored = await persistence.fetchMessage(withId: messageID) else {
                logger.info("[BGTASK] \(row.taskID) ended (\(row.status.rawValue)) before message \(messageID.uuidString.prefix(8)) was first saved. CONSEQUENCE: nothing written here — the stream still owns that message and its final flush carries the finished row.")
                return
            }
            let target: ChatMessage
            if let liveMessage {
                target = liveMessage
            } else {
                if let index = stored.timelineEvents.firstIndex(where: { $0.id == eventID }) {
                    stored.timelineEvents[index] = .backgroundTask(row)
                } else {
                    stored.timelineEvents.append(.backgroundTask(row))
                }
                target = stored
            }
            await persistence.addMessage(target, toConversation: conversationID)
            let via = liveMessage == nil ? " from its stored copy — the conversation was unloaded" : ""
            logger.info("[BGTASK] \(row.taskID) ending (\(row.status.rawValue)) saved to message \(messageID.uuidString.prefix(8))\(via). CONSEQUENCE: the row reloads as its real outcome, including after a relaunch, instead of 'running' → 'interrupted'.")
        }
        pendingWrites.append(write)
        // Bounded: one entry per ENDED task. Only the latest few are ever awaited (by tests).
        if pendingWrites.count > 32 { pendingWrites.removeFirst(pendingWrites.count - 32) }
    }

    private func makeData(from snapshot: BackgroundProcessRegistry.Snapshot, eventID: UUID) -> BackgroundTaskData {
        // ⚠️ NO FILE I/O HERE. The snapshot's tail is already bounded by the registry (200 lines),
        // so this second bound is a wire-format cap on an object that is small before it starts —
        // never a read. See the type comment for what this line used to do.
        let tail = snapshot.tail.count > BackgroundTaskData.maxOutputTail
            ? String(snapshot.tail.suffix(BackgroundTaskData.maxOutputTail))
            : snapshot.tail

        let status: BackgroundTaskStatus
        var exitCode: Int32?
        switch snapshot.status {
        case .running:          status = .running
        case .exited(let code): status = .exited; exitCode = code
        case .timedOut:         status = .timedOut
        case .stopped:          status = .stopped
        }

        return BackgroundTaskData(
            id: eventID,
            taskID: snapshot.id,
            name: snapshot.name,
            command: snapshot.command,
            workingDirectory: snapshot.workingDirectory,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            status: status,
            exitCode: exitCode,
            logPath: snapshot.logURL.path,
            outputTail: tail,
            logCharacterCount: snapshot.logCharacterCount)
    }

}

