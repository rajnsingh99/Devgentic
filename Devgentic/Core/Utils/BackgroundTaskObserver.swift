// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskObserver.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Combine
import os

private let logger = DGLogger(category: "BackgroundTaskObserver")

/// Owns the `.backgroundTask` timeline row: creates it on launch, keeps output and status current, finalises it at
/// the end.
/// A background task outlives the launching stream, so the row is driven from the process registry.
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
        /// The attempt that started the task — kept here because every update rebuilds the row
        /// from the snapshot, which does not know it.
        let variantID: UUID?
        init(message: ChatMessage, eventID: UUID, conversationID: UUID, variantID: UUID?) {
            self.message = message
            self.messageID = message.id
            self.eventID = eventID
            self.conversationID = conversationID
            self.variantID = variantID
        }
    }

    private var tracked: [String: Tracked] = [:]
    private var observation: NSObjectProtocol?
    private let registry: BackgroundProcessRegistry
    private let persistence: any ChatPersistenceProtocol

    /// The ending's in-flight disk writes, exposed so a test can await them instead of sleeping.
    private(set) var pendingWrites: [Task<Void, Never>] = []

    /// How the observer finds the message a conversation is currently streaming into.
    /// Injected rather than reached for, so the type is testable without a stream manager, profile store or live
    /// backend.
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

    /// Corrects `running` rows loaded from disk that are not running; returns how many were corrected.
    /// A live task is left alone, one the registry knows finished adopts its real outcome, and an unknown one becomes
    /// `.interrupted`.
    @discardableResult
    static func reconcile(_ messages: [ChatMessage],
                          registry: BackgroundProcessRegistry = .shared) -> Int {
        reconciledMessages(messages, registry: registry).rows
    }

    /// `reconcile`, also returning the messages it changed, which the caller must persist.
    /// The registry's knowledge of a finished task exists only in this process; unsaved, the next relaunch would call
    /// it interrupted.
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
                    // Genuinely live: this `continue` is the only thing protecting it, since `continue` in a `switch` continues the
                    // enclosing loop.
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
                    // Nothing knows this task any more; `finishedAt` stays nil because the death time is unknown and stamping now
                    // would invent a duration.
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

    /// First sight of a task: finds the message this run is streaming into and adds its row.
    /// This is the only moment the message is findable; a task with no live stream gets no row, and that is logged.
    private func adopt(_ snapshot: BackgroundProcessRegistry.Snapshot, conversationID: UUID) {
        guard let message = liveMessage?(conversationID) else {
            logger.notice("[BGTASK] \(snapshot.id) started in conversation \(conversationID.uuidString.prefix(8)) with no live stream to attach a row to. CONSEQUENCE: no timeline card for this task — it still runs, is still bounded, and get_task_output still reports it, but nobody watching the conversation will see it.")
            return
        }

        let variantID = Self.currentVariantID(of: message)
        let data = makeData(from: snapshot, eventID: UUID(), variantID: variantID)
        message.timelineEvents.append(.backgroundTask(data))
        // A task first seen already ended gets its final row only: no update will follow, and the stream's own flush
        // carries the row.
        guard !snapshot.status.isTerminal else {
            logger.info("[BGTASK] \(snapshot.id) adopted onto message \(message.id.uuidString.prefix(8)) already ended (\(snapshot.status.label)).")
            return
        }
        tracked[snapshot.id] = Tracked(message: message, eventID: data.id, conversationID: conversationID,
                                       variantID: variantID)
        logger.info("[BGTASK] \(snapshot.id) adopted onto message \(message.id.uuidString.prefix(8)).")
    }

    // MARK: - Updates

    private func apply(_ snapshot: BackgroundProcessRegistry.Snapshot, to entry: Tracked) {
        let updated = makeData(from: snapshot, eventID: entry.eventID, variantID: entry.variantID)
        let isEnding = snapshot.status.isTerminal
        if isEnding { tracked.removeValue(forKey: snapshot.id) }

        guard let message = entry.message else {
            // The conversation was unloaded: a live update is dropped, but the ending still reaches disk, or the row would
            // load as `running` forever.
            if isEnding { persistEnding(updated, of: entry, liveMessage: nil) }
            return
        }
        guard let index = message.timelineEvents.firstIndex(where: { $0.id == entry.eventID }) else { return }

        // Identity-compared: `timelineEvents.didSet` bumps a revision SwiftUI diffs on, so an unchanged write would
        // re-render every second.
        if case .backgroundTask(let current) = message.timelineEvents[index], current == updated { return }
        message.timelineEvents[index] = .backgroundTask(updated)

        if isEnding { persistEnding(updated, of: entry, liveMessage: message) }
    }

    // MARK: - Persisting the ending

    /// Writes a task's final row to disk, once per task, and only for a message that is already stored.
    /// The save is an upsert, so a blind save could mint an orphan; an absent message is still owned by the stream's flush.
    /// With no live instance the stored copy is updated, or the row appended.
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

    private func makeData(from snapshot: BackgroundProcessRegistry.Snapshot, eventID: UUID,
                          variantID: UUID?) -> BackgroundTaskData {
        var data = BackgroundTaskData(snapshot: snapshot, eventID: eventID)
        data.variantID = variantID
        return data
    }

    /// The attempt a streaming message is on. A Redo selects its new variant BEFORE the stream
    /// starts (`beginRegenerationVariant`), so this is the attempt that launched the task.
    static func currentVariantID(of message: ChatMessage) -> UUID? {
        guard let response = message.agentResponse,
              response.variants.indices.contains(response.selectedVariantIndex) else { return nil }
        return response.variants[response.selectedVariantIndex].variantId
    }

}

extension BackgroundTaskData {
    /// The card for a registry snapshot. Shared by the observer (the card in the turn that started
    /// the task) and the wake (the copy the report's stub keeps, so Redo can rebuild the report).
    init(snapshot: BackgroundProcessRegistry.Snapshot, eventID: UUID = UUID()) {
        // No file I/O: the registry already bounds the snapshot tail, so this is only a wire-format cap on a small object.
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

        self.init(
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
