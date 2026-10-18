// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ShellCommandTools.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - run_command (waits)

/// The `run_command` tool: runs a shell command (`/bin/zsh`) and waits for its result.
/// Its non-waiting sibling is `start_background_task`; both delegate to `BatchCommandTool`'s shared core
/// for the refusals, timeout clamp, truncation and execution paths.
struct RunCommandTool: DevgenticTool {
    let name = "run_command"
    let category = "System & Shell"
    let description = "Runs a shell command and WAITS for it to finish, returning its output. Use this for builds, tests, linters, and anything whose result you need. Raise timeout_seconds for a slow build."
    /// A build that writes "error" to stderr is reporting a result, not failing this tool.
    let outputMayContainErrorText = true
    /// Bounds itself at `timeout_seconds` (≤ `BatchCommandTool.maxTimeoutSeconds`) and returns the
    /// partial output — so the dispatcher's timeout sits just above that ceiling (Contract dec. 2).
    var selfBoundCeiling: TimeInterval? { TimeInterval(BatchCommandTool.maxTimeoutSeconds) }

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
                ("timeout_seconds", "integer", "Maximum seconds to wait, max 1800 (default 1800). The command is killed at the bound, but whatever it printed first is still returned."),
                ("task_name", "string", "Optional short label, e.g. 'Build and test'. Shown to the user instead of the raw command."),
            ],
            required: ["command", "working_directory"]
        )
    }

    func call(arguments: ShellCommandArguments) async throws -> String {
        switch BatchCommandTool.precheck(command: arguments.command,
                                         workingDirectory: arguments.working_directory) {
        case .refused(let reason):
            // Thrown, not returned: `outputMayContainErrorText` disables output sniffing, so a returned "Error: ..." would be
            // recorded as a successful call and never counted by the circuit breaker.
            throw ShellCommandError.refused(reason: reason)
        case .ready(let workingDirectory):
            // A command killed at its own `timeout_seconds`, or stopped, is thrown as such; returned as text it would be recorded as
            // a success. The dispatcher maps these to `.timedOut` / `.cancelled` and still hands the model the partial output.
            switch try await BatchCommandTool.runForegroundOutcome(
                command: arguments.command,
                workingDirectory: workingDirectory,
                timeout: BatchCommandTool.effectiveTimeout(arguments.timeout_seconds),
                conversationID: conversationID,
                name: arguments.task_name) {
            case .finished(let observation):
                return observation
            case .timedOut(let limit, let observation):
                throw ShellCommandError.timedOut(limit: TimeInterval(limit), observation: observation)
            case .stopped(let observation):
                throw ShellCommandError.stopped(observation: observation)
            }
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
    /// Killed at its own `timeout_seconds`; `observation` carries the partial output.
    case timedOut(limit: TimeInterval, observation: String)
    /// Stopped before it finished; `observation` carries the partial output.
    case stopped(observation: String)

    var errorDescription: String? {
        switch self {
        case .refused(let reason):      return reason
        case .launchFailed(let reason): return "Error: the command could not be started: \(reason)"
        case .timedOut(_, let observation), .stopped(let observation): return observation
        }
    }
}

// MARK: - start_background_task (does not wait)

struct StartBackgroundTaskTool: DevgenticTool {
    let name = "start_background_task"
    let category = "System & Shell"
    /// Bounds itself at `timeout_seconds` (≤ `BatchCommandTool.maxTimeoutSeconds`) and returns the
    /// partial output — so the dispatcher's timeout sits just above that ceiling (Contract dec. 2).
    var selfBoundCeiling: TimeInterval? { TimeInterval(BatchCommandTool.maxTimeoutSeconds) }
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
                ("timeout_seconds", "integer", "Seconds before the task is killed, max 1800 (default 1800). It runs unattended, so this is the only thing that stops a runaway."),
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

/// Arguments shared by both command tools, so they cannot drift in what they accept.
/// The `cmd` / `script` aliases are accepted because models emit them; rejecting a synonym wastes a turn.
struct ShellCommandArguments: Decodable, Sendable {
    let command: String
    let working_directory: String?
    let timeout_seconds: Int?
    let task_name: String?
    /// Opt-in, set by the model when it will report back; absent or false, a finished task only updates its card.
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
