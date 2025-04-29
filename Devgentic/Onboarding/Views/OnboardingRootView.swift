// Onboarding/Views/OnboardingRootView.swift
import SwiftUI

struct OnboardingRootView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    var onComplete: () -> Void

    var body: some View {
        VStack {
            // Switch view based on the ViewModel's current step
            switch viewModel.currentStep {
            // ... cases welcome, selectCategory, selectMethod ...
            // ... case configureOllamaLocal, configureOllamaApi ...

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

            // --- Placeholder Case for Agent Local ---
            case .configureAgentLocal:
                 Text("Step 4c: Configure Agent Local (View Placeholder)")
                      .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            // --- UPDATED Case for Step 4d ---
            case .configureAgentApi:
                OnboardingAgentApiSetupView(viewModel: viewModel) // Instantiate the new view
                     .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))

            // ... case .complete ...
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
        .animation(.default, value: viewModel.currentStep)
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 600,
               minHeight: 400, idealHeight: 500, maxHeight: 600)
        .onAppear {
            viewModel.onComplete = self.onComplete
        }
    }
}

#Preview {
    OnboardingRootView(onComplete: { print("Onboarding Completed!") })
}