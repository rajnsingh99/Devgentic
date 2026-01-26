//
//  ToolNamer.swift
//  Devgentic
//
//  Created by Raj Singh on 30/09/25.
//

import Foundation

/// A utility struct for creating and parsing prefixed tool names to ensure uniqueness.
struct ToolNamer {
    
    /// Creates a unique, sanitized, prefixed name for a tool based on its source.
    ///
    /// This function takes a tool name and its source's name, sanitizes the source name
    /// to make it a valid prefix (e.g., "Built-in Tools" becomes "BuiltinTools"), and
    /// combines them to prevent name collisions between different tool sources.
    ///
    /// - Example: `prefixedName(for: "execute_shell", from: "Built-in Tools")` returns `"BuiltinTools_execute_shell"`.
    ///
    /// - Parameters:
    ///   - toolName: The original name of the tool (e.g., "execute_shell").
    ///   - sourceName: The display name of the source providing the tool (e.g., "Built-in Tools").
    /// - Returns: A sanitized, unique string identifier for the tool.
    static func prefixedName(for toolName: String, from sourceName: String) -> String {
        // Sanitize the source name to make it a valid prefix (no spaces or non-alphanumeric characters)
        let sanitizedSource = sourceName.replacingOccurrences(of: " ", with: "")
                                        .filter { $0.isLetter || $0.isNumber }
        return "\(sanitizedSource)_\(toolName)"
    }
}
