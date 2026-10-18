// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderAdvancedConfigManager.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

private let logger = DGLogger(category: "AdvancedConfigSync")

// MARK: - Config Manager

/// Holds the provider-specific local configs and manages their load/sync lifecycle.
@Observable @MainActor
final class ProviderAdvancedConfigManager {
    var localOllamaConfig: OllamaAdvancedConfig = .default()
    var localGeminiConfig: GeminiAdvancedConfig = .default()
    var localAnthropicConfig: AnthropicAdvancedConfig = .default()
    var localOpenAIConfig: OpenAIAdvancedConfig = .default()
    /// OpenRouter reuses the OpenAI parameter surface but keeps its own instance
    /// so edits on one provider never bleed into the other's saved config.
    var localOpenRouterConfig: OpenAIAdvancedConfig = .default()
    /// Custom OpenAI-compatible endpoints reuse the OpenAI parameter surface too,
    /// with their own instance for the same isolation reason.
    var localOpenAICompatibleConfig: OpenAIAdvancedConfig = .default()
    var localMlxConfig: MLXAdvancedConfig = .default()

    // Why: compared, not raced: `.onChange` runs a pass after `load`, so a synchronous flag cannot suppress the
    // echo.
    /// The exact dictionary `load` most recently produced, per provider.
    @ObservationIgnored private var loadedBaselines: [ApiProvider: [String: JSONValue]] = [:]

    // Why: Ollama `default()` is the strict agent ladder (temp 0.1, seed 42): wrong for a Bot with no stored
    // config.
    /// Decodes the provider config's `advancedConfiguration` dictionary into the correct local config.
    /// - Parameter defaultProfile: whether this panel is hosted in an Agent or a Bot config.
    func load(
        from providerConfig: ProviderConfig,
        using profileService: BackendProfileService,
        defaultProfile: OllamaConfigDefaultProfile = .agent
    ) {
        switch providerConfig.apiProvider {
        case .ollama:
            localOllamaConfig = profileService.decodeConfig(
                from: providerConfig.advancedConfiguration,
                as: OllamaAdvancedConfig.self
            ) ?? Self.ollamaFallback(for: providerConfig, defaultProfile: defaultProfile)
        case .google:
            localGeminiConfig = profileService.decodeConfig(
                from: providerConfig.advancedConfiguration,
                as: GeminiAdvancedConfig.self
            ) ?? .default()
        case .anthropic:
            localAnthropicConfig = profileService.decodeConfig(
                from: providerConfig.advancedConfiguration,
                as: AnthropicAdvancedConfig.self
            ) ?? .default()
        case .openAI:
            localOpenAIConfig = profileService.decodeConfig(
                from: providerConfig.advancedConfiguration,
                as: OpenAIAdvancedConfig.self
            ) ?? .default()
        case .openRouter:
            localOpenRouterConfig = profileService.decodeConfig(
                from: providerConfig.advancedConfiguration,
                as: OpenAIAdvancedConfig.self
            ) ?? .default()
        case .openAICompatible:
            localOpenAICompatibleConfig = profileService.decodeConfig(
                from: providerConfig.advancedConfiguration,
                as: OpenAIAdvancedConfig.self
            ) ?? .default()
        case .mlx:
            localMlxConfig = profileService.decodeConfig(
                from: providerConfig.advancedConfiguration,
                as: MLXAdvancedConfig.self
            ) ?? {
                if let metadata = providerConfig.modelMetadata {
                    return .recommended(for: metadata, profile: defaultProfile)
                }
                return .default()
            }()
        }

        // Record what this load produced so a deferred `.onChange` can tell "SwiftUI is echoing
        // the value I just assigned" from "the user moved a slider".
        loadedBaselines[providerConfig.apiProvider] = encodeCurrent(
            for: providerConfig.apiProvider, using: profileService)
    }

    /// The Ollama preset shown when a profile has no stored advanced configuration.
    /// Uses the selected model's tier when known, matching `OllamaSettingsView`'s own presets.
    private static func ollamaFallback(
        for providerConfig: ProviderConfig,
        defaultProfile: OllamaConfigDefaultProfile
    ) -> OllamaAdvancedConfig {
        if let metadata = providerConfig.modelMetadata {
            return .recommended(for: metadata, profile: defaultProfile)
        }
        return defaultProfile == .agent ? .default() : .botPreset(for: .smallMedium)
    }

    /// Encodes the current local config for the given provider back to the profile dictionary.
    /// Returns `nil` when the value is byte-identical to what `load` last produced, i.e. the change is `load` echoing
    /// back, not a user edit. Callers skip the write on nil.
    func encode(for provider: ApiProvider, using profileService: BackendProfileService) -> [String: JSONValue]? {
        guard let encoded = encodeCurrent(for: provider, using: profileService) else { return nil }
        if let baseline = loadedBaselines[provider], baseline == encoded { return nil }
        // From here on this provider's panel is user-owned; a later echo of the same value is a
        // real (if redundant) edit, not the load.
        loadedBaselines[provider] = encoded
        return encoded
    }

    /// Encodes whichever local config belongs to `provider`, with no baseline comparison.
    private func encodeCurrent(for provider: ApiProvider, using profileService: BackendProfileService) -> [String: JSONValue]? {
        switch provider {
        case .ollama:   return profileService.encodeConfig(from: localOllamaConfig)
        case .google:   return profileService.encodeConfig(from: localGeminiConfig)
        case .anthropic: return profileService.encodeConfig(from: localAnthropicConfig)
        case .openAI:   return profileService.encodeConfig(from: localOpenAIConfig)
        case .openRouter: return profileService.encodeConfig(from: localOpenRouterConfig)
        case .openAICompatible: return profileService.encodeConfig(from: localOpenAICompatibleConfig)
        case .mlx:      return profileService.encodeConfig(from: localMlxConfig)
        }
    }
}

// MARK: - Sync ViewModifier

/// Attaches all 5 `.onChange(of:)` handlers that sync local config edits back to providerConfig.
struct AdvancedConfigSyncModifier: ViewModifier {
    @Bindable var configManager: ProviderAdvancedConfigManager
    var providerConfig: Binding<ProviderConfig>
    var profileService: BackendProfileService

    func body(content: Content) -> some View {
        content
            .onChange(of: configManager.localOllamaConfig) { _, _ in sync(.ollama) }
            .onChange(of: configManager.localGeminiConfig) { _, _ in sync(.google) }
            .onChange(of: configManager.localAnthropicConfig) { _, _ in sync(.anthropic) }
            .onChange(of: configManager.localOpenAIConfig) { _, _ in sync(.openAI) }
            .onChange(of: configManager.localOpenRouterConfig) { _, _ in sync(.openRouter) }
            .onChange(of: configManager.localOpenAICompatibleConfig) { _, _ in sync(.openAICompatible) }
            .onChange(of: configManager.localMlxConfig) { _, _ in sync(.mlx) }
    }

    // Why: the discard must be logged, never silent: a provider switch in the same view pass otherwise loses the
    // edit unseen.
    /// Writes one provider panel's edit back to the profile, or says why it did not.
    /// Discards the edit when the active provider differs, since `advancedConfiguration` holds only that provider's
    /// dictionary.
    private func sync(_ provider: ApiProvider) {
        let activeProvider = providerConfig.wrappedValue.apiProvider

        // Checked before `encode`, which advances `loadedBaselines[provider]` when it returns a value: a mismatched edit
        // must not move the baseline for a write that never happened.
        guard activeProvider == provider else {
            logger.notice(
                "[PROFILE] Advanced-config edit for \(provider.rawValue) arrived while the profile "
                + "is set to \(activeProvider.rawValue). CONSEQUENCE: the edit is DISCARDED — a "
                + "profile stores only the active provider's parameters — and switching back "
                + "reloads from disk, so it cannot be recovered."
            )
            return
        }

        // nil here is the ordinary case: the change is `load()` echoing its assignment back. A genuine encode failure is
        // logged inside `BackendProfileService.encodeConfig`.
        guard let encoded = configManager.encode(for: provider, using: profileService) else { return }

        providerConfig.wrappedValue.advancedConfiguration = encoded
    }
}

extension View {
    func advancedConfigSync(
        configManager: ProviderAdvancedConfigManager,
        providerConfig: Binding<ProviderConfig>,
        profileService: BackendProfileService
    ) -> some View {
        modifier(AdvancedConfigSyncModifier(
            configManager: configManager,
            providerConfig: providerConfig,
            profileService: profileService
        ))
    }
}

// MARK: - Settings View

/// Switches on the provider to render the matching settings view bound to the config manager.
/// `modelMetadata` is optional and threaded to views that derive parameter bounds from model characteristics
/// (currently MLX).
struct ProviderAdvancedSettingsView: View {
    @Bindable var configManager: ProviderAdvancedConfigManager
    let provider: ApiProvider
    @Binding var thinkingEnabled: Bool
    /// Active model metadata (context window, tier, quantization, family) used by
    /// MLX and Ollama settings to derive bounds for token-count fields.
    /// Default-nil so callers that don't have the value handy stay compiling.
    let modelMetadata: ModelMetadata?
    /// Active model name; secondary fallback to `KnownModelContextWindows.lookup` when `modelMetadata.contextWindow` is
    /// nil, common for Ollama profiles, where `/api/show.details` fills tier and quant but not the window.
    let modelName: String?
    /// Whether this view is hosted in an Agent or Bot config; picks the Ollama "Apply Optimal" preset (strict agent vs
    /// warm chat). No default, so a Bot profile never inherits agent-strict defaults from a forgotten parameter.
    let defaultProfile: OllamaConfigDefaultProfile

    init(
        configManager: ProviderAdvancedConfigManager,
        provider: ApiProvider,
        thinkingEnabled: Binding<Bool>,
        modelMetadata: ModelMetadata? = nil,
        modelName: String? = nil,
        defaultProfile: OllamaConfigDefaultProfile
    ) {
        self.configManager = configManager
        self.provider = provider
        self._thinkingEnabled = thinkingEnabled
        self.modelMetadata = modelMetadata
        self.modelName = modelName
        self.defaultProfile = defaultProfile
    }

    var body: some View {
        switch provider {
        case .ollama:
            OllamaSettingsView(
                config: $configManager.localOllamaConfig,
                thinkingEnabled: $thinkingEnabled,
                modelMetadata: modelMetadata,
                modelName: modelName,
                defaultProfile: defaultProfile
            )
        case .google:
            GeminiSettingsView(config: $configManager.localGeminiConfig)
        case .anthropic:
            // `modelName` is load-bearing here, not decorative: it selects which controls the
            // panel may show at all (see `AnthropicModelGeneration`).
            AnthropicSettingsView(config: $configManager.localAnthropicConfig, modelName: modelName)
        case .openAI:
            OpenAISettingsView(config: $configManager.localOpenAIConfig, modelName: modelName ?? "")
        case .openRouter:
            OpenAISettingsView(config: $configManager.localOpenRouterConfig, modelName: modelName ?? "", showsOpenRouterRouting: true)
        case .openAICompatible:
            OpenAISettingsView(config: $configManager.localOpenAICompatibleConfig, modelName: modelName ?? "")
        case .mlx:
            MLXSettingsView(
                config: $configManager.localMlxConfig,
                modelMetadata: modelMetadata,
                modelName: modelName,
                defaultProfile: defaultProfile
            )
        }
    }
}
