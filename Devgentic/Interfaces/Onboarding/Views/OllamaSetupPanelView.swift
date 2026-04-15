////
////  OllamaSetupPanelView.swift
////  Devgentic
////
////  Created by Raj Singh on 19/05/25.
////
//
//import SwiftUI
//
//struct OllamaSetupPanelView: View {
//    @Bindable var viewModel: AgentOnboardingViewModel
//
//    var body: some View {
//        VStack(alignment: .leading, spacing: 20) {
//            Text("Step 2: Ollama Configuration")
//                .font(.title2)
//                .fontWeight(.semibold)
//
//            Text("This step will install the Ollama application (if not already present) and download a selected Large Language Model (LLM).")
//                .font(.callout)
//                .foregroundColor(.secondary)
//
//            HStack {
//                Text("Select Ollama Model:")
//                Picker("Select Model", selection: $viewModel.selectedOllamaModel) {
//                    ForEach(viewModel.hardcodedOllamaModels, id: \.self) { modelName in
//                        Text(modelName).tag(modelName)
//                    }
//                }
//                .disabled(viewModel.ollamaSetupStatus == .inProgress)
//                .frame(minWidth: 150)
//            }
//            
//            if viewModel.ollamaSetupStatus == .inProgress {
//                ProgressView(value: viewModel.ollamaModelDownloadProgress, total: 1.0) {
//                    Text(viewModel.ollamaOverallProgressMessage)
//                        .font(.caption)
//                } currentValueLabel: {
//                    Text("\(Int(viewModel.ollamaModelDownloadProgress * 100))%")
//                        .font(.caption)
//                }
//                .padding(.vertical)
//                
//                if !viewModel.ollamaAppInstallProgressMessage.isEmpty {
//                    Text("App Install: \(viewModel.ollamaAppInstallProgressMessage)")
//                        .font(.caption2)
//                        .foregroundColor(.gray)
//                        .lineLimit(3)
//                }
//
//            } else if viewModel.ollamaSetupStatus == .completed {
//                HStack {
//                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
//                    Text("Ollama configured with model: \(viewModel.selectedOllamaModel).")
//                }
//            } else if viewModel.ollamaSetupStatus == .failed {
//                 HStack {
//                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
//                    Text(viewModel.ollamaOverallProgressMessage) // Shows the error
//                }
//            }
//            
//            Text("Note: Model downloads can be large and may take some time depending on your internet connection.")
//                .font(.caption)
//                .foregroundColor(.gray)
//
//            Spacer()
//
//            HStack {
//                 if viewModel.ollamaSetupStatus != .completed {
//                    Button(viewModel.ollamaActionButtonTitle) {
//                        viewModel.handleOllamaAction()
//                    }
//                    .disabled(!viewModel.isOllamaActionButtonEnabled || viewModel.ollamaSetupStatus == .inProgress)
//                    .keyboardShortcut(.defaultAction)
//                }
//                Spacer()
//                Button("Next") {
//                    viewModel.proceedToAgentServerSetup()
//                }
//                .disabled(!viewModel.isOllamaNextButtonEnabled)
//            }
//        }
//        .padding()
//        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
//    }
//}
//
//struct OllamaSetupPanelView_Previews: PreviewProvider {
//    static var previews: some View {
//        let vm = AgentOnboardingViewModel(onComplete: {}, onAgentReady: {_,_ in})
//        vm.currentFlowStep = .interactiveSetup
//        vm.currentInteractiveStage = .ollamaSetup
//        // vm.ollamaSetupStatus = .inProgress
//        // vm.ollamaOverallProgressMessage = "Downloading llama3 (45%)..."
//        // vm.ollamaModelDownloadProgress = 0.45
//        return OllamaSetupPanelView(viewModel: vm)
//    }
//}
