//
//  MLXContextWindowHealer.swift
//  Devgentic
//
//  Heals MLX profiles saved BEFORE the trained context window was read from config.json.
//  Their persisted `modelMetadata.contextWindow` is nil, so the context gauge and every
//  window-derived budget (compaction / RAG / native-turn) fall back to the conservative
//  8K guess — the "why is my 131K model showing 8K?" case.
//
//  MLX metadata is derived once at model-pick time and then frozen in the saved profile;
//  there's no re-derivation on load. Rather than force a manual re-pick, this looks the
//  real window up from the on-disk model (via MLXModelService, which rescans at launch and
//  already includes the config.json read) and — once per profile per session — writes it
//  back into the profile so the budgets stop using 8K too.
//

import Foundation
import os

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

    /// Writes the healed window into the persisted profile so compaction / RAG / native-turn
    /// budgets (which read the stored metadata, not the gauge) also stop using the 8K
    /// fallback. Re-running is a no-op. Best-effort: a failure still leaves the gauge correct
    /// for the session (the lookup above is independent), and the backfill retries next launch.
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

    /// The config with its window healed, or nil when there is nothing to do.
    ///
    /// ⚠️ `modelMetadata` can be entirely nil, not merely missing its window. The previous
    /// guard was `modelMetadata?.contextWindow == nil`, which is ALSO true in that case — so
    /// the optional-chained assignment silently did nothing while `saveProfile` still ran and
    /// logged success. Those profiles were therefore never healed, while a sibling profile on
    /// the same model that happened to have metadata was: a permanent 8K-vs-real divergence,
    /// with a log line claiming the opposite.
    ///
    /// Creating the metadata uses `.medium`, which is exactly what every tier consumer already
    /// substitutes for nil (`AgentConnect`: `modelMetadata?.tier ?? .medium`), so nothing that
    /// depends on tier changes behaviour — only the window is healed. Re-picking the model
    /// derives the real tier, quantization and family.
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
