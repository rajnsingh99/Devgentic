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

    // MARK: - Provider Filtering

    /// Which providers to show in the provider picker for a given profile type.
    static func allowedProviders(for profileType: ProfileType) -> [ApiProvider] {
        switch profileType {
        case .imageGen:
            // Anthropic has no image generation API
            return [.openAI, .google, .mlx, .ollama]
        case .bot, .agent, .workflow, .code:
            return ApiProvider.allCases.map { $0 }
        }
    }

    // MARK: - Model Filtering

    /// Whether model pickers should filter for tool-capable models.
    /// Only Agent profiles require tool support from their models.
    static func filterForTools(for profileType: ProfileType) -> Bool {
        switch profileType {
        case .agent:    return true
        case .bot, .imageGen, .workflow, .code: return false
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
