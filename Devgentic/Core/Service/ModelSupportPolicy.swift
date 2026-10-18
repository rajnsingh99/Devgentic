// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelSupportPolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The single answer to "can Devgentic run this model at all?" for the download surfaces.
/// Gates decision/classifier models that no inference service can load, using declared repo fields (pipeline tag, tags);
/// untagged repos stay supported.
enum ModelSupportPolicy {

    /// Pipelines that name a classifier/decision model specifically (as opposed to speech, image,
    /// or embedding models). Used only to pick the wording; membership in
    /// `MLXPipelineFilter.excludedPipelineTags` is what makes a model unsupported.
    nonisolated static let decisionPipelineTags: Set<String> = [
        "text-classification",
        "token-classification",
        "zero-shot-classification"
    ]

    /// The category's own self-declared label (TypeSafe/Laya publish it as a repo tag).
    nonisolated static let decisionModelTag = "system-one"

    /// A user-facing reason this model cannot be run, or nil when it is supported or unknown.
    /// - Parameters: `pipelineTag` is the HuggingFace `pipeline_tag` as declared; `tags` are the repo's declared tags.
    nonisolated static func unsupportedReason(pipelineTag: String?, tags: [String]) -> String? {
        let pipeline = pipelineTag?.lowercased()

        if let pipeline, decisionPipelineTags.contains(pipeline) {
            return String(localized: "This is a decision/classifier model (\(pipeline)). It returns typed judgments rather than generating text, and Devgentic can't run these yet.")
        }
        if tags.contains(where: { $0.lowercased() == decisionModelTag }) {
            return String(localized: "This is a System One decision model. It returns typed judgments rather than generating text, and Devgentic can't run these yet.")
        }
        if let pipeline, MLXPipelineFilter.excludedPipelineTags.contains(pipeline) {
            return String(localized: "This isn't a text-generation model (\(pipeline)), so Devgentic can't run it as a chat model.")
        }
        return nil
    }

    /// Convenience over `unsupportedReason` for filters.
    nonisolated static func isSupported(pipelineTag: String?, tags: [String]) -> Bool {
        unsupportedReason(pipelineTag: pipelineTag, tags: tags) == nil
    }

    /// The `hf.co/<owner>/<repo>[:quant]` form Ollama accepts for pulling a HuggingFace GGUF.
    /// Returns the `owner/repo` pair, or nil for an ordinary library name (`llama3.2:3b`), for
    /// which no pre-download metadata exists anywhere.
    nonisolated static func huggingFaceRepoId(fromOllamaName name: String) -> String? {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        for prefix in ["hf.co/", "huggingface.co/"] where lower.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            if let colon = s.firstIndex(of: ":") { s = String(s[s.startIndex..<colon]) }
            let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
            return parts.joined(separator: "/")
        }
        return nil
    }
}
