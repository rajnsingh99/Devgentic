// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CatalogModelSelection.swift
//  Devgentic
//
//  What picking a model from the catalog writes into a profile's provider config.
//
//  ⚠️ WHY (2026-10-09). The catalog wrote only capability, dialect and modalities. The model's
//  metadata (tier, quantization, family, window), chat-template source and stop sequences were
//  left as they were — the PREVIOUS model's values, or the `.medium` placeholder
//  `MLXContextWindowHealer` creates for a profile with none. A Qwen2.5-3B agent profile was stored
//  as "Medium" tier, and the coordinator, estimating from that tier, refused the run as needing
//  ~20 GB. Saving did not repair it: the catalog never wrote the fields, so there was nothing new
//  to save. Runs looked right only because `LiveModelDetection` re-detects at run start; anything
//  reading the stored copy saw the stale one.
//
//  A pick now replaces every measured field. Nothing measured on the previous model survives.
//

import Foundation

enum CatalogModelSelection {

    /// `config` with `model` picked: its provider and name, and every measurement describing it.
    ///
    /// A local model's measurements come from the analyzer result the catalog entry carries
    /// (`detectedProfile`) — read from the profile's OWN Ollama server or MLX folder, so a
    /// same-named model elsewhere cannot answer for it. A cloud model is not measured: it gets
    /// the catalog's capability, dialect, modalities and window, and no local-only artifacts.
    ///
    /// The endpoint: an MLX model runs in-process, so it has none — a pick clears whatever an
    /// earlier provider left (an MLX profile once stored Ollama's `http://localhost:11434`, shown in
    /// every profile dump though nothing used it). Any other pick takes the user's saved endpoint
    /// for the vendor, else the server the catalog listed the model from, else keeps the current one.
    ///
    /// Key and the provider-switch reset are the caller's.
    static func applying(_ model: CatalogModelItem, to config: ProviderConfig,
                         savedEndpoint: String? = nil) -> ProviderConfig {
        var out = config
        out.apiProvider = model.provider
        out.modelName = model.id
        out.thinkingEnabled = model.isReasoning
        out.baseURL = model.provider == .mlx ? nil : (savedEndpoint ?? model.baseURL ?? config.baseURL)

        if let detected = model.detectedProfile {
            out.cognitiveCapability = detected.capability
            out.modelDialect = detected.dialect
            out.modelMetadata = detected.metadata
            out.supportedModalities = detected.modalities
            out.chatTemplateSource = detected.chatTemplateSource
            out.stopSequences = detected.stopSequences
        } else {
            out.cognitiveCapability = model.cognitiveCapability
            out.modelDialect = model.modelDialect
            out.supportedModalities = model.supportedModalities
            // The tier is the fixed default the app uses for an unmeasured model; only the window
            // is a fact about this one.
            out.modelMetadata = model.contextWindow.map { ModelMetadata(tier: .medium, contextWindow: $0) }
            out.chatTemplateSource = .embedded
            out.stopSequences = []
        }
        return out
    }

    /// One line describing what a pick wrote, for the `[PROFILE]` log.
    static func describe(_ config: ProviderConfig) -> String {
        let meta = config.modelMetadata
        let tier = meta.map { $0.tier.rawValue } ?? "none"
        let window = meta?.contextWindow.map(String.init) ?? "unknown"
        return "endpoint \(config.baseURL ?? "none"), capability \(config.cognitiveCapability.rawValue), dialect \(config.modelDialect.rawValue), "
            + "tier \(tier), quantization \(meta?.quantization ?? "none"), window \(window), "
            + "template \(config.chatTemplateSource), \(config.stopSequences.count) stop sequence(s)"
    }
}
