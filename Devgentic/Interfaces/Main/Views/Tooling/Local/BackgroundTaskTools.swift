// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskTools.swift
//  Devgentic
//
//  The two tools that make a background task worth starting: read what it wrote, end it early.
//
//  ⚠️ There were THREE. `command_status` was withdrawn on 2026-09-23 because it was a strict SUBSET
//  of `get_task_output` — every one of that tool's return paths begins with the same `describe(task)`
//  line `command_status` returned, and nothing else. Keeping both cost a tool slot (schemas were
//  ~40% of a local model's 8K window on the device run) and actively caused harm: the model polled
//  `command_status` twenty times and each call returned a status line with no output in it. The
//  same twenty calls to `get_task_output` would at least have carried the build's own text.
//
//  Without them the background flag was a dead end — the process ran, its output went to
//  /dev/null, and the only thing the model got back was a pid it could do nothing with. Starting
//  work you cannot observe is not a capability.
//
//  All three are scoped to the conversation that owns the task. `bg_1` means one thing per
//  conversation; a conversation cannot poll or stop another's build.
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

/// ⚠️⚠️ THE FIX FOR A MEASURED DEVICE FAILURE (2026-09-23). A status line that said only
/// "running, 8s" gave the model no next step, so it asked again — twenty times, ~2.3 s apart,
/// until the 20-iteration cap terminated the run as `completedWithWarnings`. The answer delivered
/// to the user was twenty identical "still running" lines, the build was still going, and the
/// wasted turn records then polluted every later prompt in that conversation through episodic
/// memory.
///
/// ⚠️ It is appended to the OBSERVATION, not left to the system prompt. A prompt paragraph is read
/// once, at the start; this is read at the moment the decision is made — which is the same reason
/// `batch_command`'s `background` parameter carried its guidance inline.
///
/// ⚠️ Only while RUNNING. A terminal status needs no advice: the model has its answer.
private let stillRunningAdvice = """

Do NOT read this again in a loop — repeated polling burns your iteration budget and tells the user nothing new. Choose one: end your turn now and let the user ask later; or, if you need the result without waiting, stop this task and start it again with notify_on_completion: true, which gives you a turn of your own when it finishes.
"""

// MARK: - get_task_output

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

        // ⚠️ THE LIST-EVERYTHING FORM, absorbed from the withdrawn `command_status`. Statuses only,
        // never output: reading every task's log to answer "what is running?" would be the
        // whole-file read the incremental tail exists to avoid, multiplied by the task count.
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

        // Whole. `ToolResultBudget.fit` cuts it to the room the model actually has, keeping both
        // ends — a tool-side cap here used to cut at 8K whatever the window.
        let body = log.text

        if body.isEmpty {
            return task.status.isTerminal
                ? "\(describe(task))\nNo new output. The task has finished."
                // ⚠️ `describe` already appends the do-not-loop advice for a running task, so this
                // must not invite another immediate read on top of it — "read again with
                // since_line" was doing exactly that.
                : "\(describe(task))\nNothing new since line \(log.nextLine)."
        }
        return "\(describe(task))\nNext read from line \(log.nextLine).\n\n\(body)"
    }
}

// MARK: - stop_background_task

struct CommandStopTool: DevgenticTool {
    let name = "stop_background_task"
    let category = "System & Shell"
    // ⚠️ Names no starter, for the reason `get_task_output` gives.
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

        // ⚠️ Narrates an ACTION, so it has to be accurate about what has happened: SIGTERM has
        // been sent and the SIGKILL escalation is still pending. The status label above is a
        // different kind of claim — the record is genuinely terminal, the task will produce no
        // more output — which is why that one still reads "killed" and this does not.
        //
        // Sub-processes are covered now (`ProcessTree`), so the old "may leave them running"
        // caveat would be pessimistic rather than honest. The remaining race — a process forked
        // between the snapshot and the signal — is in the log, not in every reply.
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
            // ⚠️ The remedy names no starter, for the reason the descriptions give above: the tool
            // that starts one differs by mode, and this string is reached from both. Telling a
            // Code-mode model to "use batch_command" sends it at a tool that is not in its loadout,
            // and a recovery hint that cannot be followed is worse than none — it costs an
            // iteration and teaches the model a name that will never resolve.
            return "Error: no background task '\(id)'. No background commands have been started in this conversation — start one first, with whichever tool your loadout offers for running a command in the background."
        }
        return "Error: no background task '\(id)' in this conversation. Known tasks: \(known.joined(separator: ", "))."
    }
}
