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

    @State private var selectedProfileID: UUID?
    @State private var showingAddProfilePopover = false
    @State private var showDeleteConfirmation = false
    @State private var profileToDelete: OllamaProfile?

    var body: some View {
        // MARK: - FIX: Replaced NavigationView with NavigationSplitView
        // NavigationSplitView is the modern, correct way to create master-detail interfaces on macOS.
        NavigationSplitView {
            // MARK: - Sidebar (Master View)
            VStack(spacing: 0) {
                HStack {
                    Text("Add Profile")
                        .font(.headline)
                    Spacer()
                    Button {
                        showingAddProfilePopover = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Add New Ollama Profile")
                    .popover(isPresented: $showingAddProfilePopover) {
                        AddOllamaProfilePopover()
                            .environmentObject(ollamaProfileStore)
                    }
                }
                .padding()

                List(selection: $selectedProfileID) {
                    ForEach(ollamaProfileStore.profiles) { profile in
                        HStack {
                            Text(profile.profileName)
                            Spacer()
                            if ollamaProfileStore.selectedProfileID == profile.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .help("Active Profile")
                            }
                        }
                        .tag(profile.id) // Use .tag for selection
                        .contextMenu {
                            Button("Set as Active") {
                                ollamaProfileStore.selectedProfileID = profile.id
                            }
                            if ollamaProfileStore.profiles.count > 1 && ollamaProfileStore.selectedProfileID != profile.id {
                                Button("Delete Profile", role: .destructive) {
                                    profileToDelete = profile
                                    showDeleteConfirmation = true
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 220) // Set a minimum width for the sidebar
            
        } detail: {
            // MARK: - Detail View
            // The content of the detail view is now determined by the selectedProfileID.
            if let profileID = selectedProfileID,
               let index = ollamaProfileStore.profiles.firstIndex(where: { $0.id == profileID }) {
                
                let profileBinding = $ollamaProfileStore.profiles[index]
                
                ScrollView {
                    LocalAISettingsView(
                        ollamaProfileBinding: profileBinding,
                        onDelete: { handleDelete(profileID) }
                    )
                    .environmentObject(mainApplicationViewModel)
                    .environmentObject(ollamaProfileStore)
                    .padding(20)
                }
            } else {
                // This placeholder now correctly appears when no profile is selected.
                Text("Select an Ollama Profile")
                    .font(.title)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            // Set the initial selection if one isn't already set
            if selectedProfileID == nil {
                 selectedProfileID = ollamaProfileStore.profiles.first?.id
            }
        }
        .onChange(of: ollamaProfileStore.selectedProfileID) { _, newID in
            // Keep local selection in sync with the global selection from the store
            selectedProfileID = newID
        }
        .confirmationDialog("Delete Ollama Profile", isPresented: $showDeleteConfirmation, presenting: profileToDelete) { profile in
             Button("Delete '\(profile.profileName)'", role: .destructive) {
                 handleDelete(profile.id)
                 profileToDelete = nil
             }
         } message: { profile in
             Text("Are you sure you want to remove the profile '\(profile.profileName)'? This action cannot be undone.")
         }
    }

    private func handleDelete(_ idToDelete: UUID) {
        guard let indexToDelete = ollamaProfileStore.profiles.firstIndex(where: { $0.id == idToDelete }) else { return }

        // Determine new selection before deleting
        if selectedProfileID == idToDelete {
             if ollamaProfileStore.profiles.count > 1 {
                 if indexToDelete == ollamaProfileStore.profiles.count - 1 {
                     // If it's the last one, select the one before it
                     selectedProfileID = ollamaProfileStore.profiles[indexToDelete - 1].id
                 } else {
                     // Otherwise, select the next one
                     selectedProfileID = ollamaProfileStore.profiles[indexToDelete + 1].id
                 }
             } else {
                 // Nothing left to select
                 selectedProfileID = nil
             }
        }
        
        ollamaProfileStore.deleteProfile(id: idToDelete)
    }
}

// MARK: - Preview Provider
struct OllamaProfilesView_Previews: PreviewProvider {
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
        
        return MainApplicationViewModel(
            ollamaProfileStore: profileStore,
            agentStore: AgentStore()
        )
    }

    static var previews: some View {
        let mockViewModel = createMockViewModel()
        
        OllamaProfilesView()
            .environmentObject(mockViewModel)
            .environmentObject(mockViewModel.ollamaProfileStore)
            .frame(width: 900, height: 700)
            .previewDisplayName("Ollama Profiles Window")
            .onAppear {
                let service = OllamaService.shared
                service.serverStatus = .connected
                service.localModels = ["gemma:2b", "llama3:8b", "mistral:7b"]
            }
    }
}
