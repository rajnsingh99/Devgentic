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
    @EnvironmentObject private var toastManager: ToastManager
    @Environment(\.appTheme) private var theme

    @State private var searchText = ""
    @State private var selectedTypeFilter: String = "All"
    @State private var isAddingProfile = false
    @State private var showingDeleteAlert = false
    @State private var profileToDelete: BackendProfileModel? = nil
    @State private var profileToDuplicate: BackendProfileModel? = nil

    // Unsaved-changes navigation guard
    @State private var pendingProfileID: UUID? = nil
    @State private var showingDiscardAlert = false

    private let typeFilters = ["All"] + ProfileType.allCases.map(\.rawValue)

    private var filteredProfiles: [BackendProfileModel] {
        var result = profileService.profiles

        // Type filter
        if selectedTypeFilter != "All" {
            result = result.filter { $0.profileType.rawValue == selectedTypeFilter }
        }

        // Search filter
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
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
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search
            SidebarSearchBarView("Search profiles...", text: $searchText)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            // Type filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(typeFilters, id: \.self) { filter in
                        CategoryChip(
                            title: filter,
                            isSelected: selectedTypeFilter == filter,
                            action: { selectedTypeFilter = filter }
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
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
                                    if (profileService.editBuffer?.isDirty == true) && activeProfileID != profile.id {
                                        pendingProfileID = profile.id
                                        showingDiscardAlert = true
                                    } else {
                                        router.navigateToProfile(profile.id, activatingBufferOn: profileService)
                                    }
                                },
                                onDuplicate: {
                                    profileToDuplicate = profile
                                },
                                onDelete: {
                                    profileToDelete = profile
                                    showingDeleteAlert = true
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(isPresented: $isAddingProfile) {
            AddBackendProfileView(
                existingProfileNames: profileService.profiles.map(\.displayName)
            ) { newProfile in
                do {
                    try profileService.saveProfile(newProfile)
                    router.navigateToProfile(newProfile.id, activatingBufferOn: profileService)
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
        }
        .alert("Delete Profile?", isPresented: $showingDeleteAlert, presenting: profileToDelete) { profile in
            Button("Delete", role: .destructive) {
                try? profileService.deleteProfile(withId: profile.id)
                if activeProfileID == profile.id {
                    router.returnToChat()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Are you sure you want to delete '\(profile.displayName)'? This action cannot be undone.")
        }
        .sheet(item: $profileToDuplicate) { source in
            DuplicateProfileSheet(
                sourceProfile: source,
                existingProfileNames: profileService.profiles.map(\.displayName)
            ) { duplicate in
                do {
                    try profileService.saveProfile(duplicate)
                    router.navigateToProfile(duplicate.id, activatingBufferOn: profileService)
                    toastManager.show("Profile duplicated", style: .success)
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
        }
        .confirmationDialog("Unsaved Changes", isPresented: $showingDiscardAlert) {
            Button("Discard Changes", role: .destructive) {
                if let id = pendingProfileID {
                    router.navigateToProfile(id, activatingBufferOn: profileService)
                }
                pendingProfileID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingProfileID = nil
            }
        } message: {
            Text("You have unsaved changes. Discard them?")
        }
    }
}
