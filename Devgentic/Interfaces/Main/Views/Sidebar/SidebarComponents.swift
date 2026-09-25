// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SidebarComponents.swift
//  Devgentic
//
//  Created by Antigravity.
//

import SwiftUI

// MARK: - Header Action Button Component
struct SidebarHeaderActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var shortcut: String? = nil
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(theme.fontCaption2.weight(.bold))
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(theme.fontCaption2.weight(.semibold))
                    .foregroundColor(theme.primaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isHovered ? theme.accentColor.opacity(0.45) : theme.secondaryText.opacity(0.18),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? theme.accentColor.opacity(0.15) : theme.shadowColor.opacity(0.3),
                radius: isHovered ? 4 : 2,
                x: 0,
                y: 1
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
        .help(shortcut != nil ? "\(title) (\(shortcut!))" : title)
        .accessibilityLabel(shortcut != nil ? "\(title) (\(shortcut!))" : title)
    }
}

// MARK: - Sidebar Header View
/// The top header of a sidebar, displaying the title and an optional action button.
struct SidebarHeaderView: View {
    let title: LocalizedStringKey
    var buttonTitle: LocalizedStringKey? = nil
    var systemImage: String? = nil
    var shortcut: String? = nil
    var onAction: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            Text(title)
                .font(theme.fontBody.weight(.semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            if let buttonTitle, let systemImage, let onAction {
                SidebarHeaderActionButton(
                    title: buttonTitle,
                    systemImage: systemImage,
                    shortcut: shortcut,
                    action: onAction
                )
            }
        }
    }
}

// MARK: - Sidebar Search Bar
/// A self-contained search bar that manages its own focus state and debounces input.
struct SidebarSearchBarView: View {
    let placeholder: String
    @Binding var searchText: String

    @State private var localText: String = ""
    @FocusState private var isFocused: Bool
    @Environment(\.appTheme) private var theme

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._searchText = text
        self._localText = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(isFocused ? theme.accentColor : theme.tertiaryText)
                .font(theme.fontFootnote.weight(.semibold))
                .animation(.easeInOut(duration: 0.2), value: isFocused)
                .accessibilityHidden(true)

            TextField("", text: $localText, prompt: Text(placeholder).foregroundColor(theme.placeholderText))
                .textFieldStyle(.plain)
                .font(theme.fontFootnote)
                .foregroundStyle(theme.primaryText)
                .focused($isFocused)
                .onChange(of: localText) { _, newValue in
                    debouncedUpdate(newValue)
                }
                .onChange(of: searchText) { _, newValue in
                    if newValue != localText {
                        localText = newValue
                    }
                }

            if !localText.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        localText = ""
                        searchText = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .pointingHandCursor()
                .accessibilityLabel("Clear search")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surfaceOverlayStrong.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFocused ? theme.accentColor.opacity(0.55) : theme.dividerColor.opacity(0.35),
                    lineWidth: 0.5
                )
        )
        .shadow(
            color: isFocused ? theme.accentColor.opacity(0.2) : Color.clear,
            radius: 5, x: 0, y: 1
        )
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .onDisappear { debounceTask?.cancel() }
    }

    // MARK: - Debounce (300ms)

    @State private var debounceTask: Task<Void, Never>?

    private func debouncedUpdate(_ value: String) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searchText = value
        }
    }
}

// MARK: - Batch Header Text Button

/// Text-only toolbar button used by sidebar batch-selection headers
/// (Prompt Library, Conversations, etc.). Adds a subtle pill-shaped hover
/// fill so the tap target is discoverable instead of looking like static
/// caption text. Tint is parameterized so a secondary "Cancel" reads as
/// muted while a primary "Select All" picks up the accent color.
struct BatchHeaderTextButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.fontCaption.weight(.medium))
                .foregroundColor(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? theme.surfaceOverlay : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isHovered ? theme.surfaceOverlayStrong.opacity(0.5) : Color.clear, lineWidth: 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Shared Category Chip (Filter Bubble)
struct CategoryChip: View {
    /// ⚠️ `LocalizedStringKey`, not `String`. As a `String` this went to the non-localizing
    /// `Text` overload, so every filter chip in the app shipped untranslated (audit C2).
    /// Callers with a genuinely runtime title must model it as an enum rather than reaching
    /// for `LocalizedStringKey(someString)`, which the extractor cannot see either.
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    private var textColor: Color {
        if isSelected { return theme.primaryText }
        return isHovered ? theme.primaryText : theme.secondaryText
    }

    private var fillColor: Color {
        if isSelected { return theme.surfaceOverlayStrong }
        return isHovered ? theme.surfaceOverlay : theme.surfaceOverlay.opacity(0.4)
    }

    private var strokeColor: Color {
        if isSelected { return theme.accentColor.opacity(0.55) }
        return isHovered ? theme.secondaryText.opacity(0.25) : theme.secondaryText.opacity(0.12)
    }

    private var shadowColor: Color {
        if isSelected { return theme.accentColor.opacity(0.18) }
        return isHovered ? theme.shadowColor.opacity(0.35) : Color.clear
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(theme.fontCaption2.weight(isSelected ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundColor(textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(fillColor)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(strokeColor, lineWidth: 1)
                )
                .shadow(
                    color: shadowColor,
                    radius: isSelected ? 5 : 3,
                    x: 0,
                    y: 1
                )
                .scaleEffect(isHovered ? 1.04 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isSelected)
    }
}

// MARK: - Sidebar Empty State (Optional Shared)
struct SidebarEmptyStateView: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var buttonTitle: LocalizedStringKey? = nil
    let systemImage: String
    var onAction: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.12), theme.accentColor.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)

                Image(systemName: systemImage)
                    .font(.system(size: 36)) // Fixed size: intentional (empty state icon)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.accentColor, theme.accentColor.opacity(0.65)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(theme.fontTitle3.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Text(subtitle)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if let buttonTitle, let onAction {
                Button(action: onAction) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(theme.fontSubheadline.weight(.bold))
                            .foregroundColor(theme.accentColor)
                        Text(buttonTitle)
                            .font(theme.fontSubheadline.weight(.semibold))
                            .foregroundColor(theme.primaryText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isHovered ? theme.accentColor.opacity(0.55) : theme.accentColor.opacity(0.35),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: isHovered ? theme.accentColor.opacity(0.2) : theme.shadowColor.opacity(0.3),
                        radius: isHovered ? 6 : 4,
                        x: 0,
                        y: 2
                    )
                    .scaleEffect(isHovered ? 1.03 : 1.0)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .onHover { hovering in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                        isHovered = hovering
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Standard Sidebar Row Background
struct SidebarRowBackground: View {
    let isSelected: Bool
    let isHovering: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
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
        } else {
            Color.clear
        }
    }
}

extension View {
    /// Applies the canonical Devgentic sidebar interactive row plate (10pt continuous corner radius,
    /// dynamic accent tint when selected, and smooth surface overlay on hover).
    func sidebarRowBackground(isSelected: Bool = false, isHovering: Bool) -> some View {
        self
            .background(SidebarRowBackground(isSelected: isSelected, isHovering: isHovering))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
