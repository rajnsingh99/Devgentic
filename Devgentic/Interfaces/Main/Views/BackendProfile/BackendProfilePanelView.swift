//
//  BackendProfilePanelView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//  Updated on 05/09/25 to integrate AgentConfigDetailView.
//

import SwiftUI


struct BackendProfilePanelView: View {
    
    // MARK: - State Management
    @StateObject private var profileService = BackendProfileService()
    @State private var selectedProfileID: UUID?
    @State private var isAddingProfile = false
    
    // Deletion State
    @State private var showingDeleteAlert = false
    @State private var profileToDelete: BackendProfileModel? = nil
    
    @Environment(\.appTheme) private var theme
    
    // MARK: - Body
    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            detailView
        }
        .environmentObject(profileService)
        .preferredColorScheme(theme.id == "one_light" ? .light : (theme.id == "dracula" ? .dark : nil))
        .configureWindow(collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary])
        .alert("Delete Profile?", isPresented: $showingDeleteAlert, presenting: profileToDelete) { profile in
            Button("Delete", role: .destructive) {
                profileService.deleteProfile(withId: profile.id)
                if selectedProfileID == profile.id {
                    selectedProfileID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Are you sure you want to delete '\(profile.displayName)'? This action cannot be undone.")
        }
    }

    // MARK: - Subviews
    
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding([.leading, .top, .trailing])
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(profileService.profiles) { profile in
                        ProfileRowView(
                            profile: profile,
                            isSelected: selectedProfileID == profile.id,
                            onSelect: {
                                selectedProfileID = profile.id
                            },
                            onDelete: {
                                profileToDelete = profile
                                showingDeleteAlert = true
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollContentBackground(.hidden)
        }
        .background(theme.secondaryBackground)
        .sheet(isPresented: $isAddingProfile) {
            AddBackendProfileView { newProfile in
                profileService.saveProfile(newProfile)
                selectedProfileID = newProfile.id
            }
        }
    }
    
    private var headerView: some View {
        HStack {
            Text("Profiles")
                .font(.headline)
                .foregroundColor(theme.primaryText)
            Spacer()
            Button {
                isAddingProfile = true
            } label: {
                Image(systemName: "plus")
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .help("Add New Profile")
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        Group {
            if let selectedID = selectedProfileID,
               let selectedIndex = profileService.profiles.firstIndex(where: { $0.id == selectedID }) {
                
                BackendProfileDetailView(profile: $profileService.profiles[selectedIndex])
                
            } else {
                VStack {
                    Text("Select a profile to configure it.")
                        .font(.title2)
                        .foregroundColor(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.primaryBackground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Backend Profile Detail View

struct BackendProfileDetailView: View {
    @Binding var profile: BackendProfileModel
    @EnvironmentObject var profileService: BackendProfileService
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            switch profile.profileType {
            case .bot:
                BotConfigDetailView(profile: $profile)
            case .agent:
                AgentConfigDetailView(profile: $profile)
            case .workflow:
                WorkflowCanvasView(profile: $profile)
            case .imageGen:
                ImageGenConfigDetailView(profile: $profile)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Profile Row View
struct ProfileRowView: View {
    let profile: BackendProfileModel
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            // Selection Accent
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .transition(.opacity.combined(with: .scale))
            }

            HStack(spacing: 12) {
                Image(systemName: iconName(for: profile.profileType))
                    .font(.system(size: 16))
                    .foregroundColor(color(for: profile.profileType))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(profile.profileType.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
                
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentColor.opacity(0.12))
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surfaceOverlay)
                }
            }
        )
        .overlay(alignment: .trailing) {
            if isHovering {
                HoverActionButton(
                    icon: "trash",
                    tint: .red.opacity(0.8),
                    action: onDelete
                )
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func iconName(for type: ProfileType) -> String {
        switch type {
        case .bot: return "cpu"
        case .agent: return "person.fill.viewfinder"
        case .workflow: return "square.3.layers.3d.down.right"
        case .imageGen: return "paintbrush.fill"
        }
    }

    private func color(for type: ProfileType) -> Color {
        switch type {
        case .bot: return .blue
        case .agent: return .green
        case .workflow: return .purple
        case .imageGen: return .orange
        }
    }
}

// MARK: - Preview Provider
struct BackendProfilePanelView_Previews: PreviewProvider {
    static var previews: some View {
        BackendProfilePanelView()
            .frame(width: 800, height: 600)
    }
}
