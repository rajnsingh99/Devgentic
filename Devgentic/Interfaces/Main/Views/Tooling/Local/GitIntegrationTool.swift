// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GitIntegrationTool.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "GitTool")

// MARK: - Git Tool

/// Result of resolving a git action to an argument vector.
/// An argv, never a command string, so model-supplied `args` and `path` cannot reach a shell.
enum GitCommandResolution {
    case argv([String])
    case error(String)
}

/// Pure logic for building git argument vectors from an action and its args.
enum GitCommandBuilder {

    // Why: a plain split on spaces would break quoted arguments such as `--author="J Smith"`, so this stays a real tokenizer.
    /// Splits a shell-style argument string into argv words (word-splitting and quote removal only).
    /// No globbing, `$VAR` or operators: `;` and `|` reach git as literal arguments.
    /// Separators are the POSIX IFS set, not Unicode whitespace, so an invisible NBSP cannot split off an option.
    private static let separatorScalars: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r"]

    // Why: tested scalar-wise because `\r\n` is a single Character and matches neither `"\r"` nor `"\n"`,
    // which would silently mangle `args` that arrive with Windows line endings.
    /// Reports whether every unicode scalar of the character is a separator.
    private static func isSeparator(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { separatorScalars.contains($0) }
    }

    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false
        var quote: Character?
        var escaped = false

        for character in input {
            if escaped {
                current.append(character); started = true; escaped = false; continue
            }
            // Inside single quotes a backslash is literal, matching shell word-splitting.
            if character == "\\" && quote != "'" {
                escaped = true; started = true; continue
            }
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                started = true
                continue
            }
            if character == "'" || character == "\"" {
                quote = character; started = true; continue
            }
            if isSeparator(character) {
                if started { tokens.append(current); current = ""; started = false }
                continue
            }
            current.append(character); started = true
        }
        if started { tokens.append(current) }
        return tokens
    }

    /// Global `-c` overrides applied to every invocation, ahead of the subcommand.
    /// They neutralise repo-configured programs git would execute (`diff.external`, `core.fsmonitor`).
    /// Passed as pre-subcommand `-c` rather than flags because a later flag in `args` could re-enable them.
    static let hardening: [String] = [
        // Runs a program whenever git consults the index — including `status`, the one action
        // that takes no arguments at all.
        "-c", "core.fsmonitor=",
        // Runs a program for every file diffed, on a bare `diff`, with no opt-in flag needed.
        "-c", "diff.external=",
        // Nothing here should ever fire a repo-supplied hook.
        "-c", "core.hooksPath=/dev/null",
        // git only pages onto a tty and `ProcessRunner` hands it a pipe, so this changes
        // nothing today — it removes the dependency on that remaining true.
        "-c", "core.pager=cat",
    ]

    // Why: without it `status` can rewrite `.git/index` under `index.lock`,
    // making a concurrent user `git commit` or `git add` fail.
    /// Environment overrides for every git process the app runs (agent tool, Git Changes panel, locator).
    /// `TERM=dumb` keeps colour escapes out of parsed output.
    /// `GIT_OPTIONAL_LOCKS=0` stops a read-only `git status` from taking the index lock.
    static let environmentOverrides: [String: String] = [
        "TERM": "dumb",
        "GIT_OPTIONAL_LOCKS": "0",
    ]

    /// `base` (the inherited environment) with `environmentOverrides` applied on top — an inherited
    /// `GIT_OPTIONAL_LOCKS=1` or `TERM=xterm-256color` must not win.
    static func environment(inheriting base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        base.merging(environmentOverrides) { _, override in override }
    }

    /// Flags that suppress repo-nominated diff programs, passed on every diff-family action.
    /// `hardening` is not enough: a repo can name its own diff driver, which no fixed `-c` can empty.
    /// Passed before the caller's `args`; both flags are also in `deniedAnywhere` so they cannot be re-enabled.
    static let diffProgramSuppression: [String] = ["--no-ext-diff", "--no-textconv"]

    /// Options refused for every action, because argv stops the shell but not git's own option parser.
    /// Covers file writes (`--output`), arbitrary reads (`--no-index`, `--contents`) and re-enabling repo programs.
    /// A denylist is the second layer and inherently incomplete; `hardening` makes code execution unreachable.
    static let deniedAnywhere: Set<String> = [
        "--output", "--no-index", "--contents", "--ext-diff", "--textconv",
    ]

    /// Options refused for `branch`, which runs in list mode (`-a`); these would rename, delete or write config/refs.
    /// Scoped to `branch` because `-c`, `-C` and `-t` mean something harmless elsewhere (e.g. `git log -c`).
    static let deniedForBranch: Set<String> = [
        "-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy",
        "-u", "--set-upstream-to", "--unset-upstream", "--edit-description",
        "-f", "--force", "-t", "--track", "--create-reflog",
    ]

    // Why: prefix matching is deliberately over-broad (ambiguous abbreviations are refused too); short options stay exact.
    /// Returns a refusal message when `tokens` contain a denied option for `action`, else nil.
    /// Matches the option name (before any `=`); long options match by prefix because git accepts abbreviations.
    static func rejectionReason(action: String, tokens: [String]) -> String? {
        let denied = deniedAnywhere.union(action == "branch" ? deniedForBranch : [])
        for token in tokens where token.hasPrefix("-") {
            let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            let hit = denied.first { candidate in
                guard candidate.hasPrefix("--") else { return candidate == name }   // short: exact
                guard name.hasPrefix("--"), name.count > 2 else { return false }
                return candidate.hasPrefix(name)                                    // long: prefix
            }
            if let hit {
                return "Error: option '\(name)' is not permitted"
                    + (hit == name ? "" : " (it abbreviates '\(hit)')")
                    + " — git is read-only and confined to the repository. Remove it and retry."
            }
        }
        return nil
    }

    static func resolve(action: String, repoPath: String, extraArgs: String) -> GitCommandResolution {
        // `-C <path>` as two argv elements: the path is data, never part of a command string.
        let base = ["-C", repoPath] + hardening
        let extra = tokenize(extraArgs)

        // Rejected before the action switch so an unknown action cannot probe which options a subcommand accepts.
        if let reason = rejectionReason(action: action, tokens: extra) {
            return .error(reason)
        }

        // Suppress repo-nominated diff drivers on every action that renders file content; `extra` denies both flags so
        // a caller cannot countermand them.
        switch action {
        case "status":
            return .argv(base + ["status", "--short"])
        case "log":
            return .argv(base + ["log"] + diffProgramSuppression + (extra.isEmpty ? ["-n", "10", "--oneline"] : extra))
        case "diff":
            return .argv(base + ["diff"] + diffProgramSuppression + extra)
        case "branch":
            return .argv(base + ["branch", "-a"] + extra)
        case "stash_list":
            return .argv(base + ["stash", "list"])
        case "blame":
            // Checked AFTER tokenising, so whitespace-only `args` is caught here rather than
            // reaching git as `blame` with no file and failing with a less useful message.
            guard !extra.isEmpty else {
                return .error("Error: 'args' must contain the filename for blame.")
            }
            return .argv(base + ["blame"] + diffProgramSuppression + extra)
        case "show":
            return .argv(base + ["show"] + diffProgramSuppression + (extra.isEmpty ? ["HEAD"] : extra) + ["--stat"])
        default:
            return .error("Error: Unknown git action '\(action)'. Use status/log/diff/branch/stash_list/blame/show.")
        }
    }
}

struct GitTool: DevgenticTool {
    let name = "git"
    let category = "Developer & Diagnostics"
    let description = "Performs Git operations with structured output: status, log, diff, branch, stash, and blame."

    struct Arguments: Decodable, Sendable {
        let action: String
        let path: String?
        let args: String?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            var foundAction: String? = nil
            for key in ["action", "command", "cmd", "op"] {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundAction = val
                    break
                }
            }
            guard let a = foundAction else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'action'"))
            }
            self.action = a
            self.path = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "path")!))
            self.args = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "args")!))
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Git action: 'status', 'log', 'diff', 'branch', 'stash_list', 'blame', 'show'"),
                ("path", "string", "Repository path. Required — pass the project root."),
                ("args", "string", "Additional arguments (e.g., '-n 5' for log, filename for blame)")
            ],
            required: ["action", "path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        guard let rawPath = arguments.path, !rawPath.isEmpty else {
            return "Error: 'path' is required. Pass the project root (repository path)."
        }
        let repoPath = (rawPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: repoPath) else {
            return "Error: path '\(repoPath)' does not exist."
        }
        let extraArgs = arguments.args ?? ""

        let resolution = GitCommandBuilder.resolve(action: arguments.action, repoPath: repoPath, extraArgs: extraArgs)
        let gitArgv: [String]
        switch resolution {
        case .argv(let argv):
            gitArgv = argv
        case .error(let msg):
            // Logged because a refusal is otherwise visible only to the model, leaving operators no trace of the denied option.
            logger.notice("[GIT_DENY] action='\(arguments.action)' refused — \(msg) | args: \(extraArgs)")
            return msg
        }

        do {
            // Invoked directly, never through `zsh -c`; `ProcessRunner` drains stdout and stderr concurrently.
            // The environment comes from `GitCommandBuilder.environment`, shared with the Git Changes panel.
            let run = try ProcessRunner.run(executable: "/usr/bin/git", arguments: gitArgv,
                                            environment: GitCommandBuilder.environment())

            // "Error:"-prefixed so `ToolExecutionMediator.isSemanticFailure` classifies it as a failure.
            // A non-zero exit counts as failure even when stderr is empty.
            guard run.succeeded else {
                let detail = run.standardError.isEmpty
                    ? (run.standardOutput.isEmpty ? "(no output on stdout or stderr)" : run.standardOutput)
                    : run.standardError
                return "Error: git \(arguments.action) failed (exit \(run.exitCode))\n\(detail)"
            }

            let maxOutput = 6000
            let output = run.standardOutput
            let result = output.count > maxOutput ? String(output.prefix(maxOutput)) + "\n...[Truncated]" : output

            return "git \(arguments.action):\n\(result)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
