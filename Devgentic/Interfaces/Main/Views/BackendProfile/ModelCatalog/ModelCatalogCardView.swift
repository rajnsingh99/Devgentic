// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelCatalogCardView.swift
//  Devgentic
//
//  Model card displaying metadata, capability tags, memory fit, and selection action.
//

import SwiftUI

struct ModelCatalogCardView: View {

    let model: CatalogModelItem
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            descriptionRow
            metadataAndTagsRow
            memoryFitRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? (theme.isDark ? theme.accentColor.opacity(0.06) : theme.accentColor.opacity(0.04))
                : theme.secondaryBackground.opacity(0.7)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(borderStrokeColor, lineWidth: isSelected ? 1.5 : 0.75)
        )
    }

    private var borderStrokeColor: Color {
        if isSelected {
            return theme.accentColor.opacity(0.85)
        }
        return theme.dividerColor.opacity(theme.isDark ? 0.35 : 0.6)
    }

    private var cleanedDisplayName: String {
        model.displayName
            .replacingOccurrences(of: "(OpenRouter)", with: "")
            .replacingOccurrences(of: "(Open Router)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(cleanedDisplayName)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)

                    if let params = model.parameterCount {
                        Text(params)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.secondaryBackground, in: Capsule())
                            .foregroundColor(theme.secondaryText)
                    }
                }

                if model.displayName.lowercased() != model.id.lowercased() {
                    Text(model.id)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            // Primary Action Button (moved to top-right 'ctx' position to clean up bottom row)
            if isSelected {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.successColor)
                    Text("Selected")
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundColor(theme.successColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(theme.successColor.opacity(0.12), in: Capsule())
            } else {
                TactileButton(
                    title: LocalizedStringKey("Select Model Action"),
                    icon: "checkmark.circle",
                    variant: .primary,
                    size: .compact
                ) {
                    onSelect()
                }
            }
        }
    }

    // MARK: - Description Row

    @ViewBuilder
    private var descriptionRow: some View {
        if !model.descriptionText.isEmpty {
            Text(model.descriptionText)
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var filteredTags: [String] {
        let suppressedTags: Set<String> = [
            "recommended",
            "vision",
            "tools",
            "tool calling",
            "tool",
            "reasoning",
            "apple silicon",
            "native mlx",
            "native"
        ]
        return model.tags.filter { tag in
            !suppressedTags.contains(tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    // MARK: - Metadata & Tags Row (Icon-only Capabilities + Context Window + Tags)

    private var metadataAndTagsRow: some View {
        HStack(spacing: 6) {
            // Capability Icon Badges (Icon-only per spec)
            if model.hasVision {
                capabilityIconBadge(icon: "eye", color: .purple, tooltip: "Vision Capable")
            }
            if model.hasTools {
                capabilityIconBadge(icon: "wrench.and.screwdriver", color: .blue, tooltip: "Tool Calling Capable")
            }
            if model.isReasoning {
                capabilityIconBadge(icon: "brain", color: .orange, tooltip: "Reasoning Capable")
            }

            // Context Window Badge (in the same row as capability icons)
            Text(model.contextWindowDisplay + " ctx")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2.5)
                .background(theme.surfaceOverlay, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.dividerColor.opacity(0.4), lineWidth: 0.5)
                )
                .foregroundColor(theme.secondaryText)

            // Descriptive Tags (e.g. Frontier, Code Specialist)
            ForEach(filteredTags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(theme.secondaryBackground, in: Capsule())
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Memory Fit Row (Local Models)

    @ViewBuilder
    private var memoryFitRow: some View {
        if let fit = model.fitAssessment, fit.estimatedRuntimeRAM > 0 {
            HStack(spacing: 6) {
                Image(systemName: fit.verdict == .comfortable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(fit.verdict == .comfortable ? .green : .orange)

                Text(fit.explanation)
                    .font(theme.fontCaption2)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(.top, 1)
        }
    }

    // MARK: - Compact Capability Icon Badge

    @ViewBuilder
    private func capabilityIconBadge(icon: String, color: Color, tooltip: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(0.12))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(color.opacity(0.3), lineWidth: 0.5)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
        }
        .frame(width: 20, height: 20)
        .help(tooltip)
    }
}
