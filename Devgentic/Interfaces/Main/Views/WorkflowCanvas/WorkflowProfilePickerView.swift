// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowProfilePickerView.swift
//  Devgentic
//
//  Created by Raj Singh on 13/03/26.
//
//  Sheet view to select existing profiles (Bot/Agent) to add as nodes on the canvas.
//

import SwiftUI

struct WorkflowProfilePickerView: View {
    let profiles: [BackendProfileModel]
    let workflowProfileID: UUID
    /// False when embedded inside `WorkflowAddNodeSheet`, which draws its own header.
    var showsHeader: Bool = true
    let onSelect: (BackendProfileModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var searchText = ""

    /// The profile types this picker offers as workflow nodes.
    ///
    /// ⚠️ `.imageGen` is excluded BY PRODUCT DECISION (2026-08-16, WF-CS9): image generation is not
    /// supported as a workflow step, so it is not listed at all — not greyed out, not shown with an
    /// explanation. The RUNTIME backstops stay regardless of this list and must NOT be deleted on
    /// the strength of it: a layout SAVED BEFORE this change can still hold such a node, and
    /// `WorkflowCanvasState.load(from:)` replays the stored blob verbatim with no migration — a
    /// picker filter cannot reach it.
    ///
    /// ⚠️ An ALLOW-list, deliberately not `!= .imageGen`. `ProfileType` has FIVE cases and this
    /// picker renders FOUR sections, so `.code` profiles — which ARE real persisted rows, created
    /// the first time the Code interface opens — already passed this filter, counted toward the
    /// `availableProfiles.isEmpty` gate, and then rendered in NO section: an empty scroll view with
    /// no explanation. Naming what IS offered closes that hole with the same line, and leaves any
    /// future sixth `ProfileType` excluded until someone deliberately admits it.
    static let offerableProfileTypes: Set<ProfileType> = [.agent, .bot, .workflow]

    /// Hoisted out of `availableProfiles` so a test can reach it.
    ///
    /// ⚠️ Not tidiness: `availableProfiles` is `private`, which is file-scoped — `@testable`
    /// elevates *internal*, not private — and this project has no view-inspection harness, so a
    /// filter reachable only through `body` cannot be asserted at all.
    /// ⚠️ NO LONGER EXCLUDES PROFILES ALREADY ON THE CANVAS (2026-08-29). That exclusion existed
    /// because a node REFERENCED a shared profile, so a second node on the same profile meant two
    /// nodes editing each other's settings. Importing now COPIES into a node-owned row, so adding
    /// the same profile twice yields two independent nodes — which is the point: two
    /// differently-tuned Summarizers no longer require two entries in the profile library.
    ///
    /// The self-reference exclusion STAYS. A workflow that could add itself as a sub-workflow node
    /// is a cycle the run would have to refuse anyway, and sub-workflow nodes still reference rather
    /// than copy.
    static func offeredProfiles(
        from profiles: [BackendProfileModel],
        workflowProfileID: UUID
    ) -> [BackendProfileModel] {
        profiles.filter { profile in
            // Exclude the current workflow itself (prevent self-reference).
            // Other workflow profiles are allowed for sub-workflow nesting (P0-4).
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
                        .font(.title2)
                        .foregroundColor(theme.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add Profile to Workflow")
                            .font(.headline)
                            .foregroundColor(theme.primaryText)
                        Text("Select a profile to add as a node.")
                            .font(.caption)
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                }
                .padding()
                .background(theme.primaryBackground)

                Divider()
            }

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.secondaryText)
                TextField("Search profiles...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(theme.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Profile List
            if availableProfiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundColor(theme.secondaryText)
                    Text("No profiles to import from.")
                        .foregroundColor(theme.secondaryText)
                    Text("Go back and choose \u{201C}New node\u{201D} to build one from scratch instead.")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.primaryBackground)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !agentProfiles.isEmpty {
                            profileSection(title: "Agents", type: .agent, color: .green, profiles: agentProfiles)
                        }
                        if !botProfiles.isEmpty {
                            profileSection(title: "Bots", type: .bot, color: .blue, profiles: botProfiles)
                        }
                        if !workflowProfiles.isEmpty {
                            profileSection(title: "Workflows", type: .workflow, color: .purple, profiles: workflowProfiles)
                        }
                        if filteredProfiles.isEmpty && !searchText.isEmpty {
                            Text("No matches for \"\(searchText)\"")
                                .foregroundColor(theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        }
                    }
                    .padding()
                }
                .background(theme.primaryBackground)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(theme.secondaryBackground)
        }
        .frame(width: 420, height: 480)
    }

    @ViewBuilder
    private func profileSection(title: String, type: ProfileType, color: Color, profiles: [BackendProfileModel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProfileTypeIcon(type: type, size: 14, color: color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
            }

            ForEach(profiles) { profile in
                pickableProfileRow(profile: profile, color: color)
            }
        }
    }

    @ViewBuilder
    private func pickableProfileRow(profile: BackendProfileModel, color: Color) -> some View {
        Button {
            onSelect(profile)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ProfileTypeIcon(type: profile.profileType, size: 18, color: color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(theme.fontSubheadline.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Text(profile.profileType.localizedTitle)
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                Image(systemName: "plus.circle")
                    .foregroundColor(theme.accentColor)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
