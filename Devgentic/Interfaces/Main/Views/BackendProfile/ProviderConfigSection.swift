//
//  ProviderConfigSection.swift
//  Devgentic
//
//  Created on 26/03/26.
//
//  Shared provider configuration UI extracted from BotConfigDetailView,
//  AgentConfigDetailView, and ImageGenConfigDetailView.
//  Encapsulates: provider picker, endpoint field, API key field,
//  and dynamic model selection (Ollama, MLX, cloud pickers).
//

import SwiftUI

struct ProviderConfigSection: View {

    // MARK: - Inputs

    @Binding var providerConfig: ProviderConfig
    let profileID: UUID

    /// Profile type drives provider filtering, tool filtering, and capability defaults.
    let profileType: ProfileType

    /// Called when the user switches providers (old, new). Use for capability resets.
    var onProviderChanged: ((_ oldProvider: ApiProvider, _ newProvider: ApiProvider) -> Void)? = nil

    /// Optional custom MLX content (e.g. ImageGen uses Flux2ModelPickerView instead of MLXModelPickerView).
    var customMLXContent: AnyView? = nil

    // MARK: - Internal State

    @State private var isApiKeyVisible: Bool = false
    @State private var isEditingBaseURL: Bool = false

    @Environment(\.appTheme) private var theme

    // MARK: - Computed Helpers

    private var providers: [ApiProvider] {
        ProfileCapabilityFilter.allowedProviders(for: profileType)
    }

    private var baseURLBinding: Binding<String> {
        Binding<String>(
            get: { providerConfig.baseURL ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                providerConfig.baseURL = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerPickerRow

            Divider()

            dynamicFields
        }
        .onChange(of: providerConfig.apiProvider) { _, _ in
            isEditingBaseURL = false
        }
    }

    // MARK: - Provider Picker

    private var providerPickerRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LLM Provider")
                    .fontWeight(.medium)
                Text("The underlying model powering this profile.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 16)

            Picker("", selection: Binding(
                get: { providerConfig.apiProvider },
                set: { newValue in
                    let oldValue = providerConfig.apiProvider
                    providerConfig.apiProvider = newValue
                    if newValue != oldValue {
                        onProviderChanged?(oldValue, newValue)
                    }
                }
            )) {
                ForEach(providers, id: \.self) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: - Dynamic Fields

    @ViewBuilder
    private var dynamicFields: some View {
        switch providerConfig.apiProvider {
        case .ollama:
            ollamaFields
        case .mlx:
            mlxFields
        default:
            remoteFields
        }
    }

    // MARK: - Ollama Fields

    @ViewBuilder
    private var ollamaFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            endpointField

            Divider()

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection")
                        .fontWeight(.medium)
                }
                Spacer(minLength: 16)
                OllamaModelPickerView(
                    selectedModel: $providerConfig.modelName,
                    cognitiveCapability: Binding(
                        get: { providerConfig.cognitiveCapability },
                        set: { providerConfig.cognitiveCapability = $0 }
                    ),
                    modelDialect: Binding(
                        get: { providerConfig.modelDialect },
                        set: { providerConfig.modelDialect = $0 }
                    ),
                    modelMetadata: Binding(
                        get: { providerConfig.modelMetadata },
                        set: { providerConfig.modelMetadata = $0 }
                    ),
                    supportedModalities: Binding(
                        get: { providerConfig.supportedModalities },
                        set: { providerConfig.supportedModalities = $0 }
                    ),
                    thinkingEnabled: Binding(
                        get: { providerConfig.thinkingEnabled },
                        set: { providerConfig.thinkingEnabled = $0 }
                    ),
                    baseURL: providerConfig.baseURL ?? Self.defaultBaseURL(for: .ollama),
                    profileID: profileID,
                    filterForTools: ProfileCapabilityFilter.filterForTools(for: profileType)
                )
                .labelsHidden()
                .frame(maxWidth: 350, alignment: .trailing)
            }
        }
    }

    // MARK: - MLX Fields

    @ViewBuilder
    private var mlxFields: some View {
        if let custom = customMLXContent {
            custom
        } else {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection")
                        .fontWeight(.medium)
                }
                Spacer(minLength: 16)
                MLXModelPickerView(
                    selectedModel: $providerConfig.modelName,
                    cognitiveCapability: Binding(
                        get: { providerConfig.cognitiveCapability },
                        set: { providerConfig.cognitiveCapability = $0 }
                    ),
                    modelDialect: Binding(
                        get: { providerConfig.modelDialect },
                        set: { providerConfig.modelDialect = $0 }
                    ),
                    modelMetadata: Binding(
                        get: { providerConfig.modelMetadata },
                        set: { providerConfig.modelMetadata = $0 }
                    ),
                    supportedModalities: Binding(
                        get: { providerConfig.supportedModalities },
                        set: { providerConfig.supportedModalities = $0 }
                    ),
                    chatTemplateSource: Binding(
                        get: { providerConfig.chatTemplateSource },
                        set: { providerConfig.chatTemplateSource = $0 }
                    ),
                    stopSequences: Binding(
                        get: { providerConfig.stopSequences },
                        set: { providerConfig.stopSequences = $0 }
                    ),
                    profileID: profileID,
                    filterForTools: ProfileCapabilityFilter.filterForTools(for: profileType)
                )
                .labelsHidden()
                .frame(maxWidth: 350, alignment: .trailing)
            }
        }
    }

    // MARK: - Remote Fields (Cloud Providers)

    @ViewBuilder
    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            // API Key
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").fontWeight(.medium)
                }

                Spacer(minLength: 16)

                ZStack(alignment: .trailing) {
                    Group {
                        if isApiKeyVisible {
                            TextField("Enter API Key", text: $providerConfig.apiKey.toNonOptional(defaultValue: ""))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("API key")
                        } else {
                            SecureField("Enter API Key", text: $providerConfig.apiKey.toNonOptional(defaultValue: ""))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("API key")
                        }
                    }

                    Button(action: { isApiKeyVisible.toggle() }) {
                        Image(systemName: isApiKeyVisible ? "eye.slash" : "eye")
                            .foregroundColor(theme.secondaryText)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .help(isApiKeyVisible ? "Hide API Key" : "Show API Key")
                    .accessibilityLabel(isApiKeyVisible ? "Hide API key" : "Show API key")
                }
                .frame(maxWidth: 350)
            }

            Divider()

            endpointField

            Divider()

            // Model Selection (gated by API key)
            let currentApiKey = providerConfig.apiKey ?? ""

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection").fontWeight(.medium)
                }

                Spacer(minLength: 16)

                if currentApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a valid API Key to select a model.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                } else {
                    modelPicker(apiKey: currentApiKey)
                }
            }
        }
    }

    // MARK: - Model Picker (per provider)

    @ViewBuilder
    private func modelPicker(apiKey: String) -> some View {
        switch providerConfig.apiProvider {
        case .google:
            GeminiModelPickerView(
                selectedModel: $providerConfig.modelName,
                apiKey: apiKey
            )
            .labelsHidden()
            .frame(maxWidth: 350, alignment: .trailing)

        case .anthropic:
            AnthropicModelPickerView(
                selectedModel: $providerConfig.modelName,
                apiKey: apiKey
            )
            .labelsHidden()
            .frame(maxWidth: 350, alignment: .trailing)

        case .openAI:
            OpenAIModelPickerView(
                selectedModel: $providerConfig.modelName,
                apiKey: apiKey
            )
            .labelsHidden()
            .frame(maxWidth: 350, alignment: .trailing)

        default:
            TextField("e.g. gpt-4o", text: $providerConfig.modelName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
        }
    }

    // MARK: - Endpoint Field

    private var endpointField: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Endpoint")
                    .fontWeight(.medium)
                Text("Optional override for custom gateways.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 16)

            HStack {
                if isEditingBaseURL || (providerConfig.baseURL != nil && !providerConfig.baseURL!.isEmpty) {
                    TextField(Self.defaultBaseURL(for: providerConfig.apiProvider), text: baseURLBinding)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)

                    Button(action: {
                        providerConfig.baseURL = nil
                        isEditingBaseURL = false
                    }) {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    .help("Reset to default")
                    .accessibilityLabel("Reset to default")
                } else {
                    Text(Self.defaultBaseURL(for: providerConfig.apiProvider))
                        .foregroundColor(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(theme.secondaryBackground.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium))
                        .overlay(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium).stroke(theme.dividerColor, lineWidth: 1))

                    Button("Edit") {
                        isEditingBaseURL = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: 350)
        }
    }

    // MARK: - Static Helpers

    static func defaultBaseURL(for provider: ApiProvider) -> String {
        ProviderDefaults.baseURLString(for: provider)
    }
}
