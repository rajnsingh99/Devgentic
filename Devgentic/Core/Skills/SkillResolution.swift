// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillResolution.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "SkillResolution")

/// Skills a Code profile carries that the runtime will not load.
/// Code mode gives a profile no skills; this reports rather than enforces, since honouring them would be a product
/// decision.
enum CodeModeSkillDiagnostics {

    /// Names of enabled skills the profile holds, deduplicated.
    static func inertSkillNames(in config: AgentConfig) -> [String] {
        Array(Set((config.skillSelections ?? []).filter(\.isEnabled).map(\.name))).sorted()
    }
}

/// What resolving one profile's skills produced.
struct SkillResolutionOutcome: Sendable {
    /// Enabled, resolved, ready to render into `<available_skills>`.
    var manifests: [SkillManifest] = []
    /// Selections whose skill is not in the library. Named, so the UI can offer removal.
    var unresolved: [SkillSelection] = []
    /// Names offered by more than one linked skill. Only one copy of each reached `manifests`.
    var nameCollisions: [String] = []
}

@MainActor
enum SkillResolution {

    /// Resolves an agent config's skills for a run; returns `nil` when the profile configures no skills at all.
    /// `reporting: false` silences this function's own log lines and changes nothing else, for the `/` picker, which
    /// re-resolves per keystroke.
    static func resolve(
        for config: AgentConfig,
        profileName: String,
        store: SkillStore = .shared,
        reporting: Bool = true
    ) -> SkillResolutionOutcome? {

        guard let selections = config.skillSelections, !selections.isEmpty else { return nil }
        return resolveSelections(selections, profileName: profileName, store: store, reporting: reporting)
    }

    private static func resolveSelections(
        _ selections: [SkillSelection],
        profileName: String,
        store: SkillStore,
        reporting: Bool
    ) -> SkillResolutionOutcome {

        var outcome = SkillResolutionOutcome()
        let linked = selections

        guard let library = try? store.fetchRunnableSkills().get() else {
            // An unreadable library is not "no skills": every selection is reported unresolved and the profile's configuration
            // stays intact.
            outcome.unresolved = linked
            if reporting { logger.error("[SKILL_RESOLVE] Profile '\(profileName)': the skill library could not be read, so all \(linked.count) linked skill(s) are unresolved. CONSEQUENCE: this run gets NO skills and `load_skill` is not registered — the configuration is untouched and the next run retries.") }
            return outcome
        }

        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for selection in linked {
            guard let skill = byID[selection.skillID] else {
                outcome.unresolved.append(selection)
                continue
            }
            guard selection.isEnabled else { continue }

            // Why: falling back would silently give the model different instructions than the user pinned
            // A pinned version that has been deleted resolves to nothing instead of falling back to `latest`.
            let version: SkillVersionSD?
            if let pinned = selection.pinnedVersionID {
                version = skill.versions.first { $0.id == pinned }
                if version == nil, reporting {
                    logger.error("[SKILL_RESOLVE] Profile '\(profileName)': skill '\(skill.name)' pins version '\(pinned)', which is not in the library. CONSEQUENCE: the skill is SKIPPED for this run rather than silently falling back to the latest version — a pin exists precisely so the instructions do not change underneath the profile. Re-pin it or clear the pin.")
                }
            } else {
                version = skill.latestVersion
            }
            guard let resolved = version else {
                outcome.unresolved.append(selection)
                continue
            }
            outcome.manifests.append(manifest(for: skill, version: resolved))
        }

        // Name collisions: skills are addressed by name at run time but keyed by id, so two can share a name.
        // Resolved deterministically (lexicographically-first id wins) and reported, so behaviour is stable across runs.
        var seen = Set<String>()
        var deduped: [SkillManifest] = []
        var collisions: [String] = []
        for manifest in outcome.manifests.sorted(by: { $0.folderPath < $1.folderPath }) {
            if seen.contains(manifest.name) {
                collisions.append(manifest.name)
                continue
            }
            seen.insert(manifest.name)
            deduped.append(manifest)
        }
        outcome.manifests = deduped
        if !collisions.isEmpty {
            outcome.nameCollisions = Array(Set(collisions)).sorted()
            if reporting { logger.error("[SKILL_RESOLVE] Profile '\(profileName)': \(outcome.nameCollisions.count) skill name(s) come from MORE THAN ONE library skill: \(outcome.nameCollisions.joined(separator: ", ")). CONSEQUENCE: only one copy of each is offered to the model — skills are addressed by NAME, so the others are unreachable by `load_skill` whichever the user meant. Rename one, or unlink it.") }
        }

        // Stable, machine-independent order — this becomes prompt bytes.
        outcome.manifests.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // One line answers "what did this run actually get?"; a healthy run would otherwise log nothing.
        let offered = outcome.manifests.map { "\($0.name)@\($0.versionID ?? "?")" }.joined(separator: ", ")
        if reporting { logger.notice("[SKILL_RESOLVE] Profile '\(profileName)': \(outcome.manifests.count) skill(s) reach this run — \(offered.isEmpty ? "NONE" : offered). CONSEQUENCE: exactly these names appear in <available_skills> and exactly these versions are what `load_skill` returns; anything the user linked that is missing here is accounted for by the lines that follow.") }

        if !outcome.unresolved.isEmpty, reporting {
            logger.error("[SKILL_RESOLVE] Profile '\(profileName)': \(outcome.unresolved.count) linked skill(s) are NOT in the library and were skipped: \(outcome.unresolved.map(\.name).joined(separator: ", ")). CONSEQUENCE: the agent runs without them and cannot load them — they were deleted from the library, or are still drafts. They remain linked, so restoring or un-drafting the skill brings them back.")
        }
        return outcome
    }

    /// Flattens a library skill and one of its versions into the value type the prompt layer renders.
    /// `folderPath` carries the skill id, not a path. `versionID` is required in practice: `LoadSkillTool` reads the
    /// snapshot by it.
    private static func manifest(for skill: SkillSD, version: SkillVersionSD) -> SkillManifest {
        SkillManifest(
            id: UUID(),
            name: skill.name,
            description: version.skillDescription,
            folderPath: skill.id,
            resourceCount: version.resourceCount,
            hasScripts: version.hasScripts,
            compatibility: nil,
            isEnabled: true,
            allowedTools: version.allowedTools,
            versionID: version.id
        )
    }
}
