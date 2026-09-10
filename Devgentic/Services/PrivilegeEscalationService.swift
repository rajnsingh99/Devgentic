// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
// Services/PrivilegeEscalationService.swift
import Foundation
import os

private let logger = DGLogger(category: "PrivilegeEscalation")

struct PrivilegeEscalationService {

    /// Executes a command with administrator privileges using AppleScript.
    /// Note: This method triggers standard macOS password prompts and might not be suitable for all distribution methods (e.g., App Store).
    /// Consider SMJobBless/XPC for a more robust, production-ready solution.
    ///
    /// - Parameters:
    ///   - commandPath: The absolute path to the executable. Must be quoted if it contains spaces.
    ///   - arguments: An array of string arguments for the command. Arguments with spaces should ideally be quoted within the array element itself.
    /// - Returns: `true` if the command appeared to execute without AppleScript throwing an error, `false` otherwise (including user cancellation).
    func executeWithAdminPrivileges(commandPath: String, arguments: [String]) async -> Bool {
        // Construct the full shell command, ensuring arguments are reasonably quoted.
        // Basic quoting: wrap arguments containing spaces in single quotes. More robust quoting might be needed.
        let processedArguments = arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        let fullCommand = "\(commandPath) \(processedArguments)"

        // Escape the command for embedding within the AppleScript string
        let escapedCommand = fullCommand.replacingOccurrences(of: "\"", with: "\\\"")

        let appleScriptSource = """
        do shell script "\(escapedCommand)" with administrator privileges
        """

        logger.info("Attempting to execute with admin privileges: \(fullCommand)")

        var errorDict: NSDictionary? = nil
        if let scriptObject = NSAppleScript(source: appleScriptSource) {
            // NSAppleScript runs synchronously, so wrap in a Task for async context if needed,
            // but the execution itself will block until the script finishes or fails.
            // In this async function, it's okay to run it directly.
            let eventDescriptor = scriptObject.executeAndReturnError(&errorDict)

            if let error = errorDict {
                logger.error("AppleScript execution failed: \(error)")
                // Check for user cancellation error code (-128)
                if let errorCode = error[NSAppleScript.errorNumber] as? Int, errorCode == -128 {
                     logger.warning("Admin command execution cancelled by user.")
                 } else {
                     logger.error("Admin command execution failed with error: \(error.description)")
                 }
                return false
            } else {
                // Even if eventDescriptor is nil, no error means it likely succeeded or the command had no output.
                logger.info("AppleScript executed successfully (or without error). Event descriptor: \(eventDescriptor.description)")
                return true
            }
        } else {
            logger.error("Failed to create NSAppleScript object.")
            return false
        }
    }
}
