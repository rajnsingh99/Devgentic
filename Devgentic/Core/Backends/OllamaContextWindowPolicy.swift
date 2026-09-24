// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaContextWindowPolicy.swift
//  Devgentic
//
//  Created on 12/07/26.
//
//  Single source of truth for the context window Ollama requests actually run
//  under. Ollama allocates `num_ctx` tokens of KV cache per request — NOT the
//  model's trained maximum. When no num_ctx is sent (and none is baked into the
//  Modelfile), the server default (~4K) applies, and oversized prompts are
//  silently HEAD-truncated — system prompt first — with no client-visible
//  signal. Used by BOTH the request factory (what we send) and the retrieval
//  budget (what we assume), so the two can never disagree.
//
//  ⚠️ That claim was FALSE until 2026-09-20 — see `OllamaRequestOptions` at the
//  foot of this file for how the preset ladder let them disagree by 2x, and why
//  the ladder now lives here rather than in `AgentConnect`.
//

import Foundation

/// Resolves the context window a request will EFFECTIVELY run under, per
/// provider class — the ONE resolver behind the retrieval budget, the pre-flight
/// fit check, and AgentConnect's memory/compaction + native-turn budgets, so
/// they can never disagree about how much room a model actually has.
/// (Before this, compaction budgets assumed 128K for ANY model missing metadata —
/// including local ones whose real allocation was Ollama's ~4K default, so
/// native turn arrays never compacted and Ollama silently truncated mid-run.)
enum EffectiveContextWindow {

    /// The model's TRAINED maximum, when known (scan metadata, else catalog).
    static func trainedWindow(for config: ProviderConfig?) -> Int? {
        config?.modelMetadata?.contextWindow
            ?? KnownModelContextWindows.lookup(config?.modelName ?? "")
    }

    /// The window requests actually get: Ollama → the `num_ctx` in the options the
    /// request factory will send; MLX → trained max (the app owns the prompt),
    /// conservative 8K when unknown; cloud → trained/catalog, 128K when unknown
    /// (overflow errors loudly there anyway).
    ///
    /// ⚠️⚠️ `flavour` is consulted for Ollama ONLY, and it is required rather than
    /// defaulted on purpose. This function used to read `config.advancedConfiguration`
    /// directly — which is nil for every profile whose Advanced panel was never opened,
    /// i.e. the normal case — and so never saw the PRESET the factory materialises in
    /// its place. The gauge read 16384 while the request ran at 8192. A default value
    /// here would have let a caller keep skipping the question silently; making it
    /// required is what forces each call site to say which ladder its profile is on.
    static func resolve(for config: ProviderConfig?, flavour: OllamaConfigDefaultProfile) -> Int {
        let trained = trainedWindow(for: config)
        switch config?.apiProvider {
        case .ollama:
            // Ask for the options the factory will BUILD, not the ones the profile stored.
            let resolved = OllamaRequestOptions.resolve(
                stored: config?.advancedConfiguration,
                metadata: config?.modelMetadata,
                modelName: config?.modelName ?? "",
                flavour: flavour
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

    /// Ceiling for the auto-default. KV cache costs real memory (roughly another
    /// 0.5–1 GB for a 7B model at 8K), so we don't blindly allocate a
    /// 128K-trained model's maximum; users can exceed this deliberately via the
    /// profile's Advanced settings.
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

/// The options an Ollama request will ACTUALLY carry — the one place that answers it.
///
/// ⚠️⚠️ WHY THIS EXISTS. `OllamaContextWindowPolicy` above claims the request factory and the
/// budgets "can never disagree", and for five weeks they did. The factory resolves a profile
/// with no stored advanced configuration to the PRESET the Advanced panel displays, and every
/// preset carries its own `numCtx` — 8192 for a small/medium model. `EffectiveContextWindow`
/// asked the policy about `advancedConfiguration`, which is nil in exactly that case, so it fell
/// through to the auto-default and answered 16384.
///
/// Field-observed 2026-09-20 on a Code session: the gauge read `~2471/16384 tok (24%)` while the
/// request ran under `numCtx: 8192`. The direction is the harmful one — Ollama HEAD-truncates an
/// oversized prompt, system instructions first, so the workspace-boundary rules and the
/// termination contract are the first things dropped, and the model then "deviates" for reasons
/// no log explains.
///
/// The fix is not another resolver. It is that the fallback ladder lives HERE, and both the
/// factory and the budgets read the same resolved dictionary.
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
    }

    /// Resolves stored configuration → preset ladder → `num_ctx` auto-default, in that order.
    ///
    /// ⚠️ `flavour` picks the ladder and is NOT cosmetic: `OllamaAdvancedConfig.default()` is the
    /// AGENT preset, and handing it to a Bot pins a conversational profile to temperature 0.1
    /// with a fixed seed, so every repeated prompt returns a byte-identical reply.
    ///
    /// The two ladders happen to agree on `numCtx` at every tier today, which is exactly why the
    /// original defect stayed invisible — nothing downstream could be wrong about the window by
    /// picking the other ladder. `EffectiveContextWindow.resolve` now takes the flavour too, so a
    /// future divergence stays correct instead of quietly reintroducing the 2x gap.
    static func resolve(
        stored: [String: JSONValue]?,
        metadata: ModelMetadata?,
        modelName: String,
        flavour: OllamaConfigDefaultProfile
    ) -> Resolved {
        var options: [String: JSONValue]?
        var presetApplied: OllamaConfigDefaultProfile?

        if let stored {
            options = stored
        } else {
            // [advanced-config default] The Advanced panel DISPLAYS a preset whenever a profile
            // has no stored configuration. Nothing persisted it, so the request used to carry no
            // options at all and Ollama ran at its own ~0.8 default with random sampling: the
            // agent produced exactly the loose, non-deterministic tool calls the preset exists to
            // prevent, while the UI insisted it was at 0.10.
            let fallback: OllamaAdvancedConfig = metadata.map {
                .recommended(for: $0, profile: flavour)
            } ?? (flavour == .agent ? .default() : .botPreset(for: .smallMedium))

            options = AdvancedConfigEncoder.encode(fallback)
            presetApplied = flavour
        }

        // [num_ctx auto-default] When nothing above supplied a context window, send one sized to
        // the model instead of inheriting Ollama's ~4K server default — which silently
        // HEAD-truncates oversized prompts. min(trained max, cap) keeps KV-cache memory bounded;
        // the value flows through the provider's existing numCtx → num_ctx mapping.
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

        return Resolved(options: options, presetApplied: presetApplied, autoNumCtx: autoNumCtx)
    }
}
