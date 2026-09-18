// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppleScriptEscaping.swift
//  Devgentic
//
//  One escaper for every tool that interpolates a model-supplied value into AppleScript.
//
//  AppleScript is the THIRD interpreter tool arguments can reach, after the shell and the
//  invoked program's option parser, and it is the one argv does not help with: a tool cannot
//  hand NSAppleScript an argument vector, only source text. AppleScript can then reach a shell
//  itself via `do shell script`, so an unescaped value in a string literal is arbitrary command
//  execution — the same severity as the `zsh -c` interpolation the argv sweep removed, reached
//  by a different road.
//
//  This exists as ONE function because the failure mode is a tool that escapes MOST of its
//  interpolations: `apple_notes` escaped its title, body and search term and missed the `list`
//  action's folder, and `manage_safari_tabs` escaped nothing at all. A per-tool private copy is
//  how a site gets missed — there is nothing to be consistent WITH.
//

import Foundation

enum AppleScriptEscaping {

    /// Escapes a value for interpolation into an AppleScript **string literal** (`"…"`).
    ///
    /// Backslash first, always — otherwise the escapes introduced afterwards would themselves
    /// be escaped, and the value would decode back to something other than what was passed.
    ///
    /// The two line terminators matter as much as the quote. An AppleScript string literal
    /// cannot span lines, so a raw newline ends the statement and everything after it is parsed
    /// as SCRIPT rather than data. That happens to fail closed today — a syntax error, not an
    /// injection — but it is one grammar change away from not doing, and it makes an otherwise
    /// valid value fail for no visible reason. `\n` and `\r` are valid AppleScript escapes, so
    /// there is no cost to being correct here.
    ///
    /// ⚠️ This is for values that land INSIDE a quoted literal. It is not a sanitiser for
    /// values interpolated into script POSITIONS (an identifier, a number, a whole clause) —
    /// those have no quoting to escape into, and must be constrained by type instead. The
    /// clamped `Int` tab index in `manage_safari_tabs` and the clamped `Double` brightness in
    /// `MacOSUtilityTools` are the correct pattern for that case.
    static func escapeStringLiteral(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
