//
//  ScheduledTask.swift
//  Devgentic
//
//  Swift value-type mirror of ScheduledTaskEntity.
//  Contains enums, entity conversion, and template variable resolution.
//

import Foundation

// MARK: - Enums

enum TaskMode: String, Codable, CaseIterable, Identifiable {
    case conversationBound = "conversationBound"
    case autonomous = "autonomous"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .conversationBound: return "Conversation-Bound"
        case .autonomous: return "Autonomous"
        }
    }
}

enum TaskStatus: String, Codable, CaseIterable {
    case pending
    case running
    case completed
    case failed
    case paused
}

enum ContextWindowMode: String, Codable, CaseIterable, Identifiable {
    case continuous
    case stateless

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .continuous: return "Continuous"
        case .stateless: return "Stateless"
        }
    }
}

// MARK: - ScheduledTask

struct ScheduledTask: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var mode: TaskMode
    var promptTemplate: String
    var profileID: UUID?
    var attachedFileURLs: [URL]
    var cronExpression: String?
    var scheduledAt: Date?
    var isEnabled: Bool
    var isPaused: Bool
    var status: TaskStatus
    var lastRunAt: Date?
    var nextRunAt: Date?
    var runCount: Int
    var lastRunSummary: String?
    var linkedConversationID: UUID?
    var contextWindowMode: ContextWindowMode
    var createdAt: Date

    var isRecurring: Bool { cronExpression != nil }
    var isOneShot: Bool { scheduledAt != nil && cronExpression == nil }

    var scheduleDescription: String {
        if let cron = cronExpression, let parsed = try? CronExpression(expression: cron) {
            return parsed.humanReadable
        }
        if let date = scheduledAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter.string(from: date)
        }
        return "Manual only"
    }

    var statusColor: String {
        switch status {
        case .pending: return "blue"
        case .running: return "orange"
        case .completed: return "green"
        case .failed: return "red"
        case .paused: return "gray"
        }
    }

    static func == (lhs: ScheduledTask, rhs: ScheduledTask) -> Bool {
        lhs.id == rhs.id && lhs.runCount == rhs.runCount && lhs.status == rhs.status &&
        lhs.isEnabled == rhs.isEnabled && lhs.isPaused == rhs.isPaused
    }
}

// MARK: - Entity Conversion

extension ScheduledTaskEntity {
    func toStruct() -> ScheduledTask {
        let fileURLs: [URL] = {
            guard let json = attachedFileURLsJSON,
                  let data = json.data(using: .utf8),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return paths.compactMap { URL(fileURLWithPath: $0) }
        }()

        return ScheduledTask(
            id: id ?? UUID(),
            displayName: displayName ?? "Untitled Task",
            mode: TaskMode(rawValue: mode ?? "autonomous") ?? .autonomous,
            promptTemplate: promptTemplate ?? "",
            profileID: profileID,
            attachedFileURLs: fileURLs,
            cronExpression: cronExpression,
            scheduledAt: scheduledAt,
            isEnabled: isEnabled,
            isPaused: isPaused,
            status: TaskStatus(rawValue: status ?? "pending") ?? .pending,
            lastRunAt: lastRunAt,
            nextRunAt: nextRunAt,
            runCount: Int(runCount),
            lastRunSummary: lastRunSummary,
            linkedConversationID: linkedConversationID,
            contextWindowMode: ContextWindowMode(rawValue: contextWindowMode ?? "continuous") ?? .continuous,
            createdAt: createdAt ?? Date()
        )
    }
}

extension ScheduledTask {
    func applyTo(entity: ScheduledTaskEntity) {
        entity.id = id
        entity.displayName = displayName
        entity.mode = mode.rawValue
        entity.promptTemplate = promptTemplate
        entity.profileID = profileID
        entity.cronExpression = cronExpression
        entity.scheduledAt = scheduledAt
        entity.isEnabled = isEnabled
        entity.isPaused = isPaused
        entity.status = status.rawValue
        entity.lastRunAt = lastRunAt
        entity.nextRunAt = nextRunAt
        entity.runCount = Int16(runCount)
        entity.lastRunSummary = lastRunSummary
        entity.linkedConversationID = linkedConversationID
        entity.contextWindowMode = contextWindowMode.rawValue
        entity.createdAt = createdAt

        if !attachedFileURLs.isEmpty {
            let paths = attachedFileURLs.map { $0.path }
            if let data = try? JSONEncoder().encode(paths) {
                entity.attachedFileURLsJSON = String(data: data, encoding: .utf8)
            }
        } else {
            entity.attachedFileURLsJSON = nil
        }
    }
}

// MARK: - Template Variable Resolution

func resolveTemplate(_ template: String, task: ScheduledTask) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .long
    dateFormatter.timeStyle = .none

    let dayFormatter = DateFormatter()
    dayFormatter.dateFormat = "EEEE"

    let timeFormatter = DateFormatter()
    timeFormatter.dateStyle = .long
    timeFormatter.timeStyle = .short

    var result = template
    result = result.replacingOccurrences(of: "{{date}}", with: dateFormatter.string(from: Date()))
    result = result.replacingOccurrences(of: "{{weekday}}", with: dayFormatter.string(from: Date()))
    result = result.replacingOccurrences(of: "{{runCount}}", with: "\(task.runCount + 1)") // Next run number
    if let lastRun = task.lastRunAt {
        result = result.replacingOccurrences(of: "{{lastRunAt}}", with: timeFormatter.string(from: lastRun))
    } else {
        result = result.replacingOccurrences(of: "{{lastRunAt}}", with: "never")
    }
    if let nextRun = task.nextRunAt {
        result = result.replacingOccurrences(of: "{{nextRunAt}}", with: timeFormatter.string(from: nextRun))
    } else {
        result = result.replacingOccurrences(of: "{{nextRunAt}}", with: "N/A")
    }

    return result
}
