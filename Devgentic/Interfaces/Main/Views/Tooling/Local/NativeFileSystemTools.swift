// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeFileSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "NativeFileSystemTools")

// MARK: - List Directory Tool

struct ListDirectoryTool: DevgenticTool {
    let name = "list_directory"
    let category = "File System"
    let description = "Lists files and subdirectories within a specified folder."
    
    struct Arguments: Decodable, Sendable {
        let path: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // ROBUST PARSING: Synonyms & Casing
            var foundPath: String? = nil
            let keys = ToolPathKeys.listDirectory
            
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = val
                    break
                }
            }
            
            guard let validPath = foundPath else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'path'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }
            self.path = validPath
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "The full absolute path (or ~/ path) to the directory.")
            ],
            required: ["path"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        // Expand ~ and anchor relative paths to HOME (see FilePathResolver).
        let resolvedPath = FilePathResolver.resolve(arguments.path)

        let fileManager = FileManager.default
        let dirURL = URL(fileURLWithPath: resolvedPath)

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )

            if contents.isEmpty {
                return "📂 Directory '\(resolvedPath)' is empty."
            }

            // Phase 10: Structured output with type indicators and sizes for LLM clarity.
            var lines: [String] = []
            var dirCount = 0
            var fileCount = 0

            for itemURL in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = resourceValues?.isDirectory ?? false
                let name = itemURL.lastPathComponent

                if isDir {
                    lines.append("  [DIR]  \(name)/")
                    dirCount += 1
                } else {
                    let size = resourceValues?.fileSize ?? 0
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                    lines.append("  [FILE] \(name) (\(sizeStr))")
                    fileCount += 1
                }
            }

            let header = "📂 Contents of '\(resolvedPath)' — \(contents.count) items (\(dirCount) folders, \(fileCount) files):"
            return "\(header)\n\(lines.joined(separator: "\n"))"
        } catch {
            return "Error listing directory: \(error.localizedDescription)"
        }
    }
}

// MARK: - Read File Tool

struct ReadFileTool: DevgenticTool {
    let name = "read_file"
    let category = "File System"
    let description = "Reads the content of a file. Supports plain text, code, PDF, DOCX, XLSX, CSV, PPTX, and RTF formats."
    
    struct Arguments: Decodable, Sendable {
        let path: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // ROBUST PARSING
            var foundPath: String? = nil
            let keys = ToolPathKeys.readFile
            
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = val
                    break
                }
            }
            
            guard let validPath = foundPath else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'path'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }
            self.path = validPath
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "The full path (or ~/ path) to the file to read.")
            ],
            required: ["path"]
        )
    }
    
    /// Ceiling on the plain-text branch, matching the `maxSize` the document extractors are given.
    /// Keeps the plain-text and document branches of `read_file` consistent about how much a caller can be given.
    static let maxPlainTextCharacters = 500_000

    func call(arguments: Arguments) async throws -> String {
        // Expand ~ and anchor relative paths to HOME (see FilePathResolver).
        let resolvedPath = FilePathResolver.resolve(arguments.path)
        let url = URL(fileURLWithPath: resolvedPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            // Bare error; `ToolExecutionMediator` enriches this via `ToolRecoveryHints`
            // using only tools that are actually available in the current request.
            return "Error: File not found at '\(resolvedPath)'"
        }

        // Named as a directory rather than left to Foundation: `String(contentsOfFile:)` on a folder fails like an unreadable
        // file, so the model could not tell it passed a directory and would retry the same path.
        guard !isDirectory.boolValue else {
            return "Error: '\(resolvedPath)' is a directory, not a file. "
                + "Use list_directory to see what is inside it."
        }

        // Check the file type up front: a FIFO with no writer blocks in `read(2)` forever (a tool timeout can't interrupt it)
        // and `/dev/zero` never reaches EOF. `stat`, not `lstat`, so a symlink to a regular file still reads.
        var info = stat()
        if stat(resolvedPath, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG {
            let kind: String
            switch info.st_mode & S_IFMT {
            case S_IFIFO: kind = "a named pipe (FIFO)"
            case S_IFSOCK: kind = "a socket"
            case S_IFCHR: kind = "a character device"
            case S_IFBLK: kind = "a block device"
            default: kind = "not a regular file"
            }
            logger.info("[READFILE] '\(resolvedPath)' is \(kind); refused without opening it. Reading one would block forever or never reach EOF.")
            return "Error: '\(resolvedPath)' is \(kind), not a regular file, and cannot be read as content."
        }

        // Try document extraction first (PDF, DOCX, XLSX, CSV, PPTX, RTF)
        let registry = DocumentExtractionRegistry.shared
        if registry.canExtract(from: url) {
            do {
                let result = try await registry.extract(from: url, maxSize: 500_000)
                var output = "📄 Contents of \(result.metadata.format.uppercased()) file '\(resolvedPath)'"
                if let pages = result.metadata.pageCount {
                    output += " (\(pages) pages)"
                }
                if let sheets = result.metadata.sheetNames, !sheets.isEmpty {
                    output += " (sheets: \(sheets.joined(separator: ", ")))"
                }
                if result.metadata.wasTruncated {
                    output += " [truncated]"
                }
                output += ":\n\(result.text)"
                return output
            } catch {
                return "Error extracting document: \(error.localizedDescription)"
            }
        }

        // Fallback plain-text read: UTF-8 first, then Foundation's own detection (`usedEncoding`), then Latin-1.
        // `usedEncoding` precedes Latin-1 since it honours a BOM (UTF-16); Latin-1 decodes any bytes and would yield mojibake.
        var usedEncoding: String.Encoding = .utf8
        var content: String
        if let utf8 = try? String(contentsOfFile: resolvedPath, encoding: .utf8) {
            // Valid UTF-8 is text by definition — no sniffing, no fallbacks, no surprises.
            content = utf8
        } else if BinaryContentSniffer.looksBinary(at: url) {
            // The binary sniff sits between the strict decode and the lossy ones: Latin-1 maps all 256 byte values and cannot fail,
            // so without it a binary file (e.g. a PDF) would come back as confident mojibake instead of being refused.
            logger.info("[READFILE] '\(resolvedPath)' is not valid UTF-8 and looks binary; refused rather than decoded lossily. Returning junk as content is worse than declining to read it.")
            return "Error: '\(resolvedPath)' does not appear to be a text file. "
                + "If it is a document, make sure the extension matches its real format "
                + "(read_file handles PDF, DOCX, XLSX, CSV, PPTX and RTF by extension)."
        } else if let detected = try? String(contentsOfFile: resolvedPath, usedEncoding: &usedEncoding) {
            content = detected
            logger.info("[READFILE] '\(resolvedPath)' is not UTF-8; decoded as \(usedEncoding.description). Reported to the model as ordinary content.")
        } else if let data = try? Data(contentsOf: url),
                  let latin1 = String(data: data, encoding: .isoLatin1) {
            content = latin1
            logger.info("[READFILE] '\(resolvedPath)' decoded as ISO Latin-1 after UTF-8 and BOM detection both failed. Bytes that are not valid text will appear as substitute characters.")
        } else {
            logger.error("[READFILE] '\(resolvedPath)' could not be decoded as text under any encoding — the model gets no content for this file.")
            return "Error: '\(resolvedPath)' could not be read as text. "
                + "It may be a binary file; if it is a document, check the extension is correct."
        }

        // Bounded, and the bound is announced: silently returning the first 500 KB would leave the model unable to tell a
        // whole file from a fragment.
        if content.count > Self.maxPlainTextCharacters {
            let total = content.count
            logger.info("[READFILE] '\(resolvedPath)' is \(total) characters; returning the first \(Self.maxPlainTextCharacters) and saying so. The rest is NOT in this observation.")
            content = String(content.prefix(Self.maxPlainTextCharacters))
                + "\n\n…[truncated: showing the first \(Self.maxPlainTextCharacters) of \(total) characters. "
                + "read_file cannot page; use preview_file for the head or tail, or code_search_text to find a region.]"
        }

        return "📄 Contents of file '\(resolvedPath)':\n\(content)"
    }
}

// MARK: - Write File Tool

struct WriteFileTool: DevgenticTool {
    let name = "write_file"
    let category = "File System"
    let description = "Writes text to a file. Supports creating new files and appending to existing ones."
    
    struct Arguments: Decodable, Sendable {
        let path: String
        let content: String
        let append: Bool?
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // Parse Path
            var foundPath: String? = nil
            let pathKeys = ToolPathKeys.writeFile
            for key in pathKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = val
                    break
                }
            }
            guard let validPath = foundPath else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'path'"))
            }
            self.path = validPath
            
            // Parse Content
            var foundContent: String? = nil
            let contentKeys = ["content", "text", "body", "data", "string"]
            for key in contentKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundContent = val
                    break
                }
            }
            guard let validContent = foundContent else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'content'"))
            }
            self.content = validContent
            
            // Parse Append (Optional) - handles boolean or string boolean representations
            var appendVal: Bool? = nil
            let appendKeys = ["append", "isAppend", "shouldAppend", "appending"]
            for key in appendKeys {
                if let codingKey = DynamicKey(stringValue: key) {
                    if let boolVal = try? container.decodeIfPresent(Bool.self, forKey: codingKey) {
                        appendVal = boolVal
                        break
                    } else if let strVal = try? container.decodeIfPresent(String.self, forKey: codingKey), let boolVal = Bool(strVal) {
                        appendVal = boolVal
                        break
                    }
                }
            }
            self.append = appendVal
        }
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "Target file path."),
                ("content", "string", "Text to write."),
                ("append", "boolean", "If true, appends to the end of the file instead of overwriting.")
            ],
            required: ["path", "content"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        // Anchor relative paths to HOME (not the read-only volume root) — see FilePathResolver.
        let resolvedPath = FilePathResolver.resolve(arguments.path)
        let verb = (arguments.append ?? false) ? "appended" : "wrote"

        do {
            let fileURL = URL(fileURLWithPath: resolvedPath)
            let data = arguments.content.data(using: .utf8) ?? Data()

            // Ensure the containing folder exists: models often write to a path whose parent isn't created yet, and the atomic
            // write then fails with a misleading Foundation message. Creating intermediates makes write_file self-sufficient.
            let parent = fileURL.deletingLastPathComponent()
            if !parent.path.isEmpty {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }

            if arguments.append == true {
                if FileManager.default.fileExists(atPath: resolvedPath) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    // If append requested but file doesn't exist, create it
                     try data.write(to: fileURL, options: .atomic)
                }
            } else {
                // Overwrite behavior
                try data.write(to: fileURL, options: .atomic)
            }

            return "Successfully \(verb) to \(resolvedPath)"
        } catch {
            // Self-correcting error text: Foundation's raw string for a missing parent names the leaf as a folder, which misleads
            // the model; state the real target path instead.
            return "Error: couldn't write to '\(resolvedPath)' — \(error.localizedDescription)"
        }
    }
}

// MARK: - Delete File Tool

struct DeleteFileTool: DevgenticTool {
    let name = "delete_file"
    let category = "File System"
    let description = "Permanently deletes a file or folder from the file system."

    struct Arguments: Decodable, Sendable {
        let path: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            var foundPath: String? = nil
            let keys = ToolPathKeys.deleteFile
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = val
                    break
                }
            }
            guard let val = foundPath else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'path'"))
            }
            self.path = val
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "The absolute path of the item to delete.")
            ],
            required: ["path"]
        )
    }

    // MARK: - Testable Safety Guard

    static let criticalPaths: Set<String> = ["/", "/Users", "/System", "/Library", "/bin", "/usr"]

    static func isCriticalPath(_ path: String) -> Bool {
        criticalPaths.contains(path) || path == NSHomeDirectory()
    }

    func call(arguments: Arguments) async throws -> String {
        // Expand ~ and anchor relative paths to HOME (see FilePathResolver).
        let resolvedPath = FilePathResolver.resolve(arguments.path)
        let fm = FileManager.default

        if Self.isCriticalPath(resolvedPath) {
            return "Error: Safety Block. Deletion of root or home directory is forbidden."
        }

        do {
            if !fm.fileExists(atPath: resolvedPath) {
                return "Error: File not found at \(resolvedPath)"
            }
            try fm.removeItem(atPath: resolvedPath)
            return "Successfully deleted: \(resolvedPath)"
        } catch {
            return "Error: deletion failed — \(error.localizedDescription)"
        }
    }
}

// MARK: - Move File Tool

struct MoveFileTool: DevgenticTool {
    let name = "move_file"
    let category = "File System"
    let description = "Moves or renames a file or folder."

    struct Arguments: Decodable, Sendable {
        let source: String
        let destination: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // Alias Check: Source
            var foundSource: String? = nil
            let srcKeys = ToolPathKeys.moveFileSource
            for key in srcKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundSource = val
                    break
                }
            }
            guard let validSource = foundSource else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'source'"))
            }
            self.source = validSource
            
            // Alias Check: Destination
            var foundDest: String? = nil
            let destKeys = ToolPathKeys.moveFileDestination
            for key in destKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundDest = val
                    break
                }
            }
            guard let validDest = foundDest else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'destination'"))
            }
            self.destination = validDest
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("source", "string", "Current path of the file/folder."),
                ("destination", "string", "New path for the file/folder.")
            ],
            required: ["source", "destination"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // FIX: Support Tilde Expansion
        let resolvedSource = FilePathResolver.resolve(arguments.source)
        let resolvedDest = FilePathResolver.resolve(arguments.destination)
        
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: resolvedSource) {
                return "Error: Source path does not exist: \(resolvedSource)"
            }
            if fm.fileExists(atPath: resolvedDest) {
                return "Error: Destination already exists: \(resolvedDest). Use delete_file first if you want to overwrite."
            }
            
            try fm.moveItem(atPath: resolvedSource, toPath: resolvedDest)
            return "Successfully moved/renamed to: \(resolvedDest)"
        } catch {
            return "Error: move failed — \(error.localizedDescription)"
        }
    }
}

// MARK: - Copy File Tool

struct CopyFileTool: DevgenticTool {
    let name = "copy_file"
    let category = "File System"
    let description = "Duplicates a file or folder to a new destination."

    struct Arguments: Decodable, Sendable {
        let source: String
        let destination: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // Alias Check: Source
            var foundSource: String? = nil
            let srcKeys = ToolPathKeys.copyFileSource
            for key in srcKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundSource = val
                    break
                }
            }
            guard let validSource = foundSource else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'source'"))
            }
            self.source = validSource
            
            // Alias Check: Destination
            var foundDest: String? = nil
            let destKeys = ToolPathKeys.copyFileDestination
            for key in destKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundDest = val
                    break
                }
            }
            guard let validDest = foundDest else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'destination'"))
            }
            self.destination = validDest
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("source", "string", "Original file path."),
                ("destination", "string", "Copy destination path.")
            ],
            required: ["source", "destination"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // FIX: Support Tilde Expansion
        let resolvedSource = FilePathResolver.resolve(arguments.source)
        let resolvedDest = FilePathResolver.resolve(arguments.destination)
        
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: resolvedSource) {
                return "Error: Source path does not exist: \(resolvedSource)"
            }
            if fm.fileExists(atPath: resolvedDest) {
                return "Error: Destination already exists: \(resolvedDest)."
            }
            
            try fm.copyItem(atPath: resolvedSource, toPath: resolvedDest)
            return "Successfully copied to: \(resolvedDest)"
        } catch {
            return "Error: copy failed — \(error.localizedDescription)"
        }
    }
}

// MARK: - Create Folder Tool

struct CreateFolderTool: DevgenticTool {
    let name = "create_folder"
    let category = "File System"
    let description = "Creates a new empty directory."

    struct Arguments: Decodable, Sendable {
        let path: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // Alias Check
            var foundPath: String? = nil
            let keys = ToolPathKeys.createFolder
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundPath = val
                    break
                }
            }
            guard let validPath = foundPath else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing property 'path'"))
            }
            self.path = validPath
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("path", "string", "Absolute path for the new folder.")
            ],
            required: ["path"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        // Expand ~ and anchor relative paths to HOME (see FilePathResolver).
        let resolvedPath = FilePathResolver.resolve(arguments.path)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: resolvedPath) {
                return "Error: Directory already exists at \(resolvedPath)"
            }
            
            try fm.createDirectory(atPath: resolvedPath, withIntermediateDirectories: true, attributes: nil)
            return "Successfully created directory: \(resolvedPath)"
        } catch {
            return "Error: could not create the folder — \(error.localizedDescription)"
        }
    }
}
