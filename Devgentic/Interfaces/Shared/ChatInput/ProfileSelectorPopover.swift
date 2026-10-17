// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileSelectorPopover.swift
//  Devgentic
//
//  Redesigned profile selector aligned with the Antigravity macOS UI:
//  - Solid, clean surface background (no blurry glass bleed-through).
//  - Minimal header and compact category pills.
//  - Streamlined search input.
//  - Clean list rows with model metadata and right-aligned checkmarks.
//  - Subtle full-width hover highlight (no bouncy scaling).
//  - Actionable footer row ("Manage Profiles...") separated by a hairline divider.
//

import SwiftUI
import AppKit

struct ProfileSelectorPopover: View {

    var configuration: BackendConfiguration
    @Binding var isPresented: Bool
    /// Profile types to offer. nil = all picker types (bot/agent/workflow/imageGen).
    var allowedProfileTypes: Set<ProfileType>? = nil
    /// Optional callback to navigate to profile management / settings.
    var onManageProfiles: (() -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @Environment(\.surfaceStyle) private var surfaceStyle

    @State private var profiles: [BackendProfileModel] = []
    @State private var searchText: String = ""
    @State private var selectedType: ProfileType? = nil // nil = "All"
    @FocusState private var isSearchFocused: Bool

    /// Popover dimensions: width +15% (356pt), height doubled (+100%) to 460pt.
    private let popoverWidth: CGFloat = 356
    private let popoverHeight: CGFloat = 460

    /// Picker-facing types in display order (`.code` is managed by CodeModelPickerButton).
    private var availableTypes: [ProfileType] {
        let order: [ProfileType] = [.bot, .agent, .workflow, .imageGen]
        guard let allowed = allowedProfileTypes else { return order }
        return order.filter { allowed.contains($0) }
    }

    private func profiles(of type: ProfileType) -> [BackendProfileModel] {
        profiles.filter { $0.profileType == type }.sorted { $0.displayName < $1.displayName }
    }

    private var visibleProfiles: [BackendProfileModel] {
        let base: [BackendProfileModel]
        if let selectedType {
            base = profiles.filter { $0.profileType == selectedType }
        } else {
            base = profiles.filter { availableTypes.contains($0.profileType) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return base.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
        return base.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || (Self.detailText(for: $0)?.localizedCaseInsensitiveContains(query) ?? false)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if availableTypes.count > 1 {
                typeSegmentRow
                    .padding(.bottom, 6)
            }

            searchField
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            Rectangle()
                .fill(theme.isDark ? Color.white.opacity(0.08) : theme.dividerColor.opacity(0.35))
                .frame(height: 1)
                .padding(.horizontal, 8)

            profileList

            if let onManageProfiles {
                Rectangle()
                    .fill(theme.isDark ? Color.white.opacity(0.08) : theme.dividerColor.opacity(0.35))
                    .frame(height: 1)
                    .padding(.horizontal, 8)

                Button {
                    isPresented = false
                    onManageProfiles()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                        Text("Manage Profiles…")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popoverRowHighlight()
            }
        }
        .padding(.vertical, 8)
        .frame(width: popoverWidth, height: popoverHeight)
        .background {
            if surfaceStyle == .solid {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.secondaryBackground)
            }
        }
        .onAppear {
            profiles = (try? BackendProfileStore.shared.fetchSharedProfiles()) ?? []
            // Default to "All" so the active selection is visible immediately in the list
            selectedType = nil
            DispatchQueue.main.async { isSearchFocused = true }
        }
    }

    // MARK: - Type Filter Segment Row

    private var typeSegmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                SegmentTabButton(
                    title: String(localized: "All"),
                    count: profiles.filter { availableTypes.contains($0.profileType) }.count,
                    isSelected: selectedType == nil
                ) {
                    selectedType = nil
                }

                ForEach(availableTypes, id: \.self) { type in
                    SegmentTabButton(
                        title: Self.bubbleTitle(for: type),
                        count: profiles(of: type).count,
                        isSelected: selectedType == type
                    ) {
                        selectedType = type
                    }
                }
            }
            .padding(2.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.isDark ? Color.white.opacity(0.08) : theme.dividerColor.opacity(0.35), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 8)
    }

    private static func bubbleTitle(for type: ProfileType) -> String {
        switch type {
        case .bot: return String(localized: "Bots")
        case .agent: return String(localized: "Agents")
        case .workflow: return String(localized: "Workflows")
        case .imageGen: return String(localized: "Image Gen")
        case .code: return String(localized: "Code")
        }
    }

    // MARK: - Search Field

    private var searchBorderColor: Color {
        if isSearchFocused {
            return theme.accentColor.opacity(0.70)
        } else {
            return theme.isDark ? Color.white.opacity(0.07) : theme.dividerColor.opacity(0.35)
        }
    }

    private var searchIconColor: Color {
        if isSearchFocused {
            return theme.accentColor
        } else {
            return theme.tertiaryText
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(searchIconColor)

            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .focused($isSearchFocused)
                .overlay(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search profiles...")
                            .font(.system(size: 12))
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                    }
                }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(searchBorderColor, lineWidth: 1)
        )
    }

    // MARK: - Profile List

    @ViewBuilder
    private var profileList: some View {
        if visibleProfiles.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: searchText.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundColor(theme.tertiaryText)
                Text(searchText.isEmpty ? "No profiles found" : "No matches for \"\(searchText)\"")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 24)
        } else {
            ScrollView(showsIndicators: true) {
                VStack(spacing: 1) {
                    ForEach(visibleProfiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isSelected: configuration.selectedProfileID == profile.id,
                            onSelect: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                configuration.selectedProfileID = profile.id
                                isPresented = false
                            }
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    fileprivate static func detailText(for profile: BackendProfileModel) -> String? {
        switch profile.details {
        case .bot(let config): return config.llmConfig.modelName
        case .agent(let config): return config.llmConfig.modelName
        case .workflow:
            let count = WorkflowLayoutStore.shared.storedCounts(for: profile.id).nodes
            return count == 1 ? "1 node" : "\(count) nodes"
        case .imageGen(let config): return config.llmConfig.modelName
        case .code(let config): return config.llmConfig.modelName
        }
    }
}

// MARK: - Antigravity-Aligned Profile Row

private struct ProfileRow: View {
    let profile: BackendProfileModel
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var rowBackground: Color {
        if isHovering {
            return theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
        } else if isSelected {
            return theme.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
        } else {
            return Color.clear
        }
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Subtle 6pt identity dot for the profile type
                Circle()
                    .fill(profile.profileType.displayColor)
                    .frame(width: 6, height: 6)

                // Profile display name
                Text(profile.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Secondary metadata: model name or node count
                if let detail = ProfileSelectorPopover.detailText(for: profile), !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                // Subtle type badge pill (e.g. "Agent", "Bot", "Workflow")
                Text(profile.profileType.shortTitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.secondaryText.opacity(0.85))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.04))
                    )

                // Right-aligned Checkmark (matching Antigravity ✓)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.1)) { isHovering = hover }
        }
        .accessibilityLabel("\(profile.displayName)\(isSelected ? ", selected" : "")")
    }
}

private extension ProfileType {
    var shortTitle: String {
        switch self {
        case .bot: return "Bot"
        case .agent: return "Agent"
        case .workflow: return "Workflow"
        case .imageGen: return "Image"
        case .code: return "Code"
        }
    }
}

// MARK: - Segment Tab Button

private struct SegmentTabButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var badgeBackground: Color {
        if isSelected {
            return theme.isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)
        } else {
            return theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
        }
    }

    private var tabBackground: Color {
        if isSelected {
            return theme.isDark ? Color.white.opacity(0.12) : Color.white.opacity(0.70)
        } else if isHovering {
            return theme.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04)
        } else {
            return Color.clear
        }
    }

    private var tabBorder: Color {
        if isSelected {
            return theme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
        } else {
            return Color.clear
        }
    }

    var body: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            action()
        }) {
            HStack(spacing: 4.5) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? theme.primaryText : theme.secondaryText)

                Text("\(count)")
                    .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? theme.primaryText.opacity(0.9) : theme.tertiaryText)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(badgeBackground)
                    )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tabBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tabBorder, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.12)) { isHovering = hover }
        }
    }
}

