// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkspaceManagementTools.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import AppKit
import ApplicationServices

struct ManageWindowsTool: DevgenticTool {
    let name = "manage_windows"
    let category = "Workspace Management"
    let description = "Manages application windows: tile, fullscreen, minimize, center, resize, list all windows, bring to front, close, or move to display."

    struct Arguments: Decodable, Sendable {
        let action: String
        let bundle_id: String?
        let width: Int?
        let height: Int?
        let display_index: Int?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.action = try container.decode(String.self, forKey: DynamicKey(stringValue: "action")!)

            var bid: String? = nil
            for key in ["bundle_id", "bundleId", "app_id", "bundleID"] {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    bid = val
                    break
                }
            }
            self.bundle_id = bid
            self.width = (try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "width")!))
            self.height = (try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "height")!))
            self.display_index = (try? container.decodeIfPresent(Int.self, forKey: DynamicKey(stringValue: "display_index")!))
        }
    }

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("action", "string", "Action: 'tile_left', 'tile_right', 'fullscreen', 'minimize', 'center', 'resize', 'list_windows', 'bring_to_front', 'close_window', 'move_to_display'"),
                ("bundle_id", "string", "Bundle ID of the app (required for most actions except list_windows)"),
                ("width", "integer", "Window width in pixels (for resize)"),
                ("height", "integer", "Window height in pixels (for resize)"),
                ("display_index", "integer", "Target display index, 0-based (for move_to_display)")
            ],
            required: ["action"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return "Error: Accessibility permission denied."
        }

        if arguments.action == "list_windows" {
            return listAllWindows()
        }

        guard let bundleID = arguments.bundle_id else {
            return "Error: 'bundle_id' required for action '\(arguments.action)'."
        }

        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        guard let app = apps.first else {
            return "Error: App with bundle ID \(bundleID) is not running."
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var frontWindowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &frontWindowRef) != .success {
            if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &frontWindowRef) != .success {
                return "Error: App has no accessible windows."
            }
        }
        guard let window = frontWindowRef else {
            return "Error: App has no accessible windows."
        }
        let targetWindow = window as! AXUIElement

        switch arguments.action {
        case "bring_to_front":
            app.activate()
            AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
            return "Brought \(app.localizedName ?? bundleID) to front."

        case "close_window":
            var closeButtonRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(targetWindow, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success, let closeButton = closeButtonRef {
                AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
                return "Closed window."
            }
            return "Error: Could not find close button."

        case "minimize":
            let minVal = true as CFTypeRef
            AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, minVal)
            return "Minimized window."

        case "resize":
            guard let w = arguments.width, let h = arguments.height else {
                return "Error: 'width' and 'height' required for resize."
            }
            var newSize = CGSize(width: CGFloat(w), height: CGFloat(h))
            if let sizeVal = AXValueCreate(AXValueType.cgSize, &newSize) {
                AXUIElementSetAttributeValue(targetWindow, kAXSizeAttribute as CFString, sizeVal)
            }
            return "Resized window to \(w)x\(h)."

        case "move_to_display":
            let displayIdx = arguments.display_index ?? 0
            let screens = NSScreen.screens
            guard displayIdx < screens.count else {
                return "Error: Display index \(displayIdx) not found. Available: 0-\(screens.count - 1)."
            }
            let targetScreen = screens[displayIdx]
            var newPos = targetScreen.frame.origin
            newPos.y = NSScreen.screens[0].frame.height - targetScreen.frame.origin.y - targetScreen.frame.height
            if let posVal = AXValueCreate(AXValueType.cgPoint, &newPos) {
                AXUIElementSetAttributeValue(targetWindow, kAXPositionAttribute as CFString, posVal)
            }
            return "Moved window to display \(displayIdx)."

        default:
            guard NSScreen.main != nil else {
                return "Error: No main screen found."
            }
            let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
            var newPosition = CGPoint.zero
            var newSize = CGSize.zero
            let width = mainDisplayBounds.width
            let height = mainDisplayBounds.height

            switch arguments.action {
            case "tile_left":
                newPosition = .zero
                newSize = CGSize(width: width / 2, height: height)
            case "tile_right":
                newPosition = CGPoint(x: width / 2, y: 0)
                newSize = CGSize(width: width / 2, height: height)
            case "fullscreen":
                newPosition = .zero
                newSize = CGSize(width: width, height: height)
            case "center":
                let w = width * 0.7
                let h = height * 0.7
                newPosition = CGPoint(x: (width - w)/2, y: (height - h)/2)
                newSize = CGSize(width: w, height: h)
            default:
                return "Error: Unknown action '\(arguments.action)'."
            }

            if let sizeVal = AXValueCreate(AXValueType.cgSize, &newSize) {
                AXUIElementSetAttributeValue(targetWindow, kAXSizeAttribute as CFString, sizeVal)
            }
            if let posVal = AXValueCreate(AXValueType.cgPoint, &newPosition) {
                AXUIElementSetAttributeValue(targetWindow, kAXPositionAttribute as CFString, posVal)
            }
            return "Window action '\(arguments.action)' applied."
        }
    }

    private func listAllWindows() -> String {
        var windowList: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement] {
                for (idx, window) in windows.enumerated() {
                    var titleRef: CFTypeRef?
                    var title = "Untitled"
                    if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                       let t = titleRef as? String, !t.isEmpty {
                        title = t
                    }
                    windowList.append("[\(app.localizedName ?? "Unknown") | \(app.bundleIdentifier ?? "")] Window \(idx): \"\(title)\"")
                }
            }
        }
        if windowList.isEmpty {
            return "No accessible windows found."
        }
        return "Open Windows (\(windowList.count)):\n\(windowList.joined(separator: "\n"))"
    }
}
