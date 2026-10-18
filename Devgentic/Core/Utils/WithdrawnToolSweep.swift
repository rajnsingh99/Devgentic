// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WithdrawnToolSweep.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "WithdrawnToolSweep")

/// Removes built-in tool names a profile stores that the catalogue does not have.
/// Built-in only, never an MCP tool: an MCP tool missing from the catalogue is normal (its server may be offline).
/// A stale built-in name cannot resolve or be priced by `ToolSchemaSizes`, and has no Tool Library row to un-tick.
@MainActor
enum WithdrawnToolSweep {

    /// Tool names in `profile` that name a built-in the catalogue does not have.
    /// Pure and `static` so the rule is testable without a store; both the sweep and its tests ask this one function.
    static func withdrawnNames(in tools: [Tool]) -> [String] {
        tools.filter { tool in
            tool.sourceId == ToolSource.builtInSourceID
                && NativeToolCatalog.entry(named: tool.name) == nil
                && !NativeToolCatalog.injectedToolNames.contains(tool.name)
        }
        .map(\.name)
    }

    // Why: save only a profile that actually changed: a blanket re-save bumps `lastSelected` and reorders recently used.
    /// Drops those entries from every profile that has one; returns how many profiles changed.
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

            // Rewrapped by case, not a generic setter: `.code` reuses `AgentConfig`, so re-emitting `.agent` would change a Code
            // profile's type on disk; the exhaustive switch makes a new `ProfileDetails` case fail to compile.
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
