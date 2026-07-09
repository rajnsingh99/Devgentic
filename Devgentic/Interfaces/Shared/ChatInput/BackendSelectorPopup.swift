//
//  BackendSelectorPopup.swift
//  Devgentic
//
//  Created by Raj Singh on 05/07/25.
//

import SwiftUI
import os

// MARK: - Main Popup View
struct BackendSelectorPopup: View {

    // MARK: - State Bindings
    var configuration: BackendConfiguration
    @Binding var isPresented: Bool

    /// Profile types to display. When nil, shows all types (legacy behavior).
    /// Populated from `MainApplicationViewModel.interfaceMode.allowedProfileTypes`.
    var allowedProfileTypes: Set<ProfileType>? = nil

    @Environment(\.appTheme) private var theme

    // MARK: - Data Source
    @State private var profiles: [BackendProfileModel] = []

    // MARK: - Computed Properties for Data Filtering
    private var filteredProfiles: [BackendProfileModel] {
        guard let allowed = allowedProfileTypes else { return profiles }
        return profiles.filter { allowed.contains($0.profileType) }
    }
    private var botProfiles: [BackendProfileModel] {
        filteredProfiles.filter { $0.profileType == .bot }.sorted { $0.displayName < $1.displayName }
    }
    private var agentProfiles: [BackendProfileModel] {
        filteredProfiles.filter { $0.profileType == .agent }.sorted { $0.displayName < $1.displayName }
    }
    private var workflowProfiles: [BackendProfileModel] {
        filteredProfiles.filter { $0.profileType == .workflow }.sorted { $0.displayName < $1.displayName }
    }
    private var imageGenProfiles: [BackendProfileModel] {
        filteredProfiles.filter { $0.profileType == .imageGen }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        Group {
            if filteredProfiles.isEmpty {
                emptyState
            } else {
                columns
            }
        }
        .padding(.vertical, 8)
        .frame(maxHeight: 450)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            self.profiles = (try? BackendProfileStore.shared.fetchProfiles()) ?? []
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.title3)
                .foregroundColor(theme.tertiaryText)
            Text("No profiles available")
                .font(theme.fontSubheadline)
                .foregroundColor(theme.secondaryText)
            Text("Create one in the Backend Profiles panel.")
                .font(.caption)
                .foregroundColor(theme.tertiaryText)
        }
        .padding(24)
        .frame(minWidth: 220)
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            let showBots = !botProfiles.isEmpty
            let showAgents = !agentProfiles.isEmpty
            let showWorkflows = !workflowProfiles.isEmpty
            let showImageGen = !imageGenProfiles.isEmpty

            if showBots {
                ProfileColumnView(
                    title: "Bots",
                    profiles: botProfiles,
                    configuration: configuration,
                    onSelect: { self.isPresented = false }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }

            if showBots && (showAgents || showWorkflows || showImageGen) {
                Divider()
            }

            if showAgents {
                ProfileColumnView(
                    title: "Agents",
                    profiles: agentProfiles,
                    configuration: configuration,
                    onSelect: { self.isPresented = false }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }

            if showAgents && (showWorkflows || showImageGen) {
                Divider()
            }

            if showWorkflows {
                ProfileColumnView(
                    title: "Workflows",
                    profiles: workflowProfiles,
                    configuration: configuration,
                    onSelect: { self.isPresented = false }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }

            if showWorkflows && showImageGen {
                Divider()
            }

            if showImageGen {
                ProfileColumnView(
                    title: "Image Gen",
                    profiles: imageGenProfiles,
                    configuration: configuration,
                    onSelect: { self.isPresented = false }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }
        }
    }
}


// MARK: - Profile Column View
private struct ProfileColumnView: View {
    let title: String
    let profiles: [BackendProfileModel]
    var configuration: BackendConfiguration
    let onSelect: () -> Void
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(.caption, weight: .bold))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 18)   // aligns with cell text (8 outer + 10 inner)
                .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(profiles) { profile in
                        ItemCell(
                            profile: profile,
                            isSelected: configuration.selectedProfileID == profile.id,
                            onSelect: {
                                configuration.selectedProfileID = profile.id
                                onSelect()
                            }
                        )
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}


// MARK: - Reusable Item Cell
private struct ItemCell: View {
    let profile: BackendProfileModel
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var detailText: String? {
        switch profile.details {
        case .bot(let config):
            return config.llmConfig.modelName
        case .agent(let config):
            return config.llmConfig.modelName
        case .workflow(let config):
            let count = config.agentProfileIDs.count
            return count == 1 ? "1 node" : "\(count) nodes"
        case .imageGen(let config):
            return config.llmConfig.modelName
        case .code(let config):
            return config.llmConfig.modelName
        }
    }

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

                    if let detail = detailText, !detail.isEmpty {
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
