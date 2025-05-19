//
//  PythonInstallPromptView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI

struct PythonInstallPromptView: View {
    @ObservedObject var viewModel: AgentOnboardingViewModel
    @Environment(\.dismiss) var dismiss // To dismiss the sheet

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 50, height: 50)
                .foregroundColor(.orange)

            Text("Python Installation Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Devgentic requires Python 3.8 or newer to function. It was not found on your system.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 10) {
                Text("You have a few options:")
                Label("Install Python using Homebrew (Recommended): We can attempt to install Python for you using Homebrew. This is usually the easiest method if you have Homebrew installed.", systemImage: "wand.and.stars")
                Label("Install Python Manually: Visit python.org to download and install Python. After installation, restart this setup.", systemImage: "desktopcomputer")
            }
            .font(.subheadline)
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)


            HStack(spacing: 15) {
                Button("Attempt Homebrew Install") {
                    viewModel.attemptPythonInstallationViaHomebrew()
                    // ViewModel will set showPythonInstallSheet = false
                }
                .keyboardShortcut(.defaultAction) // Make it default

                Button("I'll Install Manually") {
                    viewModel.userWillInstallPythonManually()
                    // ViewModel will set showPythonInstallSheet = false
                }
            }
            
            Button("Cancel Setup") {
                viewModel.cancelSetup() // This will also dismiss the sheet if currentStep changes
                dismiss()
            }
            .buttonStyle(.link)
            .padding(.top)

        }
        .padding(EdgeInsets(top: 30, leading: 20, bottom: 30, trailing: 20))
        .frame(minWidth: 450, idealWidth: 500, maxWidth: 550, minHeight: 380)
    }
}

// Preview
struct PythonInstallPromptView_Previews: PreviewProvider {
    static var previews: some View {
        PythonInstallPromptView(viewModel: AgentOnboardingViewModel(onComplete: {}))
    }
}
