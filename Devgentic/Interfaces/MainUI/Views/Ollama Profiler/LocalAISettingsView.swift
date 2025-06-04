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
    @ObservedObject var ollamaService: OllamaService
    @ObservedObject var mainViewModel: MainApplicationViewModel
    @Binding var ollamaProfile: OllamaProfile

    @State private var showingRemovalConfirmation = false
    @State private var modelToRemoveFromName: String? = nil
    
    // New state for editable profile name
    @State private var editableProfileName: String
    @State private var showUpdateFeedback = false

    // MARK: - Initializer to accept the binding and initialize editableProfileName
    init(ollamaService: OllamaService, mainViewModel: MainApplicationViewModel, ollamaProfileBinding: Binding<OllamaProfile>) {
        self.ollamaService = ollamaService
        self.mainViewModel = mainViewModel
        self._ollamaProfile = ollamaProfileBinding
        // Initialize editableProfileName with the current profile's name
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
                            logger.info("Profile name updated to '\(trimmedName)' for profile ID \(ollamaProfile.id.uuidString)")
                            withAnimation {
                                showUpdateFeedback = true
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                                await MainActor.run {
                                    withAnimation {
                                        showUpdateFeedback = false
                                    }
                                }
                            }
                        }
                    } label: {
                        if showUpdateFeedback {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Text("Update")
                        }
                    }
                    .disabled(!isProfileNameChanged || showUpdateFeedback)
                    .buttonStyle(.bordered)
                    .frame(width: showUpdateFeedback ? 40 : 80) // Adjust width for feedback icon
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
                        ProgressView("Loading Models...")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let error = ollamaService.modelLoadingError {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if ollamaService.localModels.isEmpty {
                        Text("No models found. Ensure Ollama is running and models are downloaded.")
                             .foregroundColor(.gray)
                             .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("Select a model", selection: $ollamaProfile.llmModelName) {
                            ForEach(ollamaService.localModels, id: \.self) { modelName in
                                Text(modelName).tag(modelName)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: ollamaProfile.llmModelName) { newValue, _ in
                             logger.debug("Ollama model selected for profile '\(ollamaProfile.profileName)': \(newValue)")
                         }
                    }
                }
                .controlSize(.regular)

                 if !ollamaService.isLoadingModels && ollamaService.modelLoadingError == nil && !ollamaService.localModels.isEmpty {
                     Divider()
                     Text("Installed Models:")
                         .font(.headline)

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
                                 .disabled(ollamaService.isPullingModel ||
                                           ollamaService.isRemovingModel ||
                                           ollamaProfile.llmModelName == modelName)
                                 .foregroundColor(.red)
                                 .buttonStyle(PlainButtonStyle())
                                 .help("Remove \(modelName)")
                             }
                             .padding(.vertical, 2)
                         }
                     }
                     .padding(.top, 5)
                 }

                if !ollamaService.isLoadingModels && ollamaService.modelLoadingError == nil && ollamaService.localModels.isEmpty {
                    Text("Try downloading a model below!")
                         .font(.callout)
                         .foregroundColor(.gray)
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
                     TextField("e.g., llama2:7b, mistral:latest", text: $ollamaService.modelToPull)
                         .textFieldStyle(RoundedBorderTextFieldStyle())
                         .disabled(ollamaService.isPullingModel || ollamaService.isRemovingModel)
                         .onChange(of: ollamaService.modelToPull) { _, _ in
                              ollamaService.clearPullActionStatus()
                          }

                     Button {
                         Task {
                             await ollamaService.pullModel(name: ollamaService.modelToPull, baseURL: ollamaProfile.baseURL)
                         }
                     } label: {
                         if ollamaService.isPullingModel {
                             ProgressView().controlSize(.small)
                         } else if ollamaService.modelPullError == nil && ollamaService.pullStage == "Complete" {
                             Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                         } else {
                              Image(systemName: "arrow.down.circle")
                         }
                     }
                     .disabled(ollamaService.modelToPull.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                               ollamaService.isPullingModel ||
                               ollamaService.isRemovingModel)
                 }
                 .controlSize(.regular)

                 if ollamaService.isPullingModel {
                     ProgressView(value: ollamaService.pullProgress)
                         .progressViewStyle(.linear)
                         .frame(maxWidth: .infinity, alignment: .leading)
                     HStack {
                          Text(ollamaService.pullStage)
                              .font(.callout)
                              .foregroundColor(.gray)
                          Spacer()
                           if ollamaService.isPullingModel {
                              Text(String(format: "%.0f%%", ollamaService.pullProgress * 100))
                                   .font(.callout)
                                   .foregroundColor(.gray)
                           }
                     }
                 } else {
                      if ollamaService.modelPullError == nil && ollamaService.pullStage == "Complete" && !ollamaService.modelToPull.isEmpty {
                          Text("Successfully pulled '\(ollamaService.modelToPull)'.")
                              .foregroundColor(.green)
                              .font(.callout)
                      }
                 }
                 if let error = ollamaService.modelPullError {
                     Text("Pull Error: \(error)")
                         .foregroundColor(.red)
                         .font(.callout)
                 }
                 if let error = ollamaService.modelRemoveError {
                     Text("Removal Error: \(error)")
                         .foregroundColor(.red)
                         .font(.callout)
                 }
             }

            Divider()

            // MARK: - Bind Advanced Generation and File Handling Parameters to ollamaProfile
             VStack(alignment: .leading, spacing: 10) {
                 Text("Advanced Generation Parameters:")
                     .font(.headline)
                     .padding(.bottom, 5)
                 
                 HStack {
                     Text("Temperature:")
                         .frame(width: 150, alignment: .leading)
                         .help("Controls randomness. Higher is more creative.")
                     Slider(value: $ollamaProfile.temperature, in: 0.0...2.0) { Text("Temperature") }
                     .controlSize(.regular)
                     Text("\(ollamaProfile.temperature, format: .number.precision(.fractionLength(2)))")
                         .frame(width: 40, alignment: .trailing)
                 }
                 HStack {
                     Text("Top K:")
                          .frame(width: 150, alignment: .leading)
                          .help("Limits sampling to top K tokens.")
                     Stepper(value: $ollamaProfile.topK, in: 0...200) { Text("Top K: \(ollamaProfile.topK)") }
                     .controlSize(.regular)
                 }
                 HStack {
                      Text("Top P:")
                          .frame(width: 150, alignment: .leading)
                           .help("Limits sampling based on cumulative probability.")
                      Slider(value: $ollamaProfile.topP, in: 0.0...1.0) { Text("Top P") }
                      .controlSize(.regular)
                      Text("\(ollamaProfile.topP, format: .number.precision(.fractionLength(2)))")
                           .frame(width: 40, alignment: .trailing)
                 }
                 HStack {
                      Text("Repeat Penalty:")
                          .frame(width: 150, alignment: .leading)
                           .help("Penalizes repeated tokens.")
                      Slider(value: $ollamaProfile.repeatPenalty, in: 1.0...2.0) { Text("Repeat Penalty") }
                      .controlSize(.regular)
                      Text("\(ollamaProfile.repeatPenalty, format: .number.precision(.fractionLength(2)))")
                           .frame(width: 40, alignment: .trailing)
                 }
                 HStack {
                      Text("Context Window:")
                           .frame(width: 150, alignment: .leading)
                           .help("Model's context window size (tokens).")
                      TextField("e.g., 4096", value: $ollamaProfile.contextWindowSize, format: .number)
                          .textFieldStyle(RoundedBorderTextFieldStyle())
                          .frame(width: 80)
                          .controlSize(.regular)
                 }
                 HStack {
                      Text("GPU Layers:")
                           .frame(width: 150, alignment: .leading)
                           .help("Number of layers to offload to GPU (-1 for all).")
                      Stepper(value: $ollamaProfile.gpuLayers, in: -1...100) { Text("GPU Layers: \(ollamaProfile.gpuLayers == -1 ? "All" : "\(ollamaProfile.gpuLayers)")") }
                      .controlSize(.regular)
                 }

                Divider().padding(.vertical, 5)

                Text("File Handling Parameters:")
                    .font(.subheadline)
                    .padding(.bottom, 3)

                HStack {
                    Text("Max Inline Chars:")
                        .frame(width: 150, alignment: .leading)
                        .help("Maximum characters from a text/source file to include directly in the prompt. Larger files are referenced by path. (Default: 5000)")
                    TextField("", value: $ollamaProfile.maxInlineChars, format: .number)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 80)
                        .controlSize(.regular)
                        .multilineTextAlignment(.trailing)
                    Text("chars")
                        .foregroundColor(.gray)
                }

                HStack {
                    Text("Max Attached Files:")
                        .frame(width: 150, alignment: .leading)
                        .help("Maximum number of files to reference or include in a single prompt to Ollama. (Default: 5)")
                    Stepper(value: $ollamaProfile.maxAttachedFiles, in: 1...20) {
                        Text("\(ollamaProfile.maxAttachedFiles) files")
                    }
                    .controlSize(.regular)
                }
                 
                HStack {
                    Text("Text File Strategy:")
                        .frame(width: 150, alignment: .leading)
                        .help("Choose how text and source code files are presented to Ollama.")
                    Picker("Text File Strategy", selection: $ollamaProfile.textFileInclusionStrategy) {
                        ForEach(TextFileInclusionStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .controlSize(.regular)
                }

                HStack {
                    Text("Image Handling:")
                        .frame(width: 150, alignment: .leading)
                        .help("How to handle image attachments for text-only Ollama models.")
                    Picker("Image Handling", selection: $ollamaProfile.imageHandlingStrategy) {
                        ForEach(OllamaImageHandlingStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .controlSize(.regular)
                }

                HStack {
                    Text("Binary File Handling:")
                        .frame(width: 150, alignment: .leading)
                        .help("How to handle non-text, non-image binary files (PDF, DOCX) for text-only Ollama models.")
                    Picker("Binary File Handling", selection: $ollamaProfile.binaryFileHandlingStrategy) {
                        ForEach(OllamaBinaryFileHandlingStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .controlSize(.regular)
                }

             }
             .disabled(ollamaService.isPullingModel || ollamaService.isRemovingModel)

            Spacer()
        }
        .padding()
        .confirmationDialog("Confirm Model Removal",
                            isPresented: $showingRemovalConfirmation,
                            presenting: modelToRemoveFromName) { modelNameInDialog in
            Button("Remove '\(modelNameInDialog)'", role: .destructive) {
                Task {
                    await ollamaService.removeModel(name: modelNameInDialog, baseURL: ollamaProfile.baseURL)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { modelNameInDialog in
            Text("Are you sure you want to remove the model '\(modelNameInDialog)'? This action cannot be undone.")
        }
        .onAppear {
            logger.debug("LocalAISettingsView appeared for profile: \(ollamaProfile.profileName). Current editable name: '\(editableProfileName)'")
            ollamaService.clearAllModelActionStatuses()
            
            if editableProfileName != ollamaProfile.profileName {
                editableProfileName = ollamaProfile.profileName
                logger.debug("Synced editableProfileName to bound profile name: '\(ollamaProfile.profileName)' on appear.")
            }

            // Always update OllamaService's baseURL and llmModelName to match the current profile
            // and trigger a status check/model load for the new baseURL.
            if ollamaService.ollamaBaseURL != ollamaProfile.baseURL {
                 logger.debug("Profile baseURL (\(ollamaProfile.baseURL)) differs from OllamaService baseURL (\(ollamaService.ollamaBaseURL)) on appear. Updating OllamaService's baseURL and triggering status check.")
                 ollamaService.ollamaBaseURL = ollamaProfile.baseURL
                 Task {
                     await ollamaService.checkServerStatusAndUpdateModels()
                 }
            } else {
                // If baseURL hasn't changed, but models might not be loaded yet (e.g., first appear)
                // or if status is unknown/disconnected, trigger a check.
                if ollamaService.serverStatus == .unknown || ollamaService.serverStatus == .disconnected || ollamaService.localModels.isEmpty {
                    logger.debug("OllamaService status is unknown/disconnected or models are empty on appear. Triggering status check.")
                    Task {
                        await ollamaService.checkServerStatusAndUpdateModels()
                    }
                }
            }

            if ollamaService.llmModelName != ollamaProfile.llmModelName {
                 logger.debug("Profile llmModelName (\(ollamaProfile.llmModelName)) differs from OllamaService llmModelName (\(ollamaService.llmModelName)) on appear. Updating OllamaService's llmModelName.")
                 ollamaService.llmModelName = ollamaProfile.llmModelName
            }
        }
        .onDisappear {
             ollamaService.clearAllModelActionStatuses()
             modelToRemoveFromName = nil
             showingRemovalConfirmation = false
        }
        .onChange(of: ollamaProfile.id) { oldProfileID, newProfileID in
            logger.debug("LocalAISettingsView: ollamaProfile.id changed from \(oldProfileID.uuidString) to \(newProfileID.uuidString).")
            
            // Attempt to find the new profile in the store to ensure we have the freshest data.
            if let newProfileFromStore = mainViewModel.ollamaProfileStore.profiles.first(where: { $0.id == newProfileID }) {
                if editableProfileName != newProfileFromStore.profileName {
                    editableProfileName = newProfileFromStore.profileName
                    logger.debug("Reset editableProfileName to '\(newProfileFromStore.profileName)' from store for new profile ID.")
                }
                // When profile ID changes, always update OllamaService's baseURL and modelName
                // and trigger a fresh status check/model load for the new profile.
                if ollamaService.ollamaBaseURL != newProfileFromStore.baseURL {
                    ollamaService.ollamaBaseURL = newProfileFromStore.baseURL
                    logger.info("Profile ID changed. Updating OllamaService baseURL to '\(newProfileFromStore.baseURL)' and triggering status check.")
                    Task {
                        await ollamaService.checkServerStatusAndUpdateModels()
                    }
                }
                if ollamaService.llmModelName != newProfileFromStore.llmModelName {
                    ollamaService.llmModelName = newProfileFromStore.llmModelName
                    logger.debug("Profile ID changed. Updating OllamaService llmModelName to '\(newProfileFromStore.llmModelName)'.")
                }

            } else {
                // Fallback: If the profile isn't in the store (e.g., if store update is lagging or profile was deleted),
                // use the name from the `ollamaProfile` binding, which should represent the new profile.
                // This assumes the `ollamaProfile` binding passed by the parent (`OllamaProfilesView`) IS the new profile.
                if editableProfileName != ollamaProfile.profileName {
                    editableProfileName = ollamaProfile.profileName
                    logger.warning("Profile with ID \(newProfileID.uuidString) not found in store. Reset editableProfileName using the current binding's profileName: '\(ollamaProfile.profileName)'.")
                }
                // If the profile is somehow not found in the store, we should still try to update OllamaService
                // based on the binding's current values.
                if ollamaService.ollamaBaseURL != ollamaProfile.baseURL {
                    ollamaService.ollamaBaseURL = ollamaProfile.baseURL
                    logger.warning("Profile not found in store. Updating OllamaService baseURL from binding to '\(ollamaProfile.baseURL)' and triggering status check.")
                    Task {
                        await ollamaService.checkServerStatusAndUpdateModels()
                    }
                }
                if ollamaService.llmModelName != ollamaProfile.llmModelName {
                    ollamaService.llmModelName = ollamaProfile.llmModelName
                    logger.warning("Profile not found in store. Updating OllamaService llmModelName from binding to '\(ollamaProfile.llmModelName)'.")
                }
            }
        }
        .onChange(of: ollamaProfile.baseURL) { oldURL, newURL in
            if oldURL != newURL {
                logger.debug("LocalAISettingsView: ollamaProfile.baseURL changed from '\(oldURL)' to '\(newURL)' for profile '\(ollamaProfile.profileName)'.")
                // When baseURL changes, update OllamaService's baseURL and trigger a status check/model load.
                ollamaService.ollamaBaseURL = newURL
                logger.info("baseURL of active profile '\(ollamaProfile.profileName)' changed. Triggering checkServerStatusAndUpdateModels.")
                Task {
                    await ollamaService.checkServerStatusAndUpdateModels()
                }
            }
        }
        .onChange(of: ollamaProfile.llmModelName) { oldModel, newModel in
            if oldModel != newModel {
                logger.debug("LocalAISettingsView: ollamaProfile.llmModelName changed from '\(oldModel ?? "nil")' to '\(newModel)' for profile '\(ollamaProfile.profileName)'.")
                // Only update OllamaService's llmModelName if this profile is the currently selected one in the store.
                // This prevents other profiles from changing the global OllamaService's active model.
                if mainViewModel.ollamaProfileStore.selectedProfileID == ollamaProfile.id {
                    ollamaService.llmModelName = newModel
                }
            }
        }
    }
}

// MARK: - Preview Provider
// (Preview Provider remains the same as the previous version)
struct LocalAISettingsView_Previews: PreviewProvider {
    @State static var defaultMockProfile = OllamaProfile.defaultProfile()
    @State static var pullingMockProfile = OllamaProfile.defaultProfile()

    static var mockOllamaService: OllamaService {
        let service = OllamaService()
        service.localModels = ["llama3:8b", "mistral:7b", "gemma:2b"]
        service.llmModelName = "mistral:7b"
        service.serverStatus = .connected
        return service
    }

    static var mockOllamaProfileStore: OllamaProfileStore {
        let store = OllamaProfileStore()
        var profileForStore = OllamaProfile.defaultProfile()
        profileForStore.profileName = "Default Preview Profile" // Give it a distinct name for clarity
        store.profiles = [profileForStore]
        store.selectedProfileID = profileForStore.id
        defaultMockProfile = profileForStore // Ensure the @State var for preview also uses this
        return store
    }

    static var mockMainViewModel: MainApplicationViewModel {
        let vm = MainApplicationViewModel(ollamaService: mockOllamaService, ollamaProfileStore: mockOllamaProfileStore)
        return vm
    }
    
    struct ConfirmationDialogPreviewWrapper: View {
        @ObservedObject var ollamaService: OllamaService
        @ObservedObject var mainViewModel: MainApplicationViewModel
        @State private var showingConfirmation = true
        @State private var modelToRemove: String? = "gemma:2b"
        @State private var mockProfileForDialog = OllamaProfile.defaultProfile()

        var body: some View {
            LocalAISettingsView(ollamaService: ollamaService, mainViewModel: mainViewModel, ollamaProfileBinding: $mockProfileForDialog)
                 .confirmationDialog("Confirm Model Removal",
                                     isPresented: $showingConfirmation,
                                     presenting: modelToRemove) { name in
                     Button("Remove '\(name)'", role: .destructive) {}
                     Button("Cancel", role: .cancel) {}
                 } message: { name in
                     Text("Are you sure you want to remove '\(name)'?")
                 }
        }
    }

    static var previews: some View {
        Group {
            LocalAISettingsView(ollamaService: mockOllamaService, mainViewModel: mockMainViewModel, ollamaProfileBinding: $defaultMockProfile)
                .frame(width: 500, height: 800)
                .previewLayout(.sizeThatFits)
                .previewDisplayName("Default State")
                .onAppear {
                    // For preview, ensure defaultMockProfile is what's in the store if needed for consistency
                    if mockOllamaProfileStore.profiles.isEmpty {
                        mockOllamaProfileStore.profiles.append(defaultMockProfile)
                        mockOllamaProfileStore.selectedProfileID = defaultMockProfile.id
                    }
                }


            let pullingOllamaServiceInstance: OllamaService = {
                let service = OllamaService()
                service.serverStatus = .connected
                service.localModels = ["mistral:7b"]
                service.llmModelName = "mistral:7b"
                service.isPullingModel = true
                service.modelToPull = "phi3:mini"
                service.pullStage = "downloading manifest"
                service.pullProgress = 0.45
                return service
            }()
            
            let pullingMockProfileStoreInstance: OllamaProfileStore = {
                let store = OllamaProfileStore()
                 var pullingProfile = OllamaProfile.defaultProfile()
                 pullingProfile.profileName = "Pulling Preview Profile"
                 pullingMockProfile = pullingProfile // Update the @State var
                store.profiles = [pullingProfile]
                store.selectedProfileID = pullingProfile.id
                return store
            }()

            LocalAISettingsView(
                ollamaService: pullingOllamaServiceInstance,
                mainViewModel: MainApplicationViewModel(ollamaService: pullingOllamaServiceInstance, ollamaProfileStore: pullingMockProfileStoreInstance),
                ollamaProfileBinding: $pullingMockProfile
            )
                .frame(width: 500, height: 800)
                .previewLayout(.sizeThatFits)
                .previewDisplayName("Pulling State")
                
            ConfirmationDialogPreviewWrapper(ollamaService: mockOllamaService, mainViewModel: mockMainViewModel)
                 .frame(width: 500, height: 800)
                 .previewDisplayName("Confirmation Dialog")
        }
    }
}
