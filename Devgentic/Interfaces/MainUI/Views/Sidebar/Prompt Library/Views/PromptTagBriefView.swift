// PromptTagBriefView.swift
import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.Devgentic", category: "PromptTagBriefView")

/// A view that displays a brief overview of a prompt and allows in-place editing.
struct PromptTagBriefView: View {
    /// The original prompt data.
    let originalPrompt: Prompt // Renamed to avoid confusion with editable state
    
    /// Closure to be called when the "Save" button is tapped with the updated prompt.
    var onSave: (Prompt) -> Void
    
    /// Closure to be called to dismiss the popover.
    var onClose: () -> Void

    // MARK: - State for Editing
    @State private var isEditing: Bool = false
    @State private var editableTitle: String
    @State private var editableText: String
    // Store the initial category and tags to re-apply them on save, as they are not edited here.
    private let initialCategory: String
    private let initialTags: [String]?

    // Environment object to access shared prompt store for updates
    // Not strictly needed here if all save logic is passed up via onSave,
    // but could be an alternative for direct saving if desired.
    // For now, we'll rely on the onSave callback.
    // @EnvironmentObject var promptStore: PromptStore

    init(prompt: Prompt, onSave: @escaping (Prompt) -> Void, onClose: @escaping () -> Void) {
        self.originalPrompt = prompt
        self.onSave = onSave
        self.onClose = onClose
        
        // Initialize editable state with the prompt's current values
        _editableTitle = State(initialValue: prompt.title)
        _editableText = State(initialValue: prompt.text)
        self.initialCategory = prompt.category
        self.initialTags = prompt.tags
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView
            
            if isEditing {
                editingView
            } else {
                displayView
            }
            
            footerView
        }
        .padding()
        .frame(width: 340, height: isEditing ? 320 : 280) // Adjust height for editing mode
        .background(VisualEffectBlur(material: .popover).ignoresSafeArea())
        .cornerRadius(10)
        .shadow(radius: 5)
        .animation(.default, value: isEditing) // Animate changes between modes
    }

    // MARK: - Subviews
    private var headerView: some View {
        HStack {
            if isEditing {
                TextField("Prompt Title", text: $editableTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .textFieldStyle(PlainTextFieldStyle()) // Use PlainTextFieldStyle for a cleaner look in edit mode
                    .padding(.vertical, 2) // Add some padding to make it look like part of the design
                    .background(Color(NSColor.controlBackgroundColor)) // Subtle background for TextField
                    .cornerRadius(4)
            } else {
                Text(originalPrompt.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
            }
            Spacer()
            Button(action: {
                if isEditing {
                    // If changes were made, consider an "are you sure" or revert them.
                    // For simplicity, just revert to original and exit edit mode.
                    editableTitle = originalPrompt.title
                    editableText = originalPrompt.text
                    isEditing = false
                } else {
                    onClose() // Standard close action
                }
            }) {
                Image(systemName: isEditing ? "xmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 16))
            }
            .buttonStyle(PlainButtonStyle())
            .help(isEditing ? "Cancel Editing" : "Close")
        }
    }

    private var displayView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(originalPrompt.text)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 50, maxHeight: 180) // Adjusted maxHeight for display mode
            .padding(EdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5))
            .background(Color(NSColor.textBackgroundColor).opacity(0.5))
            .cornerRadius(6)
        }
    }

    private var editingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // TextEditor for the prompt text
            TextEditor(text: $editableText)
                .font(.system(size: 13))
                .frame(minHeight: 100, maxHeight: .infinity) // Allow it to take more space
                .padding(2)
                .border(Color.gray.opacity(0.3), width: 1)
                .cornerRadius(6)
            
            // Optionally, you could add fields for category and tags here if needed
            // For now, keeping it focused on title and text as per the request.
        }
    }

    private var footerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Category: \(initialCategory)") // Show initial category, not editable here
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let tags = initialTags, !tags.isEmpty {
                    Text("Tags: \(tags.joined(separator: ", "))") // Show initial tags
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            
            if isEditing {
                Button("Save") {
                    handleSaveChanges()
                }
                .buttonStyle(BorderedProminentButtonStyle())
                .keyboardShortcut(.defaultAction) // Allows Enter to trigger save
            } else {
                Button("Edit") {
                    // Populate editable fields with current prompt data before entering edit mode
                    editableTitle = originalPrompt.title
                    editableText = originalPrompt.text
                    isEditing = true
                }
                .buttonStyle(BorderedProminentButtonStyle())
            }
        }
    }

    // MARK: - Actions
    private func handleSaveChanges() {
        logger.debug("Attempting to save changes for prompt: \(originalPrompt.id.uuidString)")
        // Create an updated prompt object
        // Note: We use originalPrompt.id and other non-editable fields like createdAt, isUserDefined
        // and the initialCategory and initialTags loaded in init.
        var updatedPrompt = originalPrompt
        updatedPrompt.title = editableTitle
        updatedPrompt.text = editableText
        // If category and tags were editable, you'd update them here from their respective @State vars.
        // Since they are not editable in this design, they remain as per originalPrompt.
        // Or, if you made them editable:
        // updatedPrompt.category = editableCategory
        // updatedPrompt.tags = editableTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        onSave(updatedPrompt)
        isEditing = false // Exit editing mode
        // onClose() // Optionally close the popover immediately after save
    }
}

// MARK: - Previews
struct PromptTagBriefView_Previews_InlineEdit: PreviewProvider {
    static var samplePrompt1: Prompt {
        Prompt(
            id: UUID(),
            title: "Explain Complex Concept Simply",
            text: "Explain the concept of quantum entanglement to a five-year-old. Use simple analogies and avoid jargon. The explanation should be engaging and easy to understand, focusing on the core idea of interconnectedness without delving into the mathematical formalism. Ensure the tone is patient and encouraging.",
            category: "Education",
            isUserDefined: true,
            tags: ["explain", "simple", "science"]
        )
    }
    
    static var samplePrompt2: Prompt {
        Prompt(
            id: UUID(),
            title: "Generate Python Code",
            text: "Write a Python function that makes a GET request to 'https://api.example.com/data' and returns the JSON response. Include error handling for network issues and non-200 status codes. Use the 'requests' library.",
            category: "Development",
            isUserDefined: false,
            tags: ["python", "api"]
        )
    }

    @State static var previewPrompt1 = samplePrompt1 // Use @State for mutable preview prompt
    @State static var previewPrompt2 = samplePrompt2

    static var previews: some View {
        Group {
            PromptTagBriefView(
                prompt: previewPrompt1,
                onSave: { updatedPrompt in
                    print("Save tapped for: \(updatedPrompt.title). New text: \(updatedPrompt.text)")
                    // Simulate update in preview
                    previewPrompt1 = updatedPrompt
                },
                onClose: {
                    print("Close tapped for prompt 1")
                }
            )
            .previewLayout(.sizeThatFits)
            .padding()
            .previewDisplayName("Detailed Prompt (View Mode)")
            
            // To preview edit mode, you might need a wrapper view or toggle in preview
            PromptTagBriefView(
                prompt: previewPrompt2,
                onSave: { updatedPrompt in
                    print("Save tapped for: \(updatedPrompt.title)")
                    previewPrompt2 = updatedPrompt
                },
                onClose: {
                    print("Close tapped for prompt 2")
                }
            )
            // .environmentObject(PromptStore.shared) // If PromptStore was used directly
            .onAppear {
                // Hack to show edit mode in preview, not ideal for real use
                // In a real app, the "Edit" button would toggle this.
                // For preview, you might need a @State var in the PreviewProvider itself.
            }
            .previewLayout(.sizeThatFits)
            .padding()
            .previewDisplayName("Coding Prompt (Can Toggle Edit)")
        }
    }
}
