import SwiftUI

/// Represents the main view content for the Quick Access overlay panel.
/// This view displays a top bar, conversation history, and an input bar.
/// It dynamically adjusts its height based on the `isExpanded` state.
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
    let userMessageBackgroundColor = Color.accentColor.opacity(0.8) // Keep for potential future use
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
                    .transition(.opacity.combined(with: .move(edge: .top)))

                conversationHistorySection
                    // Give the history section some minimum height when expanded
                    // to ensure the container grows sufficiently. Adjust 200 as needed.
                    .frame(minHeight: 200) // Ensures space for content when expanded
                    .transition(.opacity) // Simple fade for history
            }
            // No Spacer needed here when collapsed, the frame modifier handles min height

            // --- Always Visible Input Bar ---
            newInputBarSection
                .padding(.horizontal)
                .padding(.vertical, 10) // Consistent padding
        }
        // Apply overall frame constraints
        .frame(
            idealWidth: 500, // Suggest an ideal width
            maxWidth: 600,  // Limit max width if needed
            // Set a minimum height ONLY when expanded to control expanded size
            minHeight: viewModel.isExpanded ? 500 : nil, // Adjust 300 as desired total expanded height
            alignment: .top // Align content to the top
        )
        .background(panelBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 16)) // Apply rounding to the background
        .animation(.easeInOut(duration: 0.3), value: viewModel.isExpanded) // Animate layout changes based on expansion
        .onAppear(perform: handleOnAppear)
        .onChange(of: viewModel.isProcessing) { wasProcessing, isNowProcessing in
            // Re-focus logic after processing (might need adjustment based on final UX)
            if wasProcessing && !isNowProcessing && viewModel.errorMessage == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.isInputFocused = true
                }
            }
        }
        // When the view appears or expansion state changes, ensure focus is set correctly.
        .onChange(of: viewModel.isExpanded) { _, isNowExpanded in
             // Ensure focus when collapsed or when it becomes expanded
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
                // Post notification to request closing the panel
                NotificationCenter.default.post(name: Notification.Name("CloseQuickAccessOverlay"), object: nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(iconColor)
            }
            .buttonStyle(.plain) // Use plain style for icon-only buttons

            Spacer() // Pushes buttons to the sides

            // Add other top bar buttons as needed (Copy, Pin, etc.)
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
        .font(.title3) // Consistent font size for icons
        .padding(.bottom, 8) // Spacing below the top bar
    }

    /// **Conversation History Section** (Only shown when expanded)
    private var conversationHistorySection: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 15) {
                    // --- TODO: Replace below with actual conversation history data loop ---

                    // Display mock result if available (temporary)
                    if let resultText = viewModel.results {
                         AgentMessageBubble(text: resultText)
                    }

                    // --- Status/Error Display ---
                    if viewModel.isProcessing {
                        HStack {
                            Spacer()
                            ProgressView().scaleEffect(0.8) // Smaller progress indicator
                            Spacer()
                        }.padding(.vertical)
                    } else if let errorMessage = viewModel.errorMessage {
                        ErrorMessageView(message: errorMessage)
                    }

                    // --- Anchor for scrolling ---
                    // Used to programmatically scroll to the bottom
                    Spacer().frame(height: 1).id("bottomAnchor")

                }
                .padding(.horizontal) // Padding inside the scroll view
                .padding(.top, 10)
                // Ensure the VStack takes up horizontal space for alignment
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // TODO: Add scroll-to-bottom logic when real history is implemented
            // .onChange(of: viewModel.conversationHistory.count) { // Example trigger
            //      withAnimation { scrollProxy.scrollTo("bottomAnchor", anchor: .bottom) }
            // }
        }
    }

    /// **Input Bar Section** (Always visible)
    private var newInputBarSection: some View {
        VStack(spacing: 8) { // Vertical stack for TextField and buttons below it
            // --- Text Input Field ---
            TextField("", text: $viewModel.userInput, prompt: Text("Ask anything").foregroundColor(placeholderColor))
                .textFieldStyle(.plain) // Basic text field appearance
                .font(.body)
                .foregroundColor(.primary) // Standard text color
                .frame(height: 25) // Define height for the text field
                .focused($isInputFocused) // Bind focus state
                .onSubmit(viewModel.submitQuery) // Submit on Enter/Return key
                .accessibilityLabel("Query Input")

            // --- Action Buttons Row ---
            HStack(spacing: 12) {
                // Example action buttons
                Button {} label: { Image(systemName: "plus").foregroundColor(iconColor) }
                    .buttonStyle(.plain)
                Button {} label: { Image(systemName: "globe").foregroundColor(iconColor) }
                    .buttonStyle(.plain)
                Button {} label: { Image(systemName: "sparkles.telescope").foregroundColor(iconColor) } // Example different icon
                    .buttonStyle(.plain)
                Button {} label: { Image(systemName: "cursorarrow.motionlines").foregroundColor(iconColor) }
                    .buttonStyle(.plain)

                Spacer() // Pushes Mic and Submit buttons to the right

                Button {} label: { Image(systemName: "mic").foregroundColor(iconColor) }
                    .buttonStyle(.plain)

                // Submit Button
                Button {
                    viewModel.submitQuery() // Call ViewModel action
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        // Change color based on input state
                        .foregroundColor(viewModel.userInput.isEmpty || viewModel.isProcessing ? iconColor : .accentColor)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.userInput.isEmpty || viewModel.isProcessing) // Disable if empty or processing
                .keyboardShortcut(.defaultAction) // Allow Enter/Return key to trigger this button too
                .contentShape(Rectangle()) // Ensure the whole area is tappable
                .accessibilityLabel("Submit Query")
            }
            .font(.title3) // Font size for the icons in this row
        }
        .padding(.horizontal, 12) // Padding inside the input bar background
        .padding(.vertical, 10)
        .background(inputBackgroundColor) // Background for the input area
        .clipShape(RoundedRectangle(cornerRadius: 12)) // Rounded corners for the input bar
    }

    // MARK: - Message Bubble Views

    // Example User Message Bubble (Keep for future use with history)
    private struct UserMessageBubble: View {
        let text: String
        var body: some View {
            HStack {
                Spacer() // Push to the right
                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.9)) // User message color
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 400, alignment: .trailing) // Limit width, align right
                    .textSelection(.enabled) // Allow text selection
            }
        }
    }

    // Agent (Response) Message Bubble
    private struct AgentMessageBubble: View {
        let text: String
        var body: some View {
            HStack {
                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.25, green: 0.25, blue: 0.27)) // Agent message color
                    .foregroundColor(.primary) // Standard text color
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, alignment: .leading) // Allow agent bubble to use available width
                    .textSelection(.enabled) // Allow text selection
                Spacer() // Keep spacer if needed, or remove if text should wrap within max width
            }
        }
    }

    // Error Message View
    private struct ErrorMessageView: View {
        let message: String
        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.callout)
                    .foregroundColor(.red)
                Spacer() // Push to the left
            }
            .padding(.vertical, 5)
            .textSelection(.enabled) // Allow selecting error text
        }
    }


    // MARK: - Event Handlers

    /// Actions to perform when the view first appears.
    private func handleOnAppear() {
        // Request focus for the input field shortly after appearing.
        // This delay helps ensure the view hierarchy is ready.
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
             print("QuickAccessOverlayView appeared, requesting focus.")
             self.isInputFocused = true
         }
    }
}

// MARK: - Previews

/// Helper container for consistent preview framing and ViewModel setup.
struct QuickAccessPreviewContainer: View {
    @StateObject var viewModel: QuickAccessViewModel
    let displayName: String
    var body: some View {
        // Use a geometry reader if specific size context is needed, otherwise direct frame is fine.
        QuickAccessOverlayView(viewModel: viewModel)
            // Set frame based on expanded state for preview accuracy
            // Use the new potential expanded height (e.g., 300) and suggested width (500)
            .frame(width: 500, height: viewModel.isExpanded ? 300 : 95) // Adjusted height for preview
            .previewDisplayName(displayName)
            // Set an outer frame for the preview canvas itself
            .frame(width: 500, height: 300) // Adjusted outer frame height
    }
}

/// Provides previews for different states of the overlay view in Xcode Canvas.
struct QuickAccessOverlayView_Previews: PreviewProvider {
    // --- ViewModel Factories for Different States ---
    static func createDefaultViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel()
        vm.isExpanded = false // Explicitly collapsed
        return vm
    }

    static func createExpandedViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel()
        vm.isExpanded = true
        vm.results = "This is a sample result shown in the expanded view. It might be longer to test scrolling."
        return vm
    }

    static func createExpandedProcessingViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel()
        vm.userInput = "Processing this query..." // Show input that led to processing
        vm.isExpanded = true
        vm.isProcessing = true
        return vm
    }

    static func createExpandedErrorViewModel() -> QuickAccessViewModel {
        let vm = QuickAccessViewModel()
        vm.userInput = "This query caused an error" // Show input that led to error
        vm.isExpanded = true
        vm.errorMessage = "Error: Could not connect to the backend service. Please check your connection."
        return vm
    }

    // --- Preview Definitions ---
    static var previews: some View {
        Group {
            // Preview the collapsed state
            QuickAccessPreviewContainer(viewModel: createDefaultViewModel(), displayName: "1. Collapsed State")

             // Preview the expanded state with a result
            QuickAccessPreviewContainer(viewModel: createExpandedViewModel(), displayName: "2. Expanded State (With Result)")

             // Preview expanded state during processing
             QuickAccessPreviewContainer(viewModel: createExpandedProcessingViewModel(), displayName: "3. Expanded Processing")

             // Preview expanded state with an error message
             QuickAccessPreviewContainer(viewModel: createExpandedErrorViewModel(), displayName: "4. Expanded Error")
        }
        // Set a background for the preview group for better visibility
        .background(Color(red: 0.3, green: 0.3, blue: 0.3)) // Slightly lighter background for contrast
    }
}
