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
    /// fallback. Guarded to only touch MLX configs that are actually missing the window, so
    /// re-running is a no-op. Best-effort: a failure still leaves the gauge correct for the
    /// session (the lookup above is independent), and the backfill retries next launch.
    private static func persistBackfill(window: Int, profileID: UUID, modelName: String) {
        do {
            guard var snapshot = try BackendProfileStore.shared.fetchProfile(byId: profileID) else { return }
            switch snapshot.details {
            case .bot(var cfg) where cfg.llmConfig.apiProvider == .mlx && cfg.llmConfig.modelMetadata?.contextWindow == nil:
                cfg.llmConfig.modelMetadata?.contextWindow = window
                snapshot.details = .bot(cfg)
            case .agent(var cfg) where cfg.llmConfig.apiProvider == .mlx && cfg.llmConfig.modelMetadata?.contextWindow == nil:
                cfg.llmConfig.modelMetadata?.contextWindow = window
                snapshot.details = .agent(cfg)
            case .code(var cfg) where cfg.llmConfig.apiProvider == .mlx && cfg.llmConfig.modelMetadata?.contextWindow == nil:
                cfg.llmConfig.modelMetadata?.contextWindow = window
                snapshot.details = .code(cfg)
            default:
                // Window already present, metadata absent, or a non-MLX detail — nothing to persist.
                return
            }
            try BackendProfileStore.shared.saveProfile(snapshot)
            logger.info("[MLX-MIGRATE] Backfilled context window \(window) into MLX profile \(profileID.uuidString.prefix(8)) (\(modelName)) — gauge + compaction/RAG/native-turn budgets now use the real window instead of the 8K fallback.")
        } catch {
            logger.warning("[MLX-MIGRATE] Failed to persist backfilled context window \(window) for profile \(profileID.uuidString.prefix(8)) (\(modelName)): \(error.localizedDescription) — gauge still shows the real window this session; budgets heal on the next successful save.")
        }
    }
}
