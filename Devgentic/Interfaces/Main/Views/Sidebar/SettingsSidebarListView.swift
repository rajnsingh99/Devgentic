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

    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    /// The currently-displayed settings category (derived from the router).
    private var activeCategory: SettingsCategory? {
        if case .settingsDetail(let cat) = router.activeDestination { return cat }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            SidebarHeaderView(title: "Settings")
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

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
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct SettingsCategoryRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if isSelected {
                Capsule()
                    .fill(theme.accentColor)
                    .frame(width: 3, height: 18)
                    .padding(.trailing, 6)
                    .transition(.opacity.combined(with: .scale))
            } else {
                Spacer().frame(width: 9)
            }

            HStack(spacing: 10) {
                Image(systemName: category.iconName)
                    .font(theme.fontFootnote.weight(isSelected ? .bold : .semibold))
                    .foregroundColor(isSelected ? theme.accentColor : (isHovering ? theme.primaryText : theme.secondaryText))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.localizedTitle)
                        .font(theme.fontFootnote.weight(isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                    Text(category.subtitle)
                        .font(theme.fontCaption2)
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarRowBackground(isSelected: isSelected, isHovering: isHovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}
