//
//  CreateEditPromptView.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI

struct CreateEditPromptView: View {
    @EnvironmentObject var viewModel: PromptLibraryViewModel
    @Environment(\.dismiss) var dismiss // To close the sheet

    // Available categories - can be dynamic later
    private let categories = ["General", "Development", "Productivity", "Creativity", "Writing", "Education", "Research", "Marketing", "Custom"]

    var body: some View {
        VStack(spacing: 20) {
            Text(viewModel.promptToEdit == nil ? "Create New Prompt" : "Edit Prompt")
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.bottom)

            // Form fields
            Form {
                TextField("Title", text: $viewModel.editablePromptTitle)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Picker("Category", selection: $viewModel.editablePromptCategory) {
                    ForEach(categories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                // Allow custom category input if "Custom" is selected (optional enhancement)

                VStack(alignment: .leading) {
                    Text("Prompt Text:")
                    TextEditor(text: $viewModel.editablePromptText)
                        .frame(minHeight: 150, maxHeight: 400)
                        .border(Color.gray.opacity(0.3), width: 1)
                        .cornerRadius(5)
                }
                
                TextField("Tags (comma-separated)", text: $viewModel.editablePromptTagsString)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .help("Enter tags separated by commas, e.g., coding, python, algorithm")
            }
            .padding(.bottom)


            // Action Buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(viewModel.promptToEdit == nil ? "Create Prompt" : "Save Changes") {
                    viewModel.savePromptFromSheet()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.editablePromptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          viewModel.editablePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(25)
        .frame(minWidth: 500, idealWidth: 600, minHeight: 450, idealHeight: 550) // Good size for a sheet
        .onAppear {
            // If no prompt is being edited (i.e., creating new), and category is empty, set default
            if viewModel.promptToEdit == nil && viewModel.editablePromptCategory.isEmpty {
                viewModel.editablePromptCategory = "General"
            }
        }
    }
}

// MARK: - Preview
struct CreateEditPromptView_Previews: PreviewProvider {
    static func configuredViewModel(isEditing: Bool) -> PromptLibraryViewModel {
        let vm = PromptLibraryViewModel()
        if isEditing {
            let examplePrompt = Prompt.examplePrompts.first ?? Prompt(title: "Test Edit", text: "Editing this prompt.", category: "Testing", isUserDefined: true, tags: ["edit", "test"])
            // If store is empty, add it so it can be "edited"
            if PromptStore.shared.getPrompt(withId: examplePrompt.id) == nil {
                 PromptStore.shared.addPrompt(examplePrompt)
            }
            vm.prepareToEditPrompt(examplePrompt)
        } else {
            vm.prepareForCreateNewPrompt() // ensure fields are clear for create mode
        }
        return vm
    }

    static var previews: some View {
        Group {
            CreateEditPromptView()
                .environmentObject(configuredViewModel(isEditing: false))
                .previewDisplayName("Create New Prompt")

            CreateEditPromptView()
                .environmentObject(configuredViewModel(isEditing: true))
                .previewDisplayName("Edit Prompt")
        }
        .onAppear {
            // Ensure the mock store has data for the preview
             if PromptStore.shared.prompts.isEmpty {
                 Prompt.examplePrompts.forEach { PromptStore.shared.addPrompt($0) }
             }
        }
    }
}
