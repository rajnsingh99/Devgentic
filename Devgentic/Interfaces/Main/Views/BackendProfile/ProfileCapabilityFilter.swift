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

    // MARK: - Custom Model Picker

    /// Whether the profile+provider combination requires a custom model picker
    /// instead of the standard one (e.g., ImageGen + MLX uses Flux2ModelPickerView).
    static func requiresCustomModelPicker(
        for profileType: ProfileType,
        provider: ApiProvider
    ) -> Bool {
        profileType == .imageGen && provider == .mlx
    }

    // MARK: - Model Display Helpers

    /// Display label for a model row in the picker.
    /// Appends "(Chat Only)" for Agent profiles when the model lacks tool support.
    static func modelDisplayLabel(
        modelName: String,
        cognitiveCapability: ModelCognitiveCapability,
        profileType: ProfileType
    ) -> String {
        if isModelDisabled(cognitiveCapability: cognitiveCapability, profileType: profileType) {
            return "\(modelName) (Chat Only)"
        }
        return modelName
    }

    /// Whether a model row should be disabled (visible but not selectable) in the picker.
    /// Only Agent profiles disable models that lack tool support.
    static func isModelDisabled(
        cognitiveCapability: ModelCognitiveCapability,
        profileType: ProfileType
    ) -> Bool {
        profileType == .agent && cognitiveCapability == .none
    }
}
