// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  FileContextStrategyPicker.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A picker for choosing a `FileContextStrategy` in profile editors.
struct FileContextStrategyPicker: View {
    @Binding var strategy: FileContextStrategy?
    let profileType: ProfileType
    @Environment(\.appTheme) private var theme

    private var defaultStrategy: FileContextStrategy {
        FileContextStrategy.defaultStrategy(for: profileType)
    }

    /// Mirrors runtime resolution (`BackendProfileSnapshot.resolvedFileContextStrategy`),
    /// so an unsupported persisted override renders as the default it heals to.
    private var resolvedStrategy: FileContextStrategy {
        FileContextStrategy.resolve(strategy, for: profileType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingMedium) {
            ForEach(FileContextStrategy.availableStrategies(for: profileType), id: \.self) { option in
                FileContextStrategyCard(
                    strategy: option,
                    isSelected: resolvedStrategy == option,
                    isDefault: option == defaultStrategy,
                    theme: theme
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if option == defaultStrategy {
                            strategy = nil
                        } else {
                            strategy = option
                        }
                    }
                }
            }

            if resolvedStrategy != defaultStrategy {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .accessibilityHidden(true)
                    // `LocalizedStringKey` interpolation of a `Text` keeps the key extractable and localizes both substituted values.
                    Text("Custom override. Default for \(Text(profileType.localizedTitle)) is \(Text(defaultStrategy.localizedTitle)).")
                }
                .font(theme.fontCaption2)
                .foregroundColor(theme.secondaryText)
            }
        }
    }
}

// MARK: - Strategy Card

private struct FileContextStrategyCard: View {
    let strategy: FileContextStrategy
    let isSelected: Bool
    let isDefault: Bool
    let theme: any Theme
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: strategy.iconName)
                    .font(theme.fontTitle3)
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(strategy.localizedTitle)
                            .font(theme.fontFootnote.weight(.semibold))
                            .foregroundColor(theme.primaryText)

                        if isDefault {
                            Text("Default")
                                .font(theme.fontCaption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.accentColor.opacity(0.15))
                                .foregroundColor(theme.accentColor)
                                .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusSmall))
                        }
                    }

                    Text(strategy.localizedDescription)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.secondaryText)
                        .lineSpacing(2.5)
                        .lineLimit(2)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(theme.spacingMedium)
            .background(
                RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadiusMedium)
                    .stroke(isSelected ? theme.accentColor.opacity(0.3) : theme.dividerColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
