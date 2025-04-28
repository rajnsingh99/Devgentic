// Onboarding/Views/OnboardingRootView.swift
import SwiftUI

struct OnboardingRootView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    var onComplete: () -> Void

    var body: some View {
        VStack {
            // Switch view based on the ViewModel's current step
            switch viewModel.currentStep {
            // ... other cases (welcome, selectCategory, selectMethod) ...

            case .welcome:
                OnboardingWelcomeView(onGetStarted: viewModel.goToNextStep)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .selectCategory:
                OnboardingCategorySelectView(viewModel: viewModel)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .selectMethod:
                OnboardingMethodSelectView(viewModel: viewModel)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))


            // --- UPDATED Case for Step 4a ---
            case .configureOllamaLocal:
                OnboardingOllamaLocalSetupView(viewModel: viewModel) // Instantiate the new view
                     .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))


            // --- Placeholder Cases for Other Configuration Steps (Step 4b, 4c, 4d) ---
            case .configureOllamaApi:
                Text("Step 4b: Configure Ollama API (View Placeholder)")
                     .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .configureAgentLocal:
                Text("Step 4c: Configure Agent Local (View Placeholder)")
                     .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            case .configureAgentApi:
                Text("Step 4d: Configure Agent API (View Placeholder)")
                     .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            // --- End of Placeholder Cases ---

            // ... case .complete ...
             case .complete:
                 Text("Setup Complete!")
                     .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            // Call the ViewModel's completion logic now
                            viewModel.completeOnboarding()
                        }
                     }
                     .transition(.opacity)

            }
        }
        // Apply animation to the transitions between steps
        .animation(.default, value: viewModel.currentStep)
         // Adjust frame size if needed, especially for the log view
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 600,
               minHeight: 400, idealHeight: 500, maxHeight: 600)
        // Ensure the onComplete callback is passed to the ViewModel
        .onAppear {
            viewModel.onComplete = self.onComplete
        }
    }
}

#Preview {
    OnboardingRootView(onComplete: { print("Onboarding Completed!") })
}