// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillToolText.swift
//  Devgentic
//
//  Flattening the values a skill tool prints into text the MODEL reads.
//
//  ## Why this is a shared type and not a private helper
//
//  ⚠️⚠️ IT WAS A PRIVATE HELPER, AND THAT IS EXACTLY HOW THE SECOND HOLE SURVIVED. `LoadSkillTool`
//  grew a `label()` to stop a skill name forging a markdown heading in its own output — and
//  `UpdateSkillTool`, which addresses skills by the same model-supplied name and prints it into the
//  same kind of tool result, went on interpolating it raw. One tool was guarded, its twin was not:
//  a guard on a NAME rather than on a capability, which is this codebase's own recorded failure mode
//  and the reason it now has a name of its own.
//
//  ## What a LABEL is, and what it is not
//
//  A label is app-voice STRUCTURE: `# Skill: <name>`, `## <path>`, or a name quoted inside a
//  sentence the app speaks. A newline inside one forges a sibling heading, and a `[SYSTEM ALERT]`
//  line is indistinguishable from a real one. Collapsing costs nothing, because a heading was never
//  allowed to be multi-line.
//
//  ⚠️ NEVER a skill BODY and never a bundled file's CONTENT. A body is followable third-party
//  instructions the model is meant to execute, and it is re-emitted — the model copies commands out
//  of it into tool arguments. Collapsing would destroy every fenced code block; escaping would hand
//  `execute_shell` the string `cat a.log 2&gt;&amp;1`. That is the opposite conclusion from
//  `SkillDiscoveryRendering`, and correct for the same reason: a routing key is never re-emitted and
//  a body always is.
//

import Foundation

enum SkillToolText {

    /// Flattens a value a skill tool renders as a one-line label.
    ///
    /// Capped as well as collapsed: several of these values are MODEL-supplied and otherwise
    /// unbounded.
    static func label(_ raw: String, limit: Int = 200) -> String {
        let collapsed = raw
            .components(separatedBy: CharacterSet.controlCharacters.union(.newlines))
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
