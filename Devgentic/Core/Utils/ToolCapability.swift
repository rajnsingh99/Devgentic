// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ToolCapability.swift
//  Devgentic
//
//  What a tool can DO, as opposed to what it is called.
//
//  Several parts of the app need to know "is this one of the tools that runs whatever the model
//  writes?" — the permission banner's risk badge, and anything added later. Each of them used to
//  answer it with its own hand-written list of tool NAMES, and the lists disagreed:
//  `HITLRiskTier.classify` named `execute_shell` and `run_applescript` but not `batch_command`,
//  which is the same `/bin/zsh -c` under a different name and in a different UI category, so it
//  rendered as "Modifies" with a pencil where its twin rendered "Destructive" with a warning.
//
//  A list of names is a claim about naming, not about behaviour, and it goes stale silently:
//  `disk_usage` belonged in this set until 2026-07-31 (it interpolated a tool argument into a
//  `zsh -c` string) and appeared in none of them. It is argv now and correctly absent — but no
//  list was ever edited in either direction.
//
//  So: one set, here, and a test (`ToolCapabilityTests`) that reads the tool sources and fails
//  the build if a tool hands its own argument to an interpreter without being in it. The set
//  cannot drift from the code, because the code is what the test checks it against.
//

import Foundation

enum ToolCapability {

    /// Tools whose ARGUMENT is executed as code.
    ///
    /// The line is "a string the model wrote becomes something the machine runs", not "this tool
    /// can cause damage". `delete_file` is destructive and is deliberately NOT here — it does one
    /// bounded thing to a named path. These three do *anything*, which is a different property:
    /// no argument validation can bound them, because the argument is a program.
    ///
    /// - `execute_shell` → `/bin/zsh -c <command>` (via `ShellSessionManager`)
    /// - `batch_command` → `/bin/zsh -c <command>` (directly)
    /// - `run_applescript` → `NSAppleScript(source: <script>)`, which reaches a shell of its own
    ///   through `do shell script`
    ///
    /// Tools that interpolate an argument INTO a fixed script are not in this set — their
    /// mitigation is escaping (`AppleScriptEscaping`), not gating, because the shape of what runs
    /// is fixed by us and only a value inside it comes from the model.
    static let arbitraryCodeExecution: Set<String> = [
        "execute_shell",
        "batch_command",
        "run_applescript",
    ]

    static func executesArbitraryCode(_ toolName: String) -> Bool {
        arbitraryCodeExecution.contains(toolName)
    }
}
