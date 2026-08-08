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

    /// True when `attachedFileURLsJSON` could not be decoded, so `attachedFileURLs` is empty because
    /// it was UNREADABLE rather than because the task has no attachments.
    ///
    /// ⚠️ Load-scoped, and excluded from `==`: it describes this read, not the task. The writer
    /// checks it and refuses to null the stored column — otherwise one failed decode plus any routine
    /// edit erased the user's attachment list permanently (G23). Same shape as
    /// `ChatMessage.timelineDecodeFailed`.
    var attachedFileURLsUnreadable: Bool = false
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
