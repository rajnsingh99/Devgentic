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

    /// Converts to the `ScheduledTask` value type used by the service and UI.
    func toStruct() -> ScheduledTask {
        let fileURLs: [URL] = {
            guard let json = attachedFileURLsJSON,
                  let data = json.data(using: .utf8),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return paths.compactMap { URL(fileURLWithPath: $0) }
        }()

        return ScheduledTask(
            id: id,
            displayName: displayName,
            mode: TaskMode(rawValue: mode) ?? .autonomous,
            promptTemplate: promptTemplate,
            profileID: profileID,
            attachedFileURLs: fileURLs,
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

        if !task.attachedFileURLs.isEmpty {
            let paths = task.attachedFileURLs.map { $0.path }
            if let data = try? JSONEncoder().encode(paths) {
                attachedFileURLsJSON = String(data: data, encoding: .utf8)
            }
        } else {
            attachedFileURLsJSON = nil
        }
    }
}
