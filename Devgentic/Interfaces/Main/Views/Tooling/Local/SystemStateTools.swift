// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
        // ⚠️ ROUTED THROUGH THE DISPATCHER, NOT `UNUserNotificationCenter` DIRECTLY. This tool used
        // to build its own `UNMutableNotificationContent` and call `center.add(request)`, which made
        // it the one notification path in the app that no user setting could stop: neither the
        // "Enable Notifications" master switch nor the per-channel switches in Settings had any
        // effect on it, because it never touched the dispatcher they gate. An agent could notify a
        // user who had switched notifications off.
        //
        // ⚠️ It also called `requestAuthorization` itself, prompting for system permission from
        // inside a tool call. `LocalNotificationChannel.send` already handles every authorization
        // state — including `.denied`, which it reports with a message naming System Settings —
        // so that prompt is not lost, it is just no longer duplicated here.
        let delivered = await NotificationDispatcher.shared.dispatch(
            AppNotificationPayload(
                title: arguments.title,
                body: arguments.body,
                metadata: ["source": "push_local_notification"]
            )
        )

        guard delivered > 0 else {
            // Truthful, and actionable: the previous implementation said "pushed successfully"
            // for anything that did not throw.
            return "Notification not delivered. Notifications are switched off in Devgentic's "
                + "settings, or no notification channel is enabled. Nothing was shown to the user."
        }
        return "Notification pushed successfully to \(delivered) channel(s)."
    }
}
