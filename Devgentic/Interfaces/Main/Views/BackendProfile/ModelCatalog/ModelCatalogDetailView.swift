// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelCatalogDetailView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Right detail pane of the Model Catalog split view: search, filter chips and model cards.
struct ModelCatalogDetailView: View {

    let category: ModelCatalogProviderCategory
    let activeModelId: String
    var baseURLOverride: String? = nil
    let onSelectModel: (CatalogModelItem) -> Void
    let onEditKey: (ModelCatalogProviderCategory) -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @State private var searchText: String = ""
    @State private var selectedFilter: CatalogFilterCapability = .all
    @State private var models: [CatalogModelItem] = []
    @State private var isLoading: Bool = false

    @State private var customEndpointURL: String = ""
    @State private var customModelName: String = ""
    @State private var customAPIKey: String = ""
    @State private var isCustomKeyVisible: Bool = false

    private let keyStore = AppProviderKeyStore.shared
    private let catalogService = ModelCatalogService.shared

    private var requiresKeyAndMissing: Bool {
        !category.isLocal && category != .custom && !keyStore.hasKey(forAccount: category.vendorKey)
    }

    private var currentEndpointString: String {
        let trimmed = customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return baseURLOverride ?? AppProviderKeyStore.loadEndpoint(forAccount: "openai_compatible") ?? ProviderDefaults.openAICompatibleHintURL.absoluteString
    }

    private var filteredModels: [CatalogModelItem] {
        var result = models

        // Search text filter
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter {
                $0.displayName.lowercased().contains(query)
                || $0.id.lowercased().contains(query)
                || $0.descriptionText.lowercased().contains(query)
                || ($0.parameterCount?.lowercased().contains(query) ?? false)
            }
        }

        // Capability filter
        switch selectedFilter {
        case .all:
            break
        case .vision:
            result = result.filter { $0.hasVision }
        case .tools:
            result = result.filter { $0.hasTools }
        case .reasoning:
            result = result.filter { $0.isReasoning }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if requiresKeyAndMissing {
                keyValidationRequiredView
            } else {
                // Header Bar (shown when provider is ready or key is configured)
                headerBar

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                if category == .custom {
                    customGatewayDetailContent
                } else {
                    // Filter & Search Controls
                    filterAndSearchBar

                    Rectangle()
                        .fill(theme.dividerColor.opacity(0.3))
                        .frame(height: 0.5)

                    // Models List (Uniform Fixed-Width Cards)
                    ScrollView {
                        if isLoading {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.regular)
                                Text("Loading catalog...")
                                    .font(theme.fontCaption)
                                    .foregroundColor(theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                        } else if filteredModels.isEmpty {
                            emptyStateView
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredModels) { model in
                                    ModelCatalogCardView(
                                        model: model,
                                        isSelected: model.id == activeModelId,
                                        onSelect: { onSelectModel(model) }
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
        }
        .background(theme.primaryBackground)
        .task(id: category) {
            if category == .custom {
                if customEndpointURL.isEmpty {
                    customEndpointURL = baseURLOverride ?? AppProviderKeyStore.loadEndpoint(forAccount: "openai_compatible") ?? ProviderDefaults.openAICompatibleHintURL.absoluteString
                }
                if customAPIKey.isEmpty {
                    customAPIKey = AppProviderKeyStore.load(forAccount: "openai_compatible") ?? ""
                }
            }
            await loadModels()
        }
        .onChange(of: keyStore.revision) { _, _ in
            Task {
                if category == .custom {
                    if let saved = AppProviderKeyStore.loadEndpoint(forAccount: "openai_compatible") {
                        customEndpointURL = saved
                    }
                    if let key = AppProviderKeyStore.load(forAccount: "openai_compatible") {
                        customAPIKey = key
                    }
                }
                await loadModels()
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .frame(width: 38, height: 38)
                .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(category.title)
                        .font(theme.fontHeadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    if category.isLocal {
                        Text(category.subtitle)
                            .font(theme.fontCaption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.secondaryBackground, in: Capsule())
                            .foregroundColor(theme.secondaryText)
                    }
                }

                if category == .ollama {
                    Text(catalogService.isOllamaOnline ? "Ollama daemon connected · \(catalogService.ollamaVersion ?? "Ready")" : "Ollama daemon unreachable at \(baseURLOverride ?? ProviderDefaults.ollamaBaseURL.absoluteString)")
                        .font(theme.fontCaption2)
                        .foregroundColor(catalogService.isOllamaOnline ? .green : theme.secondaryText)
                } else if category == .custom {
                    let endpoint = currentEndpointString
                    if catalogService.isCustomEndpointOnline {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("Gateway connected · \(models.count) model\(models.count == 1 ? "" : "s") discovered at \(endpoint)")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                    } else {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text(catalogService.customEndpointError != nil ? "Gateway unreachable at \(endpoint)" : "Gateway offline at \(endpoint)")
                                .font(theme.fontCaption2)
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                } else if !category.isLocal {
                    if let masked = keyStore.maskedKey(forAccount: category.vendorKey) {
                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.green)
                                Text("Key: \(masked)")
                                    .font(theme.fontCaption2)
                                    .foregroundColor(theme.secondaryText)
                            }

                            if let endpoint = AppProviderKeyStore.loadEndpoint(forAccount: category.vendorKey) {
                                Text("·")
                                    .foregroundColor(theme.secondaryText.opacity(0.4))
                                Text("Endpoint: \(endpoint)")
                                    .font(theme.fontCaption2)
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("API Key required for model inference")
                            .font(theme.fontCaption2)
                            .foregroundColor(.orange)
                    }
                }
            }

            Spacer()

            // Key & Endpoint Management Actions
            if !category.isLocal {
                let hasKey = keyStore.hasKey(forAccount: category.vendorKey)
                let title = category == .custom ? "Configure Gateway" : (hasKey ? "Edit Key & Endpoint" : "Configure Key")
                let icon = (hasKey || category == .custom) ? "slider.horizontal.3" : "key.fill"

                TactileButton(
                    title: title,
                    icon: icon,
                    variant: (hasKey || category == .custom) ? .secondary : .primary,
                    size: .compact
                ) {
                    onEditKey(category)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Key Validation Required View

    private var keyValidationRequiredView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.12))
                    .frame(width: 68, height: 68)

                Image(systemName: category.icon)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(theme.accentColor)

                // Key indicator badge
                Circle()
                    .fill(theme.secondaryBackground)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(theme.dividerColor.opacity(0.6), lineWidth: 1))
                    .overlay(
                        Image(systemName: "key.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.accentColor)
                    )
                    .offset(x: 22, y: 22)
            }
            .frame(width: 76, height: 76)

            VStack(spacing: 6) {
                Text("\(category.title) API Key Required")
                    .font(theme.fontTitle3.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Text("Enter your \(category.title) API key to load and select available models.\nYour key will be securely saved to the macOS Keychain across the app lifetime.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 440)
            }

            TactileButton(
                title: "Configure \(category.title) Key",
                icon: "key.fill",
                variant: .primary,
                size: .regular
            ) {
                onEditKey(category)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Filter and Search Bar

    private var filterAndSearchBar: some View {
        HStack(spacing: 12) {
            // Search Field (adequate width so placeholder is never clipped)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.secondaryText)
                    .font(.system(size: 13))

                TextField(
                    "",
                    text: $searchText,
                    prompt: Text(category == .custom ? "Search server models by name or id" : "Search models by name or id").foregroundColor(theme.placeholderText)
                )
                .textFieldStyle(.plain)
                .font(theme.fontFootnote)
                .foregroundStyle(theme.primaryText)
                .disableAutocorrection(true)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor(enabled: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.secondaryBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 0.5)
            )
            .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)

            if category == .custom {
                TactileIconButton(icon: "arrow.clockwise", tooltip: "Refresh server models", size: .compact) {
                    Task {
                        await loadModels()
                    }
                }
            }

            Spacer(minLength: 16)

            // Capability Filter Pills
            HStack(spacing: 6) {
                ForEach(CatalogFilterCapability.allCases) { filter in
                    CatalogFilterChip(
                        title: filter.rawValue,
                        icon: filter.icon,
                        isSelected: selectedFilter == filter
                    ) {
                        selectedFilter = filter
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.2))
    }

    // MARK: - Custom Gateway Detail Content (Live Discovery UX)

    private var customGatewayDetailContent: some View {
        VStack(spacing: 0) {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Discovering models from gateway (\(currentEndpointString))...")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else if models.isEmpty {
                // When offline or no models discovered: clean configuration and manual connect card
                ScrollView {
                    VStack(spacing: 16) {
                        customGatewayConnectionCard
                    }
                    .padding(16)
                }
            } else {
                // Live server models discovered!
                filterAndSearchBar

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredModels) { model in
                            ModelCatalogCardView(
                                model: model,
                                isSelected: model.id == activeModelId,
                                onSelect: { selectCustomDiscoveredModel(model) }
                            )
                            .frame(maxWidth: .infinity)
                        }

                        // Bottom manual entry option
                        manualModelEntryFooter
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - Custom Gateway Connection Card (Offline / Setup State)

    private var customGatewayConnectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 15))
                        .foregroundColor(theme.accentColor)
                    Text("OpenAI-Compatible Gateway")
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                }

                Text("Connect to local inference engines (LM Studio, vLLM, LocalAI) or private servers. Devgentic queries `GET /v1/models` to discover available models live.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                    .lineSpacing(2)
            }

            // Presets
            HStack(spacing: 8) {
                Text("Presets:")
                    .font(theme.fontCaption2.weight(.medium))
                    .foregroundColor(theme.secondaryText)

                ForEach(CompatibleEndpointPreset.all) { preset in
                    let isSelected = CompatibleEndpointPreset.matching(customEndpointURL)?.id == preset.id
                    TactileButton(
                        title: LocalizedStringKey(preset.name),
                        variant: isSelected ? .primary : .secondary,
                        size: .compact
                    ) {
                        customEndpointURL = preset.url
                        if preset.usesHuggingFaceToken,
                           let token = HuggingFaceTokenStore.shared.token, !token.isEmpty {
                            customAPIKey = token
                        }
                        Task {
                            await discoverModels()
                        }
                    }
                }

                Spacer()
            }

            // Endpoint URL Field
            VStack(alignment: .leading, spacing: 4) {
                Text("Gateway Endpoint URL")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.primaryText)

                HStack(spacing: 8) {
                    TextField("http://localhost:1234/v1", text: $customEndpointURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    if customEndpointURL != ProviderDefaults.openAICompatibleHintURL.absoluteString {
                        TactileButton(title: "Reset", variant: .subtle, size: .compact) {
                            customEndpointURL = ProviderDefaults.openAICompatibleHintURL.absoluteString
                        }
                    }
                }
            }

            // Optional API Key
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key (Optional)")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.primaryText)

                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText.opacity(0.7))

                    if isCustomKeyVisible {
                        TextField(
                            "",
                            text: $customAPIKey,
                            prompt: Text("Enter API Key (Optional for local servers)").foregroundColor(theme.placeholderText)
                        )
                        .textFieldStyle(.plain)
                        .font(theme.fontCodeCaption)
                        .foregroundColor(theme.primaryText)
                        .disableAutocorrection(true)
                    } else {
                        SecureField(
                            "",
                            text: $customAPIKey,
                            prompt: Text("Enter API Key (Optional for local servers)").foregroundColor(theme.placeholderText)
                        )
                        .textFieldStyle(.plain)
                        .font(theme.fontCodeCaption)
                        .foregroundColor(theme.primaryText)
                        .disableAutocorrection(true)
                    }

                    if !customAPIKey.isEmpty {
                        Button {
                            isCustomKeyVisible.toggle()
                        } label: {
                            Image(systemName: isCustomKeyVisible ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(theme.secondaryBackground.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.dividerColor.opacity(0.4), lineWidth: 0.5))
            }

            // Discover Models Action
            HStack {
                if let error = catalogService.customEndpointError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                        Text(error)
                            .font(theme.fontCaption2)
                            .lineLimit(1)
                    }
                    .foregroundColor(theme.warningColor)
                }

                Spacer()

                TactileButton(
                    title: "Discover Models",
                    icon: "arrow.clockwise",
                    variant: .primary,
                    size: .regular
                ) {
                    Task {
                        await discoverModels()
                    }
                }
                .disabled(customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Divider
            HStack(spacing: 8) {
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
                Text("OR CONNECT DIRECTLY")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)
            }
            .padding(.vertical, 4)

            // Direct Model Identifier Field
            VStack(alignment: .leading, spacing: 4) {
                Text("Model Identifier")
                    .font(theme.fontCaption.weight(.medium))
                    .foregroundColor(theme.primaryText)

                HStack(spacing: 8) {
                    TextField("e.g. qwen2.5-coder-7b-instruct", text: $customModelName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))

                    TactileButton(
                        title: "Connect & Select",
                        icon: "checkmark.circle.fill",
                        variant: .secondary,
                        size: .compact
                    ) {
                        applyCustomManualModel()
                    }
                    .disabled(customModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Use this if your server is offline or does not expose a /v1/models endpoint.")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
            }
        }
        .padding(18)
        .background(theme.secondaryBackground.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.4), lineWidth: 0.75)
        )
    }

    // MARK: - Manual Model Entry Footer (When server models are listed)

    private var manualModelEntryFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundColor(theme.accentColor)
                Text("Model Not Listed?")
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)
            }

            Text("Enter a custom model identifier if your model is served under an alias or not listed in /v1/models.")
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)

            HStack(spacing: 8) {
                TextField("e.g. custom-finetuned-model", text: $customModelName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                TactileButton(
                    title: "Select Model",
                    icon: "checkmark",
                    variant: .secondary,
                    size: .compact
                ) {
                    applyCustomManualModel()
                }
                .disabled(customModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .background(theme.secondaryBackground.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.dividerColor.opacity(0.4), lineWidth: 0.5)
        )
        .padding(.top, 4)
    }

    // MARK: - Actions & Selection Logic

    private func selectCustomDiscoveredModel(_ model: CatalogModelItem) {
        let endpoint = currentEndpointString
        AppProviderKeyStore.saveEndpoint(endpoint, forAccount: "openai_compatible")
        let trimmedKey = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            AppProviderKeyStore.save(trimmedKey, forAccount: "openai_compatible")
        }
        onSelectModel(model)
    }

    private func applyCustomManualModel() {
        let trimmedModel = customModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        let endpoint = currentEndpointString
        AppProviderKeyStore.saveEndpoint(endpoint, forAccount: "openai_compatible")
        let trimmedKey = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            AppProviderKeyStore.save(trimmedKey, forAccount: "openai_compatible")
        }

        let customItem = CatalogModelItem(
            id: trimmedModel,
            displayName: trimmedModel,
            provider: .openAICompatible,
            vendorKey: "openai_compatible",
            parameterCount: nil,
            contextWindow: 32_768,
            contextWindowDisplay: "32K",
            supportedModalities: .visionInput,
            cognitiveCapability: .parallelActions,
            modelDialect: .nativeJSON,
            isReasoning: false,
            descriptionText: "Custom gateway model (\(endpoint))",
            baseURL: endpoint,
            tags: ["Custom Gateway"]
        )

        onSelectModel(customItem)
    }

    private func discoverModels() async {
        let trimmedURL = customEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalURL = trimmedURL.isEmpty ? ProviderDefaults.openAICompatibleHintURL.absoluteString : trimmedURL
        customEndpointURL = finalURL
        AppProviderKeyStore.saveEndpoint(finalURL, forAccount: "openai_compatible")

        let trimmedKey = customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            AppProviderKeyStore.save(trimmedKey, forAccount: "openai_compatible")
        }

        await loadModels()
    }

    // MARK: - Empty State View

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(theme.secondaryText)

            if !searchText.isEmpty {
                Text("No models match '\(searchText)'")
                    .font(theme.fontBody.weight(.medium))
                    .foregroundColor(theme.primaryText)
                Text("Try adjusting your search query or capability filter.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)

                TactileButton(title: "Clear Search", icon: "xmark", variant: .subtle, size: .compact) {
                    searchText = ""
                }
                .padding(.top, 4)
            } else if selectedFilter != .all {
                Text("No models match '\(selectedFilter.rawValue)'")
                    .font(theme.fontBody.weight(.medium))
                    .foregroundColor(theme.primaryText)
                Text("Try selecting 'All Models' to view all available options.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)

                TactileButton(title: "Reset Filter", icon: "arrow.counterclockwise", variant: .subtle, size: .compact) {
                    selectedFilter = .all
                }
                .padding(.top, 4)
            } else if category == .ollama && !catalogService.isOllamaOnline {
                Text("Ollama Server Not Reachable")
                    .font(theme.fontBody.weight(.medium))
                    .foregroundColor(theme.primaryText)
                Text("Ensure Ollama is running (`ollama serve`) and has models pulled (`ollama pull <model>`).")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
            } else {
                Text("No models found for \(category.title)")
                    .font(theme.fontBody.weight(.medium))
                    .foregroundColor(theme.primaryText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func loadModels() async {
        guard !requiresKeyAndMissing else {
            models = []
            return
        }
        isLoading = true
        if category == .custom {
            let endpoint = currentEndpointString
            let key = customAPIKey.isEmpty
                ? AppProviderKeyStore.load(forAccount: "openai_compatible")
                : customAPIKey
            models = await catalogService.loadCustomEndpointModels(baseURL: endpoint, apiKey: key)
        } else {
            models = await catalogService.models(for: category, baseURLOverride: baseURLOverride)
        }
        isLoading = false
    }
}

// MARK: - Filter Chip Component

private struct CatalogFilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @State private var isHovered = false

    private var isThemeContrast: Bool {
        buttonAccentStyle == .themeContrast
    }

    private var textColor: Color {
        if isSelected {
            if isThemeContrast {
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
            }
            return theme.primaryText
        }
        return isHovered ? theme.primaryText : theme.secondaryText
    }

    private var iconColor: Color {
        if isSelected {
            if isThemeContrast {
                return theme.isDark ? Color(red: 0.08, green: 0.08, blue: 0.08) : .white
            }
            return theme.accentColor
        }
        return isHovered ? theme.primaryText : theme.secondaryText
    }

    private var fillColor: Color {
        if isSelected {
            if isThemeContrast {
                return theme.isDark ? Color.white : Color(red: 0.12, green: 0.12, blue: 0.14)
            }
            return theme.surfaceOverlayStrong
        }
        return isHovered ? theme.surfaceOverlay : theme.surfaceOverlay.opacity(0.4)
    }

    private var strokeColor: Color {
        if isSelected {
            if isThemeContrast {
                return theme.isDark ? Color.white : Color(red: 0.12, green: 0.12, blue: 0.14)
            }
            return theme.accentColor.opacity(0.55)
        }
        return isHovered ? theme.secondaryText.opacity(0.25) : theme.secondaryText.opacity(0.12)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(theme.fontCaption.weight(isSelected ? .semibold : .regular))
                    .foregroundColor(textColor)
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointingHandCursor(enabled: true)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
