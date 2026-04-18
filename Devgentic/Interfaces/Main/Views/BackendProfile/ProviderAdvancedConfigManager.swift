//
//  ProviderAdvancedConfigManager.swift
//  Devgentic
//
//  Shared provider-specific advanced config management used by
//  BotConfigDetailView and AgentConfigDetailView.
//

import SwiftUI

// MARK: - Config Manager

/// Holds the 5 provider-specific local configs and manages the load/sync lifecycle.
/// Replaces the duplicated @State variables and onChange handlers in Bot/Agent detail views.
@Observable @MainActor
final class ProviderAdvancedConfigManager {
    var localOllamaConfig: OllamaAdvancedConfig = .default()
    var localGeminiConfig: GeminiAdvancedConfig = .default()
    var localAnthropicConfig: AnthropicAdvancedConfig = .default()
    var localOpenAIConfig: OpenAIAdvancedConfig = .default()
    var localMlxConfig: MLXAdvancedConfig = .default()

    /// Guard flag: prevents onChange handlers from writing back during initial load.
    var isLoading = false

    /// Decodes the provider config's `advancedConfiguration` dictionary into the correct local config.
    func load(from providerConfig: ProviderConfig, using profileService: BackendProfileService) {
        isLoading = true
        switch providerConfig.apiProvider {
        case .ollama:
            localOllamaConfig = profileService.decodeConfig(
                from: providerConfig.advancedConfiguration,
                as: OllamaAdvancedConfig.self
            ) ?? .default()
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
        case .mlx:
            localMlxConfig = profileService.decodeConfig(
                from: providerConfig.advancedConfiguration,
                as: MLXAdvancedConfig.self
            ) ?? {
                if let metadata = providerConfig.modelMetadata {
                    return .recommended(for: metadata)
                }
                return .default()
            }()
        }
        isLoading = false
    }

    /// Encodes the current local config for the given provider back to the profile dictionary.
    /// Returns `nil` when `isLoading` is true (callers should skip the write).
    func encode(for provider: ApiProvider, using profileService: BackendProfileService) -> [String: JSONValue]? {
        guard !isLoading else { return nil }
        switch provider {
        case .ollama:   return profileService.encodeConfig(from: localOllamaConfig)
        case .google:   return profileService.encodeConfig(from: localGeminiConfig)
        case .anthropic: return profileService.encodeConfig(from: localAnthropicConfig)
        case .openAI:   return profileService.encodeConfig(from: localOpenAIConfig)
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
            .onChange(of: configManager.localOllamaConfig) { _, _ in
                guard let encoded = configManager.encode(for: .ollama, using: profileService),
                      providerConfig.wrappedValue.apiProvider == .ollama else { return }
                providerConfig.wrappedValue.advancedConfiguration = encoded
            }
            .onChange(of: configManager.localGeminiConfig) { _, _ in
                guard let encoded = configManager.encode(for: .google, using: profileService),
                      providerConfig.wrappedValue.apiProvider == .google else { return }
                providerConfig.wrappedValue.advancedConfiguration = encoded
            }
            .onChange(of: configManager.localAnthropicConfig) { _, _ in
                guard let encoded = configManager.encode(for: .anthropic, using: profileService),
                      providerConfig.wrappedValue.apiProvider == .anthropic else { return }
                providerConfig.wrappedValue.advancedConfiguration = encoded
            }
            .onChange(of: configManager.localOpenAIConfig) { _, _ in
                guard let encoded = configManager.encode(for: .openAI, using: profileService),
                      providerConfig.wrappedValue.apiProvider == .openAI else { return }
                providerConfig.wrappedValue.advancedConfiguration = encoded
            }
            .onChange(of: configManager.localMlxConfig) { _, _ in
                guard let encoded = configManager.encode(for: .mlx, using: profileService),
                      providerConfig.wrappedValue.apiProvider == .mlx else { return }
                providerConfig.wrappedValue.advancedConfiguration = encoded
            }
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

/// Switches on the provider to render the correct settings view bound to the config manager.
struct ProviderAdvancedSettingsView: View {
    @Bindable var configManager: ProviderAdvancedConfigManager
    let provider: ApiProvider
    @Binding var thinkingEnabled: Bool

    var body: some View {
        switch provider {
        case .ollama:
            OllamaSettingsView(config: $configManager.localOllamaConfig, thinkingEnabled: $thinkingEnabled)
        case .google:
            GeminiSettingsView(config: $configManager.localGeminiConfig)
        case .anthropic:
            AnthropicSettingsView(config: $configManager.localAnthropicConfig)
        case .openAI:
            OpenAISettingsView(config: $configManager.localOpenAIConfig)
        case .mlx:
            MLXSettingsView(config: $configManager.localMlxConfig)
        }
    }
}
