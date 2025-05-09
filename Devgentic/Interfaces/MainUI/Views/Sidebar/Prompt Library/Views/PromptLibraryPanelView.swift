//
//  PromptLibraryPanelView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptLibraryPanelView")

struct PromptLibraryPanelView: View {
    @StateObject var promptLibraryViewModel = PromptLibraryViewModel()
    @Binding var showPromptLibrary: Bool
    @EnvironmentObject var mainViewModel: MainApplicationViewModel

    var body: some View {
        ZStack {
            // Dimmed background, tap to dismiss
            Color.black.opacity(0.45) // Slightly darker for better contrast with panel
                .edgesIgnoringSafeArea(.all)
                .onTapGesture { closePanel() }

            // Main Panel Content
            VStack(spacing: 0) {
                // Panel Header: Title, Search, Add Button, Close Button
                HStack {
                    Text("Prompts Library")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.leading) // Padding for the title

                    Spacer() // Pushes search/add to center, then close button to right

                    // Search Bar and Add Button Group
                    HStack(spacing: 10) { // Increased spacing for better visual separation
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(Color(NSColor.secondaryLabelColor).opacity(0.7)) // Slightly less prominent
                        
                        TextField("Search Prompts...", text: $promptLibraryViewModel.searchText)
                            .textFieldStyle(.plain)
                            .frame(maxWidth: 280) // Constrain width of search field
                            .padding(.vertical, 8) // Adequate vertical padding
                            .padding(.horizontal, 10) // Horizontal padding inside text field
                            .background(Color.black.opacity(0.2)) // Darker background for search
                            .cornerRadius(8) // Rounded corners for search field
                            .foregroundColor(.white.opacity(0.85)) // Text color

                        Button {
                            promptLibraryViewModel.prepareForCreateNewPrompt()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Create New Prompt")
                    }
                    .padding(.horizontal) // Padding around the search/add group

                    Spacer() // Pushes close button to the far right

                    Button(action: closePanel) {
                        Image(systemName: "xmark.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22) // Slightly larger close button
                            .foregroundColor(Color(NSColor.placeholderTextColor)) // Standard color for close
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.trailing) // Padding for the close button
                }
                .padding(.vertical, 12) // Vertical padding for the entire header
                .background(Color.black.opacity(0.4)) // Slightly more opaque header background

                Divider().background(Color.white.opacity(0.15)) // Softer divider

                // Main Content Area: Split View
                HSplitView {
                     leftPane()
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 450) // Adjusted ideal/max width slightly
                     rightPane()
                        .frame(maxWidth: .infinity) // Right pane takes remaining space
                }
            }
            .frame(minWidth: 850, idealWidth: 1000, maxWidth: 1400, // Adjusted overall panel size
                   minHeight: 550, idealHeight: 700, maxHeight: 900)
            .background(VisualEffectBlur(material: .sidebar, blendingMode: .behindWindow).edgesIgnoringSafeArea(.all))
            .clipShape(RoundedRectangle(cornerRadius: 16)) // Slightly larger corner radius
            .shadow(color: Color.black.opacity(0.6), radius: 20, x: 0, y: 8) // More pronounced shadow
            .padding(30) // Reduced outer padding for a bit more screen space
        }
        .transition(.scale(scale: 0.95).combined(with: .opacity)) // Smoother transition
        .onAppear {
            logger.info("PromptLibraryPanelView appeared.")
            // Ensure example prompts are loaded if the store is empty
            // This is handled by PromptStore.shared initialization, but good to be aware
        }
    }

    @ViewBuilder
    private func leftPane() -> some View {
        VStack(spacing: 0) { // Use VStack to manage content within the left pane
            // List of Prompts or Placeholder Text
            if promptLibraryViewModel.filteredPrompts.isEmpty {
                VStack { // Center placeholder text
                    Spacer()
                    Image(systemName: promptLibraryViewModel.searchText.isEmpty ? "tray.fill" : "magnifyingglass") // Contextual icon
                        .font(.system(size: 40))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .padding(.bottom, 5)
                    Text(promptLibraryViewModel.searchText.isEmpty ? "No prompts in library." : "No prompts match \"\(promptLibraryViewModel.searchText)\".")
                        .font(.headline)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                    Text(promptLibraryViewModel.searchText.isEmpty ? "Click '+' in the header to add a new prompt." : "Try a different search term.")
                        .font(.subheadline)
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding() // Add some padding around the placeholder content
            } else {
                List(selection: $promptLibraryViewModel.selectedPrompt) {
                    ForEach(promptLibraryViewModel.filteredPrompts) { prompt in
                        PromptListItemView(prompt: prompt)
                            .tag(prompt) // Tag for selection
                            .onTapGesture { // Ensure selection works
                                promptLibraryViewModel.selectPrompt(prompt)
                            }
                            // Potentially add contextMenu here in the future
                    }
                }
                .listStyle(.sidebar) // Appropriate style for a selection list
                .environmentObject(promptLibraryViewModel) // <<< --- ADDED THIS LINE ---
                // This makes the promptLibraryViewModel available to PromptListItemView and its children.
            }
        }
        // The .sheet modifier for creating/editing prompts is associated with this pane's context.
        .sheet(isPresented: $promptLibraryViewModel.showingCreateOrEditPromptSheet) {
            // Pass the same ViewModel instance to the sheet
            CreateEditPromptView()
                .environmentObject(promptLibraryViewModel)
                // Define a good size for the sheet
                .frame(minWidth: 550, idealWidth: 650, maxWidth: 800,
                       minHeight: 450, idealHeight: 550, maxHeight: 700)
        }
    }

    @ViewBuilder
    private func rightPane() -> some View {
        // Detail view for the selected prompt or a placeholder
        Group {
            if let selectedPrompt = promptLibraryViewModel.selectedPrompt {
                PromptDetailView(prompt: selectedPrompt)
                    // Pass necessary EnvironmentObjects if PromptDetailView or its subviews require them
                    .environmentObject(promptLibraryViewModel)
                    .environmentObject(mainViewModel) // For "Use Prompt" functionality
            } else {
                // Placeholder when no prompt is selected
                VStack {
                    Spacer()
                    Image(systemName: "text.book.closed.fill") // More distinct icon
                        .font(.system(size: 50))
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .padding(.bottom, 10)
                    Text("Select a prompt")
                        .font(.title2)
                        .fontWeight(.medium)
                        .foregroundColor(Color(NSColor.labelColor.withAlphaComponent(0.8)))
                    Text("Choose a prompt from the list on the left to see its details here.")
                        .font(.body)
                        .foregroundColor(Color(NSColor.secondaryLabelColor))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Consistent background for the right pane, slightly different from the list background for visual hierarchy
        .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
    }

    private func closePanel() {
        withAnimation(.easeInOut(duration: 0.2)) { // Use a standard ease for closing
            showPromptLibrary = false
        }
        logger.info("PromptLibraryPanelView closed.")
    }
}

// MARK: - Preview
struct PromptLibraryPanelView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a mock MainApplicationViewModel for the preview
        let mockMainViewModel = MainApplicationViewModel()
        
        // Ensure PromptStore has data for the preview.
        // This is crucial for the preview to be meaningful.
        if PromptStore.shared.prompts.isEmpty {
             Prompt.examplePrompts.forEach { PromptStore.shared.addPrompt($0) }
             // Log to confirm example prompts are added for preview
             // print("Preview: Added example prompts to PromptStore. Total: \(PromptStore.shared.prompts.count)")
        } else {
            // print("Preview: PromptStore already has prompts. Total: \(PromptStore.shared.prompts.count)")
        }

        // Create a local instance of PromptLibraryViewModel for the preview
        // This allows the preview to have its own isolated state if needed,
        // though it will still use the shared PromptStore.
        // let previewPromptLibVM = PromptLibraryViewModel() // Not strictly needed if @StateObject is used above
        

        return PromptLibraryPanelView(
            // If you were to pass previewPromptLibVM, change @StateObject to @ObservedObject
            // in PromptLibraryPanelView. For now, it creates its own using PromptStore.shared.
            showPromptLibrary: .constant(true) // Keep the panel visible for preview
        )
        .environmentObject(mockMainViewModel) // Provide the MainApplicationViewModel
        // Note: The PromptLibraryViewModel is created by @StateObject within PromptLibraryPanelView,
        // and then injected into the List's environment for PromptListItemView to use.
        // So, we don't need to inject another instance of PromptLibraryViewModel here for the panel itself.
        .frame(width: 1000, height: 700) // Set a representative size for the preview
        .previewDisplayName("Prompt Library Panel")
    }
}
