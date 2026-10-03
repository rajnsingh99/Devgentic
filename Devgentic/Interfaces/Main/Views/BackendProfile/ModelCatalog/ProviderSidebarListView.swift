// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderSidebarListView.swift
//  Devgentic
//
//  Left sidebar of the dedicated Model Catalog split view showing providers and key status.
//

import SwiftUI

struct ProviderSidebarListView: View {

    @Binding var selectedCategory: ModelCatalogProviderCategory
    @Environment(\.appTheme) private var theme

    private let keyStore = AppProviderKeyStore.shared
    private let catalogService = ModelCatalogService.shared

    private var localCategories: [ModelCatalogProviderCategory] {
        [.ollama, .mlx]
    }

    private var remoteCategories: [ModelCatalogProviderCategory] {
        [.huggingFace, .anthropic, .openAI, .google, .openRouter, .custom]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sidebar List
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sectionView(title: "LOCAL ENGINES", categories: localCategories)
                    sectionView(title: "REMOTE & CLOUD", categories: remoteCategories)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            // System Hardware Summary Footer
            hardwareFooter
        }
        .background(theme.secondaryBackground.opacity(0.4))
    }

    // MARK: - Section View

    @ViewBuilder
    private func sectionView(title: String, categories: [ModelCatalogProviderCategory]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(theme.fontCaption2.weight(.bold))
                .foregroundColor(theme.secondaryText.opacity(0.8))
                .tracking(0.5)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)

            ForEach(categories) { category in
                ProviderSidebarRow(
                    category: category,
                    isSelected: selectedCategory == category,
                    badgeView: AnyView(badge(for: category))
                ) {
                    selectedCategory = category
                }
            }
        }
    }

    // MARK: - Status Badge

    private func isCategoryActive(_ category: ModelCatalogProviderCategory) -> Bool {
        switch category {
        case .ollama:
            return catalogService.isOllamaOnline
        case .mlx:
            return !MLXModelService.shared.installedModels.isEmpty
        case .custom:
            return keyStore.hasKey(forAccount: category.vendorKey)
        default:
            return keyStore.hasKey(forAccount: category.vendorKey)
        }
    }

    private func statusTooltip(for category: ModelCatalogProviderCategory, isActive: Bool) -> String {
        switch category {
        case .ollama:
            return isActive ? "Ollama Online" : "Ollama Offline"
        case .mlx:
            return isActive ? "MLX Ready (\(MLXModelService.shared.installedModels.count) installed)" : "No MLX Models Installed"
        case .custom:
            return isActive ? "Custom Key Configured" : "Custom Key Not Configured"
        default:
            return isActive ? "\(category.title) Key Configured" : "\(category.title) Key Required"
        }
    }

    @ViewBuilder
    private func badge(for category: ModelCatalogProviderCategory) -> some View {
        let active = isCategoryActive(category)
        Circle()
            .fill(active ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .strokeBorder(active ? Color.green.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .help(statusTooltip(for: category, isActive: active))
    }

    // MARK: - Hardware Footer

    private var hardwareFooter: some View {
        let profile = SystemHardwareProfiler.shared.profile
        return HStack(spacing: 8) {
            Image(systemName: "memorychip")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(theme.accentColor)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(profile.chipFamily == .unknown ? "Apple Silicon" : "Apple \(profile.chipFamily.rawValue)")
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text("\(profile.formattedTotalRAM) RAM · \(profile.formattedEffectiveBudget) Budget")
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.secondaryBackground.opacity(0.5))
    }
}

// MARK: - Sidebar Row Subview

private struct ProviderSidebarRow: View {
    let category: ModelCatalogProviderCategory
    let isSelected: Bool
    let badgeView: AnyView
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Provider Icon
                Image(systemName: category.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? theme.accentColor : (isHovered ? theme.primaryText : theme.secondaryText))
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? theme.accentColor.opacity(0.15) : theme.secondaryBackground.opacity(0.6))
                    )

                // Provider Name & Subtitle
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                        .font(theme.fontFootnote.weight(isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? theme.primaryText : (isHovered ? theme.primaryText : theme.primaryText.opacity(0.9)))
                        .lineLimit(1)

                    Text(category.subtitle)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Status Badge
                badgeView
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? (theme.isDark ? theme.accentColor.opacity(0.14) : theme.accentColor.opacity(0.10))
                            : (isHovered ? theme.surfaceOverlay : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.accentColor.opacity(0.4) : Color.clear,
                        lineWidth: 0.5
                    )
            )
            .contentShape(Rectangle())
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
