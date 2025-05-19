//
//  AutomatedSetupInProgressView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI

struct AutomatedSetupInProgressView: View {
    @ObservedObject var viewModel: AgentOnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Setting Up Your Devgentic Agent")
                .font(.title2)
                .fontWeight(.medium)
                .padding(.top)

            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 10)

            Text(viewModel.loadingMessage)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(height: 50) // Give some fixed height to prevent layout jumps

            ScrollViewReader { scrollViewProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.scriptLog, id: \.self) { logLine in
                            Text(logLine)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 5)
                                .id(logLine) // ID for scrolling
                        }
                    }
                    .padding(10)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.7))
                    .cornerRadius(8)
                }
                .frame(minHeight: 150, maxHeight: .infinity) // Ensure it takes available space
                .onChange(of: viewModel.scriptLog.count) { _ in
                    // Auto-scroll to the bottom when new log entries are added
                    if let lastLog = viewModel.scriptLog.last {
                        withAnimation {
                            scrollViewProxy.scrollTo(lastLog, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal)
            
            Button("Cancel Setup") {
                viewModel.cancelSetup()
            }
            .padding(.bottom)

        }
        .padding()
    }
}

// Preview
struct AutomatedSetupInProgressView_Previews: PreviewProvider {
    static var previews: some View {
        let vm = AgentOnboardingViewModel(onComplete: {})
        vm.isLoading = true
        vm.loadingMessage = "Downloading Ollama model (gemma:2b)..."
        vm.scriptLog = [
            "[10:00:00 AM] Starting setup...",
            "[10:00:01 AM] Checking Python installation...",
            "[10:00:05 AM] Python 3.9.6 found at /usr/local/bin/python3.",
            "[10:00:05 AM] Setting up virtual environment...",
            "[10:00:20 AM] Dependencies installed.",
            "[10:00:20 AM] Downloading Ollama model (gemma:2b)... This might take a while.",
            "[10:00:21 AM] Pulling manifest...",
            "[10:00:25 AM] Pulling f16e31f02469...",
        ]
        return AutomatedSetupInProgressView(viewModel: vm)
            .frame(width: 500, height: 500)
    }
}
