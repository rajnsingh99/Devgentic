// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileCapabilityFilter.swift
//  Devgentic
//
//  Created on 30/03/26.
//
//  Single source of truth for provider and model filtering rules
//  across all profile types (Bot, Agent, ImageGen, Workflow).
//  Replaces scattered hardcoded `allowedProviders`, `filterForTools`,
//  and `onProviderChanged` logic in individual detail views.
//

import Foundation

struct ProfileCapabilityFilter {

    // MARK: - Remote Models Gate

    /// First-party remote providers hidden by the General Settings "Show Remote
    /// Models" toggle (`AppSettings.showRemoteModelsKey`). Deliberately exactly
    /// Gemini, OpenAI, and Anthropic — the owner's decision (2026-09-26) does not
    /// gate the third-party remote aggregators (OpenRouter, openAICompatible), which
    /// keep their own entries in every picker.
    static let remoteModelProviders: Set<ApiProvider> = [.google, .openAI, .anthropic]

    /// Filters a provider list by the remote-models toggle. `keepingCurrent` re-appends
    /// a provider the gate removed when it is the profile's CONFIGURED value: hiding a
    /// provider must not turn an existing profile's picker into a blank selection — the
    /// configured value stays visible (and runnable) until the user actively switches
    /// away. New selections are limited to the visible list.
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

    /// Default provider for a NEW image-gen profile. Historically `.openAI`; falls
    /// back to a local provider while remote models are hidden, so a fresh profile doesn't open
    /// on a provider the toggle just removed from every picker (the picker would show
    /// it via `keepingCurrent`, defeating the feature on first sight). The local fallback is
    /// `.mlx` only in a build that includes on-device image generation, `.ollama` otherwise.
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
            // A saved profile still on MLX in a build without on-device generation keeps MLX
            // visible so its picker isn't blank; the editor explains why it can't run and the
            // factory refuses it with the same message. New selections can't choose it.
            var providers = imageGenProviders
            if current == .mlx, !providers.contains(.mlx) { providers.append(.mlx) }
            return filteringRemoteModels(providers, keepingCurrent: current)
        case .bot, .agent, .workflow, .code:
            return filteringRemoteModels(ApiProvider.allCases.map { $0 }, keepingCurrent: current)
        }
    }

    // MARK: - Cognitive Capability

    /// Default cognitive capability to assign when a provider is selected.
    /// - Agent + cloud providers → `.parallelActions` (native structured output)
    /// - Agent + local providers → `.singleAction` (single-tool dispatch)
    /// - Everything else → `.none` (no tool routing needed)
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

    /// A short, user-facing note about a model's tool support — or `nil` when there is nothing
    /// worth saying. Pickers append this to the row; it is the ONLY thing a capability verdict is
    /// allowed to do to a model row.
    ///
    /// ⚠️ This replaced two helpers that had zero callers for months (register G95):
    /// `modelDisplayLabel`, and `isModelDisabled` — whose own documentation described making a row
    /// *"visible but not selectable"*. That is a GATE, so adopting it would have spread a violation
    /// of the project rule (capability metadata may LABEL or GROUP, never gate) into three more
    /// pickers instead of removing one. It is deleted rather than reused. `requiresCustomModelPicker`
    /// went with it: the need is real but is met by injecting the custom picker as content
    /// (`ProviderConfigSection` → `ImageGenConfigDetailView`'s `Flux2ModelPickerView`), not by asking
    /// a predicate.
    ///
    /// ⚠️ **Wording is chosen by the CAVEAT, not by the provider.** How much a `.none` verdict can be
    /// trusted varies *within* a provider, so per-provider copy would be wrong roughly half the time:
    /// Ollama produces `.none` from the daemon's capabilities array (authoritative — a tools request
    /// really will 400), from a reasoning-only NAME match, and from having no capabilities field at
    /// all. Only the first deserves a flat "No tools"; saying that for a name guess trains the user to
    /// ignore the note, and hedging on a protocol fact understates a true negative.
    ///
    /// A caller with no caveat information at all should pass `.undetected` — that is precisely what
    /// it means, and it yields the hedged wording. OpenRouter is the case in point: its
    /// `toolCapable` flag reads `?? false`, so a model with no `supported_parameters` metadata is
    /// indistinguishable from one that declares no tool support, and only the hedge is honest.
    ///
    /// - Returns: `nil` for non-Agent profiles — a Bot never dispatches tools, so the note is noise.
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
