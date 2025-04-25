import SwiftUI

/// Represents the main view content for the Quick Access overlay panel.
/// This view displays an input field, a submit button, and areas for showing
/// processing status, results, or error messages.
struct QuickAccessOverlayView: View {
    /// Observes the ViewModel passed from the NSHostingController or parent view.
    /// @StateObject ensures the ViewModel's lifecycle is tied to this view's lifecycle.
    @StateObject var viewModel: QuickAccessViewModel

    /// Manages the focus state of the primary input field, allowing programmatic focus.
    @FocusState private var isInputFocused: Bool

    /// Defines the structure and layout of the overlay UI.
    var body: some View {
        VStack(spacing: 12) { // Vertical stack for main layout
            // --- Input Area (TextField and Button) ---
            inputSection

            // --- Status / Results / Error Area ---
            statusSection

            // Pushes content towards the top.
            Spacer()
        }
        // Apply vertical padding to the main content stack.
        .padding(.vertical)
        // Ensure the VStack tries to fill the available horizontal and vertical space
        // provided by its container (NSPanel).
        // NOTE: If the view appears collapsed, ensure the hosting NSPanel's size
        // is set *before* showing it in your AppKit code.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Use the visual effect background (assuming VisualEffectBlur.swift exists)
        .background(VisualEffectBlur(material: .hudWindow))
        // Attach event handlers
        .onAppear(perform: handleOnAppear)
        // Use inline closure for onChange logic
        .onChange(of: viewModel.isProcessing) { wasProcessing, isNowProcessing in
            // This signature (wasProcessing, isNowProcessing) requires Swift 5.7+
            print("isProcessing changed: \(wasProcessing) -> \(isNowProcessing)")
            if wasProcessing && !isNowProcessing && viewModel.errorMessage == nil {
                // Refocus input field after successful processing
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    print("Refocusing input field after processing.")
                    self.isInputFocused = true
                }
            }
        }
    }

    // MARK: - Subviews

    /// The horizontal stack containing the text input field and submit button.
    private var inputSection: some View {
        HStack(spacing: 8) {
            TextField("Ask Devgentic...", text: $viewModel.userInput)
                .frame(maxWidth: .infinity)        // Allow it to grow
                .layoutPriority(1)                // Take priority in the HStack
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.9))
                .cornerRadius(6)
                .onSubmit(viewModel.submitQuery)
                .accessibilityLabel("Query Input")

            Button {
                viewModel.submitQuery()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundColor(viewModel.userInput.isEmpty || viewModel.isProcessing ? .secondary : .accentColor) // Dynamic color
            }
            .buttonStyle(.plain) // Remove default button chrome
            .disabled(viewModel.userInput.isEmpty || viewModel.isProcessing) // Disable when needed
            .keyboardShortcut(.defaultAction) // Allow Enter key trigger
            .contentShape(Rectangle()) // Improve hit area
            .accessibilityLabel("Submit Query")
        }
        .frame(minWidth: 600, minHeight: 180)
        .fixedSize() 
        .padding(.horizontal) // Padding for the input group
    }

    /// The section displaying the progress indicator, error message, or results.
    @ViewBuilder
    private var statusSection: some View {
        Group {
            if viewModel.isProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.8) // Slightly smaller spinner
            } else if let errorMessage = viewModel.errorMessage {
                // Improved error presentation with an icon
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundColor(.red)
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading) // Align left
                .textSelection(.enabled) // Allow copying error
            } else if let results = viewModel.results {
                // ScrollView for potentially long results
                ScrollView {
                    Text(results)
                        .font(.body)
                        .foregroundColor(.primary)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading) // Align left
                        .textSelection(.enabled) // Allow copying results
                }
            } else {
                // Render nothing if no status/result/error
                EmptyView()
            }
        }
        .frame(minHeight: 40) // Prevent collapse when empty
    }

    // MARK: - Event Handlers

    /// Actions to perform when the view first appears.
    private func handleOnAppear() {
        // Request focus shortly after appearing, helps ensure window is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            print("QuickAccessOverlayView appeared, requesting focus.")
            self.isInputFocused = true
        }
    }

    // (Original handleProcessingChange function kept for reference if needed)
    /// Original handler function (logic moved inline to onChange).
    private func handleProcessingChange(wasProcessing: Bool, isNowProcessing: Bool) {
        print("handleProcessingChange called: \(wasProcessing) -> \(isNowProcessing)")
        if wasProcessing && !isNowProcessing && viewModel.errorMessage == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.isInputFocused = true
            }
        }
    }
}

// MARK: - Previews

/// Helper container for consistent preview framing.
struct QuickAccessPreviewContainer: View {
    @StateObject var viewModel: QuickAccessViewModel
    let displayName: String
    var body: some View {
        QuickAccessOverlayView(viewModel: viewModel)
            .frame(width: 550, height: 150) // Standard preview size
            .previewDisplayName(displayName)
    }
}

/// Provides previews for different states of the overlay view.
struct QuickAccessOverlayView_Previews: PreviewProvider {
    // Factory methods for creating ViewModels in specific states
    static func createDefaultViewModel() -> QuickAccessViewModel { QuickAccessViewModel() }
    static func createProcessingViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel();
        vm.userInput = "Explain quantum entanglement";
        vm.isProcessing = true;
        return vm
    }
    static func createResultsViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel();
        vm.userInput = "Explain quantum entanglement";
        vm.results = "Quantum entanglement is a physical phenomenon that occurs when a pair or group of particles is generated...";
        return vm
    }
    static func createLongResultsViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel();
        vm.userInput = "Tell me a long story";
        vm.results = """
        Once upon a time, in a world woven from pure code, lived a small algorithm named 'Sort'. Sort wasn't flashy like 'Render3D' or mysterious like 'NeuralNet', but it had a deep love for order. It spent its cycles arranging scattered bits of data into neat sequences. One day, a massive, chaotic dataset arrived – a jumbled mess of user logs, sensor readings, and random thoughts. 'Sort' took a deep breath (metaphorically, of course) and began its work, comparing, swapping, and merging until, finally, clarity emerged from the chaos.
        """;
        return vm
    }
    static func createErrorViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel();
        vm.userInput = "Connect to unavailable service";
        vm.errorMessage = "Error: Could not connect to Devgentic Core Service (503)";
        return vm
    }

    // Define the previews using the helper container and factory methods
    static var previews: some View {
        Group {
            QuickAccessPreviewContainer(viewModel: createDefaultViewModel(), displayName: "1. Default State")
            QuickAccessPreviewContainer(viewModel: createProcessingViewModel(), displayName: "2. Processing State")
            QuickAccessPreviewContainer(viewModel: createResultsViewModel(), displayName: "3. With Results")
            QuickAccessPreviewContainer(viewModel: createLongResultsViewModel(), displayName: "4. With Long Results (Scrolling)")
                .frame(height: 250) // Taller frame for long results preview
            QuickAccessPreviewContainer(viewModel: createErrorViewModel(), displayName: "5. Error State")
        }
    }
}
