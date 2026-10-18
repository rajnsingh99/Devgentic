// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPErrorAnalyzer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

struct MCPUserError: Equatable {
    let title: String
    let message: String
    let suggestion: String
    let rawLog: String?
}

struct MCPErrorAnalyzer {
    
    static func analyze(error: Error) -> MCPUserError {
        let rawMessage = error.localizedDescription
        let normalized = rawMessage.lowercased()

        // 1. Check for "Command Not Found" (Missing executables like npx, uvx)
        if normalized.contains("command not found") {
            let cmd = extractCommand(from: rawMessage)
            return MCPUserError(
                title: "Executable Not Found",
                message: "The system could not locate the command '\(cmd)'.",
                suggestion: "Ensure that '\(cmd)' is installed. If using a package manager like Homebrew or npm, try running it in your terminal first to verify it works.",
                rawLog: rawMessage
            )
        }
        
        // 2. Check for File Not Found (Python scripts, paths)
        if normalized.contains("no such file or directory") || normalized.contains("errno 2") {
            return MCPUserError(
                title: "File Path Invalid",
                message: "The system cannot find the specified file or directory.",
                suggestion: "Check your 'Arguments' for typos. If pointing to a script (like .py or .js), ensure you are using the absolute path (e.g., /Users/name/script.py) instead of a relative one.",
                rawLog: rawMessage
            )
        }
        
        // 3. Check for Python/UVX Package Errors
        if normalized.contains("unsatisfiable") || normalized.contains("not found in the package registry") {
            return MCPUserError(
                title: "Package Not Found",
                message: "The requested Python/Node package could not be downloaded.",
                suggestion: "Check the package name in your arguments. It might be misspelled or no longer available in the registry.",
                rawLog: rawMessage
            )
        }
        
        // 4. Check for Connection Refused (Remote URLs)
        if normalized.contains("connection refused") {
            return MCPUserError(
                title: "Connection Refused",
                message: "Could not connect to the remote server.",
                suggestion: "Ensure the server is running and listening on the correct port. Check if a firewall is blocking the connection.",
                rawLog: rawMessage
            )
        }
        
        // 5. Check for Timeouts
        if normalized.contains("timed out") {
            return MCPUserError(
                title: "Connection Timed Out",
                message: "The server did not respond within the time limit.",
                suggestion: "The tool might be stuck waiting for input, downloading a large file, or compiling dependencies. Try running the command in your terminal to see if it hangs.",
                rawLog: rawMessage
            )
        }
        
        // Default / Unknown Error
        return MCPUserError(
            title: "Connection Failed",
            message: "An unexpected error occurred while connecting to the MCP server.",
            suggestion: "Check the raw logs below for more details. Verifying the command in your system terminal often helps identify the issue.",
            rawLog: rawMessage
        )
    }
    
    private static func extractCommand(from errorMsg: String) -> String {
        // Tries to extract "xyz" from "command not found: xyz" (case-insensitive)
        if let range = errorMsg.range(of: "command not found: ", options: .caseInsensitive) {
            let cmd = String(errorMsg[range.upperBound...])
            return cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "command"
    }
}
