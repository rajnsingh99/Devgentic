//
//  AgentWelcomeView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI

struct AgentWelcomeView: View {
    @ObservedObject var viewModel: AgentOnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "brain.head.profile.fill") // More AI/Agent relevant icon
                .resizable()
                .scaledToFit()
                .frame(width: 70, height: 70)
                .foregroundColor(.accentColor)
                .padding(.bottom, 10)

            Text("Welcome to Devgentic Agent Setup")
                .font(.largeTitle)
                .fontWeight(.medium)

            Text("Let's get your local AI agent running. This automated process will set up Python, Ollama, and the Devgentic agent on your Mac.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)
            
            if viewModel.isLoading {
                 ProgressView()
                     .padding()
                 Text(viewModel.loadingMessage)
                     .font(.caption)
                     .foregroundColor(.secondary)
            }


            Spacer()
            
            Button(action: {
                viewModel.startSetup()
            }) {
                Text("Get Started")
                    .fontWeight(.semibold)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .padding()
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain) // Use plain to allow full custom background
            .disabled(viewModel.isLoading)
            .padding(.horizontal, 50)
            .padding(.bottom, 10)
            
            Button(action: {
                // Quit the app or provide an alternative action
                NSApplication.shared.terminate(nil)
            }) {
                Text("Cancel Setup")
            }
            .buttonStyle(.link)
            .disabled(viewModel.isLoading)


            Spacer()
        }
        .padding()
    }
}

// Preview
struct AgentWelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        AgentWelcomeView(viewModel: AgentOnboardingViewModel(onComplete: {}))
            .frame(width: 500, height: 450)
    }
}
