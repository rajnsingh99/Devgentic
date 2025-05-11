// ChatInputAreaView.swift
// Views/ChatInputAreaView.swift
import SwiftUI
import os
import Combine
import AppKit // Ensure AppKit is imported

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatInputAreaView")

// Assuming NSAttributedString.Key.promptID is defined globally, e.g.:
// extension NSAttributedString.Key {
//     static let promptID = NSAttributedString.Key("promptID_unique_key")
// }
// If not, ensure it's consistently defined and used.

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

    // MARK: - State for Prompt Tag Brief View Popover
    @State private var tappedPromptDetail: Prompt? = nil       // Holds the prompt for the brief view
    // The tappedLinkAnchorRect was part of a previous feature for positioning.
    // If that feature was reverted as per "Code is now working, So I have reverted the both the file changes",
    // then this might not be needed, or its usage would depend on the "baseline" version of CustomTextEditor.
    // For now, I'll assume the popover is item-based as per the baseline ChatInputAreaView.swift provided.
    // If anchor-based positioning is still desired, tappedLinkAnchorRect would be re-introduced.
    // @State private var tappedLinkAnchorRect: CGRect? = nil // Example if anchor-based positioning was kept

    // --- Constants for Styling ---
    private let iconSize: CGFloat = 18
    private let sendButtonSize: CGFloat = 26
    private let cornerRadiusValue: CGFloat = 12
    private let textEditorMinHeight: CGFloat = 24
    private let textEditorMaxHeight: CGFloat = 200

    private let promptStore = PromptStore.shared // Direct access to PromptStore
    
    // The MainApplicationViewModel is no longer directly used by the popover's edit action,
    // but might be used by other parts of this view or its parent.
    // If it was removed from the environment of this view's hierarchy, this would cause an issue.
    // Assuming it's still provided if other functionalities depend on it.
    // @EnvironmentObject var mainViewModel: MainApplicationViewModel


    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            promptSuggestionsArea
            mainInputArea
        }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: suggestionQuery) { oldValue, newValue in
            performPromptFiltering(query: newValue)
        }
        .onChange(of: showPromptSuggestions) { oldValue, newValue in
            if newValue {
                performPromptFiltering(query: suggestionQuery)
            } else {
                if !filteredPrompts.isEmpty {
                    self.filteredPrompts = []
                }
            }
        }
    }

    // MARK: - Helper Views for Body Composition

    @ViewBuilder
    private var promptSuggestionsArea: some View {
        if showPromptSuggestions {
            PromptSuggestionView(
                prompts: filteredPrompts,
                suggestionQuery: suggestionQuery,
                onSelectPrompt: { selectedPrompt in
                    logger.info("Prompt selected: \(selectedPrompt.title)")
                    
                    guard let rangeToReplace = activePromptTriggerRange else {
                        logger.error("Cannot insert prompt tag: activePromptTriggerRange is nil.")
                        let currentText = userInput
                        let separator = currentText.isEmpty || currentText.last == " " ? "" : " "
                        userInput += "\(separator)#\(selectedPrompt.title) "
                        self.clearSuggestionStates()
                        return
                    }

                    let tagText = "#\(selectedPrompt.title)"
                    // Ensure .promptID is correctly defined and accessible
                    let attributes: [NSAttributedString.Key: Any] = [
                        .foregroundColor: NSColor.systemBlue,
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                        // REMOVED: .link attribute to prevent system pop-up
                        // .link: URL(string: "prompt://\(selectedPrompt.id)") ?? URL(string: "about:blank")!,
                        NSAttributedString.Key.promptID: selectedPrompt.id // Assuming .promptID is defined
                    ]
                    let attributedTag = NSAttributedString(string: tagText, attributes: attributes)
                    
                    let finalAttributedString = NSMutableAttributedString(attributedString: attributedTag)
                    let defaultAttributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                        .foregroundColor: NSColor.labelColor
                    ]
                    let trailingSpace = NSAttributedString(string: " ", attributes: defaultAttributes)
                    finalAttributedString.append(trailingSpace)

                    self.attributedTextInsertionRequest = .init(
                        range: rangeToReplace,
                        attributedString: finalAttributedString
                    )
                    
                    self.clearSuggestionStates()
                    
                    DispatchQueue.main.async {
                        self.isInputFocused.wrappedValue = true
                    }
                }
            )
            .padding(.bottom, 4)
        }
    }

    private var mainInputArea: some View {
        VStack(spacing: 3) {
            editorAndPlaceholderArea
            toolbarArea
        }
        .background(VisualEffectBlur(material: .hudWindow))
        .cornerRadius(cornerRadiusValue)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadiusValue)
                .stroke(Color.gray.opacity(0.4), lineWidth: 1)
        )
    }

    private var editorAndPlaceholderArea: some View {
        ZStack(alignment: .topLeading) {
            CustomTextEditor(
                text: $userInput,
                onCommit: onSendMessage,
                minHeight: textEditorMinHeight,
                maxHeight: textEditorMaxHeight,
                showPromptSuggestions: $showPromptSuggestions,
                suggestionQuery: $suggestionQuery,
                activePromptTriggerRange: $activePromptTriggerRange,
                attributedTextInsertion: $attributedTextInsertionRequest,
                onPromptTagTapped: { promptID in // Assuming CustomTextEditor's onPromptTagTapped provides only UUID based on baseline
                    logger.debug("ChatInputAreaView: Received tap on promptID: \(promptID.uuidString)")
                    if let prompt = promptStore.getPrompt(withId: promptID) {
                        self.tappedPromptDetail = prompt
                        // If anchor-based positioning was reverted, tappedLinkAnchorRect is not set here.
                        // self.tappedLinkAnchorRect = anchorRect // This line would be active if anchorRect was passed and used
                        // self.showPromptBriefViewPopover = true // This would be used with anchor-based popover
                        logger.debug("ChatInputAreaView: Set prompt '\(prompt.title)' for brief view.")
                    } else {
                        logger.error("ChatInputAreaView: Tapped prompt with ID \(promptID.uuidString) not found in store.")
                        self.tappedPromptDetail = nil
                        // self.tappedLinkAnchorRect = nil
                        // self.showPromptBriefViewPopover = false
                    }
                }
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)
            // MARK: - Updated popover modifier to use onSave
            .popover(item: $tappedPromptDetail) { promptToShow in // Uses Identifiable nature of Prompt
                // Ensure PromptTagBriefView is correctly initialized with the new 'onSave'
                PromptTagBriefView(
                    prompt: promptToShow,
                    onSave: { updatedPrompt in // Use the new onSave closure
                        logger.info("Save requested for prompt: '\(updatedPrompt.title)' from brief view.")
                        promptStore.updatePrompt(updatedPrompt) // Update in the store
                        
                        // Update local state to reflect changes immediately in the popover if it were to re-render
                        // before dismissal, or if other UI elements depend on this specific instance.
                        self.tappedPromptDetail = updatedPrompt
                        
                        // Dismiss the popover after save.
                        // For item-based popover, setting tappedPromptDetail to nil dismisses it.
                        // However, since we just updated it, we might need to explicitly nil it out *after* the update
                        // if the update itself doesn't cause a re-evaluation that closes it.
                        // The most straightforward way to dismiss an item-based popover is to set its item to nil.
                        // Let's ensure it's dismissed.
                        DispatchQueue.main.async { // Ensure dismissal happens after current update cycle
                           self.tappedPromptDetail = nil
                        }
                        logger.info("Prompt '\(updatedPrompt.title)' updated and popover closed.")
                    },
                    onClose: {
                        self.tappedPromptDetail = nil // Dismiss popover by nilling out the item
                        logger.debug("ChatInputAreaView: Popover closed via PromptTagBriefView's onClose.")
                    }
                )
                .onAppear {
                    logger.debug("ChatInputAreaView: PromptTagBriefView appeared for \(promptToShow.title)")
                }
            }


            if userInput.isEmpty && !isInputFocused.wrappedValue {
                Text("Ask Devgentic...")
                    .font(Font.system(size: NSFont.systemFontSize))
                    .foregroundColor(Color(NSColor.placeholderTextColor))
                    .padding(.leading, 5)
                    .padding(.top, 3)
                    .allowsHitTesting(false)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .focused(isInputFocused)
        .disabled(isSending || showSettings)
    }

    private var toolbarArea: some View {
        // Toolbar area remains the same as your baseline version.
        // For brevity, I'll include it as it was in your provided baseline.
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

            Button(action: onSendMessage) {
                if isSending {
                    ProgressView().controlSize(.small).frame(width: sendButtonSize, height: sendButtonSize)
                } else {
                    ZStack {
                        Circle().fill(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || showSettings ? Color.gray.opacity(0.3) : Color(NSColor.controlAccentColor))
                        Image(systemName: "arrow.up")
                            .resizable()
                            .scaledToFit()
                            .fontWeight(.semibold)
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

        let allPrompts = promptStore.getAllPrompts()
        if query.isEmpty {
            self.filteredPrompts = Array(allPrompts.sorted { $0.title.lowercased() < $1.title.lowercased() }.prefix(10))
        } else {
            let lowercasedQuery = query.lowercased()
            self.filteredPrompts = allPrompts.filter {
                $0.title.lowercased().contains(lowercasedQuery) // Only searching title for simplicity here, can be expanded
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
// The preview provider from your baseline ChatInputAreaView.swift is used here.
// It might need adjustments to fully test the new onSave behavior if desired.
struct ChatInputAreaView_Previews_Phase2: PreviewProvider { // Renaming to avoid conflict if old one exists
    @FocusState static var isFocused: Bool
    
    // Using the actual PromptStore for previews to test saving.
    static var localPromptStore = PromptStore.shared
    
    // Sample MainApplicationViewModel for preview (though not directly used for edit in this flow)
    // static var mainViewModelPreview: MainApplicationViewModel = MainApplicationViewModel() // Assuming MainApplicationViewModel is defined

    struct ChatInputAreaInteractivePreview: View {
        @State private var userInputPreview: String = "Initial text. Try #Example" // Example might be from Prompt.examplePrompts
        @FocusState private var isInputFocusedPreview: Bool
        
        // Example prompt to use for testing
        // Ensure PromptStore has this prompt or add it.
        static var examplePromptID: UUID? = Prompt.examplePrompts.first?.id

        init() {
            // Ensure sample prompts exist in the shared store for preview consistency
            if let id = Self.examplePromptID, localPromptStore.getPrompt(withId: id) == nil, !Prompt.examplePrompts.isEmpty {
                localPromptStore.addPrompt(Prompt.examplePrompts.first!)
            } else if Prompt.examplePrompts.isEmpty {
                // Add a default if examplePrompts is empty
                let defaultExample = Prompt(title: "Example", text: "This is an example prompt.", category: "General", isUserDefined: true)
                localPromptStore.addPrompt(defaultExample)
                Self.examplePromptID = defaultExample.id
            } else if Self.examplePromptID == nil && !Prompt.examplePrompts.isEmpty {
                 Self.examplePromptID = Prompt.examplePrompts.first!.id
                 if localPromptStore.getPrompt(withId: Self.examplePromptID!) == nil {
                     localPromptStore.addPrompt(Prompt.examplePrompts.first!)
                 }
            }
        }

        var body: some View {
            VStack(alignment: .leading) {
                 Text("Type text. Try a #tag. Tapping a tag should show popover with inline edit.")
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
                // .environmentObject(mainViewModelPreview) // Not strictly needed for this preview's focus
                .environmentObject(localPromptStore) // Provide PromptStore if any subview uses it via @EnvironmentObject

                Text("Try tapping a #tag if one is inserted. For example, if 'Summarize Text' is a prompt, type #Summarize Text, select it, then tap the blue tag.")
                    .font(.caption2)
                    .padding(.top)
                
                // Display current prompt details from store for verification
                if let id = Self.examplePromptID, let testPrompt = localPromptStore.getPrompt(withId: id) {
                    Text("Store version of '\(testPrompt.title)': \(testPrompt.text)")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.top)
                }
            }
            .onAppear {
                 // Ensure PromptStore is populated for previews
                 if localPromptStore.getAllPrompts().isEmpty {
                     Prompt.examplePrompts.forEach { localPromptStore.addPrompt($0) }
                     if !Prompt.examplePrompts.isEmpty && Self.examplePromptID == nil {
                         Self.examplePromptID = Prompt.examplePrompts.first!.id
                     } else if Prompt.examplePrompts.isEmpty && Self.examplePromptID == nil {
                         let defaultExample = Prompt(title: "Example", text: "This is an example prompt.", category: "General", isUserDefined: true)
                         localPromptStore.addPrompt(defaultExample)
                         Self.examplePromptID = defaultExample.id
                     }
                 }
            }
        }
    }

    static var previews: some View {
        ScrollView {
            VStack(spacing: 30) {
                Text("Chat Input Area (Inline Edit Popover Test)")
                    .font(.largeTitle)
                    .padding(.bottom)

                VStack(alignment: .leading) {
                    Text("Interactive Input")
                        .font(.headline)
                    ChatInputAreaInteractivePreview()
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
                .previewDisplayName("Interactive Input with Inline Edit")
            }
            .padding()
            .frame(width: 480, height: 700) // Increased height for preview content
        }
        .background(Color(NSColor.windowBackgroundColor))
        .environmentObject(localPromptStore)
    }
}
