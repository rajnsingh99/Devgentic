// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskHistory.swift
//  Devgentic
//
//  A conversation's task list = the tasks this launch is running or ran (the registry, in memory)
//  + every task card saved in the conversation's timeline (2026-09-26).
//
//  ⚠️ Why. The list and its pill read ONLY `BackgroundProcessRegistry`, which lives in memory — so
//  after a relaunch a conversation that had run twenty builds showed an empty list, and the pill
//  hid itself, while every one of those runs was sitting in the saved timeline cards with its
//  status, exit code, output tail and log path. The cards are the durable record; this derives the
//  list from them rather than keeping a second copy that would have to be kept in sync.
//
//  ⚠️ Keyed by LOG FILE, not task id. `bg_1` restarts at 1 every launch, so two different runs in
//  one conversation can share it; each run's log file is new (timestamped, `O_EXCL`).
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

    /// Live tasks win over their own saved card. A saved card still `running` that is NOT live is
    /// a task that died with an earlier launch (quit kills every task) — shown as `interrupted`,
    /// with no invented finish time. Finished rows at or before `clearedBefore` are hidden; a
    /// running task never is. Oldest first.
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

    /// ⚠️ Clearing HIDES; it deletes nothing. The cards stay in the conversation (they are its
    /// history) and the logs stay until the retention sweep. Without a remembered cutoff, cleared
    /// rows would come straight back from the saved cards on the next reload.
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
