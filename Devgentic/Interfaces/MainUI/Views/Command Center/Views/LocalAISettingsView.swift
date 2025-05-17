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

    @State private var showingRemovalConfirmation = false
    @State private var modelToRemoveFromName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Local AI (Ollama)")
                .font(.title2)
                .padding(.bottom, 5)

            Divider()

            // --- Displaying and Selecting Models ---
            // ... (This section remains unchanged from the previous version) ...
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
                        Picker("Select a model", selection: $ollamaService.llmModelName) {
                            ForEach(ollamaService.localModels, id: \.self) { modelName in
                                Text(modelName).tag(modelName)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: ollamaService.llmModelName) { newValue, _ in
                             logger.debug("Ollama model selected: \(newValue)")
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
                                           ollamaService.llmModelName == modelName)
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
            // ... (This section remains unchanged from the previous version) ...
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
                 if let error = ollamaService.modelRemoveError {
                     Text("Removal Error: \(error)")
                         .foregroundColor(.red)
                         .font(.callout)
                 }
             }

            Divider()

            // --- Advanced Generation and File Handling Parameters Section ---
             VStack(alignment: .leading, spacing: 10) {
                 Text("Advanced Generation Parameters:")
                     .font(.headline)
                     .padding(.bottom, 5)
                 
                 // ... (Temperature, Top K, Top P, Repeat Penalty, Context Window, GPU Layers - unchanged) ...
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
                     Stepper(value: $mainViewModel.ollamaTopK, in: 0...200) { Text("Top K: \(mainViewModel.ollamaTopK)") }
                     .controlSize(.regular)
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
                      Stepper(value: $mainViewModel.ollamaGpuLayers, in: -1...100) { Text("GPU Layers: \(mainViewModel.ollamaGpuLayers == -1 ? "All" : "\(mainViewModel.ollamaGpuLayers)")") }
                      .controlSize(.regular)
                 }

                Divider().padding(.vertical, 5)

                Text("File Handling Parameters:")
                    .font(.subheadline)
                    .padding(.bottom, 3)

                // Phase 1 Settings (Max Inline Chars, Max Attached Files - unchanged)
                HStack {
                    Text("Max Inline Chars:")
                        .frame(width: 150, alignment: .leading)
                        .help("Maximum characters from a text/source file to include directly in the prompt. Larger files are referenced by path. (Default: 5000)")
                    TextField("", value: $mainViewModel.ollamaMaxInlineChars, format: .number)
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
                    Stepper(value: $mainViewModel.ollamaMaxAttachedFiles, in: 1...20) {
                        Text("\(mainViewModel.ollamaMaxAttachedFiles) files")
                    }
                    .controlSize(.regular)
                }
                 
                // NEW: Phase 2 Strategy Pickers
                HStack {
                    Text("Text File Strategy:")
                        .frame(width: 150, alignment: .leading)
                        .help("Choose how text and source code files are presented to Ollama.")
                    Picker("Text File Strategy", selection: $mainViewModel.ollamaTextFileInclusionStrategy) {
                        ForEach(TextFileInclusionStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    .labelsHidden() // Keep label for accessibility, but hide visually if Text view is sufficient
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .controlSize(.regular)
                }

                HStack {
                    Text("Image Handling:")
                        .frame(width: 150, alignment: .leading)
                        .help("How to handle image attachments for text-only Ollama models.")
                    Picker("Image Handling", selection: $mainViewModel.ollamaImageHandlingStrategy) {
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
                    Picker("Binary File Handling", selection: $mainViewModel.ollamaBinaryFileHandlingStrategy) {
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
                    await ollamaService.removeModel(name: modelNameInDialog)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { modelNameInDialog in
            Text("Are you sure you want to remove the model '\(modelNameInDialog)'? This action cannot be undone.")
        }
        .onAppear {
            logger.debug("LocalAISettingsView appeared.")
            ollamaService.clearAllModelActionStatuses()
        }
        .onDisappear {
             ollamaService.clearAllModelActionStatuses()
             modelToRemoveFromName = nil
             showingRemovalConfirmation = false
        }
    }
}

// MARK: - Preview Provider
struct LocalAISettingsView_Previews: PreviewProvider {
    static var mockOllamaService: OllamaService {
        let service = OllamaService()
        service.localModels = ["llama3:8b", "mistral:7b", "gemma:2b"]
        service.llmModelName = "mistral:7b"
        service.serverStatus = .connected
        return service
    }

    static var mockMainViewModel: MainApplicationViewModel {
        let vm = MainApplicationViewModel(ollamaService: mockOllamaService)
        vm.ollamaMaxInlineChars = 5000
        vm.ollamaMaxAttachedFiles = 5
        // Defaults for strategies are already set in MainApplicationViewModel's @AppStorage initializers
        // vm.ollamaTextFileInclusionStrategy = .preferInlining (already default)
        // vm.ollamaImageHandlingStrategy = .includePathWithWarning (already default)
        // vm.ollamaBinaryFileHandlingStrategy = .includePathWithWarning (already default)
        vm.ollamaTemperature = 0.75
        vm.ollamaTopK = 45
        return vm
    }
    
    struct ConfirmationDialogPreviewWrapper: View {
        @ObservedObject var ollamaService: OllamaService
        @ObservedObject var mainViewModel: MainApplicationViewModel
        @State private var showingConfirmation = true
        @State private var modelToRemove: String? = "gemma:2b"

        var body: some View {
            LocalAISettingsView(ollamaService: ollamaService, mainViewModel: mainViewModel)
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
                .frame(width: 500, height: 800) // Increased height for new pickers
                .previewLayout(.sizeThatFits)
                .previewDisplayName("Default State")

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
                .frame(width: 500, height: 800)
                .previewLayout(.sizeThatFits)
                .previewDisplayName("Pulling State")
                
            ConfirmationDialogPreviewWrapper(ollamaService: mockOllamaService, mainViewModel: mockMainViewModel)
                 .frame(width: 500, height: 800)
                 .previewDisplayName("Confirmation Dialog")
        }
    }
}
