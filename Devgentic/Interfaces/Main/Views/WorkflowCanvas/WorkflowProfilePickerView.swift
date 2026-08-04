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
    let existingNodeProfileIDs: Set<UUID>
    let workflowProfileID: UUID
    let onSelect: (BackendProfileModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var searchText = ""

    private var availableProfiles: [BackendProfileModel] {
        profiles.filter { profile in
            // Exclude the current workflow itself (prevent self-reference).
            // Other workflow profiles are allowed for sub-workflow nesting (P0-4).
            profile.id != workflowProfileID &&
            !existingNodeProfileIDs.contains(profile.id)
        }
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

    private var imageGenProfiles: [BackendProfileModel] {
        filteredProfiles.filter { $0.profileType == .imageGen }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
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
                    Text("No available profiles.")
                        .foregroundColor(theme.secondaryText)
                    Text("Create profiles first, then add them here.")
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
                            profileSection(title: "Agents", icon: ProfileType.agent.iconName, color: .green, profiles: agentProfiles)
                        }
                        if !botProfiles.isEmpty {
                            profileSection(title: "Bots", icon: ProfileType.bot.iconName, color: .blue, profiles: botProfiles)
                        }
                        if !workflowProfiles.isEmpty {
                            profileSection(title: "Workflows", icon: ProfileType.workflow.iconName, color: .purple, profiles: workflowProfiles)
                        }
                        if !imageGenProfiles.isEmpty {
                            profileSection(title: "Image Generators", icon: ProfileType.imageGen.iconName, color: .orange, profiles: imageGenProfiles)
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
    private func profileSection(title: String, icon: String, color: Color, profiles: [BackendProfileModel]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(color)

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
                Image(systemName: profile.profileType.iconName)
                    .foregroundColor(color)
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
