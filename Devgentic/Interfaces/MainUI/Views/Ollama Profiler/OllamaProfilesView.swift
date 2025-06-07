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

    @State private var selectedProfileID: UUID?
    @State private var showingAddProfilePopover = false
    @State private var showDeleteConfirmation = false
    @State private var profileToDelete: OllamaProfileModel?

    var body: some View {
        NavigationSplitView {
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
                        OllamaAddProfilePopover()
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
            .frame(minWidth: 220)
            
        } detail: {
            if let profileID = selectedProfileID,
               let index = ollamaProfileStore.profiles.firstIndex(where: { $0.id == profileID }) {
                
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
                Text("Select an Ollama Profile")
                    .font(.title)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if selectedProfileID == nil {
                 selectedProfileID = ollamaProfileStore.profiles.first?.id
            }
        }
        .onChange(of: ollamaProfileStore.selectedProfileID) { _, newID in
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
        if selectedProfileID == idToDelete {
             if ollamaProfileStore.profiles.count > 1 {
                 if indexToDelete == ollamaProfileStore.profiles.count - 1 {
                     selectedProfileID = ollamaProfileStore.profiles[indexToDelete - 1].id
                 } else {
                     selectedProfileID = ollamaProfileStore.profiles[indexToDelete + 1].id
                 }
             } else {
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
            let defaultProfile = OllamaProfileModel.defaultProfile()
            let remoteProfile = OllamaProfileModel(
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
