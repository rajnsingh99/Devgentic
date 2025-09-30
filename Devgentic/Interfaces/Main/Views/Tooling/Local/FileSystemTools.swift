//
//  FileSystemTools.swift
//  LocalServer
//
//  Created by Raj Singh on 21/09/25.
//

import Foundation

// MARK: - List Directory Tool

/// A tool to list the contents of a specified directory.
struct ListDirectoryTool: ExecutableTool {
    var name: String = "list_directory"
    var description: String = "Lists all files and folders in a specified directory. Returns a comma-separated list."
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [
            "path": ToolParameterProperty(type: "string", description: "The full path to the directory (e.g., '/Users/user/Desktop').")
        ],
        required: ["path"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw NSError(domain: "FileSystemToolError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required 'path' argument."])
        }

        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(atPath: path)
        return contents.joined(separator: ", ")
    }
}

// MARK: - Read File Tool

/// A tool to read the contents of a file.
struct ReadFileTool: ExecutableTool {
    var name: String = "read_file"
    var description: String = "Reads the entire content of a text file and returns it as a string."
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [
            "path": ToolParameterProperty(type: "string", description: "The full path to the file to be read.")
        ],
        required: ["path"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw NSError(domain: "FileSystemToolError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required 'path' argument."])
        }

        return try String(contentsOfFile: path, encoding: .utf8)
    }
}

// MARK: - Write File Tool

/// A tool to write content to a file.
struct WriteFileTool: ExecutableTool {
    var name: String = "write_file"
    var description: String = "Writes or overwrites a text file with the provided content. Creates the file if it does not exist."
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [
            "path": ToolParameterProperty(type: "string", description: "The full path to the file to be written."),
            "content": ToolParameterProperty(type: "string", description: "The text content to write into the file.")
        ],
        required: ["path", "content"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw NSError(domain: "FileSystemToolError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required 'path' argument."])
        }
        guard let content = arguments["content"] as? String else {
            throw NSError(domain: "FileSystemToolError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing required 'content' argument."])
        }

        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return "Successfully wrote content to \(path)."
    }
}

// MARK: - Delete File Tool

/// A tool to delete a file.
struct DeleteFileTool: ExecutableTool {
    var name: String = "delete_file"
    var description: String = "Permanently deletes a specified file from the file system."
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [
            "path": ToolParameterProperty(type: "string", description: "The full path of the file to delete.")
        ],
        required: ["path"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let path = arguments["path"] as? String else {
            throw NSError(domain: "FileSystemToolError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required 'path' argument."])
        }

        try FileManager.default.removeItem(atPath: path)
        return "Successfully deleted file at \(path)."
    }
}
