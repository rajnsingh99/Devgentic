//
//  PromptListItemView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//
// Views/PromptLibrary/PromptListItemView.swift
import SwiftUI

struct PromptListItemView: View {
    let prompt: Prompt
    @EnvironmentObject var viewModel: PromptLibraryViewModel
    
    private var isSelected: Bool {
        viewModel.selectedPrompt?.id == prompt.id
    }

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle") // Simple selection indicator
                .foregroundColor(isSelected ? .accentColor : Color(NSColor.secondaryLabelColor))
            Text(prompt.title)
                .foregroundColor(Color(NSColor.labelColor)) // Ensure text is visible
                .padding(.vertical, 4) // Minimal padding
            Spacer()
        }
        .padding(.horizontal, 8) // Padding for the HStack
        .frame(height: 30) // Give it a fixed height for now to ensure it's not collapsing
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color(NSColor.controlBackgroundColor).opacity(0.5)) // Visible background
        .contentShape(Rectangle()) // Ensure tappable
        .cornerRadius(4)
    }
}

// MARK: - Preview (can be simplified or commented out during this debug phase)
struct PromptListItemView_Previews: PreviewProvider {
    static let mockPrompt = Prompt(
        title: "Test Prompt Title",
        text: "Test prompt text.",
        category: "Test",
        isUserDefined: true
    )
    static let mockViewModel = PromptLibraryViewModel()

    static var previews: some View {
        PromptListItemView(prompt: mockPrompt)
            .environmentObject(mockViewModel)
            .padding()
            .frame(width: 300)
            .previewDisplayName("Simplified Item")
            .onAppear {
                 if PromptStore.shared.prompts.isEmpty {
                     PromptStore.shared.addPrompt(mockPrompt)
                 }
                 mockViewModel.selectPrompt(mockPrompt) // Test selection
            }
    }
}
