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
        VStack(alignment: .leading, spacing: 10) {
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
                    Text("Custom override. Default for \(profileType.rawValue) is \(FileContextStrategy.defaultStrategy(for: profileType).displayName).")
                }
                .font(.caption)
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
                    .font(.title3)
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(strategy.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(theme.primaryText)

                        if isDefault {
                            Text("Default")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(theme.accentColor.opacity(0.15))
                                .foregroundColor(theme.accentColor)
                                .cornerRadius(4)
                        }
                    }

                    Text(strategy.description)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? theme.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? theme.accentColor.opacity(0.3) : theme.dividerColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
