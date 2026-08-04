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

    @Environment(BackendProfileService.self) private var profileService
    @Environment(MainViewRouter.self) private var router
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    @State private var searchText = ""
    /// ⚠️ Modelled as `ProfileType?` (nil = All) rather than a `String`. It was a raw
    /// string compared against `profileType.rawValue`, which meant the chip label WAS the
    /// filter key — so localizing the label would have broken filtering, and leaving it
    /// unlocalized was the C2 bug. Separating identity from display fixes both.
    @State private var selectedTypeFilter: ProfileType? = nil
    @State private var isAddingProfile = false
    @State private var showingDeleteAlert = false
    @State private var profileToDelete: BackendProfileModel? = nil
    @State private var profileToDuplicate: BackendProfileModel? = nil

    // Unsaved-changes navigation guard
    @State private var pendingProfileID: UUID? = nil
    @State private var showingDiscardAlert = false

    private let typeFilters: [ProfileType?] = [nil] + ProfileType.allCases.filter { $0 != .code }

    /// Code profiles are hidden from the sidebar — managed by CodeSessionManager.
    private var filteredProfiles: [BackendProfileModel] {
        var result = profileService.profiles.filter { $0.profileType != .code }

        // Type filter
        if let selectedTypeFilter {
            result = result.filter { $0.profileType == selectedTypeFilter }
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

    /// While the Tool Library is the active destination, this pane hosts the library's
    /// navigation instead of the profile list.
    ///
    /// DERIVED from the router, deliberately not stored: "save or back returns to the
    /// profile list" then falls out of the destination changing, rather than being state
    /// someone has to remember to reset — which is exactly how such a toggle desyncs when
    /// the user navigates away mid-configuration.
    private var isShowingToolLibrary: Bool {
        if case .toolLibrary = router.activeDestination { return true }
        return false
    }

    var body: some View {
        if isShowingToolLibrary {
            ToolNavigationPane(host: .profilesTab)
        } else {
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
                            title: filter?.localizedTitle ?? "All",
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
                            .font(theme.fontSubheadline)
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
}
