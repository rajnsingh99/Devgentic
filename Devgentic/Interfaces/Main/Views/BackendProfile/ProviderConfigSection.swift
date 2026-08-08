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
                    guard newValue != oldValue else { return }
                    providerConfig.switchProvider(to: newValue)
                    onProviderChanged?(oldValue, newValue)
                }
            )) {
                ForEach(providers, id: \.self) { provider in
                    // Label localizes; the `.tag` keeps the enum value itself (selection identity).
                    Text(provider.localizedTitle).tag(provider)
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
        case .openAICompatible:
            openAICompatibleFields
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
            apiKeyField()

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

    // MARK: - OpenAI-Compatible Fields (custom endpoint)

    /// Layout for a user-supplied OpenAI-compatible endpoint: the base URL is
    /// REQUIRED and leads; the API key is OPTIONAL; model discovery is gated on
    /// the base URL (not the key), since local servers usually need no key.
    @ViewBuilder
    private var openAICompatibleFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            endpointField

            Divider()

            apiKeyField(labelSuffix: " (Optional)")

            Divider()

            let currentBaseURL = providerConfig.baseURL ?? ""

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection").fontWeight(.medium)
                    Text("Load the endpoint's models, or type the id.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer(minLength: 16)

                if currentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter the API Endpoint above first.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                } else {
                    OpenAICompatibleModelPickerView(
                        selectedModel: $providerConfig.modelName,
                        baseURL: currentBaseURL,
                        apiKey: providerConfig.apiKey ?? ""
                    )
                    .frame(maxWidth: 350, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - API Key Field (shared)

    /// The API-key row shared by cloud providers and the OpenAI-compatible
    /// endpoint. `labelSuffix` lets the compatible case mark the field optional.
    @ViewBuilder
    private func apiKeyField(labelSuffix: String = "") -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key\(labelSuffix)").fontWeight(.medium)
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
    }

    // MARK: - Model Picker (per provider)

    /// The profile's configured API Endpoint as a URL, or nil when unset/unparseable.
    ///
    /// ⚠️ Returns nil rather than a fallback so each service applies its OWN `ProviderDefaults`
    /// value — one resolver here would have to know four vendor defaults and would drift from them.
    /// An unparseable string also resolves to nil: `ProfileValidator` Rule 5 already blocks saving
    /// one, and silently routing a typo'd endpoint to the vendor is exactly this finding.
    private var configuredBaseURL: URL? {
        guard let raw = providerConfig.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// ⚠️ Every picker below receives `configuredBaseURL`. The endpoint field is rendered directly
    /// ABOVE these pickers, so "all traffic for this profile goes there" is the only reasonable
    /// reading — and it was false: the pickers hardcoded the vendor host and sent the user's
    /// gateway-scoped key to it.
    @ViewBuilder
    private func modelPicker(apiKey: String) -> some View {
        switch providerConfig.apiProvider {
        case .google:
            GeminiModelPickerView(
                selectedModel: $providerConfig.modelName,
                apiKey: apiKey,
                baseURL: configuredBaseURL
            )
            .labelsHidden()
            .frame(maxWidth: 350, alignment: .trailing)

        case .anthropic:
            AnthropicModelPickerView(
                selectedModel: $providerConfig.modelName,
                apiKey: apiKey,
                baseURL: configuredBaseURL
            )
            .labelsHidden()
            .frame(maxWidth: 350, alignment: .trailing)

        case .openAI:
            OpenAIModelPickerView(
                selectedModel: $providerConfig.modelName,
                apiKey: apiKey,
                baseURL: configuredBaseURL
            )
            .labelsHidden()
            .frame(maxWidth: 350, alignment: .trailing)

        case .openRouter:
            OpenRouterModelPickerView(
                selectedModel: $providerConfig.modelName,
                cognitiveCapability: Binding(
                    get: { providerConfig.cognitiveCapability },
                    set: { providerConfig.cognitiveCapability = $0 }
                ),
                modelMetadata: Binding(
                    get: { providerConfig.modelMetadata },
                    set: { providerConfig.modelMetadata = $0 }
                ),
                supportedModalities: Binding(
                    get: { providerConfig.supportedModalities },
                    set: { providerConfig.supportedModalities = $0 }
                ),
                apiKey: apiKey,
                baseURL: configuredBaseURL,
                filterForTools: ProfileCapabilityFilter.filterForTools(for: profileType)
            )
            .frame(maxWidth: 350, alignment: .trailing)

        default:
            TextField("e.g. gpt-4o", text: $providerConfig.modelName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
        }
    }

    // MARK: - Endpoint Field

    /// Plain-HTTP warning for the configured endpoint, or nil when there is nothing to say
    /// (register A52). Recomputed per render — it has to follow the key being typed as well as the
    /// URL, since attaching a credential is what turns "readable traffic" into "readable key".
    private var transportWarning: String? {
        EndpointTransportSecurity.warning(
            for: EndpointTransportSecurity.evaluate(
                baseURL: providerConfig.baseURL,
                apiKey: providerConfig.apiKey
            )
        )
    }

    private var endpointField: some View {
        VStack(alignment: .leading, spacing: 8) {
            endpointRow

            // ⚠️ Register A52. The app would send `Authorization: Bearer <key>` over unencrypted
            // HTTP with nothing said about it. Warning, not a block: `http://localhost` is how the
            // local providers work, and the classifier exempts loopback for exactly that reason.
            if let transportWarning {
                Label(transportWarning, systemImage: "lock.open.trianglebadge.exclamationmark")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.warningColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("Insecure endpoint warning")
                    .accessibilityValue(transportWarning)
            }
        }
    }

    private var endpointRow: some View {
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

                    GlassActionButton(title: "Edit", icon: "pencil") {
                        isEditingBaseURL = true
                    }
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

// MARK: - ApiProvider Localization
//
// `ApiProvider` is declared in `BackendProfile.swift`, a Foundation-only model file whose
// values are `Codable` and reach SwiftData/JSON — it must not import SwiftUI, so the
// presentation-only property lives here in the SwiftUI layer instead.
extension ApiProvider {
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` stays for persistence and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .ollama:           return "Ollama (Local)"
        case .mlx:              return "MLX (Apple Silicon)"
        case .openAI:           return "OpenAI"
        case .anthropic:        return "Anthropic"
        case .google:           return "Google"
        case .openRouter:       return "OpenRouter"
        case .openAICompatible: return "Custom (OpenAI-Compatible)"
        }
    }
}
