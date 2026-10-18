// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodingAssistantTools.swift
//  Devgentic
//
//  Created by Raj Singh.
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

/// Pure logic for applying a search-and-replace edit to content, with no file I/O or logging.
enum EditMatcher {
    static func applyEdit(content: String, oldString: String, newString: String) -> EditMatchResult {
        let occurrences = content.components(separatedBy: oldString).count - 1

        if occurrences == 1 {
            return .applied(newContent: content.replacingOccurrences(of: oldString, with: newString))
        } else if occurrences > 1 {
            return .ambiguous(occurrences: occurrences)
        }

        // Fallback: whitespace-normalized single-line match, so an `old_string` with different indentation still matches.
        // Ambiguous matches are refused, the line's indent is re-applied, and `\r` is trimmed for CRLF files.
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

        // Leading whitespace of the replaced line. An empty `newString` is a deletion and stays empty; a `newString` that
        // starts with whitespace is left alone.
        let indent = String(lines[lineIdx].prefix { $0 == " " || $0 == "\t" })
        var replacement: String
        if newString.isEmpty || newString.hasPrefix(" ") || newString.hasPrefix("\t") {
            replacement = newString
        } else {
            replacement = indent + newString
        }

        // Re-attaches the line's own carriage return so a CRLF file does not end up with mixed line endings.
        if lines[lineIdx].hasSuffix("\r") && !replacement.hasSuffix("\r") {
            replacement += "\r"
        }

        var mutableLines = lines
        mutableLines[lineIdx] = replacement
        return .applied(newContent: mutableLines.joined(separator: "\n"))
    }
}

// MARK: - Search Binary Resolution

// Why: a type rather than a function because of `discoveryOverride`: a test machine has one binary, so the other branch
// would otherwise never be covered.
/// Which search program the code-search tools run: ripgrep when installed, `/usr/bin/grep` otherwise. The two differ
/// in regex dialect, flags and `-c` output shape, so both paths ship and must work.
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

    /// Test-only; nil in production and never written by app code, which only reads `ripgrepPath`. `nonisolated(unsafe)`
    /// because a test sets it once before the call it affects.
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

/// The number of matches a search found, as opposed to the number of lines it printed (which differs when context is
/// on). Uses `-c` (`<path>:<count>` per file, summed) at the cost of a second invocation, so callers use it only when
/// context is on.
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

// MARK: - Search Exit Status

// Why: an empty stdout covers both "no matches" and a rejected pattern; reporting the latter as no matches makes the
// agent believe the code is absent.
/// What a grep/ripgrep run reported, read from its exit status rather than from whether it printed anything. 0 =
/// matches, 1 = none, 2 = error; exit 2 with non-empty stdout keeps the output, and an empty stdout with another
/// status is an error with a neutral message.
enum SearchRunReport: Equatable {
    /// Lines to show. `incompleteNote` is set when the program also reported an error, so the
    /// result may be missing matches.
    case output(String, incompleteNote: String?)
    /// The program searched and found nothing.
    case noMatches
    /// The program reported an error and printed no results. `message` is model-facing.
    case failed(message: String)

    /// Lines of the program's stderr quoted back to the model. A pattern error is one to four
    /// lines; a permission flood over a home directory is thousands.
    static let maxQuotedErrorLines = 6

    static func interpret(_ run: ProcessRunner.Result, program: String, tool: String, pattern: String? = nil) -> SearchRunReport {
        let hasOutput = !run.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if run.exitCode == 0 || run.exitCode == 1 {
            return hasOutput ? .output(run.standardOutput, incompleteNote: nil) : .noMatches
        }

        let reason = quotedError(run.standardError, program: program)
        guard hasOutput else {
            logger.warning("[CODESEARCH] \(tool): \(program) exited \(run.exitCode) with no results. CONSEQUENCE: reported to the model as an error, not as 'No matches' — an empty result from a failed search is not evidence the pattern is absent.")
            return .failed(message: "Error: \(program) reported an error (exit \(run.exitCode)) and returned no results, so this is NOT a \"no matches\" result. \(reason)\nFix the pattern or narrow the path, then search again." + (pattern.flatMap(globHint) ?? ""))
        }
        logger.warning("[CODESEARCH] \(tool): \(program) exited \(run.exitCode) but printed results. CONSEQUENCE: the results are shown with a note that the search was incomplete.")
        return .output(run.standardOutput, incompleteNote: "[Search incomplete: \(program) reported an error (exit \(run.exitCode)), so matches may be missing. \(reason)]")
    }

    /// Returns a filename-glob hint when the pattern starts with `*`, which cannot be a regular expression.
    static func globHint(for pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("*") else { return nil }
        let glob = trimmed.hasPrefix("**/") ? trimmed : "**/" + trimmed
        return "\n'\(trimmed)' is a filename glob, not a regular expression: these search tools match file CONTENTS. To find files by name, use glob_files with pattern \"\(glob)\"."
    }

    /// The program's own words, capped. Blank lines are dropped but leading spaces are kept —
    /// ripgrep points at the offending character with a caret aligned under the pattern.
    private static func quotedError(_ standardError: String, program: String) -> String {
        let lines = standardError
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return "\(program) gave no reason." }
        var quoted = lines.prefix(maxQuotedErrorLines).map { String($0.prefix(300)) }
        if lines.count > maxQuotedErrorLines {
            quoted.append("(+\(lines.count - maxQuotedErrorLines) more line\(lines.count - maxQuotedErrorLines == 1 ? "" : "s"))")
        }
        return "\(program) said:\n" + quoted.joined(separator: "\n")
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
            for key in ToolPathKeys.codingFile {
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
        // `edits` carries objects, but `SchemaBuilder.object` declares every array as strings; the declared item type is
        // what providers validate calls against (see `edit_code_batch`).
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

        // Why: a pattern beginning with `-` would otherwise be read as the search program's own flag (`grep -f`, ripgrep
        // `--pre`); argv stops the shell, not the callee's parser.
        // `--` ends option parsing.
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
            // Fallback to grep with `-E` (extended regex), the dialect ripgrep speaks. Grep's default is basic regex, which
            // would make the same pattern match on one machine and not another.
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

        // Search programs write one "Permission denied" line per unreadable directory to stderr; an unread stderr pipe would
        // fill past 64 KB and hang the search.
        let run: ProcessRunner.Result
        do {
            run = try ProcessRunner.run(process)
        } catch {
            return "Error running search: \(error.localizedDescription)"
        }

        // Read the exit status, not just stdout — see `SearchRunReport`.
        let rawOutput: String
        let incompleteNote: String?
        switch SearchRunReport.interpret(run, program: rgPath == nil ? "grep" : "ripgrep", tool: name, pattern: arguments.pattern) {
        case .failed(let message):
            return message
        case .noMatches:
            return "No matches found for '\(arguments.pattern)'."
        case .output(let output, let note):
            rawOutput = output
            incompleteNote = note
        }

        // `max_results` bounds the number of printed lines, not matches: with context on, one match prints up to 2N+1 lines.
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

        // Counts real matches. Only worth a second invocation when context is on, the only case where printed lines and
        // matches differ.
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
        let summary = "\(result)\n(\(reportedCount) \(Self.pluralise(noun, count: reportedCount)))"
        return incompleteNote.map { "\(summary)\n\($0)" } ?? summary
    }

    /// Returns the noun with the right plural form: "1 match" / "2 matches", "1 file" / "2 files".
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

        // Why: `pattern` and `path` come from the model; with argv each is one argument whatever it contains, so there is no
        // shell parser to escape from.
        // Runs `find` directly, never through a shell.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")

        let pattern = arguments.pattern
        // Heavy directories are pruned rather than filtered afterwards: `-prune` never enters `node_modules`, while `!
        // -path` still descends into it.
        var pruneNames = ["-name", ".git", "-o", "-name", "node_modules"]
        let matchPredicate: [String]

        if pattern.contains("**") {
            pruneNames += ["-o", "-name", ".build", "-o", "-name", "DerivedData"]
            matchPredicate = ["-name", pattern.replacingOccurrences(of: "**/", with: "")]
        } else if pattern.contains("/") {
            // Path-shaped patterns keep the narrower prune set so the set of found files does not change.
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
            // stderr is ignored rather than redirected: `find` reports unreadable directories there and exits non-zero, which is
            // not a search failure.
            output = try ProcessRunner.run(process).standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        if output.isEmpty {
            return "No files found matching '\(arguments.pattern)' in \(basePath)."
        }

        // The result limit is applied here, and the reported count is the number that matched, so an exact-fit result is not
        // mistaken for truncation.
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
        var failures: [String] = []
        var incompleteNotes: [String] = []

        for (pattern, glob) in patterns {
            let rgPath = SearchBinary.ripgrepPath

            let process = Process()

            if let rgPath = rgPath {
                process.executableURL = URL(fileURLWithPath: rgPath)
                var args = ["-n", "--no-heading", "--color=never", "-B", "1", "-A", "5"]
                if glob != "*" {
                    args += ["--glob", glob]
                }
                // `--` ends option parsing: the pattern is built from a model-supplied `symbol`, and a leading `-` would reach
                // ripgrep's own parser. See `code_search`.
                args += ["--", pattern, basePath]
                process.arguments = args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
                // `-E` is part of the seed so a source scan can verify every grep fallback requests the same dialect. See
                // `code_search`.
                var args = ["-rnE", "--color=never", "-A", "5"]
                if glob != "*" {
                    args += ["--include", glob]
                }
                args += ["--", pattern, basePath]
                process.arguments = args
            }

            // ProcessRunner drains stdout AND stderr concurrently; this site read the pipe only
            // after waitUntilExit(), which hangs once output passes the ~64 KB buffer.
            let run: ProcessRunner.Result
            do {
                run = try ProcessRunner.run(process)
            } catch {
                // A search that never ran is reported as an error instead of "No definition found".
                failures.append("Error running search: \(error.localizedDescription)")
                continue
            }

            // The symbol is placed inside a regex, so characters like `(` or `*` can make the program reject it (exit 2, empty
            // stdout); read the exit status, not just stdout.
            switch SearchRunReport.interpret(run, program: rgPath == nil ? "grep" : "ripgrep", tool: name) {
            case .failed(let message):
                failures.append(message)
            case .noMatches:
                break
            case .output(let output, let note):
                allResults.append(output.trimmingCharacters(in: .whitespacesAndNewlines))
                if let note { incompleteNotes.append(note) }
            }
        }

        if allResults.isEmpty {
            if let failure = failures.first {
                // Only when the symbol itself carries regex syntax — the same exit 2 also means
                // "unreadable paths", where this advice would be wrong.
                let regexSyntax = Set("()[]{}?*+.|^$\\")
                guard symbol.contains(where: regexSyntax.contains) else { return failure }
                return failure + "\nfind_definition places `symbol` inside a regular expression — pass a bare identifier, without ( ) [ ] { } ? * + . | ^ $ or \\."
            }
            return "No definition found for '\(symbol)'\(arguments.language != nil ? " in \(arguments.language!) files" : "")."
        }

        var result = allResults.joined(separator: "\n---\n")

        let maxOutput = 8000
        if result.count > maxOutput {
            result = String(result.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars]"
        }

        // A pattern that failed while another found definitions still leaves a gap — say so.
        let notes = incompleteNotes + failures
        let suffix = notes.isEmpty ? "" : "\n" + notes.joined(separator: "\n")
        return "Definitions for '\(symbol)':\n\(result)\(suffix)"
    }
}

// MARK: - Batch Command Tool (Multi-Step Shell Execution)

struct BatchCommandTool: DevgenticTool {
    let name = "batch_command"
    let category = "Coding Assistant"
    /// Bounds itself at `timeout_seconds` (≤ `BatchCommandTool.maxTimeoutSeconds`) and returns the
    /// partial output — so the dispatcher's timeout sits just above that ceiling (Contract dec. 2).
    var selfBoundCeiling: TimeInterval? { TimeInterval(BatchCommandTool.maxTimeoutSeconds) }
    let description = "Executes a shell command with advanced options: configurable timeout, background execution, and working directory. Output is returned in full; if it is larger than the room left in the model's context, the middle is omitted (start and end kept) with a note saying so."

    /// Scopes background tasks to the conversation that started them, so `bg_1` is per conversation and one conversation
    /// cannot poll or stop another's build. Optional because the catalogue builds every tool with `nil` for Library
    /// metadata; a nil id means a background task cannot be registered and `call` refuses.
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
                ("timeout_seconds", "integer", "Maximum execution time in seconds, max 1800. Defaults to 1800 (the maximum) in the foreground and in the background. The process is killed on timeout, but any output it produced first is still returned."),
                // The description says when background mode is right, since the model chooses the mode at the moment it reads it.
                ("task_name", "string", "Optional short label shown to the user instead of the raw command."),
                ("background", "boolean", "Default false. Keep it false for anything whose result you need — the call waits and returns the output, and timeout_seconds goes up to 1800 for a slow build. Set it true ONLY to leave something running that you will not wait for, such as a dev server; it returns a task id instead of output, and you must call get_task_output to see anything.")
            ],
            required: ["command", "working_directory"]
        )
    }

    // MARK: - Timeout Bounds

    /// Applied to a foreground call that names no timeout: the full ceiling, since Stop and every outer timeout kill a
    /// foreground command.
    static let defaultTimeoutSeconds = maxTimeoutSeconds

    /// Applied to a background call that names no timeout. The ceiling is the default because `background: true` already
    /// signals long work, and requiring `timeout_seconds` would hard-fail smaller models.
    static let defaultBackgroundTimeoutSeconds = maxTimeoutSeconds

    /// The ceiling a caller cannot exceed: 30 minutes, sized to fit a full build-and-test cycle. The tool dispatcher
    /// bounds a call at this plus 30 s (`selfBoundCeiling`), and enclosing turn or scheduled-run limits shorten it
    /// further (`ExecutionBudget`).
    static let maxTimeoutSeconds = 1800

    /// Returns the timeout actually applied; static so the clamp is testable without spawning a shell. A request above
    /// the ceiling is clamped, and a non-positive request is treated as unspecified, never as no limit.
    static func effectiveTimeout(_ requested: Int?, background: Bool = false) -> Int {
        guard let requested, requested > 0 else {
            return background ? defaultBackgroundTimeoutSeconds : defaultTimeoutSeconds
        }
        return min(requested, maxTimeoutSeconds)
    }

    // MARK: - Testable Safety Guard

    // Output leaves this tool whole; `ToolResultBudget.fit` later cuts it to the room actually free, keeping both ends
    // on line boundaries.

    /// A speed-bump against the best-known ways to destroy a machine by accident; not a security boundary.
    /// `batch_command` is a shell, so any command here can be respelled past the list; the real boundary is whether a
    /// profile grants the tool. See `ShellCommandGuard`.
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
    // One implementation shared by `batch_command`, `run_command` and `start_background_task`, so the guard attaches to
    // a capability rather than a tool name.

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

    /// How a foreground command ended, so a caller can classify the result without reading its text; `observation` is
    /// what the model is told in every case.
    enum ForegroundOutcome: Equatable {
        case finished(String)
        /// Killed at its own `timeout_seconds`.
        case timedOut(limit: Int, observation: String)
        /// Stopped before it finished — by the user, or because its run was stopped.
        case stopped(observation: String)

        var observation: String {
            switch self {
            case .finished(let text), .timedOut(_, let text), .stopped(let text): text
            }
        }
    }

    static func runForeground(command: String,
                              workingDirectory: String,
                              timeout: Int,
                              conversationID: UUID?,
                              name: String? = nil) async throws -> String {
        try await runForegroundOutcome(command: command, workingDirectory: workingDirectory, timeout: timeout,
                                       conversationID: conversationID, name: name).observation
    }

    static func runForegroundOutcome(command: String,
                                     workingDirectory: String,
                                     timeout: Int,
                                     conversationID: UUID?,
                                     name: String? = nil) async throws -> ForegroundOutcome {
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

        // Why: `waitUntilEnded` is a continuation with no cancellation handler, so without this a cancelled caller keeps waiting
        // for the full bound.
        // Stop hook: cancelling the caller stops the command, and the wait returns its partial output once the shell is
        // reaped (SIGTERM, SIGKILL after 2 s).
        let stopID = started.id
        let waited = await withTaskCancellationHandler {
            await registry.waitUntilEnded(conversationID: conversationID, taskID: stopID)
        } onCancel: {
            _ = registry.stop(conversationID: conversationID, taskID: stopID)
        }
        guard let ended = waited else {
            // Only if the conversation was deleted while the command ran — `discard` drops the record.
            return .stopped(observation: "Error: The command's record was removed while it ran (its conversation was deleted), so its output is unavailable.")
        }

        let data = (try? Data(contentsOf: ended.logURL)) ?? Data()
        let output = String(decoding: data, as: UTF8.self)

        switch ended.status {
        case .timedOut:
            // Partial output is returned rather than discarded: a command killed at the bound usually produced the evidence for
            // why it was slow.
            return .timedOut(limit: timeout, observation: output.isEmpty
                ? "Error: Command timed out after \(timeout)s and was killed. It produced no output."
                : "Error: Command timed out after \(timeout)s and was killed. Output before the kill:\n\(output)")
        case .stopped:
            return .stopped(observation: output.isEmpty
                ? "Error: The command was stopped before it finished (by the user, or because its run was stopped or ran out of time). It produced no output."
                : "Error: The command was stopped before it finished (by the user, or because its run was stopped or ran out of time). Output before it was stopped:\n\(output)")
        case .exited(let code):
            return .finished(ShellExitStatus.annotate(output, exitCode: code))
        case .running:
            // `waitUntilEnded` returns only after the shell exits, so this cannot be reached.
            logger.error("[BGPROC] conv \(conversationID.uuidString.prefix(8)) — \(ended.id) was reported as ended while its status is still running. CONSEQUENCE: its output is returned without an exit code.")
            return .finished(output)
        }
    }

    /// The path with no conversation to own the command, so no registry entry, card or log. Kept on
    /// `ProcessRunner` for callers that build the tool without a conversation.
    private static func runForegroundUnregistered(command: String, workingDirectory: String, timeout: Int) async throws -> ForegroundOutcome {
        let process = shell(command, in: workingDirectory)
        nonisolated(unsafe) let target = process
        let seconds = TimeInterval(timeout)

        // Runs off the cooperative pool: `ProcessRunner.run` is synchronous and `timeout` goes up to 1800 s, which would
        // park a worker thread.
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

        // Reported in the observation, not just the log: an incomplete capture looks like a command that printed less.
        if !run.result.outputComplete {
            output += "\n\n[note] This command left a background process holding its output stream. "
                + "Reading stopped when the command itself finished, so anything written after that is NOT shown above, "
                + "and the background process loses its output stream. Redirect it to keep its output: `cmd > log 2>&1 &`."
        }

        if run.timedOut {
            return .timedOut(limit: timeout, observation: output.isEmpty
                ? "Error: Command timed out after \(timeout)s and was killed. It produced no output."
                : "Error: Command timed out after \(timeout)s and was killed. Output before the kill:\n\(output)")
        }
        return .finished(ShellExitStatus.annotate(output, exitCode: run.result.exitCode))
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
                Read its output with get_task_output, end it early with stop_background_task.
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
            for key in ToolPathKeys.codingFile {
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
            for key in ToolPathKeys.codingFile {
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
        // Per-file noise filter for OS metadata files that are never useful to the agent and would eat the output budget on
        // deep trees.
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
