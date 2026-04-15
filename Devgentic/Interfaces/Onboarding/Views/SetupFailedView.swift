////
////  SetupFailedView.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//import SwiftUI
//
//// Define a protocol for the ViewModel that SetupFailedView expects.
//// This should align with the properties and methods used from AgentOnboardingViewModel.
//protocol SetupFailedViewModelProtocol: Observable, AnyObject {
//    var errorMessage: String? { get }
//    var scriptLog: [String] { get }
//    func startOnboardingFlow() // To retry the entire interactive setup
//    func cancelSetup()         // To go back to welcome or initial state
//}
//
//struct SetupFailedView<ViewModelType: SetupFailedViewModelProtocol>: View {
//    var viewModel: ViewModelType
//
//    var body: some View {
//        VStack(spacing: 20) {
//            Spacer()
//            Image(systemName: "xmark.octagon.fill")
//                .resizable()
//                .scaledToFit()
//                .frame(width: 60, height: 60)
//                .foregroundColor(.red)
//
//            Text("Agent Setup Failed")
//                .font(.title)
//                .fontWeight(.bold)
//
//            // Accessing viewModel.errorMessage. This should be a direct String? access.
//            // The error "Referencing subscript 'subscript(dynamicMember:)' requires wrapper..."
//            // suggests a potential compiler confusion or type mismatch if it occurs here.
//            // Ensuring the ViewModelType conforms correctly and errorMessage is a simple @Published var
//            // in the concrete AgentOnboardingViewModel should prevent this.
//            if let errorMessage = viewModel.errorMessage {
//                Text(errorMessage)
//                    .font(.body)
//                    .multilineTextAlignment(.center)
//                    .foregroundColor(.secondary)
//                    .padding(.horizontal, 30)
//            } else {
//                Text("An unexpected error occurred during the setup process.")
//                    .font(.body)
//                    .multilineTextAlignment(.center)
//                    .foregroundColor(.secondary)
//                    .padding(.horizontal, 30)
//            }
//            
//            // Displaying recent logs
//            if !viewModel.scriptLog.isEmpty {
//                ScrollView {
//                    VStack(alignment: .leading, spacing: 4) {
//                        Text("Recent Logs:")
//                            .font(.caption.bold())
//                            .padding(.bottom, 2)
//                        // Accessing viewModel.scriptLog. This should be a direct [String] access.
//                        ForEach(viewModel.scriptLog.suffix(20), id: \.self) { logLine in
//                            Text(logLine)
//                                .font(.system(.caption2, design: .monospaced))
//                                .frame(maxWidth: .infinity, alignment: .leading)
//                                .padding(.horizontal, 5)
//                        }
//                    }
//                    .padding(10)
//                    .background(Color(NSColor.textBackgroundColor).opacity(0.7))
//                    .cornerRadius(8)
//                    .frame(maxWidth: .infinity)
//                }
//                .frame(maxHeight: 150)
//                .padding(.horizontal)
//            }
//
//
//            Spacer()
//
//            HStack(spacing: 20) {
//                Button("Retry Setup") {
//                    // Action to retry: Should call the method that starts the interactive flow.
//                    viewModel.startOnboardingFlow()
//                }
//                .keyboardShortcut(.defaultAction)
//
//                Button("Cancel") {
//                    // Action to cancel: Should take the user back to the welcome screen.
//                    viewModel.cancelSetup()
//                }
//            }
//            .padding(.bottom)
//            Spacer()
//        }
//        .padding()
//        .frame(minWidth: 480, idealWidth: 550, maxWidth: 600,
//               minHeight: 400, idealHeight: 450, maxHeight: 550)
//    }
//}
//
//// Mock ViewModel for SetupFailedView's preview
//// This mock should conform to SetupFailedViewModelProtocol and simulate
//// the relevant parts of the actual AgentOnboardingViewModel.
//@Observable
//class MockSetupFailedViewModel: SetupFailedViewModelProtocol {
//    var errorMessage: String? = "Python installation check failed.\nDetails: Command '/usr/bin/which python3' failed with exit code 1. Error: Not found"
//    var scriptLog: [String] = [
//        "[10:00:00 AM] Starting setup...",
//        "[10:00:01 AM] Checking Python installation...",
//        "[10:00:01 AM] Error: Python not found during interactive check."
//    ]
//
//    func startOnboardingFlow() {
//        print("Preview: 'Retry Setup' (startOnboardingFlow) action triggered.")
//        // In a real scenario, this would reset the state and change currentFlowStep.
//        self.errorMessage = "Retrying setup..."
//        self.scriptLog.append("--- RETRYING SETUP ---")
//    }
//
//    func cancelSetup() {
//        print("Preview: 'Cancel' (cancelSetup) action triggered.")
//        // In a real scenario, this would reset currentFlowStep to .welcome.
//        self.errorMessage = "Setup cancelled by user."
//    }
//}
//
//// Preview
//struct SetupFailedView_Previews: PreviewProvider {
//    static var previews: some View {
//        // Use the MockSetupFailedViewModel for the preview
//        SetupFailedView(viewModel: MockSetupFailedViewModel())
//    }
//}
