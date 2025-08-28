////
////  AgentServerPanelView.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//import SwiftUI
//
//struct AgentServerPanelView: View {
//    @ObservedObject var viewModel: AgentOnboardingViewModel
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 20) {
//            Text("Step 3: Agent Server Setup")
//                .font(.title2)
//                .fontWeight(.semibold)
//
//            Text("This final step will prepare the Python virtual environment, install necessary dependencies, and start the Devgentic agent server.")
//                .font(.callout)
//                .foregroundColor(.secondary)
//            
//            if viewModel.agentServerStatus == .inProgress {
//                ProgressView()
//                    .padding(.vertical)
//                Text(viewModel.agentServerProgressMessage)
//                    .font(.caption)
//                    .foregroundColor(.gray)
//            } else if viewModel.agentServerStatus == .completed {
//                HStack {
//                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
//                    Text("Agent server setup complete and running.")
//                }
//                 Text(viewModel.agentServerProgressMessage) // Shows final success message
//                    .font(.caption)
//            } else if viewModel.agentServerStatus == .failed {
//                 HStack {
//                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
//                    Text(viewModel.agentServerProgressMessage) // Shows the error
//                }
//            }
//
//            Spacer()
//
//            HStack {
//                if viewModel.agentServerStatus != .completed && viewModel.agentServerStatus != .inProgress {
//                     Button(viewModel.agentServerActionButtonTitle) {
//                        viewModel.handleAgentServerAction()
//                    }
//                    .disabled(!viewModel.isAgentServerActionButtonEnabled || viewModel.agentServerStatus == .inProgress)
//                }
//                
//                Spacer()
//                
//                Button("Finish") {
//                    viewModel.finishInteractiveSetup()
//                }
//                .disabled(!viewModel.isAgentServerFinishButtonEnabled)
//                .keyboardShortcut(.defaultAction)
//            }
//        }
//        .padding()
//        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
//    }
//}
//
//struct AgentServerPanelView_Previews: PreviewProvider {
//    static var previews: some View {
//        let vm = AgentOnboardingViewModel(onComplete: {}, onAgentReady: {_,_ in})
//        vm.currentFlowStep = .interactiveSetup
//        vm.currentInteractiveStage = .agentServerSetup
//        // vm.agentServerStatus = .inProgress
//        // vm.agentServerProgressMessage = "Launching agent..."
//        return AgentServerPanelView(viewModel: vm)
//    }
//}
