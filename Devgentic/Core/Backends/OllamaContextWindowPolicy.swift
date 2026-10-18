// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaContextWindowPolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Resolves the context window a request will effectively run under, per provider class.
/// The one resolver behind the retrieval budget, the pre-flight fit check and AgentConnect's compaction budgets,
/// so they cannot disagree about how much room a model has.
enum EffectiveContextWindow {

    /// The model's TRAINED maximum, when known (scan metadata, else catalog).
    static func trainedWindow(for config: ProviderConfig?) -> Int? {
        config?.modelMetadata?.contextWindow
            ?? KnownModelContextWindows.lookup(config?.modelName ?? "")
    }

    // Why: profiles never opened in Advanced have no stored config and the factory materialises a preset,
    // so the preset must be read through `flavour` or the gauge disagrees with the request.
    /// The window requests actually get: Ollama `num_ctx` from the request options; MLX trained max (8K if unknown);
    /// cloud trained/catalog (128K if unknown). `flavour` is consulted for Ollama only and is required, not defaulted.
    static func resolve(for config: ProviderConfig?, flavour: OllamaConfigDefaultProfile) -> Int {
        let trained = trainedWindow(for: config)
        switch config?.apiProvider {
        case .ollama:
            // Ask for the options the factory will BUILD, not the ones the profile stored.
            let resolved = OllamaRequestOptions.resolve(
                stored: config?.advancedConfiguration,
                metadata: config?.modelMetadata,
                modelName: config?.modelName ?? "",
                flavour: flavour,
                numCtxOverride: config?.numCtxOverride
            )
            return OllamaContextWindowPolicy.effectiveTokens(
                configuredNumCtx: OllamaContextWindowPolicy.configuredNumCtx(in: resolved.options),
                trainedContextWindow: trained
            )
        case .mlx:
            return max(2_048, trained ?? 8_192)
        default:
            return max(2_048, trained ?? 128_000)
        }
    }
}

enum OllamaContextWindowPolicy {

    /// Ceiling for the auto-default.
    /// KV cache costs real memory (roughly 0.5–1 GB more for a 7B model at 8K), so a 128K-trained model's maximum is
    /// not allocated blindly; users can exceed this via the profile's Advanced settings.
    static let autoDefaultCap = 16_384

    /// What Ollama allocates when no num_ctx reaches it: 2,048 on older servers,
    /// 4,096 on current ones, overridable server-side by OLLAMA_CONTEXT_LENGTH —
    /// and none of it queryable via the API. Assume the current default.
    static let assumedServerDefault = 4_096

    /// The user's explicit numCtx from a profile's advanced configuration
    /// (the Advanced card in Bot/Agent config → `advancedConfiguration["numCtx"]`).
    static func configuredNumCtx(in options: [String: JSONValue]?) -> Int? {
        guard let value = options?["numCtx"] else { return nil }
        if case .number(let double) = value, double > 0 { return Int(double) }
        return nil
    }

    /// The num_ctx to auto-send when the user configured none: the model's
    /// trained maximum, memory-capped. Nil when the trained size is unknown —
    /// then we send nothing rather than guess above the server default.
    static func autoNumCtx(trainedContextWindow: Int?) -> Int? {
        guard let trained = trainedContextWindow, trained > 0 else { return nil }
        return min(trained, autoDefaultCap)
    }

    /// The window the rest of the app should assume a request runs under —
    /// mirrors exactly what the request factory resolves and sends:
    /// user-configured value → auto-default → assumed server default.
    static func effectiveTokens(configuredNumCtx: Int?, trainedContextWindow: Int?) -> Int {
        if let configured = configuredNumCtx { return configured }
        if let auto = autoNumCtx(trainedContextWindow: trainedContextWindow) { return auto }
        return assumedServerDefault
    }
}

// Why: a profile with no stored config runs under its preset's `numCtx`;
// Ollama head-truncates oversized prompts, dropping system rules first.
/// The options an Ollama request will actually carry: the one place that answers it.
/// The fallback ladder lives here; the request factory and the context budgets read the same resolved dictionary.
enum OllamaRequestOptions {

    /// What the factory resolved, and how — so `AgentConnect` can log the same lines it always
    /// did without re-deriving the decision it just delegated.
    struct Resolved {
        /// Exactly what `OllamaLLMProvider` will be constructed with.
        let options: [String: JSONValue]?
        /// Non-nil when no stored configuration existed and the preset ladder supplied one.
        let presetApplied: OllamaConfigDefaultProfile?
        /// Non-nil when the `num_ctx` auto-default had to be merged in on top.
        let autoNumCtx: Int?
        /// Non-nil when `numCtxOverride` decided the window (Code's per-project context size).
        var overrideNumCtx: Int? = nil
    }

    // Why: handing the agent preset to a Bot pins a conversational profile to temperature 0.1 with a fixed seed.
    /// Resolves stored configuration, then preset ladder, then `num_ctx` auto-default, in that order.
    /// `flavour` picks the ladder and is not cosmetic; `EffectiveContextWindow.resolve` takes it too.
    static func resolve(
        stored: [String: JSONValue]?,
        metadata: ModelMetadata?,
        modelName: String,
        flavour: OllamaConfigDefaultProfile,
        numCtxOverride: Int?
    ) -> Resolved {
        var options: [String: JSONValue]?
        var presetApplied: OllamaConfigDefaultProfile?

        if let stored {
            options = stored
        } else {
            // The Advanced panel displays a preset whenever a profile has no stored configuration, so the request carries
            // the same options instead of Ollama's own default sampling.
            let fallback: OllamaAdvancedConfig = metadata.map {
                .recommended(for: $0, profile: flavour)
            } ?? (flavour == .agent ? .default() : .botPreset(for: .smallMedium))

            options = AdvancedConfigEncoder.encode(fallback)
            presetApplied = flavour
        }

        // When nothing above supplied a context window, send one sized to the model instead of Ollama's ~4K default,
        // which head-truncates oversized prompts: min(trained max, cap) keeps KV-cache memory bounded.
        var autoNumCtx: Int?
        if OllamaContextWindowPolicy.configuredNumCtx(in: options) == nil,
           let auto = OllamaContextWindowPolicy.autoNumCtx(
               trainedContextWindow: metadata?.contextWindow ?? KnownModelContextWindows.lookup(modelName)
           ) {
            var merged = options ?? [:]
            merged["numCtx"] = .number(Double(auto))
            options = merged
            autoNumCtx = auto
        }

        // Applied last so it wins over everything above: the user set it for exactly this run's project. Kept in this
        // function so the request and every budget read the same window.
        if let override = numCtxOverride, override > 0 {
            var merged = options ?? [:]
            merged["numCtx"] = .number(Double(override))
            return Resolved(options: merged, presetApplied: presetApplied, autoNumCtx: nil, overrideNumCtx: override)
        }

        return Resolved(options: options, presetApplied: presetApplied, autoNumCtx: autoNumCtx)
    }
}
