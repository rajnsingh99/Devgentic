//
//  SettingsSidebarListView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Inline sidebar list for settings categories. Replaces the separate
//  SettingsView window — tapping a category shows its detail in the
//  main content area via MainViewRouter.
//

import SwiftUI

struct SettingsSidebarListView: View {

    @EnvironmentObject private var router: MainViewRouter
    @Environment(\.appTheme) private var theme

    /// The currently-displayed settings category (derived from the router).
    private var activeCategory: SettingsCategory? {
        if case .settingsDetail(let cat) = router.activeDestination { return cat }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Category list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsCategory.allCases) { category in
                        SettingsCategoryRow(
                            category: category,
                            isSelected: activeCategory == category,
                            onSelect: {
                                router.navigateToSettings(category)
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - Settings Category Row

private struct SettingsCategoryRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .transition(.opacity.combined(with: .scale))
            }

            HStack(spacing: 12) {
                Image(systemName: category.iconName)
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)

                    Text(category.subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surfaceOverlay)
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
