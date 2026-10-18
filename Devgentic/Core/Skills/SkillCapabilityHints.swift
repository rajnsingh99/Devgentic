// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillCapabilityHints.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Notices that a skill needs a tool the profile does not have and says so; it never grants a capability. The user is
/// told once, with a one-click way to act on it; the check runs when a profile links a skill.
enum SkillCapabilityHints {

    /// Declared names that mean "this skill runs shell commands", matched case-sensitively against the base name (so
    /// `Bash(git add:*)` counts). Kept small: a loose match would infer capability from foreign vocabulary.
    /// `batch_command` and `execute_shell` stay because a skill on disk may still declare them.
    static let shellDeclaringNames: Set<String> = [
        "Bash", "execute_shell", "batch_command", "run_command", "start_background_task"
    ]

    /// Whether linking this skill should offer the profile a shell tool: the package bundles `scripts/`, or
    /// `allowed-tools` declares a shell. Returns a Bool for a sentence and a button; it must never append a tool.
    static func shouldOfferShellTool(
        declaredTools: [String]?,
        hasScripts: Bool,
        profileTools: [Tool]
    ) -> Bool {
        guard !profileTools.contains(where: { $0.name == shellToolName }) else { return false }
        if hasScripts { return true }
        return (declaredTools ?? []).contains {
            shellDeclaringNames.contains(SkillToolDeclaration.baseName(of: $0))
        }
    }

    /// The tool a user gets if they accept the offer, built from `RunCommandTool` so its description and schema cannot
    /// drift. `requiresConfirmation` stays true, and the source is `ToolSource.builtInSourceID`, never a minted UUID,
    /// since the Tool Library matches rows on `(name, sourceId)`.
    static func shellTool() -> Tool {
        let shell = RunCommandTool()
        return Tool(
            name: shell.name,
            description: shell.description,
            isEnabled: true,
            requiresConfirmation: true,
            sourceId: ToolSource.builtInSourceID,
            parameters: shell.parameterSchema
        )
    }

    /// The shell tool the offer grants: `run_command`.
    static var shellToolName: String { RunCommandTool().name }
}
