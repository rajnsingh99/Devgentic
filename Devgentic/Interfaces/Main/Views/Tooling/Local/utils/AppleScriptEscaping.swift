// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppleScriptEscaping.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Escapes model-supplied values for interpolation into AppleScript source.
/// Every tool that builds AppleScript from a tool argument goes through this one function.
enum AppleScriptEscaping {

    // Why: escape the backslash first or later escapes get escaped again.
    /// Escapes a value for interpolation into an AppleScript string literal.
    /// Escapes the backslash first, then the quote, `\n` and `\r`; a raw newline would end the statement.
    /// Only for values inside quotes; identifiers, numbers and clauses must be constrained by type instead.
    static func escapeStringLiteral(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
