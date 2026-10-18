// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ScheduledTaskSD.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData

private let logger = DGLogger(category: "ScheduledTaskSD")

/// SwiftData model for scheduled task persistence: a flat entity with no relationships or value transformers.
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
    // Why: must stay optional: only an optional attribute is lightweight-safe to add to an existing store.
    /// The task's own execution limit in seconds; nil falls back to the profile's `executionTimeout`,
    /// else the scheduler default.
    var runLimitSeconds: Double?

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
        createdAt: Date = Date(),
        runLimitSeconds: Double? = nil
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
        self.runLimitSeconds = runLimitSeconds
    }
}

// MARK: - Conversion Helpers

extension ScheduledTaskModel {

    /// Current persisted shape of `attachedFileURLsJSON`: a `VersionedBlob<[String]>` envelope around the array of paths.
    /// The reader still accepts a bare array, since unwrapped rows can exist indefinitely.
    static let attachedFilesBlobVersion = 1

    /// Converts to the `ScheduledTask` value type used by the service and UI.
    func toStruct() -> ScheduledTask {
        // "No attachments" and "unreadable attachment list" are different states: distinguish and log, and let the
        // writer refuse. Collapsing them with `?? []` plus any routine edit would erase the stored paths permanently.
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
            // Decode the envelope directly so a failure carries the real error for the caller to log and the writer to refuse on,
            // rather than silently reporting no attachments.
            do {
                return try JSONDecoder().decode(VersionedBlob<[String]>.self, from: data).payload
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
            createdAt: createdAt,
            runLimit: runLimitSeconds
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
        runLimitSeconds = task.runLimit

        // Refuse to null a column that could not be read: `toStruct()` yields an empty list for undecodable JSON.
        // Gate on `unreadable && isEmpty`, not emptiness alone, or removing all attachments could never persist.
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
