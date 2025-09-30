//
//  SystemTools.swift
//  LocalServer
//
//  Created by Raj Singh on 21/09/25.
//

import Foundation
import AppKit // Required for NSPasteboard (Clipboard)

// MARK: - Get Clipboard Content Tool

/// A tool to retrieve the current text content from the system clipboard.
@MainActor // Interacting with NSPasteboard must be done on the main thread.
struct GetClipboardContentTool: ExecutableTool {
    var name: String = "get_clipboard_content"
    var description: String = "Retrieves the current text content from the system clipboard."
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [:], // No parameters are needed for this tool.
        required: []
    )

    func execute(arguments: [String: Any]) async throws -> String {
        return NSPasteboard.general.string(forType: .string) ?? "Clipboard does not contain text."
    }
}


// MARK: - Set Clipboard Content Tool

/// A tool to place text content onto the system clipboard.
@MainActor // Interacting with NSPasteboard must be done on the main thread.
struct SetClipboardContentTool: ExecutableTool {
    var name: String = "set_clipboard_content"
    var description: String = "Places a given string of text onto the system clipboard."
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [
            "content": ToolParameterProperty(type: "string", description: "The text content to place on the clipboard.")
        ],
        required: ["content"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let content = arguments["content"] as? String else {
            throw NSError(domain: "SystemToolError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required 'content' argument."])
        }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        
        return "Successfully set clipboard content."
    }
}


// MARK: - Get System Stats Tool

/// A tool to retrieve basic information about the macOS system.
struct GetSystemStatsTool: ExecutableTool {
    var name: String = "get_system_stats"
    var description: String = "Retrieves basic system information like macOS version, active username, and device model."
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [:], // No parameters are needed for this tool.
        required: []
    )

    func execute(arguments: [String: Any]) async throws -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let userName = ProcessInfo.processInfo.fullUserName
        
        // Use sysctl to get the hardware model identifier (e.g., "MacBookPro18,1")
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let deviceModel = String(cString: model)

        let stats = [
            "os_version": osVersion,
            "username": userName,
            "device_model": deviceModel
        ]

        // Return the stats as a JSON string for easy parsing by the agent.
        let jsonData = try JSONSerialization.data(withJSONObject: stats, options: .prettyPrinted)
        return String(data: jsonData, encoding: .utf8) ?? "Error: Could not serialize system stats."
    }
}
