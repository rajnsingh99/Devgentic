////
////  InteractiveSetupSidebarView.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//import SwiftUI
//
//struct InteractiveSetupSidebarView: View {
//    @ObservedObject var viewModel: AgentOnboardingViewModel
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 0) {
//            Text("Onboarding Setup")
//                .font(.title2)
//                .fontWeight(.semibold)
//                .padding(.horizontal)
//                .padding(.top, 20)
//                .padding(.bottom, 10)
//
//            ForEach(AgentOnboardingViewModel.InteractiveSetupStage.allCases) { stage in
//                StageRow(
//                    stage: stage,
//                    isActive: viewModel.currentInteractiveStage == stage,
//                    status: status(for: stage),
//                    progressMessage: progressMessage(for: stage),
//                    action: {
//                        // Allow clicking on completed previous stages to review? For now, no action.
//                        // Or, viewModel.currentInteractiveStage = stage (if allowed)
//                    }
//                )
//                if stage != AgentOnboardingViewModel.InteractiveSetupStage.allCases.last {
//                    // Dotted line connector (simplified)
//                    Rectangle()
//                        .fill(Color.gray.opacity(0.5))
//                        .frame(width: 1, height: 30)
//                        .padding(.leading, 27) // Align with icon center
//                }
//            }
//            Spacer() // Pushes stages to the top
//        }
//        .frame(maxWidth: .infinity, maxHeight: .infinity)
//        .background(Color(NSColor.windowBackgroundColor).opacity(0.5)) // Subtle background
//    }
//
//    private func status(for stage: AgentOnboardingViewModel.InteractiveSetupStage) -> AgentOnboardingViewModel.StageStatus {
//        switch stage {
//        case .pythonVerification:
//            return viewModel.pythonVerificationStatus
//        case .ollamaSetup:
//            return viewModel.ollamaSetupStatus
//        case .agentServerSetup:
//            return viewModel.agentServerStatus
//        }
//    }
//    
//    private func progressMessage(for stage: AgentOnboardingViewModel.InteractiveSetupStage) -> String? {
//        guard viewModel.currentInteractiveStage == stage else { return nil }
//        switch stage {
//        case .pythonVerification:
//            return viewModel.pythonVerificationStatus == .inProgress ? viewModel.pythonVerificationMessage : nil
//        case .ollamaSetup:
//            if viewModel.ollamaSetupStatus == .inProgress {
//                return viewModel.ollamaAppInstallProgressMessage.isEmpty ? viewModel.ollamaOverallProgressMessage : "\(viewModel.ollamaAppInstallProgressMessage)\n\(viewModel.ollamaOverallProgressMessage)"
//            }
//            return nil
//        case .agentServerSetup:
//            return viewModel.agentServerStatus == .inProgress ? viewModel.agentServerProgressMessage : nil
//        }
//    }
//}
//
//struct StageRow: View {
//    let stage: AgentOnboardingViewModel.InteractiveSetupStage
//    let isActive: Bool
//    let status: AgentOnboardingViewModel.StageStatus
//    let progressMessage: String?
//    let action: () -> Void
//
//    var body: some View {
//        Button(action: action) {
//            HStack(spacing: 12) {
//                Image(systemName: iconName())
//                    .font(.system(size: 18))
//                    .foregroundColor(iconColor())
//                    .frame(width: 24, height: 24) // Consistent icon size
//
//                VStack(alignment: .leading, spacing: 2) {
//                    Text(stage.title)
//                        .fontWeight(isActive ? .bold : .medium)
//                        .foregroundColor(isActive ? .primary : .secondary)
//                    
//                    if isActive, let message = progressMessage, status == .inProgress {
//                        Text(message)
//                            .font(.caption)
//                            .foregroundColor(.gray)
//                            .lineLimit(2)
//                    } else if status == .completed {
//                         Text("Completed")
//                            .font(.caption)
//                            .foregroundColor(.green)
//                    } else if status == .failed {
//                         Text("Failed")
//                            .font(.caption)
//                            .foregroundColor(.red)
//                    }
//                }
//                Spacer()
//                if isActive {
//                    Image(systemName: "chevron.right")
//                        .foregroundColor(.gray)
//                }
//            }
//            .padding(.vertical, 10)
//            .padding(.horizontal)
//            .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
//            .cornerRadius(8)
//        }
//        .buttonStyle(.plain)
//        .disabled(status == .inProgress && !isActive) // Example: disable clicking if not active and something is running
//    }
//
//    private func iconName() -> String {
//        switch status {
//        case .pending, .awaitingUserInput:
//            return isActive ? "ellipsis.circle.fill" : "circle" // "gearshape"
//        case .inProgress:
//            return "gearshape.arrow.triangle.2.circlepath" // "arrow.triangle.2.circlepath.circle"
//        case .completed:
//            return "checkmark.circle.fill"
//        case .failed:
//            return "xmark.octagon.fill"
//        }
//    }
//
//    private func iconColor() -> Color {
//        switch status {
//        case .pending, .awaitingUserInput:
//            return isActive ? .accentColor : .gray
//        case .inProgress:
//            return .accentColor
//        case .completed:
//            return .green
//        case .failed:
//            return .red
//        }
//    }
//}
//
//struct InteractiveSetupSidebarView_Previews: PreviewProvider {
//    static var previews: some View {
//        let vm = AgentOnboardingViewModel(onComplete: {}, onAgentReady: {_,_ in})
//        vm.currentFlowStep = .interactiveSetup
//        vm.pythonVerificationStatus = .completed
//        vm.currentInteractiveStage = .ollamaSetup
//        vm.ollamaSetupStatus = .inProgress
//        vm.ollamaOverallProgressMessage = "Downloading llama3 (35%)..."
//        return InteractiveSetupSidebarView(viewModel: vm)
//            .frame(width: 250)
//    }
//}
