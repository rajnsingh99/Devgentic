//
//  BackendProfilePanelView.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//

import SwiftUI

// The `AnyBackendProfile` wrapper is no longer needed and has been removed.

/// The main container view for the `BackendProfile` management flow.
struct BackendProfilePanelView: View {
    
    // MARK: - State Management
    @StateObject private var profileService = BackendProfileService()
    @State private var selectedProfileID: UUID?
    @State private var isAddingProfile = false
    
    // MARK: - Body
    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            detailView
        }
        .environmentObject(profileService)
    }

    // MARK: - Subviews
    
    private var sidebarView: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Profiles")
                    .font(.headline)
                Spacer()
                Button {
                    isAddingProfile = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add New Profile")
            }
            .padding([.leading, .top, .trailing])

            // The list now iterates directly over the array of `BackendProfileModel`.
            List(selection: $selectedProfileID) {
                ForEach(profileService.profiles) { profile in
                    ProfileRowView(profile: profile)
                        .tag(profile.id)
                }
            }
            .listStyle(.sidebar)
        }
        .sheet(isPresented: $isAddingProfile) {
            AddBackendProfileView { newProfile in
                profileService.saveProfile(newProfile)
                selectedProfileID = newProfile.id
            }
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        if let selectedID = selectedProfileID,
           // Find the index of the selected profile in the service's array.
           let selectedIndex = profileService.profiles.firstIndex(where: { $0.id == selectedID }) {
            
            // Pass a binding directly to the model at the found index.
            BackendProfileDetailView(profile: $profileService.profiles[selectedIndex])
            
        } else {
            Text("Select a profile to configure it.")
                .font(.title2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Profile Row View
private struct ProfileRowView: View {
    // This view now takes the concrete model type.
    let profile: BackendProfileModel

    var body: some View {
        HStack {
            Image(systemName: iconName(for: profile.profileType))
                .font(.title3)
                .frame(width: 25, alignment: .center)
                .foregroundColor(color(for: profile.profileType))

            VStack(alignment: .leading) {
                Text(profile.displayName)
                    .fontWeight(.medium)
                Text(profile.profileType.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func iconName(for type: ProfileType) -> String {
        switch type {
        case .bot: return "cpu"
        case .agent: return "person.fill.viewfinder"
        case .workflow: return "square.3.layers.3d.down.right"
        }
    }
    
    private func color(for type: ProfileType) -> Color {
        switch type {
        case .bot: return .blue
        case .agent: return .green
        case .workflow: return .purple
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
