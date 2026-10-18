// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileCapabilityFilter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Single source of truth for provider and model filtering rules
/// across all profile types (Bot, Agent, ImageGen, Workflow).
struct ProfileCapabilityFilter {

    // MARK: - Remote Models Gate

    /// First-party remote providers (Gemini, OpenAI, Anthropic) hidden by the "Show Remote Models" setting.
    /// Third-party aggregators (OpenRouter, openAICompatible) are not gated and keep their entries in every picker.
    static let remoteModelProviders: Set<ApiProvider> = [.google, .openAI, .anthropic]

    /// Filters a provider list by the remote-models toggle.
    /// `keepingCurrent` re-appends a provider the gate removed when it is the profile's configured value, so an
    /// existing profile's picker never becomes a blank selection.
    static func filteringRemoteModels(
        _ providers: [ApiProvider],
        keepingCurrent current: ApiProvider? = nil
    ) -> [ApiProvider] {
        guard !AppSettings.showRemoteModels else { return providers }
        var filtered = providers.filter { !remoteModelProviders.contains($0) }
        if let current, providers.contains(current), !filtered.contains(current) {
            filtered.append(current)
        }
        return filtered
    }

    /// Default provider for a new image-gen profile: `.openAI`, or a local provider while remote models are hidden.
    /// The local fallback is `.mlx` in a build with on-device image generation, `.ollama` otherwise.
    static var defaultImageGenProvider: ApiProvider {
        if AppSettings.showRemoteModels { return .openAI }
        return MLXImageGenAvailability.isCompiledIn ? .mlx : .ollama
    }

    /// Providers that can generate images in THIS build. Anthropic has no image generation API;
    /// MLX is listed only when on-device generation is compiled in (`MLXImageGenAvailability`).
    static var imageGenProviders: [ApiProvider] {
        MLXImageGenAvailability.isCompiledIn
            ? [.openAI, .google, .mlx, .ollama]
            : [.openAI, .google, .ollama]
    }

    // MARK: - Provider Filtering

    /// Which providers to show in the provider picker for a given profile type.
    /// Filtered by the remote-models gate; pass `keepingCurrent` from a picker that
    /// edits an existing profile so its configured provider stays visible.
    static func allowedProviders(
        for profileType: ProfileType,
        keepingCurrent current: ApiProvider? = nil
    ) -> [ApiProvider] {
        switch profileType {
        case .imageGen:
            // A saved profile still on MLX in a build without on-device generation keeps MLX visible so its picker
            // isn't blank; new selections can't choose it.
            var providers = imageGenProviders
            if current == .mlx, !providers.contains(.mlx) { providers.append(.mlx) }
            return filteringRemoteModels(providers, keepingCurrent: current)
        case .bot, .agent, .workflow, .code:
            return filteringRemoteModels(ApiProvider.allCases.map { $0 }, keepingCurrent: current)
        }
    }

    // MARK: - Cognitive Capability

    /// Default cognitive capability for a selected provider: Agent + cloud → `.parallelActions`,
    /// Agent + local → `.singleAction`, everything else → `.none`.
    static func defaultCognitiveCapability(
        for profileType: ProfileType,
        provider: ApiProvider
    ) -> ModelCognitiveCapability {
        guard profileType == .agent else { return .none }

        switch provider {
        case .openAI, .google, .anthropic, .openRouter, .openAICompatible:
            return .parallelActions
        case .ollama, .mlx:
            return .singleAction
        }
    }

    // MARK: - Model Display

    // Why: capability metadata may label a model row; it never gates or disables selection.
    /// A short, user-facing note about a model's tool support, or `nil` when there is nothing worth saying.
    /// Returns `nil` for non-Agent profiles; a caller with no caveat information passes `.undetected`.
    /// Wording follows the caveat, not the provider: only an authoritative `.none` is stated flatly.
    static func toolCapabilityNote(
        capability: ModelCognitiveCapability,
        caveat: ToolSupportCaveat?,
        profileType: ProfileType
    ) -> String? {
        guard profileType == .agent else { return nil }

        guard capability == .none else {
            // Tool-capable, but the model is a reasoning fine-tune: the server accepts the tools
            // param, so this is a RELIABILITY note, not a protocol one. Still worth surfacing.
            return caveat == .reasoningFocused ? "⚠️ Reasoning-focused" : nil
        }

        switch caveat {
        case .serverRejectsTools:
            // The only case we actually know: the daemon declared no tool support.
            return "🚫 No tools"
        case .reasoningFocused:
            return "⚠️ Reasoning-focused"
        case .undetected, nil:
            return "⚠︎ Tools unconfirmed"
        }
    }
}
