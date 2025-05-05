// Onboarding/Views/OnboardingCategorySelectView.swift
import SwiftUI

struct OnboardingCategorySelectView: View {
    // Use @ObservedObject to react to changes in the shared ViewModel
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose Backend Type")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom, 5) // Add some space below the title

            // --- Ollama Option ---
            OnboardingCardView(
                title: "Local Server (Ollama)",
                description: "Run models locally on your Mac using Ollama. Requires Ollama installation.",
                systemImageName: "desktopcomputer", // Replace with better icon if possible
                isSelected: viewModel.selectedCategory == .ollama,
                action: {
                    viewModel.selectedCategory = .ollama
                }
            )

            // --- Agent Option ---
            OnboardingCardView(
                title: "Devgentic Agent",
                description: "Connect to a specialized Agent, running locally or hosted elsewhere.",
                systemImageName: "puzzlepiece.extension.fill", // Example icon
                isSelected: viewModel.selectedCategory == .agent,
                action: {
                    viewModel.selectedCategory = .agent
                }
            )

            Spacer() // Pushes buttons to the bottom

            // --- Navigation Buttons ---
            HStack {
                Button("Back") {
                    viewModel.goToPreviousStep()
                }
                .buttonStyle(.bordered) // Standard back button style

                Spacer() // Push buttons apart

                Button("Next") {
                    viewModel.goToNextStep()
                }
                .buttonStyle(.borderedProminent) // Primary action style
                .disabled(viewModel.selectedCategory == nil) // Disable if nothing selected
                .keyboardShortcut(.defaultAction) // Bind to Enter key
            }
            .controlSize(.large) // Consistent button size
            .padding(.top) // Add space above buttons

        }
        .padding(30) // Add padding around the entire VStack content
    }
}

// Assume BackendType exists in Models/BackendType.swift with .ollama and .agent cases
// If not, this Preview won't work correctly until that enum is defined.
#Preview {
    // Create a dummy ViewModel for the preview
    let previewViewModel = OnboardingViewModel()
    return OnboardingCategorySelectView(viewModel: previewViewModel)
        .frame(width: 450, height: 400) // Match OnboardingRootView preview size
        // You can pre-select an option for previewing selection state:
        // .onAppear { previewViewModel.selectedCategory = .ollama }
}