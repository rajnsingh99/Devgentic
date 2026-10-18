// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ScheduledTask.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Enums

/// Whether a scheduled task is bound to a conversation or runs autonomously.
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
    /// The last run hit its execution limit.
    /// Stored as a raw string and read tolerantly, so an older build reads it as `.pending`.
    case timedOut
    case cancelled
    /// Its time passed while Devgentic was closed or the Mac was asleep, and it was skipped, not run late.
    /// The summary says which run(s).
    case missed
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

    // Why: otherwise one failed decode plus any routine edit erases the user's attachment list permanently
    /// True when `attachedFileURLsJSON` could not be decoded, so `attachedFileURLs` is empty because it was unreadable.
    /// Load-scoped and excluded from `==`; the writer checks it and refuses to null the stored column.
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
    /// This task's own execution limit in seconds.
    /// nil uses the profile's `executionTimeout`, else `SchedulerCoordinator.defaultScheduledRunLimit`.
    var runLimit: TimeInterval? = nil

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
        case .timedOut: return "orange"
        case .cancelled: return "gray"
        case .missed: return "orange"
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
