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
            // Left rail = STATE: accent when selected or hovered; absent otherwise
            if isSelected || isHovering {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: isSelected ? [theme.accentColor, theme.accentColor.opacity(0.45)] : [theme.accentColor.opacity(0.4), theme.accentColor.opacity(0.15)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, isSelected ? 2 : 5)
                    .padding(.trailing, 4)
                    .shadow(color: isSelected ? theme.accentColor.opacity(0.4) : .clear, radius: 4)
                    .transition(.opacity.combined(with: .scale))
            } else {
                Spacer().frame(width: 7)
            }

            HStack(spacing: 12) {
                Image(systemName: category.iconName)
                    .font(.system(.body))
                    .foregroundColor(isSelected ? theme.accentColor : theme.secondaryText)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(theme.fontFootnote.weight(.medium))
                        .foregroundColor(theme.primaryText)

                    Text(category.subtitle)
                        .font(.system(.caption))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.accentColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(theme.accentColor.opacity(0.15), lineWidth: 0.5)
                        )
                        .shadow(color: theme.accentColor.opacity(0.05), radius: 4, x: 0, y: 0)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
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
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}
