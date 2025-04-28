// Onboarding/Views/OnboardingOllamaLocalSetupView.swift
import SwiftUI

struct OnboardingOllamaLocalSetupView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Setting Up Local Ollama")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Select the Ollama models you want to download, then start the setup. The script will check your installation and download models.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true) // Allow wrapping

            // --- Model Selector ---
            OllamaModelSelectorView(
                models: viewModel.recommendedOllamaModels,
                selectedModelNames: $viewModel.selectedModelNames
            )
            .disabled(viewModel.isScriptRunning) // Disable selection while running

            // Optionally, add a TextField for custom models if needed
            // TextField("Other model name (optional)", text: $viewModel.customModelName) ...

            // --- Start Button ---
            Button {
                viewModel.startOllamaSetupScript()
            } label: {
                HStack {
                    if viewModel.isScriptRunning && !viewModel.requiresAdminPrivilege { // Show spinner only when actively running
                        ProgressView().controlSize(.small)
                    } else {
                        // Show different icons based on state? Maybe just play always.
                        Image(systemName: "play.circle.fill")
                    }
                    Text(viewModel.isScriptRunning ? "Running Setup..." : "Start Setup")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Disable if script is running OR if no models are selected
            .disabled(viewModel.isScriptRunning || viewModel.selectedModelNames.isEmpty)


            // --- Progress / Log Output ---
            Text("Setup Progress:")
                .font(.headline)
                .padding(.top, 5) // Reduced top padding

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) { // Reduced spacing
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
                .frame(minHeight: 100, maxHeight: 150) // Flexible height
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
             // Use ZStack to potentially overlay messages if needed, or just VStack
            VStack(alignment: .leading) {
                if viewModel.requiresAdminPrivilege {
                    HStack {
                        Image(systemName: "shield.lefthalf.filled")
                        Text("Admin approval needed. Check for password prompt.")
                    }
                    .foregroundColor(.orange)
                    .padding(.bottom, 2)
                }

                if let errorMessage = viewModel.scriptErrorMessage {
                    HStack {
                        Image(systemName: "xmark.octagon.fill")
                        Text(errorMessage)
                            .lineLimit(2) // Allow error message wrapping
                    }
                    .foregroundColor(.red)
                    .padding(.bottom, 2)
                }

                // Show success message clearly when done
                if viewModel.isSetupComplete && viewModel.scriptErrorMessage == nil {
                     HStack {
                         Image(systemName: "checkmark.circle.fill")
                         Text("Setup Successful!")
                     }
                     .foregroundColor(.green)
                     .padding(.bottom, 2)
                 }
            }
            .frame(minHeight: 20) // Reserve some space for status messages


            Spacer() // Pushes buttons to the bottom

            // --- Navigation Buttons ---
            HStack {
                Button("Back") {
                    viewModel.goToPreviousStep()
                    // Consider cancelling script if running (needs cancel implementation)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isScriptRunning) // Disable Back while running

                Spacer()

                Button("Finish") {
                    viewModel.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                 // Enable only when setup is complete AND script isn't running AND no error
                .disabled(!viewModel.isSetupComplete || viewModel.isScriptRunning || viewModel.scriptErrorMessage != nil)
                .keyboardShortcut(.defaultAction) // Allow enter if Finish is enabled
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
    previewViewModel.selectedModelNames = ["llama3"]
    // previewViewModel.isScriptRunning = true
    // previewViewModel.requiresAdminPrivilege = true
    // previewViewModel.scriptErrorMessage = "Download failed: Network Error."
    // previewViewModel.isSetupComplete = true // Simulate completion state

    return OnboardingOllamaLocalSetupView(viewModel: previewViewModel)
        .frame(width: 450, height: 550) // Adjust height for new UI
}