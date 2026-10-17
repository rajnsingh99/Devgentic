// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderConfigSection.swift
//  Devgentic
//
//  Unified Model-First Inference Engine configuration UI.
//  Replaces legacy provider/key/endpoint dropdown clutter with a sleek,
//  authoritative Selected Model Card backed by the dedicated Model Catalog.
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

    /// Optional custom MLX content (e.g. ImageGen uses Flux2ModelPickerView instead of the model catalog).
    var customMLXContent: AnyView? = nil

    // MARK: - Internal State

    @State private var isShowingModelCatalog: Bool = false

    @Environment(\.appTheme) private var theme

    private let catalogService = ModelCatalogService.shared
    private let keyStore = AppProviderKeyStore.shared

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let custom = customMLXContent, providerConfig.apiProvider == .mlx {
                custom
            } else {
                selectedModelCard
            }
        }
        .sheet(isPresented: $isShowingModelCatalog) {
            ModelCatalogWindowView(
                providerConfig: $providerConfig,
                profileID: profileID,
                profileType: profileType,
                onProviderChanged: onProviderChanged
            )
        }
    }

    // MARK: - Selected Model Card

    @ViewBuilder
    private var selectedModelCard: some View {
        if providerConfig.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyModelCard
        } else {
            activeModelCard
        }
    }

    // MARK: - Empty State Card

    private var emptyModelCard: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surfaceOverlay)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.dividerColor.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Image(systemName: "square.dashed")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text("No Model Selected")
                    .font(theme.fontBody.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Text("Select an on-device local engine or cloud model to power this profile.")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer(minLength: 16)

            TactileButton(
                title: "Browse Models",
                icon: "square.grid.2x2",
                variant: .primary,
                size: .regular
            ) {
                isShowingModelCatalog = true
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Active Model Card

    private var activeModelCard: some View {
        let category = ModelCatalogProviderCategory.category(for: providerConfig)
        let isReady = isEngineReady(for: category)

        return VStack(alignment: .leading, spacing: 12) {
            // Header Row: Provider Icon + Display Name & Integrated Status + Change Model Action
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: category.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 38, height: 38)
                    .background(theme.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 0.75)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(cleanedDisplayName)
                            .font(theme.fontHeadline.weight(.bold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)

                        // Provider Badge Capsule
                        Text(category.title)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(theme.surfaceOverlay, in: Capsule())
                            .overlay(Capsule().strokeBorder(theme.dividerColor.opacity(0.4), lineWidth: 0.5))
                            .foregroundColor(theme.secondaryText)
                    }

                    // Integrated Status Dot & Endpoint Subtitle
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isReady ? Color.green : Color.orange)
                            .frame(width: 6.5, height: 6.5)
                            .overlay(
                                Circle()
                                    .strokeBorder((isReady ? Color.green : Color.orange).opacity(0.35), lineWidth: 1)
                            )

                        Text(readinessStatusText(for: category, isReady: isReady))
                            .font(theme.fontCaption2.weight(.medium))
                            .foregroundColor(isReady ? Color.green : Color.orange)

                        Text("·")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText.opacity(0.6))

                        Text(endpointOrTypeSubtitle(for: category))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 16)

                TactileButton(
                    title: "Change Model",
                    icon: "arrow.triangle.2.circlepath",
                    variant: .secondary,
                    size: .compact
                ) {
                    isShowingModelCatalog = true
                }
            }

            // Single Clean Divider
            Rectangle()
                .fill(theme.dividerColor.opacity(0.35))
                .frame(height: 0.5)
                .padding(.vertical, 2)

            // Bottom Row: Unified Specifications & Capabilities Row
            HStack(alignment: .center, spacing: 8) {
                // Cognitive Capability Badge
                let cap = providerConfig.cognitiveCapability
                let (capTitle, capIcon, capColor): (String, String, Color) = {
                    switch cap {
                    case .parallelActions:
                        return ("Parallel Actions", "bolt.shield.fill", .green)
                    case .singleAction:
                        return ("Single Action", "bolt.fill", .blue)
                    case .none:
                        return ("Text Only", "bubble.left.and.bubble.right.fill", theme.secondaryText)
                    }
                }()
                specBadge(title: capTitle, icon: capIcon, color: capColor, isNeutral: cap == .none)

                // Context Window Badge
                if let contextText = contextWindowDisplay {
                    specBadge(title: "\(contextText) Context", icon: "book.closed", color: theme.secondaryText, isNeutral: true)
                }

                // Modalities Badges
                if providerConfig.supportedModalities.contains(.visionInput) {
                    specBadge(title: "Vision", icon: "eye.fill", color: .purple)
                }
                if providerConfig.cognitiveCapability != .none {
                    specBadge(title: "Tools", icon: "wrench.and.screwdriver.fill", color: .blue)
                }
                if providerConfig.thinkingEnabled {
                    specBadge(title: "Reasoning", icon: "brain.fill", color: .orange)
                }

                Spacer(minLength: 12)

                // Architecture Caption
                Text(architectureCaption)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers

    private var architectureCaption: String {
        if profileType == .imageGen {
            return "Diffusion Generation Engine"
        }
        switch providerConfig.cognitiveCapability {
        case .parallelActions:
            return "Structured Tooling Architecture"
        case .singleAction:
            return "Sequential Tooling Architecture"
        case .none:
            return "Conversational Engine"
        }
    }

    private var contextWindowDisplay: String? {
        if let ctx = providerConfig.modelMetadata?.contextWindow, ctx > 0 {
            return formatContextTokens(ctx)
        }
        let category = ModelCatalogProviderCategory.category(for: providerConfig)
        if let catalogCtx = catalogService.contextWindow(for: providerConfig.modelName, category: category) {
            return catalogCtx
        }
        let lower = providerConfig.modelName.lowercased()
        if lower.contains("gemini") { return "1M" }
        if lower.contains("claude") { return "200K" }
        if lower.contains("o1") || lower.contains("o3") { return "200K" }
        if lower.contains("gpt-4") { return "128K" }
        if lower.contains("deepseek") { return "64K" }
        if lower.contains("llama-3") || lower.contains("llama3") { return "128K" }
        if lower.contains("qwen") { return "32K" }
        if lower.contains("mistral") { return "32K" }
        return "8K"
    }

    private func formatContextTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return "\(tokens / 1_000_000)M"
        } else if tokens >= 1_000 {
            return "\(tokens / 1_000)K"
        }
        return "\(tokens)"
    }

    private func specBadge(
        title: String,
        icon: String,
        color: Color,
        isNeutral: Bool = false
    ) -> some View {
        HStack(spacing: 4.5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            isNeutral ? theme.surfaceOverlay : color.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isNeutral ? theme.dividerColor.opacity(0.4) : color.opacity(0.25), lineWidth: 0.75)
        )
        .foregroundColor(isNeutral ? theme.primaryText : color)
    }

    private var cleanedDisplayName: String {
        providerConfig.modelName
            .replacingOccurrences(of: "(OpenRouter)", with: "")
            .replacingOccurrences(of: "(Open Router)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func endpointOrTypeSubtitle(for category: ModelCatalogProviderCategory) -> String {
        if providerConfig.apiProvider == .openAICompatible {
            return providerConfig.baseURL ?? "Custom OpenAI-Compatible Gateway"
        } else if category.isLocal {
            if category == .ollama {
                return providerConfig.baseURL ?? ProviderDefaults.ollamaBaseURL.absoluteString
            } else {
                return "On-Device · Apple Silicon (MLX)"
            }
        } else {
            return "Cloud API · \(category.title)"
        }
    }

    private func isEngineReady(for category: ModelCatalogProviderCategory) -> Bool {
        switch category {
        case .ollama:
            return catalogService.isOllamaOnline
        case .mlx:
            return !MLXModelService.shared.installedModels.isEmpty
        case .custom:
            return true
        default:
            return keyStore.hasKey(forAccount: category.vendorKey)
        }
    }

    private func readinessStatusText(for category: ModelCatalogProviderCategory, isReady: Bool) -> String {
        switch category {
        case .ollama:
            return isReady ? "Online" : "Offline"
        case .mlx:
            return isReady ? "Ready" : "No Models Installed"
        case .custom:
            return "Online"
        default:
            return isReady ? "Active" : "Key Required"
        }
    }

    static func defaultBaseURL(for provider: ApiProvider) -> String {
        ProviderDefaults.baseURLString(for: provider)
    }
}

// MARK: - ApiProvider Localization

extension ApiProvider {
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
