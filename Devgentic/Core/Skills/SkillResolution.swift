// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillResolution.swift
//  Devgentic
//
//  Turns a profile's stored skills into the manifests a run actually gets.
//
//  ## The dual-read window, and when it closes
//
//  Two shapes coexist:
//
//    - **v9 (`skillSelections`)** — references into the skill LIBRARY. Authoritative for `name`,
//      `description`, `resourceCount` and `hasScripts`; the profile supplies `isEnabled` and
//      `pinnedVersionID`. This is what makes editing a skill change every linked agent at once —
//      except one that pinned a version, which is the point of pinning.
//    - **legacy (`skillConfig.manifests`)** — manifest copies that used to live in the blob. Read
//      only when `skillSelections` is nil, and their `folderPath` really is a path.
//
//  ⚠️ `compatibility` is always nil on the library path: `SkillVersionSD` has no such field. It
//  survives on `SkillManifest` only for the legacy arm.
//
//  ⚠️ THE LEGACY ARM IS NARROWER THAN IT LOOKS, and the original version of this comment was wrong
//  about it. It does NOT cover "a profile written before v8 that has not been re-saved":
//  `migrateToV8` runs on the READ path of EVERY decode and sets `skillSelections` whenever
//  `skillConfig.manifests` parses, so a migrated blob always arrives WITH selections. What actually
//  reaches this arm is a blob already stamped v8+ that carries `skillConfig` and no selections —
//  `encodeIfPresent` omits a nil list, so any `AgentConfig` built that way round-trips into exactly
//  that shape. Pinned by `SkillSelectionMigrationTests`.
//
//  ## Three outcomes that must not be collapsed
//
//  A selection can fail in three different ways, and the remedies are opposite:
//
//    - **unresolved** — the `skillID` is not in the library: the skill was deleted, or is still a
//      draft, or a pinned version is gone. The user should remove the link or restore the skill.
//    - **awaitingRelink** — carried over from before the library and not yet re-linked. The user
//      should do NOTHING; `SkillLibraryImportSweep` repairs it.
//    - **name collision** — two library skills share a name. Only one is reachable by `load_skill`,
//      because skills are addressed by name at run time.
//
//  All three are reported, never silently dropped. The tools path is the cautionary tale: a deleted
//  MCP source leaves orphan references with no row to un-tick and no error anyone sees.
//

import Foundation
import os

private let logger = DGLogger(category: "SkillResolution")

/// Skills a Code profile carries that the runtime will not load.
///
/// ⚠️⚠️ EXTRACTED BECAUSE THE INLINE VERSION WENT SILENT AND NOBODY COULD SEE IT. Code mode gives a
/// profile no skills; the warning that says so read ONLY the pre-V6 `skillConfig` blob, so once the
/// migration moved every profile's skills into `skillSelections` it could never fire again — for
/// exactly the profiles that reach it. Buried in a `logger.notice` inside a 1500-line function, it
/// had no test and no way to get one.
///
/// ⚠️ Reports rather than enforces, and must stay that way. Honouring these would be a product
/// decision about Code mode's ephemeral profile identity, not a bug fix.
enum CodeModeSkillDiagnostics {

    /// Names of enabled skills the profile holds, across BOTH storage shapes, deduplicated.
    ///
    /// The legacy arm stays for a profile that has not been through the import sweep; the selection
    /// arm is the one that fires for everything else.
    static func inertSkillNames(in config: AgentConfig) -> [String] {
        let fromSelections = (config.skillSelections ?? []).filter(\.isEnabled).map(\.name)
        let fromLegacyBlob = config.skillConfig?.manifests.filter(\.isEnabled).map(\.name) ?? []
        return Array(Set(fromSelections + fromLegacyBlob)).sorted()
    }
}

/// What resolving one profile's skills produced.
struct SkillResolutionOutcome: Sendable {
    /// Enabled, resolved, ready to render into `<available_skills>`.
    var manifests: [SkillManifest] = []
    /// Selections whose skill is not in the library. Named, so the UI can offer removal.
    var unresolved: [SkillSelection] = []
    /// Selections carried over from a pre-V6 profile that the launch sweep has not re-linked yet.
    ///
    /// ⚠️ Counted SEPARATELY from `unresolved`, because the remedies are opposite: an unresolved
    /// selection points at a skill that is gone and the user should remove it; one awaiting re-link
    /// points at a skill that probably still exists and the user should do NOTHING. Reporting them
    /// together would tell someone to delete links that are about to repair themselves.
    var awaitingRelink: [SkillSelection] = []
    /// True when the legacy blob was read because no selections existed.
    var usedLegacyPath = false
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

        if let selections = config.skillSelections {
            guard !selections.isEmpty else { return nil }
            return resolveSelections(selections, profileName: profileName, store: store)
        }

        // Legacy arm — a blob stamped v8+ carrying `skillConfig` but no `skillSelections`.
        guard let manifests = config.skillConfig?.manifests, !manifests.isEmpty else { return nil }
        var outcome = SkillResolutionOutcome()
        outcome.usedLegacyPath = true
        outcome.manifests = manifests.filter(\.isEnabled)
        logger.info("[SKILL_RESOLVE] Profile '\(profileName)' resolved \(outcome.manifests.count) skill(s) from the LEGACY blob (no skillSelections present). CONSEQUENCE: their descriptions and bodies are whatever that blob recorded, NOT what the library holds — and their folder paths no longer address anything, so `load_skill` will fail on them. This profile has not been through the V6 sweep.")
        return outcome
    }

    private static func resolveSelections(
        _ selections: [SkillSelection],
        profileName: String,
        store: SkillStore
    ) -> SkillResolutionOutcome {

        var outcome = SkillResolutionOutcome()

        // A pre-V6 selection has no address yet. Separated BEFORE the library is consulted, so it
        // can never be reported as "this skill was deleted".
        let (linked, pending) = selections.partitioned { !$0.isAwaitingRelink }
        outcome.awaitingRelink = pending

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
            guard let skillID = selection.skillID, let skill = byID[skillID] else {
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
        let offered = outcome.manifests.map { "\($0.name)@\($0.versionID ?? "legacy")" }.joined(separator: ", ")
        logger.notice("[SKILL_RESOLVE] Profile '\(profileName)': \(outcome.manifests.count) skill(s) reach this run — \(offered.isEmpty ? "NONE" : offered). CONSEQUENCE: exactly these names appear in <available_skills> and exactly these versions are what `load_skill` returns; anything the user linked that is missing here is accounted for by the lines that follow.")

        if !outcome.unresolved.isEmpty {
            logger.error("[SKILL_RESOLVE] Profile '\(profileName)': \(outcome.unresolved.count) linked skill(s) are NOT in the library and were skipped: \(outcome.unresolved.map(\.name).joined(separator: ", ")). CONSEQUENCE: the agent runs without them and cannot load them — they were deleted from the library, or are still drafts. They remain linked, so restoring or un-drafting the skill brings them back.")
        }
        if !outcome.awaitingRelink.isEmpty {
            logger.notice("[SKILL_RESOLVE] Profile '\(profileName)': \(outcome.awaitingRelink.count) skill(s) carried over from before the library and have not been re-linked: \(outcome.awaitingRelink.map(\.name).joined(separator: ", ")). CONSEQUENCE: they are skipped for now and the user should NOT remove them — the import sweep re-links them once their folder has been ingested.")
        }
        return outcome
    }

    /// Flattens a library skill + one of its versions into the value type the prompt layer renders.
    ///
    /// ⚠️ `folderPath` carries the SKILL ID, not a path — the name is wrong and is called out here
    /// rather than quietly relied upon. `SkillManifest` is the boundary type the prompt layer and
    /// `LoadSkillTool` already speak, and reshaping it is a separate change.
    ///
    /// ⚠️⚠️ `versionID` IS NOT OPTIONAL IN PRACTICE HERE, and forgetting it broke every skill load.
    /// `LoadSkillTool` dereferences one of these two fields: with a version id it reads the stored
    /// snapshot, without one it treats `folderPath` as a real path. Set the id and the first branch
    /// runs; omit it and the tool tries to open a file called `skill_<uuid>/SKILL.md`.
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

private extension Array {
    /// Splits into (matching, notMatching), preserving order in both.
    func partitioned(_ isMatch: (Element) -> Bool) -> ([Element], [Element]) {
        var matching: [Element] = []
        var other: [Element] = []
        for element in self {
            if isMatch(element) { matching.append(element) } else { other.append(element) }
        }
        return (matching, other)
    }
}
