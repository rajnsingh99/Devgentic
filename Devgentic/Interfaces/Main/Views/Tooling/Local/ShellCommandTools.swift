// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ShellCommandTools.swift
//  Devgentic
//
//  `batch_command`, split by intent — one tool that waits, one that does not.
//
//  ── Why ─────────────────────────────────────────────────────────────────────────────────
//
//  The Code tools guide states the rule this project already settled on, on a screen the user
//  reads: *"Generic tools with multi-modal boolean toggles (e.g. edit_code, code_search) are
//  superseded by focused single-intent splits. Smaller models (MLX & Ollama 7B–14B) never
//  hallucinate toggles or corrupt files."*
//
//  `background: true` is exactly such a toggle, and `batch_command` survived the 2026-07-31 split
//  work that produced `edit_code_single`/`edit_code_batch`, the three `code_search_*` tools,
//  `create_new_file`/`overwrite_file` and `manage_processes`/`kill_process`. It was simply missed.
//
//  The proof it mattered: on 2026-09-21 the flag's description had to grow by 270 characters of
//  prose explaining WHEN to set it, because a device run had backgrounded a build whose result it
//  wanted one second later and then spent nine iterations polling for it. That prose existed only
//  because one tool served two intents. The tool NAME now carries it, for free, and a name cannot
//  be hallucinated the way a boolean can.
//
//  ⚠️ Both delegate to `BatchCommandTool`'s shared core. There is one implementation of the
//  refusals, the timeout clamp, the truncation and the two execution paths — `batch_command`
//  itself is now a dispatcher over the same functions. A guard or a behaviour attached to one
//  tool is attached to a NAME rather than a capability, which is the reasoning `ShellCommandGuard`
//  already carries.
//
//  ⚠️ NOT named `bash_*`: this runs `/bin/zsh`. A name that misstates the shell outlives the
//  decision that chose it.
//

import Foundation

// MARK: - run_command (waits)

struct RunCommandTool: DevgenticTool {
    let name = "run_command"
    let category = "System & Shell"
    let description = "Runs a shell command and WAITS for it to finish, returning its output. Use this for builds, tests, linters, and anything whose result you need. Raise timeout_seconds for a slow build."
    /// A build that writes "error" to stderr is reporting a result, not failing this tool.
    let outputMayContainErrorText = true

    let conversationID: UUID?

    init(conversationID: UUID? = nil) {
        self.conversationID = conversationID
    }

    typealias Arguments = ShellCommandArguments

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(
            properties: [
                ("command", "string", "The shell command to run."),
                ("working_directory", "string", "Working directory. Required — pass the project root or a subpath."),
                ("timeout_seconds", "integer", "Maximum seconds to wait, max 900 (default 30). The command is killed at the bound, but whatever it printed first is still returned."),
                ("task_name", "string", "Optional short label, e.g. 'Build and test'. Shown to the user instead of the raw command."),
            ],
            required: ["command", "working_directory"]
        )
    }

    func call(arguments: ShellCommandArguments) async throws -> String {
        switch BatchCommandTool.precheck(command: arguments.command,
                                         workingDirectory: arguments.working_directory) {
        case .refused(let reason):
            // ⚠️ THROWN, not returned. `outputMayContainErrorText` switches off the mediator's
            // output sniffing, so a returned "Error: …" is recorded as a SUCCESSFUL call and the
            // circuit breaker never counts it. `execute_shell` held this line until its removal on
            // 2026-09-24; `run_command` is now the shell, so it holds it here.
            throw ShellCommandError.refused(reason: reason)
        case .ready(let workingDirectory):
            return try await BatchCommandTool.runForeground(
                command: arguments.command,
                workingDirectory: workingDirectory,
                timeout: BatchCommandTool.effectiveTimeout(arguments.timeout_seconds),
                conversationID: conversationID,
                name: arguments.task_name)
        }
    }
}

/// A shell command that never ran. Thrown rather than returned by tools that opt out of output
/// sniffing — see `RunCommandTool.call`. Classified as `.executionThrew`: a soft failure, so the
/// model sees the reason and may retry, and the tool is not banned.
enum ShellCommandError: Error, LocalizedError {
    /// Refused before any process ran — interactive programs, destructive patterns, a missing
    /// working directory.
    case refused(reason: String)
    /// The shell could not be started at all.
    case launchFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .refused(let reason):      return reason
        case .launchFailed(let reason): return "Error: the command could not be started: \(reason)"
        }
    }
}

// MARK: - start_background_task (does not wait)

struct StartBackgroundTaskTool: DevgenticTool {
    let name = "start_background_task"
    let category = "System & Shell"
    let description = "Starts a shell command and returns IMMEDIATELY with a task id, without waiting. Use this only to leave something running that you are not waiting for, such as a dev server or a watcher. You get no output from this call — read it with get_task_output."

    let conversationID: UUID?

    init(conversationID: UUID? = nil) {
        self.conversationID = conversationID
    }

    typealias Arguments = ShellCommandArguments

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(
            properties: [
                ("command", "string", "The shell command to start."),
                ("working_directory", "string", "Working directory. Required — pass the project root or a subpath."),
                ("timeout_seconds", "integer", "Seconds before the task is killed, max 900 (default 900). It runs unattended, so this is the only thing that stops a runaway."),
                ("task_name", "string", "Optional short label, e.g. 'Dev server'. Shown to the user instead of the raw command."),
                ("notify_on_completion", "boolean", "Default false. Set it true ONLY if you are going to end your turn now and want to be given this task's result when it finishes. You will be asked to report on it and will have no tools, so do not set it for anything you intend to act on yourself — poll with get_task_output instead. Never set it for a dev server or a watcher: those do not finish."),
            ],
            required: ["command", "working_directory"]
        )
    }

    func call(arguments: ShellCommandArguments) async throws -> String {
        switch BatchCommandTool.precheck(command: arguments.command,
                                         workingDirectory: arguments.working_directory) {
        case .refused(let reason):
            return reason
        case .ready(let workingDirectory):
            return BatchCommandTool.startBackground(
                command: arguments.command,
                workingDirectory: workingDirectory,
                timeout: BatchCommandTool.effectiveTimeout(arguments.timeout_seconds, background: true),
                conversationID: conversationID,
                name: arguments.task_name,
                notifyOnCompletion: arguments.notify_on_completion ?? false)
        }
    }
}

// MARK: - Shared arguments

/// ⚠️ Shared so the two splits cannot drift in what they accept. The `cmd` / `script` aliases are
/// kept from `batch_command`: models emit them, and rejecting a call over a synonym wastes a turn.
struct ShellCommandArguments: Decodable, Sendable {
    let command: String
    let working_directory: String?
    let timeout_seconds: Int?
    let task_name: String?
    /// ⚠️ OPT-IN, and the model is the one that opts in — it is the party that says it will report
    /// back. Absent or false, a finished task updates its card and nothing else happens.
    let notify_on_completion: Bool?

    private struct DynamicKey: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        var resolved: String?
        for key in ["command", "cmd", "script"] {
            if let codingKey = DynamicKey(stringValue: key),
               let value = try? container.decode(String.self, forKey: codingKey) {
                resolved = value
                break
            }
        }
        command = try resolved ?? container.decode(String.self, forKey: DynamicKey(stringValue: "command")!)

        working_directory = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "working_directory")!)
        timeout_seconds = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "timeout_seconds")!)
        task_name = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "task_name")!)
        notify_on_completion = try? container.decodeIfPresent(Bool.self, forKey: DynamicKey(stringValue: "notify_on_completion")!)
    }
}
