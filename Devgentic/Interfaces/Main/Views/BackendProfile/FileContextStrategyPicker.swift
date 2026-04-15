//
//  FileContextStrategyPicker.swift
//  Devgentic
//
//  Created on 29/03/26.
//
//  Reusable SwiftUI component for selecting a FileContextStrategy in profile editors.
//

import SwiftUI

struct FileContextStrategyPicker: View {
    @Binding var strategy: FileContextStrategy?
    let profileType: ProfileType
    @Environment(\.appTheme) private var theme

    private var resolvedStrategy: FileContextStrategy {
        strategy ?? FileContextStrategy.defaultStrategy(for: profileType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacingMedium) {
            ForEach(FileContextStrategy.allCases, id: \.self) { option in
                FileContextStrategyCard(
                    strategy: option,
                    isSelected: resolvedStrategy == option,
                    isDefault: option == FileContextStrategy.defaultStrategy(for: profileType),
                    theme: theme
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if option == FileContextStrategy.defaultStrategy(for: profileType) {
                            strategy = nil
                        } else {
                            strategy = option
                        }
                    }
                }
            }

            if strategy != nil {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .accessibilityHidden(true)
                    Text("Custom override. Default for \(profileType.rawValue) is \(FileContextStrategy.defaultStrategy(for: profileType).displayName).")
                }
                .font(theme.fontCaption)
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
                        Text(strategy.displayName)
                            .font(theme.fontSubheadline.weight(.medium))
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

                    Text(strategy.description)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.secondaryText)
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
