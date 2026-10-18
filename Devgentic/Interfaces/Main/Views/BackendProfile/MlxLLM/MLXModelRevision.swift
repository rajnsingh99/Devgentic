// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelRevision.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "MLXModelRevision")

/// Reads the commit a downloaded MLX model was fetched at and compares it with the published `sha`.
/// Lets the app tell whether an installed copy is current or the repo's branch tip has moved.
enum MLXModelRevision {

    /// Where HubApi keeps its per-file download metadata, relative to a model folder.
    private static let metadataSubpath = ".cache/huggingface/download"

    /// The commit hash a model was downloaded at, or nil when it can't be determined.
    /// Reads each file's `.metadata` in a stable order and logs disagreement between snapshots.
    static func installedRevision(atModelFolder folder: URL) -> String? {
        let metadataDir = folder.appendingPathComponent(metadataSubpath)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: metadataDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        let metadataFiles = files.filter { $0.pathExtension == "metadata" }.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
        guard !metadataFiles.isEmpty else { return nil }

        // Why: stale metadata of files that left the repo is never pruned, so a minority of old hashes can linger
        // Counts commits across metadata files; the one most files agree on is the model's revision.
        var counts: [String: Int] = [:]
        for file in metadataFiles {
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Line 1 is the commit hash — see `HubApi.writeDownloadMetadata`.
            guard let hash = contents.split(separator: "\n").first.map(String.init),
                  isPlausibleCommitHash(hash) else { continue }
            counts[hash, default: 0] += 1
        }

        guard !counts.isEmpty else { return nil }
        guard counts.count > 1 else { return counts.first?.key }

        // Rank by file count, with a stable tiebreak so the log is reproducible.
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let summary = ranked.map { "\(shortForm($0.key))×\($0.value)" }.joined(separator: ", ")

        // Why: a wrong pick can assert "Update available" forever or hide a real update
        // An even split is unanswerable, so report `.unknown` instead of picking a hash.
        guard ranked[0].value > ranked[1].value else {
            logger.error("[MLXSTORE] \(folder.lastPathComponent) has NO majority revision — its metadata splits evenly across \(counts.count) commits (\(summary)). CONSEQUENCE: reporting no revision, so the update check answers .unknown instead of comparing against an arbitrarily chosen commit. Re-download to make the folder consistent.")
            return nil
        }

        logger.warning("[MLXSTORE] \(folder.lastPathComponent) contains files from \(counts.count) different revisions (\(summary)). CONSEQUENCE: reporting the majority commit \(self.shortForm(ranked[0].key)); the minority files are probably stale metadata HubApi never pruned, but a re-download is the only way to be certain.")
        return ranked[0].key
    }

    /// Git object ids are 40 hex characters. Guards against a truncated or garbage metadata
    /// file being reported as a revision and then compared against a real `sha`.
    static func isPlausibleCommitHash(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy(\.isHexDigit)
    }

    /// Short form for display.
    static func shortForm(_ hash: String) -> String {
        String(hash.prefix(7))
    }

    // MARK: - Update comparison

    /// The result of comparing an installed revision against the published one.
    enum UpdateStatus: Equatable {
        /// Installed revision matches what HuggingFace publishes.
        case upToDate(revision: String)
        /// The publisher has pushed a newer commit.
        case updateAvailable(installed: String, latest: String)
        /// Can't tell: no local metadata, or the remote didn't report a `sha`.
        /// Distinct from `upToDate`, which must never be reported when the answer is unknown.
        case unknown(reason: String)

        var needsUpdate: Bool {
            if case .updateAvailable = self { return true }
            return false
        }
    }

    static func compare(installed: String?, latest: String?) -> UpdateStatus {
        guard let installed, isPlausibleCommitHash(installed) else {
            return .unknown(reason: "No download metadata for this model — it may predate revision tracking, or have been imported.")
        }
        guard let latest, isPlausibleCommitHash(latest) else {
            return .unknown(reason: "HuggingFace didn't report a revision for this model.")
        }
        return installed == latest
            ? .upToDate(revision: installed)
            : .updateAvailable(installed: installed, latest: latest)
    }
}
