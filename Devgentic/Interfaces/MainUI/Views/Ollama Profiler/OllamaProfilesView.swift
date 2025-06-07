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
    @EnvironmentObject var mainApplicationViewModel: MainApplicationViewModel

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
                            .environmentObject(ollamaProfileStore)
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
            }
            .confirmationDialog("Delete Ollama Profile", isPresented: $showingDeleteConfirmation, presenting: profileToDelete) { profile in
                Button("Delete '\(profile.profileName)'", role: .destructive) {
                    ollamaProfileStore.deleteProfile(id: profile.id)
                    profileToDelete = nil
                }
            } message: { profile in
                Text("Are you sure you want to remove the profile '\(profile.profileName)'? This action cannot be undone.")
            }


            // MARK: - Detail View Area
            if let selectedProfile = selectedProfileForNavigation {
                profileDetailView(for: selectedProfile)
                    .navigationTitle(selectedProfile.profileName)
            } else {
                Text("Select an Ollama Profile")
                    .font(.title)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if let currentSelectedID = ollamaProfileStore.selectedProfileID,
               let profile = ollamaProfileStore.profiles.first(where: { $0.id == currentSelectedID }) {
                selectedProfileForNavigation = profile
            } else if !ollamaProfileStore.profiles.isEmpty {
                selectedProfileForNavigation = ollamaProfileStore.profiles.first
                ollamaProfileStore.selectedProfileID = ollamaProfileStore.profiles.first?.id
            }
        }
        .onChange(of: selectedProfileForNavigation) { _, newProfile in
            if let newSelectedProfile = newProfile, ollamaProfileStore.selectedProfileID != newSelectedProfile.id {
                ollamaProfileStore.selectedProfileID = newSelectedProfile.id
            }
        }
        .onChange(of: ollamaProfileStore.selectedProfileID) { _, newStoreSelectedID in
            if let newID = newStoreSelectedID,
               let profile = ollamaProfileStore.profiles.first(where: { $0.id == newID }),
               selectedProfileForNavigation != profile {
                selectedProfileForNavigation = profile
            } else if newStoreSelectedID == nil {
                selectedProfileForNavigation = nil
            }
        }
        .onChange(of: ollamaProfileStore.profiles) { _, newProfiles in
            if let currentSelected = selectedProfileForNavigation, !newProfiles.contains(currentSelected) {
                selectedProfileForNavigation = newProfiles.first
                ollamaProfileStore.selectedProfileID = newProfiles.first?.id
            }
        }
    }

    // Helper to provide the correct detail view based on selection
    @ViewBuilder
    private func profileDetailView(for profile: OllamaProfile) -> some View {
        ScrollView {
            let profileBinding = Binding<OllamaProfile>(
                get: { self.ollamaProfileStore.profiles.first { $0.id == profile.id } ?? profile },
                set: { updatedProfile in self.ollamaProfileStore.updateProfile(profile: updatedProfile) }
            )

            // MARK: - Corrected call to LocalAISettingsView
            // This view now gets its dependencies from the environment.
            LocalAISettingsView(ollamaProfileBinding: profileBinding)
                .environmentObject(mainApplicationViewModel) // Ensure environment is passed down
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview Provider
struct OllamaProfilesView_Previews: PreviewProvider {
    // Helper to create a view model instance for previews
    static func createMockViewModel() -> MainApplicationViewModel {
        let profileStore = OllamaProfileStore()
        if profileStore.profiles.isEmpty {
            let defaultProfile = OllamaProfile.defaultProfile()
            let remoteProfile = OllamaProfile(
                id: UUID(), profileName: "Remote Server", baseURL: "http://192.168.1.100:11434",
                llmModelName: "llama2:7b", temperature: 0.7, topK: 30, topP: 0.8,
                repeatPenalty: 1.0, contextWindowSize: 2048, gpuLayers: 0,
                maxInlineChars: 2000, maxAttachedFiles: 3,
                textFileInclusionStrategy: .alwaysUsePaths,
                imageHandlingStrategy: .doNotInclude,
                binaryFileHandlingStrategy: .doNotInclude
            )
            profileStore.profiles = [defaultProfile, remoteProfile]
            profileStore.selectedProfileID = defaultProfile.id
        }
        
        // Correctly initialize without OllamaService
        return MainApplicationViewModel(
            ollamaProfileStore: profileStore,
            agentStore: AgentStore()
        )
    }

    static var previews: some View {
        let mockViewModel = createMockViewModel()
        
        // Now, we inject both the viewModel and its profileStore into the environment
        // for the preview to use.
        OllamaProfilesView()
            .environmentObject(mockViewModel)
            .environmentObject(mockViewModel.ollamaProfileStore)
            .frame(width: 900, height: 600)
            .previewDisplayName("Ollama Profiles Window")
            .onAppear {
                // For previews, configure the state of the SHARED service instance
                let service = OllamaService.shared
                service.serverStatus = .connected
                service.localModels = ["gemma:2b", "llama3:8b", "mistral:7b"]
                service.isLoadingModels = false
                service.modelPullError = nil
            }
    }
}
