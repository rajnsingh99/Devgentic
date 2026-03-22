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
    let description = "Manages the macOS clipboard: read/write text, read/write images, check content type."

    struct Arguments: Decodable, Sendable {
        let action: String
        let text: String?
        let image_path: String?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'read', 'write', 'read_image', 'write_image', 'get_types'"),
                ("text", "string", "Text to write (required for 'write')"),
                ("image_path", "string", "File path to save/load image (for read_image saves to path, write_image loads from path)")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        return await MainActor.run {
            let pb = NSPasteboard.general

            switch arguments.action {
            case "read":
                if let str = pb.string(forType: .string) {
                    return "Clipboard Contents:\n\(str)"
                } else {
                    return "Clipboard is empty or does not contain text."
                }

            case "write":
                guard let text = arguments.text else {
                    return "Error: 'text' is required for 'write' action."
                }
                pb.clearContents()
                pb.setString(text, forType: .string)
                return "Successfully wrote to clipboard."

            case "read_image":
                guard let imgData = pb.data(forType: .tiff) ?? pb.data(forType: .png) else {
                    return "No image data on clipboard."
                }
                let savePath = (arguments.image_path as NSString?)?.expandingTildeInPath
                    ?? NSTemporaryDirectory() + "clipboard_image_\(UUID().uuidString.prefix(8)).png"
                guard let image = NSImage(data: imgData),
                      let tiffData = image.tiffRepresentation,
                      let bitmapRep = NSBitmapImageRep(data: tiffData),
                      let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                    return "Error: Could not convert clipboard image."
                }
                do {
                    try pngData.write(to: URL(fileURLWithPath: savePath))
                    return "Saved clipboard image to: \(savePath) (\(pngData.count) bytes)"
                } catch {
                    return "Error saving image: \(error.localizedDescription)"
                }

            case "write_image":
                guard let imagePath = arguments.image_path else {
                    return "Error: 'image_path' required for write_image."
                }
                let expandedPath = (imagePath as NSString).expandingTildeInPath
                guard let image = NSImage(contentsOfFile: expandedPath) else {
                    return "Error: Could not load image from '\(expandedPath)'."
                }
                pb.clearContents()
                pb.writeObjects([image])
                return "Image copied to clipboard from \(expandedPath)."

            case "get_types":
                let types = pb.types?.map { $0.rawValue } ?? []
                return "Clipboard content types: \(types.joined(separator: ", "))"

            default:
                return "Error: Unknown action '\(arguments.action)'."
            }
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
        let center = UNUserNotificationCenter.current()
        let options: UNAuthorizationOptions = [.alert, .sound]
        
        let access = try await center.requestAuthorization(options: options)
        guard access else {
            return "Error: Notification permission denied."
        }
        
        let content = UNMutableNotificationContent()
        content.title = arguments.title
        content.body = arguments.body
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try await center.add(request)
        
        return "Notification pushed successfully."
    }
}
