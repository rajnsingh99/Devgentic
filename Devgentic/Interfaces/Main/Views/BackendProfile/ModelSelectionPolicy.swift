// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelSelectionPolicy.swift
//  Devgentic
//
//  Created on 08/08/26.
//
//  The one rule every model picker follows when a fetched list arrives: **never rewrite a model the
//  user already chose.** (2026-10-09: the profile editor's per-provider pickers named below are
//  deleted — the model catalog replaced them — so the live caller is the ImageGen Flux2 selection.)
//
//  ⚠️ This rule has now been broken and re-fixed four separate times in this codebase — OpenRouter
//  (register G95), the cloud pickers (MP-01), and the Ollama picker (A37) — because each picker
//  implemented it inline and they drifted apart. Opening a profile to change something unrelated
//  could repoint it at a different model, silently, with no undo. Extracted so the next picker
//  inherits the rule instead of re-deriving it.
//
//  ⚠️ A model missing from a fetched list is NOT evidence the user was wrong. It may be newly
//  released, region-limited, hand-entered, removed from a daemon that is still starting, or absent
//  because the fetch itself half-failed. The run reports the failure honestly if it really is gone,
//  which is a far better outcome than a profile that quietly changed model.
//
//  There is no exception. The former `MLXModelPickerView` carried one (an MLX model missing from
//  the local disk was replaced); register B13 deleted it after proving its premise false, and the
//  view itself was deleted on 2026-10-09 — nothing constructed it once the model catalog took over.
//

import Foundation

/// What a picker should do with its `selectedModel` after a fetch.
enum ModelSelectionResolution: Equatable {
    /// The saved model is in the list. Nothing to do.
    case keep
    /// There was no selection at all, so this one was filled in. A new profile has nothing to lose.
    case fill(String)
    /// A saved model that the fetched list does not contain. **Kept**, and worth a log line so the
    /// discrepancy is visible without the profile being altered.
    case keptUnlisted(String)
    /// Nothing was selected and the list is empty, so there is nothing to fill it with.
    case nothingAvailable
}

enum ModelSelectionPolicy {

    /// Resolves what should happen to `saved` given the models a fetch returned.
    ///
    /// - Parameters:
    ///   - saved: the profile's current `selectedModel` (may be empty).
    ///   - available: every model id the fetch returned, in display order.
    ///   - fillCandidate: which id to use when filling an empty selection. Pass a
    ///     capability-preferred choice where one exists (the Ollama agent picker prefers a
    ///     tool-capable model); defaults to the first available.
    static func resolve(
        saved: String,
        available: [String],
        fillCandidate: String? = nil
    ) -> ModelSelectionResolution {
        guard !saved.isEmpty else {
            guard let candidate = fillCandidate ?? available.first else { return .nothingAvailable }
            return .fill(candidate)
        }

        // ⚠️ An empty list means the fetch found nothing — a daemon that is down, an endpoint that
        // 403'd. That is the LEAST safe moment to conclude the saved model is invalid.
        guard !available.isEmpty else { return .keptUnlisted(saved) }

        return available.contains(saved) ? .keep : .keptUnlisted(saved)
    }
}
