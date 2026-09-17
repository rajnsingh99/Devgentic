// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    @FocusState private var isListFocused: Bool
    @State private var focusedCategory: SettingsCategory? = nil

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
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(SettingsCategory.allCases) { category in
                            SettingsCategoryRow(
                                category: category,
                                isSelected: activeCategory == category,
                                isFocused: isListFocused && focusedCategory == category,
                                onSelect: {
                                    focusedCategory = category
                                    router.navigateToSettings(category)
                                }
                            )
                            .id(category)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .scrollContentBackground(.hidden)
                .focusable()
                .focused($isListFocused)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    moveFocus(direction, proxy: proxy)
                }
                .onKeyPress(.return) {
                    if let cat = focusedCategory {
                        router.navigateToSettings(cat)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress { press in
                    if let char = press.characters.first,
                       let num = Int(String(char)),
                       num >= 1 && num <= SettingsCategory.allCases.count {
                        let cat = SettingsCategory.allCases[num - 1]
                        focusedCategory = cat
                        router.navigateToSettings(cat)
                        withAnimation(.easeInOut(duration: 0.12)) {
                            proxy.scrollTo(cat, anchor: .center)
                        }
                        return .handled
                    }
                    return .ignored
                }
            }
        }
        .onAppear {
            if focusedCategory == nil {
                focusedCategory = activeCategory ?? .general
            }
        }
        .onChange(of: activeCategory) { _, newCat in
            if let newCat {
                focusedCategory = newCat
            }
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        let categories = SettingsCategory.allCases
        guard !categories.isEmpty else { return }
        let current = focusedCategory ?? activeCategory ?? categories.first!
        guard let currentIndex = categories.firstIndex(of: current) else {
            let first = categories.first!
            focusedCategory = first
            router.navigateToSettings(first)
            return
        }

        switch direction {
        case .up:
            let prevIndex = max(0, currentIndex - 1)
            let cat = categories[prevIndex]
            focusedCategory = cat
            router.navigateToSettings(cat)
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(cat, anchor: .center)
            }
        case .down:
            let nextIndex = min(categories.count - 1, currentIndex + 1)
            let cat = categories[nextIndex]
            focusedCategory = cat
            router.navigateToSettings(cat)
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(cat, anchor: .center)
            }
        default:
            break
        }
    }
}

private struct SettingsCategoryRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    var isFocused: Bool = false
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
        .sidebarRowBackground(isSelected: isSelected, isHovering: isHovering || isFocused)
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
