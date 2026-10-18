// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolCapability.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// What a tool can do, as opposed to what it is called: one set of tools that execute model-written code, shared by
/// the risk badge and other consumers. `ToolCapabilityTests` reads the tool sources and fails if a tool hands its own
/// argument to an interpreter without being in the set.
enum ToolCapability {

    /// Tools whose argument is executed as code: a string the model wrote becomes something the machine runs, which
    /// argument validation cannot bound. `delete_file` is destructive but bounded to a named path, so it is not here;
    /// tools that interpolate an argument into a fixed script rely on escaping (`AppleScriptEscaping`).
    static let arbitraryCodeExecution: Set<String> = [
        "batch_command",
        // The `batch_command` splits hand their argument to `/bin/zsh -c`, so both are arbitrary code execution and
        // `.destructive`; `HITLRiskTier.classify` and `SessionToolApprovals` read this set.
        "run_command",
        "start_background_task",
        "run_applescript",
    ]

    static func executesArbitraryCode(_ toolName: String) -> Bool {
        arbitraryCodeExecution.contains(toolName)
    }
}
