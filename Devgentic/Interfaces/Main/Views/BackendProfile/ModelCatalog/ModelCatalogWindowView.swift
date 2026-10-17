// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelCatalogWindowView.swift
//  Devgentic
//
//  Dedicated split-view window/sheet for browsing model catalog and selecting models.
//  Features providers on the left, model catalog cards on the right, and one-time
//  Keychain API key management.
//

import SwiftUI

private let logger = DGLogger(category: "ModelCatalog")

struct ModelCatalogWindowView: View {

    @Binding var providerConfig: ProviderConfig
    let profileID: UUID
    let profileType: ProfileType
    var onProviderChanged: ((_ oldProvider: ApiProvider, _ newProvider: ApiProvider) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var selectedCategory: ModelCatalogProviderCategory
    @State private var keyPromptCategory: ModelCatalogProviderCategory? = nil
    @State private var pendingSelectedModel: CatalogModelItem? = nil

    init(
        providerConfig: Binding<ProviderConfig>,
        profileID: UUID,
        profileType: ProfileType,
        onProviderChanged: ((_ oldProvider: ApiProvider, _ newProvider: ApiProvider) -> Void)? = nil
    ) {
        self._providerConfig = providerConfig
        self.profileID = profileID
        self.profileType = profileType
        self.onProviderChanged = onProviderChanged
        self._selectedCategory = State(initialValue: ModelCatalogProviderCategory.category(for: providerConfig.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Window Header Bar
            windowHeader

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            // Split View: Sidebar + Detail
            HSplitView {
                // Left Pane: Providers
                ProviderSidebarListView(selectedCategory: $selectedCategory)
                    .frame(minWidth: 240, idealWidth: 260, maxWidth: 300)

                // Right Pane: Models Catalog
                ModelCatalogDetailView(
                    category: selectedCategory,
                    activeModelId: providerConfig.modelName,
                    baseURLOverride: providerConfig.baseURL,
                    onSelectModel: { model in
                        handleSelectModel(model)
                    },
                    onEditKey: { category in
                        keyPromptCategory = category
                    }
                )
                .frame(minWidth: 650)
            }
        }
        // Increased window dimensions by ~20% for optimal breathing room and 2-column density
        .frame(minWidth: 1040, idealWidth: 1150, minHeight: 700, idealHeight: 800)
        .background(theme.primaryBackground)
        .sheet(item: $keyPromptCategory) { category in
            ProviderKeyPromptSheet(
                category: category,
                initialEndpoint: providerConfig.baseURL,
                onSaved: { savedKey, savedEndpoint in
                    if let endpoint = savedEndpoint {
                        providerConfig.baseURL = endpoint
                    } else if providerConfig.apiProvider == category.apiProvider {
                        providerConfig.baseURL = nil
                    }
                    if let pending = pendingSelectedModel, pending.vendorKey == category.vendorKey {
                        applyModel(pending, key: savedKey, endpointOverride: savedEndpoint)
                        pendingSelectedModel = nil
                    } else if providerConfig.apiProvider == category.apiProvider {
                        providerConfig.apiKey = savedKey
                    }
                }
            )
        }
    }

    // MARK: - Window Header

    private var windowHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 16))
                .foregroundColor(theme.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text("Model Catalog")
                    .font(theme.fontHeadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Text("Browse available models across local engines and remote inference providers.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            TactileIconButton(icon: "xmark", tooltip: "Close", size: .compact) {
                dismiss()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.secondaryBackground.opacity(0.45))
    }

    // MARK: - Selection Logic

    private func handleSelectModel(_ model: CatalogModelItem) {
        if !model.provider.isLocal && model.vendorKey != "openai_compatible" {
            let hasKey = AppProviderKeyStore.shared.hasKey(forAccount: model.vendorKey)
            if !hasKey {
                // Prompt user for key and endpoint one time before applying
                pendingSelectedModel = model
                keyPromptCategory = selectedCategory
                return
            }
        }

        let key = AppProviderKeyStore.load(forAccount: model.vendorKey)
        let endpoint = AppProviderKeyStore.loadEndpoint(forAccount: model.vendorKey)
        applyModel(model, key: key, endpointOverride: endpoint)
    }

    /// ⚠️ Order matters, and was wrong. The provider-change callback used to run LAST, after the
    /// model's values were written, so its profile-type default (an agent on MLX or Ollama gets
    /// `.singleAction`) overwrote the capability just measured for the picked model. And a provider
    /// change reset nothing: the old provider's tuned generation settings and model measurements
    /// rode along. Now: reset for the new provider, apply the profile-type defaults, then the
    /// picked model's own values — the most specific answer is written last and wins.
    private func applyModel(_ model: CatalogModelItem, key: String?, endpointOverride: String? = nil) {
        let oldProvider = providerConfig.apiProvider

        if oldProvider != model.provider {
            providerConfig.switchProvider(to: model.provider)
            onProviderChanged?(oldProvider, model.provider)
        }
        providerConfig = CatalogModelSelection.applying(
            model, to: providerConfig,
            savedEndpoint: endpointOverride ?? AppProviderKeyStore.loadEndpoint(forAccount: model.vendorKey))

        if model.provider.isLocal && model.detectedProfile == nil {
            logger.warning(
                "[PROFILE] Picked local model '\(model.id)' (\(model.provider.rawValue)) for profile "
                + "\(profileID.uuidString.prefix(8)) with no analyzer result on its catalog entry. "
                + "CONSEQUENCE: the profile stores the catalog's capability and no tier, template or stop "
                + "sequences; runs still re-detect at start, but anything reading the stored copy sees defaults."
            )
        }
        logger.info(
            "[PROFILE] Picked '\(model.id)' (\(model.provider.rawValue)) from the catalog for profile "
            + "\(profileID.uuidString.prefix(8)) — \(CatalogModelSelection.describe(providerConfig)). "
            + "It is stored on the next save."
        )

        if let key, !key.isEmpty {
            providerConfig.apiKey = key
        }

        dismiss()
    }
}
