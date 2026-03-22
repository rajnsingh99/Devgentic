//
//  AdvancedFinderTools.swift
//  Devgentic
//

import Foundation
import AppKit

struct ManageFinderTagsTool: DevgenticTool {
    let name = "manage_finder_tags"
    let category = "Advanced Finder & File Management"
    let description = "Reads tags for a specific file."
    
    struct Arguments: Decodable, Sendable {
        let action: String
        let file_path: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action ('read_tags')"),
                ("file_path", "string", "Absolute path to the file")
            ],
            required: ["action", "file_path"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let url = URL(fileURLWithPath: arguments.file_path)
        do {
            let resourceValues = try url.resourceValues(forKeys: [.tagNamesKey])
            let tags = resourceValues.tagNames ?? []
            return "Tags for \(url.lastPathComponent):\n\(tags.joined(separator: ", "))"
        } catch {
            return "Error reading tags: \(error.localizedDescription)"
        }
    }
}

struct TriggerQuickLookTool: DevgenticTool {
    let name = "trigger_quicklook"
    let category = "Advanced Finder & File Management"
    let description = "Opens a file instantly using macOS QuickLook."
    
    struct Arguments: Decodable, Sendable {
        let file_path: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("file_path", "string", "Absolute file path")
            ],
            required: ["file_path"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", arguments.file_path]
        let outPipe = Pipe()
        process.standardOutput = outPipe

        do {
            try process.run()
            return "QuickLook opened for \(arguments.file_path)."
        } catch {
            return "Error triggering QuickLook: \(error)"
        }
    }
}

struct EmptyTrashTool: DevgenticTool {
    let name = "empty_trash"
    let category = "Advanced Finder & File Management"
    let description = "Empties the macOS Trash."
    
    struct Arguments: Decodable, Sendable {}
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }
    
    func call(arguments: Arguments) async throws -> String {
        return await MainActor.run {
            let script = """
            tell application "Finder"
                empty trash
            end tell
            """
            var errorInfo: NSDictionary?
            let scriptObj = NSAppleScript(source: script)
            _ = scriptObj?.executeAndReturnError(&errorInfo)

            if let err = errorInfo {
                return "AppleScript Error while emptying trash: \(err)"
            }
            return "Trash emptied successfully."
        }
    }
}
