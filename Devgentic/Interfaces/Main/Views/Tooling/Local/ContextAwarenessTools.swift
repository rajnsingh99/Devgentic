//
//  ContextAwarenessTools.swift
//  Devgentic
//

import Foundation
import AppKit

struct GetFocusContextTool: DevgenticTool {
    let name = "get_focus_context"
    let category = "Deep Context Awareness"
    let description = "Retrieves the currently focused application and its active window title."
    
    struct Arguments: Decodable, Sendable {}
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }
    
    func call(arguments: Arguments) async throws -> String {
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Retrieved Focus Context",
            operations: []
        )
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return "Error: Accessibility permission denied. (Audit Ref: \(logID))"
        }
        
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return "No frontmost application. (Audit Ref: \\(logID))"
        }
        
        let appName = frontmostApp.localizedName ?? "Unknown App"
        let bundleID = frontmostApp.bundleIdentifier ?? "Unknown Bundle ID"
        
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var frontWindowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &frontWindowRef)
        
        var windowTitle = "Unknown Window"
        if result == .success, let frontWindow = frontWindowRef {
            let targetWindow = frontWindow as! AXUIElement
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(targetWindow, kAXTitleAttribute as CFString, &titleRef) == .success, let title = titleRef as? String {
                windowTitle = title
            }
        }
        
        return """
        Active Application: \(appName) (\(bundleID))
        Focused Window: \(windowTitle)
        (Audit Ref: \(logID))
        """
    }
}
