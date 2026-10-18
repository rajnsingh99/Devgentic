// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelSelectionPolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// Resolves what should happen to `saved` given the `available` model ids a fetch returned.
    /// `fillCandidate` is the id used when filling an empty selection (a capability-preferred choice where one exists);
    /// it defaults to the first available.
    static func resolve(
        saved: String,
        available: [String],
        fillCandidate: String? = nil
    ) -> ModelSelectionResolution {
        guard !saved.isEmpty else {
            guard let candidate = fillCandidate ?? available.first else { return .nothingAvailable }
            return .fill(candidate)
        }

        // An empty list means the fetch found nothing (daemon down, endpoint refused): the least safe moment
        // to conclude the saved model is invalid.
        guard !available.isEmpty else { return .keptUnlisted(saved) }

        return available.contains(saved) ? .keep : .keptUnlisted(saved)
    }
}
