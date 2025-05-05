// Onboarding/Views/OnboardingAgentApiSetupView.swift
import SwiftUI

struct OnboardingAgentApiSetupView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    // Placeholder for potential delegation strategies - replace with actual enum/options if available
    private let delegationStrategies = ["auto", "manual", "none"] // Example options

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Connect to Agent API")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Enter the Base URL of your running Devgentic Agent server and select a delegation strategy.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // --- Input Fields ---
            VStack(alignment: .leading) {
                Text("Agent Base URL:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("e.g., http://localhost:8000", text: $viewModel.agentApiUrl)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .disabled(viewModel.agentApiTestInProgress)
            }

            VStack(alignment: .leading) {
                Text("Delegation Strategy:")
                     .font(.caption)
                     .foregroundColor(.secondary)
                // Using a Picker for predefined strategies
                Picker("Delegation Strategy", selection: $viewModel.agentDelegationStrategy) {
                    ForEach(delegationStrategies, id: \.self) { strategy in
                        Text(strategy).tag(strategy)
                    }
                }
                .labelsHidden() // Hide label if desired, title is above
                // .pickerStyle(.segmented) // Or another style
                .disabled(viewModel.agentApiTestInProgress)

                // OR use a TextField if strategy is freeform:
                // TextField("e.g., auto", text: $viewModel.agentDelegationStrategy)
                //     .textFieldStyle(.roundedBorder)
                //     .disabled(viewModel.agentApiTestInProgress)
            }


            // --- Connection Test ---
            HStack {
                Button {
                    viewModel.testAgentApiConnection()
                } label: {
                    HStack {
                        if viewModel.agentApiTestInProgress {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "network")
                        }
                        Text(viewModel.agentApiTestInProgress ? "Testing..." : "Test Connection")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.agentApiTestInProgress || viewModel.agentApiUrl.isEmpty) // Disable if empty or testing

                Spacer()

                // --- Status Indicator ---
                if viewModel.agentApiTestInProgress {
                    Text("Checking...")
                        .foregroundColor(.secondary)
                } else if let errorMsg = viewModel.agentApiTestError {
                     HStack {
                         Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                         Text("Failed").foregroundColor(.red)
                             .help(errorMsg) // Show full error on hover
                     }
                } else if viewModel.isAgentApiConnectionOk == true {
                     HStack {
                         Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                         Text("Success").foregroundColor(.green)
                     }
                } else {
                    // Initial state or after clearing
                    Text("Untested")
                         .foregroundColor(.secondary)
                }
            }
            .frame(height: 25)

            Spacer()

            // --- Navigation Buttons ---
            HStack {
                Button("Back") {
                    viewModel.goToPreviousStep()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.agentApiTestInProgress)

                Spacer()

                Button("Finish") {
                    viewModel.completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                // Enable only after successful test and if not currently testing
                .disabled(viewModel.isAgentApiConnectionOk != true || viewModel.agentApiTestInProgress)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top)

        }
        .padding(30)
    }
}

#Preview {
    let previewViewModel = OnboardingViewModel()
    // previewViewModel.agentApiUrl = "http://localhost:8000"
    // previewViewModel.agentDelegationStrategy = "auto"
    // previewViewModel.agentApiTestInProgress = false
    // previewViewModel.isAgentApiConnectionOk = true
    // previewViewModel.agentApiTestError = "Connection timed out."

    return OnboardingAgentApiSetupView(viewModel: previewViewModel)
         .frame(width: 450, height: 400)
}