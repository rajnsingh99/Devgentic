//
//  PromptDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptDetailView")

struct PromptDetailView: View {
    let prompt: Prompt
    @EnvironmentObject var libraryViewModel: PromptLibraryViewModel
    @EnvironmentObject var mainViewModel: MainApplicationViewModel // For using the prompt

    @State private var showDeleteConfirmation: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            // Header: Title and Actions
            HStack {
                Text(prompt.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                Spacer()
                
                // Edit Button
                Button {
                    libraryViewModel.prepareToEditPrompt(prompt)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .help("Edit this prompt")

                // Delete Button
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
                .help("Delete this prompt")
            }
            .padding(.bottom, 5)

            // Category and Tags
            HStack(spacing: 10) {
                Text("Category: \(prompt.category)")
                    .font(.subheadline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .clipShape(Capsule())

                if let tags = prompt.tags, !tags.isEmpty {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                Spacer()
            }
            .padding(.bottom, 10)
            
            Divider()

            // Prompt Text Area
            Text("Prompt Content:")
                .font(.title3)
                .fontWeight(.semibold)
            
            ScrollView {
                Text(prompt.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(NSColor.textBackgroundColor).opacity(0.5)) // Slight background for text area
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity) // Allow scroll view to expand

            Spacer() // Pushes "Use Prompt" button to the bottom

            // "Use Prompt" Button
            Button {
                usePrompt()
            } label: {
                HStack {
                    Image(systemName: "arrow.right.circle.fill")
                    Text("Use Prompt in Chat")
                }
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle()) // Use PlainButtonStyle for custom background and full width
            .shadow(radius: 3)

        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.3)) // Background for the detail view
        .alert("Delete Prompt?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                libraryViewModel.deletePrompt(prompt)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete the prompt \"\(prompt.title)\"? This action cannot be undone.")
        }
    }

    private func usePrompt() {
        mainViewModel.userInput = prompt.text
        libraryViewModel.updatePromptUsage(prompt: prompt) // Mark as used
        
        // Close the prompt library panel
        // This assumes the panel's visibility is controlled by a @Binding in its parent,
        // which we'll handle during integration with MainApplicationView.
        // For now, we can log this action.
        logger.info("Used prompt: '\(prompt.title)'. Text copied to main input.")
        
        // To actually close the panel, the `showPromptLibrary` binding in PromptLibraryPanelView
        // needs to be set to false. This action should ideally be done by PromptLibraryPanelView itself
        // or by MainApplicationViewModel. Let's assume PromptLibraryPanelView handles its closure.
        // We can notify it or have a shared state. For now, the parent will close.
    }
}

// MARK: - Preview
struct PromptDetailView_Previews: PreviewProvider {
    static let mockPrompt = Prompt(
        id: UUID(),
        title: "Elaborate Content Creator",
        text: "Please elaborate on the provided topic [Topic Here] by generating a comprehensive and engaging piece of content. The content should be well-structured, informative, and at least 500 words long. Include relevant examples, statistics if applicable, and a concluding summary. Maintain a [Tone: e.g., professional, conversational, academic] tone throughout the piece. Ensure the language is clear and accessible to a general audience. \n\nKey areas to cover:\n1. Introduction to the topic.\n2. Main arguments/points with supporting details.\n3. Potential counter-arguments or alternative perspectives (and address them).\n4. Real-world applications or implications.\n5. Conclusion summarizing the key takeaways.",
        category: "Content Creation",
        isUserDefined: true,
        tags: ["writing", "long-form", "elaboration"]
    )
    static let mockLibraryVM = PromptLibraryViewModel()
    static let mockMainVM = MainApplicationViewModel()
    
    static var previews: some View {
        PromptDetailView(prompt: mockPrompt)
            .environmentObject(mockLibraryVM)
            .environmentObject(mockMainVM)
            .onAppear {
                // Ensure the mock store has data for the preview
                 if PromptStore.shared.prompts.isEmpty {
                     Prompt.examplePrompts.forEach { PromptStore.shared.addPrompt($0) }
                 }
            }
            .frame(width: 500, height: 700)
            .previewDisplayName("Prompt Detail")
    }
}
