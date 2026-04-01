//
//  SidebarComponents.swift
//  Devgentic
//
//  Created by Antigravity.
//

import SwiftUI

// MARK: - Sidebar Header View
/// The top header of a sidebar, displaying the title and an optional action button.
struct SidebarHeaderView: View {
    let title: String
    var buttonTitle: String? = nil
    var systemImage: String? = nil
    var shortcut: String? = nil
    var onAction: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            if let buttonTitle, let systemImage, let onAction {
                Button(action: onAction) {
                    HStack(spacing: 4) {
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(buttonTitle)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(theme.accentColor.opacity(0.15))
                    .foregroundColor(theme.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(shortcut != nil ? "\(buttonTitle) (\(shortcut!))" : buttonTitle)
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
                .foregroundColor(isFocused ? theme.accentColor : theme.secondaryText)
                .font(.system(size: 14))
                .animation(.easeInOut(duration: 0.2), value: isFocused)

            TextField(placeholder, text: $localText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onChange(of: localText) { _, newValue in
                    debouncedUpdate(newValue)
                }
                .onChange(of: searchText) { _, newValue in
                    // Sync back when parent clears search programmatically
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
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.surfaceOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isFocused ? theme.accentColor.opacity(0.5) : theme.surfaceOverlayStrong,
                    lineWidth: isFocused ? 1.0 : 0.5
                )
        )
        .shadow(
            color: isFocused ? theme.accentColor.opacity(0.15) : Color.clear,
            radius: 6, x: 0, y: 0
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

// MARK: - Sidebar Empty State (Optional Shared)
struct SidebarEmptyStateView: View {
    let title: String
    let subtitle: String
    var buttonTitle: String? = nil
    let systemImage: String
    var onAction: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.08), Color.purple.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 90, height: 90)

                Image(systemName: systemImage)
                    .font(.system(size: 36))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.7), Color.purple.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }

            if let buttonTitle, let onAction {
                Button(action: onAction) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text(buttonTitle)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
