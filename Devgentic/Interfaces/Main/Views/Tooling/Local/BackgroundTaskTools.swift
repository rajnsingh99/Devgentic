// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskTools.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Shared formatting

/// One rendering of a task line, so three tools cannot describe the same task three ways.
private func describe(_ task: BackgroundProcessRegistry.Snapshot) -> String {
    let elapsed = Int(task.elapsed().rounded())
    // The command stays even when a name is present: the model may have to reason about what was
    // actually run, and a label it invented three turns ago is not a substitute for that.
    let label = task.name.map { "\(task.id) \"\($0)\"" } ?? task.id
    return "\(label) — \(task.status.label), \(elapsed)s — \(task.command)\(task.status.isTerminal ? "" : stillRunningAdvice)"
}

/// Advice appended to the observation of a still-running task, telling the model not to poll in a loop.
/// Attached at decision time rather than in the system prompt; terminal statuses need none.
private let stillRunningAdvice = """

Do NOT read this again in a loop — repeated polling burns your iteration budget and tells the user nothing new. Choose one: end your turn now and let the user ask later; or, if you need the result without waiting, stop this task and start it again with notify_on_completion: true, which gives you a turn of your own when it finishes.
"""

// MARK: - get_task_output

/// Reads what a background command wrote and ends it early, scoped to the conversation that owns the task.
struct CommandOutputTool: DevgenticTool {
    let name = "get_task_output"
    let category = "System & Shell"
    let description = "Reads the output a background command has produced so far. Pass since_line to get only what is new since your last read, instead of the whole log again."
    /// A build that writes "error" to stderr is reporting a result, not failing this tool — the
    /// same opt-out `execute_shell` carries.
    let outputMayContainErrorText = true

    let conversationID: UUID?

    init(conversationID: UUID? = nil) {
        self.conversationID = conversationID
    }

    struct Arguments: Decodable, Sendable {
        let task_id: String?
        let since_line: Int?
    }

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(
            properties: [
                ("task_id", "string", "The task whose output to read (e.g. 'bg_1'). Omit to list every background task in this conversation with its status, without output."),
                ("since_line", "integer", "Start from this line, as reported by your previous read. Omit to read from the beginning.")
            ],
            required: []
        )
    }

    func call(arguments: Arguments) async throws -> String {
        guard let conversationID else { return BackgroundTaskToolSupport.noConversation }

        // The list-everything form returns statuses only, never output, to avoid reading every task's log.
        guard let requested = arguments.task_id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty else {
            let all = BackgroundProcessRegistry.shared.snapshots(conversationID: conversationID)
            guard !all.isEmpty else {
                return "No background commands have been started in this conversation."
            }
            return "Background tasks:\n" + all.map(describe).joined(separator: "\n")
        }
        let id = requested
        guard let task = BackgroundProcessRegistry.shared.snapshot(conversationID: conversationID, taskID: id),
              let log = BackgroundProcessRegistry.shared.readLog(
                conversationID: conversationID, taskID: id, sinceLine: max(0, arguments.since_line ?? 0))
        else {
            return BackgroundTaskToolSupport.unknown(id, conversationID: conversationID)
        }

        // Returned whole; `ToolResultBudget.fit` cuts it to the room the model has, keeping both ends.
        let body = log.text

        if body.isEmpty {
            return task.status.isTerminal
                ? "\(describe(task))\nNo new output. The task has finished."
                // `describe` already appends the do-not-loop advice for a running task, so this must not invite another immediate read.
                : "\(describe(task))\nNothing new since line \(log.nextLine)."
        }
        return "\(describe(task))\nNext read from line \(log.nextLine).\n\n\(body)"
    }
}

// MARK: - stop_background_task

struct CommandStopTool: DevgenticTool {
    let name = "stop_background_task"
    let category = "System & Shell"
    // Names no starter tool, because the tool that starts a task differs by mode.
    let description = "Ends a background command that is still running. Its output up to that point is kept and can still be read with get_task_output."

    let conversationID: UUID?

    init(conversationID: UUID? = nil) {
        self.conversationID = conversationID
    }

    struct Arguments: Decodable, Sendable {
        let task_id: String
    }

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(
            properties: [
                ("task_id", "string", "The task to end (e.g. 'bg_1').")
            ],
            required: ["task_id"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        guard let conversationID else { return BackgroundTaskToolSupport.noConversation }

        let id = arguments.task_id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task = BackgroundProcessRegistry.shared.stop(conversationID: conversationID, taskID: id) else {
            return BackgroundTaskToolSupport.unknown(id, conversationID: conversationID)
        }

        // Narrates an action, so it states what has happened: SIGTERM was sent and the SIGKILL escalation is pending.
        // Sub-processes are covered by `ProcessTree`.
        return "\(describe(task))\nStop requested for it and any sub-processes it started; anything that ignores the request is force-killed a moment later."
    }
}

// MARK: - Shared refusals

enum BackgroundTaskToolSupport {
    /// Matches `batch_command`'s own refusal: the catalogue builds every tool once with a nil id
    /// for Library metadata, and a tool reached in that state has no conversation to look in.
    static let noConversation =
        "Error: background tasks are unavailable here (no conversation to look them up in)."

    static func unknown(_ id: String, conversationID: UUID) -> String {
        let known = BackgroundProcessRegistry.shared.snapshots(conversationID: conversationID).map(\.id)
        guard !known.isEmpty else {
            // The remedy names no starter tool: it differs by mode and this string is reached from both.
            return "Error: no background task '\(id)'. No background commands have been started in this conversation — start one first, with whichever tool your loadout offers for running a command in the background."
        }
        return "Error: no background task '\(id)' in this conversation. Known tasks: \(known.joined(separator: ", "))."
    }
}
