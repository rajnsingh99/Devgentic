//
//  NativeFileSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//  Updated for Audit Consistency & Manipulation Primitives.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - List Directory Tool

struct ListDirectoryTool: OpenFoundationModels.Tool {
    let name = "list_directory"
    let description = "Lists the filenames of all files and folders in a specified directory path."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        
        init(_ content: GeneratedContent) throws {
            let properties = try content.properties()
            
            // ROBUST PARSING: Check aliases
            var foundPath: String? = nil
            let keys = ["path", "directory", "folder", "dir"]
            
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
                    description: "The full absolute path to the directory.",
                    schema: pathSchema,
                    isOptional: false
                )
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Listed directory contents: \(arguments.path)",
            operations: [
                ["action": "list", "path": arguments.path]
            ]
        )
        // -------------------------------

        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: arguments.path)
            let result = contents.isEmpty ? "Directory is empty." : contents.joined(separator: "\n")
            return "\(result)\n(Audit Ref: \(logID))"
        } catch {
            return "Error listing directory: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Read File Tool

struct ReadFileTool: OpenFoundationModels.Tool {
    let name = "read_file"
    let description = "Reads the entire content of a text file at the specified path."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        
        init(_ content: GeneratedContent) throws {
            let properties = try content.properties()
            
            // ROBUST PARSING: Check aliases
            var foundPath: String? = nil
            let keys = ["path", "file", "filename", "filePath"]
            
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
                    description: "The full path to the file to read.",
                    schema: pathSchema,
                    isOptional: false
                )
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Read file content: \(arguments.path)",
            operations: [
                ["action": "read", "path": arguments.path]
            ]
        )
        // -------------------------------
        
        do {
            let content = try String(contentsOfFile: arguments.path, encoding: .utf8)
            return "\(content)\n(Audit Ref: \(logID))"
        } catch {
            return "Error reading file: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Write File Tool

struct WriteFileTool: OpenFoundationModels.Tool {
    let name = "write_file"
    let description = "Writes text content to a file at the specified path. Creates the file if it doesn't exist. Can overwrite or append."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        let content: String
        let append: Bool?
        
        init(_ content: GeneratedContent) throws {
            let properties = try content.properties()
            
            // Parse Path
            var foundPath: String? = nil
            let pathKeys = ["path", "file", "filename", "destination", "filepath"]
            for key in pathKeys { if let val = properties[key], let str = try? String(val) { foundPath = str; break } }
            guard let validPath = foundPath else { throw GeneratedContentError.missingProperty("path") }
            self.path = validPath
            
            // Parse Content
            var foundContent: String? = nil
            let contentKeys = ["content", "text", "body", "data"]
            for key in contentKeys { if let val = properties[key], let str = try? String(val) { foundContent = str; break } }
            guard let validContent = foundContent else { throw GeneratedContentError.missingProperty("content") }
            self.content = validContent
            
            // Parse Append (Optional)
            if let val = properties["append"], let boolVal = try? Bool(val) {
                self.append = boolVal
            } else {
                self.append = false
            }
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
        // --- LOGGING INSTRUMENTATION ---
        let mode = (arguments.append ?? false) ? "append" : "write"
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "\(mode.capitalized) to file at \(arguments.path)",
            operations: [
                ["action": mode, "path": arguments.path, "status": "attempted"]
            ]
        )
        // -------------------------------
        
        do {
            let fileURL = URL(fileURLWithPath: arguments.path)
            let data = arguments.content.data(using: .utf8) ?? Data()
            
            if arguments.append == true {
                if FileManager.default.fileExists(atPath: arguments.path) {
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

            return "Successfully \(mode)ed to \(arguments.path) (Audit Ref: \(logID))"
        } catch {
            return "Error writing file: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}

// MARK: - Delete File Tool

struct DeleteFileTool: OpenFoundationModels.Tool {
    let name = "delete_file"
    let description = "Permanently deletes a file or directory. USE WITH CAUTION. This action is irreversible. Always verify the path before deletion."

    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            var foundPath: String? = nil
            let keys = ["path", "file", "filename", "item"]
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
        let path = arguments.path
        let fm = FileManager.default
        let criticalPaths = ["/", "/Users", "/System", "/Library", "/bin", "/usr"]
        if criticalPaths.contains(path) || path == NSHomeDirectory() {
            return "Error: Safety Block. Deletion of root or home directory is forbidden."
        }

        do {
            if !fm.fileExists(atPath: path) {
                return "Error: File not found at \(path)"
            }
            try fm.removeItem(atPath: path)
            
            // --- LOGGING INSTRUMENTATION ---
            let logID = LogManager.shared.logAction(
                toolName: self.name,
                summary: "Deleted item at \(path)",
                operations: [
                    ["action": "delete", "path": path, "status": "success"]
                ]
            )
            return "Successfully deleted: \(path) (Audit Ref: \(logID))"
        } catch {
            return "Deletion failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Move File Tool

struct MoveFileTool: OpenFoundationModels.Tool {
    let name = "move_file"
    let description = "Moves or renames a file or directory from one path to another. Use this for renaming items as well."

    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let source: String
        let destination: String
        
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // Alias Check: Source
            var foundSource: String? = nil
            let srcKeys = ["source", "src", "from", "current_path", "source_path"]
            for key in srcKeys {
                if let val = props[key], let str = try? String(val) { foundSource = str; break }
            }
            guard let validSource = foundSource else { throw GeneratedContentError.missingProperty("source") }
            self.source = validSource
            
            // Alias Check: Destination
            var foundDest: String? = nil
            let destKeys = ["destination", "dest", "to", "target", "new_path", "target_path"]
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
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: arguments.source) {
                return "Error: Source path does not exist: \(arguments.source)"
            }
            if fm.fileExists(atPath: arguments.destination) {
                return "Error: Destination already exists: \(arguments.destination). Use delete_file first if you want to overwrite."
            }
            
            try fm.moveItem(atPath: arguments.source, toPath: arguments.destination)
            
            // --- LOGGING INSTRUMENTATION ---
            let logID = LogManager.shared.logAction(
                toolName: self.name,
                summary: "Moved item",
                operations: [
                    ["from": arguments.source, "to": arguments.destination, "status": "success"]
                ]
            )
            return "Successfully moved/renamed to: \(arguments.destination) (Audit Ref: \(logID))"
        } catch {
            return "Move failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Copy File Tool

struct CopyFileTool: OpenFoundationModels.Tool {
    let name = "copy_file"
    let description = "Copies a file or directory to a new location. Preserves metadata where possible."

    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let source: String
        let destination: String
        
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // Alias Check: Source
            var foundSource: String? = nil
            let srcKeys = ["source", "src", "from", "current_path", "original"]
            for key in srcKeys {
                if let val = props[key], let str = try? String(val) { foundSource = str; break }
            }
            guard let validSource = foundSource else { throw GeneratedContentError.missingProperty("source") }
            self.source = validSource
            
            // Alias Check: Destination
            var foundDest: String? = nil
            let destKeys = ["destination", "dest", "to", "target", "copy_path"]
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
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: arguments.source) {
                return "Error: Source path does not exist: \(arguments.source)"
            }
            if fm.fileExists(atPath: arguments.destination) {
                return "Error: Destination already exists: \(arguments.destination)."
            }
            
            try fm.copyItem(atPath: arguments.source, toPath: arguments.destination)
            
            // --- LOGGING INSTRUMENTATION ---
            let logID = LogManager.shared.logAction(
                toolName: self.name,
                summary: "Copied item",
                operations: [
                    ["from": arguments.source, "to": arguments.destination, "status": "success"]
                ]
            )
            return "Successfully copied to: \(arguments.destination) (Audit Ref: \(logID))"
        } catch {
            return "Copy failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Create Folder Tool

struct CreateFolderTool: OpenFoundationModels.Tool {
    let name = "create_folder"
    let description = "Creates a new folder/directory. Will create intermediate directories if they do not exist."

    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        
        init(_ content: GeneratedContent) throws {
            let props = try content.properties()
            
            // Alias Check
            var foundPath: String? = nil
            let keys = ["path", "folder", "directory", "dir", "name", "target"]
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
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: arguments.path) {
                return "Error: Directory already exists at \(arguments.path)"
            }
            
            try fm.createDirectory(atPath: arguments.path, withIntermediateDirectories: true, attributes: nil)
            
            // --- LOGGING INSTRUMENTATION ---
            let logID = LogManager.shared.logAction(
                toolName: self.name,
                summary: "Created directory",
                operations: [
                    ["path": arguments.path, "status": "success"]
                ]
            )
            return "Successfully created directory: \(arguments.path) (Audit Ref: \(logID))"
        } catch {
            return "Creation failed: \(error.localizedDescription)"
        }
    }
}
