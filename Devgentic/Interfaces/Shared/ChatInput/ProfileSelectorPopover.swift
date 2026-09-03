//
//  ProfileSelectorPopover.swift
//  Devgentic
//
//  Redesigned profile selector (v2 of BackendSelectorPopup): a fixed-width popover with a
//  search field, a horizontal type-bubble row (Bot / Agent / Workflow / Image Gen — filtered
//  by `allowedProfileTypes`), and a single scrolling list of the selected type's profiles.
//
//  Why the redesign: the old BackendSelectorPopup rendered one COLUMN per type (minWidth 180
//  each), so with two+ types its minimum width (360pt+) exceeded what the NSPopover resolved
//  from the call site's `.frame(minWidth: 240)` + `.fixedSize(horizontal: false)` — the content
//  overflowed and clipped on both sides (the "truncated / half-rendered" bug). A single column
//  at a FIXED width makes the popover size deterministic, and search + type bubbles scale
//  better as profile counts grow.
//
//  Used by ALL profile pickers: the QuickAccess panel chip (directly) and the main composer +
//  QuickAccess Settings (via BackendPickerButton). Replaces the deleted BackendSelectorPopup.
//

import SwiftUI

struct ProfileSelectorPopover: View {

    // Same contract as BackendSelectorPopup, so call sites can swap 1:1.
    var configuration: BackendConfiguration
    @Binding var isPresented: Bool
    /// Profile types to offer. nil = all picker types (bot/agent/workflow/imageGen).
    var allowedProfileTypes: Set<ProfileType>? = nil

    @Environment(\.appTheme) private var theme

    @State private var profiles: [BackendProfileModel] = []
    @State private var searchText: String = ""
    @State private var selectedType: ProfileType = .bot
    @FocusState private var isSearchFocused: Bool

    /// Fixed content width & height — matching CodeModelSelectorPopover 1:1 (340 x 440).
    private let popoverWidth: CGFloat = 340
    private let listMaxHeight: CGFloat = 330

    /// Picker-facing types in display order (`.code` is never offered, matching the old popup).
    private var availableTypes: [ProfileType] {
        let order: [ProfileType] = [.bot, .agent, .workflow, .imageGen]
        guard let allowed = allowedProfileTypes else { return order }
        return order.filter { allowed.contains($0) }
    }

    private func profiles(of type: ProfileType) -> [BackendProfileModel] {
        profiles.filter { $0.profileType == type }.sorted { $0.displayName < $1.displayName }
    }

    private var visibleProfiles: [BackendProfileModel] {
        let base = profiles(of: selectedType)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || (Self.detailText(for: $0)?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            searchField
            typeBubbleRow
            Rectangle()
                .fill(theme.dividerColor.opacity(0.25))
                .frame(height: 1)
                .padding(.horizontal, 10)
            profileList
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: popoverWidth, height: 440)
        .onAppear {
            profiles = (try? BackendProfileStore.shared.fetchSharedProfiles()) ?? []
            // Land on the current selection's type so the highlighted row is visible immediately.
            if let id = configuration.selectedProfileID,
               let current = profiles.first(where: { $0.id == id }),
               availableTypes.contains(current.profileType) {
                selectedType = current.profileType
            } else if let first = availableTypes.first {
                selectedType = first
            }
            DispatchQueue.main.async { isSearchFocused = true }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isSearchFocused ? theme.accentColor : theme.tertiaryText)

            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .font(theme.fontSubheadline)
                .foregroundColor(theme.primaryText)
                .focused($isSearchFocused)
                .accessibilityLabel("Search profiles")
                .overlay(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search profiles...")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceOverlayStrong)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSearchFocused ? theme.accentColor.opacity(0.55) : theme.secondaryText.opacity(0.18),
                    lineWidth: 1
                )
        )
        .shadow(color: isSearchFocused ? theme.accentColor.opacity(0.2) : Color.black.opacity(0.1), radius: 4)
        .padding(.horizontal, 12)
    }

    // MARK: - Type bubbles

    private var typeBubbleRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableTypes, id: \.self) { type in
                    TypeBubbleView(
                        type: type,
                        count: profiles(of: type).count,
                        isActive: selectedType == type,
                        action: { selectedType = type }
                    )
                }
            }
            .padding(.horizontal, 12)
        }
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

    // MARK: - List

    @ViewBuilder
    private var profileList: some View {
        if visibleProfiles.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: searchText.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass")
                    .font(.system(size: 26))
                    .foregroundColor(theme.tertiaryText)
                Text(searchText.isEmpty ? "No profiles of this type yet" : "No matches found")
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                if searchText.isEmpty {
                    Text("Create one in the Backend Profiles panel.")
                        .font(.caption)
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 36)
        } else {
            ScrollView(showsIndicators: true) {
                VStack(spacing: 6) {
                    ForEach(visibleProfiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isSelected: configuration.selectedProfileID == profile.id,
                            onSelect: {
                                configuration.selectedProfileID = profile.id
                                isPresented = false
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 12)
            }
            .frame(maxHeight: listMaxHeight)
        }
    }

    fileprivate static func detailText(for profile: BackendProfileModel) -> String? {
        switch profile.details {
        case .bot(let config): return config.llmConfig.modelName
        case .agent(let config): return config.llmConfig.modelName
        case .workflow:
            // ⚠️ Reads the LAYOUT's denormalized count, not `WorkflowConfig.agentProfileIDs`. That
            // field is retired, and it was never right for this label anyway: it only ever counted
            // PROFILE nodes, so a workflow of Routers, Code, Gates and Actions reported "0 nodes".
            let count = WorkflowLayoutStore.shared.storedCounts(for: profile.id).nodes
            return count == 1 ? "1 node" : "\(count) nodes"
        case .imageGen(let config): return config.llmConfig.modelName
        case .code(let config): return config.llmConfig.modelName
        }
    }
}

// MARK: - Type Bubble Component

private struct TypeBubbleView: View {
    let type: ProfileType
    let count: Int
    let isActive: Bool
    let action: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(type.displayColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: type.displayColor.opacity(0.8), radius: 3)

                Text(bubbleTitle)
                    .font(.system(size: 12, weight: isActive ? .bold : .medium))
                    .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)

                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(isActive ? theme.primaryText.opacity(0.85) : theme.tertiaryText)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill(isActive ? type.displayColor.opacity(0.25) : theme.surfaceOverlayStrong)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isActive ? type.displayColor.opacity(0.18) : (isHovered ? theme.surfaceOverlayStrong : theme.surfaceOverlay))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? type.displayColor.opacity(0.65) : (isHovered ? theme.secondaryText.opacity(0.3) : Color.clear),
                        lineWidth: 1
                    )
            )
            .shadow(color: isActive ? type.displayColor.opacity(0.25) : .clear, radius: 4)
            .scaleEffect(isHovered ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovered = h }
        }
    }

    private var bubbleTitle: String {
        switch type {
        case .bot: return String(localized: "Bots")
        case .agent: return String(localized: "Agents")
        case .workflow: return String(localized: "Workflows")
        case .imageGen: return String(localized: "Image Gen")
        case .code: return String(localized: "Code")
        }
    }
}

// MARK: - Row

private struct ProfileRow: View {
    let profile: BackendProfileModel
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(profile.profileType.displayColor.opacity(isHovering || isSelected ? 0.25 : 0.12))
                        .frame(width: 24, height: 24)
                        .shadow(color: isHovering ? profile.profileType.displayColor.opacity(0.4) : .clear, radius: 4)

                    Circle()
                        .fill(profile.profileType.displayColor)
                        .frame(width: 7, height: 7)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let detail = ProfileSelectorPopover.detailText(for: profile), !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.accentColor)
                        .shadow(color: theme.accentColor.opacity(0.5), radius: 4)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected
                          ? theme.accentColor.opacity(0.16)
                          : (isHovering ? theme.surfaceOverlayStrong : theme.surfaceOverlay.opacity(0.4)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? theme.accentColor.opacity(0.55)
                            : (isHovering ? theme.secondaryText.opacity(0.3) : Color.clear),
                        lineWidth: 1
                    )
            )
            .shadow(color: isSelected ? theme.accentColor.opacity(0.2) : (isHovering ? Color.black.opacity(0.15) : .clear), radius: 5, y: 2)
            .scaleEffect(isHovering ? 1.015 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { isHovering = hover }
        }
        .accessibilityLabel("\(profile.displayName)\(isSelected ? ", selected" : "")")
    }
}
