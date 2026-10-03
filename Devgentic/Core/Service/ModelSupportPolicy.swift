// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelSupportPolicy.swift
//  Devgentic
//
//  The ONE answer to "can Devgentic run this model at all?" for the download surfaces.
//
//  ⚠️ WHY THIS IS A DOWNLOAD GATE AND NOT "CAPABILITY METADATA". The standing rule is that a
//  capability verdict (tool support, reasoning, fit) may LABEL or GROUP a model, never block an
//  action — because those verdicts are guesses and the user may know better. This is a different
//  question: a decision model (Jev-style / Laya / GLiNER2.5-Decide) is an ENCODER with a typed
//  decision head. There is no generation loop, no chat template, no tool-call output — nothing in
//  `MLXService` or `OllamaService` can load it, so a "successful" download is a multi-GB file that
//  fails at first use with an error that never names the cause. It is gated by the owner's
//  explicit decision (2026-10-03: "we are not yet supporting decision models"), and every signal
//  below is a DECLARED field on the repo, not a shape guess.
//
//  ⚠️ DECLARED SIGNALS ONLY. Verified against the live HuggingFace API (2026-10-03):
//    • convaiinnovations/laya      → pipeline_tag `text-classification`, tag `system-one`,
//                                    config `{}` — NO `architectures`, so an architecture check
//                                    would have missed it. The pipeline tag is what catches it.
//    • fastino/GLiNER2.5-Decide    → pipeline_tag `token-classification`, architectures
//                                    `["SpanExtractor"]` (not a stock transformers class).
//  Untagged repos stay SUPPORTED — the same stance `MLXPipelineFilter` already takes, for the same
//  reason: the tag vocabulary moves, and hiding an unfamiliar-but-usable LLM is the worse error.
//

import Foundation

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

    /// A user-facing reason this model cannot be run, or nil when it is supported / unknown.
    ///
    /// - Parameters:
    ///   - pipelineTag: HuggingFace `pipeline_tag`, exactly as declared.
    ///   - tags: the repo's declared `tags`.
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
