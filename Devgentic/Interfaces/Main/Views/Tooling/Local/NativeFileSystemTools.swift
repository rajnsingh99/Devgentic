//
//  NativeFileSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  Updated for Robust JSON Parsing & Schema Injection.
//

import Foundation

// MARK: - List Directory Tool

struct ListDirectoryTool: DevgenticTool {
    let name = "list_directory"
    let description = """
    [PURPOSE]: Lists the filenames and subdirectories within a specific folder.
    [WHEN TO USE]: Use when you need to explore the file structure or verify if a file exists before reading it.
    [INPUT]: { "path": "~/Documents" }
    [OUTPUT]: A list of filenames or an empty status.
    """
    
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
            let keys = [
                "path", "directory", "folder", "dir",
                "directoryPath", "folderPath", "targetPath" // CamelCase handling
            ]
            
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
        // FIX: Support Tilde Expansion
        let resolvedPath = (arguments.path as NSString).expandingTildeInPath
        
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Listed directory contents: \(resolvedPath)",
            operations: [
                ["action": "list", "path": resolvedPath]
            ]
        )
        // -------------------------------

        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: resolvedPath)
            let result = contents.isEmpty ? "(Directory is empty)" : contents.joined(separator: "\n")
            
            // FIX: Explicitly label the source path in the output
            return "📂 Contents of directory '\(resolvedPath)':\n\(result)\n(Audit Ref: \(logID))"
        } catch {
            return "Error listing directory: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Read File Tool

struct ReadFileTool: DevgenticTool {
    let name = "read_file"
    let description = """
    [PURPOSE]: Reads the plain text content of a file.
    [WHEN TO USE]: Use to inspect code, logs, or text documents. Do not use for binary files (images/apps).
    [INPUT]: { "path": "~/Documents/notes.txt" }
    [OUTPUT]: The full string content of the file.
    """
    
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
            let keys = [
                "path", "file", "filename", "filePath",
                "source", "target", "file_path"
            ]
            
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
    
    func call(arguments: Arguments) async throws -> String {
        // FIX: Support Tilde Expansion
        let resolvedPath = (arguments.path as NSString).expandingTildeInPath
        
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Read file content: \(resolvedPath)",
            operations: [
                ["action": "read", "path": resolvedPath]
            ]
        )
        // -------------------------------
        
        do {
            let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
            // FIX: Explicitly label the file source
            return "📄 Contents of file '\(resolvedPath)':\n\(content)\n(Audit Ref: \(logID))"
        } catch {
            return "Error reading file: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Write File Tool

struct WriteFileTool: DevgenticTool {
    let name = "write_file"
    let description = """
    [PURPOSE]: Writes text data to a file. Can create new files or append to existing ones.
    [WHEN TO USE]: Use for creating scripts, saving notes, or logging data.
    [INPUT]: { "path": "~/tmp/log.txt", "content": "Entry 1", "append": true }
    [OUTPUT]: Success or Error message.
    """
    
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
            let pathKeys = ["path", "file", "filename", "destination", "filepath", "target", "filePath"]
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
        // FIX: Support Tilde Expansion
        let resolvedPath = (arguments.path as NSString).expandingTildeInPath
        
        // --- LOGGING INSTRUMENTATION ---
        let mode = (arguments.append ?? false) ? "append" : "write"
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "\(mode.capitalized) to file at \(resolvedPath)",
            operations: [
                ["action": mode, "path": resolvedPath, "status": "attempted"]
            ]
        )
        // -------------------------------
        
        do {
            let fileURL = URL(fileURLWithPath: resolvedPath)
            let data = arguments.content.data(using: .utf8) ?? Data()
            
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

            return "Successfully \(mode)ed to \(resolvedPath) (Audit Ref: \(logID))"
        } catch {
            return "Error writing file: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Delete File Tool

struct DeleteFileTool: DevgenticTool {
    let name = "delete_file"
    let description = """
    [PURPOSE]: Permanently deletes a file or folder from the file system.
    [WHEN TO USE]: Use only when explicitly requested by the user or when cleaning up temporary files created by you.
    [INPUT]: { "path": "~/tmp/old_data" }
    [OUTPUT]: Success or Error message.
    """

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
            let keys = ["path", "file", "filename", "item", "filePath", "target"]
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

    func call(arguments: Arguments) async throws -> String {
        // FIX: Support Tilde Expansion
        let resolvedPath = (arguments.path as NSString).expandingTildeInPath
        let fm = FileManager.default
        let criticalPaths = ["/", "/Users", "/System", "/Library", "/bin", "/usr"]
        
        if criticalPaths.contains(resolvedPath) || resolvedPath == NSHomeDirectory() {
            return "Error: Safety Block. Deletion of root or home directory is forbidden."
        }

        do {
            if !fm.fileExists(atPath: resolvedPath) {
                return "Error: File not found at \(resolvedPath)"
            }
            try fm.removeItem(atPath: resolvedPath)
            
            // --- LOGGING INSTRUMENTATION ---
            let logID = LogManager.shared.logAction(
                toolName: self.name,
                summary: "Deleted item at \(resolvedPath)",
                operations: [
                    ["action": "delete", "path": resolvedPath, "status": "success"]
                ]
            )
            return "Successfully deleted: \(resolvedPath) (Audit Ref: \(logID))"
        } catch {
            return "Deletion failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Move File Tool

struct MoveFileTool: DevgenticTool {
    let name = "move_file"
    let description = """
    [PURPOSE]: Moves or renames a file/folder.
    [WHEN TO USE]: Use to organize files or rename items.
    [INPUT]: { "source": "~/tmp/a.txt", "destination": "~/tmp/b.txt" }
    [OUTPUT]: Success or Error message.
    """

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
            let srcKeys = [
                "source", "src", "from", "current_path", "source_path",
                "original", "sourcePath", "filePath" // CamelCase
            ]
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
            let destKeys = [
                "destination", "dest", "to", "target", "new_path", "target_path",
                "destinationPath", "newPath", "targetPath" // CamelCase
            ]
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
        let resolvedSource = (arguments.source as NSString).expandingTildeInPath
        let resolvedDest = (arguments.destination as NSString).expandingTildeInPath
        
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: resolvedSource) {
                return "Error: Source path does not exist: \(resolvedSource)"
            }
            if fm.fileExists(atPath: resolvedDest) {
                return "Error: Destination already exists: \(resolvedDest). Use delete_file first if you want to overwrite."
            }
            
            try fm.moveItem(atPath: resolvedSource, toPath: resolvedDest)
            
            // --- LOGGING INSTRUMENTATION ---
            let logID = LogManager.shared.logAction(
                toolName: self.name,
                summary: "Moved item",
                operations: [
                    ["from": resolvedSource, "to": resolvedDest, "status": "success"]
                ]
            )
            return "Successfully moved/renamed to: \(resolvedDest) (Audit Ref: \(logID))"
        } catch {
            return "Move failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Copy File Tool

struct CopyFileTool: DevgenticTool {
    let name = "copy_file"
    let description = """
    [PURPOSE]: Duplicates a file or folder.
    [WHEN TO USE]: Use to back up files or duplicate templates.
    [INPUT]: { "source": "~/tmp/a.txt", "destination": "~/tmp/a_copy.txt" }
    [OUTPUT]: Success or Error message.
    """

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
            let srcKeys = ["source", "src", "from", "current_path", "original", "sourcePath"]
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
            let destKeys = ["destination", "dest", "to", "target", "copy_path", "destinationPath"]
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
        let resolvedSource = (arguments.source as NSString).expandingTildeInPath
        let resolvedDest = (arguments.destination as NSString).expandingTildeInPath
        
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: resolvedSource) {
                return "Error: Source path does not exist: \(resolvedSource)"
            }
            if fm.fileExists(atPath: resolvedDest) {
                return "Error: Destination already exists: \(resolvedDest)."
            }
            
            try fm.copyItem(atPath: resolvedSource, toPath: resolvedDest)
            
            // --- LOGGING INSTRUMENTATION ---
            let logID = LogManager.shared.logAction(
                toolName: self.name,
                summary: "Copied item",
                operations: [
                    ["from": resolvedSource, "to": resolvedDest, "status": "success"]
                ]
            )
            return "Successfully copied to: \(resolvedDest) (Audit Ref: \(logID))"
        } catch {
            return "Copy failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Create Folder Tool

struct CreateFolderTool: DevgenticTool {
    let name = "create_folder"
    let description = """
    [PURPOSE]: Creates a new empty directory.
    [WHEN TO USE]: Use to organize files or prepare for new output.
    [INPUT]: { "path": "~/Projects/NewApp" }
    [OUTPUT]: Success or Error message.
    """

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
            let keys = [
                "path", "folder", "directory", "dir", "name", "target",
                "folderPath", "directoryPath" // CamelCase
            ]
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
        // FIX: Support Tilde Expansion
        let resolvedPath = (arguments.path as NSString).expandingTildeInPath
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: resolvedPath) {
                return "Error: Directory already exists at \(resolvedPath)"
            }
            
            try fm.createDirectory(atPath: resolvedPath, withIntermediateDirectories: true, attributes: nil)
            
            // --- LOGGING INSTRUMENTATION ---
            let logID = LogManager.shared.logAction(
                toolName: self.name,
                summary: "Created directory",
                operations: [
                    ["path": resolvedPath, "status": "success"]
                ]
            )
            return "Successfully created directory: \(resolvedPath) (Audit Ref: \(logID))"
        } catch {
            return "Creation failed: \(error.localizedDescription)"
        }
    }
}
