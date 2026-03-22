//
//  VisionAutomationTools.swift
//  Devgentic
//

import Foundation
import ScreenCaptureKit
import Vision
import AppKit
import ApplicationServices

// MARK: - Read Screen State Tool

struct ReadScreenStateTool: DevgenticTool {
    let name = "read_screen_state"
    let category = "Vision & UI"
    let description = "Takes a silent capture of the screen and extracts structural text for UI understanding."
    
    struct Arguments: Decodable, Sendable {}
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }
    
    func call(arguments: Arguments) async throws -> String {
        guard CGPreflightScreenCaptureAccess() else {
            return "Error: Screen recording permission denied."
        }
        
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            return "Error: No displays found."
        }
        
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        
        let requestHandler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        
        try requestHandler.perform([request])
        
        guard let observations = request.results as? [VNRecognizedTextObservation] else {
            return "No text recognized."
        }
        
        var recognizedElements: [[String: Any]] = []
        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            let boundingBox = observation.boundingBox
            
            recognizedElements.append([
                "text": topCandidate.string,
                "confidence": topCandidate.confidence,
                "boundingBox": [
                    "x": boundingBox.origin.x,
                    "y": boundingBox.origin.y,
                    "width": boundingBox.width,
                    "height": boundingBox.height
                ]
            ])
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: recognizedElements, options: .prettyPrinted)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"
        
        return "Screen state extracted successfully:\n\(jsonString)"
    }
}

// MARK: - Click UI Element Tool

struct ClickUIElementTool: DevgenticTool {
    let name = "click_ui_element"
    let category = "Vision & UI"
    let description = "Programmatically clicks UI elements based on their accessibility labels or titles."
    
    struct Arguments: Decodable, Sendable {
        let label: String
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("label", "string", "The accessibility label or title of the element to click.")
            ],
            required: ["label"]
        )
    }
    
    func call(arguments: Arguments) async throws -> String {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            return "Error: Accessibility permission denied."
        }
        
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return "Error: No frontmost application."
        }
        
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        
        // Find element by recursing up to 4 levels deep to prevent freezing
        func search(element: AXUIElement, targetLabel: String, depth: Int) -> AXUIElement? {
            if depth > 4 { return nil }
            
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success, let title = value as? String, title.localizedCaseInsensitiveContains(targetLabel) {
                 return element
            }
            if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value) == .success, let desc = value as? String, desc.localizedCaseInsensitiveContains(targetLabel) {
                 return element
            }
            
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success, let children = childrenRef as? [AXUIElement] {
                for child in children {
                    if let found = search(element: child, targetLabel: targetLabel, depth: depth + 1) {
                        return found
                    }
                }
            }
            return nil
        }
        
        guard let target = search(element: appElement, targetLabel: arguments.label, depth: 0) else {
            return "Error: Could not find UI element with label '\(arguments.label)' in the frontmost application."
        }
        
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        if result == .success {
            return "Successfully clicked element '\(arguments.label)'."
        } else {
            return "Error: Could not perform click action on element '\(arguments.label)'. AXError: \(result.rawValue)"
        }
    }
}
