// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// Keys pasted for other providers during this editing session, so switching away and back
    /// restores them. In memory only: `switchProvider(to:)` clears `apiKey`, and only the key for
    /// the provider actually selected is ever saved (to the Keychain) or sent.
    @State private var stashedKeys: [ApiProvider: String] = [:]

    /// Bound only so toggling General Settings → "Show Remote Models" re-renders the
    /// picker live; the filter itself lives in `ProfileCapabilityFilter`.
    @AppStorage(AppSettings.showRemoteModelsKey) private var showRemoteModels: Bool = false

    @Environment(\.appTheme) private var theme

    // MARK: - Computed Helpers

    private var providers: [ApiProvider] {
        ProfileCapabilityFilter.allowedProviders(for: profileType, keepingCurrent: providerConfig.apiProvider)
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
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text("The underlying model powering this profile.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.5)
            }

            Spacer(minLength: 16)

            Picker("", selection: Binding(
                get: { providerConfig.apiProvider },
                set: { newValue in
                    let oldValue = providerConfig.apiProvider
                    guard newValue != oldValue else { return }
                    if let key = providerConfig.apiKey, !key.isEmpty { stashedKeys[oldValue] = key }
                    providerConfig.switchProvider(to: newValue)
                    providerConfig.apiKey = stashedKeys[newValue]
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
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
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
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
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

    /// ⚠️ register B22 — the ENDPOINT LEADS. This used to render the API Key field first, and the
    /// order is not cosmetic: `AnthropicModelPickerView` and `OpenAIModelPickerView` fetch as soon
    /// as a key is present, so a user configuring the form top-to-bottom pasted a gateway-scoped
    /// key and had it verified against the VENDOR host before they ever reached the field that
    /// says where this profile talks to. `openAICompatibleFields` below already led with the
    /// endpoint; matching it makes the two layouts agree and removes the exposure by construction
    /// rather than by the user happening to fill the form out of order.
    @ViewBuilder
    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            endpointField

            Divider()

            apiKeyField()

            Divider()

            // Model Selection (gated by API key)
            let currentApiKey = providerConfig.apiKey ?? ""

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                }

                Spacer(minLength: 16)

                if currentApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a valid API Key to select a model.")
                        .font(theme.fontCaption2)
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

            // ⚠️ Known endpoints, offered because the capability already worked and could not be
            // found. HuggingFace Inference Providers speak the OpenAI wire format, so this
            // provider has always driven them — including native tool calls — but the field is a
            // bare URL box hinting at localhost, so nobody would guess it.
            HStack(spacing: 8) {
                Text("Presets")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                ForEach(CompatibleEndpointPreset.all) { preset in
                    let isActive = CompatibleEndpointPreset.matching(providerConfig.baseURL)?.id == preset.id
                    Button(preset.name) { providerConfig.baseURL = preset.url }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(isActive ? theme.accentColor : nil)
                        .help("Use \(preset.name) at \(preset.url)")
                        .accessibilityLabel("Use the \(preset.name) endpoint")
                }
                Spacer()
            }

            Divider()

            apiKeyField(labelSuffix: " (Optional)")

            // ⚠️ An explicit button, never a silent auto-fill. This COPIES a Keychain secret out
            // of the HuggingFace download store into the per-profile key store — a second item
            // that will not track the first when the user rotates the token. Making the copy the
            // user's deliberate act is what makes the later divergence explicable.
            if let preset = CompatibleEndpointPreset.matching(providerConfig.baseURL),
               preset.usesHuggingFaceToken,
               HuggingFaceTokenStore.shared.hasToken,
               (providerConfig.apiKey ?? "").isEmpty {
                HStack(spacing: 8) {
                    Button("Use saved HuggingFace token") {
                        providerConfig.apiKey = HuggingFaceTokenStore.shared.token
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("Copies the token from Settings › General into this profile.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                    Spacer()
                }
            }

            Divider()

            let currentBaseURL = providerConfig.baseURL ?? ""

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model Selection")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Load the endpoint's models, or type the id.")
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                }

                Spacer(minLength: 16)

                if currentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter the API Endpoint above first.")
                        .font(theme.fontCaption2)
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
                Text("API Key\(labelSuffix)")
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
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
    /// ⚠️ register B22 — the three-case form. This was `configuredBaseURL: URL?`, which collapsed
    /// "not set" and "set but unparseable" into the same `nil`, and `nil` means "use the vendor
    /// default" — so a typo'd or half-typed gateway address silently sent the profile's key to the
    /// vendor. `ConfiguredEndpoint` keeps the third case distinct so the picker can refuse instead
    /// of falling back. The old property is gone rather than kept as a shim: leaving a `URL?`
    /// accessor next to this is an invitation to re-introduce exactly the collapse it describes.
    private var configuredEndpoint: ConfiguredEndpoint {
        ConfiguredEndpoint.resolve(providerConfig.baseURL)
    }

    /// ⚠️ Every picker below receives `configuredEndpoint`. The endpoint field is rendered directly
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
                endpoint: configuredEndpoint
            )
            .labelsHidden()
            .frame(maxWidth: 350, alignment: .trailing)

        case .anthropic:
            AnthropicModelPickerView(
                selectedModel: $providerConfig.modelName,
                apiKey: apiKey,
                endpoint: configuredEndpoint
            )
            .labelsHidden()
            .frame(maxWidth: 350, alignment: .trailing)

        case .openAI:
            OpenAIModelPickerView(
                selectedModel: $providerConfig.modelName,
                apiKey: apiKey,
                endpoint: configuredEndpoint
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
                endpoint: configuredEndpoint,
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
                    .font(theme.fontCaption2)
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
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                Text("Optional override for custom gateways.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2.5)
            }

            Spacer(minLength: 16)

            HStack {
                if isEditingBaseURL || (providerConfig.baseURL != nil && !providerConfig.baseURL!.isEmpty) {
                    TextField(Self.defaultBaseURL(for: providerConfig.apiProvider), text: baseURLBinding)
                        .font(theme.fontFootnote)
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
                        .font(theme.fontFootnote)
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
