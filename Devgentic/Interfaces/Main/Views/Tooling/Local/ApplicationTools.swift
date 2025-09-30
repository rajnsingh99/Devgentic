//
//  ApplicationTools.swift
//  LocalServer
//
//  Created by Raj Singh on 21/09/25.
//

import Foundation
import AppKit // Required for NSWorkspace and NSAppleScript

// MARK: - Open Application Tool

/// A tool to launch a specified application using its bundle identifier.
@MainActor // Interacting with NSWorkspace must be done on the main thread.
struct OpenApplicationTool: ExecutableTool {
    var name: String = "open_application"
    var description: String = "Launches a specified application on macOS using its unique bundle identifier (e.g., 'com.apple.Safari', 'com.apple.dt.Xcode', 'com.apple.Notes')."
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [
            "bundle_identifier": ToolParameterProperty(type: "string", description: "The bundle identifier of the application to open.")
        ],
        required: ["bundle_identifier"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let bundleID = arguments["bundle_identifier"] as? String else {
            throw NSError(domain: "ApplicationToolError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing required 'bundle_identifier' argument."])
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return "Error: Application with bundle identifier '\(bundleID)' not found."
        }
        
        // Use the modern async method to launch the application.
        try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        
        return "Successfully launched \(bundleID)."
    }
}


// MARK: - Run AppleScript Tool

/// A tool to execute an AppleScript command.
struct RunAppleScriptTool: ExecutableTool {
    var name: String = "run_applescript"
    var description: String = "Executes a given AppleScript command. Useful for automating tasks within and between applications."
    var parameters: ToolParameters = ToolParameters(
        type: "object",
        properties: [
            "script": ToolParameterProperty(type: "string", description: "The AppleScript code to execute.")
        ],
        required: ["script"]
    )

    func execute(arguments: [String: Any]) async throws -> String {
        guard let scriptSource = arguments["script"] as? String else {
            throw NSError(domain: "ApplicationToolError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing required 'script' argument."])
        }

        // Running AppleScript is a synchronous operation, so we wrap it to be non-blocking.
        return try await Task.detached {
            guard let script = NSAppleScript(source: scriptSource) else {
                throw NSError(domain: "ApplicationToolError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize AppleScript."])
            }
            
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)

            if let error = errorInfo {
                let errorMessage = error[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error."
                return "AppleScript Error: \(errorMessage)"
            }
            
            return descriptor.stringValue ?? "AppleScript executed successfully but returned no text output."
        }.value
    }
}

