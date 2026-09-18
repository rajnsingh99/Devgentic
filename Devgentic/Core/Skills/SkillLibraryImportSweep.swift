// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillLibraryImportSweep.swift
//  Devgentic
//
//  The launch pass that finishes what the V5→V6 migration deliberately could not.
//
//  ## Why the migration left work behind
//
//  Two steps hand this their unfinished halves, and both stopped for the same reason — purity:
//
//    - `SkillLibraryMigration.captureLegacyFolderPaths` ran inside `willMigrate`, the one window
//      where the retired `SkillManifestSD` rows still existed. It wrote the folder paths down and
//      did nothing else, because a migration hook is the wrong place for file I/O that can hang on
//      an unmounted volume or fail halfway with the store mid-upgrade.
//    - `ProfileMigrator.migrateToV9` reshaped each selection's `folderPath` into
//      `legacyFolderPath` and left `skillID` absent, because `migrateIfNeeded` runs on the READ
//      path of every decode and must stay pure — it has no store to ask.
//
//  This is the one place that holds both halves. It ingests each folder, which is exactly what
//  teaches it `folderPath → skillID`, and then rewrites every profile selection that was waiting
//  for that answer.
//
//  ## ⚠️⚠️ WHERE THE FOLDERS COME FROM — and why the capture file is not enough
//
//  There are TWO sources, and for every real upgrade only the second one has anything in it:
//
//    1. The capture file, written from the V4/V5 `SkillManifestSD` registry.
//    2. The profiles themselves — every selection still holding a `legacyFolderPath`.
//
//  **V4 and V5 never shipped.** The last released build is at schema V3, so that registry table is
//  always empty and the capture always wrote nothing. Sourcing this pass from it alone made the
//  whole thing a silent no-op that discarded every upgrading user's skills. `harvestLegacyFolders`
//  is the second source and the one that actually fires; see its comment for the full chain.
//
//  ## Ordering is the safety property
//
//  Read the profiles → ingest everything → re-link every profile → ONLY THEN clear the capture. A
//  crash between ingest and re-link leaves skills in the library and profiles still pointing at
//  nothing; the capture file, where it exists, is how the next launch reconnects them.
//
//  ⚠️ A HARVESTED folder needs no such record and is self-healing: its selection stays
//  `awaitingRelink` until the re-link succeeds, so the next launch simply finds it again. Only
//  captured refs are written back on failure.
//
//  ⚠️ Re-running after a partial success would DUPLICATE skills, since names are not unique and
//  nothing in the library records where a skill came from. That is why the capture is cleared on
//  success, why failures are written back individually, and why the profile fetch happens BEFORE
//  any ingest — a store that cannot be read now aborts with nothing yet written.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "SkillLibraryImportSweep")

struct SkillImportSweepOutcome: Sendable, Equatable {
    /// Names of skills that reached the library on this pass.
    var imported: [String] = []
    /// Folders that could not be read, with the reason. Retried on the next launch.
    var failed: [RejectedSkill] = []
    var profilesExamined = 0
    var selectionsRelinked = 0
    /// Selections still waiting — their folder failed, or was never captured.
    var selectionsStillPending = 0
    /// Profiles whose blob could not be read. Their selections were NOT re-linked.
    var unreadableProfiles: [String] = []
    /// Set when the pass stopped early. The capture file is kept so the next launch retries.
    var abortReason: String?

}

@MainActor
enum SkillLibraryImportSweep {

    /// ⚠️⚠️ THE SWEEP IS NOT RE-ENTRANT, AND IT NOW HAS A SUSPENSION POINT IN IT.
    ///
    /// Before the ingest moved off the main actor two overlapping passes were impossible: a pass
    /// held the main actor from the profile fetch to the capture rewrite. It no longer does — and
    /// freeing the main actor is exactly what makes the Skills window openable DURING a slow launch
    /// ingest, where "Try again" starts a second pass over the same pending list. Both would ingest
    /// the same folder and create two skills with the same name, which the user then has to find and
    /// delete by hand: nothing records where a skill came from, so nothing can tell them apart.
    ///
    /// ⚠️ `isRetryingImports` in the library view is NOT this guard — it is a guard on one NAME, and
    /// the launch path never sees it.
    ///
    /// No lock is needed: both accessors are main-actor-isolated, and the guard is taken and
    /// released without an `await` between the check and the set.
    private static var isSweeping = false

    /// ⚠️ Extracted for the same reason `shouldClearCapture` is: the state it protects is only
    /// reachable while a pass is suspended, which no test can reach from outside `run`.
    static func beginExclusive() -> Bool {
        guard !isSweeping else { return false }
        isSweeping = true
        return true
    }

    static func endExclusive() { isSweeping = false }

    /// Imports every captured pre-V6 folder and re-links the profiles that referenced them.
    ///
    /// Total: it reports rather than throws, and a failure anywhere leaves the capture file in place
    /// so the next launch can retry.
    @discardableResult
    static func run(container: ModelContainer, store: SkillStore = .shared) async -> SkillImportSweepOutcome {
        var outcome = SkillImportSweepOutcome()

        // ⚠️ EXCLUSIVITY FIRST — see `beginExclusive`. A second overlapping pass would re-ingest the
        // same folders and duplicate every skill, and the duplicates are indistinguishable.
        guard beginExclusive() else {
            outcome.abortReason = "another import sweep is already running"
            logger.notice("[SKILL_SWEEP] A sweep is already in progress; this request was ignored. CONSEQUENCE: nothing was imported twice — the pass already running will finish and report, and the capture file is untouched.")
            return outcome
        }
        defer { endExclusive() }

        // ⚠️⚠️ PROFILES ARE FETCHED FIRST BECAUSE THEY ARE A SOURCE OF WORK, NOT ONLY ITS TARGET.
        // The capture file is empty for every real upgrade — see `harvestLegacyFolders`. Fetching
        // here also means a store that cannot be read aborts BEFORE anything is ingested, so the
        // one state this pass must never leave behind (skills imported, capture cleared, nothing
        // re-linked) is now unreachable by that route.
        let context = container.mainContext
        let profiles: [BackendProfile]
        do {
            // ⚠️ NO fetchLimit. `BackendProfileStore` caps its own fetches at 500 because that is a
            // UI bound for a picker; inheriting it here would silently skip a 501st profile's links
            // and still report the pass complete.
            profiles = try context.fetch(FetchDescriptor<BackendProfile>())
        } catch {
            outcome.abortReason = "profile fetch failed: \(error.localizedDescription)"
            logger.error("[SKILL_SWEEP] Could not read profiles: \(error.localizedDescription). CONSEQUENCE: NOTHING was imported and no profile was re-linked; the capture file is untouched and the next launch retries from the beginning. Nothing was lost.")
            return outcome
        }

        // Previously-failed folders, re-tried alongside whatever the profiles yield.
        let captured = SkillLibraryMigration.peekPendingImports()
        let pending = mergedPending(captured: captured,
                                    harvested: harvestLegacyFolders(from: profiles))
        guard !pending.isEmpty else { return outcome }

        logger.notice("[SKILL_SWEEP] Importing \(pending.count) pre-V6 skill folder(s) into the library (\(captured.count) retried from the previous pass, \(pending.count - captured.count) recovered from profile links).")

        // 1. Ingest. A folder may legitimately yield more than one skill, so the map is one-to-many.
        var byFolder: [String: [(id: String, name: String)]] = [:]
        var stillPending: [SkillLibraryMigration.LegacySkillRef] = []

        for ref in pending {
            // ⚠️ The hop is PER FOLDER. Reading everything in one hop would free the main actor
            // for the whole phase but hold every skill's bytes at once — `maxSkillBytes` is 30 MB,
            // so twenty folders is 600 MB resident. One at a time keeps the peak where it was.
            let result = await SkillIngest.readOffCallerActor(contentsOf: URL(fileURLWithPath: ref.folderPath))

            guard !result.skills.isEmpty else {
                let reason = result.rejected.first?.reason
                    ?? "Nothing readable was found at \(ref.folderPath)."
                outcome.failed.append(RejectedSkill(label: ref.name, reason: reason))
                // ⚠️ EVERY failure is recorded now, harvested ones included — the file is no longer
                // a migration capture but the Skills library's "could not be imported" list, and a
                // folder the user cannot see is a folder they cannot retry or dismiss. Retrying is
                // safe regardless: the harvest re-derives the same folder from the profile anyway,
                // so this adds visibility, not a second source of truth.
                stillPending.append(ref)
                logger.error("[SKILL_SWEEP] Could not import '\(ref.name)' from \(ref.folderPath): \(reason) CONSEQUENCE: it is NOT in the library, every profile that linked it still reports it as awaiting re-link, and this folder is retried on the next launch — most often the volume simply was not mounted.")
                continue
            }

            for ingested in result.skills {
                switch store.createSkill(from: ingested, origin: .imported, note: "Imported from \(ref.folderPath).") {
                case .failure(let error):
                    // ⚠️ ABORT, and keep the capture. A store that cannot be written to will not
                    // improve by continuing, and half an import followed by a cleared capture is
                    // the one state this pass must never leave behind.
                    outcome.abortReason = "could not write '\(ingested.name)': \(error.localizedDescription)"
                    logger.error("[SKILL_SWEEP] \(outcome.abortReason ?? ""). CONSEQUENCE: the sweep STOPPED, the capture file is untouched, and the next launch retries from the beginning. Skills already imported on this pass stay — a duplicate is possible if the retry succeeds, and is visible and removable, which a silent half-import is not.")
                    return outcome
                case .success(let skill):
                    // ⚠️ No permission travels with it — see `LegacySkillRef`. A recovered skill is
                    // not agent-writable until the user says so, which is `update_skill`'s
                    // default-deny posture and not a regression.
                    byFolder[ref.folderPath, default: []].append((id: skill.id, name: skill.name))
                    outcome.imported.append(skill.name)
                }
            }

            // Anything the folder held that did NOT import is still worth telling the user about.
            for rejection in result.rejected {
                outcome.failed.append(rejection)
                logger.notice("[SKILL_SWEEP] '\(rejection.label)' in \(ref.folderPath) was not imported: \(rejection.reason) CONSEQUENCE: the rest of that folder still imported; only this one is missing.")
            }
        }

        // 2. Re-link. Done even when some folders failed — the ones that succeeded should work now.
        relink(map: byFolder, profiles: profiles, context: context, into: &outcome)
        guard outcome.abortReason == nil else { return outcome }

        // 3. Clear, keeping only what failed.
        if shouldClearCapture(outcome) {
            SkillLibraryMigration.setPendingImports(stillPending)
        }

        logger.notice("[SKILL_SWEEP] Done: imported \(outcome.imported.count) skill(s), re-linked \(outcome.selectionsRelinked) profile reference(s) across \(outcome.profilesExamined) profile(s). \(outcome.failed.count) folder(s) failed and \(outcome.selectionsStillPending) reference(s) are still waiting. CONSEQUENCE: \(shouldClearCapture(outcome) ? (stillPending.isEmpty ? "nothing is left pending; the capture file is gone" : "\(stillPending.count) folder(s) are retried on the next launch") : "the capture file was KEPT because \(outcome.unreadableProfiles.count) profile(s) could not be read — repair them and relaunch to finish re-linking").")
        return outcome
    }

    /// Whether the capture file may be rewritten after a pass.
    ///
    /// ⚠️ Extracted as a pure function on purpose. The ordering it protects — ingest, re-link, THEN
    /// clear — is the sweep's one irreversible step, and an integration test cannot reach it: the
    /// production container always has a `BackendProfile` entity, so a profile fetch does not
    /// realistically fail on demand. A decision buried in a `guard` inside a 60-line function is a
    /// decision with no test; the same extraction fixed three untestable defects in this feature
    /// already.
    ///
    /// The rule: a pass that ABORTED must keep the file, because the capture is the only map from a
    /// folder to the skill it became. Failed FOLDERS are a different thing — they are written back
    /// individually and retried.
    ///
    /// ⚠️⚠️ AN UNREADABLE PROFILE ALSO KEEPS IT, and this used to be wrong in a way the sweep's own
    /// log announced: it told the user their links would be picked up on a later launch "provided
    /// the capture file still lists their folders", and then cleared that file on the very same
    /// pass. A profile whose blob could not be decoded at sweep time had its skills imported, its
    /// links left pending, and the only map from those folders to those skills deleted — so
    /// repairing the profile afterwards could never repair the links. Permanent, and silent.
    static func shouldClearCapture(_ outcome: SkillImportSweepOutcome) -> Bool {
        outcome.abortReason == nil && outcome.unreadableProfiles.isEmpty
    }

    // MARK: - Where the work comes from

    /// Every pre-V6 folder address still referenced by a profile.
    ///
    /// ⚠️⚠️ THIS EXISTS BECAUSE THE CAPTURE FILE IS EMPTY FOR EVERY REAL UPGRADE, AND WITHOUT IT
    /// THIS WHOLE PASS WAS A NO-OP THAT SILENTLY DISCARDED EVERY USER'S SKILLS.
    ///
    /// `captureLegacyFolderPaths` reads `SkillManifestSD` — the V4/V5 folder registry. **V4 and V5
    /// never shipped.** The last released build is at schema V3, where that table is created EMPTY
    /// by the lightweight V3→V4 stage, so the capture always found nothing, wrote no file, and this
    /// sweep returned at its first `guard`. Meanwhile the user's skills were sitting in the profile
    /// blob the whole time: `ProfileMigrator.migrateToV8` derives `skillSelections` from the legacy
    /// `skillConfig.manifests`, and `migrateToV9` moves each `folderPath` to `legacyFolderPath` with
    /// `skillID` absent. Every one of those selections then stayed `awaitingRelink` forever — agent
    /// runs with no skills, `load_skill` never registered, library empty, no banner, no error.
    ///
    /// So the profiles are not merely the thing this pass repairs; they are the only surviving
    /// record of WHAT to repair. The capture file remains the better source where it exists,
    /// because it also carries `isAgentWritable`, which a selection does not.
    ///
    /// ⚠️ Self-healing by construction, which the capture file is not: a harvested folder that
    /// fails to ingest leaves its selection `awaitingRelink`, so the next launch finds it again —
    /// and one that succeeds is re-linked and therefore stops being found. Nothing to write back,
    /// nothing to clear, no file to lose.
    ///
    /// Pure and total on purpose — it is the decision this defect turned on, and burying it in the
    /// middle of `run` is what made the original absence invisible to the whole suite.
    static func harvestLegacyFolders(from profiles: [BackendProfile]) -> [SkillLibraryMigration.LegacySkillRef] {
        var refs: [SkillLibraryMigration.LegacySkillRef] = []
        var seen = Set<String>()

        for profile in profiles {
            // An unreadable blob decodes to a placeholder with no selections; harvesting it would
            // report "nothing to do" for a profile whose links we simply could not read.
            guard profile.configurationUnreadableReason == nil else { continue }

            for selection in selections(in: profile.details) {
                guard selection.isAwaitingRelink,
                      let folder = selection.legacyFolderPath,
                      !folder.isEmpty else { continue }
                // Deduplicated by PATH, not by selection: two profiles linking the same folder must
                // ingest it once and then both re-link to what it produced.
                guard seen.insert(folder).inserted else { continue }
                refs.append(.init(folderPath: folder, name: selection.name))
            }
        }
        // Ordered so a repeated run behaves identically.
        return refs.sorted { $0.folderPath < $1.folderPath }
    }

    /// The captured refs plus any harvested folder the capture did not already name.
    ///
    /// ⚠️ CAPTURE WINS on a collision, and only for `isAgentWritable`. A harvested ref cannot know
    /// that flag and so defaults it to false; letting it displace a captured `true` would silently
    /// revoke a permission the user had granted. Default-deny is right for the unknown case and
    /// wrong as an overwrite.
    static func mergedPending(
        captured: [SkillLibraryMigration.LegacySkillRef],
        harvested: [SkillLibraryMigration.LegacySkillRef]
    ) -> [SkillLibraryMigration.LegacySkillRef] {
        let capturedPaths = Set(captured.map(\.folderPath))
        return captured + harvested.filter { !capturedPaths.contains($0.folderPath) }
    }

    /// The skill selections a profile holds, across every arm that stores them.
    ///
    /// ⚠️ `.code` is included for the same reason `rewrittenDetails` rewrites it: Code profiles
    /// persist selections even though the runtime gives them no skills, so omitting them here would
    /// leave dead addresses that resurface the day skills are enabled for Code.
    private static func selections(in details: ProfileDetails) -> [SkillSelection] {
        switch details {
        case .agent(let config): return config.skillSelections ?? []
        case .code(let config): return config.skillSelections ?? []
        case .bot, .workflow, .imageGen: return []
        }
    }

    // MARK: - Re-linking

    /// ⚠️ Takes the profiles `run` already fetched rather than fetching again. Two fetches would
    /// let the set of profiles change between harvest and re-link, so a profile added in that
    /// window could contribute a folder to the ingest and then never be re-linked to it.
    private static func relink(
        map: [String: [(id: String, name: String)]],
        profiles: [BackendProfile],
        context: ModelContext,
        into outcome: inout SkillImportSweepOutcome
    ) {
        for profile in profiles {
            outcome.profilesExamined += 1

            // ⚠️ An unreadable blob decodes to a `.bot` PLACEHOLDER with no skills and no error at
            // this call site. Treating that as "this profile has no selections" is precisely the
            // silent under-migration this guards against.
            if let reason = profile.configurationUnreadableReason {
                outcome.unreadableProfiles.append(profile.displayName)
                logger.error("[SKILL_SWEEP] Profile '\(profile.displayName)' is unreadable (\(String(describing: reason))). CONSEQUENCE: any pre-V6 skill links it holds were NOT re-linked and stay pending — repairing the profile and relaunching picks them up, provided the capture file still lists their folders.")
                continue
            }

            guard let rewritten = rewrittenDetails(for: profile.details, map: map, into: &outcome) else { continue }
            profile.details = rewritten
        }

        do { try context.save() } catch {
            outcome.abortReason = "profile save failed: \(error.localizedDescription)"
            logger.error("[SKILL_SWEEP] Could not save re-linked profiles: \(error.localizedDescription). CONSEQUENCE: the imported skills are in the library but every profile still points at nothing; the capture file is kept so the next launch retries. The user sees their links as awaiting re-link meanwhile.")
        }
    }

    /// Returns rewritten details, or nil when this profile has nothing to change.
    ///
    /// ⚠️ Returns nil rather than an unchanged copy so the caller never writes a profile it did not
    /// need to. Writing every profile on every launch would churn `configData` for no reason and
    /// defeat the no-op-save guard `BackendProfileStore` relies on.
    private static func rewrittenDetails(
        for details: ProfileDetails,
        map: [String: [(id: String, name: String)]],
        into outcome: inout SkillImportSweepOutcome
    ) -> ProfileDetails? {
        switch details {
        case .agent(var config):
            guard let updated = rewritten(config.skillSelections, map: map, into: &outcome) else { return nil }
            config.skillSelections = updated
            return .agent(config)
        case .code(var config):
            // ⚠️ `.code` reuses `AgentConfig` and persists `skillSelections` through its own arm.
            // Runtime currently gives Code profiles no skills, but the REFERENCES are stored and
            // must be migrated, or enabling skills for Code later silently inherits dead links.
            guard let updated = rewritten(config.skillSelections, map: map, into: &outcome) else { return nil }
            config.skillSelections = updated
            return .code(config)
        case .bot, .workflow, .imageGen:
            return nil
        }
    }

    /// Rewrites the pending selections it can, or returns nil when there is nothing to change.
    ///
    /// ⚠️ `internal` so the nil-means-do-not-write rule can be tested DIRECTLY. It cannot be
    /// observed through the sweep: re-encoding unchanged details produces byte-identical
    /// `configData`, so a test comparing stored bytes passes whether or not the write happened —
    /// verified, by a mutation that survived exactly that test. The rule still matters, because the
    /// unreachable-folder case recurs on every launch and a needless write is churn forever.
    static func rewritten(
        _ selections: [SkillSelection]?,
        map: [String: [(id: String, name: String)]],
        into outcome: inout SkillImportSweepOutcome
    ) -> [SkillSelection]? {
        guard let selections, selections.contains(where: \.isAwaitingRelink) else { return nil }

        var changed = false
        var result: [SkillSelection] = []
        for selection in selections {
            guard selection.isAwaitingRelink, let folder = selection.legacyFolderPath else {
                result.append(selection)
                continue
            }
            guard let candidates = map[folder], !candidates.isEmpty else {
                outcome.selectionsStillPending += 1
                result.append(selection)
                continue
            }

            // ⚠️ Match on NAME first. One captured folder can yield several skills, and the
            // selection recorded which one it meant. Taking `candidates.first` would silently
            // repoint a link at a sibling skill — the link would still "work", against the wrong
            // instructions, which is worse than leaving it pending.
            guard let match = candidates.first(where: { $0.name == selection.name }) else {
                outcome.selectionsStillPending += 1
                result.append(selection)
                logger.error("[SKILL_SWEEP] A profile links '\(selection.name)' from \(folder), but that folder imported \(candidates.count) skill(s) and none is named '\(selection.name)': \(candidates.map(\.name).joined(separator: ", ")). CONSEQUENCE: the link is left awaiting re-link rather than pointed at a sibling — the user can link the right skill in the Skills library.")
                continue
            }

            result.append(selection.relinked(to: match.id, name: match.name))
            outcome.selectionsRelinked += 1
            changed = true
        }
        return changed ? result : nil
    }
}
