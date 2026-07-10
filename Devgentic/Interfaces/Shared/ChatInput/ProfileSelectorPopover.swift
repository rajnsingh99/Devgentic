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

    /// Fixed content width — deterministic NSPopover sizing (the structural fix).
    private let popoverWidth: CGFloat = 320
    private let listMaxHeight: CGFloat = 320

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
            Divider().background(theme.dividerColor.opacity(0.3))
            profileList
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: popoverWidth)
        .onAppear {
            profiles = (try? BackendProfileStore.shared.fetchProfiles()) ?? []
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
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .font(theme.fontSubheadline)
                .foregroundColor(theme.primaryText)
                .focused($isSearchFocused)
                .accessibilityLabel("Search profiles")
                .overlay(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search profiles")
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.placeholderText)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(theme.surfaceOverlay.opacity(0.6)))
        .padding(.horizontal, 10)
    }

    // MARK: - Type bubbles

    private var typeBubbleRow: some View {
        HStack(spacing: 6) {
            ForEach(availableTypes, id: \.self) { type in
                typeBubble(type)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private func typeBubble(_ type: ProfileType) -> some View {
        let isActive = selectedType == type
        let count = profiles(of: type).count
        return Button(action: { selectedType = type }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(type.displayColor)
                    .frame(width: 6, height: 6)
                Text(Self.bubbleTitle(for: type))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isActive ? theme.primaryText.opacity(0.7) : theme.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isActive ? theme.accentColor.opacity(0.18) : theme.surfaceOverlay.opacity(0.5)))
            .overlay(Capsule().stroke(isActive ? theme.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(Self.bubbleTitle(for: type)), \(count) profiles\(isActive ? ", selected" : "")")
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
            VStack(spacing: 6) {
                Image(systemName: searchText.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass")
                    .font(.title3)
                    .foregroundColor(theme.tertiaryText)
                Text(searchText.isEmpty ? "No profiles of this type yet" : "No matches")
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.secondaryText)
                if searchText.isEmpty {
                    Text("Create one in the Backend Profiles panel.")
                        .font(.caption)
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                VStack(spacing: 1) {
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
                .padding(.vertical, 2)
            }
            .frame(maxHeight: listMaxHeight)
        }
    }

    fileprivate static func detailText(for profile: BackendProfileModel) -> String? {
        switch profile.details {
        case .bot(let config): return config.llmConfig.modelName
        case .agent(let config): return config.llmConfig.modelName
        case .workflow(let config):
            let count = config.agentProfileIDs.count
            return count == 1 ? "1 node" : "\(count) nodes"
        case .imageGen(let config): return config.llmConfig.modelName
        case .code(let config): return config.llmConfig.modelName
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
            HStack(spacing: 8) {
                Circle()
                    .fill(profile.profileType.displayColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(theme.fontSubheadline.weight(.medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let detail = ProfileSelectorPopover.detailText(for: profile), !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(.caption))
                        .foregroundColor(theme.accentColor)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected
                          ? theme.accentColor.opacity(0.15)
                          : (isHovering ? theme.surfaceOverlay : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.1)) { isHovering = hover }
        }
        .padding(.horizontal, 8)
        .accessibilityLabel("\(profile.displayName)\(isSelected ? ", selected" : "")")
    }
}
