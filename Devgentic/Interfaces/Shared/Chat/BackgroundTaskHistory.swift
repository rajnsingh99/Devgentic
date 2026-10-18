// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskHistory.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// One row of the task list, whichever source it came from.
struct BackgroundTaskListItem: Identifiable, Equatable {
    /// The run's log path, standardized. Unique per run — see the file comment.
    let id: String
    /// The registry handle (`bg_1`, `fg_2`). Repeats across launches; never a key.
    let taskID: String
    let name: String?
    let command: String
    let startedAt: Date
    let finishedAt: Date?
    let status: BackgroundTaskStatus
    let exitCode: Int32?
    let logURL: URL
    /// The output tail saved on the card — what is shown when the log file has been swept.
    let savedTail: String
    /// Present in this launch's registry: stoppable, and its log is read through the registry.
    let isLive: Bool

    var isRunning: Bool { status == .running }

    func elapsed(now: Date = Date()) -> TimeInterval {
        (finishedAt ?? now).timeIntervalSince(startedAt)
    }
}

enum BackgroundTaskHistory {

    static func key(forLogPath path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Live tasks win over their own saved card. A saved card still `running` that is not live died with an earlier
    /// launch and is shown as `interrupted` with no invented finish time. Finished rows at or before `clearedBefore` are
    /// hidden; a running task never is. Oldest first.
    static func items(live: [BackgroundProcessRegistry.Snapshot],
                      saved: [BackgroundTaskData],
                      clearedBefore: Date?) -> [BackgroundTaskListItem] {
        var byKey: [String: BackgroundTaskListItem] = [:]

        for row in saved {
            let key = key(forLogPath: row.logPath)
            byKey[key] = BackgroundTaskListItem(
                id: key, taskID: row.taskID, name: row.name, command: row.command,
                startedAt: row.startedAt, finishedAt: row.finishedAt,
                status: row.status == .running ? .interrupted : row.status,
                exitCode: row.exitCode, logURL: URL(fileURLWithPath: row.logPath),
                savedTail: row.outputTail, isLive: false)
        }
        for snapshot in live {
            let key = key(forLogPath: snapshot.logURL.path)
            let (status, exitCode) = cardStatus(of: snapshot.status)
            byKey[key] = BackgroundTaskListItem(
                id: key, taskID: snapshot.id, name: snapshot.name, command: snapshot.command,
                startedAt: snapshot.startedAt, finishedAt: snapshot.finishedAt,
                status: status, exitCode: exitCode, logURL: snapshot.logURL,
                savedTail: snapshot.tail, isLive: true)
        }

        return byKey.values
            .filter { item in
                guard let clearedBefore, !item.isRunning else { return true }
                return (item.finishedAt ?? item.startedAt) > clearedBefore
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    static func cardStatus(of status: BackgroundProcessRegistry.Status) -> (BackgroundTaskStatus, Int32?) {
        switch status {
        case .running:          return (.running, nil)
        case .exited(let code): return (.exited, code)
        case .timedOut:         return (.timedOut, nil)
        case .stopped:          return (.stopped, nil)
        }
    }

    // MARK: - "Clear finished"

    /// Clearing hides and deletes nothing: the cards stay in the conversation and the logs stay until the retention sweep.
    /// The remembered cutoff keeps cleared rows from coming back from the saved cards on reload.
    private static let clearedBeforeKey = "backgroundTaskHistory.clearedBefore"

    static func clearedBefore(_ conversationID: UUID, defaults: UserDefaults = .standard) -> Date? {
        (defaults.dictionary(forKey: clearedBeforeKey)?[conversationID.uuidString] as? Double)
            .map(Date.init(timeIntervalSince1970:))
    }

    static func markCleared(_ conversationID: UUID, now: Date = Date(), defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: clearedBeforeKey) ?? [:]
        all[conversationID.uuidString] = now.timeIntervalSince1970
        defaults.set(all, forKey: clearedBeforeKey)
    }
}
