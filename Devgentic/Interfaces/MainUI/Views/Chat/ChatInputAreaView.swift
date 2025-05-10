// Views/ChatInputAreaView.swift
import SwiftUI
import os
import Combine

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatInputAreaView")

struct ChatInputAreaView: View {
    // Bindings and State passed down
    @Binding var userInput: String
    @Binding var showContextArea: Bool
    @Binding var activeContextFilePath: String?
    let isSending: Bool
    let showSettings: Bool
    var isInputFocused: FocusState<Bool>.Binding

    // Actions passed up
    let onSendMessage: () -> Void
    let onToggleContext: () -> Void

    // --- State variables for Prompt Suggestions ---
    @State private var showPromptSuggestions: Bool = false
    @State private var suggestionQuery: String = ""
    @State private var filteredPrompts: [Prompt] = []
    @State private var activePromptTriggerRange: NSRange? = nil
    
    @State private var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil

    // --- Constants for Styling ---
    private let iconSize: CGFloat = 18
    private let sendButtonSize: CGFloat = 26
    private let cornerRadiusValue: CGFloat = 12
    // These define the desired content height of the text editor itself (the NSTextView)
    private let textEditorMinHeight: CGFloat = 24
    private let textEditorMaxHeight: CGFloat = 200 // Max height for NSTextView content before it scrolls internally

    private let promptStore = PromptStore.shared // Assuming PromptStore is defined

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { // Outermost VStack
            promptSuggestionsArea // Extracted Helper View
            mainInputArea         // Extracted Helper View
        }
        // This allows the entire ChatInputAreaView (the outermost VStack) to grow vertically
        // based on its content (Suggestions + InputBox).
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: suggestionQuery) { oldValue, newValue in
            // logger.debug("Suggestion query changed from '\(oldValue)' to: '\(newValue)'. Filtering prompts.")
            performPromptFiltering(query: newValue)
        }
        .onChange(of: showPromptSuggestions) { oldValue, newValue in
            // logger.debug("showPromptSuggestions changed from \(oldValue) to: \(newValue). Current query: '\(suggestionQuery)'")
            if newValue {
                performPromptFiltering(query: suggestionQuery) // Filter when suggestions become visible
            } else {
                // Clear filtered prompts if suggestions are hidden and there were results
                if !filteredPrompts.isEmpty {
                    self.filteredPrompts = []
                    // logger.debug("showPromptSuggestions became false. Cleared filtered prompts.")
                }
            }
        }
    }

    // MARK: - Helper Views for Body Composition

    @ViewBuilder
    private var promptSuggestionsArea: some View {
        // Conditionally show PromptSuggestionView
        if showPromptSuggestions {
            // Assuming PromptSuggestionView is defined correctly
            PromptSuggestionView(
                prompts: filteredPrompts,
                suggestionQuery: suggestionQuery,
                onSelectPrompt: { selectedPrompt in
                    logger.info("Prompt selected: \(selectedPrompt.title)")
                    
                    guard let rangeToReplace = activePromptTriggerRange else {
                        logger.error("Cannot insert prompt tag: activePromptTriggerRange is nil.")
                        // Fallback: append to current text if range is lost
                        let currentText = userInput
                        let separator = currentText.isEmpty || currentText.last == " " ? "" : " "
                        userInput += "\(separator)#\(selectedPrompt.title) "
                        self.clearSuggestionStates()
                        return
                    }

                    let tagText = "#\(selectedPrompt.title)"
                    // Define attributes for the tag
                    let attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.systemBlue, // Example: Blue color for the tag
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium) // Example: Medium weight
                    ]
                    let attributedTag = NSAttributedString(string: tagText, attributes: attributes)
                    
                    // Create a mutable attributed string to append a trailing space with default attributes
                    let finalAttributedString = NSMutableAttributedString(attributedString: attributedTag)
                    // Ensure trailing space has default attributes to avoid continuing tag style
                    let defaultAttributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), // Match editor's default font
                        .foregroundColor: NSColor.labelColor // Match editor's default text color
                    ]
                    let trailingSpace = NSAttributedString(string: " ", attributes: defaultAttributes)
                    finalAttributedString.append(trailingSpace)

                    // Request the insertion in CustomTextEditor
                    self.attributedTextInsertionRequest = .init(
                        range: rangeToReplace,
                        attributedString: finalAttributedString
                    )
                    
                    self.clearSuggestionStates() // Hide suggestions panel
                    
                    // Ensure focus returns to the editor after selection
                    DispatchQueue.main.async {
                        self.isInputFocused.wrappedValue = true
                    }
                }
            )
            .padding(.bottom, 4) // Spacing between suggestions and input box
        }
    }

    private var mainInputArea: some View {
        // VStack for the main input box (background, border, etc.)
        VStack(spacing: 3) { // Spacing within the input box (e.g., between editor and toolbar)
            editorAndPlaceholderArea // Extracted Helper View
            toolbarArea              // Extracted Helper View
        }
        // Styling for the entire input box container
        .background(VisualEffectBlur(material: .hudWindow)) // Assuming VisualEffectBlur is defined
        .cornerRadius(cornerRadiusValue)
        .overlay( // Border
            RoundedRectangle(cornerRadius: cornerRadiusValue)
                .stroke(Color.gray.opacity(0.4), lineWidth: 1)
        )
    }

    private var editorAndPlaceholderArea: some View {
        ZStack(alignment: .topLeading) { // ZStack for editor and placeholder
            // Assuming CustomTextEditor is defined correctly
            CustomTextEditor(
                text: $userInput,
                onCommit: onSendMessage,
                minHeight: textEditorMinHeight,     // Pass min height for the text content
                maxHeight: textEditorMaxHeight,   // Pass max height for the text content
                showPromptSuggestions: $showPromptSuggestions,
                suggestionQuery: $suggestionQuery,
                activePromptTriggerRange: $activePromptTriggerRange,
                attributedTextInsertion: $attributedTextInsertionRequest
            )
            // VERY IMPORTANT: Allows the CustomTextEditor (NSScrollView) to grow based on its intrinsicContentSize
            .fixedSize(horizontal: false, vertical: true)
            // This frame modifier constrains the CustomTextEditor's NSScrollView in SwiftUI's layout.
            // The NSScrollView's intrinsicContentSize (now clamped by min/maxHeight) will drive this.
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)

            // Placeholder Text
            if userInput.isEmpty && !isInputFocused.wrappedValue {
                Text("Ask Devgentic...")
                    .font(Font.system(size: NSFont.systemFontSize))
                    .foregroundColor(Color(NSColor.placeholderTextColor))
                    .padding(.leading, 5) // Standard NSTextView horizontal padding
                    .padding(.top, 3)
                    .allowsHitTesting(false) // Placeholder should not intercept clicks
            }
        }
        // Padding for the text editor area within its bordered container
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .focused(isInputFocused) // Manage focus state
        .disabled(isSending || showSettings) // Disable input when sending or settings are shown
    }

    private var toolbarArea: some View {
        // Toolbar HStack for action buttons
        HStack(spacing: 12) {
            Button { logger.info("Plus icon tapped") } label: {
                Image(systemName: "plus")
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSending || showSettings)
            .help("Attach files (Not Implemented)")

            Button {
                logger.info("Internet Search (globe) icon tapped - No functionality")
            } label: {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSending || showSettings)
            .help("Web Search (Not Implemented)")
            
            Button(action: onToggleContext) {
                Image(systemName: "paperclip")
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundColor(showContextArea ? Color(NSColor.controlAccentColor) : .secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSending || showSettings)
            .help(showContextArea ? "Hide Context Area" : "Show Context Area")

            Spacer()

            Button { logger.info("Mic icon tapped") } label: {
                Image(systemName: "mic.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSending || showSettings)
            .help("Voice Input (Not Implemented)")

            // Send Button
            Button(action: onSendMessage) {
                if isSending {
                    ProgressView().controlSize(.small).frame(width: sendButtonSize, height: sendButtonSize)
                } else {
                    ZStack {
                        Circle().fill(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || showSettings ? Color.gray.opacity(0.3) : Color(NSColor.controlAccentColor))
                        Image(systemName: "arrow.up")
                            .resizable() // Apply .resizable() first
                            .scaledToFit()
                            .fontWeight(.semibold) // Apply fontWeight after resizable and scaledToFit
                            .frame(width: sendButtonSize * 0.5, height: sendButtonSize * 0.5)
                            .foregroundColor(Color.white)
                    }
                    .frame(width: sendButtonSize, height: sendButtonSize)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || showSettings)
            .keyboardShortcut(.return, modifiers: .shift)
            .help("Send Message (Shift+Return to send, Alt+Return for newline)")
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
    }


    // MARK: - Helper Methods
    private func performPromptFiltering(query: String) {
        guard showPromptSuggestions else {
            if !filteredPrompts.isEmpty {
                self.filteredPrompts = []
            }
            return
        }

        let allPrompts = promptStore.getAllPrompts() // Assuming promptStore is correctly populated
        if query.isEmpty {
            self.filteredPrompts = Array(allPrompts.sorted { $0.title.lowercased() < $1.title.lowercased() }.prefix(10))
        } else {
            let lowercasedQuery = query.lowercased()
            self.filteredPrompts = allPrompts.filter {
                $0.title.lowercased().contains(lowercasedQuery)
            }
            .sorted { $0.title.lowercased() < $1.title.lowercased() }
            .prefix(10)
            .map{$0}
        }
    }
    
    private func clearSuggestionStates() {
        self.showPromptSuggestions = false
        self.activePromptTriggerRange = nil
        self.suggestionQuery = ""
    }
}

// MARK: - Preview Provider
struct ChatInputAreaView_Previews_ResizableFix: PreviewProvider { // Renamed Preview
    @FocusState static var isFocused: Bool
    @State static var text = ""
    @State static var showCtx = false
    @State static var ctxPath: String? = nil

    struct ChatInputAreaWithSuggestionsPreview: View {
        @State private var userInputPreview: String = "This is some initial text.\nTry adding more lines using Alt+Enter."
        @FocusState private var isInputFocusedPreview: Bool
        
        var body: some View {
            VStack(alignment: .leading) {
                 Text("Type text. Use Alt+Enter for newlines. Shift+Return to 'send'.")
                     .font(.caption)
                     .foregroundColor(.gray)
                     .padding(.bottom, 5)
                ChatInputAreaView(
                    userInput: $userInputPreview,
                    showContextArea: .constant(false),
                    activeContextFilePath: .constant(nil),
                    isSending: false,
                    showSettings: false,
                    isInputFocused: $isInputFocusedPreview,
                    onSendMessage: { print("Preview: Send Tapped. Current input: \(userInputPreview)") },
                    onToggleContext: { print("Preview: Toggle Context Tapped") }
                )
            }
            .onAppear {
                 // Ensure PromptStore is populated for previews
                 if PromptStore.shared.getAllPrompts().isEmpty {
                     // Manually add some example prompts if your Prompt/PromptStore structure allows
                     // This is a placeholder; adapt to your actual Prompt/PromptStore implementation
                     // Example: PromptStore.shared.addPrompt(Prompt(title: "Example", text: "Example prompt text"))
                 }
            }
        }
    }

    static var previews: some View {
        ScrollView {
            VStack(spacing: 30) {
                Text("Chat Input Area (Resizable Fix Previews)")
                    .font(.largeTitle)
                    .padding(.bottom)

                VStack(alignment: .leading) {
                    Text("Default Input (Empty)")
                        .font(.headline)
                    ChatInputAreaView(
                        userInput: $text,
                        showContextArea: $showCtx,
                        activeContextFilePath: $ctxPath,
                        isSending: false,
                        showSettings: false,
                        isInputFocused: $isFocused,
                        onSendMessage: { print("Preview: Send Tapped. Input: \(text)") },
                        onToggleContext: { showCtx.toggle(); if showCtx { ctxPath = "/preview/file.swift"} else { ctxPath = nil } }
                    )
                }
                .padding()
                .background(Color.black.opacity(0.1))
                .cornerRadius(10)
                .previewDisplayName("Default (Empty)")
                
                Divider().padding(.vertical)
                
                VStack(alignment: .leading) {
                    Text("Multiline & Suggestions Test")
                        .font(.headline)
                    ChatInputAreaWithSuggestionsPreview()
                }
                .padding()
                .background(Color.black.opacity(0.1))
                .cornerRadius(10)
                .previewDisplayName("Multiline Test")
            }
            .padding()
            .frame(width: 480)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}
