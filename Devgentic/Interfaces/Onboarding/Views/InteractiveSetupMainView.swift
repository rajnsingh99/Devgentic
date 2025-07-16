//
//  InteractiveSetupMainView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI

struct InteractiveSetupMainView: View {
    @ObservedObject var viewModel: AgentOnboardingViewModel

    var body: some View {
        HSplitView { // Or HStack if HSplitView is not desired/available directly in vanilla SwiftUI for macOS target
            InteractiveSetupSidebarView(viewModel: viewModel)
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 300) // Sidebar width
            
            // Right panel content, dynamic based on current stage
            VStack {
                switch viewModel.currentInteractiveStage {
                case .pythonVerification:
                    if viewModel.showEmbeddedPythonInstallPrompt {
                        // Embed PythonInstallPromptView directly or a simplified version
                        PythonInstallPromptView(viewModel: viewModel, isEmbedded: true)
                    } else {
                        PythonVerificationPanelView(viewModel: viewModel)
                    }
                case .ollamaSetup:
                    OllamaSetupPanelView(viewModel: viewModel)
                case .agentServerSetup:
                    AgentServerPanelView(viewModel: viewModel)
                }
                Spacer() // Pushes content to the top
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Right panel takes remaining space
            .padding()
        }
        .onAppear {
            // If coming from welcome, `startOnboardingFlow` in VM should have set initial stage.
            // If direct entry for debugging, ensure first stage is set.
            if viewModel.currentInteractiveStage == .pythonVerification && viewModel.pythonVerificationStatus == .pending && !viewModel.showEmbeddedPythonInstallPrompt {
                 // If needed, trigger initial action for the first stage, or ensure UI reflects pending state.
            }
        }
    }
}

struct InteractiveSetupMainView_Previews: PreviewProvider {
    static var previews: some View {
        let vm = AgentOnboardingViewModel(onComplete: {}, onAgentReady: {_,_ in})
        vm.currentFlowStep = .interactiveSetup // Simulate being in this step
        return InteractiveSetupMainView(viewModel: vm)
    }
}
