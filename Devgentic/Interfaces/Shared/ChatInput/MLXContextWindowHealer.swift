// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXContextWindowHealer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Heals MLX profiles whose stored `modelMetadata.contextWindow` is nil, using the on-disk model's real window.
/// Looks it up via `MLXModelService` and, once per profile per session, writes it back to the profile.
@MainActor
enum MLXContextWindowHealer {

    private static let logger = DGLogger(category: "MLXContextWindowHealer")

    /// Profiles a persist has already been attempted for this session. The (cheap, cached)
    /// window LOOKUP still runs on every gauge recompute so the display is always correct;
    /// only the write-back is de-duplicated.
    private static var persistedThisSession: Set<UUID> = []

    /// The real trained window for an MLX config whose persisted metadata lacks one, or nil
    /// for non-MLX configs / uninstalled models. Best-effort persists the value back to the
    /// profile the first time a given profile is healed.
    static func trainedWindow(for config: ProviderConfig, profileID: UUID?) -> Int? {
        guard config.apiProvider == .mlx else { return nil }
        guard let window = MLXModelService.shared.trainedContextWindow(forModelName: config.modelName) else {
            return nil
        }
        if let profileID, !persistedThisSession.contains(profileID) {
            persistedThisSession.insert(profileID)
            persistBackfill(window: window, profileID: profileID, modelName: config.modelName)
        }
        return window
    }

    /// Writes the healed window into the persisted profile so compaction / RAG / native-turn budgets use it too.
    /// Re-running is a no-op. Best-effort: a failure leaves the gauge correct and the backfill retries next launch.
    private static func persistBackfill(window: Int, profileID: UUID, modelName: String) {
        do {
            guard var snapshot = try BackendProfileStore.shared.fetchProfile(byId: profileID) else { return }

            switch snapshot.details {
            case .bot(var cfg):
                guard let healed = healedConfig(cfg.llmConfig, window: window) else { return }
                cfg.llmConfig = healed
                snapshot.details = .bot(cfg)
            case .agent(var cfg):
                guard let healed = healedConfig(cfg.llmConfig, window: window) else { return }
                cfg.llmConfig = healed
                snapshot.details = .agent(cfg)
            case .code(var cfg):
                guard let healed = healedConfig(cfg.llmConfig, window: window) else { return }
                cfg.llmConfig = healed
                snapshot.details = .code(cfg)
            default:
                return  // workflow / imageGen have no single chat model to heal
            }

            try BackendProfileStore.shared.saveProfile(snapshot)
            logger.info("[MLX-MIGRATE] Backfilled context window \(window) into MLX profile \(profileID.uuidString.prefix(8)) (\(modelName)) — gauge + compaction/RAG/native-turn budgets now use the real window instead of the 8K fallback.")
        } catch {
            logger.warning("[MLX-MIGRATE] Failed to persist backfilled context window \(window) for profile \(profileID.uuidString.prefix(8)) (\(modelName)): \(error.localizedDescription) — gauge still shows the real window this session; budgets heal on the next successful save.")
        }
    }

    /// Test seam for `healedConfig`. Internal rather than private so the absent-metadata case
    /// below is pinned without reaching through the profile store.
    static func healedConfigForTesting(_ config: ProviderConfig, window: Int) -> ProviderConfig? {
        healedConfig(config, window: window)
    }

    // Why: an optional-chained window write onto nil `modelMetadata` silently does nothing; create the metadata first.
    /// The config with its window healed, or nil when there is nothing to do.
    /// Creates `modelMetadata` when it is entirely nil, using `.medium`, the tier consumers already substitute for nil.
    /// Only the window is healed; re-picking the model derives the real tier, quantization and family.
    private static func healedConfig(_ config: ProviderConfig, window: Int) -> ProviderConfig? {
        guard config.apiProvider == .mlx else { return nil }
        var healed = config

        if let existing = config.modelMetadata {
            guard existing.contextWindow == nil else { return nil }  // already healed
            healed.modelMetadata?.contextWindow = window
            return healed
        }

        logger.info("[MLX-MIGRATE] Profile had NO model metadata at all (not just a missing window) — creating it with the .medium tier the app already substitutes for nil, so only the context window changes.")
        healed.modelMetadata = ModelMetadata(tier: .medium, contextWindow: window)
        return healed
    }
}
