// Views/Settings/LocalAISettingsView.swift
import SwiftUI
import os

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LocalAISettingsView")

// MARK: - Local AI Settings Detail View
struct LocalAISettingsView: View {
    // Observe OllamaService for Ollama-specific state and actions
    @ObservedObject var ollamaService: OllamaService
    // Observe MainApplicationViewModel for general settings like advanced parameters
    @ObservedObject var mainViewModel: MainApplicationViewModel

    // --- State for Confirmation Dialog ---
    @State private var showingRemovalConfirmation = false
    @State private var modelToRemoveFromName: String? = nil // Store the name of the model to remove

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Local AI (Ollama)")
                .font(.title2)
                .padding(.bottom, 5)

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
                        // Bind selection to ollamaService.llmModelName (@AppStorage via OllamaService)
                        Picker("Select a model", selection: $ollamaService.llmModelName) {
                            ForEach(ollamaService.localModels, id: \.self) { modelName in
                                Text(modelName).tag(modelName)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: ollamaService.llmModelName) { newValue, _ in // Updated for iOS 17+
                             logger.debug("Ollama model selected: \(newValue)")
                             // llmModelName in OllamaService is @AppStorage, changes are auto-saved.
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
                                           ollamaService.llmModelName == modelName) // Cannot remove active model
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
                     // Bind to ollamaService.modelToPull
                     TextField("e.g., llama2:7b, mistral:latest", text: $ollamaService.modelToPull)
                         .textFieldStyle(RoundedBorderTextFieldStyle())
                         .disabled(ollamaService.isPullingModel || ollamaService.isRemovingModel)
                         .onChange(of: ollamaService.modelToPull) { _, _ in // Updated for iOS 17+
                              ollamaService.clearPullActionStatus()
                              // ollamaService.clearRemoveActionStatus() // Not strictly needed here, pull status is enough
                          }

                     Button {
                         Task {
                             // Call action on ollamaService
                             await ollamaService.pullModel(name: ollamaService.modelToPull)
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
                 if let error = ollamaService.modelRemoveError { // Display removal errors from OllamaService
                     Text("Removal Error: \(error)")
                         .foregroundColor(.red)
                         .font(.callout)
                 }
             }

            Divider()

            // --- Advanced Generation Parameters Section ---
            // These parameters are still bound to MainApplicationViewModel's @AppStorage properties
             VStack(alignment: .leading, spacing: 10) {
                 Text("Advanced Generation Parameters:")
                     .font(.headline)
                     .padding(.bottom, 5)
                 .disabled(ollamaService.isPullingModel || ollamaService.isRemovingModel) // Use ollamaService state

                 HStack {
                     Text("Temperature:")
                         .frame(width: 150, alignment: .leading)
                         .help("Controls randomness. Higher is more creative.")
                     Slider(value: $mainViewModel.ollamaTemperature, in: 0.0...2.0) { Text("Temperature") }
                     .controlSize(.regular)
                     Text("\(mainViewModel.ollamaTemperature, format: .number.precision(.fractionLength(2)))")
                         .frame(width: 40, alignment: .trailing)
                 }
                 HStack {
                     Text("Top K:")
                          .frame(width: 150, alignment: .leading)
                          .help("Limits sampling to top K tokens.")
                     Stepper(value: $mainViewModel.ollamaTopK, in: 0...200) { Text("Top K") }
                     .controlSize(.regular)
                     Text("\(mainViewModel.ollamaTopK)")
                          .frame(width: 40, alignment: .trailing)
                 }
                 HStack {
                      Text("Top P:")
                          .frame(width: 150, alignment: .leading)
                           .help("Limits sampling based on cumulative probability.")
                      Slider(value: $mainViewModel.ollamaTopP, in: 0.0...1.0) { Text("Top P") }
                      .controlSize(.regular)
                      Text("\(mainViewModel.ollamaTopP, format: .number.precision(.fractionLength(2)))")
                           .frame(width: 40, alignment: .trailing)
                 }
                 HStack {
                      Text("Repeat Penalty:")
                          .frame(width: 150, alignment: .leading)
                           .help("Penalizes repeated tokens.")
                      Slider(value: $mainViewModel.ollamaRepeatPenalty, in: 1.0...2.0) { Text("Repeat Penalty") }
                      .controlSize(.regular)
                      Text("\(mainViewModel.ollamaRepeatPenalty, format: .number.precision(.fractionLength(2)))")
                           .frame(width: 40, alignment: .trailing)
                 }
                 HStack {
                      Text("Context Window:")
                           .frame(width: 150, alignment: .leading)
                           .help("Model's context window size (tokens).")
                      TextField("e.g., 4096", value: $mainViewModel.ollamaContextWindowSize, format: .number)
                          .textFieldStyle(RoundedBorderTextFieldStyle())
                          .frame(width: 80)
                          .controlSize(.regular)
                 }
                 HStack {
                      Text("GPU Layers:")
                           .frame(width: 150, alignment: .leading)
                           .help("Number of layers to offload to GPU (-1 for all).")
                      Stepper(value: $mainViewModel.ollamaGpuLayers, in: -1...100) { Text("GPU Layers") }
                      .controlSize(.regular)
                      Text(mainViewModel.ollamaGpuLayers == -1 ? "All" : "\(mainViewModel.ollamaGpuLayers)")
                           .frame(width: 40, alignment: .trailing)
                 }
             }
            Spacer()
        }
        .confirmationDialog("Confirm Model Removal",
                            isPresented: $showingRemovalConfirmation,
                            presenting: modelToRemoveFromName) { modelNameInDialog in
            Button("Remove '\(modelNameInDialog)'", role: .destructive) {
                Task {
                    // Call action on ollamaService
                    await ollamaService.removeModel(name: modelNameInDialog)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { modelNameInDialog in
            Text("Are you sure you want to remove the model '\(modelNameInDialog)'? This action cannot be undone.")
        }
        .onAppear {
            logger.debug("LocalAISettingsView appeared.")
            // Initial status/model load is typically handled by MainApplicationViewModel's selectedSettingsSection didSet
            // or by OllamaService's init or a specific trigger.
            // Ensure statuses are clear on appear if navigating back to this tab.
            ollamaService.clearAllModelActionStatuses()
            showingRemovalConfirmation = false
            modelToRemoveFromName = nil
        }
        .onDisappear {
             ollamaService.clearAllModelActionStatuses()
             showingRemovalConfirmation = false
             modelToRemoveFromName = nil
        }
    }
}

// MARK: - Preview Provider
struct LocalAISettingsView_Previews: PreviewProvider {
    static var mockOllamaService: OllamaService {
        let service = OllamaService()
        service.localModels = ["llama3:8b", "mistral:7b", "gemma:2b"]
        service.llmModelName = "mistral:7b" // This is @AppStorage in OllamaService
        service.serverStatus = .connected
        return service
    }

    static var mockMainViewModel: MainApplicationViewModel {
        // MainApplicationViewModel's init now takes OllamaService
        let vm = MainApplicationViewModel(ollamaService: mockOllamaService)
        // Set other mainViewModel properties if needed for preview
        vm.ollamaTemperature = 0.5
        vm.ollamaTopK = 50
        return vm
    }
    
    // Preview helper for confirmation dialog
    struct ConfirmationDialogPreviewWrapper: View {
        @ObservedObject var ollamaService: OllamaService
        @ObservedObject var mainViewModel: MainApplicationViewModel
        @State private var showingConfirmation = true // Start with dialog shown
        @State private var modelToRemove: String? = "gemma:2b"

        var body: some View {
            LocalAISettingsView(ollamaService: ollamaService, mainViewModel: mainViewModel)
                 .padding()
                 .frame(width: 500)
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
            LocalAISettingsView(ollamaService: mockOllamaService, mainViewModel: mockMainViewModel)
                .padding()
                .frame(width: 500)
                .previewLayout(.sizeThatFits)
                .previewDisplayName("Default State")

            // To preview pulling state:
            let pullingOllamaService: OllamaService = {
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
            LocalAISettingsView(ollamaService: pullingOllamaService, mainViewModel: MainApplicationViewModel(ollamaService: pullingOllamaService))
                .padding()
                .frame(width: 500)
                .previewLayout(.sizeThatFits)
                .previewDisplayName("Pulling State")
                
            ConfirmationDialogPreviewWrapper(ollamaService: mockOllamaService, mainViewModel: mockMainViewModel)
                 .previewDisplayName("Confirmation Dialog")
        }
    }
}
