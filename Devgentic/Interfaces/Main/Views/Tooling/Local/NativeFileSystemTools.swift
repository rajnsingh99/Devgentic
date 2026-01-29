//
//  NativeFileSystemTools.swift
//  Devgentic
//
//  Created by Raj Singh on 26/01/26.
//


import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - List Directory Tool

struct ListDirectoryTool: OpenFoundationModels.Tool {
    let name = "list_directory"
    // IMPROVEMENT: Explicitly stating limitations helps the agent choose the right tool
    let description = "Lists the filenames of all files and folders in a specified directory path. Does not provide file size or metadata."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        
        init(_ content: GeneratedContent) throws {
            let properties = try content.properties()
            guard let pathContent = properties["path"] else {
                throw GeneratedContentError.missingProperty("path")
            }
            self.path = try String(pathContent)
        }
    }
    
    var parameters: GenerationSchema {
        let pathSchema = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(
                    name: "path",
                    description: "The full absolute path to the directory (e.g., '/Users/username/Desktop').",
                    schema: pathSchema,
                    isOptional: false
                )
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        let fileManager = FileManager.default
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: arguments.path)
            return contents.isEmpty ? "Directory is empty." : contents.joined(separator: "\n")
        } catch {
            return "Error listing directory: \(error.localizedDescription)"
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
            guard let pathContent = properties["path"] else {
                throw GeneratedContentError.missingProperty("path")
            }
            self.path = try String(pathContent)
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
        do {
            return try String(contentsOfFile: arguments.path, encoding: .utf8)
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Write File Tool

struct WriteFileTool: OpenFoundationModels.Tool {
    let name = "write_file"
    let description = "Writes text content to a file at the specified path. Creates the file if it doesn't exist, and overwrites it if it does."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        let content: String
        
        init(_ content: GeneratedContent) throws {
            let properties = try content.properties()
            
            guard let pathVal = properties["path"] else { throw GeneratedContentError.missingProperty("path") }
            self.path = try String(pathVal)
            
            guard let contentVal = properties["content"] else { throw GeneratedContentError.missingProperty("content") }
            self.content = try String(contentVal)
        }
    }
    
    var parameters: GenerationSchema {
        let strSchema = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "path", description: "Target file path.", schema: strSchema),
                DynamicGenerationSchema.Property(name: "content", description: "Text to write.", schema: strSchema)
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        do {
            try arguments.content.write(toFile: arguments.path, atomically: true, encoding: .utf8)
            return "Successfully wrote to \(arguments.path)"
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }
}

// MARK: - Delete File Tool

struct DeleteFileTool: OpenFoundationModels.Tool {
    let name = "delete_file"
    let description = "Permanently deletes a file at the specified path."
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        let path: String
        
        init(_ content: GeneratedContent) throws {
            let properties = try content.properties()
            guard let pathVal = properties["path"] else { throw GeneratedContentError.missingProperty("path") }
            self.path = try String(pathVal)
        }
    }
    
    var parameters: GenerationSchema {
        let strSchema = DynamicGenerationSchema(type: String.self)
        let root = DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                DynamicGenerationSchema.Property(name: "path", description: "Path of file to delete.", schema: strSchema)
            ]
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    typealias Output = String
    
    func call(arguments: Arguments) async throws -> String {
        do {
            try FileManager.default.removeItem(atPath: arguments.path)
            return "Successfully deleted \(arguments.path)"
        } catch {
            return "Error deleting file: \(error.localizedDescription)"
        }
    }
}
