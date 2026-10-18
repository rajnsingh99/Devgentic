// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CuratedMLXCatalog.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// A hand-checked model recommendation.
struct CuratedMLXModel: Identifiable, Hashable, Sendable {
    /// HuggingFace repo id. Verified to exist at the date in the file header.
    let id: String
    /// Why someone would pick this one, in plain language.
    let rationale: String
    /// Approximate download size in bytes, read from the HuggingFace API at curation time.
    /// Display-only — the real size is fetched before any download starts.
    let approximateBytes: Int64
    /// Minimum system RAM this is a sensible choice for.
    let recommendedMinimumRAMGB: Int

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: approximateBytes, countStyle: .file)
    }
}

enum CuratedMLXCatalog {

    /// Ordered smallest-first so the list reads as a ladder.
    /// Sizes are indicative only (from HuggingFace `usedStorage`); the download path always fetches the real total.
    static let models: [CuratedMLXModel] = [
        CuratedMLXModel(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            rationale: "Small and quick. A good first model on any Apple silicon Mac, and capable enough for tool use.",
            approximateBytes: 1_700_000_000,
            recommendedMinimumRAMGB: 8
        ),
        CuratedMLXModel(
            id: "mlx-community/Phi-4-mini-instruct-4bit",
            rationale: "Strong reasoning for its size, with reliable tool calling. Good on 8–16 GB machines.",
            approximateBytes: 2_200_000_000,
            recommendedMinimumRAMGB: 8
        ),
        CuratedMLXModel(
            id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            rationale: "A noticeable step up in quality from the 3B, still comfortable on 16 GB.",
            approximateBytes: 4_300_000_000,
            recommendedMinimumRAMGB: 16
        ),
        CuratedMLXModel(
            id: "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            rationale: "Well-rounded general model with solid tool support and a 128K context window.",
            approximateBytes: 4_500_000_000,
            recommendedMinimumRAMGB: 16
        ),
        CuratedMLXModel(
            id: "mlx-community/granite-3.3-8b-instruct-4bit",
            rationale: "IBM's instruct model — dependable at following structured instructions.",
            approximateBytes: 4_600_000_000,
            recommendedMinimumRAMGB: 16
        ),
        CuratedMLXModel(
            id: "mlx-community/Mistral-Nemo-Instruct-2407-4bit",
            rationale: "Very large context window and strong multi-step tool use. Wants 24 GB or more.",
            approximateBytes: 6_900_000_000,
            recommendedMinimumRAMGB: 24
        ),
        CuratedMLXModel(
            id: "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit",
            rationale: "Specialised for code. A mixture-of-experts model, so it runs faster than its size suggests — but it is a big download.",
            approximateBytes: 17_200_000_000,
            recommendedMinimumRAMGB: 32
        )
    ]

    /// The curated set, ordered so models this machine can run come first.
    /// Ordering only, nothing is hidden: a user on 8 GB can still see and download the 30B coder model.
    static func recommended(forSystemRAMGB ramGB: Int) -> [CuratedMLXModel] {
        models.sorted { lhs, rhs in
            let lhsFits = lhs.recommendedMinimumRAMGB <= ramGB
            let rhsFits = rhs.recommendedMinimumRAMGB <= ramGB
            if lhsFits != rhsFits { return lhsFits }
            return lhs.approximateBytes < rhs.approximateBytes
        }
    }

    static func contains(repoId: String) -> Bool {
        models.contains { $0.id.caseInsensitiveCompare(repoId) == .orderedSame }
    }
}

// MARK: - Pipeline filtering

/// Which HuggingFace `pipeline_tag`s name models `MLXService` cannot run as an LLM.
enum MLXPipelineFilter {

    // Why: a denylist, not an allowlist: an allowlist would hide usable models
    // carrying unfamiliar tags such as `any-to-any` (multimodal LLMs).
    /// HuggingFace pipeline tags that cannot serve as an LLM.
    /// Unknown tags stay visible; only known-unusable ones are excluded.
    static let excludedPipelineTags: Set<String> = [
        "automatic-speech-recognition",   // parakeet — results 1, 2 and 29 of the live top-30
        "text-to-speech",
        "text-to-audio",
        "audio-to-audio",
        "audio-classification",
        "voice-activity-detection",
        "text-to-image",
        "image-to-image",
        "image-classification",
        "image-segmentation",
        "object-detection",
        "depth-estimation",
        "feature-extraction",            // embedding models
        "sentence-similarity",
        "fill-mask",
        "token-classification",
        "text-classification",
        "zero-shot-classification",
        "reinforcement-learning"
    ]

    /// True when a listing entry should be hidden from the LLM store.
    static func shouldExclude(pipelineTag: String?) -> Bool {
        guard let tag = pipelineTag?.lowercased() else { return false }  // untagged stays visible
        return excludedPipelineTags.contains(tag)
    }
}
