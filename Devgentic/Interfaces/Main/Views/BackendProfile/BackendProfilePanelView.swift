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
    @State private var profileService = BackendProfileService()
    @State private var selectedProfileID: UUID?
    @State private var isAddingProfile = false
    @State private var searchText: String = ""

    // Deletion State
    @State private var showingDeleteAlert = false
    @State private var profileToDelete: BackendProfileModel? = nil

    // Duplication State
    @State private var profileToDuplicate: BackendProfileModel? = nil

    // Unsaved-changes navigation guard
    @State private var pendingProfileID: UUID? = nil
    @State private var showingDiscardAlert = false

    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme

    /// Profiles filtered by search text (name or type). Code profiles are hidden — managed by CodeSessionManager.
    private var filteredProfiles: [BackendProfileModel] {
        let base = profileService.profiles.filter { $0.profileType != .code }
        if searchText.isEmpty { return base }
        let query = searchText.lowercased()
        return base.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.profileType.rawValue.lowercased().contains(query)
        }
    }

    // MARK: - Body
    var body: some View {
        NavigationSplitView {
            sidebarView
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            detailView
        }
        .environment(profileService)
        .preferredColorScheme(theme.id == "one_light" ? .light : (theme.id == "dracula" ? .dark : nil))
        .withToastOverlay()
        .configureWindow(collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary])
        .alert("Delete Profile?", isPresented: $showingDeleteAlert, presenting: profileToDelete) { profile in
            Button("Delete", role: .destructive) {
                do {
                    try profileService.deleteProfile(withId: profile.id)
                    if selectedProfileID == profile.id {
                        selectedProfileID = nil
                    }
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text("Are you sure you want to delete '\(profile.displayName)'? This action cannot be undone.")
        }
        .confirmationDialog("Unsaved Changes", isPresented: $showingDiscardAlert) {
            Button("Discard Changes", role: .destructive) {
                if let id = pendingProfileID {
                    profileService.activateEditBuffer(for: id)
                    selectedProfileID = id
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

    // MARK: - Subviews
    
    private var sidebarView: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding([.leading, .top, .trailing])
                .padding(.bottom, 8)

            // Search field
            if profileService.profiles.count > 5 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(theme.secondaryText)
                        .font(.system(.caption))
                    TextField("Filter profiles...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(.caption))
                        .foregroundColor(theme.primaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: theme.cornerRadiusMedium).fill(theme.surfaceOverlay))
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(filteredProfiles) { profile in
                        ProfileRowView(
                            profile: profile,
                            isSelected: selectedProfileID == profile.id,
                            onSelect: {
                                if (profileService.editBuffer?.isDirty == true) && selectedProfileID != profile.id {
                                    pendingProfileID = profile.id
                                    showingDiscardAlert = true
                                } else {
                                    profileService.activateEditBuffer(for: profile.id)
                                    selectedProfileID = profile.id
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
            }
            .scrollContentBackground(.hidden)
        }
        .background(theme.secondaryBackground)
        .sheet(isPresented: $isAddingProfile) {
            AddBackendProfileView(
                existingProfileNames: profileService.profiles.map(\.displayName)
            ) { newProfile in
                do {
                    try profileService.saveProfile(newProfile)
                    profileService.activateEditBuffer(for: newProfile.id)
                    selectedProfileID = newProfile.id
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
            }
        }
        .sheet(item: $profileToDuplicate) { source in
            DuplicateProfileSheet(
                sourceProfile: source,
                existingProfileNames: profileService.profiles.map(\.displayName)
            ) { duplicate in
                do {
                    try profileService.saveProfile(duplicate)
                    profileService.activateEditBuffer(for: duplicate.id)
                    selectedProfileID = duplicate.id
                    toastManager.show("Profile duplicated", style: .success)
                } catch {
                    toastManager.show(error.localizedDescription, style: .error)
                }
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
            .accessibilityLabel("Add new profile")

            Menu {
                Button("Export All...") {
                    let success = ProfileExporter.exportProfiles(profileService.profiles)
                    if success {
                        toastManager.show("Profiles exported", style: .success)
                    } else if !profileService.profiles.isEmpty {
                        toastManager.show("Export failed or was cancelled", style: .warning)
                    }
                }
                Button("Import...") {
                    guard let candidates = ProfileExporter.importProfiles(existingProfiles: profileService.profiles) else { return }

                    var successCount = 0
                    var skipCount = 0
                    var lastError: Error?

                    for candidate in candidates {
                        // For conflicts: suffix the name to avoid confusion
                        var profile = candidate.profile
                        if candidate.isConflict {
                            profile = BackendProfileSnapshot(
                                id: profile.id,
                                displayName: "\(profile.displayName) (Imported)",
                                lastSelected: profile.lastSelected,
                                details: profile.details
                            )
                        }

                        do {
                            try profileService.saveProfile(profile)
                            successCount += 1
                        } catch {
                            skipCount += 1
                            lastError = error
                        }
                    }

                    if successCount > 0 {
                        toastManager.show("\(successCount) profile(s) imported", style: .success)
                    }
                    if let error = lastError {
                        toastManager.show("\(skipCount) import(s) failed: \(error.localizedDescription)", style: .error)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .help("Export / Import Profiles")
            .accessibilityLabel("Export / Import Profiles")
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        Group {
            if let selectedID = selectedProfileID,
               let buffer = profileService.editBuffer,
               buffer.draft.id == selectedID {

                BackendProfileDetailView(editBuffer: buffer, onDelete: { id in
                    selectedProfileID = nil
                    do {
                        try profileService.deleteProfile(withId: id)
                    } catch {
                        toastManager.show(error.localizedDescription, style: .error)
                    }
                })
                .id(selectedID)

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
    @Bindable var editBuffer: ProfileEditBuffer
    var onDelete: ((UUID) -> Void)? = nil
    @Environment(BackendProfileService.self) var profileService
    @Environment(\.appTheme) private var theme

    var body: some View {
        Group {
            switch editBuffer.draft.profileType {
            case .bot:
                BotConfigDetailView(editBuffer: editBuffer, onDelete: onDelete)
            case .agent:
                AgentConfigDetailView(editBuffer: editBuffer, onDelete: onDelete)
            case .workflow:
                WorkflowCanvasView(profile: $editBuffer.draft, onDelete: onDelete)
            case .imageGen:
                ImageGenConfigDetailView(editBuffer: editBuffer, onDelete: onDelete)
            case .code:
                // Code mode uses the dedicated Code interface, not profile-based config.
                // This case should not be reachable, but handle gracefully.
                Text("Code sessions are configured via the Code interface.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            // Left rail = STATE: accent when selected or hovered; absent otherwise
            if isSelected || isHovering {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: isSelected ? [theme.accentColor, theme.accentColor.opacity(0.45)] : [theme.accentColor.opacity(0.4), theme.accentColor.opacity(0.15)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, isSelected ? 2 : 5)
                    .padding(.trailing, 4)
                    .shadow(color: isSelected ? theme.accentColor.opacity(0.4) : .clear, radius: 4)
                    .transition(.opacity.combined(with: .scale))
            } else {
                Spacer().frame(width: 7)
            }

            HStack(spacing: 12) {
                Image(systemName: iconName(for: profile.profileType))
                    .font(.system(.body))
                    .foregroundColor(color(for: profile.profileType))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(theme.fontFootnote.weight(.medium))
                        .foregroundColor(theme.primaryText)
                    Text(profile.profileType.rawValue)
                        .font(.system(.caption))
                        .foregroundColor(theme.secondaryText)
                }
                
                Spacer()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.accentColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(theme.accentColor.opacity(0.15), lineWidth: 0.5)
                        )
                        .shadow(color: theme.accentColor.opacity(0.05), radius: 4, x: 0, y: 0)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                .accessibilityLabel("Delete \(profile.displayName)")
                .padding(.trailing, 8)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel("\(profile.displayName), \(profile.profileType.rawValue)")
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button {
                onDuplicate()
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    private func iconName(for type: ProfileType) -> String {
        type.iconName
    }

    private func color(for type: ProfileType) -> Color {
        type.displayColor
    }
}

// MARK: - Duplicate Profile Sheet

/// A lightweight sheet that lets the user choose a name before duplicating a profile.
struct DuplicateProfileSheet: View {
    let sourceProfile: BackendProfileModel
    let existingProfileNames: [String]
    let onConfirm: (BackendProfileSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    @State private var displayName: String = ""

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicateName: Bool {
        let lower = trimmedName.lowercased()
        return !lower.isEmpty && existingProfileNames.contains(where: { $0.lowercased() == lower })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.system(.title3))
                    .foregroundColor(theme.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicate Profile")
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                    Text("From '\(sourceProfile.displayName)'")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Name field
            VStack(alignment: .leading, spacing: 8) {
                Text("Profile Name")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)

                TextField("Enter a name for the duplicate", text: $displayName)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(theme.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(isDuplicateName ? theme.warningColor : theme.dividerColor, lineWidth: 1)
                    )

                if isDuplicateName {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(.caption))
                        Text("A profile named '\(trimmedName)' already exists.")
                            .font(.system(.caption))
                    }
                    .foregroundColor(theme.warningColor)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(20)

            Divider()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Duplicate") {
                    let duplicate = BackendProfileSnapshot(
                        id: UUID(),
                        displayName: trimmedName,
                        lastSelected: nil,
                        details: sourceProfile.details
                    )
                    onConfirm(duplicate)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420)
        .background(theme.primaryBackground)
        .onAppear {
            displayName = "\(sourceProfile.displayName) (Copy)"
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
