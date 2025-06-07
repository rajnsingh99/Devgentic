//
//  LocalAISettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI
import os

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LocalAISettingsView")

// MARK: - Local AI Settings Detail View
struct LocalAISettingsView: View {
    // MARK: - Corrected: Dependencies are now from the environment
    @EnvironmentObject var mainViewModel: MainApplicationViewModel
    private var ollamaService: OllamaService { mainViewModel.ollamaService }
    
    @Binding var ollamaProfile: OllamaProfile

    @State private var showingRemovalConfirmation = false
    @State private var modelToRemoveFromName: String? = nil
    
    // State for editable profile name
    @State private var editableProfileName: String
    @State private var showUpdateFeedback = false

    // MARK: - Corrected: Initializer no longer needs services passed in
    init(ollamaProfileBinding: Binding<OllamaProfile>) {
        self._ollamaProfile = ollamaProfileBinding
        self._editableProfileName = State(initialValue: ollamaProfileBinding.wrappedValue.profileName)
    }

    var isProfileNameChanged: Bool {
        editableProfileName.trimmingCharacters(in: .whitespacesAndNewlines) != ollamaProfile.profileName &&
        !editableProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Local AI (Ollama) Profile: \(ollamaProfile.profileName)")
                .font(.title2)
                .padding(.bottom, 5)

            Divider()

            // --- Profile Name and Base URL ---
            VStack(alignment: .leading, spacing: 10) {
                Text("Profile Details:")
                    .font(.headline)
                HStack {
                    Text("Profile Name:")
                        .frame(width: 150, alignment: .leading)
                    TextField("Profile Name", text: $editableProfileName)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    Button {
                        let trimmedName = editableProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmedName.isEmpty {
                            ollamaProfile.profileName = trimmedName
                            withAnimation { showUpdateFeedback = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                await MainActor.run {
                                    withAnimation { showUpdateFeedback = false }
                                }
                            }
                        }
                    } label: {
                        if showUpdateFeedback {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        } else {
                            Text("Update")
                        }
                    }
                    .disabled(!isProfileNameChanged || showUpdateFeedback)
                    .buttonStyle(.bordered)
                    .frame(width: showUpdateFeedback ? 40 : 80)
                }
                HStack {
                    Text("Base URL:")
                        .frame(width: 150, alignment: .leading)
                    TextField("Ollama Base URL", text: $ollamaProfile.baseURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .disabled(true)
                        .help("Base URL is set when the profile is created and cannot be changed.")
                }
            }

            Divider()

            // --- Displaying and Selecting Models ---
            VStack(alignment: .leading, spacing: 10) {
                Text("Available Models:")
                    .font(.headline)

                HStack {
                    Text("Ollama Model:")
                        .frame(width: 150, alignment: .leading)

                    if ollamaService.isLoadingModels {
                        ProgressView("Loading Models...").controlSize(.small)
                    } else if let error = ollamaService.modelLoadingError {
                        Text("Error: \(error)").foregroundColor(.red)
                    } else if ollamaService.localModels.isEmpty {
                        Text("No models found. Ensure Ollama is running.").foregroundColor(.gray)
                    } else {
                        Picker("Select a model", selection: $ollamaProfile.llmModelName) {
                            ForEach(ollamaService.localModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                .frame(minHeight: 22)

                 if !ollamaService.isLoadingModels && ollamaService.modelLoadingError == nil && !ollamaService.localModels.isEmpty {
                     Divider()
                     Text("Installed Models:")
                         .font(.subheadline)

                     VStack(alignment: .leading) {
                         ForEach(ollamaService.localModels, id: \.self) { modelName in
                             HStack {
                                 Text(modelName)
                                     .frame(maxWidth: .infinity, alignment: .leading)

                                 Button {
                                     modelToRemoveFromName = modelName
                                     showingRemovalConfirmation = true
                                 } label: {
                                     if ollamaService.isRemovingModel && ollamaService.removingModelName == modelName {
                                         ProgressView().controlSize(.small)
                                     } else {
                                         Image(systemName: "trash")
                                     }
                                 }
                                 .disabled(ollamaService.isPullingModel || ollamaService.isRemovingModel || ollamaProfile.llmModelName == modelName)
                                 .foregroundColor(.red)
                                 .buttonStyle(PlainButtonStyle())
                                 .help("Remove \(modelName)")
                             }
                             .padding(.vertical, 2)
                         }
                     }
                     .padding(.top, 5)
                 }
            }

            Divider()

            // --- Pull Model Section ---
            VStack(alignment: .leading, spacing: 10) {
                 Text("Download New Model:")
                     .font(.headline)

                 HStack {
                     Text("Model Name:")
                          .frame(width: 150, alignment: .leading)
                    
                     // MARK: - Corrected: Bind to the view model's service property
                     TextField("e.g., llama3:latest", text: $mainViewModel.ollamaService.modelToPull)
                         .textFieldStyle(RoundedBorderTextFieldStyle())
                         .disabled(ollamaService.isPullingModel || ollamaService.isRemovingModel)
                         .onChange(of: ollamaService.modelToPull) { _,_ in ollamaService.clearPullActionStatus() }

                     Button {
                         Task {
                             await ollamaService.pullModel(name: ollamaService.modelToPull, baseURL: ollamaProfile.baseURL)
                         }
                     } label: {
                         if ollamaService.isPullingModel {
                             ProgressView().controlSize(.small)
                         } else { Image(systemName: "arrow.down.circle") }
                     }
                     .disabled(ollamaService.modelToPull.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ollamaService.isPullingModel || ollamaService.isRemovingModel)
                 }

                 if ollamaService.isPullingModel {
                     ProgressView(value: ollamaService.pullProgress).progressViewStyle(.linear)
                     HStack {
                         Text(ollamaService.pullStage.capitalized)
                         Spacer()
                         Text(String(format: "%.0f%%", ollamaService.pullProgress * 100))
                     }
                     .font(.caption).foregroundColor(.secondary)
                 }
                 if let error = ollamaService.modelPullError {
                     Text("Pull Error: \(error)").foregroundColor(.red).font(.caption)
                 }
                 if let error = ollamaService.modelRemoveError {
                     Text("Removal Error: \(error)").foregroundColor(.red).font(.caption)
                 }
            }

            Divider()

            // MARK: - Advanced Parameters
             VStack(alignment: .leading, spacing: 10) {
                 Text("Advanced Generation Parameters:").font(.headline)
                 
                 HStack {
                     Text("Temperature:").frame(width: 150, alignment: .leading)
                     Slider(value: $ollamaProfile.temperature, in: 0.0...2.0)
                     Text("\(ollamaProfile.temperature, specifier: "%.2f")").frame(width: 40)
                 }
                 HStack {
                     Text("Top K:").frame(width: 150, alignment: .leading)
                     Stepper(value: $ollamaProfile.topK, in: 0...200) { Text("\(ollamaProfile.topK)") }
                 }
                 HStack {
                     Text("Top P:").frame(width: 150, alignment: .leading)
                     Slider(value: $ollamaProfile.topP, in: 0.0...1.0)
                     Text("\(ollamaProfile.topP, specifier: "%.2f")").frame(width: 40)
                 }
                 HStack {
                     Text("Repeat Penalty:").frame(width: 150, alignment: .leading)
                     Slider(value: $ollamaProfile.repeatPenalty, in: 1.0...2.0)
                     Text("\(ollamaProfile.repeatPenalty, specifier: "%.2f")").frame(width: 40)
                 }
                 HStack {
                     Text("Context Window:").frame(width: 150, alignment: .leading)
                     TextField("", value: $ollamaProfile.contextWindowSize, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                 }
                 HStack {
                     Text("GPU Layers:").frame(width: 150, alignment: .leading)
                     Stepper(value: $ollamaProfile.gpuLayers, in: -1...100) { Text(ollamaProfile.gpuLayers == -1 ? "All" : "\(ollamaProfile.gpuLayers)") }
                 }
             }
            
             Divider().padding(.vertical, 5)

             VStack(alignment: .leading, spacing: 10) {
                 Text("File Handling Parameters:").font(.subheadline)
                 HStack {
                     Text("Max Inline Chars:").frame(width: 150, alignment: .leading)
                     TextField("", value: $ollamaProfile.maxInlineChars, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                     Text("chars").foregroundColor(.gray)
                 }
                 HStack {
                     Text("Max Attached Files:").frame(width: 150, alignment: .leading)
                     Stepper(value: $ollamaProfile.maxAttachedFiles, in: 1...20) { Text("\(ollamaProfile.maxAttachedFiles) files") }
                 }
                 Picker("Text File Strategy:", selection: $ollamaProfile.textFileInclusionStrategy) {
                     ForEach(TextFileInclusionStrategy.allCases) { Text($0.displayName).tag($0) }
                 }
                 Picker("Image Handling:", selection: $ollamaProfile.imageHandlingStrategy) {
                     ForEach(OllamaImageHandlingStrategy.allCases) { Text($0.displayName).tag($0) }
                 }
                 Picker("Binary File Handling:", selection: $ollamaProfile.binaryFileHandlingStrategy) {
                     ForEach(OllamaBinaryFileHandlingStrategy.allCases) { Text($0.displayName).tag($0) }
                 }
             }

            Spacer()
        }
        .padding()
        .confirmationDialog("Confirm Model Removal", isPresented: $showingRemovalConfirmation, presenting: modelToRemoveFromName) { modelName in
            Button("Remove '\(modelName)'", role: .destructive) {
                Task {
                    await ollamaService.removeModel(name: modelName, baseURL: ollamaProfile.baseURL)
                }
            }
        } message: { modelName in
            Text("Are you sure you want to remove the model '\(modelName)'? This cannot be undone.")
        }
        .onDisappear {
             ollamaService.clearAllModelActionStatuses()
        }
        .onChange(of: ollamaProfile.id) {
            // When the parent view switches which profile we are editing,
            // reset the local editable name to match the new profile.
            editableProfileName = ollamaProfile.profileName
        }
    }
}

// MARK: - Preview Provider (Corrected)
struct LocalAISettingsView_Previews: PreviewProvider {
    static func createMockViewModel() -> MainApplicationViewModel {
        let profileStore = OllamaProfileStore()
        let defaultProfile = OllamaProfile.defaultProfile()
        profileStore.profiles = [defaultProfile]
        profileStore.selectedProfileID = defaultProfile.id
        
        let vm = MainApplicationViewModel(
            ollamaProfileStore: profileStore,
            agentStore: AgentStore()
        )
        return vm
    }
    
    @State static var mockProfile = OllamaProfile.defaultProfile()

    static var previews: some View {
        let viewModel = createMockViewModel()
        
        // Configure the shared service for the preview
        let service = OllamaService.shared
        service.localModels = ["llama3:8b", "mistral:7b", "gemma:2b"]
        service.llmModelName = "mistral:7b"
        service.serverStatus = .connected
        
        return LocalAISettingsView(ollamaProfileBinding: $mockProfile)
            .environmentObject(viewModel)
            .frame(width: 500, height: 1100)
            .previewDisplayName("Default State")
    }
}
