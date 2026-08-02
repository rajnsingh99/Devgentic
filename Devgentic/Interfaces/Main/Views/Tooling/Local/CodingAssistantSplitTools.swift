//
//  CodingAssistantSplitTools.swift
//  Devgentic
//
//  Small-model-friendly split variants of edit_code / code_search / create_file.
//  Used exclusively by the Code interface — the originals remain for chat & workflow.
//
//  These tools are intentionally NOT registered in LocalToolManager, so they do not
//  appear in the Tool Library UI. They are wired directly via AgentConnect's
//  resolveNativeTool switch and surfaced only through CodeToolPreset.
//
//  Each tool carries a single intent and no behavior-changing boolean toggles —
//  so a small LLM cannot mis-set a knob and silently land in the wrong behavior.
//

import Foundation

// MARK: - edit_code_single

struct EditCodeSingleTool: DevgenticTool {
    let name = "edit_code_single"
    let category = "Coding Assistant"
    let description = "Applies ONE search-and-replace edit to a file. Finds the exact `old_string` and replaces it with `new_string`. `old_string` must appear exactly once in the file — include enough surrounding context for uniqueness. For multiple edits in the same file, use `edit_code_batch` instead."

    struct Arguments: Decodable, Sendable {
        let file_path: String
        let old_string: String
        let new_string: String

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
            guard let validPath = fp else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing 'file_path'"
                ))
            }
            self.file_path = validPath
            self.old_string = try container.decode(String.self, forKey: DynamicKey(stringValue: "old_string")!)
            self.new_string = try container.decode(String.self, forKey: DynamicKey(stringValue: "new_string")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("file_path", "string", "Absolute or relative path to the file to edit."),
                ("old_string", "string", "The exact code block to find and replace. Must appear exactly once in the file. Include enough surrounding context lines to guarantee uniqueness."),
                ("new_string", "string", "The new code to replace `old_string` with. Use an empty string to delete the matched block.")
            ],
            required: ["file_path", "old_string", "new_string"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return CodeEditApplier.applySingle(
            filePath: arguments.file_path,
            oldString: arguments.old_string,
            newString: arguments.new_string
        )
    }
}

// MARK: - edit_code_batch

struct EditCodeBatchTool: DevgenticTool {
    let name = "edit_code_batch"
    let category = "Coding Assistant"
    let description = "Applies MULTIPLE search-and-replace edits to one file in a single atomic call. Each edit's `old_string` must appear exactly once. Use this when you need to change several distinct regions of the same file in one step. For a single edit, use `edit_code_single`."

    struct Arguments: Decodable, Sendable {
        let file_path: String
        let edits: [EditBlock]

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
            guard let validPath = fp else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing 'file_path'"
                ))
            }
            self.file_path = validPath
            self.edits = try container.decode([EditBlock].self, forKey: DynamicKey(stringValue: "edits")!)
        }
    }

    var parameterSchema: ToolParameters {
        // `edits` is built by hand rather than through `SchemaBuilder.object`, which hardcodes
        // `items: ["type": "string"]` for every array. That is right for `tags` and `sourcePaths`
        // and WRONG here: this is an array of objects, and the machine-readable item type is what
        // a provider validates a tool call against — the prose in the description is not. A model
        // reading the schema literally would send an array of strings, which cannot decode.
        var properties = SchemaBuilder.object(
            properties: [
                ("file_path", "string", "Absolute or relative path to the file to edit.")
            ],
            required: []
        ).properties
        properties["edits"] = ToolParameterProperty(
            type: "array",
            description: "Array of `{old_string, new_string}` objects. Applied in order against the working copy. Each `old_string` must appear exactly once at the time it is applied.",
            items: ["type": "object"]
        )
        return ToolParameters(type: "object", properties: properties, required: ["file_path", "edits"])
    }

    func call(arguments: Arguments) async throws -> String {
        let pairs = arguments.edits.map { ($0.old_string, $0.new_string) }
        return CodeEditApplier.applyBatch(filePath: arguments.file_path, edits: pairs)
    }
}

// MARK: - code_search_text (loose content search)

struct CodeSearchTextTool: DevgenticTool {
    let name = "code_search_text"
    let category = "Coding Assistant"
    let description = "Searches file contents for a regex pattern — case-insensitive, substring-style. Returns matching lines with surrounding context. Use this for loose content searches like finding TODOs, keywords, or API usages. For exact symbol lookup, use `code_search_symbol`. To list files only, use `code_search_files`."

    struct Arguments: Decodable, Sendable {
        let pattern: String
        let path: String
        let glob: String?
        let max_results: Int?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("pattern", "string", "Regex or literal text to search for (e.g. 'TODO', 'import.*React')."),
                ("path", "string", "Directory or file path to search within. Required — pass the project root or a specific subpath."),
                ("glob", "string", "Optional file filter (e.g. '*.swift', '*.ts'). Narrows search scope."),
                ("max_results", "integer", "Maximum number of matches to return (default 50).")
            ],
            required: ["pattern", "path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return await RipgrepRunner.run(
            pattern: arguments.pattern,
            path: arguments.path,
            glob: arguments.glob,
            contextLines: 2,
            maxResults: arguments.max_results ?? 50,
            caseSensitive: false,
            wholeWord: false,
            filesOnly: false
        )
    }
}

// MARK: - code_search_symbol (exact symbol lookup)

struct CodeSearchSymbolTool: DevgenticTool {
    let name = "code_search_symbol"
    let category = "Coding Assistant"
    let description = "Finds exact occurrences of a symbol (function, class, struct, variable name). Case-sensitive, whole-word match only — so 'User' will not match 'Username'. Ideal for locating where a specific identifier is defined or used. For loose keyword search, use `code_search_text`."

    struct Arguments: Decodable, Sendable {
        let pattern: String
        let path: String
        let glob: String?
        let max_results: Int?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("pattern", "string", "The exact symbol name to look for (e.g. 'UserSession', 'handleLogin')."),
                ("path", "string", "Directory or file path to search within. Required — pass the project root or a specific subpath."),
                ("glob", "string", "Optional file filter (e.g. '*.swift', '*.ts')."),
                ("max_results", "integer", "Maximum number of matches to return (default 50).")
            ],
            required: ["pattern", "path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return await RipgrepRunner.run(
            pattern: arguments.pattern,
            path: arguments.path,
            glob: arguments.glob,
            contextLines: 0,
            maxResults: arguments.max_results ?? 50,
            caseSensitive: true,
            wholeWord: true,
            filesOnly: false
        )
    }
}

// MARK: - code_search_files (filenames only)

struct CodeSearchFilesTool: DevgenticTool {
    let name = "code_search_files"
    let category = "Coding Assistant"
    let description = "Returns the filenames (paths) of files that contain a given pattern, without the matching lines themselves. Useful when you only need to know WHICH files mention something, not WHERE. For content + context, use `code_search_text`."

    struct Arguments: Decodable, Sendable {
        let pattern: String
        let path: String
        let glob: String?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("pattern", "string", "Regex or literal text to look for."),
                ("path", "string", "Directory or file path to search within. Required — pass the project root or a specific subpath."),
                ("glob", "string", "Optional file filter (e.g. '*.swift', '*.ts').")
            ],
            required: ["pattern", "path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return await RipgrepRunner.run(
            pattern: arguments.pattern,
            path: arguments.path,
            glob: arguments.glob,
            contextLines: 0,
            maxResults: 200,
            caseSensitive: false,
            wholeWord: false,
            filesOnly: true
        )
    }
}

// MARK: - create_new_file (strict new)

struct CreateNewFileTool: DevgenticTool {
    let name = "create_new_file"
    let category = "Coding Assistant"
    let description = "Creates a brand-new file with the given content. Fails if a file already exists at that path — to intentionally replace an existing file, use `overwrite_file` instead. Creates parent directories as needed."

    struct Arguments: Decodable, Sendable {
        let file_path: String
        let content: String

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
            guard let validPath = fp else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing 'file_path'"
                ))
            }
            self.file_path = validPath
            self.content = try container.decode(String.self, forKey: DynamicKey(stringValue: "content")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("file_path", "string", "Absolute or relative path for the new file."),
                ("content", "string", "The complete file content to write.")
            ],
            required: ["file_path", "content"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return FileCreator.writeStrictNew(path: arguments.file_path, content: arguments.content)
    }
}

// MARK: - overwrite_file (explicit destructive)

struct OverwriteFileTool: DevgenticTool {
    let name = "overwrite_file"
    let category = "Coding Assistant"
    let description = "Replaces an existing file's contents entirely with new content. Use this ONLY when you intentionally want to discard the current contents. For partial edits, use `edit_code_single` / `edit_code_batch`. For creating a genuinely new file, use `create_new_file`."

    struct Arguments: Decodable, Sendable {
        let file_path: String
        let content: String

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
            guard let validPath = fp else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing 'file_path'"
                ))
            }
            self.file_path = validPath
            self.content = try container.decode(String.self, forKey: DynamicKey(stringValue: "content")!)
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("file_path", "string", "Absolute or relative path to the file to overwrite."),
                ("content", "string", "The new complete file content. The previous contents are discarded.")
            ],
            required: ["file_path", "content"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return FileCreator.writeOverwrite(path: arguments.file_path, content: arguments.content)
    }
}

// MARK: - Private helpers

/// Shared edit applier used by edit_code_single and edit_code_batch.
/// Delegates to `EditMatcher.applyEdit` for match semantics (exact → whitespace-normalized single-line fallback).
private enum CodeEditApplier {

    static func applySingle(filePath: String, oldString: String, newString: String) -> String {
        let expandedPath = FilePathResolver.resolve(filePath)
        let fileURL = URL(fileURLWithPath: expandedPath)

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return "Error: File not found at '\(expandedPath)'."
        }

        let content: String
        do {
            content = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }

        let result = EditMatcher.applyEdit(content: content, oldString: oldString, newString: newString)
        switch result {
        case .applied(let newContent):
            do {
                try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
                return "Applied edit to \(filePath)."
            } catch {
                return "Error writing file: \(error.localizedDescription)"
            }
        case .notFound:
            return "Error: old_string not found in '\(filePath)'. Read the file with `read_file` and ensure `old_string` is an exact substring with sufficient surrounding context."
        case .ambiguous(let occurrences):
            return "Error: old_string matches \(occurrences) locations in '\(filePath)'. Include more surrounding context to make the match unique."
        }
    }

    static func applyBatch(filePath: String, edits: [(old: String, new: String)]) -> String {
        let expandedPath = FilePathResolver.resolve(filePath)
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

        var appliedCount = 0
        var errors: [String] = []

        for (idx, edit) in edits.enumerated() {
            let match = EditMatcher.applyEdit(content: content, oldString: edit.old, newString: edit.new)
            switch match {
            case .applied(let newContent):
                content = newContent
                appliedCount += 1
            case .notFound:
                errors.append("Edit \(idx + 1): old_string not found. Ensure it is an exact substring of the current (post-prior-edits) file.")
            case .ambiguous(let occurrences):
                errors.append("Edit \(idx + 1): old_string matches \(occurrences) locations. Include more context to make it unique.")
            }
        }

        if appliedCount > 0 {
            do {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                return "Error writing file: \(error.localizedDescription)"
            }
        }

        var result = "Applied \(appliedCount)/\(edits.count) edit(s) to \(filePath)."
        if !errors.isEmpty {
            result += "\nErrors:\n" + errors.joined(separator: "\n")
        }
        return result
    }
}

/// Shared file writer used by create_new_file and overwrite_file.
private enum FileCreator {

    static func writeStrictNew(path: String, content: String) -> String {
        let expandedPath = FilePathResolver.resolve(path)
        let fileURL = URL(fileURLWithPath: expandedPath)
        let fm = FileManager.default

        if fm.fileExists(atPath: expandedPath) {
            return "Error: File already exists at '\(expandedPath)'. Use `overwrite_file` to intentionally replace it, or choose a different path."
        }

        return writeAtomically(url: fileURL, displayPath: path, content: content, verb: "Created")
    }

    static func writeOverwrite(path: String, content: String) -> String {
        let expandedPath = FilePathResolver.resolve(path)
        let fileURL = URL(fileURLWithPath: expandedPath)
        let existed = FileManager.default.fileExists(atPath: expandedPath)
        let verb = existed ? "Overwrote" : "Created"

        return writeAtomically(url: fileURL, displayPath: path, content: content, verb: verb)
    }

    private static func writeAtomically(url: URL, displayPath: String, content: String, verb: String) -> String {
        let parentDir = url.deletingLastPathComponent().path
        let fm = FileManager.default

        if !fm.fileExists(atPath: parentDir) {
            do {
                try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
            } catch {
                return "Error creating directory: \(error.localizedDescription)"
            }
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            let lineCount = content.components(separatedBy: "\n").count
            return "\(verb) file '\(displayPath)' (\(lineCount) lines, \(content.count) chars)."
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }
}

/// Shared ripgrep runner used by the three code_search_* variants.
/// Extracted so each variant can pin the behavior flags it wants without exposing
/// the underlying toggles to the LLM.
private enum RipgrepRunner {

    static func run(
        pattern: String,
        path: String,
        glob: String?,
        contextLines: Int,
        maxResults: Int,
        caseSensitive: Bool,
        wholeWord: Bool,
        filesOnly: Bool
    ) async -> String {
        guard !path.isEmpty else {
            return "Error: 'path' is required. Pass the project root or a specific subpath."
        }
        let resolvedPath = FilePathResolver.resolve(path)
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return "Error: path '\(resolvedPath)' does not exist."
        }

        let rgPath = SearchBinary.ripgrepPath

        let process = Process()

        if let rgPath = rgPath {
            var args: [String] = ["-n", "--no-heading", "--color=never"]
            if !filesOnly { args += ["-C", String(contextLines)] }
            if !caseSensitive { args.append("-i") }
            if wholeWord { args.append("-w") }
            if filesOnly { args.append("-l") }
            if let glob = glob { args += ["--glob", glob] }
            // `--` ends option parsing. `pattern` is model-supplied, and argv does not protect
            // the callee's own parser: a leading `-` reaches ripgrep, whose `--pre` names a
            // preprocessor COMMAND it executes. This runner backs the three `code_search_*`
            // tools, which are the ones a Code profile actually gets.
            args.append("--")
            args.append(pattern)
            args.append(resolvedPath)

            process.executableURL = URL(fileURLWithPath: rgPath)
            process.arguments = args
        } else {
            // `-E` — EXTENDED regex, so this fallback means the same thing ripgrep does. See the
            // note in `code_search`: grep's default BASIC dialect turns `+ ? | ( )` into
            // literals, so whether a pattern matches depended on whether ripgrep was installed.
            var grepArgs = ["-rnE", "--color=never"]
            if !caseSensitive { grepArgs.append("-i") }
            if wholeWord { grepArgs.append("-w") }
            if filesOnly { grepArgs.append("-l") }
            if let glob = glob { grepArgs += ["--include", glob] }
            grepArgs.append("--")            // as above; grep's `-f` reads a file as its pattern list
            grepArgs.append(pattern)
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
            return "No matches found for '\(pattern)'."
        }

        // `maxResults` bounds PRINTED LINES, not matches — with context on, one match prints up
        // to 2N+1 of them. The two were conflated here exactly as in `code_search`; see
        // `SearchMatchCounter` for why the display output cannot be counted directly.
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

        // `code_search_text` is the only one of the three splits that requests context, so it is
        // the only one paying for a counting run. `code_search_symbol` and `code_search_files`
        // pass `contextLines: 0` / `filesOnly`, where printed lines already equal the answer.
        let exactMatches: Int? = (!filesOnly && contextLines > 0)
            ? SearchMatchCounter.exactMatchCount(
                executable: rgPath ?? "/usr/bin/grep",
                arguments: SearchMatchCounter.countingArguments(
                    useRipgrep: rgPath != nil,
                    pattern: pattern,
                    path: resolvedPath,
                    glob: glob,
                    caseSensitive: caseSensitive,
                    wholeWord: wholeWord))
            : nil
        let reportedCount = exactMatches ?? shownLines

        var result = truncatedLines.joined(separator: "\n")
        if truncated {
            result += "\n\n[Truncated: output exceeded \(maxResults) lines"
            if let exactMatches { result += " (\(exactMatches) match\(exactMatches == 1 ? "" : "es") total)" }
            result += ". Refine your pattern or glob to narrow results.]"
        }

        let maxOutput = 8000
        if result.count > maxOutput {
            result = String(result.prefix(maxOutput)) + "\n...[Output truncated at \(maxOutput) chars]"
        }

        // `noun + "es"` produced "filees" on the files-only path — the one `code_search_files`
        // always takes. Shared pluraliser now, so the two search tools cannot disagree.
        let noun = filesOnly ? "file" : "match"
        return "\(result)\n(\(reportedCount) \(CodeSearchTool.pluralise(noun, count: reportedCount)))"
    }
}
