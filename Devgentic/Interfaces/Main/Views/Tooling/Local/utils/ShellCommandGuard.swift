// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ShellCommandGuard.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The refusal rules shared by every tool that runs a caller-supplied shell command, so each shell tool consults
/// one list. Usability rules (no interactive REPLs or interactive sudo), not a security boundary: a denylist over a
/// shell cannot be one.
enum ShellCommandGuard {

    /// Programs that take over the terminal no matter how they are invoked. Neither tool
    /// attaches a TTY, so these do not "run badly" — they hang until the timeout and return
    /// nothing useful.
    static let alwaysInteractive: Set<String> = ["nano", "vim", "vi", "emacs", "top", "htop", "less", "more"]

    /// Interpreters that drop into a REPL when given no arguments, blocked only in that form. Token matching, not
    /// substring matching, keeps `topology` from tripping the `top` rule.
    static let replCommands: Set<String> = ["python", "python3", "node", "irb", "ruby", "swift"]

    /// Interactive sudo sessions: there is no way to answer the password prompt.
    static let blockedPrefixes: [String] = ["sudo -s", "sudo su", "sudo -i"]

    /// Returns the reason this command must be refused before any process is launched, or nil to run it. A reason
    /// rather than a Bool so every call site reports the same actionable sentence.
    static func refusalReason(for command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let firstToken = tokens.first ?? ""

        if alwaysInteractive.contains(firstToken) {
            return "Error: Interactive command '\(firstToken)' is blocked. Use non-interactive alternatives (e.g., 'cat' instead of 'less')."
        }
        if replCommands.contains(firstToken) && tokens.count <= 1 {
            return "Error: Running '\(firstToken)' in REPL mode is blocked. Pass a script file or use the -c flag (e.g., 'python3 -c \"print(1)\"')."
        }
        if blockedPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return "Error: Interactive sudo sessions are blocked."
        }
        return nil
    }
}
