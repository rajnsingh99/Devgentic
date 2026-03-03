//
//  WorkspaceManagementTools.swift
//  Devgentic
//

import Foundation
import AppKit
import ApplicationServices

struct ManageWindowsTool: DevgenticTool {
    let name = "manage_windows"
    let category = "Workspace Management"
    let description = "Resizes, moves, or minimizes application windows to organize the workspace."
    
    struct Arguments: Decodable, Sendable {
        let bundle_id: String
        let action: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("bundle_id", "string", "The bundle identifier of the app."),
                ("action", "string", "The action to perform (tile_left, tile_right, fullscreen, minimize, center).")
            ],
            required: ["bundle_id", "action"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Managed window for \(arguments.bundle_id)",
            operations: [
                ["bundle_id": arguments.bundle_id, "action": arguments.action]
            ]
        )
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return "Error: Accessibility permission denied. (Audit Ref: \(logID))"
        }
        
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == arguments.bundle_id }
        guard let app = apps.first else {
            return "Error: App with bundle ID \(arguments.bundle_id) is not running. (Audit Ref: \(logID))"
        }
        
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        
        var frontWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &frontWindowRef)
        
        guard result == .success, let frontWindow = frontWindowRef else {
            var mainWindowRef: CFTypeRef?
            let mainResult = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &mainWindowRef)
            guard mainResult == .success, let main = mainWindowRef else {
                return "Error: App has no accessible windows. (Audit Ref: \(logID))"
            }
            frontWindowRef = main
            return "Error: App has no accessible windows. (Audit Ref: \(logID))"
        }
        
        let targetWindow = frontWindowRef as! AXUIElement
        
        guard NSScreen.main != nil else {
            return "Error: No main screen found. (Audit Ref: \(logID))"
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
        case "minimize":
            let minVal = true as CFTypeRef
            AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, minVal)
            return "Minimized window successfully. (Audit Ref: \(logID))"
        default:
            return "Error: Unknown action '\(arguments.action)'. (Audit Ref: \(logID))"
        }
        
        if let sizeVal = AXValueCreate(AXValueType.cgSize, &newSize) {
            AXUIElementSetAttributeValue(targetWindow, kAXSizeAttribute as CFString, sizeVal)
        }
        
        if let posVal = AXValueCreate(AXValueType.cgPoint, &newPosition) {
            AXUIElementSetAttributeValue(targetWindow, kAXPositionAttribute as CFString, posVal)
        }
        
        return "Window action '\(arguments.action)' applied successfully. (Audit Ref: \(logID))"
    }
}
