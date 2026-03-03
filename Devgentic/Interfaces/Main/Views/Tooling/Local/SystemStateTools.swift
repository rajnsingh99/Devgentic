//
//  SystemStateTools.swift
//  Devgentic
//

import Foundation
import AppKit
import UserNotifications

struct ManageClipboardTool: DevgenticTool {
    let name = "manage_clipboard"
    let category = "System State"
    let description = "Reads from or writes text to the macOS clipboard."
    
    struct Arguments: Decodable, Sendable {
        let action: String
        let text: String?
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "'read' or 'write'"),
                ("text", "string", "Text to write to the clipboard (required for 'write')")
            ],
            required: ["action"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Clipboard action: \(arguments.action)",
            operations: [
                ["action": arguments.action]
            ]
        )
        
        return await MainActor.run {
            let pb = NSPasteboard.general
            if arguments.action == "read" {
                if let str = pb.string(forType: .string) {
                    return "Clipboard Contents:\n\(str)\n(Audit Ref: \(logID))"
                } else {
                    return "Clipboard is empty or does not contain text. (Audit Ref: \(logID))"
                }
            } else if arguments.action == "write" {
                guard let text = arguments.text else {
                    return "Error: 'text' is required for 'write' action. (Audit Ref: \(logID))"
                }
                pb.clearContents()
                pb.setString(text, forType: .string)
                return "Successfully wrote to clipboard. (Audit Ref: \(logID))"
            }
            return "Error: Unknown action '\(arguments.action)'. (Audit Ref: \(logID))"
        }
    }
}

struct PushLocalNotificationTool: DevgenticTool {
    let name = "push_local_notification"
    let category = "System State"
    let description = "Pushes a notification to the macOS Notification Center."
    
    struct Arguments: Decodable, Sendable {
        let title: String
        let body: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("title", "string", "Notification title"),
                ("body", "string", "Notification body text")
            ],
            required: ["title", "body"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Pushed notification: \(arguments.title)",
            operations: [
                ["title": arguments.title]
            ]
        )
        
        let center = UNUserNotificationCenter.current()
        let options: UNAuthorizationOptions = [.alert, .sound]
        
        let access = try await center.requestAuthorization(options: options)
        guard access else {
            return "Error: Notification permission denied. (Audit Ref: \(logID))"
        }
        
        let content = UNMutableNotificationContent()
        content.title = arguments.title
        content.body = arguments.body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(request)
        
        return "Notification pushed successfully. (Audit Ref: \(logID))"
    }
}
