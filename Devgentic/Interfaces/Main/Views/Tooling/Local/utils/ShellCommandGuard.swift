// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ShellCommandGuard.swift
//  Devgentic
//
//  The refusal rules shared by every tool that runs a caller-supplied shell command.
//
//  There were TWO such tools, not one. `execute_shell` (`TerminalTool` → `ShellSessionManager`,
//  both removed 2026-09-24 as a duplicate of `run_command`) enforced these rules; `batch_command` is an equally complete `/bin/zsh -c` runner that
//  enforced NONE of them, so every refusal below was reachable simply by naming the other
//  tool. A profile that hardened `execute_shell` — or an operator who read its blocks and
//  believed them — got none of it.
//
//  That is the general shape worth naming: a guard attached to ONE tool is a guard on a NAME,
//  not on a capability. These rules live here so both shells consult the same list and a third
//  shell runner has something to call rather than something to reinvent.
//
//  ⚠️ What this is NOT. These are usability and footgun rules — they stop the agent hanging
//  the run on an interactive program, and stop it opening an interactive sudo session it
//  cannot answer. They are NOT a security boundary, and no denylist over a shell can be one:
//  the argument to `zsh -c` is a complete programming language, so any command can be spelled
//  a way a list does not recognise. Both tools remain arbitrary code execution BY DESIGN. The
//  boundary is whether the profile grants them at all.
//

import Foundation

enum ShellCommandGuard {

    /// Programs that take over the terminal no matter how they are invoked. Neither tool
    /// attaches a TTY, so these do not "run badly" — they hang until the timeout and return
    /// nothing useful.
    static let alwaysInteractive: Set<String> = ["nano", "vim", "vi", "emacs", "top", "htop", "less", "more"]

    /// Interpreters that drop into a REPL when given no arguments. Blocked ONLY in that form:
    /// `python3 script.py` and `python3 -c "…"` are ordinary non-interactive commands, and
    /// token-matching rather than substring-matching is what keeps `topology` from tripping
    /// the `top` rule.
    static let replCommands: Set<String> = ["python", "python3", "node", "irb", "ruby", "swift"]

    /// Interactive sudo sessions: there is no way to answer the password prompt.
    static let blockedPrefixes: [String] = ["sudo -s", "sudo su", "sudo -i"]

    /// The reason this command must be refused before any process is launched, or nil to run it.
    ///
    /// Returns a REASON rather than a Bool so both call sites report the same sentence — a
    /// refusal the model can act on ("use cat instead of less") is worth more than a generic
    /// denial, and two hand-written copies of that sentence would drift.
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
