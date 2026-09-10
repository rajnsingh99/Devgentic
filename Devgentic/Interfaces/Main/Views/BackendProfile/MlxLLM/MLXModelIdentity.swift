// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MLXModelIdentity.swift
//  Devgentic
//
//  Created 2026-08-03 for Batch 1 of the MLX Model Manager readiness plan (A3 + A17).
//
//  The single definition of "which model is this?" for the MLX subsystem.
//
//  Why this file exists. `MLXModelItem.displayName` is the identity key everywhere — the
//  install check in `DownloadCoordinator`, the terminal-state decision in `DownloadManager`,
//  the profile-to-path resolution in `AgentConnect` / `IntelligenceCoreService` /
//  `HistoryCompactionService` / `WorkflowExecutor`, the profile cache, and the store's
//  Installed badge. It was produced by re-attaching the author only when the parent directory
//  was literally `mlx-community`, so every other publisher yielded a bare model name. Two
//  incompatible comparators then grew around that: an exact `==` (which never matched for
//  those models) and a lenient `contains` (which matched too much, marking un-downloaded
//  models as installed and hiding their Download button entirely).
//
//  Both the derivation and the comparison live here so they cannot drift apart again.
//

import Foundation
import Hub

enum MLXModelIdentity {

    @MainActor private static let logger = DGLogger(category: "MLXModelIdentity")

    // MARK: - Derivation

    /// The canonical `author/name` repo id for a model directory.
    ///
    /// `downloadBase` is `MLXModelService.modelsDirectory` — the value handed to
    /// `HubApi(downloadBase:)`. HubApi nests everything one level deeper under the repo-type
    /// segment (`models`), which is part of the on-disk layout but NOT part of the repo id.
    ///
    /// Handles three layouts:
    ///   1. `<base>/models/<author>/<name>/`        — what HubApi writes today.
    ///   2. `…/models--Org--Name/snapshots/<sha>/`  — the python `huggingface_hub` cache.
    ///   3. Anything else                            — falls back to the folder name.
    static func canonicalRepoId(forModelAt modelDir: URL, downloadBase: URL) -> String {
        // (2) first: in the python cache `modelDir.lastPathComponent` is a commit SHA, so a
        // `starts(with: "models--")` test on the leaf never fires — the marker is an ancestor.
        var ancestor = modelDir.standardizedFileURL
        while ancestor.pathComponents.count > 1 {
            let name = ancestor.lastPathComponent
            if name.hasPrefix("models--") {
                return name
                    .replacingOccurrences(of: "models--", with: "")
                    .replacingOccurrences(of: "--", with: "/")
            }
            ancestor = ancestor.deletingLastPathComponent()
        }

        // (1) Path relative to the download base, minus the repo-type segment.
        let baseComponents = downloadBase.standardizedFileURL.pathComponents
        let modelComponents = modelDir.standardizedFileURL.pathComponents
        guard modelComponents.count > baseComponents.count,
              Array(modelComponents.prefix(baseComponents.count)) == baseComponents else {
            return modelDir.lastPathComponent  // (3)
        }
        var relative = Array(modelComponents.dropFirst(baseComponents.count))
        if relative.count > 1, relative[0] == Hub.RepoType.models.rawValue {
            relative.removeFirst()
        }
        return relative.joined(separator: "/")
    }

    // MARK: - Comparison

    /// How a match was reached. Callers that care about ambiguity can inspect this;
    /// most just use `matches`.
    enum MatchKind: Equatable {
        /// Full repo ids agree — the only unambiguous outcome.
        case exact
        /// Only the bare model names agree. Ambiguous across publishers: two orgs can ship
        /// the same folder name. Tolerated because profiles saved before the canonical-id
        /// fix stored the bare name, and dropping them would orphan the user's configured
        /// model. Always logged.
        case legacyBareName
        case none
    }

    /// Compare a stored/installed identifier against a candidate repo id.
    ///
    /// ⚠️ Never use `contains` here. The bare model name is a *substring* of longer variant
    /// names (`…-4bit` inside `…-4bit-DWQ`), so a substring test reports a distinct model as
    /// installed and the store then renders no Download affordance for it at all.
    static func match(installed: String, candidate: String) -> MatchKind {
        let lhs = installed.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty else { return .none }

        if lhs.caseInsensitiveCompare(rhs) == .orderedSame { return .exact }

        // Legacy tolerance: exactly one side carries an author. Compare whole path
        // components — never a substring.
        let lhsBare = lhs.components(separatedBy: "/").last ?? lhs
        let rhsBare = rhs.components(separatedBy: "/").last ?? rhs
        let onlyOneIsQualified = lhs.contains("/") != rhs.contains("/")
        if onlyOneIsQualified, lhsBare.caseInsensitiveCompare(rhsBare) == .orderedSame {
            return .legacyBareName
        }
        return .none
    }

    /// Convenience boolean. Logs whenever the ambiguous legacy branch is what produced the
    /// match, naming both identifiers, so a wrong resolution is diagnosable from the log.
    @MainActor
    static func matches(installed: String, candidate: String) -> Bool {
        switch match(installed: installed, candidate: candidate) {
        case .exact:
            return true
        case .legacyBareName:
            logger.warning("[MLXSTORE] Identity matched only on the bare model name: installed='\(installed)' candidate='\(candidate)'. CONSEQUENCE: this is ambiguous across publishers — if two orgs ship this folder name the wrong model may be resolved. Re-select the model in the profile to store its full repo id.")
            return true
        case .none:
            return false
        }
    }
}
