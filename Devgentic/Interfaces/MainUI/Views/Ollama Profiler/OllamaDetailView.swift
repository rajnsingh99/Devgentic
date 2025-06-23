//
//  OllamaDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaDetailView")

struct OllamaDetailView: View {
    @EnvironmentObject var mainViewModel: MainApplicationViewModel
    @EnvironmentObject var ollamaProfileStore: OllamaProfileStore
    private var ollamaService: OllamaService { mainViewModel.ollamaService }
    
    @Binding var ollamaProfile: OllamaProfileModel
    var onDelete: () -> Void

    @State private var editableProfile: OllamaProfileModel
    @State private var hasUnsavedChanges = false
    @State private var showingRemovalConfirmation = false

    init(ollamaProfileBinding: Binding<OllamaProfileModel>, onDelete: @escaping () -> Void) {
        self._ollamaProfile = ollamaProfileBinding
        self.onDelete = onDelete
        self._editableProfile = State(initialValue: ollamaProfileBinding.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Ollama Profile Settings")
                .font(.title2)
                .padding(.bottom, 5)

            Divider()

            // --- Full content of the view ---
            fullBodyContent
        }
        .padding()
        .onChange(of: editableProfile) { _, _ in checkForChanges() }
        .onChange(of: ollamaProfile) { _, newProfile in
            resetState(with: newProfile)
        }
        .confirmationDialog("Delete Ollama Profile", isPresented: $showingRemovalConfirmation, presenting: ollamaProfile) { profile in
            Button("Delete '\(profile.profileName)'", role: .destructive) {
                onDelete()
            }
        } message: { profile in
            Text("Are you sure you want to remove the profile '\(profile.profileName)'? This action cannot be undone.")
        }
    }
    
    private func checkForChanges() {
        hasUnsavedChanges = editableProfile != ollamaProfile
    }
    
    private func saveChanges() {
        // Update the binding to reflect changes immediately in the parent view.
        ollamaProfile = editableProfile
        // Call the store's method to persist the changes to Core Data.
        ollamaProfileStore.updateProfile(profile: editableProfile)
        hasUnsavedChanges = false
        logger.info("Saved changes for Ollama profile: \(editableProfile.profileName)")
    }
    
    private func resetState(with newProfile: OllamaProfileModel) {
        if editableProfile != newProfile {
            editableProfile = newProfile
            hasUnsavedChanges = false
        }
    }
    
    // Full body content (for completeness, even though parts are unchanged)
    @ViewBuilder
    private var fullBodyContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            // --- Profile Details ---
            VStack(alignment: .leading, spacing: 10) {
                Text("Profile Details")
                    .font(.headline)
                
                HStack {
                    Text("Profile Name:")
                        .frame(width: 150, alignment: .leading)
                    TextField("Profile Name", text: $editableProfile.profileName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    if editableProfile.profileName != ollamaProfile.profileName {
                        Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                    }
                }
                
                HStack {
                    Text("Base URL:")
                        .frame(width: 150, alignment: .leading)
                    TextField("Ollama Base URL", text: $editableProfile.baseURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(true)
                        .help("Base URL is set when the profile is created and cannot be changed.")
                }
            }
            .padding(.bottom, 10)

            // --- Model Selection and Management ---
            VStack(alignment: .leading, spacing: 10) {
                Text("Model Management")
                    .font(.headline)

                HStack {
                    Text("Selected Model:")
                        .frame(width: 150, alignment: .leading)

                    if ollamaService.isLoadingModels {
                        ProgressView("Loading...").controlSize(.small)
                    } else if let error = ollamaService.modelLoadingError {
                        Text("Error: \(error)").foregroundColor(.red)
                    } else if ollamaService.localModels.isEmpty {
                        Text("No models found.").foregroundColor(.gray)
                    } else {
                        Picker("Select a model", selection: $editableProfile.llmModelName) {
                            ForEach(ollamaService.localModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        if editableProfile.llmModelName != ollamaProfile.llmModelName {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                        }
                    }
                }
                .frame(minHeight: 22)
            }
            .padding(.bottom, 10)
            
            // --- Advanced Parameters ---
            DisclosureGroup("Advanced Parameters") {
                VStack(alignment: .leading, spacing: 10) {
                     HStack {
                         Text("Temperature:").frame(width: 150, alignment: .leading)
                         Slider(value: $editableProfile.temperature, in: 0.0...2.0)
                         Text("\(editableProfile.temperature, specifier: "%.2f")").frame(width: 40)
                         if editableProfile.temperature != ollamaProfile.temperature {
                             Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                         }
                     }
                     HStack {
                         Text("Top K:").frame(width: 150, alignment: .leading)
                         Stepper(value: $editableProfile.topK, in: 0...200) { Text("\(editableProfile.topK)") }
                         if editableProfile.topK != ollamaProfile.topK {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                         }
                     }
                     HStack {
                         Text("Top P:").frame(width: 150, alignment: .leading)
                         Slider(value: $editableProfile.topP, in: 0.0...1.0)
                         Text("\(editableProfile.topP, specifier: "%.2f")").frame(width: 40)
                         if editableProfile.topP != ollamaProfile.topP {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                         }
                     }
                     HStack {
                         Text("Repeat Penalty:").frame(width: 150, alignment: .leading)
                         Slider(value: $editableProfile.repeatPenalty, in: 1.0...2.0)
                         Text("\(editableProfile.repeatPenalty, specifier: "%.2f")").frame(width: 40)
                         if editableProfile.repeatPenalty != ollamaProfile.repeatPenalty {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                         }
                     }
                     HStack {
                         Text("Context Window:").frame(width: 150, alignment: .leading)
                         TextField("", value: $editableProfile.contextWindowSize, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                         if editableProfile.contextWindowSize != ollamaProfile.contextWindowSize {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                         }
                     }
                     HStack {
                         Text("GPU Layers:").frame(width: 150, alignment: .leading)
                         Stepper(value: $editableProfile.gpuLayers, in: -1...100) { Text(editableProfile.gpuLayers == -1 ? "All" : "\(editableProfile.gpuLayers)") }
                         if editableProfile.gpuLayers != ollamaProfile.gpuLayers {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                         }
                     }
                }
                .padding(.top)
            }
            .padding(.bottom, 10)

            Spacer()
            
            // --- Action Buttons ---
            HStack {
                // MODIFIED: Removed the condition. The delete button is now always visible.
                Button("Delete Profile") {
                    showingRemovalConfirmation = true
                }
                .foregroundColor(.red)
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Save") {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnsavedChanges || editableProfile.profileName.isEmpty)
            }
        }
    }
}
