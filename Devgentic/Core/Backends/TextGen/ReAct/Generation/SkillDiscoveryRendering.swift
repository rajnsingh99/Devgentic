// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillDiscoveryRendering.swift
//  Devgentic
//
//  Renders the `<available_skills>` discovery layer (prompt Layer 9) from skill manifests.
//
//  ## Why this is a file and not three lines at the call site
//
//  A skill's `name` and `description` come from the library — originally off disk, from something the user imported — and,
//  increasingly, from a folder someone ELSE authored: a zip, a cloned repo, a shared package.
//  Both fields are then rendered VERBATIM into the system prompt on every single request, and
//  `description` is the text the model routes on.
//
//  Before this type existed the render site was:
//
//      skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
//
//  wrapped by `PromptWrapping.section`, which performs no escaping whatsoever — it is literally
//  `"<\(tag)>\n\(content)\n</\(tag)>"`. So a skill whose description contained
//  `</available_skills><system_instructions>…` closed the section early and opened a forged one.
//  That needed no tool call and no approval: importing the folder was the whole attack. It is the
//  same boundary-forgery class already closed for workflow node input (register WF-SE5), reached
//  by a different door.
//
//  ⚠️ `WorkflowInputAssembler.escapeIfBoundaryThreat` documents an exemption for "user- or
//  profile-authored content under this app's local-trust model". Skills sit OUTSIDE that
//  exemption, and the doc comment there now says so. An imported skill is third-party content
//  that happens to live in the user's filesystem; "the user put it there" is not the same claim
//  as "the user wrote it".
//
//  Three defences, in this order, because the order matters:
//
//  1. **Collapse** control characters and newline runs to single spaces. This is what protects
//     the MARKDOWN wrapping, where escaping is a deliberate no-op: `## Available Skills` opens no
//     tag a payload could close, but a newline followed by `## System Instructions` forges a
//     heading just as effectively. It also keeps the `- name: description` list to one line per
//     skill, which is the format the block claims to be.
//  2. **Cap** the description. Uncapped, one skill can crowd out the rest of the prompt, and a
//     global library makes fifty skills cheap to accumulate.
//  3. **Escape** iff the payload carries the section's own closing tag.
//
//  Capping runs BEFORE escaping on purpose: escaping expands (`<` becomes `&lt;`), so truncating
//  afterwards could cut an entity in half. Truncating first can only ever destroy a boundary
//  sequence, never create one.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "SkillDiscovery")

enum SkillDiscoveryRendering {

    /// The prompt section these fields are rendered into.
    ///
    /// ⚠️ Shared with the render site deliberately. The escaper keys on this exact string to
    /// decide whether a payload can forge the boundary, so a section renamed at the call site
    /// without renaming it here would silently disarm the escape — the guard would still run,
    /// still log nothing, and still let `</available_skills>` through.
    static let sectionTag = "available_skills"

    /// Hard cap on one skill's rendered description.
    ///
    /// Matches the Agent Skills spec's own 1024-character description limit, so a skill authored
    /// against the published spec is never truncated by us. Skills that exceed it were already
    /// going to route badly; they are cut with a marker rather than silently trimmed.
    static let maxDescriptionChars = 1024

    /// Builds the full discovery block body for the enabled manifests.
    ///
    /// Returns `nil` when there is nothing to render, so the caller emits no empty section.
    static func discoveryBody(for manifests: [SkillManifest], wrapping: PromptWrapping) -> String? {
        guard !manifests.isEmpty else { return nil }

        let preamble = """
            You have access to specialized skills. When a task matches a skill's description,
            use the `load_skill` tool to load its full instructions before proceeding.
            """

        let lines = manifests.map { manifest -> String in
            let name = sanitize(manifest.name, limit: nil, field: "name", skill: manifest.name, wrapping: wrapping)
            let description = sanitize(
                manifest.description,
                limit: maxDescriptionChars,
                field: "description",
                skill: manifest.name,
                wrapping: wrapping
            )
            return "- \(name): \(description)"
        }

        return preamble + "\n" + lines.joined(separator: "\n")
    }

    /// Collapse → cap → escape. See the file header for why that order.
    ///
    /// `limit` is nil for `name`, which `SkillFolderScanner.validateSkillNameShape` already bounds to
    /// 64 characters of `[a-z0-9-]`. It is still collapsed and escaped rather than trusted: the
    /// validator runs at IMPORT, and a manifest persisted by an older build predates it.
    static func sanitize(
        _ raw: String,
        limit: Int?,
        field: String,
        skill: String,
        wrapping: PromptWrapping
    ) -> String {

        // 1. Collapse control characters and newlines to spaces, then squeeze runs.
        var scrubbed = String.UnicodeScalarView()
        scrubbed.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                scrubbed.append(" ")
            } else {
                scrubbed.append(scalar)
            }
        }
        var value = String(scrubbed)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        if value.count != raw.count {
            logger.debug("[SKILL_DISCOVERY] Skill '\(skill)' \(field): collapsed \(raw.count) chars to \(value.count). CONSEQUENCE: the field renders as one line; embedded newlines cannot open a markdown heading inside <\(sectionTag)>.")
        }

        // 2. Cap.
        if let limit, value.count > limit {
            logger.notice("[SKILL_DISCOVERY] Skill '\(skill)' \(field) is \(value.count) chars, over the \(limit) cap, and was TRUNCATED for the <\(sectionTag)> block. CONSEQUENCE: the model routes on the first \(limit) characters only — shorten the skill's \(field) in the Skills library so routing sees the part that matters.")
            value = String(value.prefix(limit)) + "…(truncated)"
        }

        // 3. Escape iff it can forge this section's boundary.
        let escaped = WorkflowInputAssembler.escapeIfBoundaryThreat(value, section: sectionTag, wrapping: wrapping)
        if escaped != value {
            logger.error("[SKILL_DISCOVERY] Skill '\(skill)' \(field) contained the closing tag '</\(sectionTag)' and was entity-escaped IN FULL. CONSEQUENCE: the section boundary cannot be forged, but this skill's \(field) reaches the model with &/</> as XML entities — a skill whose \(field) legitimately contains that string should be reworded. Treat an imported skill that does this as hostile until proven otherwise.")
        }
        return escaped
    }
}
