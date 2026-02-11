//
//  NativeFileSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  Updated for Robust JSON Parsing & Schema Injection.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - List Directory Tool

struct ListDirectoryTool: OpenFoundationModels.Tool {
    let name = "list_directory"
    // OPTIMIZATION: Updated example to use Tilde (~/) for robustness against username hallucinations
    let description = "Lists the filenames in a directory. Example: { \"path\": \"~/Documents\" }"
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        
        init(_ content: GeneratedContent) throws {
            let properties = try content.properties()
            
            // ROBUST PARSING: Synonyms & Casing
            var foundPath: String? = nil
            let keys = [
                "path", "directory", "folder", "dir",
                "directoryPath", "folderPath", "targetPath" // CamelCase handling
            ]
            
            for key in keys {
                if let val = properties[key], let str = try? String(val) {
                    foundPath = str
                    break
                }
            }
            
            guard let validPath = foundPath else {
                throw GeneratedContentError.missingProperty("path (checked aliases: \(keys.joined(separator: ", ")))")
            }
            self.path = validPath
        }
    }
    
    var parameters: GenerationSchema {
        let pathSchema = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "path",
                    description: "The full absolute path (or ~/ path) to the directory.",
                    schema: pathSchema,
                    isOptional: false
                )
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
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

struct ReadFileTool: OpenFoundationModels.Tool {
    let name = "read_file"
    // OPTIMIZATION: Updated example to use Tilde (~/)
    let description = "Reads the entire content of a text file. Example: { \"path\": \"~/Documents/notes.txt\" }"
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        
        init(_ content: GeneratedContent) throws {
            let properties = try content.properties()
            
            // ROBUST PARSING
            var foundPath: String? = nil
            let keys = [
                "path", "file", "filename", "filePath",
                "source", "target", "file_path"
            ]
            
            for key in keys {
                if let val = properties[key], let str = try? String(val) {
                    foundPath = str
                    break
                }
            }
            
            guard let validPath = foundPath else {
                throw GeneratedContentError.missingProperty("path (checked aliases: \(keys.joined(separator: ", ")))")
            }
            self.path = validPath
        }
    }
    
    var parameters: GenerationSchema {
        let pathSchema = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "path",
                    description: "The full path (or ~/ path) to the file to read.",
                    schema: pathSchema,
                    isOptional: false
                )
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
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

struct WriteFileTool: OpenFoundationModels.Tool {
    let name = "write_file"
    let description = "Writes text to a file. Example: { \"path\": \"~/tmp/log.txt\", \"content\": \"Entry 1\", \"append\": true }"
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        let content: String
        let append: Bool?
        
        init(_ content: GeneratedContent) throws {
            let properties = try content.properties()
            
            // Parse Path
            var foundPath: String? = nil
            let pathKeys = ["path", "file", "filename", "destination", "filepath", "target", "filePath"]
            for key in pathKeys { if let val = properties[key], let str = try? String(val) { foundPath = str; break } }
            guard let validPath = foundPath else { throw GeneratedContentError.missingProperty("path") }
            self.path = validPath
            
            // Parse Content
            var foundContent: String? = nil
            let contentKeys = ["content", "text", "body", "data", "string"]
            for key in contentKeys { if let val = properties[key], let str = try? String(val) { foundContent = str; break } }
            guard let validContent = foundContent else { throw GeneratedContentError.missingProperty("content") }
            self.content = validContent
            
            // Parse Append (Optional)
            var appendVal: Bool = false
            let appendKeys = ["append", "isAppend", "shouldAppend", "appending"]
            for key in appendKeys {
                if let val = properties[key], let boolVal = try? Bool(val) {
                    appendVal = boolVal
                    break
                }
            }
            self.append = appendVal
        }
    }
    
    var parameters: GenerationSchema {
        let strSchema = DynamicGenerationSchema(type: String.self)
        let boolSchema = DynamicGenerationSchema(type: Bool.self)
        
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "path", description: "Target file path.", schema: strSchema),
                DynamicGenerationSchema.Property(name: "content", description: "Text to write.", schema: strSchema),
                DynamicGenerationSchema.Property(name: "append", description: "If true, appends to the end of the file instead of overwriting.", schema: boolSchema, isOptional: true)
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
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

struct DeleteFileTool: OpenFoundationModels.Tool {
    let name = "delete_file"
    let description = "Permanently deletes a file/folder. Example: { \"path\": \"~/tmp/old_data\" }"

    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            var foundPath: String? = nil
            let keys = ["path", "file", "filename", "item", "filePath", "target"]
            for key in keys { if let val = props[key], let str = try? String(val) { foundPath = str; break } }
            guard let val = foundPath else { throw GeneratedContentError.missingProperty("path") }
            self.path = val
        }
    }

    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "path", description: "The absolute path of the item to delete.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }

    typealias Output = String

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

struct MoveFileTool: OpenFoundationModels.Tool {
    let name = "move_file"
    let description = "Moves or renames a file. Example: { \"source\": \"~/tmp/a.txt\", \"destination\": \"~/tmp/b.txt\" }"

    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let source: String
        let destination: String
        
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // Alias Check: Source
            var foundSource: String? = nil
            let srcKeys = [
                "source", "src", "from", "current_path", "source_path",
                "original", "sourcePath", "filePath" // CamelCase
            ]
            for key in srcKeys {
                if let val = props[key], let str = try? String(val) { foundSource = str; break }
            }
            guard let validSource = foundSource else { throw GeneratedContentError.missingProperty("source") }
            self.source = validSource
            
            // Alias Check: Destination
            var foundDest: String? = nil
            let destKeys = [
                "destination", "dest", "to", "target", "new_path", "target_path",
                "destinationPath", "newPath", "targetPath" // CamelCase
            ]
            for key in destKeys {
                if let val = props[key], let str = try? String(val) { foundDest = str; break }
            }
            guard let validDest = foundDest else { throw GeneratedContentError.missingProperty("destination") }
            self.destination = validDest
        }
    }

    var parameters: GenerationSchema {
        let strSchema = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "source", description: "Current path of the file/folder.", schema: strSchema),
                DynamicGenerationSchema.Property(name: "destination", description: "New path for the file/folder.", schema: strSchema)
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }

    typealias Output = String

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

struct CopyFileTool: OpenFoundationModels.Tool {
    let name = "copy_file"
    let description = "Copies a file/folder. Example: { \"source\": \"~/tmp/a.txt\", \"destination\": \"~/tmp/a_copy.txt\" }"

    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let source: String
        let destination: String
        
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // Alias Check: Source
            var foundSource: String? = nil
            let srcKeys = ["source", "src", "from", "current_path", "original", "sourcePath"]
            for key in srcKeys {
                if let val = props[key], let str = try? String(val) { foundSource = str; break }
            }
            guard let validSource = foundSource else { throw GeneratedContentError.missingProperty("source") }
            self.source = validSource
            
            // Alias Check: Destination
            var foundDest: String? = nil
            let destKeys = ["destination", "dest", "to", "target", "copy_path", "destinationPath"]
            for key in destKeys {
                if let val = props[key], let str = try? String(val) { foundDest = str; break }
            }
            guard let validDest = foundDest else { throw GeneratedContentError.missingProperty("destination") }
            self.destination = validDest
        }
    }

    var parameters: GenerationSchema {
        let strSchema = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "source", description: "Original file path.", schema: strSchema),
                DynamicGenerationSchema.Property(name: "destination", description: "Copy destination path.", schema: strSchema)
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }

    typealias Output = String

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

struct CreateFolderTool: OpenFoundationModels.Tool {
    let name = "create_folder"
    let description = "Creates a directory. Example: { \"path\": \"~/Projects/NewApp\" }"

    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // Alias Check
            var foundPath: String? = nil
            let keys = [
                "path", "folder", "directory", "dir", "name", "target",
                "folderPath", "directoryPath" // CamelCase
            ]
            for key in keys {
                if let val = props[key], let str = try? String(val) { foundPath = str; break }
            }
            guard let validPath = foundPath else { throw GeneratedContentError.missingProperty("path") }
            self.path = validPath
        }
    }

    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "path", description: "Absolute path for the new folder.", schema: DynamicGenerationSchema(type: String.self))
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }

    typealias Output = String

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
