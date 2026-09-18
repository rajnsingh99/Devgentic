// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  KeyboardShortcutsReferenceView.swift
//  Devgentic
//
//  Interactive searchable cheatsheet of all keyboard shortcuts in Devgentic.
//

import SwiftUI

struct KeyboardShortcutsReferenceView: View {

    @Environment(\.appTheme) private var theme
    @State private var selectedCategory: ShortcutCategory = .all
    @State private var searchText: String = ""

    private var filteredShortcuts: [ShortcutItem] {
        let categoryFiltered: [ShortcutItem]
        if selectedCategory == .all {
            categoryFiltered = ShortcutRegistry.allShortcuts
        } else {
            categoryFiltered = ShortcutRegistry.allShortcuts.filter { $0.category == selectedCategory }
        }

        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return categoryFiltered
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return categoryFiltered.filter { item in
            item.title.lowercased().contains(query) ||
            item.description.lowercased().contains(query) ||
            item.category.rawValue.lowercased().contains(query) ||
            item.keys.joined(separator: " ").lowercased().contains(query) ||
            (item.contextNote?.lowercased().contains(query) ?? false)
        }
    }

    private var groupedShortcuts: [(category: ShortcutCategory, items: [ShortcutItem])] {
        if selectedCategory != .all {
            return [(selectedCategory, filteredShortcuts)]
        }

        let activeCategories = ShortcutCategory.allCases.filter { $0 != .all }
        return activeCategories.compactMap { cat in
            let items = filteredShortcuts.filter { $0.category == cat }
            return items.isEmpty ? nil : (cat, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            categoryFilterBar
            Divider()
                .opacity(0.4)

            if filteredShortcuts.isEmpty {
                emptyStateView
            } else {
                shortcutsList
            }
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 520, idealHeight: 600)
        .background(theme.primaryBackground)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "command.square.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.accentColor)

                    Text("Keyboard Shortcuts")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)
                }

                Text("\(filteredShortcuts.count) command\(filteredShortcuts.count == 1 ? "" : "s") available")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.tertiaryText)

                TextField("Search shortcuts or keys…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(theme.primaryText)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 240)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong, lineWidth: 0.8)
            )
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    // MARK: - Category Filter Bar

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ShortcutCategory.allCases) { category in
                    let isSelected = selectedCategory == category
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedCategory = category
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: category.icon)
                                .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            Text(category.rawValue)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? theme.accentColor : theme.surfaceOverlay.opacity(0.7))
                        )
                        .foregroundColor(isSelected ? .white : theme.secondaryText)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(isSelected ? Color.clear : theme.surfaceOverlayStrong, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Shortcuts List

    private var shortcutsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(groupedShortcuts, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        // Section Header
                        HStack(spacing: 6) {
                            Image(systemName: group.category.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.accentColor)

                            Text(group.category.rawValue)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(theme.primaryText)

                            Text("(\(group.items.count))")
                                .font(.caption2)
                                .foregroundColor(theme.tertiaryText)

                            Spacer()
                        }
                        .padding(.bottom, 2)

                        // Cards Container
                        VStack(spacing: 6) {
                            ForEach(group.items) { item in
                                ShortcutRowView(item: item, theme: theme)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(theme.tertiaryText.opacity(0.6))

            Text("No shortcuts found")
                .font(.headline)
                .foregroundColor(theme.primaryText)

            Text("No commands match “\(searchText)” in \(selectedCategory.rawValue).")
                .font(.subheadline)
                .foregroundColor(theme.secondaryText)

            Button("Clear Search") {
                searchText = ""
                selectedCategory = .all
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row View

private struct ShortcutRowView: View {
    let item: ShortcutItem
    let theme: any Theme
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Left: Title & Description
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    if let note = item.contextNote {
                        Text(note)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(theme.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(item.description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            // Right: Keycap Badges
            HStack(spacing: 4) {
                ForEach(Array(item.keys.enumerated()), id: \.offset) { _, key in
                    KeyCapView(key: key, theme: theme)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? theme.surfaceOverlayStrong : theme.surfaceOverlay.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isHovering ? theme.accentColor.opacity(0.3) : theme.surfaceOverlayStrong.opacity(0.6), lineWidth: 0.7)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - KeyCap View

private struct KeyCapView: View {
    let key: String
    let theme: any Theme

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 4)
            .frame(minWidth: minWidth)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.secondaryBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.surfaceOverlayStrong, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
    }

    private var minWidth: CGFloat {
        switch key {
        case "Space": return 44
        case "Esc": return 32
        case "1–9": return 32
        default: return 22
        }
    }

    private var horizontalPadding: CGFloat {
        key.count > 1 ? 6 : 4
    }
}
