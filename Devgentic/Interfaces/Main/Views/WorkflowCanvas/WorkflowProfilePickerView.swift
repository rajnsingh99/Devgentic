// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowProfilePickerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Sheet that lists existing profiles (agent, bot, workflow) to add as nodes on the workflow canvas.
struct WorkflowProfilePickerView: View {
    let profiles: [BackendProfileModel]
    let workflowProfileID: UUID
    /// False when embedded inside `WorkflowAddNodeSheet`, which draws its own header.
    var showsHeader: Bool = true
    var showsFooter: Bool? = nil
    let onSelect: (BackendProfileModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var searchText = ""

    private var effectiveShowsFooter: Bool {
        showsFooter ?? showsHeader
    }

    // Why: runtime backstops for excluded node types stay: a saved layout can still hold one and the loader replays it
    // verbatim.
    /// The profile types this picker offers as workflow nodes. An allow-list rather than `!= .imageGen`, so a profile
    /// type with no picker section (such as `.code`) is never offered and new types stay excluded.
    static let offerableProfileTypes: Set<ProfileType> = [.agent, .bot, .workflow]

    // Why: internal rather than private so a test can assert the filter; a filter reachable only through `body` cannot
    // be tested.
    /// Returns the profiles to offer, excluding the current workflow itself (a self-reference would be a cycle).
    /// Profiles already on the canvas stay offered, since importing copies into a node-owned row; sub-workflow nodes
    /// still reference.
    static func offeredProfiles(
        from profiles: [BackendProfileModel],
        workflowProfileID: UUID
    ) -> [BackendProfileModel] {
        profiles.filter { profile in
            // Exclude the current workflow itself to prevent self-reference; other workflows are allowed for sub-workflow
            // nesting.
            profile.id != workflowProfileID
                && offerableProfileTypes.contains(profile.profileType)
        }
    }

    private var availableProfiles: [BackendProfileModel] {
        Self.offeredProfiles(from: profiles,
                             workflowProfileID: workflowProfileID)
    }

    private var filteredProfiles: [BackendProfileModel] {
        if searchText.isEmpty { return availableProfiles }
        return availableProfiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var botProfiles: [BackendProfileModel] {
        filteredProfiles.filter { $0.profileType == .bot }
    }

    private var agentProfiles: [BackendProfileModel] {
        filteredProfiles.filter { $0.profileType == .agent }
    }

    private var workflowProfiles: [BackendProfileModel] {
        filteredProfiles.filter { $0.profileType == .workflow }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — suppressed when embedded in `WorkflowAddNodeSheet`, which draws its own
            // (with a Back control); two stacked headers read as a broken sheet.
            if showsHeader {
                HStack(spacing: 12) {
                    Image(systemName: "plus.square.on.square")
                        .font(theme.fontTitle2)
                        .foregroundStyle(theme.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Profile to Workflow")
                            .font(theme.fontHeadline)
                            .foregroundStyle(theme.primaryText)
                        Text("Select a profile to add as a node.")
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    TactileButton(title: "Cancel", variant: .subtle, size: .compact) {
                        dismiss()
                    }
                }
                .padding()
                .background(theme.primaryBackground)

                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)
            }

            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                TextField("", text: $searchText, prompt: Text("Search profiles").foregroundColor(theme.placeholderText))
                    .textFieldStyle(.plain)
                    .font(theme.fontFootnote)
                    .foregroundStyle(theme.primaryText)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(theme.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.dividerColor.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Rectangle()
                .fill(theme.dividerColor.opacity(0.3))
                .frame(height: 0.5)

            // Profile List
            if availableProfiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundStyle(theme.secondaryText)
                    Text("No profiles to import from")
                        .font(theme.fontSubheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    Text("Go back and choose \u{201C}New node\u{201D} to build one from scratch instead.")
                        .font(theme.fontCaption)
                        .foregroundStyle(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(theme.primaryBackground)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !agentProfiles.isEmpty {
                            profileSection(title: "Agents", type: .agent, profiles: agentProfiles)
                        }
                        if !botProfiles.isEmpty {
                            profileSection(title: "Bots", type: .bot, profiles: botProfiles)
                        }
                        if !workflowProfiles.isEmpty {
                            profileSection(title: "Workflows", type: .workflow, profiles: workflowProfiles)
                        }
                        if filteredProfiles.isEmpty && !searchText.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 24))
                                    .foregroundStyle(theme.tertiaryText)
                                Text("No matches for \"\(searchText)\"")
                                    .font(theme.fontFootnote)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(theme.primaryBackground)
            }

            // Footer (only shown in standalone mode; suppressed when embedded in WorkflowAddNodeSheet)
            if effectiveShowsFooter {
                Rectangle()
                    .fill(theme.dividerColor.opacity(0.3))
                    .frame(height: 0.5)

                HStack {
                    Spacer()
                    TactileButton(title: "Cancel", variant: .subtle, size: .compact) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding()
                .background(theme.secondaryBackground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(width: showsHeader ? 480 : nil, height: showsHeader ? 520 : nil)
    }

    @ViewBuilder
    private func profileSection(title: String, type: ProfileType, profiles: [BackendProfileModel]) -> some View {
        let color = type.displayColor
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProfileTypeIcon(type: type, size: 13, color: color)
                Text(title)
                    .font(theme.fontCaption.weight(.semibold))
                    .foregroundStyle(color)

                Text("\(profiles.count)")
                    .font(theme.fontCaption2.weight(.medium))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(theme.surfaceOverlay)
                    )
            }
            .padding(.leading, 2)

            ForEach(profiles) { profile in
                pickableProfileRow(profile: profile, color: color)
            }
        }
    }

    @ViewBuilder
    private func pickableProfileRow(profile: BackendProfileModel, color: Color) -> some View {
        PickableProfileCard(
            profile: profile,
            color: color,
            onSelect: {
                onSelect(profile)
                dismiss()
            }
        )
    }
}

// MARK: - Pickable Profile Card

private struct PickableProfileCard: View {
    let profile: BackendProfileModel
    let color: Color
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(isHovered ? 0.20 : 0.12))
                        .frame(width: 34, height: 34)
                    ProfileTypeIcon(type: profile.profileType, size: 18, color: color)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(theme.fontFootnote.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(profile.profileType.localizedTitle)
                            .font(theme.fontCaption2)
                            .foregroundStyle(theme.secondaryText)

                        if let model = profile.resolvedLLMConfig?.modelName, !model.isEmpty {
                            Text("•")
                                .font(theme.fontCaption2)
                                .foregroundStyle(theme.tertiaryText)
                            Text(model)
                                .font(theme.fontCaption2)
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("Import")
                        .font(theme.fontCaption.weight(.medium))
                }
                .foregroundStyle(isHovered ? theme.accentColor : theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isHovered ? theme.accentColor.opacity(0.12) : theme.surfaceOverlay)
                )
                .overlay(
                    Capsule()
                        .stroke(isHovered ? theme.accentColor.opacity(0.4) : theme.dividerColor.opacity(0.25), lineWidth: 0.75)
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? theme.surfaceOverlayStrong : theme.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isHovered ? color.opacity(0.4) : theme.dividerColor.opacity(0.25), lineWidth: 1)
            )
            .shadow(color: isHovered ? theme.shadowColor.opacity(0.12) : .clear, radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { isHovered = $0 }
    }
}
