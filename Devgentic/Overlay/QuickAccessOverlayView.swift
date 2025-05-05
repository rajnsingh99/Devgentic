import SwiftUI

/// Represents the main view content for the Quick Access overlay panel.
/// This view displays a top bar, conversation history, and an input bar.
struct QuickAccessOverlayView: View {
    /// Observes the ViewModel passed from the NSHostingController or parent view.
    /// @StateObject ensures the ViewModel's lifecycle is tied to this view's lifecycle.
    @StateObject var viewModel: QuickAccessViewModel

    /// Manages the focus state of the primary input field, allowing programmatic focus.
    @FocusState private var isInputFocused: Bool

    // --- Color Constants ---
    let panelBackgroundColor = Color(red: 0.18, green: 0.18, blue: 0.19)
    let inputBackgroundColor = Color(red: 0.2, green: 0.2, blue: 0.22)
    let iconColor = Color.secondary
    let placeholderColor = Color.gray
    let userMessageBackgroundColor = Color.accentColor.opacity(0.8)
    let agentMessageBackgroundColor = Color(red: 0.25, green: 0.25, blue: 0.27)

    /// Defines the structure and layout of the overlay UI.
    var body: some View {
        VStack(spacing: 0) {
            // --- Conditional Top Bar & History (Show only when expanded) ---
            if viewModel.isExpanded {
                topBarSection
                    .padding(.horizontal)
                    .padding(.top, 10)
                    // Add transition for smoother appearance
                    .transition(.opacity.combined(with: .move(edge: .top))) // Combine fade and slide

                conversationHistorySection
                    // Removed layoutPriority, let VStack manage space
                    // Add transition for smoother appearance
                    .transition(.opacity) // Simple fade for history
            } else {
                 // Optional: Add a minimum height spacer when collapsed if needed
                 // Spacer().frame(height: 1) // Add spacer to prevent complete collapse if needed
            }

            // --- Always Visible Input Bar ---
            newInputBarSection
                .padding(.horizontal)
                .padding(.vertical, 10) // Consistent padding
        }
        .background(panelBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Let SwiftUI fill the allocated space
        // Use the isExpanded state for the main animation trigger
        .animation(.easeInOut(duration: 0.3), value: viewModel.isExpanded) // Animate layout changes based on expansion
        .onAppear(perform: handleOnAppear)
        .onChange(of: viewModel.isProcessing) { wasProcessing, isNowProcessing in
            // Focus logic might need refinement depending on desired behavior during expansion
            if wasProcessing && !isNowProcessing && viewModel.errorMessage == nil {
                // Re-focus after processing completes successfully
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.isInputFocused = true
                }
            }
        }
        // When the view appears or expansion state changes, ensure focus is set correctly.
        .onChange(of: viewModel.isExpanded) { _, isNowExpanded in
             // Ensure focus when collapsed (initial state or after reset)
             // Or ensure focus when it becomes expanded (useful if focus was lost)
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { // Slight delay helps
                 self.isInputFocused = true
             }
        }
    }

    // MARK: - Subviews

    /// **Top Control Bar** (Only shown when expanded)
    private var topBarSection: some View {
        HStack {
            Button {
                print("Close button tapped")
                NotificationCenter.default.post(name: Notification.Name("CloseQuickAccessOverlay"), object: nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(iconColor)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { print("Copy tapped") } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(iconColor)
            }
            .buttonStyle(.plain)

            Button { print("Pin tapped") } label: {
                Image(systemName: "pin")
                    .foregroundColor(iconColor)
            }
            .buttonStyle(.plain)
        }
        .font(.title3)
        .padding(.bottom, 8)
    }

    /// **Conversation History Section** (Only shown when expanded)
    private var conversationHistorySection: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 15) {
                    // --- TODO: Replace below with actual data loop ---
                    // Display mock result if available (temporary until history is implemented)
                    if let resultText = viewModel.results {
                         AgentMessageBubble(text: resultText)
                    }

                    // --- Status/Error Display ---
                    if viewModel.isProcessing {
                        HStack {
                            Spacer()
                            ProgressView().scaleEffect(0.8)
                            Spacer()
                        }.padding(.vertical)
                    } else if let errorMessage = viewModel.errorMessage {
                        ErrorMessageView(message: errorMessage)
                    }

                    // --- Anchor for scrolling ---
                    Spacer().frame(height: 1).id("bottomAnchor")

                }
                .padding(.horizontal)
                .padding(.top, 10)
                // Ensure the VStack takes up horizontal space for alignment
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // TODO: Add scroll-to-bottom logic when real history is added
            // .onChange(of: viewModel.conversationHistory.count) {
            //      withAnimation { scrollProxy.scrollTo("bottomAnchor", anchor: .bottom) }
            // }
        }
    }

    /// **Input Bar Section** (Always visible)
    private var newInputBarSection: some View {
        VStack(spacing: 8) {
            TextField("", text: $viewModel.userInput, prompt: Text("Ask anything").foregroundColor(placeholderColor))
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundColor(.primary)
                .frame(height: 25)
                .focused($isInputFocused)
                .onSubmit(viewModel.submitQuery)
                .accessibilityLabel("Query Input")

            HStack(spacing: 12) {
                Button {} label: { Image(systemName: "plus").foregroundColor(iconColor) }
                    .buttonStyle(.plain)
                Button {} label: { Image(systemName: "globe").foregroundColor(iconColor) }
                    .buttonStyle(.plain)
                Button {} label: { Image(systemName: "sparkles.telescope").foregroundColor(iconColor) }
                    .buttonStyle(.plain)
                Button {} label: { Image(systemName: "cursorarrow.motionlines").foregroundColor(iconColor) }
                    .buttonStyle(.plain)
                Spacer()
                Button {} label: { Image(systemName: "mic").foregroundColor(iconColor) }
                    .buttonStyle(.plain)
                Button {
                    viewModel.submitQuery()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundColor(viewModel.userInput.isEmpty || viewModel.isProcessing ? iconColor : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.userInput.isEmpty || viewModel.isProcessing)
                .keyboardShortcut(.defaultAction)
                .contentShape(Rectangle())
                .accessibilityLabel("Submit Query")
            }
            .font(.title3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(inputBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Message Bubble Views (Unchanged)

    private struct UserMessageBubble: View { // Keep for future use
        let text: String
        var body: some View {
            HStack {
                Spacer()
                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.9))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 400, alignment: .trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private struct AgentMessageBubble: View {
        let text: String
        var body: some View {
            HStack {
                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.25, green: 0.25, blue: 0.27))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: /*@START_MENU_TOKEN@*/.infinity/*@END_MENU_TOKEN@*/, alignment: .leading) // Allow agent bubble to use more width
                    .textSelection(.enabled)
                Spacer() // Keep spacer if needed, or remove if text should wrap within max width
            }
        }
    }

    private struct ErrorMessageView: View {
        let message: String
        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
                Spacer()
            }
            .padding(.vertical, 5)
            .textSelection(.enabled)
        }
    }


    // MARK: - Event Handlers

    /// Actions to perform when the view first appears.
    private func handleOnAppear() {
        // Ensure focus is set correctly on appear, especially if starting collapsed
         if !viewModel.isExpanded {
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                 print("QuickAccessOverlayView appeared (collapsed), requesting focus.")
                 self.isInputFocused = true
             }
         } else {
             // If appearing already expanded (e.g., panel was hidden then shown again without state reset)
             DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                 print("QuickAccessOverlayView appeared (expanded), requesting focus.")
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
        // Use a geometry reader to provide size context for the preview
        GeometryReader { geometry in
             QuickAccessOverlayView(viewModel: viewModel)
                 // Set frame based on expanded state for preview accuracy
                 // Adjust width to match panel width if needed for preview
                 .frame(width: 700, height: viewModel.isExpanded ? 450 : 95) // Use heights from OverlayWindowManager
                 .previewDisplayName(displayName)
        }
        // Set a fixed outer frame for the GeometryReader itself
         .frame(width: 700, height: 450) // Match expanded size for outer frame

    }
}

/// Provides previews for different states of the overlay view.
struct QuickAccessOverlayView_Previews: PreviewProvider {
    // Factory for default (collapsed) state
    static func createDefaultViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel()
        vm.isExpanded = false // Explicitly collapsed
        return vm
    }
    // Factory for expanded state (e.g., after query)
    static func createExpandedViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel()
        vm.isExpanded = true
        vm.results = "This is a sample result shown in the expanded view." // Add sample result
        return vm
    }
     // Factory for expanded processing state
    static func createExpandedProcessingViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel()
        vm.userInput = "Processing this..."
        vm.isExpanded = true
        vm.isProcessing = true
        return vm
    }
     // Factory for expanded error state
    static func createExpandedErrorViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel()
        vm.isExpanded = true
        vm.errorMessage = "Error occurred during processing."
        return vm
    }


    static var previews: some View {
        Group {
            // Preview the collapsed state
            QuickAccessPreviewContainer(viewModel: createDefaultViewModel(), displayName: "1. Collapsed State")

             // Preview the expanded state
            QuickAccessPreviewContainer(viewModel: createExpandedViewModel(), displayName: "2. Expanded State (With Result)")

             // Preview expanded processing
             QuickAccessPreviewContainer(viewModel: createExpandedProcessingViewModel(), displayName: "3. Expanded Processing")

             // Preview expanded error
             QuickAccessPreviewContainer(viewModel: createExpandedErrorViewModel(), displayName: "4. Expanded Error")
        }
        .background(Color(red: 0.18, green: 0.18, blue: 0.19))
    }
}
