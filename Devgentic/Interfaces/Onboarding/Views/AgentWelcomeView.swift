// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
////
////  AgentWelcomeView.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//// AgentWelcomeView.swift
////
////  AgentWelcomeView.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//import SwiftUI
//
//struct AgentWelcomeView: View {
//    var viewModel: AgentOnboardingViewModel
//
//    var body: some View {
//        VStack(spacing: 20) {
//            Spacer()
//
//            Image(systemName: "brain.head.profile.fill") // More AI/Agent relevant icon
//                .resizable()
//                .scaledToFit()
//                .frame(width: 70, height: 70)
//                .foregroundColor(.accentColor)
//                .padding(.bottom, 10)
//
//            Text("Welcome to Devgentic Agent Setup")
//                .font(.largeTitle)
//                .fontWeight(.medium)
//
//            Text("Let's get your local AI agent running. This setup process will guide you through the necessary steps.")
//                .font(.body)
//                .multilineTextAlignment(.center)
//                .foregroundColor(.secondary)
//                .padding(.horizontal, 40)
//            
//            // REMOVED: The 'if viewModel.isLoading' block, as 'isLoading' and 'loadingMessage'
//            // are no longer general properties in the interactive ViewModel.
//            // Loading states are handled within the interactive setup stages.
//
//            Spacer()
//            
//            Button(action: {
//                // This should call the method in AgentOnboardingViewModel
//                // that transitions to the new interactive setup flow.
//                viewModel.startOnboardingFlow()
//            }) {
//                Text("Get Started")
//                    .fontWeight(.semibold)
//                    .frame(minWidth: 0, maxWidth: .infinity)
//                    .padding()
//                    .foregroundColor(.white)
//                    .background(Color.accentColor)
//                    .cornerRadius(10)
//            }
//            .buttonStyle(.plain) // Use plain to allow full custom background
//            // REMOVED: .disabled(viewModel.isLoading)
//            .padding(.horizontal, 50)
//            .padding(.bottom, 10)
//            
//            Button(action: {
//                // Quit the app or provide an alternative action if setup is truly cancelled from welcome.
//                // If part of a larger onboarding, this might go back or call a different cancel logic.
//                // For now, keeping terminate as per original, but consider if viewModel.cancelSetup() is more appropriate
//                // if it resets to a state *before* even .welcome if needed.
//                // If cancelSetup() from welcome should just quit, NSApplication.shared.terminate(nil) is fine.
//                // If it should reset the VM and stay on welcome, that's also an option.
//                NSApplication.shared.terminate(nil)
//            }) {
//                Text("Cancel Setup & Quit") // Clarified button action
//            }
//            .buttonStyle(.link)
//            // REMOVED: .disabled(viewModel.isLoading)
//
//            Spacer()
//        }
//        .padding()
//        // Ensure this view is used when viewModel.currentFlowStep == .welcome
//    }
//}
//
//// Preview
//struct AgentWelcomeView_Previews: PreviewProvider {
//    static var previews: some View {
//        // For the preview to work, AgentOnboardingViewModel needs to be initialized.
//        // The onComplete and onAgentReady closures are part of its init.
//        let vm = AgentOnboardingViewModel(
//            onComplete: { print("Preview: Onboarding Completed!") },
//            onAgentReady: { url, pid in print("Preview: Agent Ready at \(url) with PID \(pid)") }
//        )
//        // Ensure the preview starts in the .welcome flow step
//        vm.currentFlowStep = .welcome
//        
//        return AgentWelcomeView(viewModel: vm)
//            .frame(width: 500, height: 450)
//    }
//}
