// Onboarding/Views/OnboardingRootView.swift
import SwiftUI

struct OnboardingRootView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    var onComplete: () -> Void

    var body: some View {
        VStack { // Main container for the switching views
            // Switch view based on the ViewModel's current step
            switch viewModel.currentStep {
            case .welcome:
                OnboardingWelcomeView(onGetStarted: viewModel.goToNextStep)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .selectCategory:
                OnboardingCategorySelectView(viewModel: viewModel)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .selectMethod:
                OnboardingMethodSelectView(viewModel: viewModel)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .configureOllamaLocal:
                OnboardingOllamaLocalSetupView(viewModel: viewModel)
                     .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .configureOllamaApi:
                OnboardingOllamaApiSetupView(viewModel: viewModel)
                     .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .configureAgentLocal:
                 Text("Step 4c: Configure Agent Local (View Placeholder)") // Placeholder
                      .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .configureAgentApi:
                OnboardingAgentApiSetupView(viewModel: viewModel)
                     .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

             case .complete:
                 Text("Setup Complete!")
                     .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            viewModel.completeOnboarding()
                        }
                     }
                     .transition(.opacity)
            }
        }
        // Apply animation to the transitions between steps
        // .animation(.default, value: viewModel.currentStep) // Keep animation on container if desired, or remove if causing issues
        // --- ADJUSTED FRAME ---
        // Remove fixed/max height to allow vertical resizing based on content
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 600,
               minHeight: 400) // Keep minHeight if needed, remove maxHeight
        // --- END ADJUSTED FRAME ---
        // Ensure the onComplete callback is passed to the ViewModel
        .onAppear {
            viewModel.onComplete = self.onComplete
        }
    }
}

#Preview {
    OnboardingRootView(onComplete: { print("Onboarding Completed!") })
}
