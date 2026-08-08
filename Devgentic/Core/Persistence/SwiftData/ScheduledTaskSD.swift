//
//  ScheduledTaskSD.swift
//  Devgentic
//
//  Created on 26/03/26.
//
//  SwiftData @Model class for scheduled task persistence.
//  Replaces ScheduledTaskEntity. Flat entity, no relationships, no ValueTransformers.
//

import Foundation
import SwiftData

private let logger = DGLogger(category: "ScheduledTaskSD")

@Model
final class ScheduledTaskModel {

    @Attribute(.unique)
    var id: UUID

    var displayName: String
    var mode: String                    // TaskMode.rawValue
    var promptTemplate: String
    var profileID: UUID?
    var attachedFileURLsJSON: String?   // JSON-encoded [String] file paths
    var cronExpression: String?
    var scheduledAt: Date?
    var isEnabled: Bool
    var isPaused: Bool
    var status: String                  // TaskStatus.rawValue
    var lastRunAt: Date?
    var nextRunAt: Date?
    var runCount: Int
    var lastRunSummary: String?
    var linkedConversationID: UUID?
    var contextWindowMode: String       // ContextWindowMode.rawValue
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String = "Untitled Task",
        mode: String = "autonomous",
        promptTemplate: String = "",
        profileID: UUID? = nil,
        attachedFileURLsJSON: String? = nil,
        cronExpression: String? = nil,
        scheduledAt: Date? = nil,
        isEnabled: Bool = true,
        isPaused: Bool = false,
        status: String = "pending",
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        runCount: Int = 0,
        lastRunSummary: String? = nil,
        linkedConversationID: UUID? = nil,
        contextWindowMode: String = "continuous",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.mode = mode
        self.promptTemplate = promptTemplate
        self.profileID = profileID
        self.attachedFileURLsJSON = attachedFileURLsJSON
        self.cronExpression = cronExpression
        self.scheduledAt = scheduledAt
        self.isEnabled = isEnabled
        self.isPaused = isPaused
        self.status = status
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.runCount = runCount
        self.lastRunSummary = lastRunSummary
        self.linkedConversationID = linkedConversationID
        self.contextWindowMode = contextWindowMode
        self.createdAt = createdAt
    }
}

// MARK: - Conversion Helpers

extension ScheduledTaskModel {

    /// Current persisted shape of `attachedFileURLsJSON`.
    ///
    /// ⚠️ ENVELOPE, not an inline key: the payload is a bare `[String]` ARRAY. Written as
    /// `VersionedBlob<[String]>`; the reader keeps accepting a bare array for as long as unwrapped
    /// rows can exist, which is indefinitely (G19).
    static let attachedFilesBlobVersion = 1

    /// Converts to the `ScheduledTask` value type used by the service and UI.
    func toStruct() -> ScheduledTask {
        // ⚠️ "No attachments" and "the attachment list could not be read" are DIFFERENT, and the
        // previous `?? []` collapsed them (G23). That made the loss permanent on the next write:
        // `init(from task:)` below nils the column whenever the in-memory list is empty, so one
        // failed decode plus any routine edit of the task erased the paths for good — silently, with
        // no log. Distinguish, log, and let the writer refuse.
        let decoded: [URL]? = {
            guard let json = attachedFileURLsJSON else { return [] }  // genuinely no attachments
            guard let data = json.data(using: .utf8) else {
                logger.error(
                    "[PERSISTENCE] Scheduled task '\(displayName)' (\(id)): attachedFileURLsJSON is not "
                    + "valid UTF-8 (\(json.count) chars). CONSEQUENCE: its attachments do not load for "
                    + "this run, and the stored value is PROTECTED from being nulled by that empty state."
                )
                return nil
            }
            // ⚠️ ENVELOPE (G19): the payload is a bare `[String]` ARRAY, which has nowhere to put a
            // version key. The bare-array fallback inside `VersionedBlob.decode` is load-bearing —
            // every task row written before 2026-08-05 is unwrapped, and a row is only rewritten
            // when the task is edited.
            if let result = VersionedBlob<[String]>.decode(from: data) {
                return result.payload.compactMap { URL(fileURLWithPath: $0) }
            }
            do {
                // Neither shape decoded — fall through to the real error so the caller logs it and
                // the writer refuses, rather than silently reporting "no attachments".
                return try JSONDecoder().decode([String].self, from: data)
                    .compactMap { URL(fileURLWithPath: $0) }
            } catch {
                logger.error(
                    "[PERSISTENCE] Scheduled task '\(displayName)' (\(id)): attachedFileURLsJSON "
                    + "UNDECODABLE (\(json.count) chars) — \(error). CONSEQUENCE: the task runs WITHOUT "
                    + "its attached files this time, and the stored value is PROTECTED from being "
                    + "nulled by that empty state; it stays recoverable by a build that can read it."
                )
                return nil
            }
        }()

        let fileURLs = decoded ?? []

        return ScheduledTask(
            id: id,
            displayName: displayName,
            mode: TaskMode(rawValue: mode) ?? .autonomous,
            promptTemplate: promptTemplate,
            profileID: profileID,
            attachedFileURLs: fileURLs,
            attachedFileURLsUnreadable: decoded == nil,
            cronExpression: cronExpression,
            scheduledAt: scheduledAt,
            isEnabled: isEnabled,
            isPaused: isPaused,
            status: TaskStatus(rawValue: status) ?? .pending,
            lastRunAt: lastRunAt,
            nextRunAt: nextRunAt,
            runCount: runCount,
            lastRunSummary: lastRunSummary,
            linkedConversationID: linkedConversationID,
            contextWindowMode: ContextWindowMode(rawValue: contextWindowMode) ?? .continuous,
            createdAt: createdAt
        )
    }

    /// Applies values from a `ScheduledTask` value type to this model.
    func apply(from task: ScheduledTask) {
        displayName = task.displayName
        mode = task.mode.rawValue
        promptTemplate = task.promptTemplate
        profileID = task.profileID
        cronExpression = task.cronExpression
        scheduledAt = task.scheduledAt
        isEnabled = task.isEnabled
        isPaused = task.isPaused
        status = task.status.rawValue
        lastRunAt = task.lastRunAt
        nextRunAt = task.nextRunAt
        runCount = task.runCount
        lastRunSummary = task.lastRunSummary
        linkedConversationID = task.linkedConversationID
        contextWindowMode = task.contextWindowMode.rawValue
        createdAt = task.createdAt

        // ⚠️ REFUSE to null a column we could not read. `toStruct()` hands back an empty list when
        // the stored JSON is undecodable, and this branch nils the column whenever the list is
        // empty — so without the guard, one failed decode plus any routine edit (rename, pause,
        // reschedule) erased the user's attachment list permanently.
        //
        // The rule is `unreadable && isEmpty`, matching the chat timeline and NOT the profile rule:
        // an empty attachment list is a perfectly legal user state, so gating on emptiness alone
        // would freeze the column and make "remove all attachments" impossible to persist.
        if task.attachedFileURLsUnreadable && task.attachedFileURLs.isEmpty {
            logger.error(
                "[PERSISTENCE] Refusing to null attachedFileURLsJSON for scheduled task "
                + "'\(task.displayName)' (\(task.id)): the stored list failed to decode on load and "
                + "nothing has replaced it, so this write would erase it. CONSEQUENCE: the stored "
                + "value is left byte-intact and stays recoverable; this task runs without its "
                + "attachments until a build that can read them."
            )
        } else if !task.attachedFileURLs.isEmpty {
            let paths = task.attachedFileURLs.map { $0.path }
            if let data = try? JSONEncoder().encode(
                VersionedBlob(schemaVersion: Self.attachedFilesBlobVersion, payload: paths)
            ) {
                attachedFileURLsJSON = String(data: data, encoding: .utf8)
            }
        } else {
            attachedFileURLsJSON = nil
        }
    }
}
