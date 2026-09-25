// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillCapabilityHints.swift
//  Devgentic
//
//  Noticing that a skill needs a tool the profile does not have — and saying so, never fixing it.
//
//  ## This used to grant, and that was the defect
//
//  `AgentSkillsSection` once appended `execute_shell` to a profile automatically when an imported
//  skill bundled a `scripts/` directory. A directory listing — a fact about unreviewed content —
//  was deciding a capability, which is exactly what invariant 14 forbids: **capability metadata
//  describes; it never enforces.** It also did not survive contact with archives: once a skill can
//  arrive in a .zip the user did not author, "this package contains scripts/" would be enough to
//  grant shell access to whatever profile imported it.
//
//  What remains is the useful half — the user is TOLD, once, with a one-click way to act on it.
//
//  ⚠️ MOVED HERE when the folder registry and its profile card were deleted (V6). It lived in a
//  SwiftUI view before, which is why the demotion from grant to offer originally shipped with no
//  test at all. A decision that cannot be called without a view is a decision with no test.
//
//  ## Why it moved to the LINK site rather than the import site
//
//  Importing is now global: a skill goes into the library, which belongs to no profile. The shell
//  tool is per-profile. So the only moment both facts are in hand is when a profile LINKS a skill,
//  and that is where this is asked.
//

import Foundation

enum SkillCapabilityHints {

    /// Declared names that mean "this skill runs shell commands".
    ///
    /// ⚠️ Matched CASE-SENSITIVELY against the BASE name, so `Bash(git add:*)` counts while a
    /// hypothetical MCP tool named `bash` is not read as Claude Code's `Bash`. Deliberately small:
    /// this set decides whether a sentence appears, so a miss costs a missing suggestion and a false
    /// hit costs a suggestion the user declines — but a loose match would start inferring capability
    /// from arbitrary foreign vocabulary, which is the thing that was removed.
    /// ⚠️ `batch_command` and `execute_shell` STAY. Both are withdrawn from the catalogue (the
    /// latter 2026-09-24, as a duplicate of `run_command`) but a SKILL on disk may still declare one — and a skill that names a retired tool should still
    /// be recognised as declaring a shell rather than silently declaring nothing.
    static let shellDeclaringNames: Set<String> = [
        "Bash", "execute_shell", "batch_command", "run_command", "start_background_task"
    ]

    /// Whether linking this skill should OFFER the profile a shell tool.
    ///
    /// Two independent triggers, and they do not overlap:
    ///   - `hasScripts` — the package bundles files under `scripts/`.
    ///   - `allowed-tools` declares a shell. A skill whose instructions say "run `git status`"
    ///     declares `Bash` and ships no `scripts/` directory at all, so under the old rule the offer
    ///     never appeared and the skill silently could not do what it said.
    ///
    /// ⚠️ Returns a Bool for a sentence and a button. It must never append a tool — see the header.
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

    /// The tool a user gets if they accept the offer.
    ///
    /// ⚠️ `requiresConfirmation: true`, and never relax it here. The offer's whole justification is
    /// that the grant is a person's answer to a question; handing back a pre-approved shell would
    /// make the question cosmetic.
    ///
    /// ⚠️ `ToolSource.builtInSourceID`, never a minted UUID. This used to read
    /// `UUID(uuidString: "00000000-SKIL-AUTO-SHEL-000000000000") ?? UUID()` — S, K, I, L, U, T, O
    /// and H are not hex digits, so the parse failed on EVERY call and each import minted a fresh
    /// random id. The Tool Library matches rows on `(name, sourceId)`, so the tool rendered as OFF
    /// while it was live, ticking it appended a SECOND copy, and un-ticking removed only the
    /// built-in-sourced one — leaving the auto-added copy enabled and unreachable from any UI.
    /// Never write `X ?? UUID()` for a compile-time-constant identity.
    ///
    /// Built from `RunCommandTool` itself, so the offered record's description and schema cannot
    /// drift from the tool that will run it.
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

    /// The shell tool the offer grants. `run_command` since 2026-09-24, when `execute_shell` — its
    /// duplicate — was removed.
    static var shellToolName: String { RunCommandTool().name }
}
