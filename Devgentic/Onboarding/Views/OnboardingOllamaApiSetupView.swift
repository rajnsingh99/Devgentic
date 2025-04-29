// Onboarding/Views/OnboardingOllamaApiSetupView.swift
import SwiftUI

struct OnboardingOllamaApiSetupView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Connect to Ollama API")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the Base URL of your running Ollama server (usually `http://localhost:11434`). You can also specify a default model.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true) // Allow wrapping

            // --- Input Fields ---
            VStack(alignment: .leading) {
                Text("Ollama Base URL:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g., http://localhost:11434", text: $viewModel.ollamaApiUrl)
                    .textFieldStyle(.roundedBorder)
                    // .textContentType(.URL) // <-- REMOVE THIS LINE
                    // .keyboardType(.URL)     // <-- REMOVE THIS LINE
                    .disableAutocorrection(true) // Keep this if desired
                    .disabled(viewModel.apiTestInProgress)
            }

            VStack(alignment: .leading) {
                Text("Default Model Name (Optional):")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g., llama3", text: $viewModel.ollamaApiModel)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.apiTestInProgress)
            }

            // --- Connection Test ---
            HStack {
                Button {
                    viewModel.testOllamaApiConnection()
                } label: {
                    HStack {
                        if viewModel.apiTestInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "network")
                        }
                        Text(viewModel.apiTestInProgress ? "Testing..." : "Test Connection")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.apiTestInProgress || viewModel.ollamaApiUrl.isEmpty)

                Spacer()

                // --- Status Indicator ---
                if viewModel.apiTestInProgress {
                    Text("Checking...")
                        .foregroundColor(.secondary)
                } else if let errorMsg = viewModel.apiTestError {
                     HStack {
                         Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                         Text("Failed").foregroundColor(.red)
                             .help(errorMsg)
                     }
                } else if viewModel.isApiConnectionOk == true {
                     HStack {
                         Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                         Text("Success").foregroundColor(.green)
                     }
                } else {
                    Text("Untested")
                         .foregroundColor(.secondary)
                }
            }
            .frame(height: 25)

            Spacer() // Pushes buttons to the bottom

            // --- Navigation Buttons ---
            HStack {
                Button("Back") {
                    viewModel.goToPreviousStep()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.apiTestInProgress)

                Spacer()

                Button("Finish") {
                    viewModel.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isApiConnectionOk != true || viewModel.apiTestInProgress)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top)

        }
        .padding(30)
    }
}

#Preview {
    let previewViewModel = OnboardingViewModel()
    return OnboardingOllamaApiSetupView(viewModel: previewViewModel)
         .frame(width: 450, height: 400)
}
