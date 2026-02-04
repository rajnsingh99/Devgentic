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
    
    // To give focus to the title field when the view appears
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            Text(viewModel.promptToEdit == nil ? "Create New Prompt" : "Edit Prompt")
                .font(.title2)
                .fontWeight(.semibold)
                .padding()
            
            Divider()

            // MARK: - Form Fields
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 20) {
                // --- Title Row ---
                GridRow(alignment: .center) {
                    Text("Title")
                        .gridColumnAlignment(.trailing)
                    
                    TextField("Enter a clear and concise title", text: $viewModel.editablePromptTitle)
                        .textFieldStyle(.roundedBorder)
                        .focused($isTitleFocused)
                }
                
                // --- Category Row ---
                GridRow(alignment: .center) {
                    Text("Category")
                        .gridColumnAlignment(.trailing)
                    
                    Picker("Category", selection: $viewModel.editablePromptCategory) {
                        ForEach(categories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden() // Hide the default picker label
                }

                // --- Prompt Text Row ---
                GridRow(alignment: .top) {
                    Text("Prompt Text")
                        .gridColumnAlignment(.trailing)
                        .padding(.top, 8)
                    
                    TextEditor(text: $viewModel.editablePromptText)
                        .font(.body)
                        .frame(minHeight: 150, maxHeight: 400)
                        .padding(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
                
                // --- Tags Row ---
                GridRow(alignment: .center) {
                    Text("Tags")
                        .gridColumnAlignment(.trailing)
                    
                    TextField("Comma-separated, e.g., coding, python", text: $viewModel.editablePromptTagsString)
                        .textFieldStyle(.roundedBorder)
                        .help("Use commas to separate multiple tags.")
                }
            }
            .padding(20)

            Spacer()
            
            Divider()

            // MARK: - Action Buttons
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
            .padding()
        }
        .onAppear {
            // If no prompt is being edited (i.e., creating new), and category is empty, set default
            if viewModel.promptToEdit == nil && viewModel.editablePromptCategory.isEmpty {
                viewModel.editablePromptCategory = "General"
            }
            // Focus the title field automatically
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTitleFocused = true
            }
        }
    }
}

// MARK: - Preview
struct CreateEditPromptView_Previews: PreviewProvider {
    static func configuredViewModel(isEditing: Bool) -> PromptLibraryViewModel {
        let vm = PromptLibraryViewModel()
        if isEditing {
            let examplePrompt = DevPrompt.examplePrompts.first ?? DevPrompt(title: "Test Edit", text: "Editing this prompt.", category: "Testing", isUserDefined: true, tags: ["edit", "test"])
            if PromptService.shared.getPrompt(withId: examplePrompt.id) == nil {
                 PromptService.shared.addPrompt(examplePrompt)
            }
            vm.prepareToEditPrompt(examplePrompt)
        } else {
            vm.prepareForCreateNewPrompt()
        }
        return vm
    }

    static var previews: some View {
        Group {
            CreateEditPromptView()
                .environmentObject(configuredViewModel(isEditing: false))
                .previewDisplayName("Create New Prompt")
                .frame(width: 550, height: 500)

            CreateEditPromptView()
                .environmentObject(configuredViewModel(isEditing: true))
                .previewDisplayName("Edit Prompt")
                .frame(width: 550, height: 500)
        }
        .onAppear {
             if PromptService.shared.prompts.isEmpty {
                 DevPrompt.examplePrompts.forEach { PromptService.shared.addPrompt($0) }
             }
        }
    }
}
