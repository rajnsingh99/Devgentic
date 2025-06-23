//
//  OllamaProfilesView.swift
//  Devgentic
//
//  Created by Raj Singh on 01/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaProfilesView")

struct OllamaProfilesView: View {
    @EnvironmentObject var ollamaProfileStore: OllamaProfileStore
    @EnvironmentObject var mainApplicationViewModel: MainApplicationViewModel

    // This state now drives the selection in the List.
    @State private var selectedProfileID: UUID?

    @State private var showingAddProfilePopover = false
    @State private var showDeleteConfirmation = false
    @State private var profileToDelete: OllamaProfileModel?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // --- Header to Add Profiles ---
                HStack {
                    Text("Ollama Profiles")
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
                        OllamaAddProfilePopover()
                            .environmentObject(ollamaProfileStore)
                    }
                }
                .padding()

                // --- Profiles List ---
                List(selection: $selectedProfileID) {
                    ForEach(ollamaProfileStore.profiles) { profile in
                        HStack {
                            Text(profile.profileName)
                            Spacer()
                            // Show a checkmark for the globally selected active profile
                            if ollamaProfileStore.selectedProfileID == profile.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .help("Active Profile")
                            }
                        }
                        .tag(profile.id)
                        .contextMenu {
                            Button("Set as Active") {
                                // Set the global active profile
                                ollamaProfileStore.selectedProfileID = profile.id
                            }
                            // MODIFIED: Removed condition to allow deleting any profile
                            Button("Delete Profile", role: .destructive) {
                                profileToDelete = profile
                                showDeleteConfirmation = true
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 220)
            
        } detail: {
            // --- Detail View ---
            if let profileID = selectedProfileID,
               let index = ollamaProfileStore.profiles.firstIndex(where: { $0.id == profileID }) {
                
                // Binding to the profile in the store's array
                let profileBinding = $ollamaProfileStore.profiles[index]
                
                ScrollView {
                    OllamaDetailView(
                        ollamaProfileBinding: profileBinding,
                        onDelete: { handleDelete(profileID) }
                    )
                    .environmentObject(mainApplicationViewModel)
                    .environmentObject(ollamaProfileStore)
                    .padding(20)
                }
            } else {
                // --- Placeholder for when no profile is selected or none exist ---
                VStack(spacing: 10) {
                     Image(systemName: "rectangle.stack.badge.plus")
                         .font(.largeTitle)
                         .foregroundColor(.secondary)
                     Text(ollamaProfileStore.profiles.isEmpty ? "No Ollama Profiles" : "Select a Profile")
                         .font(.title)
                     Text(ollamaProfileStore.profiles.isEmpty ? "Click the '+' button to add a new profile." : "Select a profile from the list to view its details.")
                         .foregroundColor(.secondary)
                         .multilineTextAlignment(.center)
                         .frame(maxWidth: 300)
                }
            }
        }
        .onAppear {
            // Sync local selection with the global selection from the store
            if selectedProfileID == nil {
                 selectedProfileID = ollamaProfileStore.selectedProfileID ?? ollamaProfileStore.profiles.first?.id
            }
        }
        .onChange(of: ollamaProfileStore.selectedProfileID) { _, newID in
            // Keep local selection in sync with global changes
            selectedProfileID = newID
        }
        .onChange(of: selectedProfileID) { _, newID in
            // When the user actively selects a profile in this view,
            // update the globally active profile as well.
            if ollamaProfileStore.selectedProfileID != newID {
                ollamaProfileStore.selectedProfileID = newID
            }
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

    /// Handles the deletion of a profile.
    private func handleDelete(_ idToDelete: UUID) {
        // Find the index before telling the store to delete.
        guard let indexToDelete = ollamaProfileStore.profiles.firstIndex(where: { $0.id == idToDelete }) else { return }

        // If the profile being deleted is the one selected in the sidebar, plan to select another.
        if selectedProfileID == idToDelete {
             if ollamaProfileStore.profiles.count > 1 {
                 // Select the previous item, or the next if it's the first
                 if indexToDelete > 0 {
                     selectedProfileID = ollamaProfileStore.profiles[indexToDelete - 1].id
                 } else {
                     // If there's a next item (count > 1), select it
                     selectedProfileID = ollamaProfileStore.profiles[indexToDelete + 1].id
                 }
             } else {
                 // This was the last profile, so no selection is possible.
                 selectedProfileID = nil
             }
        }
        
        // Tell the store to delete the profile from Core Data.
        // The store will handle updating its `profiles` array and the `selectedProfileID`.
        ollamaProfileStore.deleteProfile(id: idToDelete)
    }
}
