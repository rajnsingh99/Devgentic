// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    @FocusState private var isListFocused: Bool
    @FocusState private var isSearchFocused: Bool
    @State private var focusedProfileID: UUID? = nil

    private let typeFilters: [ProfileType?] = [nil] + ProfileType.allCases.filter { $0 != .code }

    /// Code profiles are hidden from the sidebar — managed by CodeSessionManager.
    private var filteredProfiles: [BackendProfileModel] {
        // ⚠️ `sharedProfiles`, not `profiles` — a workflow node's owned configuration row must
        // never appear in the library sidebar. The `.code` filter stays: it is a different
        // exclusion (an internal profile type), and both must hold.
        var result = profileService.sharedProfiles.filter { $0.profileType != .code }

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

    /// While the Tool Library is the active destination for a specific profile, this pane
    /// hosts the library's navigation instead of the profile list.
    ///
    /// DERIVED from the router, deliberately not stored: "save or back returns to the
    /// profile list" then falls out of the destination changing, rather than being state
    /// someone has to remember to reset — which is exactly how such a toggle desyncs when
    /// the user navigates away mid-configuration.
    private var isShowingToolLibrary: Bool {
        if case .toolLibrary(let profileID) = router.activeDestination, profileID != nil { return true }
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
                buttonTitle: "New Profile",
                systemImage: "plus",
                shortcut: "⌘N",
                onAction: { isAddingProfile = true }
            )
            .keyboardShortcut("n", modifiers: [.command])
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Search
            SidebarSearchBarView("Search profiles", text: $searchText)
                .focused($isSearchFocused)
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

            // ⚠️ register B23 — the A47 error state lives inside the `profiles.isEmpty` arm below,
            // which covers exactly ONE of the two failure shapes. `loadProfiles()` deliberately
            // keeps the in-memory list when a fetch throws, so every failure AFTER the first
            // successful load — the ones a running app actually hits, e.g. a save elsewhere
            // triggering a reload against a store that has gone away — leaves a fully populated
            // sidebar that is silently stale. `lastLoadError` was set and rendered nowhere, so the
            // list read as current: a profile deleted or edited in another window still appears,
            // and selecting it routes to a detail view built from a snapshot the store no longer
            // agrees with. Same principle as A47 itself — "we could not read this" must never
            // render identically to "this is what you have".
            // `sharedProfiles`, matching the list this banner sits above — keyed on the
            // unfiltered list it could claim a stale list while the sidebar rendered nothing.
            if let loadError = profileService.lastLoadError, !profileService.sharedProfiles.isEmpty {
                staleListBanner(loadError)
            }

            // Profile list
            if filteredProfiles.isEmpty {
                if profileService.sharedProfiles.isEmpty {
                    // ⚠️ "We could not read your profiles" and "you have none yet" rendered
                    // IDENTICALLY before this. At launch `loadProfiles()` runs from `init`, where
                    // there is no prior list to fall back on, so a fetch failure showed a first-run
                    // empty state — with a "New Profile" button — to a user whose store was full.
                    // Creating one from there is the worst available next action.
                    if let loadError = profileService.lastLoadError {
                        SidebarEmptyStateView(
                            title: "Couldn't Load Profiles",
                            subtitle: "\(loadError)\n\nYour profiles have not been deleted — they could not be read.",
                            buttonTitle: "Retry",
                            buttonIcon: "arrow.clockwise",
                            systemImage: "exclamationmark.triangle",
                            onAction: { profileService.loadProfiles() }
                        )
                    } else {
                        SidebarEmptyStateView(
                            title: "No Profiles",
                            subtitle: "Create an AI profile to get started.",
                            buttonTitle: "New Profile",
                            buttonIcon: "plus",
                            systemImage: "cpu",
                            onAction: { isAddingProfile = true }
                        )
                    }
                } else {
                    SidebarEmptyStateView(
                        title: "No matches",
                        subtitle: "No profiles found for \"\(searchText)\"",
                        buttonTitle: "Clear Search",
                        systemImage: "magnifyingglass",
                        onAction: { searchText = "" }
                    )
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(filteredProfiles) { profile in
                                ProfileRowView(
                                    profile: profile,
                                    isSelected: activeProfileID == profile.id,
                                    isFocused: isListFocused && focusedProfileID == profile.id,
                                    onSelect: {
                                        focusedProfileID = profile.id
                                        selectProfile(profile)
                                    },
                                    onDuplicate: {
                                        profileToDuplicate = profile
                                    },
                                    onDelete: {
                                        profileToDelete = profile
                                        showingDeleteAlert = true
                                    }
                                )
                                .id(profile.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                    }
                    .scrollContentBackground(.hidden)
                    .focusable()
                    .focused($isListFocused)
                    .focusEffectDisabled()
                    .onMoveCommand { direction in
                        moveFocus(direction, proxy: proxy)
                    }
                    .onKeyPress(.return) {
                        if let id = focusedProfileID,
                           let profile = filteredProfiles.first(where: { $0.id == id }) {
                            selectProfile(profile)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.delete) {
                        if let id = focusedProfileID,
                           let profile = filteredProfiles.first(where: { $0.id == id }) {
                            profileToDelete = profile
                            showingDeleteAlert = true
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress { press in
                        if press.modifiers.contains(.command) {
                            if press.key == "d" {
                                if let id = focusedProfileID,
                                   let profile = filteredProfiles.first(where: { $0.id == id }) {
                                    profileToDuplicate = profile
                                    return .handled
                                }
                            } else if press.key == "f" {
                                isSearchFocused = true
                                return .handled
                            }
                        }
                        return .ignored
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingProfile) {
            AddBackendProfileView(
                existingProfileNames: profileService.sharedProfiles.map(\.displayName)
            ) { newProfile in
                // ⚠️ Deliberately NOT caught here (register A64). The throw is what keeps the sheet
                // open with the user's name and type intact; swallowing it into a toast is exactly
                // the behaviour that made a rejected create unrecoverable.
                try profileService.saveProfile(newProfile)
                router.navigateToProfile(newProfile.id, activatingBufferOn: profileService)
            }
        }
        .alert("Delete Profile?", isPresented: $showingDeleteAlert, presenting: profileToDelete) { profile in
            Button("Delete", role: .destructive) {
                // ⚠️ Was `try?` followed by an UNCONDITIONAL `returnToChat()`. On a throw the user
                // got no toast, the row stayed (the service's `loadProfiles()` never ran because
                // the throw preceded it), and they were still yanked out of the profile they were
                // editing — a failure that looked exactly like a UI bug. The create/duplicate arms
                // ten lines above already do this correctly.
                do {
                    try profileService.deleteProfile(withId: profile.id)
                    if activeProfileID == profile.id {
                        router.returnToChat()
                    }
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            // ⚠️ Register A30. This used to say only "This action cannot be undone" — true, and
            // useless: it names no consequence beyond the profile itself, so a user deleting an
            // agent had no way to learn that a nightly scheduled task depended on it. The warning
            // is only useful BEFORE the delete; afterwards there is nothing to decide.
            Text(ProfileReferenceIndex.deletionMessage(for: profile, in: profileService.profiles))
        }
        .sheet(item: $profileToDuplicate) { source in
            DuplicateProfileSheet(
                sourceProfile: source,
                existingProfileNames: profileService.sharedProfiles.map(\.displayName)
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
            // Offered only when a canvas is actually dirty — the field editor has its own Save
            // pill, and a second Save button that silently did nothing for it would be worse
            // than none.
            if profileService.canvasEditGuard.hasUnsavedChanges {
                Button("Save Changes") {
                    profileService.canvasEditGuard.saveHook?()
                    if let id = pendingProfileID {
                        router.navigateToProfile(id, activatingBufferOn: profileService)
                    }
                    pendingProfileID = nil
                }
            }
            Button("Discard Changes", role: .destructive) {
                // ⚠️ Actually discard. Navigating away used to be the whole of "discard", which
                // worked by accident for the field buffer (it is rebuilt on activate) and not at
                // all for a canvas, whose state outlives the row change.
                profileService.canvasEditGuard.discardHook?()
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
        .onAppear {
            if focusedProfileID == nil {
                focusedProfileID = activeProfileID
            }
        }
        .onChange(of: activeProfileID) { _, newID in
            if let newID {
                focusedProfileID = newID
            }
        }
        .onChange(of: filteredProfiles.map(\.id)) { _, newIDs in
            if let id = focusedProfileID, !newIDs.contains(id) {
                focusedProfileID = newIDs.first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProfile)) { _ in
            isAddingProfile = true
        }
        }
    }

    private func selectProfile(_ profile: BackendProfileModel) {
        profileService.flushPendingEditorText()
        if profileService.hasUnsavedEditorChanges && activeProfileID != profile.id {
            pendingProfileID = profile.id
            showingDiscardAlert = true
        } else {
            router.navigateToProfile(profile.id, activatingBufferOn: profileService)
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection, proxy: ScrollViewProxy) {
        guard !filteredProfiles.isEmpty else { return }
        let currentID = focusedProfileID ?? activeProfileID ?? filteredProfiles.first?.id
        guard let currentID,
              let currentIndex = filteredProfiles.firstIndex(where: { $0.id == currentID }) else {
            focusedProfileID = filteredProfiles.first?.id
            return
        }

        switch direction {
        case .up:
            let prevIndex = max(0, currentIndex - 1)
            let profile = filteredProfiles[prevIndex]
            focusedProfileID = profile.id
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(profile.id, anchor: .center)
            }
        case .down:
            let nextIndex = min(filteredProfiles.count - 1, currentIndex + 1)
            let profile = filteredProfiles[nextIndex]
            focusedProfileID = profile.id
            withAnimation(.easeInOut(duration: 0.12)) {
                proxy.scrollTo(profile.id, anchor: .center)
            }
        default:
            break
        }
    }

    /// Compact "this list may be stale" strip for a load failure that left profiles in memory.
    ///
    /// ⚠️ Deliberately NOT the full `SidebarEmptyStateView` treatment the empty case gets: there is
    /// a usable list underneath and the app is not blocked, so this warns and offers a retry
    /// without taking the list away. Warn, don't clamp.
    @ViewBuilder
    private func staleListBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(theme.warningColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("This list may be out of date")
                    .font(theme.fontCaption)
                    .foregroundColor(theme.primaryText)
                Text(message)
                    .font(theme.fontCaption)
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            Button("Retry") { profileService.loadProfiles() }
                .buttonStyle(.plain)
                .font(theme.fontCaption)
                .foregroundColor(theme.accentColor)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.12))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}
