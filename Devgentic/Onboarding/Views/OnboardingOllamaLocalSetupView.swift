// Onboarding/Views/OnboardingOllamaLocalSetupView.swift
import SwiftUI

struct OnboardingOllamaLocalSetupView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    // Helper to determine if the start button should be disabled
    private var isStartDisabled: Bool {
        if viewModel.isScriptRunning { return true } // Disable if running
        // Disable if "Other..." is selected but custom name is empty
        if viewModel.selectedRecommendedModelName == nil && viewModel.customModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        // Disable if no recommended model is selected AND custom name is empty (edge case)
        if viewModel.selectedRecommendedModelName == nil && viewModel.customModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
             return true
        }
        // Otherwise, enable
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Setting Up Local Ollama")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select a recommended model or enter a custom one, then start the setup. The script will check your installation and download the model.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true) // Allow wrapping

            Divider()

            // --- Model Selection Area ---
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Model:")
                    .font(.headline)

                Picker("Select Model", selection: $viewModel.selectedRecommendedModelName) {
                    ForEach(viewModel.recommendedOllamaModels) { model in
                        // Display name and size in the picker row
                        HStack {
                            Text(model.displayName)
                            Text("(\(model.sizeDescription))").foregroundColor(.secondary)
                        }
                        .tag(model.name as String?) // Tag with the actual model name (optional)
                    }
                    Text("Other...").tag(nil as String?) // Tag for the "Other" option
                }
                .labelsHidden() // Use the Text label above instead
                .disabled(viewModel.isScriptRunning)

                // --- Conditional Custom Model TextField ---
                if viewModel.selectedRecommendedModelName == nil { // Show only if "Other..." is selected
                    VStack(alignment: .leading, spacing: 3) {
                         Text("Custom Model Name:")
                             .font(.caption)
                             .foregroundColor(.secondary)
                         TextField("Enter exact Ollama model name (e.g., llama3:70b)", text: $viewModel.customModelName)
                             .textFieldStyle(.roundedBorder)
                             .disabled(viewModel.isScriptRunning)
                    }
                    .padding(.leading, 5) // Indent slightly
                }
            }
            .padding(.bottom, 10) // Space after model selection

            // --- Start Button ---
            Button {
                viewModel.startOllamaSetupScript()
            } label: {
                HStack {
                    if viewModel.isScriptRunning && !viewModel.requiresAdminPrivilege {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.circle.fill")
                    }
                    Text(viewModel.isScriptRunning ? "Running Setup..." : "Start Setup")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isStartDisabled) // Use computed property for disabled state

            Divider().padding(.vertical, 5)

            // --- Progress / Log Output ---
            Text("Setup Progress:")
                .font(.headline)

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(viewModel.scriptLogOutput.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // --- Increased Height ---
                .frame(minHeight: 200, maxHeight: 300) // Increased height
                .background(Color(.textBackgroundColor))
                .border(Color.gray.opacity(0.5))
                .onChange(of: viewModel.scriptLogOutput.count) { _, _ in
                    if let lastIndex = viewModel.scriptLogOutput.indices.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollProxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            }

            // --- Status Indicators ---
            VStack(alignment: .leading) {
                if viewModel.requiresAdminPrivilege {
                    HStack {
                        Image(systemName: "shield.lefthalf.filled")
                        Text("Admin approval needed. Check for password prompt.")
                    }
                    .foregroundColor(.orange).padding(.bottom, 2)
                }
                if let errorMessage = viewModel.scriptErrorMessage {
                    HStack {
                        Image(systemName: "xmark.octagon.fill")
                        Text(errorMessage).lineLimit(2)
                    }
                    .foregroundColor(.red).padding(.bottom, 2)
                }
                if viewModel.isSetupComplete && viewModel.scriptErrorMessage == nil {
                     HStack {
                         Image(systemName: "checkmark.circle.fill")
                         Text("Setup Successful!")
                     }
                     .foregroundColor(.green).padding(.bottom, 2)
                 }
            }
            .frame(minHeight: 20) // Reserve space

            Spacer() // Pushes buttons to the bottom

            // --- Navigation Buttons ---
            HStack {
                Button("Back") {
                    viewModel.goToPreviousStep()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScriptRunning)

                Spacer()

                Button("Finish") {
                    viewModel.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                // Use the correct logic for enabling Finish
                .disabled(!viewModel.isSetupComplete || viewModel.isScriptRunning || viewModel.scriptErrorMessage != nil)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top)

        }
        .padding(30)
        .onDisappear {
             // Optional: Cancel script if view disappears unexpectedly?
             // viewModel.cancelScriptExecution()
         }
    }
}

#Preview {
    let previewViewModel = OnboardingViewModel()
    // Simulate different states for preview
    previewViewModel.scriptLogOutput = ["Checking Ollama...", "Ollama found.", "Pulling model 'llama3'..."]
    // previewViewModel.selectedRecommendedModelName = nil // Simulate "Other..." selected
    // previewViewModel.customModelName = "my-custom-model"
    // previewViewModel.isScriptRunning = true
    // previewViewModel.requiresAdminPrivilege = true
    // previewViewModel.scriptErrorMessage = "Download failed: Network Error."
    // previewViewModel.isSetupComplete = true // Simulate completion state

    return OnboardingOllamaLocalSetupView(viewModel: previewViewModel)
        .frame(width: 450, height: 550) // Adjust height for new UI
}

