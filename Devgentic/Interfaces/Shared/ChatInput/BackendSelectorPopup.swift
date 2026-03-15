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
    @ObservedObject var configuration: BackendConfiguration
    @Binding var isPresented: Bool
    
    // MARK: - Environment
    @Environment(\.openWindow) var openWindow

    // MARK: - Data Source
    @State private var profiles: [BackendProfileModel] = []
    
    // MARK: - Computed Properties for Data Filtering
    private var botProfiles: [BackendProfileModel] {
        profiles.filter { $0.profileType == .bot }.sorted { $0.displayName < $1.displayName }
    }
    private var agentProfiles: [BackendProfileModel] {
        profiles.filter { $0.profileType == .agent }.sorted { $0.displayName < $1.displayName }
    }
    private var workflowProfiles: [BackendProfileModel] {
        profiles.filter { $0.profileType == .workflow }.sorted { $0.displayName < $1.displayName }
    }
    private var imageGenProfiles: [BackendProfileModel] {
        profiles.filter { $0.profileType == .imageGen }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            let showBots = !botProfiles.isEmpty
            let showAgents = !agentProfiles.isEmpty
            let showWorkflows = !workflowProfiles.isEmpty
            let showImageGen = !imageGenProfiles.isEmpty

            // Column 1: Bots
            if showBots {
                ProfileColumnView(
                    title: "Bots",
                    profiles: botProfiles,
                    configuration: configuration,
                    onSelect: { self.isPresented = false },
                    onEdit: { profileID in
                        // Placeholder for future edit action
                        // openWindow(id: "profile-editor", value: profileID)
                        self.isPresented = false
                    }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }

            if showBots && (showAgents || showWorkflows || showImageGen) {
                Divider()
            }

            // Column 2: Agents
            if showAgents {
                ProfileColumnView(
                    title: "Agents",
                    profiles: agentProfiles,
                    configuration: configuration,
                    onSelect: { self.isPresented = false },
                    onEdit: { profileID in
                        // openWindow(id: "profile-editor", value: profileID)
                        self.isPresented = false
                    }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }

            if showAgents && (showWorkflows || showImageGen) {
                Divider()
            }

            // Column 3: Workflows
            if showWorkflows {
                ProfileColumnView(
                    title: "Workflows",
                    profiles: workflowProfiles,
                    configuration: configuration,
                    onSelect: { self.isPresented = false },
                    onEdit: { profileID in
                        // openWindow(id: "profile-editor", value: profileID)
                        self.isPresented = false
                    }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }

            if showWorkflows && showImageGen {
                Divider()
            }

            // Column 4: Image Gen
            if showImageGen {
                ProfileColumnView(
                    title: "Image Gen",
                    profiles: imageGenProfiles,
                    configuration: configuration,
                    onSelect: { self.isPresented = false },
                    onEdit: { _ in self.isPresented = false }
                )
                .frame(minWidth: 180, idealWidth: 200)
            }
        }
        .padding(.vertical, 8)
        .frame(maxHeight: 450)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            self.profiles = BackendProfileStore.shared.fetchProfiles()
        }
    }
}


// MARK: - Profile Column View
private struct ProfileColumnView: View {
    let title: String
    let profiles: [BackendProfileModel]
    @ObservedObject var configuration: BackendConfiguration
    let onSelect: () -> Void
    let onEdit: (UUID) -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 5) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .center, spacing: 0) {
                    ForEach(profiles) { profile in
                        let isSelected = configuration.selectedProfileID == profile.id
                        
                        ItemCell(
                            profile: profile,
                            isSelected: isSelected
                        )
                        .onTapGesture(count: 2) { onEdit(profile.id) }
                        .onTapGesture(count: 1) {
                            configuration.selectedProfileID = profile.id
                            self.onSelect()
                        }
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

    private var detailText: String? {
        switch profile.details {
        case .bot(let llmConfig, _):
            return llmConfig.modelName
        case .agent:
            return "Agent" // Placeholder
        case .workflow:
            return "Workflow" // Placeholder
        case .imageGen(let llmConfig, _, _, _):
            return llmConfig.modelName
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer()
                VStack(alignment: .center, spacing: 2) {
                    Text(profile.displayName)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let detail = detailText, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            if isSelected {
                HStack {
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .cornerRadius(6)
        .padding(.horizontal, 8)
    }
}
