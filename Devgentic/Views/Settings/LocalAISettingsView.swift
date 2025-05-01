// Views/LocalAISettingsView.swift
import SwiftUI
import os // Import os for logging

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "LocalAISettingsView")


// MARK: - Local AI Settings Detail View
struct LocalAISettingsView: View {
    // Now observing the ViewModel directly to access its state
    @ObservedObject var viewModel: MainApplicationViewModel

    // --- State for Confirmation Dialog ---
    @State private var showingRemovalConfirmation = false
    @State private var modelToRemove: String? = nil
    // -------------------------------------


    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Local AI (Ollama)")
                .font(.title2)
                .padding(.bottom, 5)

            Divider()

            // --- Displaying and Selecting Models ---
            VStack(alignment: .leading, spacing: 10) { // Group model selection controls
                Text("Available Models:") // Add a label for the section
                    .font(.headline)

                HStack {
                    Text("Ollama Model:")
                        .frame(width: 150, alignment: .leading) // Consistent label width

                    // Show loading indicator if models are being fetched
                    if viewModel.isLoadingModels {
                        ProgressView("Loading Models...")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading) // Take available space
                    } else if let error = viewModel.modelLoadingError {
                        // Show error message if fetching failed
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading) // Take available space
                    } else if viewModel.localOllamaModels.isEmpty {
                         // Message if no models are found
                        Text("No models found. Make sure Ollama is running and you have downloaded models.")
                             .foregroundColor(.gray)
                             .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    else {
                        // Use a Picker to select from available models
                        // Bind selection directly to viewModel.llmModelName (@AppStorage)
                        Picker("Select a model", selection: $viewModel.llmModelName) {
                            // Ensure the currently selected model is in the list,
                            // otherwise Picker might show a blank or default.
                            // We handle setting a default in the ViewModel if needed.
                            ForEach(viewModel.localOllamaModels, id: \.self) { modelName in
                                Text(modelName).tag(modelName) // Use model name as the tag
                            }
                        }
                        .labelsHidden() // Hide the redundant "Select a model" label
                        .frame(maxWidth: .infinity, alignment: .leading) // Allow picker to expand
                        // onChange is now on viewModel.llmModelName
                        .onChange(of: viewModel.llmModelName) { newValue in
                             logger.debug("Ollama model selected: \(newValue)")
                             // llmModelName is @AppStorage, changes are auto-saved.
                             // No need to manually update llmModelName here.
                         }
                    }
                }
                .controlSize(.regular)

                 // Display the list of models below the picker to add remove buttons
                 if !viewModel.isLoadingModels && viewModel.modelLoadingError == nil && !viewModel.localOllamaModels.isEmpty {
                     Divider() // Optional divider
                     Text("Installed Models:")
                         .font(.headline)

                     // Use a List or ForEach to display models with remove buttons
                     // Using ForEach in a VStack for simpler styling within settings panel
                     VStack(alignment: .leading) {
                         ForEach(viewModel.localOllamaModels, id: \.self) { modelName in
                             HStack {
                                 Text(modelName) // Display the model name
                                     .frame(maxWidth: .infinity, alignment: .leading) // Take available space

                                 // --- Remove Button ---
                                 Button {
                                     // Action: Set the model to remove and show the confirmation dialog
                                     modelToRemove = modelName // Store the model name
                                     showingRemovalConfirmation = true // Show the dialog
                                 } label: {
                                     // Show a spinner if THIS model is being removed
                                     if viewModel.isRemovingModel && viewModel.removingModelName == modelName {
                                         ProgressView()
                                              .controlSize(.small)
                                     } else {
                                         Image(systemName: "trash") // Trash icon
                                     }
                                 }
                                 // Disable button if:
                                 // - A pull is in progress
                                 // - Any removal action is in progress
                                 // - This model is the currently selected model
                                 // Check against viewModel.llmModelName
                                 .disabled(viewModel.isPullingModel ||
                                           viewModel.isRemovingModel || // Disable all delete buttons if any removal is in progress
                                           viewModel.llmModelName == modelName) // Cannot remove the active model
                                 .foregroundColor(.red) // Style the trash icon in red
                                 .buttonStyle(PlainButtonStyle()) // Use plain style for icon button
                                 .help("Remove \(modelName)") // Add a tooltip
                                 // --- End Remove Button ---
                             }
                             .padding(.vertical, 2) // Add vertical padding between model rows
                         }
                     }
                     .padding(.top, 5)
                 }


                 // Add suggestion to pull if no models found and not loading/errored
                if !viewModel.isLoadingModels && viewModel.modelLoadingError == nil && viewModel.localOllamaModels.isEmpty {
                    Text("Try downloading a model below!")
                         .font(.callout)
                         .foregroundColor(.gray)
                }
            }
            // --- End Displaying and Selecting Models ---

            Divider() // Add a divider before the Pull Model section

            // --- Pull Model Section ---
            VStack(alignment: .leading, spacing: 10) { // Group pull model controls
                 Text("Download New Model:") // Add a label for the section
                     .font(.headline)

                 HStack {
                     Text("Model Name:")
                          .frame(width: 150, alignment: .leading) // Consistent label width

                     TextField("e.g., llama2:7b, mistral:latest", text: $viewModel.modelToPull)
                         .textFieldStyle(RoundedBorderTextFieldStyle())
                         .disabled(viewModel.isPullingModel || viewModel.isRemovingModel) // Disable input while any action is pulling/removing
                         // Optional: Clear status/error when user starts typing again
                         .onChange(of: viewModel.modelToPull) { _ in
                              viewModel.clearPullStatus() // Clear pull specific status/error
                              viewModel.clearRemoveStatus() // Clear remove specific status/error
                          }

                     Button {
                         // Trigger the pull action in the ViewModel
                         Task {
                             await viewModel.pullModelAction(name: viewModel.modelToPull)
                         }
                     } label: {
                         // Change button label based on state
                         if viewModel.isPullingModel {
                             ProgressView() // Show spinner while pulling
                                 .controlSize(.small)
                         } else if viewModel.modelPullError == nil && viewModel.pullStage == "Complete" {
                             // Show a checkmark after successful pull completion (using pullStage as a final state indicator)
                             Image(systemName: "checkmark.circle.fill")
                                 .foregroundColor(.green)
                         }
                         else {
                              Image(systemName: "arrow.down.circle") // Default download icon
                         }
                     }
                     // Disable the button if input is empty or already pulling/removing
                     .disabled(viewModel.modelToPull.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                               viewModel.isPullingModel ||
                               viewModel.isRemovingModel)
                 }
                 .controlSize(.regular)

                // --- Display Streaming Pull Progress ---
                 if viewModel.isPullingModel {
                     // Show the progress bar while pulling
                     ProgressView(value: viewModel.pullProgress) // Bind to pullProgress (0.0 to 1.0)
                         .progressViewStyle(.linear)
                         .frame(maxWidth: .infinity, alignment: .leading)

                     // Show the detailed status message
                     HStack {
                          Text(viewModel.pullStage) // e.g., "downloading", "extracting"
                              .font(.callout)
                              .foregroundColor(.gray)

                          Spacer() // Push percentage to the right

                          // Display percentage while pulling is in progress
                          // Use pullProgress directly as it's a non-optional Double
                           if viewModel.isPullingModel { // Condition to show the percentage text
                              Text(String(format: "%.0f%%", viewModel.pullProgress * 100))
                                   .font(.callout)
                                   .foregroundColor(.gray)
                           }
                     }

                 } else {
                      // Show final pull success status message if no error and stage is complete
                      // Use pullStage == "Complete" and check for no error
                      if viewModel.modelPullError == nil && viewModel.pullStage == "Complete" {
                          // Show success message including the name of the model that was pulled (stored in ViewModel.modelToPull initially)
                          Text("Successfully pulled \(viewModel.modelToPull.isEmpty ? "model" : "'\(viewModel.modelToPull)'").")
                              .foregroundColor(.green)
                      }
                      // Note: If there was a pull error, modelPullError will be non-nil and displayed below
                 }
                 // --- End Display Streaming Pull Progress ---

                 // Display specific pull error message if one exists
                 if let error = viewModel.modelPullError {
                     Text("Pull Error: \(error)") // Clarify it's a pull error
                         .foregroundColor(.red)
                         .font(.callout) // Use callout font for error details
                 }

                // --- Display Removal Error Message ---
                 if let error = viewModel.modelRemoveError {
                     Text("Removal Error: \(error)") // Display removal errors
                         .foregroundColor(.red)
                         .font(.callout)
                 }
                // --- End Display Removal Error Message ---

             }
            // --- End Pull Model Section ---

            Divider() // Add a divider before the Advanced Parameters section

            // --- Advanced Generation Parameters Section ---
             VStack(alignment: .leading, spacing: 10) {
                 Text("Advanced Generation Parameters:")
                     .font(.headline)
                     .padding(.bottom, 5)

                 // Disable all advanced controls while a model action is in progress
                 .disabled(viewModel.isPullingModel || viewModel.isRemovingModel)

                 // Temperature
                 HStack {
                     Text("Temperature:")
                         .frame(width: 150, alignment: .leading)
                         .help("Controls randomness (higher = more creative). Typical: 0.0 to 1.0+") // Tooltip

                     Slider(value: $viewModel.ollamaTemperature, in: 0.0...2.0) { // Provide a range (adjust as needed)
                         Text("Temperature") // Accessibility label
                     }
                     .controlSize(.regular)
                      // Display current value
                     Text("\(viewModel.ollamaTemperature, format: .number.precision(.fractionLength(2)))")
                         .frame(width: 40, alignment: .trailing) // Align value

                 }

                 // Top K
                 HStack {
                     Text("Top K:")
                          .frame(width: 150, alignment: .leading)
                          .help("Limits sampling to the top K most likely tokens. Typical: 0 to 100+") // Tooltip

                     // Using Stepper for integer values with a range
                     Stepper(value: $viewModel.ollamaTopK, in: 0...200) { // Provide a range
                         Text("Top K") // Accessibility label
                     }
                     .controlSize(.regular)
                      // Display current value
                     Text("\(viewModel.ollamaTopK)")
                          .frame(width: 40, alignment: .trailing) // Align value

                 }

                 // Top P
                 HStack {
                      Text("Top P:")
                          .frame(width: 150, alignment: .leading)
                           .help("Limits sampling based on cumulative probability. Typical: 0.0 to 1.0") // Tooltip

                      Slider(value: $viewModel.ollamaTopP, in: 0.0...1.0) { // Range 0.0 to 1.0
                           Text("Top P") // Accessibility label
                      }
                      .controlSize(.regular)
                       // Display current value
                      Text("\(viewModel.ollamaTopP, format: .number.precision(.fractionLength(2)))")
                           .frame(width: 40, alignment: .trailing) // Align value
                 }

                 // Repeat Penalty
                 HStack {
                      Text("Repeat Penalty:")
                          .frame(width: 150, alignment: .leading)
                           .help("Penalizes repeated tokens. Typical: 1.0 to 2.0") // Tooltip

                      Slider(value: $viewModel.ollamaRepeatPenalty, in: 1.0...2.0) { // Provide a range
                           Text("Repeat Penalty") // Accessibility label
                      }
                      .controlSize(.regular)
                       // Display current value
                      Text("\(viewModel.ollamaRepeatPenalty, format: .number.precision(.fractionLength(2)))")
                           .frame(width: 40, alignment: .trailing) // Align value
                 }

                 // Context Window Size
                 HStack {
                      Text("Context Window:")
                           .frame(width: 150, alignment: .leading)
                           .help("Sets the model's context window size (tokens).") // Tooltip

                     // Using TextField with formatter or Stepper for potentially large int
                     // Let's use Stepper with a larger range or TextField
                     // Using TextField for flexibility, could add validation later
                      TextField("e.g., 4096, 8192", value: $viewModel.ollamaContextWindowSize, format: .number)
                          .textFieldStyle(RoundedBorderTextFieldStyle())
                          .frame(width: 80) // Fixed width for input
                          .controlSize(.regular)
                          // Display current value (redundant with TextField, but can show formatting)
                          // Text("\(viewModel.ollamaContextWindowSize)") // Optional display outside TextField

                 }

                 // Number of GPU Layers
                 HStack {
                      Text("GPU Layers:")
                           .frame(width: 150, alignment: .leading)
                           .help("Number of layers to offload to the GPU (-1 for all).") // Tooltip

                     // Using Stepper for integer value, -1 is a special case
                      Stepper(value: $viewModel.ollamaGpuLayers, in: -1...100) { // Adjust max value as needed
                           Text("GPU Layers") // Accessibility label
                      }
                      .controlSize(.regular)
                       // Display current value
                      Text(viewModel.ollamaGpuLayers == -1 ? "All" : "\(viewModel.ollamaGpuLayers)") // Display "All" for -1
                           .frame(width: 40, alignment: .trailing) // Align value
                 }
             }
            // --- End Advanced Generation Parameters Section ---


            Spacer() // Push content to top
        }
        // Add the confirmation dialog to the view
        .confirmationDialog("Confirm Model Removal",
                            isPresented: $showingRemovalConfirmation,
                            presenting: modelToRemove) { modelName in // Use 'presenting' to pass the model name to the dialog
            // Dialog buttons
            Button("Remove '\(modelName)'", role: .destructive) {
                // Action to perform when 'Remove' is tapped in the dialog
                Task {
                    await viewModel.removeModelAction(name: modelName)
                }
            }
            Button("Cancel", role: .cancel) {
                // Action to perform when 'Cancel' is tapped
                // No action needed, dialog dismisses automatically
            }
        } message: { modelName in // Message content, also receives the presenting value
            Text("Are you sure you want to remove the model '\(modelName)'? This action cannot be undone.")
        }
         // Add a simple onAppear to log when the view appears (optional but helpful for debugging)
        .onAppear {
            logger.debug("LocalAISettingsView appeared.")
             // The loading of models is triggered by the selectedSettingsSection observer in the ViewModel
             // Ensure model action status is clear when the view appears initially
             viewModel.clearModelActionStatus()
             // Also clear dialog state
             showingRemovalConfirmation = false
             modelToRemove = nil
        }
        // Add an onDisappear to clear status messages and dialog state when leaving the tab
        .onDisappear {
             viewModel.clearModelActionStatus()
             showingRemovalConfirmation = false
             modelToRemove = nil
        }
    }
}

// MARK: - Preview Provider
struct LocalAISettingsView_Previews: PreviewProvider {
     // Create a mock ViewModel for previews
     // Note: ViewModel state for previews is typically set here directly or in a helper
    static var mockViewModel: MainApplicationViewModel {
        let vm = MainApplicationViewModel()
        // Simulate loaded models for the Picker and List
        vm.localOllamaModels = ["llama3:8b", "mistral:7b", "gemma:2b", "codellama:7b", "llama2:7b"]
        // vm.selectedOllamaModelName is replaced by llmModelName which is @AppStorage
        vm.llmModelName = "mistral:7b" // Set a default selection

        // Set up other ViewModel states for specific preview configurations if needed

        // Example: Set some advanced parameters to non-default values for preview
         vm.ollamaTemperature = 0.5
         vm.ollamaTopK = 50
         vm.ollamaTopP = 0.95
         vm.ollamaRepeatPenalty = 1.2
         vm.ollamaContextWindowSize = 8192
         vm.ollamaGpuLayers = 0 // Use CPU

        // For example, to preview the pulling state:
        // vm.modelToPull = "phi3:latest"
        // vm.isPullingModel = true
        // vm.pullStage = "downloading"
        // vm.pullProgress = 0.45

        return vm
    }

     // The main 'previews' static variable is required by the PreviewProvider protocol
     static var previews: some View {
         Group { // Use a Group to include multiple preview configurations

             // --- Preview 1: Default State ---
             LocalAISettingsView(viewModel: mockViewModel)
                 .padding()
                 .frame(width: 500) // Adjust frame for the new content
                 .previewLayout(.sizeThatFits)
                 .previewDisplayName("Default State")

             // --- Preview 2: Confirmation Dialog Showing ---
             // Use a helper struct that holds @State for the dialog
              ConfirmationDialogPreviewWrapper(viewModel: mockViewModel) // Pass the mock ViewModel here
                  .previewDisplayName("Confirmation Dialog Showing")

         }
     }
}

// MARK: - Preview Helper for Confirmation Dialog
// This helper struct is used to hold the @State variables needed
// to manually control the visibility of the confirmation dialog in a preview.
struct ConfirmationDialogPreviewWrapper: View {
    // Accept the ViewModel as an ObservedObject parameter
    @ObservedObject var viewModel: MainApplicationViewModel // Accept ViewModel here

    // @State variables to control the dialog's presentation for this preview
    @State private var showingRemovalConfirmation = true // Start with dialog shown
    @State private var modelToRemove: String? = "gemma:2b" // Simulate removing this model

    var body: some View {
        LocalAISettingsView(viewModel: viewModel) // Pass the received ViewModel
             .padding()
             .frame(width: 500)
             // Apply the confirmation dialog here as well,
             // bound to the State variables in THIS helper struct.
             .confirmationDialog("Confirm Model Removal", // Add the dialog here too
                                 isPresented: $showingRemovalConfirmation,
                                 presenting: modelToRemove) { modelName in
                 // Use dummy actions for preview buttons
                 Button("Remove '\(modelName)'", role: .destructive) { }
                 Button("Cancel", role: .cancel) { }
             } message: { modelName in
                 Text("Are you sure you want to remove the model '\(modelName)'? This action cannot be undone.")
             }
    }
}
