//
//  AutomatedSetupInProgressView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/05/25.
//

import SwiftUI

// Define a protocol that outlines the requirements for the ViewModel
// that AutomatedSetupInProgressView expects. This helps in creating mocks
// or ensuring the passed ViewModel is compatible.
protocol AutomatedSetupViewModelProtocol: ObservableObject {
    var loadingMessage: String { get }
    var scriptLog: [String] { get }
    func cancelSetup()
    // Add other properties/methods if the view uses them, e.g., an isLoading flag
    // var isLoading: Bool { get }
}

struct AutomatedSetupInProgressView<ViewModelType: AutomatedSetupViewModelProtocol>: View {
    @ObservedObject var viewModel: ViewModelType

    var body: some View {
        VStack(spacing: 20) {
            Text("Setting Up Your Devgentic Agent")
                .font(.title2)
                .fontWeight(.medium)
                .padding(.top)

            ProgressView()
                .scaleEffect(1.5)
                .padding(.bottom, 10)

            // Line 24 (in the original context): Text(viewModel.loadingMessage)
            // This expects viewModel.loadingMessage to be a String.
            // The error "Initializer 'init(_:)' requires that 'Binding<Subject>' conform to ‘StringProtocol’"
            // would occur if viewModel.loadingMessage was somehow a Binding<String> passed here.
            // With a correctly defined @Published var loadingMessage: String in the ViewModel,
            // viewModel.loadingMessage is a String, and Text() should accept it.
            Text(viewModel.loadingMessage)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(minHeight: 40, idealHeight: 50, maxHeight: 60) // Adjusted for dynamic text

            ScrollViewReader { scrollViewProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        // This ForEach expects viewModel.scriptLog to be [String]
                        // and logLine to be a String. Text(logLine) is correct.
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
                    .frame(maxWidth: .infinity) // Ensure VStack takes full width for alignment
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
            // .disabled(!viewModel.isLoading) // Example if an isLoading property was used
        }
        .padding()
        .frame(minWidth: 480, idealWidth: 550, maxWidth: 700,
               minHeight: 400, idealHeight: 500, maxHeight: 600)
    }
}

// Mock ViewModel for previewing AutomatedSetupInProgressView
class MockAutomatedSetupViewModel: AutomatedSetupViewModelProtocol {
    @Published var loadingMessage: String = "Initializing setup..."
    @Published var scriptLog: [String] = [
        "[10:00:00 AM] Starting setup...",
        "[10:00:01 AM] Checking prerequisites...",
    ]
    // @Published var isLoading: Bool = true // Example

    func cancelSetup() {
        print("Preview: Cancel setup action triggered.")
        // self.isLoading = false
        self.loadingMessage = "Setup cancelled by user."
    }

    // Simulate adding logs for preview
    init() {
        // Example of updating log and message for preview
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.loadingMessage = "Processing step 1..."
            self.scriptLog.append("[10:00:02 AM] Step 1 in progress...")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.loadingMessage = "Finalizing..."
            self.scriptLog.append("[10:00:04 AM] Step 1 completed.")
            self.scriptLog.append("[10:00:04 AM] Starting step 2...")
        }
    }
}

// Preview
struct AutomatedSetupInProgressView_Previews: PreviewProvider {
    static var previews: some View {
        AutomatedSetupInProgressView(viewModel: MockAutomatedSetupViewModel())
    }
}
