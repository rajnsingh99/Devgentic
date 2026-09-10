// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  VisionInputTools.swift
//  Devgentic
//

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Type Text Tool

// MARK: - Scroll UI Tool

struct ScrollUITool: DevgenticTool {
    let name = "scroll_ui"
    let category = "Vision & UI"
    let description = "Scrolls the screen at a given position. Useful for scrolling within apps."

    struct Arguments: Decodable, Sendable {
        let direction: String
        let amount: Int?
        let x: Int?
        let y: Int?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("direction", "string", "Scroll direction: 'up', 'down', 'left', 'right'"),
                ("amount", "integer", "Scroll amount in lines (default 3)"),
                ("x", "integer", "X coordinate to scroll at (default: center of screen)"),
                ("y", "integer", "Y coordinate to scroll at (default: center of screen)")
            ],
            required: ["direction"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let amount = Int32(arguments.amount ?? 3)
        let screenBounds = CGDisplayBounds(CGMainDisplayID())
        let posX = CGFloat(arguments.x ?? Int(screenBounds.width / 2))
        let posY = CGFloat(arguments.y ?? Int(screenBounds.height / 2))

        var deltaX: Int32 = 0
        var deltaY: Int32 = 0

        switch arguments.direction {
        case "up": deltaY = amount
        case "down": deltaY = -amount
        case "left": deltaX = amount
        case "right": deltaX = -amount
        default:
            return "Error: Unknown direction '\(arguments.direction)'. Use up/down/left/right."
        }

        // Move cursor to position first
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: posX, y: posY), mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) {
            scrollEvent.post(tap: .cghidEventTap)
        }

        return "Scrolled \(arguments.direction) by \(amount) lines at (\(Int(posX)), \(Int(posY)))."
    }
}

// MARK: - Read UI Element Tree Tool

struct ReadUIElementTreeTool: DevgenticTool {
    let name = "read_ui_element_tree"
    let category = "Vision & UI"
    let description = "Dumps the accessibility element hierarchy of the frontmost app for UI inspection."

    struct Arguments: Decodable, Sendable {
        let max_depth: Int?
        let app_bundle_id: String?
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("max_depth", "integer", "Maximum depth to traverse (default 3, max 5)"),
                ("app_bundle_id", "string", "Bundle ID of app to inspect (default: frontmost app)")
            ],
            required: []
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return "Error: Accessibility permission denied."
        }

        let maxDepth = min(arguments.max_depth ?? 3, 5)
        let app: NSRunningApplication?

        if let bundleID = arguments.app_bundle_id {
            app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }

        guard let runningApp = app else {
            return "Error: Application not found."
        }

        let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        var output = "UI Tree for \(runningApp.localizedName ?? "Unknown") (depth: \(maxDepth)):\n"
        output += dumpElement(appElement, depth: 0, maxDepth: maxDepth)

        // Cap output to prevent excessive responses
        let maxOutput = 8000
        if output.count > maxOutput {
            output = String(output.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars]"
        }

        return output
    }

    private func dumpElement(_ element: AXUIElement, depth: Int, maxDepth: Int) -> String {
        if depth > maxDepth { return "" }

        let indent = String(repeating: "  ", count: depth)
        var line = indent

        // Get role
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success, let role = roleRef as? String {
            line += "[\(role)]"
        } else {
            line += "[Unknown]"
        }

        // Get title
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success, let title = titleRef as? String, !title.isEmpty {
            line += " \"\(title)\""
        }

        // Get value (for text fields etc)
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success, let value = valueRef as? String, !value.isEmpty {
            let truncVal = value.count > 50 ? String(value.prefix(50)) + "..." : value
            line += " value=\"\(truncVal)\""
        }

        // Get description
        var descRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef) == .success, let desc = descRef as? String, !desc.isEmpty {
            line += " desc=\"\(desc)\""
        }

        line += "\n"

        // Recurse into children
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success, let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(20) { // Cap children per level
                line += dumpElement(child, depth: depth + 1, maxDepth: maxDepth)
            }
        }

        return line
    }
}
