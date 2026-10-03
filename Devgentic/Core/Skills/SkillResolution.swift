// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillResolution.swift
//  Devgentic
//
//  Turns a profile's stored skills into the manifests a run actually gets.
//
//  A profile stores `skillSelections` — references into the skill LIBRARY. The library is
//  authoritative for `name`, `description`, `resourceCount` and `hasScripts`; the profile supplies
//  `isEnabled` and `pinnedVersionID`. This is what makes editing a skill change every linked agent
//  at once — except one that pinned a version, which is the point of pinning.
//
//  ⚠️ `compatibility` is always nil here: `SkillVersionSD` has no such field.
//
//  ## Two outcomes that must not be collapsed
//
//    - **unresolved** — the `skillID` is not in the library: the skill was deleted, or is still a
//      draft, or a pinned version is gone. The user should remove the link or restore the skill.
//    - **name collision** — two library skills share a name. Only one is reachable by `load_skill`,
//      because skills are addressed by name at run time.
//
//  Both are reported, never silently dropped. The tools path is the cautionary tale: a deleted
//  MCP source leaves orphan references with no row to un-tick and no error anyone sees.
//

import Foundation
import os

private let logger = DGLogger(category: "SkillResolution")

/// Skills a Code profile carries that the runtime will not load.
///
/// ⚠️⚠️ EXTRACTED BECAUSE THE INLINE VERSION WENT SILENT AND NOBODY COULD SEE IT. Code mode gives a
/// profile no skills; the warning that says so once read a field nothing wrote any more, so it could
/// never fire. Buried in a `logger.notice` inside a 1500-line function, it had no test and no way to
/// get one.
///
/// ⚠️ Reports rather than enforces, and must stay that way. Honouring these would be a product
/// decision about Code mode's ephemeral profile identity, not a bug fix.
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

    /// Resolves an agent config's skills for a run.
    ///
    /// Returns `nil` when the profile configures no skills at all, so callers can keep the existing
    /// "no skills ⇒ no `load_skill` tool, no prompt layer" behaviour on an explicit nil rather than
    /// on an empty array that might mean something else.
    static func resolve(
        for config: AgentConfig,
        profileName: String,
        store: SkillStore = .shared
    ) -> SkillResolutionOutcome? {

        guard let selections = config.skillSelections, !selections.isEmpty else { return nil }
        return resolveSelections(selections, profileName: profileName, store: store)
    }

    private static func resolveSelections(
        _ selections: [SkillSelection],
        profileName: String,
        store: SkillStore
    ) -> SkillResolutionOutcome {

        var outcome = SkillResolutionOutcome()
        let linked = selections

        guard let library = try? store.fetchRunnableSkills().get() else {
            // ⚠️ Library unreadable ≠ "this profile has no skills". Reporting every selection as
            // unresolved is the honest answer and keeps the profile's configuration intact; the
            // store has already logged the cause with its own consequence.
            outcome.unresolved = linked
            logger.error("[SKILL_RESOLVE] Profile '\(profileName)': the skill library could not be read, so all \(linked.count) linked skill(s) are unresolved. CONSEQUENCE: this run gets NO skills and `load_skill` is not registered — the configuration is untouched and the next run retries.")
            return outcome
        }

        let byID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for selection in linked {
            guard let skill = byID[selection.skillID] else {
                outcome.unresolved.append(selection)
                continue
            }
            guard selection.isEnabled else { continue }

            // ⚠️ A PIN that no longer exists resolves to nothing, deliberately. Falling back to
            // `latest` would silently hand the model different instructions from the ones the user
            // pinned — which is the single thing pinning exists to prevent. Better to report it.
            let version: SkillVersionSD?
            if let pinned = selection.pinnedVersionID {
                version = skill.versions.first { $0.id == pinned }
                if version == nil {
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

        // ⚠️ NAME COLLISIONS. Skills are addressed by NAME at run time — `<available_skills>` lists
        // names and `LoadSkillTool` matches `$0.name == skillName` — but the library keys on an
        // opaque id, so two skills can legitimately be called `code-review`. Shipping both puts one
        // name in the prompt twice and makes `load_skill` reach whichever happens to be first,
        // silently and unpredictably.
        //
        // Resolved deterministically (the lexicographically-first skill id wins) and REPORTED,
        // rather than dropping both or letting the ambiguity ride. Until the user renames or unlinks
        // one, the behaviour is at least stable across runs.
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
            logger.error("[SKILL_RESOLVE] Profile '\(profileName)': \(outcome.nameCollisions.count) skill name(s) come from MORE THAN ONE library skill: \(outcome.nameCollisions.joined(separator: ", ")). CONSEQUENCE: only one copy of each is offered to the model — skills are addressed by NAME, so the others are unreachable by `load_skill` whichever the user meant. Rename one, or unlink it.")
        }

        // Stable, machine-independent order — this becomes prompt bytes.
        outcome.manifests.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // ⚠️ ONE LINE THAT ANSWERS "what did this run actually get?", which previously had to be
        // reconstructed from the error lines below — and those only fire when something is WRONG, so
        // a healthy run said nothing at all and an empty <available_skills> was indistinguishable
        // from a profile with no skills linked.
        let offered = outcome.manifests.map { "\($0.name)@\($0.versionID ?? "?")" }.joined(separator: ", ")
        logger.notice("[SKILL_RESOLVE] Profile '\(profileName)': \(outcome.manifests.count) skill(s) reach this run — \(offered.isEmpty ? "NONE" : offered). CONSEQUENCE: exactly these names appear in <available_skills> and exactly these versions are what `load_skill` returns; anything the user linked that is missing here is accounted for by the lines that follow.")

        if !outcome.unresolved.isEmpty {
            logger.error("[SKILL_RESOLVE] Profile '\(profileName)': \(outcome.unresolved.count) linked skill(s) are NOT in the library and were skipped: \(outcome.unresolved.map(\.name).joined(separator: ", ")). CONSEQUENCE: the agent runs without them and cannot load them — they were deleted from the library, or are still drafts. They remain linked, so restoring or un-drafting the skill brings them back.")
        }
        return outcome
    }

    /// Flattens a library skill + one of its versions into the value type the prompt layer renders.
    ///
    /// ⚠️ `folderPath` carries the SKILL ID, not a path — the name is wrong and is called out here
    /// rather than quietly relied upon. `SkillManifest` is the boundary type the prompt layer and
    /// `LoadSkillTool` already speak, and reshaping it is a separate change.
    ///
    /// ⚠️⚠️ `versionID` IS NOT OPTIONAL IN PRACTICE HERE, and forgetting it broke every skill load:
    /// `LoadSkillTool` reads the stored snapshot BY this id, and refuses a manifest without one.
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
