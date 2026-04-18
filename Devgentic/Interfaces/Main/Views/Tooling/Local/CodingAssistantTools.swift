//
//  CodingAssistantTools.swift
//  Devgentic
//
//  Industry-standard coding tools for autonomous LLM coding agents.
//  Implements patterns from modern AI coding assistants (Claude Code, Cursor, etc.)
//

import Foundation

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

        // Fallback: whitespace-normalized single-line match
        let normalizedSearch = oldString.trimmingCharacters(in: .whitespaces)
        let lines = content.components(separatedBy: "\n")

        for (lineIdx, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == normalizedSearch {
                var mutableLines = lines
                mutableLines[lineIdx] = newString
                return .applied(newContent: mutableLines.joined(separator: "\n"))
            }
        }

        return .notFound
    }
}

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
        return SchemaBuilder.object(
            properties: [
                ("file_path", "string", "Absolute or relative path to the file to edit."),
                ("old_string", "string", "The exact code block to find and replace. Must be unique in the file. Include enough surrounding context lines to ensure uniqueness."),
                ("new_string", "string", "The new code to replace old_string with. Use empty string to delete the matched block."),
                ("edits", "array", "Array of {old_string, new_string} objects for multiple atomic edits in one call. Takes precedence over top-level old_string/new_string.")
            ],
            required: ["file_path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let expandedPath = (arguments.file_path as NSString).expandingTildeInPath
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
        let resolvedPath = (rawPath as NSString).expandingTildeInPath
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

        args.append(arguments.pattern)
        args.append(resolvedPath)

        // Check if rg (ripgrep) is available, fallback to grep
        let rgPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/rg") ? "/opt/homebrew/bin/rg"
            : FileManager.default.fileExists(atPath: "/usr/local/bin/rg") ? "/usr/local/bin/rg"
            : nil

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let rgPath = rgPath {
            process.executableURL = URL(fileURLWithPath: rgPath)
            process.arguments = args
        } else {
            // Fallback to grep -rn
            var grepArgs = ["-rn", "--color=never"]
            if !(arguments.case_sensitive ?? true) { grepArgs.append("-i") }
            if arguments.whole_word ?? false { grepArgs.append("-w") }
            if arguments.files_only ?? false { grepArgs.append("-l") }
            if let glob = arguments.glob {
                grepArgs += ["--include", glob]
            }
            grepArgs.append(arguments.pattern)
            grepArgs.append(resolvedPath)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = grepArgs
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Error running search: \(error.localizedDescription)"
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let rawOutput = String(data: data, encoding: .utf8) ?? ""

        if rawOutput.isEmpty {
            return "No matches found for '\(arguments.pattern)'."
        }

        // Truncate to max_results matches
        let lines = rawOutput.components(separatedBy: "\n")
        var matchCount = 0
        var truncatedLines: [String] = []
        var truncated = false

        for line in lines {
            if arguments.files_only ?? false {
                matchCount += 1
            } else if !line.isEmpty && !line.hasPrefix("--") {
                matchCount += 1
            }
            if matchCount > maxResults {
                truncated = true
                break
            }
            truncatedLines.append(line)
        }

        var result = truncatedLines.joined(separator: "\n")
        if truncated {
            result += "\n\n[Truncated: >\(maxResults) matches. Refine your pattern or glob to narrow results.]"
        }

        // Cap total output size
        let maxOutput = 8000
        if result.count > maxOutput {
            result = String(result.prefix(maxOutput)) + "\n...[Output truncated at \(maxOutput) chars]"
        }

        return "\(result)\n(\(matchCount) match\(matchCount == 1 ? "" : "es"))"
    }
}

// MARK: - Glob Files Tool (File Pattern Matching)

struct GlobFilesTool: DevgenticTool {
    let name = "glob_files"
    let category = "Coding Assistant"
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
        let basePath = (rawPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: basePath) else {
            return "Error: path '\(basePath)' does not exist."
        }
        let maxResults = arguments.max_results ?? 100

        // Use find + shell glob for pattern matching
        let process = Process()
        let outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")

        let pattern = arguments.pattern
        var cmd: String

        if pattern.contains("**") {
            // Recursive glob via find
            let filePattern = pattern.replacingOccurrences(of: "**/", with: "")
            cmd = "find \"\(basePath)\" -type f -name \"\(filePattern)\" ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.build/*' ! -path '*/DerivedData/*' 2>/dev/null | head -\(maxResults)"
        } else if pattern.contains("/") {
            // Path-specific pattern
            cmd = "find \"\(basePath)\" -type f -path '*/\(pattern)' ! -path '*/.git/*' ! -path '*/node_modules/*' 2>/dev/null | head -\(maxResults)"
        } else {
            // Simple filename pattern
            cmd = "find \"\(basePath)\" -type f -name \"\(pattern)\" ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.build/*' ! -path '*/DerivedData/*' 2>/dev/null | head -\(maxResults)"
        }

        process.arguments = ["-c", cmd]
        process.standardOutput = outPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.isEmpty {
            return "No files found matching '\(arguments.pattern)' in \(basePath)."
        }

        let files = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var result = "Found \(files.count) file(s) matching '\(arguments.pattern)':\n"
        result += files.joined(separator: "\n")

        if files.count >= maxResults {
            result += "\n\n[Truncated at \(maxResults) results. Refine your pattern to narrow results.]"
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
        let basePath = (rawPath as NSString).expandingTildeInPath
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
            let rgPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/rg") ? "/opt/homebrew/bin/rg"
                : FileManager.default.fileExists(atPath: "/usr/local/bin/rg") ? "/usr/local/bin/rg"
                : nil

            let process = Process()
            let outPipe = Pipe()
            process.standardOutput = outPipe

            if let rgPath = rgPath {
                process.executableURL = URL(fileURLWithPath: rgPath)
                var args = ["-n", "--no-heading", "--color=never", "-B", "1", "-A", "5"]
                if glob != "*" {
                    args += ["--glob", glob]
                }
                args += [pattern, basePath]
                process.arguments = args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
                var args = ["-rn", "--color=never", "-A", "5"]
                if glob != "*" {
                    args += ["--include", glob]
                }
                args += ["-E", pattern, basePath]
                process.arguments = args
            }

            do {
                try process.run()
                process.waitUntilExit()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
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
    let description = "Executes a shell command with advanced options: configurable timeout, background execution, working directory, and intelligent output truncation (preserves first and last lines for tracebacks)."

    struct Arguments: Decodable, Sendable {
        let command: String
        let working_directory: String?
        let timeout_seconds: Int?
        let background: Bool?

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
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("command", "string", "The shell command to execute."),
                ("working_directory", "string", "Working directory for command execution. Required — pass the project root or a specific subpath."),
                ("timeout_seconds", "integer", "Maximum execution time in seconds (default 30, max 300). Process is killed on timeout."),
                ("background", "boolean", "Run in background and return immediately with a job ID (default false).")
            ],
            required: ["command", "working_directory"]
        )
    }

    // MARK: - Testable Safety Guard

    /// Intelligent output truncation: keeps head + tail lines for tracebacks, then hard char cap.
    static func truncateOutput(_ output: String, maxLines: Int = 1000, maxChars: Int = 8000) -> String {
        var result = output
        let outputLines = result.components(separatedBy: "\n")
        if outputLines.count > maxLines {
            let headCount = maxLines / 2
            let tailCount = maxLines / 2
            let headLines = Array(outputLines.prefix(headCount))
            let tailLines = Array(outputLines.suffix(tailCount))
            result = headLines.joined(separator: "\n")
                + "\n\n[... \(outputLines.count - maxLines) lines truncated ...]\n\n"
                + tailLines.joined(separator: "\n")
        }
        if result.count > maxChars {
            result = String(result.prefix(maxChars)) + "\n...[Truncated at \(maxChars) chars]"
        }
        return result
    }

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

    func call(arguments: Arguments) async throws -> String {
        // Safety: block destructive commands
        if Self.isDestructiveCommand(arguments.command) {
            return "Error: Command blocked by safety filter. Destructive system commands are not permitted."
        }

        guard let rawWD = arguments.working_directory, !rawWD.isEmpty else {
            return "Error: 'working_directory' is required. Pass the project root or a specific subpath."
        }
        let expandedWD = (rawWD as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedWD) else {
            return "Error: working_directory '\(expandedWD)' does not exist."
        }

        let timeout = min(arguments.timeout_seconds ?? 30, 300)

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", arguments.command]
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.currentDirectoryURL = URL(fileURLWithPath: expandedWD)

        if arguments.background ?? false {
            do {
                try process.run()
                return "Command launched in background (PID: \(process.processIdentifier))."
            } catch {
                return "Error launching background command: \(error.localizedDescription)"
            }
        }

        do {
            try process.run()
        } catch {
            return "Error: \(error.localizedDescription)"
        }

        // Timeout enforcement via structured concurrency
        nonisolated(unsafe) let detachedProcess = process
        nonisolated(unsafe) let detachedOutPipe = outPipe
        nonisolated(unsafe) let detachedErrPipe = errPipe

        let timedOut = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            nonisolated(unsafe) var resumed = false
            DispatchQueue.global().async {
                detachedProcess.waitUntilExit()
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: true)
            }
        }

        if timedOut {
            process.terminate()
            return "Error: Command timed out after \(timeout)s and was terminated."
        }

        let stdoutData = detachedOutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = detachedErrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus

        // Combine stdout + stderr
        var output = stdout
        if !stderr.isEmpty {
            output += (output.isEmpty ? "" : "\n") + "[stderr]\n" + stderr
        }

        output = Self.truncateOutput(output)

        return "Exit code: \(exitCode)\n\(output)"
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
        let expandedPath = (arguments.file_path as NSString).expandingTildeInPath
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
        let expandedPath = (arguments.file_path as NSString).expandingTildeInPath

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
    let name = "codebase_map"
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
        let basePath = (rawPath as NSString).expandingTildeInPath
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
