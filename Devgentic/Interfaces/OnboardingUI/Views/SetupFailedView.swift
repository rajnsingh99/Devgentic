//
//  Untitled.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI

struct SetupFailedView: View {
    @ObservedObject var viewModel: AgentOnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "xmark.octagon.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .foregroundColor(.red)

            Text("Agent Setup Failed")
                .font(.title)
                .fontWeight(.bold)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 30)
            } else {
                Text("An unexpected error occurred during the setup process.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 30)
            }
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Logs:")
                        .font(.caption.bold())
                        .padding(.bottom, 2)
                    ForEach(viewModel.scriptLog.suffix(20), id: \.self) { logLine in // Show last 20 logs
                        Text(logLine)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 5)
                    }
                }
                .padding(10)
                .background(Color(NSColor.textBackgroundColor).opacity(0.7))
                .cornerRadius(8)
            }
            .frame(maxHeight: 150)
            .padding(.horizontal)


            Spacer()

            HStack {
                Button("Retry Setup") {
                    viewModel.startSetup() // Attempt the setup again from the beginning
                }
                .keyboardShortcut(.defaultAction)

                Button("Cancel") {
                    viewModel.cancelSetup() // Go back to welcome or quit
                }
            }
            .padding(.bottom)
            Spacer()
        }
        .padding()
    }
}

// Preview
struct SetupFailedView_Previews: PreviewProvider {
    static var previews: some View {
        let vm = AgentOnboardingViewModel(onComplete: {})
        vm.errorMessage = "Python installation check failed.\nDetails: Command '/usr/bin/which python3' failed with exit code 1. Error: Not found"
        vm.scriptLog = ["[10:00:00 AM] Starting setup...", "[10:00:01 AM] Checking Python installation...", "[10:00:01 AM] Error: Python not found"]
        return SetupFailedView(viewModel: vm)
            .frame(width: 500, height: 400)
    }
}

