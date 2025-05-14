// ChatInputAreaView.swift
// Views/ChatInputAreaView.swift
import SwiftUI
import os
import Combine
import AppKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatInputAreaSyncFix")

struct ChatInputAreaView: View {
    @Binding var userInput: String // This is the source of truth for text content
    @Binding var showContextArea: Bool
    @Binding var activeContextFilePath: String?
    let isSending: Bool
    let showSettings: Bool
    var isInputFocused: FocusState<Bool>.Binding

    let onSendMessage: (NSAttributedString) -> Void
    let onToggleContext: () -> Void

    @EnvironmentObject var explorerViewModel: ExplorerViewModel
    @EnvironmentObject var mainViewModel: MainApplicationViewModel

    @State private var showPromptSuggestions: Bool = false
    @State private var suggestionQuery: String = ""
    @State private var filteredPrompts: [Prompt] = []
    @State private var activePromptTriggerRange: NSRange? = nil // Managed by CustomTextEditor's Coordinator
    
    @State private var showFileSuggestions: Bool = false
    @State private var fileSuggestionQuery: String = ""
    @State private var filteredFiles: [FileSystemItem] = []
    @State private var activeFileMentionTriggerRange: NSRange? = nil // Managed by CustomTextEditor's Coordinator

    // This is how ChatInputAreaView tells CustomTextEditor to insert something
    @State private var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    
    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil

    private let promptStore = PromptStore.shared
    
    private let iconSize: CGFloat = 18
    private let sendButtonSize: CGFloat = 26
    private let cornerRadiusValue: CGFloat = 12
    private let textEditorMinHeight: CGFloat = 24
    private let textEditorMaxHeight: CGFloat = 200

    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            promptSuggestionsArea
            fileSuggestionsArea
            
            if !mainViewModel.attachedFiles.isEmpty {
                AttachedFilesDisplayView(
                    attachedFiles: mainViewModel.attachedFiles,
                    onRemoveFile: { fileItemToRemove in
                        mainViewModel.removeAttachedFile(fileItem: fileItemToRemove)
                    }
                )
                .padding(.horizontal, 5).padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            mainInputArea
        }
        .animation(.spring(), value: mainViewModel.attachedFiles.count)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: suggestionQuery) { newValue in performPromptFiltering(query: newValue) } // Use newValue
        .onChange(of: showPromptSuggestions) { showState in // Use new name
            if showState { performPromptFiltering(query: suggestionQuery) }
            else if !filteredPrompts.isEmpty { filteredPrompts = [] }
        }
        .onChange(of: fileSuggestionQuery) { newValue in performFileFiltering(query: newValue) } // Use newValue
        .onChange(of: showFileSuggestions) { showState in // Use new name
            if showState { performFileFiltering(query: fileSuggestionQuery) }
            else if !filteredFiles.isEmpty { filteredFiles = [] }
        }
        // When userInput changes externally (e.g. ViewModel clears it),
        // CustomTextEditor's updateNSView will handle updating the NSTextView.
    }

    @ViewBuilder private var promptSuggestionsArea: some View {
        if showPromptSuggestions {
            PromptSuggestionView(
                prompts: filteredPrompts,
                suggestionQuery: suggestionQuery,
                onSelectPrompt: { selectedPrompt in
                    handlePromptSelection(selectedPrompt)
                }
            )
            .padding(.bottom, 4).padding(.horizontal, 5)
        }
    }

    @ViewBuilder private var fileSuggestionsArea: some View {
        if showFileSuggestions {
            FileSuggestionView(
                files: filteredFiles,
                suggestionQuery: fileSuggestionQuery,
                onSelectFile: { selectedFileItem in
                    handleFileSelection(selectedFileItem)
                }
            )
            .padding(.bottom, 4).padding(.horizontal, 5)
        }
    }

    private var mainInputArea: some View {
        VStack(spacing: 3) {
            editorAndPlaceholderArea
            toolbarArea
        }
        .background(VisualEffectBlur(material: .hudWindow))
        .cornerRadius(cornerRadiusValue)
        .overlay( RoundedRectangle(cornerRadius: cornerRadiusValue).stroke(Color.gray.opacity(0.4), lineWidth: 1) )
    }

    private var editorAndPlaceholderArea: some View {
        ZStack(alignment: .topLeading) {
            CustomTextEditor(
                text: $userInput, // Bound to ViewModel's userInput via MainApplicationView
                onCommit: { attributedString in
                    // This `userInput` here is the @Binding, which should reflect CustomTextEditor's content.
                    // However, always prefer to get the most current attributedString directly from the editor for sending.
                    logger.debug("onCommit from CustomTextEditor. Text to send: \"\(attributedString.string.prefix(50))\"")
                    self.onSendMessage(attributedString)
                    // After onSendMessage, the ViewModel is expected to clear its `userInput` string.
                    // This change to `userInput` will flow back to CustomTextEditor via its binding
                    // and `updateNSView` will clear the NSTextView.
                },
                minHeight: textEditorMinHeight,
                maxHeight: textEditorMaxHeight,
                showPromptSuggestions: $showPromptSuggestions, // Controls visibility of suggestion UI
                suggestionQuery: $suggestionQuery,             // Text after '#' or '@'
                activePromptTriggerRange: $activePromptTriggerRange, // Range of '#query' in editor
                showFileSuggestions: $showFileSuggestions,
                fileSuggestionQuery: $fileSuggestionQuery,
                activeFileMentionTriggerRange: $activeFileMentionTriggerRange,
                attributedTextInsertion: $attributedTextInsertionRequest, // Action for insertions
                textViewRef: { nsTextViewInstance in
                    self.editorTextView = nsTextViewInstance
                }
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)

            if userInput.isEmpty && !isInputFocused.wrappedValue && mainViewModel.attachedFiles.isEmpty {
                Text(placeholderText)
                    .font(Font.system(size: NSFont.systemFontSize))
                    .foregroundColor(Color(NSColor.placeholderTextColor))
                    .padding(.leading, 5).padding(.top, 3)
                    .allowsHitTesting(false)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .focused(isInputFocused)
        .disabled(isSending || showSettings || mainViewModel.voiceInputState == .processing)
    }
    
    private var placeholderText: String { /* ... same ... */
        if !mainViewModel.attachedFiles.isEmpty { return "Add a message or ask about the files..." }
        switch mainViewModel.voiceInputState {
            case .recording: return "Listening..."
            case .processing: return "Processing audio..."
            case .error(let message): return "Voice error: \(message.prefix(30))..."
            default: return "Ask Devgentic..."
        }
    }
    private var toolbarArea: some View { /* ... same ... */
        HStack(spacing: 12) {
            Button(action: openFilePicker) {
                Image(systemName: "plus").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(.secondary)
            }.buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings || mainViewModel.voiceInputState == .processing).help("Attach files")
            Button { logger.info("Internet Search (globe) icon tapped - No functionality") } label: { Image(systemName: "globe").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(.secondary) }.buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings).help("Web Search (Not Implemented)")
            Button(action: onToggleContext) { Image(systemName: "paperclip").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(showContextArea ? Color(NSColor.controlAccentColor) : .secondary) }.buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings).help(showContextArea ? "Hide Context Area" : "Show Context Area")
            Spacer()
            Button { mainViewModel.toggleVoiceInput() } label: {
                micButtonImage.resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(micButtonColor)
            }.buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings || mainViewModel.voiceInputState == .requestingPermissions || mainViewModel.voiceInputState == .processing).help(micButtonHelpText)
            Button(action: {
                guard let textView = editorTextView else {
                    logger.error("Send button: editorTextView is nil. Cannot get attributedString.");
                    if !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty {
                        onSendMessage(NSAttributedString(string: userInput, attributes: defaultTypingAttributes))
                    }
                    return
                }
                let textToSend = textView.attributedString()
                if !textToSend.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty {
                    onSendMessage(textToSend)
                }
            }) {
                if isSending { ProgressView().controlSize(.small).frame(width: sendButtonSize, height: sendButtonSize) }
                else {
                    ZStack {
                        let canSend = !(editorTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !mainViewModel.attachedFiles.isEmpty
                        Circle().fill( (canSend && !showSettings) ? Color(NSColor.controlAccentColor) : Color.gray.opacity(0.3))
                        Image(systemName: "arrow.up").resizable().scaledToFit().fontWeight(.semibold).frame(width: sendButtonSize * 0.5, height: sendButtonSize * 0.5).foregroundColor(Color.white)
                    }.frame(width: sendButtonSize, height: sendButtonSize)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled( !(!(editorTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !mainViewModel.attachedFiles.isEmpty) || isSending || showSettings)
            .keyboardShortcut(.return, modifiers: .shift)
        }
        .padding(.horizontal, 15).padding(.bottom, 10)
    }
    private func openFilePicker() { /* ... same ... */
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true; openPanel.canChooseDirectories = true; openPanel.allowsMultipleSelection = true
        openPanel.prompt = "Attach Files or Folders"
        openPanel.begin { response in if response == .OK { processSelectedURLs(openPanel.urls) } }
    }
    private func processSelectedURLs(_ urls: [URL]) { /* ... same ... */
        var newItems: [FileSystemItem] = []
        for url in urls {
            var fileIsDirectoryObjC: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &fileIsDirectoryObjC) {
                let itemName = url.lastPathComponent; let isDirectoryBool = fileIsDirectoryObjC.boolValue
                newItems.append(FileSystemItem(id: url, name: itemName, url: url, isDirectory: isDirectoryBool))
            }
        }
        if !newItems.isEmpty { mainViewModel.addAttachedFiles(fileItems: newItems) }
    }
    private var micButtonImage: Image { /* ... same ... */
        switch mainViewModel.voiceInputState {
            case .recording: return Image(systemName: "stop.circle.fill")
            case .processing: return Image(systemName: "hourglass.circle")
            case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error: return Image(systemName: "mic.slash.fill")
            case .requestingPermissions: return Image(systemName: "mic.badge.plus")
            default: return Image(systemName: "mic.fill")
        }
    }
    private var micButtonColor: Color { /* ... same ... */
        switch mainViewModel.voiceInputState {
            case .recording: return .red
            case .processing: return .orange
            case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error: return .red.opacity(0.7)
            case .requestingPermissions: return .orange
            default: return .secondary
        }
    }
    private var micButtonHelpText: String { /* ... same ... */
        switch mainViewModel.voiceInputState {
            case .idle, .available: return "Start Voice Input"
            case .recording: return "Stop Voice Input"
            case .processing: return "Processing Voice Input..."
            case .requestingPermissions: return "Requesting Voice Permissions..."
            case .permissionsDeniedMic: return "Microphone permission denied."
            case .permissionsDeniedSpeech: return "Speech recognition permission denied."
            case .speechRecognitionUnavailable: return "Speech recognition is currently unavailable."
            case .error(let specificError): return "Voice input error: \(specificError.prefix(30))..."
        }
    }

    private func performPromptFiltering(query: String) { /* ... same ... */
        let allPrompts = promptStore.getAllPrompts()
        if query.isEmpty {
            filteredPrompts = Array(allPrompts.sorted { $0.title.lowercased() < $1.title.lowercased() }.prefix(10))
        } else {
            let lowercasedQuery = query.lowercased()
            filteredPrompts = allPrompts.filter { $0.title.lowercased().contains(lowercasedQuery) }
                                      .sorted { $0.title.lowercased() < $1.title.lowercased() }.prefix(10).map{$0}
        }
    }
    
    private func handlePromptSelection(_ selectedPrompt: Prompt) {
        // This range is determined by CustomTextEditor's Coordinator based on user typing '#' and query
        guard let rangeToReplace = activePromptTriggerRange else {
            logger.error("Cannot insert prompt text: activePromptTriggerRange is nil. Current userInput: \"\(userInput)\". Appending text as fallback.")
            let separator = userInput.isEmpty || userInput.last == " " || userInput.last == "\n" ? "" : " "
            // Directly modify userInput; CustomTextEditor will pick up the change via binding.
            // This direct modification should be okay if rangeToReplace is nil, as it implies
            // the suggestion trigger mechanism didn't set the range properly.
            userInput += "\(separator)\(selectedPrompt.text) "
            clearPromptSuggestionStates() // Still clear suggestion UI
            return
        }

        let promptFullText = selectedPrompt.text
        logger.info("ChatInputAreaView: Requesting insertion of prompt '\(selectedPrompt.title)'. Text: \"\(promptFullText.prefix(50))\" to replace range: \(NSStringFromRange(rangeToReplace)) in current text: \"\(userInput.prefix(100))\" (length: \(userInput.count))")

        let attributedPromptText = NSAttributedString(string: promptFullText, attributes: defaultTypingAttributes)
        let trailingSpace = NSAttributedString(string: " ", attributes: defaultTypingAttributes)
        let finalAttributedString = NSMutableAttributedString(attributedString: attributedPromptText)
        finalAttributedString.append(trailingSpace)
        
        // Set the request for CustomTextEditor to handle the actual text replacement
        attributedTextInsertionRequest = .init(
            range: rangeToReplace,
            attributedString: finalAttributedString
        )
        // CustomTextEditor's updateNSView will perform the replacement and then update its
        // internal text. The binding $userInput will be updated from CustomTextEditor.

        clearPromptSuggestionStates() // Hide suggestion UI
        DispatchQueue.main.async { self.isInputFocused.wrappedValue = true } // Refocus editor
    }
    
    private func clearPromptSuggestionStates() {
        showPromptSuggestions = false
        // activePromptTriggerRange is managed by Coordinator, but good to nil it here if selection happens.
        // However, Coordinator should clear it upon successful processing or dismissal.
        // For safety, we can nil it here too, though it might be redundant if Coordinator is robust.
        activePromptTriggerRange = nil
        suggestionQuery = ""
        // filteredPrompts will clear via .onChange
    }

    private func performFileFiltering(query: String) { /* ... same ... */
        let files = explorerViewModel.suggestableFiles(query: query)
        self.filteredFiles = Array(files.prefix(10))
    }
    private func handleFileSelection(_ selectedFile: FileSystemItem) { /* ... same, ensure no direct userInput update ... */
        mainViewModel.addAttachedFile(fileItem: selectedFile)
        if let rangeToReplace = activeFileMentionTriggerRange {
            attributedTextInsertionRequest = .init(range: rangeToReplace, attributedString: NSAttributedString(string: ""))
        }
        clearFileSuggestionStates()
        DispatchQueue.main.async { self.isInputFocused.wrappedValue = true }
    }
    private func clearFileSuggestionStates() { /* ... same ... */
        showFileSuggestions = false
        activeFileMentionTriggerRange = nil
        fileSuggestionQuery = ""
    }
}

struct ChatInputAreaView_Previews_Refactor_AtMention_P2_Cleanup: PreviewProvider {
    static var localPromptStore = PromptStore.shared
    @StateObject static var previewExplorerViewModel = ExplorerViewModel()
    
    static func createPreviewMainViewModel(withAttachedFiles files: [FileSystemItem] = []) -> MainApplicationViewModel { /* ... */ return MainApplicationViewModel() }
    static func createDummyFile(name: String, ext: String, isDirectoryInput: Bool = false) -> FileSystemItem { /* ... */ return FileSystemItem(id:URL(fileURLWithPath: ""), name:"", url:URL(fileURLWithPath:""), isDirectory:false) }

    struct ChatInputAreaInteractivePreview: View {
        @StateObject var mainViewModelForPreview: MainApplicationViewModel
        @FocusState private var isInputFocusedPreview: Bool
        @State private var previewUserInput: String = "" // This will be bound to CustomTextEditor

        init(configure: @escaping (MainApplicationViewModel) -> Void = { _ in }, attachedFiles: [FileSystemItem] = [], initialUserInput: String = "") {
            let vm = MainApplicationViewModel()
            vm.attachedFiles = attachedFiles
            _mainViewModelForPreview = StateObject(wrappedValue: vm)
            _previewUserInput = State(initialValue: initialUserInput) // Initialize the @State
            configure(vm)
            
            if PromptStore.shared.getAllPrompts().isEmpty {
                 PromptStore.shared.addPrompt(Prompt(title: "Test Prompt", text: "This is the full test prompt text.", category: "Testing", isUserDefined: true))
                 PromptStore.shared.addPrompt(Prompt(title: "Brainstorm", text: "Brainstorm ideas for X, Y, and Z.", category: "Creativity", isUserDefined: false))
            }
        }

        var body: some View {
            VStack(alignment: .leading) {
                Text("Type '#' for prompt suggestions. Selecting inserts full text.")
                     .font(.caption).foregroundColor(.gray).padding(.bottom, 5)
                ChatInputAreaView(
                    userInput: $previewUserInput, // Pass the @State binding
                    showContextArea: .constant(false),
                    activeContextFilePath: .constant(nil),
                    isSending: mainViewModelForPreview.isSending,
                    showSettings: mainViewModelForPreview.showSettings,
                    isInputFocused: $isInputFocusedPreview,
                    onSendMessage: { attrString in
                        print("Preview: Send Tapped. Input: \(attrString.string.prefix(100))")
                        mainViewModelForPreview.isSending = true
                        // Simulate ViewModel clearing the input
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { // Slightly longer to ensure updates propagate
                             previewUserInput = "" // This change should flow to CustomTextEditor
                             mainViewModelForPreview.isSending = false
                        }
                    },
                    onToggleContext: { print("Preview: Toggle Context Tapped") }
                )
                .environmentObject(mainViewModelForPreview)
                .environmentObject(ChatInputAreaView_Previews_Refactor_AtMention_P2_Cleanup.previewExplorerViewModel)
                Text("Bound userInput in Preview: \"\(previewUserInput)\"") // Debugging display
            }
        }
    }

    static var previews: some View {
        return ScrollView {
            VStack(spacing: 30) {
                Text("Chat Input Area (Sync & Insertion Fixes)")
                    .font(.largeTitle).padding(.bottom)
                ChatInputAreaInteractivePreview(initialUserInput: "#Test") // Test with initial text
                    .padding().background(Color(NSColor.controlBackgroundColor).opacity(0.3)).cornerRadius(10)
                ChatInputAreaInteractivePreview() // Test empty initial state
                    .padding().background(Color(NSColor.controlBackgroundColor).opacity(0.3)).cornerRadius(10)

            }.padding().frame(width: 480)
        }.background(Color(NSColor.windowBackgroundColor))
    }
}
