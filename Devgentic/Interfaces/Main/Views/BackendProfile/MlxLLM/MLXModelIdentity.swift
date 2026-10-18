// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXModelIdentity.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Hub

/// The single definition of "which model is this?" for the MLX subsystem.
/// Both the derivation of a model's identity key and the comparison against it live here.
enum MLXModelIdentity {


    // MARK: - Derivation

    /// The canonical `author/name` repo id for a model directory.
    /// `downloadBase` is `MLXModelService.modelsDirectory`; HubApi's extra `models` path segment is not part of the id.
    /// Layouts: HubApi's `<base>/models/<author>/<name>/`, the python `huggingface_hub` cache, else the folder name.
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
        /// Full repo ids agree.
        case exact
        case none
    }

    // Why: a substring match reports a distinct model as installed and hides its Download button.
    /// Compares a stored/installed identifier against a candidate repo id.
    /// Never a `contains` test: a bare model name is a substring of longer variants (`…-4bit` in `…-4bit-DWQ`).
    static func match(installed: String, candidate: String) -> MatchKind {
        let lhs = installed.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !rhs.isEmpty else { return .none }

        return lhs.caseInsensitiveCompare(rhs) == .orderedSame ? .exact : .none
    }

    /// Convenience boolean.
    @MainActor
    static func matches(installed: String, candidate: String) -> Bool {
        match(installed: installed, candidate: candidate) == .exact
    }
}
