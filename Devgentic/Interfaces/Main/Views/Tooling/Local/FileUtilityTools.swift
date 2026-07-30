//
//  FileUtilityTools.swift
//  Devgentic
//

import Foundation
import CommonCrypto

// MARK: - Grep Files Tool

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

        var grepArgs = ["-rn", "--include=*"]
        if let ext = arguments.file_extension {
            grepArgs = ["-rn", "--include=*.\(ext)"]
        }
        grepArgs += [arguments.pattern, expandedPath]

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
            return "Grep error: \(error.localizedDescription)"
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
            let output = try ProcessRunner.run(process).standardOutput

            if output.isEmpty {
                return "Files are identical."
            }

            let maxOutput = 6000
            let truncated = output.count > maxOutput ? String(output.prefix(maxOutput)) + "\n...[Truncated]" : output
            return "Diff:\n\(truncated)"
        } catch {
            return "Diff error: \(error.localizedDescription)"
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
