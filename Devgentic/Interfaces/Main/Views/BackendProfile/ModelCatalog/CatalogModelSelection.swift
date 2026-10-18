// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CatalogModelSelection.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// What picking a model from the catalog writes into a profile's provider config.
/// A pick replaces every measured field (tier, quantization, family, window, template, stop sequences).
enum CatalogModelSelection {

    /// Returns `config` with `model` applied: its provider, name and every measurement describing it.
    /// Local measurements come from the entry's `detectedProfile`; cloud models are not measured.
    /// An MLX pick clears the endpoint; other picks take the saved vendor endpoint, else the catalog's, else the current.
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
