// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillDiscoveryRendering.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "SkillDiscovery")

// Why: capping runs before escaping because escaping expands; truncating afterwards could cut an entity in half.
// The cap bounds source characters, not rendered bytes.
/// Renders the `<available_skills>` discovery layer of the prompt from skill manifests. Skill `name`/`description`
/// may come from third-party folders, so each field is collapsed (control characters, newline runs), capped, then
/// escaped (`&`, `<`, `>`) unconditionally, in that order, so it cannot forge a prompt section boundary.
enum SkillDiscoveryRendering {

    /// The prompt section these fields are rendered into.
    /// Escaping is unconditional; this string only picks the log severity (a payload carrying this section's own closing tag
    /// is a forgery attempt worth `.error`). A stale value mis-grades a log line, never leaves a field unescaped.
    static let sectionTag = "available_skills"

    /// Hard cap on one skill's rendered description, matching the Agent Skills spec's 1024-character limit so a skill
    /// authored to the spec is never truncated. Over-long descriptions are cut with a marker rather than silently trimmed.
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
            // `name` is capped too: `validateSkillNameShape` bounds it at ingress, but rendering must not trust a manifest
            // persisted before that validator.
            let name = sanitize(manifest.name, limit: SkillLibraryLimits.maxNameChars,
                                field: "name", skill: manifest.name, wrapping: wrapping)
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

    /// Collapses control characters and newline runs, caps to `limit`, then escapes, in that order.
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

        // Compare `value != raw`, not counts: a control character replaced one-for-one by a space leaves the count identical,
        // so the single-character substitution a hostile description would use would go unlogged.
        if value != raw {
            logger.debug("[SKILL_DISCOVERY] Skill '\(skill)' \(field): collapsed \(raw.count) chars to \(value.count) (wrapping=\(wrapping.logLabel)). CONSEQUENCE: the field renders as one line; embedded newlines cannot open a markdown heading inside <\(sectionTag)>.")
        }

        // 2. Cap.
        if let limit, value.count > limit {
            logger.notice("[SKILL_DISCOVERY] Skill '\(skill)' \(field) is \(value.count) chars, over the \(limit) cap, and was TRUNCATED for the <\(sectionTag)> block. CONSEQUENCE: the model routes on the first \(limit) characters only — shorten the skill's \(field) in the Skills library so routing sees the part that matters.")
            value = String(value.prefix(limit)) + "…(truncated)"
        }

        // 3. Escape — ALWAYS, and with `.xml` hardcoded. See the file header for why this is no
        //    longer `escapeIfBoundaryThreat` and why the caller's wrapping is not threaded through.
        let escaped = WorkflowInputAssembler.escapeForXMLEmbedding(value, wrapping: .xml)

        if escaped != value {
            // The boundary predicate is a detector, never a gate (escaping has already happened): it only decides how loud the
            // line is, so a benign `&` in prose cannot drown out an actual forgery attempt.
            if value.range(of: "</\(sectionTag)", options: .caseInsensitive) != nil {
                logger.error("[SKILL_DISCOVERY] Skill '\(skill)' \(field) contains this section's own closing tag ('</\(sectionTag)') — a BOUNDARY FORGERY attempt, not a stray angle bracket. Entity-escaped in full. CONSEQUENCE: the section cannot be closed early and the payload reaches the model inert; treat this skill as hostile until proven otherwise and remove it from the library.")
            } else {
                logger.debug("[SKILL_DISCOVERY] Skill '\(skill)' \(field) contained &, < or > and was entity-escaped (\(value.count) → \(escaped.count) chars). CONSEQUENCE: the model reads the entity spelling. Routing is unaffected — this field is prose the model MATCHES on, never markup it must reproduce — so an odd-looking description in a prompt dump is this, not corruption.")
            }
            if field == "name" {
                logger.error("[SKILL_DISCOVERY] Skill '\(skill)' NAME was rewritten by escaping, so the string the model sees no longer equals `manifest.name`. CONSEQUENCE: this skill is LISTED BUT UNREACHABLE — `LoadSkillTool` and `UpdateSkillTool` both resolve with `$0.name == arguments.skillName` against the RAW name, so every `load_skill` and `update_skill` call on it fails. A spec-conformant name is [a-z0-9-] and escapes to itself, so this can only fire for a manifest that predates `validateSkillNameShape`: re-import the skill folder to fix it.")
            }
        }
        return escaped
    }
}
