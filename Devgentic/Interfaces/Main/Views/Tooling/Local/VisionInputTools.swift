//
//  VisionInputTools.swift
//  Devgentic
//

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// MARK: - Type Text Tool

struct TypeTextTool: DevgenticTool {
    let name = "type_text"
    let category = "Vision & UI"
    let description = "Types text into the currently focused application using simulated keystrokes."

    struct Arguments: Decodable, Sendable {
        let text: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("text", "string", "The text to type into the focused application.")
            ],
            required: ["text"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Typed \(arguments.text.count) characters",
            operations: [["length": String(arguments.text.count)]]
        )

        let src = CGEventSource(stateID: .hidSystemState)

        for char in arguments.text {
            let str = String(char)
            let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            event?.keyboardSetUnicodeString(string: str)
            event?.post(tap: .cghidEventTap)

            let upEvent = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            upEvent?.keyboardSetUnicodeString(string: str)
            upEvent?.post(tap: .cghidEventTap)

            // Small delay between keystrokes for reliability
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        return "Successfully typed \(arguments.text.count) characters. (Audit Ref: \(logID))"
    }
}

private extension CGEvent {
    func keyboardSetUnicodeString(string: String) {
        let chars = Array(string.utf16)
        self.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
    }
}

// MARK: - Press Key Combo Tool

struct PressKeyComboTool: DevgenticTool {
    let name = "press_key_combo"
    let category = "Vision & UI"
    let description = "Sends keyboard shortcuts (e.g. Cmd+S, Cmd+Tab, Ctrl+C) to the system."

    struct Arguments: Decodable, Sendable {
        let keys: String
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("keys", "string", "Key combo string like 'cmd+s', 'cmd+shift+n', 'ctrl+c', 'return', 'escape', 'tab', 'space', 'delete', 'up', 'down', 'left', 'right'.")
            ],
            required: ["keys"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Pressed key combo: \(arguments.keys)",
            operations: [["keys": arguments.keys]]
        )

        let parts = arguments.keys.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode = 0
        var foundKey = false

        for part in parts {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "option": flags.insert(.maskAlternate)
            default:
                keyCode = Self.keyCodeForString(part)
                foundKey = true
            }
        }

        guard foundKey else {
            return "Error: No key specified in '\(arguments.keys)'. (Audit Ref: \(logID))"
        }

        let src = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return "Error: Failed to create key events. (Audit Ref: \(logID))"
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return "Successfully pressed '\(arguments.keys)'. (Audit Ref: \(logID))"
    }

    private static func keyCodeForString(_ key: String) -> CGKeyCode {
        switch key {
        case "a": return 0; case "b": return 11; case "c": return 8; case "d": return 2
        case "e": return 14; case "f": return 3; case "g": return 5; case "h": return 4
        case "i": return 34; case "j": return 38; case "k": return 40; case "l": return 37
        case "m": return 46; case "n": return 45; case "o": return 31; case "p": return 35
        case "q": return 12; case "r": return 15; case "s": return 1; case "t": return 17
        case "u": return 32; case "v": return 9; case "w": return 13; case "x": return 7
        case "y": return 16; case "z": return 6
        case "0": return 29; case "1": return 18; case "2": return 19; case "3": return 20
        case "4": return 21; case "5": return 23; case "6": return 22; case "7": return 26
        case "8": return 28; case "9": return 25
        case "return", "enter": return 36
        case "escape", "esc": return 53
        case "tab": return 48
        case "space": return 49
        case "delete", "backspace": return 51
        case "forwarddelete": return 117
        case "up": return 126; case "down": return 125; case "left": return 123; case "right": return 124
        case "f1": return 122; case "f2": return 120; case "f3": return 99; case "f4": return 118
        case "f5": return 96; case "f6": return 97; case "f7": return 98; case "f8": return 100
        case "f9": return 101; case "f10": return 109; case "f11": return 103; case "f12": return 111
        case "home": return 115; case "end": return 119
        case "pageup": return 116; case "pagedown": return 121
        case "-", "minus": return 27; case "=", "equals": return 24
        case "[": return 33; case "]": return 30
        case ";": return 41; case "'": return 39
        case ",": return 43; case ".": return 47; case "/": return 44
        case "\\": return 42; case "`": return 50
        default: return 0
        }
    }
}

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
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Scrolled \(arguments.direction)",
            operations: [["direction": arguments.direction]]
        )

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
            return "Error: Unknown direction '\(arguments.direction)'. Use up/down/left/right. (Audit Ref: \(logID))"
        }

        // Move cursor to position first
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: posX, y: posY), mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) {
            scrollEvent.post(tap: .cghidEventTap)
        }

        return "Scrolled \(arguments.direction) by \(amount) lines at (\(Int(posX)), \(Int(posY))). (Audit Ref: \(logID))"
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
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Read UI element tree",
            operations: []
        )

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return "Error: Accessibility permission denied. (Audit Ref: \(logID))"
        }

        let maxDepth = min(arguments.max_depth ?? 3, 5)
        let app: NSRunningApplication?

        if let bundleID = arguments.app_bundle_id {
            app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }

        guard let runningApp = app else {
            return "Error: Application not found. (Audit Ref: \(logID))"
        }

        let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        var output = "UI Tree for \(runningApp.localizedName ?? "Unknown") (depth: \(maxDepth)):\n"
        output += dumpElement(appElement, depth: 0, maxDepth: maxDepth)

        // Cap output to prevent excessive responses
        let maxOutput = 8000
        if output.count > maxOutput {
            output = String(output.prefix(maxOutput)) + "\n...[Truncated at \(maxOutput) chars]"
        }

        return "\(output)\n(Audit Ref: \(logID))"
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
