// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileUtilityTools.swift
//  Devgentic
//

import Foundation
import CommonCrypto
import os

private let logger = DGLogger(category: "FileUtilityTools")

// MARK: - Grep Files Tool (Deprecated — use CodeSearchTextTool)

@available(*, deprecated, message: "Use CodeSearchTextTool instead")
struct GrepFilesTool: DevgenticTool {
    let name = "grep_files"
    let category = "File System"
    let description = "Searches file contents using regex patterns within a directory. Returns matching lines with file paths and line numbers."

    struct Arguments: Decodable, Sendable {
        let pattern: String
        let path: String
        let file_extension: String?
        let max_results: Int?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            var foundPattern: String? = nil
            for key in ["pattern", "regex", "search", "query"] {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundPattern = val
                    break
                }
            }
            guard let p = foundPattern else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'pattern'"))
            }
            self.pattern = p

            var foundPath: String? = nil
            for key in ["path", "directory", "dir", "folder"] {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = val
                    break
                }
            }
            guard let d = foundPath else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'path'"))
            }
            self.path = d

            self.file_extension = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "file_extension")!))
            self.max_results = (try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "max_results")!))
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("pattern", "string", "Regex pattern to search for"),
                ("path", "string", "Directory path to search in"),
                ("file_extension", "string", "Filter by file extension (e.g. 'swift', 'py')"),
                ("max_results", "integer", "Max matching lines to return (default 50)")
            ],
            required: ["pattern", "path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let expandedPath = (arguments.path as NSString).expandingTildeInPath

        // `-E` — POSIX EXTENDED regex, not grep's default BASIC regex.
        //
        // This tool's description and its schema both promise "regex patterns", and a model
        // writes the dialect every sibling here speaks: `code_search` and the three
        // `code_search_*` splits run ripgrep, whose syntax is extended. Under BRE the ordinary
        // metacharacters `+ ? | ( )` are LITERALS and `\(` opens a GROUP — the exact inversion —
        // so `func [a-z]*\(` matched nothing and this tool answered "No matches found for …".
        //
        // That is the failure worth naming: not an error, an authoritative-sounding FALSE
        // NEGATIVE. An agent asked to find every call site is told there are none, and has no
        // signal that its pattern was reinterpreted. Same shape as the unindexed-scope miss
        // `fs_smart_search` grew a filesystem fallback to avoid. `find_definition`'s grep
        // fallback already passes `-E`; this puts the two in agreement.
        var grepArgs = ["-rnE", "--include=*"]
        if let ext = arguments.file_extension {
            grepArgs = ["-rnE", "--include=*.\(ext)"]
        }
        // `--` ends option parsing: without it a model-supplied `pattern` beginning with `-`
        // is read by grep as a flag, and `-f <path>` makes grep take its pattern list from an
        // arbitrary FILE. Argv stops the shell, not the callee's own option parser.
        grepArgs += ["--", arguments.pattern, expandedPath]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = grepArgs

        do {
            // `grep -rn` writes one "Permission denied" line per unreadable directory to
            // STDERR. This site attached stderr to a pipe it never read, so over a home
            // directory that buffer fills and grep blocks forever. ProcessRunner drains both.
            let output = try ProcessRunner.run(process).standardOutput

            if output.isEmpty {
                return "No matches found for '\(arguments.pattern)' in \(arguments.path)."
            }

            let maxResults = arguments.max_results ?? 50
            let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
            let limited = lines.prefix(maxResults)
            var result = "Found \(lines.count) matches"
            if lines.count > maxResults {
                result += " (showing first \(maxResults))"
            }
            result += ":\n\(limited.joined(separator: "\n"))"

            return "\(result)"
        } catch {
            return "Error: grep failed — \(error.localizedDescription)"
        }
    }
}

// MARK: - Diff Files Tool

struct DiffFilesTool: DevgenticTool {
    let name = "diff_files"
    let category = "File System"
    let description = "Compares two files and returns a unified diff showing the differences."

    struct Arguments: Decodable, Sendable {
        let file_a: String
        let file_b: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("file_a", "string", "Path to the first file"),
                ("file_b", "string", "Path to the second file")
            ],
            required: ["file_a", "file_b"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let pathA = (arguments.file_a as NSString).expandingTildeInPath
        let pathB = (arguments.file_b as NSString).expandingTildeInPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", pathA, pathB]

        do {
            // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe
            // only after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
            let run = try ProcessRunner.run(process)

            // `diff`'s exit status is a THREE-way answer, not a success flag:
            //   0 — the files are the same        1 — they differ        2 — trouble
            // where trouble is a missing, unreadable or otherwise unusable operand, reported on
            // STDERR with stdout left EMPTY.
            //
            // Reading only stdout collapsed 0 and 2 into the same empty string, so comparing a
            // file against a path that does not exist returned "Files are identical." — the tool
            // asserting two files match when one of them is not there, with the reason sitting
            // unread on the other stream. An agent that mistypes a path is told its comparison
            // SUCCEEDED and found no differences, which is worse than any error.
            //
            // Same class as the stdout-only reads already corrected in `preview_file`,
            // `dns_lookup`, `get_wifi_info` and `run_mac_shortcut`. `-1` is `ProcessRunner`'s
            // sentinel for a child that never reaped, so it is trouble too.
            guard run.exitCode == 0 || run.exitCode == 1 else {
                let detail = (run.standardError.isEmpty ? run.standardOutput : run.standardError)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                logger.error("""
                    [DIFF] diff exited \(run.exitCode) comparing '\(pathA)' and '\(pathB)' — \
                    an operand is missing or unreadable. Reported to the model as a failure \
                    rather than as "Files are identical.", which is what the previous \
                    stdout-only read returned. Detail: \(detail.isEmpty ? "(silent)" : detail)
                    """)
                return "Error: could not compare '\(arguments.file_a)' and '\(arguments.file_b)' "
                    + "(diff exit \(run.exitCode))\n"
                    + (detail.isEmpty ? "diff reported no reason." : detail)
            }

            let output = run.standardOutput
            if output.isEmpty {
                return "Files are identical."
            }

            let maxOutput = 6000
            let truncated = output.count > maxOutput ? String(output.prefix(maxOutput)) + "\n...[Truncated]" : output
            return "Diff:\n\(truncated)"
        } catch {
            // "Error:"-prefixed so `ToolExecutionMediator.isSemanticFailure` classifies it. The
            // previous "Diff error:" missed by one word — the sniffer tests `hasPrefix("error")`
            // — so a diff that failed to launch was recorded as a successful comparison. Exactly
            // the bug `git_tool` had.
            return "Error: diff failed — \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview File Tool

struct PreviewFileTool: DevgenticTool {
    let name = "preview_file"
    let category = "File System"
    let description = "Reads the first or last N lines of a file (head/tail) without loading the entire file."

    struct Arguments: Decodable, Sendable {
        let path: String
        let mode: String?
        let lines: Int?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var foundPath: String? = nil
            for key in ["path", "file", "filePath"] {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = val
                    break
                }
            }
            guard let p = foundPath else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing 'path'"))
            }
            self.path = p
            self.mode = (try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "mode")!))
            self.lines = (try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "lines")!))
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "Path to the file"),
                ("mode", "string", "'head' for first N lines (default) or 'tail' for last N lines"),
                ("lines", "integer", "Number of lines to read (default 20)")
            ],
            required: ["path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let expandedPath = (arguments.path as NSString).expandingTildeInPath
        let cmd = (arguments.mode ?? "head") == "tail" ? "/usr/bin/tail" : "/usr/bin/head"
        let lineCount = arguments.lines ?? 20

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cmd)
        process.arguments = ["-n", String(lineCount), expandedPath]

        do {
            // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe
            // only after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
            //
            // combinedOutput, not standardOutput: this site set `standardError = outPipe`,
            // so its single read returned both. `head`/`tail` write "No such file or
            // directory" and permission errors to stderr with empty stdout — reading stdout
            // alone renders an unreadable file as a successful preview of nothing.
            let output = try ProcessRunner.run(process).combinedOutput
            return "\(arguments.mode ?? "head") \(lineCount) lines of \(arguments.path):\n\(output)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Get File Hash Tool

struct GetFileHashTool: DevgenticTool {
    let name = "get_file_hash"
    let category = "File System"
    let description = "Computes SHA256 or MD5 hash of a file for integrity verification."

    struct Arguments: Decodable, Sendable {
        let path: String
        let algorithm: String?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "Path to the file"),
                ("algorithm", "string", "'sha256' (default) or 'md5'")
            ],
            required: ["path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let expandedPath = (arguments.path as NSString).expandingTildeInPath
        let algo = (arguments.algorithm ?? "sha256").lowercased()

        // Invoked DIRECTLY, never through a shell. This site interpolated the caller's path
        // into `md5 -q "\(expandedPath)"` for `zsh -c` with NO validation of any kind — not
        // even an existence check — so a path containing a double quote closed it and ran the
        // remainder as commands. `path` is a tool argument supplied by the model.
        let executable: String
        var argv: [String]
        switch algo {
        case "md5":    executable = "/sbin/md5";      argv = ["-q", expandedPath]
        case "sha256": executable = "/usr/bin/shasum"; argv = ["-a", "256", expandedPath]
        default:
            return "Error: Unknown algorithm '\(algo)'. Use sha256 or md5."
        }

        do {
            let run = try ProcessRunner.run(executable: executable, arguments: argv)

            guard run.succeeded else {
                // `md5`/`shasum` report a missing or unreadable file on stderr. The shell form
                // discarded that (`awk` saw an empty pipe) and returned an empty hash, which
                // reads as success with a blank value.
                let detail = run.standardError.isEmpty ? run.standardOutput : run.standardError
                return "Error: could not hash '\(arguments.path)' (exit \(run.exitCode))\n"
                    + detail.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // `shasum` prints "<hash>  <filename>"; the pipeline used `awk '{print $1}'` to cut
            // it down. Taking the first whitespace-separated field here does the same without
            // needing a shell to host the pipe. `md5 -q` already prints the digest alone.
            let hash = run.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""

            return "\(algo.uppercased()): \(hash)\nFile: \(arguments.path)"
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
