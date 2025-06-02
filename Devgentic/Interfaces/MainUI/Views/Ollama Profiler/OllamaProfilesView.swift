//
//  OllamaProfilesView.swift
//  Devgentic
//
//  Created by Raj Singh on 01/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaProfilesView")

/// The main window for managing Ollama profiles.
/// It displays a master-detail interface for selecting and configuring different Ollama instances.
struct OllamaProfilesView: View {
    @EnvironmentObject var ollamaProfileStore: OllamaProfileStore
    @EnvironmentObject var mainApplicationViewModel: MainApplicationViewModel // Needed for passing to LocalAISettingsView

    @State private var selectedProfileForNavigation: OllamaProfile?
    @State private var showingAddProfilePopover = false
    @State private var showingDeleteConfirmation = false
    @State private var profileToDelete: OllamaProfile?

    var body: some View {
        NavigationView {
            // MARK: - Master View (Profiles Sidebar)
            VStack(spacing: 0) {
                HStack {
                    Text("Ollama Profiles")
                        .font(.headline)
                        .padding(.horizontal)
                    Spacer()
                    Button {
                        showingAddProfilePopover = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Add New Ollama Profile")
                    .popover(isPresented: $showingAddProfilePopover) {
                        AddOllamaProfilePopover()
                            .environmentObject(ollamaProfileStore) // Pass the store to the popover
                            .frame(minWidth: 300, idealWidth: 400, minHeight: 150, idealHeight: 200)
                    }
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 8)

                Divider()

                List(selection: $selectedProfileForNavigation) {
                    ForEach(ollamaProfileStore.profiles) { profile in
                        NavigationLink(
                            destination: profileDetailView(for: profile),
                            tag: profile,
                            selection: $selectedProfileForNavigation
                        ) {
                            HStack {
                                Text(profile.profileName)
                                Spacer()
                                if ollamaProfileStore.selectedProfileID == profile.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .help("Active Profile")
                                }
                            }
                        }
                        .contextMenu {
                            Button("Set as Active") {
                                ollamaProfileStore.selectedProfileID = profile.id
                            }
                            // Disable delete if it's the only profile or the active one
                            Button("Delete Profile", role: .destructive) {
                                profileToDelete = profile
                                showingDeleteConfirmation = true
                            }
                            .disabled(ollamaProfileStore.profiles.count <= 1 || ollamaProfileStore.selectedProfileID == profile.id)
                        }
                    }
                }
                .listStyle(SidebarListStyle())
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 250)
                .onDeleteCommand {
                    // Handle delete key press
                    if let selectedProfile = selectedProfileForNavigation,
                       ollamaProfileStore.profiles.count > 1,
                       ollamaProfileStore.selectedProfileID != selectedProfile.id {
                        profileToDelete = selectedProfile
                        showingDeleteConfirmation = true
                    }
                }
            }
            .confirmationDialog("Delete Ollama Profile",
                                isPresented: $showingDeleteConfirmation,
                                presenting: profileToDelete) { profile in
                Button("Delete '\(profile.profileName)'", role: .destructive) {
                    ollamaProfileStore.deleteProfile(id: profile.id)
                    profileToDelete = nil // Clear the reference
                }
                Button("Cancel", role: .cancel) {
                    profileToDelete = nil
                }
            } message: { profile in
                Text("Are you sure you want to remove the profile '\(profile.profileName)'? This action cannot be undone.")
            }


            // MARK: - Detail View Area
            // Display the detail view for the selected profile, or a placeholder
            if let selectedProfile = selectedProfileForNavigation {
                profileDetailView(for: selectedProfile)
                    .navigationTitle(selectedProfile.profileName) // Set title for the detail view
            } else {
                VStack {
                    Text("Select an Ollama Profile")
                        .font(.title)
                    Text("Choose a profile from the sidebar to view or edit its settings, or click '+' to add a new one.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // Initialize selectedProfileForNavigation from the store's selectedProfileID
            if let currentSelectedID = ollamaProfileStore.selectedProfileID,
               let profile = ollamaProfileStore.profiles.first(where: { $0.id == currentSelectedID }) {
                selectedProfileForNavigation = profile
            } else if ollamaProfileStore.selectedProfileID == nil && !ollamaProfileStore.profiles.isEmpty {
                // If no profile is selected in the store, but profiles exist, select the first one
                selectedProfileForNavigation = ollamaProfileStore.profiles.first
                ollamaProfileStore.selectedProfileID = ollamaProfileStore.profiles.first?.id
            }
            logger.info("OllamaProfilesView appeared. Initial selected profile: \(selectedProfileForNavigation?.profileName ?? "nil")")
        }
        // Sync ollamaProfileStore's selection when local navigation selection changes
        .onChange(of: selectedProfileForNavigation) { newValue in
            if let newSelectedProfile = newValue {
                if ollamaProfileStore.selectedProfileID != newSelectedProfile.id {
                    ollamaProfileStore.selectedProfileID = newSelectedProfile.id
                    logger.debug("OllamaProfilesView local selection changed to: \(newSelectedProfile.profileName), updating store.")
                }
            }
        }
        // Sync local navigation selection if ollamaProfileStore's selection changes from elsewhere
        .onChange(of: ollamaProfileStore.selectedProfileID) { newStoreSelectedID in
            if let newID = newStoreSelectedID,
               let profile = ollamaProfileStore.profiles.first(where: { $0.id == newID }) {
                if selectedProfileForNavigation != profile {
                    selectedProfileForNavigation = profile
                    logger.debug("OllamaProfileStore selectedProfileID changed to: \(profile.profileName), updating local selection.")
                }
            } else if newStoreSelectedID == nil {
                selectedProfileForNavigation = nil
                logger.debug("OllamaProfileStore selectedProfileID cleared, clearing local selection.")
            }
        }
    }

    // Helper to provide the correct detail view based on selection
    @ViewBuilder
    private func profileDetailView(for profile: OllamaProfile) -> some View {
        // Wrap the entire content of the detail section in a ScrollView
        ScrollView {
            // Create a binding that updates the store when the profile changes
            let profileBinding = Binding<OllamaProfile>(
                get: {
                    // Ensure we're always working with the latest version from the store
                    self.ollamaProfileStore.profiles.first(where: { $0.id == profile.id }) ?? profile
                },
                set: { updatedProfile in
                    self.ollamaProfileStore.updateProfile(profile: updatedProfile)
                }
            )

            // We need to pass the ollamaService and mainViewModel for now,
            // as LocalAISettingsView still expects them.
            // In Phase 3, LocalAISettingsView will be adapted to primarily use the OllamaProfile binding.
            LocalAISettingsView(
                ollamaService: mainApplicationViewModel.ollamaService, // Still using the main one for actions
                mainViewModel: mainApplicationViewModel, // Still using the main one for global context
                ollamaProfileBinding: profileBinding // Pass the new profile binding
            )
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview Provider
struct OllamaProfilesView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a mock OllamaProfileStore for previews
        let mockOllamaProfileStore: OllamaProfileStore = { // MARK: Use static for mock store
            let store = OllamaProfileStore()
            // Add some mock profiles
            store.profiles = [
                OllamaProfile.defaultProfile(),
                OllamaProfile(
                    id: UUID(),
                    profileName: "Remote Server",
                    baseURL: "http://192.168.1.100:11434",
                    llmModelName: "llama2:7b",
                    temperature: 0.7, topK: 30, topP: 0.8, repeatPenalty: 1.0, contextWindowSize: 2048, gpuLayers: 0,
                    maxInlineChars: 2000, maxAttachedFiles: 3,
                    textFileInclusionStrategy: .alwaysUsePaths, // Corrected enum case
                    imageHandlingStrategy: .doNotInclude,
                    binaryFileHandlingStrategy: .doNotInclude
                )
            ]
            store.selectedProfileID = store.profiles.first?.id // Select the first one by default
            return store
        }()

        // Create a mock OllamaService for previews
        let mockOllamaService: OllamaService = { // MARK: Use static for mock service
            let service = OllamaService()
            service.localModels = ["llama3:8b", "mistral:7b", "gemma:2b"]
            service.llmModelName = "mistral:7b"
            service.serverStatus = .connected
            return service
        }()

        // Create a mock MainApplicationViewModel for previews
        // MARK: Fix: Provide ollamaProfileStore to MainApplicationViewModel init
        let mockMainApplicationViewModel = MainApplicationViewModel(
            ollamaService: mockOllamaService,
            ollamaProfileStore: mockOllamaProfileStore
        )

        OllamaProfilesView()
            .environmentObject(mockOllamaProfileStore)
            .environmentObject(mockMainApplicationViewModel)
            .frame(width: 900, height: 600)
            .previewDisplayName("Ollama Profiles Window")
    }
}
