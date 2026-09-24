// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WithdrawnToolSweep.swift
//  Devgentic
//
//  Removes BUILT-IN tool names a profile stores that the catalogue no longer has.
//
//  ── The defect, measured on device (2026-09-23) ─────────────────────────────────────────
//
//  Withdrawing `batch_command` left it stored in a profile saved before the change. Two symptoms
//  on every single send, forever:
//
//    [TOOLRESOLVE] ⚠️ 'batch_command' NOT RESOLVED — the agent will run WITHOUT this capability.
//    [TOOLSCHEMA] 1 tool(s) absent from the snapshot, priced at 0 … Absent: batch_command.
//
//  The first is correct and wanted — it is how a user learns a capability went away. The second is
//  a real cost: `ToolSchemaSizes` cannot price a name that is in neither the registry nor the
//  catalogue, so the context gauge and the pre-send fit check BOTH report more headroom than the
//  request actually has, on every send.
//
//  ⚠️ And the user cannot fix it themselves. The Tool Library renders from `UnifiedToolStore`, so a
//  name with no matching source has no row to un-tick. The entry is unreachable from the UI.
//
//  ── ⚠️⚠️ BUILT-IN ONLY. NEVER AN MCP TOOL. ──────────────────────────────────────────────
//
//  An MCP tool absent from the catalogue is the NORMAL case — its server may simply be offline,
//  unauthenticated, or slow to hand over its list. The device log shows two servers failing
//  authentication at launch with 29 tools between them; pruning those would silently delete the
//  user's configuration because a remote endpoint had a bad day.
//
//  A missing BUILT-IN is different in kind: the catalogue is compiled in. If a name is not there,
//  no future launch will produce it, and nothing the user does can bring it back.
//
//  ── Why a sweep rather than a rename map ────────────────────────────────────────────────
//
//  A rename map was built for `batch_command` and deliberately deleted: it guesses what a name
//  MEANT, which is the guess-by-name behaviour `resolveExecutableTools` removed on purpose. This
//  claims nothing about meaning. It removes an entry that cannot resolve, and says so.
//

import Foundation
import os

private let logger = DGLogger(category: "WithdrawnToolSweep")

@MainActor
enum WithdrawnToolSweep {

    /// Tool names in `profile` that name a BUILT-IN the catalogue does not have.
    ///
    /// Pure and `static` so the rule is testable without a store: given a tool list, which entries
    /// are unreachable? Both the sweep and its tests ask this one function.
    static func withdrawnNames(in tools: [Tool]) -> [String] {
        tools.filter { tool in
            tool.sourceId == ToolSource.builtInSourceID
                && NativeToolCatalog.entry(named: tool.name) == nil
                && !NativeToolCatalog.injectedToolNames.contains(tool.name)
        }
        .map(\.name)
    }

    /// Drops those entries from every profile that has one. Returns how many profiles changed.
    ///
    /// ⚠️ Saves only a profile that actually changed. A blanket re-save would bump `lastSelected`
    /// on every profile and reorder "recently used" at every launch — the same waste
    /// `[PROFILE_SAVE] ⚠️ REDUNDANT` already calls out.
    @discardableResult
    static func run(store: BackendProfileStoreProtocol = BackendProfileStore.shared) -> Int {
        guard let profiles = try? store.fetchProfiles() else {
            logger.error("[TOOLSWEEP] Could not read profiles — the sweep did not run. CONSEQUENCE: any profile holding a withdrawn built-in keeps it, so the context gauge under-reads by that tool's schema size on every send until the next launch.")
            return 0
        }

        var changed = 0
        for profile in profiles {
            guard let config = profile.details.agentConfig else { continue }
            let doomed = Set(withdrawnNames(in: config.tools))
            guard !doomed.isEmpty else { continue }

            var prunedConfig = config
            prunedConfig.tools = config.tools.filter { !doomed.contains($0.name) }

            // ⚠️ Rewrapped by CASE rather than through a generic setter. `.code` reuses
            // `AgentConfig`, so re-emitting `.agent` for it would silently change a Code profile's
            // type on disk — and the exhaustive switch is what makes a sixth `ProfileDetails` case
            // fail to compile instead of quietly falling through.
            let prunedDetails: ProfileDetails
            switch profile.details {
            case .agent:  prunedDetails = .agent(prunedConfig)
            case .code:   prunedDetails = .code(prunedConfig)
            case .bot, .workflow, .imageGen: continue
            }

            do {
                _ = try store.saveProfile(
                    BackendProfileSnapshot(id: profile.id,
                                           displayName: profile.displayName,
                                           details: prunedDetails))
                changed += 1
                logger.notice("[TOOLSWEEP] Removed \(doomed.count) withdrawn built-in tool(s) from '\(profile.displayName)' (\(profile.id.uuidString.prefix(8))): \(doomed.sorted().joined(separator: ", ")). CONSEQUENCE: the ⚠️ NOT RESOLVED error and the un-priced tool schema both stop on every send; the capability was already gone, so nothing the agent could do changes.")
            } catch {
                logger.error("[TOOLSWEEP] FAILED to prune '\(profile.displayName)' (\(profile.id.uuidString.prefix(8))): \(error.localizedDescription). CONSEQUENCE: that profile keeps the unresolvable entry and its gauge keeps under-reading.")
            }
        }
        return changed
    }
}
