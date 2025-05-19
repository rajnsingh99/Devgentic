//
//  AgentOnboardingRootView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI

struct AgentOnboardingRootView: View {
    // Use @StateObject for ViewModel creation and lifecycle management within this view
    @StateObject private var viewModel: AgentOnboardingViewModel
    
    // Initializer to accept both onComplete and onAgentReady closures
    init(onComplete: @escaping () -> Void, onAgentReady: @escaping (URL, Int32) -> Void) {
        // Pass both closures to the AgentOnboardingViewModel
        _viewModel = StateObject(wrappedValue: AgentOnboardingViewModel(onComplete: onComplete, onAgentReady: onAgentReady))
    }

    var body: some View {
        VStack {
            Group {
                switch viewModel.currentStep {
                case .welcome:
                    AgentWelcomeView(viewModel: viewModel)
                case .prerequisitesCheck, .environmentSetup:
                    AutomatedSetupInProgressView(viewModel: viewModel)
                case .pythonInstallNeeded:
                    // This state is primarily handled by the sheet.
                    // Showing the welcome view allows the user to retry or see options again.
                    AgentWelcomeView(viewModel: viewModel)
                case .setupFailed:
                    SetupFailedView(viewModel: viewModel)
                }
            }
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
        }
        .animation(.default, value: viewModel.currentStep) // Apply animation to step transitions
        .frame(minWidth: 480, idealWidth: 550, maxWidth: 700,
               minHeight: 400, idealHeight: 500, maxHeight: 600)
        .sheet(isPresented: $viewModel.showPythonInstallSheet) {
            // The sheet for Python installation prompt
            PythonInstallPromptView(viewModel: viewModel)
        }
        // The onComplete and onAgentReady closures are now handled by the ViewModel.
    }
}

struct AgentOnboardingRootView_Previews: PreviewProvider {
    static var previews: some View {
        AgentOnboardingRootView(
            onComplete: { print("Preview: Onboarding Completed!") },
            onAgentReady: { url, pid in print("Preview: Agent Ready at \(url) with PID \(pid)") }
        )
    }
}
