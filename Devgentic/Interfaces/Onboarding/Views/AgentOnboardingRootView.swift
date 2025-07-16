// AgentOnboardingRootView.swift
//
//  AgentOnboardingRootView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI

struct AgentOnboardingRootView: View {
    @StateObject private var viewModel: AgentOnboardingViewModel
    
    init(onComplete: @escaping () -> Void, onAgentReady: @escaping (URL, Int32) -> Void) {
        _viewModel = StateObject(wrappedValue: AgentOnboardingViewModel(onComplete: onComplete, onAgentReady: onAgentReady))
    }

    var body: some View {
        VStack {
            // Determine the view based on the currentFlowStep of the ViewModel
            switch viewModel.currentFlowStep {
            case .welcome:
                AgentWelcomeView(viewModel: viewModel) // Existing welcome view
            case .interactiveSetup:
                InteractiveSetupMainView(viewModel: viewModel) // New interactive setup view
            case .setupFailed:
                // Ensure AgentOnboardingViewModel conforms to SetupFailedViewModelProtocol
                SetupFailedView(viewModel: viewModel)
            case .setupComplete:
                SetupCompleteScreen(onFinish: {
                    viewModel.onComplete?() // Call the original onComplete closure
                }) // Existing completion screen
            }
        }
        .animation(.default, value: viewModel.currentFlowStep)
        .frame(minWidth: 700, idealWidth: 800, maxWidth: 900, // Adjusted for wider interactive UI
               minHeight: 500, idealHeight: 600, maxHeight: 700)
    }
}

// Preview for AgentOnboardingRootView
struct AgentOnboardingRootView_Previews: PreviewProvider {
    static var previews: some View {
        AgentOnboardingRootView(
            onComplete: { print("Preview: Onboarding Completed!") },
            onAgentReady: { url, pid in print("Preview: Agent Ready at \(url) with PID \(pid)") }
        )
    }
}
