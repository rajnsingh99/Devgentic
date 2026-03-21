//
//  ProfileSidebarListView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//
//  Inline sidebar list for backend profiles. Replaces the separate
//  BackendProfilePanelView window — tapping a profile routes its
//  detail into the main content area via MainViewRouter.
//

import SwiftUI

struct ProfileSidebarListView: View {

    @EnvironmentObject private var profileService: BackendProfileService
    @EnvironmentObject private var router: MainViewRouter
    @Environment(\.appTheme) private var theme

    @State private var searchText = ""
    @State private var isAddingProfile = false
    @State private var showingDeleteAlert = false
    @State private var profileToDelete: BackendProfileModel? = nil

    private var filteredProfiles: [BackendProfileModel] {
        if searchText.isEmpty { return profileService.profiles }
        return profileService.profiles.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// The currently-displayed profile ID (derived from the router destination).
    private var activeProfileID: UUID? {
        if case .profileDetail(let id) = router.activeDestination { return id }
        if case .toolLibrary(let id) = router.activeDestination { return id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            SidebarHeaderView(
                title: "Profiles",
                buttonTitle: "New",
                systemImage: "plus",
                onAction: { isAddingProfile = true }
            )
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Search
            SidebarSearchBarView("Search profiles...", text: $searchText)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            // Profile list
            if filteredProfiles.isEmpty {
                if profileService.profiles.isEmpty {
                    SidebarEmptyStateView(
                        title: "No Profiles",
                        subtitle: "Create an AI profile to get started.",
                        buttonTitle: "New Profile",
                        systemImage: "cpu",
                        onAction: { isAddingProfile = true }
                    )
                } else {
                    VStack(spacing: 8) {
                        Spacer()
                        Text("No matches")
                            .font(.system(size: 13))
                            .foregroundColor(theme.secondaryText)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(filteredProfiles) { profile in
                            ProfileRowView(
                                profile: profile,
                                isSelected: activeProfileID == profile.id,
                                onSelect: {
                                    router.navigateToProfile(profile.id)
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
        }
        .sheet(isPresented: $isAddingProfile) {
            AddBackendProfileView { newProfile in
                profileService.saveProfile(newProfile)
                router.navigateToProfile(newProfile.id)
            }
        }
        .alert("Delete Profile?", isPresented: $showingDeleteAlert, presenting: profileToDelete) { profile in
            Button("Delete", role: .destructive) {
                profileService.deleteProfile(withId: profile.id)
                if activeProfileID == profile.id {
                    router.returnToChat()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Are you sure you want to delete '\(profile.displayName)'? This action cannot be undone.")
        }
    }
}
