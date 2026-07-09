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
    /// OpenRouter reuses the OpenAI parameter surface but keeps its own instance
    /// so edits on one provider never bleed into the other's saved config.
    var localOpenRouterConfig: OpenAIAdvancedConfig = .default()
    /// Custom OpenAI-compatible endpoints reuse the OpenAI parameter surface too,
    /// with their own instance for the same isolation reason.
    var localOpenAICompatibleConfig: OpenAIAdvancedConfig = .default()
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
            .onChange(of: configManager.localOpenRouterConfig) { _, _ in
                guard let encoded = configManager.encode(for: .openRouter, using: profileService),
                      providerConfig.wrappedValue.apiProvider == .openRouter else { return }
                providerConfig.wrappedValue.advancedConfiguration = encoded
            }
            .onChange(of: configManager.localOpenAICompatibleConfig) { _, _ in
                guard let encoded = configManager.encode(for: .openAICompatible, using: profileService),
                      providerConfig.wrappedValue.apiProvider == .openAICompatible else { return }
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
///
/// `modelMetadata` is optional and threaded through to provider-specific settings
/// views that derive parameter bounds from model characteristics (currently only
/// MLX uses it; cloud and Ollama settings rely on provider-defined ranges).
struct ProviderAdvancedSettingsView: View {
    @Bindable var configManager: ProviderAdvancedConfigManager
    let provider: ApiProvider
    @Binding var thinkingEnabled: Bool
    /// Active model metadata (context window, tier, quantization, family) used by
    /// MLX and Ollama settings to derive bounds for token-count fields.
    /// Default-nil so callers that don't have the value handy stay compiling.
    let modelMetadata: ModelMetadata?
    /// Active model name. Used as a secondary fallback to
    /// `KnownModelContextWindows.lookup` when `modelMetadata.contextWindow` is
    /// nil — common for Ollama profiles where `/api/show.details` populates
    /// tier/quant but not the context window itself.
    let modelName: String?
    /// Whether this view is hosted in an Agent or Bot config. Drives which
    /// "Apply Optimal" preset the Ollama view uses (strict agent vs warm chat).
    /// No default — every callsite must specify so a Bot profile never silently
    /// inherits agent-strict defaults from a forgotten parameter.
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
            AnthropicSettingsView(config: $configManager.localAnthropicConfig)
        case .openAI:
            OpenAISettingsView(config: $configManager.localOpenAIConfig)
        case .openRouter:
            OpenAISettingsView(config: $configManager.localOpenRouterConfig)
        case .openAICompatible:
            OpenAISettingsView(config: $configManager.localOpenAICompatibleConfig)
        case .mlx:
            MLXSettingsView(
                config: $configManager.localMlxConfig,
                modelMetadata: modelMetadata,
                modelName: modelName
            )
        }
    }
}
