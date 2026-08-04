//
//  CuratedMLXCatalog.swift
//  Devgentic
//
//  Created 2026-08-03 for G7.
//
//  A brand-new user with zero models opened the store and got a raw HuggingFace popularity
//  dump. Verified against the live endpoint this app calls: results 1, 2 and 29 of the first 30
//  were `parakeet-tdt` automatic-speech-recognition models — which `MLXService.loadModel`
//  cannot run as LLMs — each rendered with a "Chat" badge, and result 28 was a 657 GB repo.
//
//  This mirrors `WhisperModelCatalog`, which the app's sibling surface already does right: a
//  hand-checked, RAM-tiered list that gives a first run somewhere sane to start.
//
//  ⚠️ Curation rules for anyone editing this list:
//    1. Every entry must EXIST on HuggingFace. Each id below was verified live (HTTP 200) with
//       its size read from the API on 2026-08-03. A 404 here is a broken first-run experience.
//    2. No gated repos — the app has no HuggingFace token support yet (G4), so a gated entry
//       would fail at download with a 401.
//    3. Prefer tool-capable instruct models: this store is the onboarding path for agent
//       profiles, and a model that cannot call tools is a dead end there.
//    4. This is a STARTING POINT, not a whitelist. The full HuggingFace listing stays one tab
//       away — per the standing directive, curation describes, it never gates.
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
    ///
    /// Sizes were read from `usedStorage` on the HuggingFace API on 2026-08-03; they are
    /// indicative only and the download path always fetches the real total.
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

    /// The curated set, ordered so models this machine can actually run come first.
    ///
    /// Ordering only — nothing is hidden. A user on 8 GB can still see and download the 30B
    /// coder model; it simply is not the first thing offered.
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

    /// ⚠️ A DENYLIST, not an allowlist — deliberately.
    ///
    /// An allowlist silently drops anything with an unfamiliar tag, and the tag vocabulary
    /// moves. Verified against the live top-30: `any-to-any` accounts for 8 of 30 entries (the
    /// gemma-4 multimodal models) and those are perfectly usable LLMs — an allowlist built from
    /// the obvious `text-generation` / `image-text-to-text` pair would have hidden all of them.
    /// So unknown tags stay visible and only known-unusable ones are excluded.
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
