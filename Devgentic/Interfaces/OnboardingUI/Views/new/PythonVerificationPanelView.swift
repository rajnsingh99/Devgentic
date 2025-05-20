//
//  PythonVerificationPanelView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI

struct PythonVerificationPanelView: View {
    @ObservedObject var viewModel: AgentOnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Step 1: Python Environment Verification")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Devgentic requires Python version 3.8 or newer. This step will check your system for a compatible Python installation.")
                .font(.callout)
                .foregroundColor(.secondary)
            
            if viewModel.pythonVerificationStatus == .inProgress {
                ProgressView()
                    .padding(.vertical)
                Text(viewModel.pythonVerificationMessage)
                    .font(.caption)
                    .foregroundColor(.gray)
            } else if viewModel.pythonVerificationStatus == .completed {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text(viewModel.pythonVerificationMessage)
                }
            } else if viewModel.pythonVerificationStatus == .failed || viewModel.pythonVerificationStatus == .awaitingUserInput {
                 HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(viewModel.pythonVerificationMessage)
                }
            }


            Spacer()

            HStack {
                if viewModel.pythonVerificationStatus != .completed {
                    Button(viewModel.pythonActionButtonTitle) {
                        viewModel.handlePythonAction()
                    }
                    .disabled(!viewModel.isPythonActionButtonEnabled || viewModel.pythonVerificationStatus == .inProgress)
                    .keyboardShortcut(.defaultAction)
                }

                Spacer()

                Button("Next") {
                    viewModel.proceedToOllamaSetup()
                }
                .disabled(!viewModel.isPythonNextButtonEnabled)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PythonVerificationPanelView_Previews: PreviewProvider {
    static var previews: some View {
        let vm = AgentOnboardingViewModel(onComplete: {}, onAgentReady: {_,_ in})
        vm.currentFlowStep = .interactiveSetup
        vm.currentInteractiveStage = .pythonVerification
        // vm.pythonVerificationStatus = .inProgress
        // vm.pythonVerificationMessage = "Checking Python..."
        return PythonVerificationPanelView(viewModel: vm)
    }
}
