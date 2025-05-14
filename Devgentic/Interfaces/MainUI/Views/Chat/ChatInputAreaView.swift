// ChatInputAreaView.swift
// Views/ChatInputAreaView.swift
import SwiftUI
import os
import Combine
import AppKit // Ensure AppKit is imported for NSOpenPanel

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
    let onSendMessage: (NSAttributedString) -> Void
    let onToggleContext: () -> Void

    // --- Environment Objects ---
    @EnvironmentObject var explorerViewModel: ExplorerViewModel
    @EnvironmentObject var mainViewModel: MainApplicationViewModel

    // --- State variables for Prompt Suggestions ---
    @State private var showPromptSuggestions: Bool = false
    @State private var suggestionQuery: String = ""
    @State private var filteredPrompts: [Prompt] = []
    @State private var activePromptTriggerRange: NSRange? = nil
    
    // --- State variables for File Suggestions ---
    @State private var showFileSuggestions: Bool = false
    @State private var fileSuggestionQuery: String = ""
    @State private var filteredFiles: [FileSystemItem] = []
    @State private var activeFileMentionTriggerRange: NSRange? = nil

    @State private var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    
    // --- State for Tapped Tags & Popovers ---
    @State private var tappedPromptDetail: Prompt? = nil
    // REMOVED: @State private var tappedFileItemForPopover: FileSystemItem? = nil
    // This was used for the popover on inline @-file-tags, which are no longer created.


    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil

    private let promptStore = PromptStore.shared
    
    private let iconSize: CGFloat = 18
    private let sendButtonSize: CGFloat = 26
    private let cornerRadiusValue: CGFloat = 12
    private let textEditorMinHeight: CGFloat = 24
    private let textEditorMaxHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            promptSuggestionsArea
            fileSuggestionsArea
            
            if !mainViewModel.attachedFiles.isEmpty {
                AttachedFilesDisplayView(
                    attachedFiles: mainViewModel.attachedFiles,
                    onRemoveFile: { fileItemToRemove in
                        mainViewModel.removeAttachedFile(fileItem: fileItemToRemove)
                        logger.info("Removed attached file via pill: \(fileItemToRemove.name)")
                    }
                )
                .padding(.horizontal, 5)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            mainInputArea
        }
        .animation(.spring(), value: mainViewModel.attachedFiles.count)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: suggestionQuery) { performPromptFiltering(query: $1) }
        .onChange(of: showPromptSuggestions) { show in
            if show { performPromptFiltering(query: suggestionQuery) }
            else if !filteredPrompts.isEmpty { filteredPrompts = [] }
        }
        .onChange(of: fileSuggestionQuery) { performFileFiltering(query: $1) }
        .onChange(of: showFileSuggestions) { show in
            if show { performFileFiltering(query: fileSuggestionQuery) }
            else if !filteredFiles.isEmpty { filteredFiles = [] }
        }
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
            .padding(.bottom, 4)
            .padding(.horizontal, 5)
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
            .padding(.bottom, 4)
            .padding(.horizontal, 5)
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
                onCommit: { attributedString in
                    logger.debug("CustomTextEditor onCommit triggered")
                    self.onSendMessage(attributedString)
                },
                minHeight: textEditorMinHeight,
                maxHeight: textEditorMaxHeight,
                showPromptSuggestions: $showPromptSuggestions,
                suggestionQuery: $suggestionQuery,
                activePromptTriggerRange: $activePromptTriggerRange,
                onPromptTagTapped: { handlePromptTagTap($0) },
                showFileSuggestions: $showFileSuggestions,
                fileSuggestionQuery: $fileSuggestionQuery,
                activeFileMentionTriggerRange: $activeFileMentionTriggerRange,
                // REMOVED: onFileTagTapped parameter, as it's no longer part of CustomTextEditor
                attributedTextInsertion: $attributedTextInsertionRequest,
                textViewRef: { nsTextViewInstance in
                    self.editorTextView = nsTextViewInstance
                }
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)
            .popover(item: $tappedPromptDetail) { promptToShow in // Popover for #prompt tags
                PromptTagBriefView(
                    prompt: promptToShow,
                    onSave: { updatedPrompt in
                        promptStore.updatePrompt(updatedPrompt)
                        self.tappedPromptDetail = updatedPrompt // Update for potential re-display
                        DispatchQueue.main.async { self.tappedPromptDetail = nil } // Dismiss
                    },
                    onClose: { self.tappedPromptDetail = nil }
                )
            }
            // REMOVED: .popover(item: $tappedFileItemForPopover)
            // This popover was for inline @-file-tags, which are no longer created.
            // If a popover is desired for the new file pills, it would be attached to AttachedFilePillView or its container.

            if userInput.isEmpty && !isInputFocused.wrappedValue && mainViewModel.attachedFiles.isEmpty {
                Text(placeholderText)
                    .font(Font.system(size: NSFont.systemFontSize))
                    .foregroundColor(Color(NSColor.placeholderTextColor))
                    .padding(.leading, 5)
                    .padding(.top, 3)
                    .allowsHitTesting(false)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .focused(isInputFocused)
        .disabled(isSending || showSettings || mainViewModel.voiceInputState == .processing)
    }
    
    private var placeholderText: String {
        if !mainViewModel.attachedFiles.isEmpty {
            return "Add a message or ask about the files..."
        }
        switch mainViewModel.voiceInputState {
        case .recording: return "Listening..."
        case .processing: return "Processing audio..."
        case .error(let message): return "Voice error: \(message.prefix(30))..."
        default: return "Ask Devgentic..."
        }
    }

    private var toolbarArea: some View {
        HStack(spacing: 12) {
            Button(action: openFilePicker) {
                Image(systemName: "plus")
                    .resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSending || showSettings || mainViewModel.voiceInputState == .processing)
            .help("Attach files")

            Button { logger.info("Internet Search (globe) icon tapped - No functionality") } label: { Image(systemName: "globe").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(.secondary) }.buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings).help("Web Search (Not Implemented)")
            Button(action: onToggleContext) { Image(systemName: "paperclip").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(showContextArea ? Color(NSColor.controlAccentColor) : .secondary) }.buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings).help(showContextArea ? "Hide Context Area" : "Show Context Area")
            
            Spacer()
            
            Button {
                logger.info("Mic icon tapped (ChatInputAreaView). Current voice state from its VM: \(String(describing: mainViewModel.voiceInputState))")
                mainViewModel.toggleVoiceInput()
            } label: {
                micButtonImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundColor(micButtonColor)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSending || showSettings || mainViewModel.voiceInputState == .requestingPermissions || mainViewModel.voiceInputState == .processing)
            .help(micButtonHelpText)

            Button(action: {
                logger.debug("Send button tapped.")
                guard let attributedText = editorTextView?.attributedString(),
                      (!attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty) else {
                    logger.warning("Send button: Attributed text is nil or empty, and no files attached. NSTextView instance: \(editorTextView != nil)")
                    if editorTextView == nil && !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        logger.warning("Send button: editorTextView is nil, but userInput has text. Sending plain text as fallback (no file processing).")
                        onSendMessage(NSAttributedString(string: userInput))
                    }
                    return
                }
                onSendMessage(attributedText)
            }) {
                if isSending {
                    ProgressView().controlSize(.small).frame(width: sendButtonSize, height: sendButtonSize)
                } else {
                    ZStack {
                        let canSend = !(editorTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !mainViewModel.attachedFiles.isEmpty
                        Circle().fill( (canSend && !showSettings) ? Color(NSColor.controlAccentColor) : Color.gray.opacity(0.3))
                        Image(systemName: "arrow.up")
                            .resizable().scaledToFit().fontWeight(.semibold)
                            .frame(width: sendButtonSize * 0.5, height: sendButtonSize * 0.5)
                            .foregroundColor(Color.white)
                    }
                    .frame(width: sendButtonSize, height: sendButtonSize)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled( !(!(editorTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !mainViewModel.attachedFiles.isEmpty) || isSending || showSettings)
            .keyboardShortcut(.return, modifiers: .shift)
            .help("Send Message (Shift+Return to send, Alt+Return for newline)")
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
    }

    // --- Helper functions (openFilePicker, processSelectedURLs, mic button logic, prompt/file suggestion logic) ---
    
    private func openFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = "Attach Files or Folders"
        
        if #available(macOS 11.0, *) {
            openPanel.begin { response in
                if response == .OK {
                    processSelectedURLs(openPanel.urls)
                }
            }
        } else {
            if openPanel.runModal() == .OK {
                processSelectedURLs(openPanel.urls)
            }
        }
    }

    private func processSelectedURLs(_ urls: [URL]) {
        var newItems: [FileSystemItem] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                let itemName = url.lastPathComponent
                let newItem = FileSystemItem(id: url, name: itemName, url: url, isDirectory: isDirectory.boolValue)
                newItems.append(newItem)
                logger.info("Prepared to attach: \(itemName), isDir: \(isDirectory.boolValue)")
            } else {
                logger.warning("Selected URL does not exist or is not accessible: \(url.path)")
            }
        }
        
        if !newItems.isEmpty {
            mainViewModel.addAttachedFiles(fileItems: newItems)
        }
    }

    private var micButtonImage: Image {
        switch mainViewModel.voiceInputState {
        case .recording: return Image(systemName: "stop.circle.fill")
        case .processing: return Image(systemName: "hourglass.circle")
        case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error: return Image(systemName: "mic.slash.fill")
        case .requestingPermissions: return Image(systemName: "mic.badge.plus")
        case .available: return Image(systemName: "mic.fill")
        default: return Image(systemName: "mic.fill")
        }
    }

    private var micButtonColor: Color {
        switch mainViewModel.voiceInputState {
        case .recording: return .red
        case .processing: return .orange
        case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error: return .red.opacity(0.7)
        case .requestingPermissions: return .orange
        case .available: return .secondary
        default: return .secondary
        }
    }
    
    private var micButtonHelpText: String {
        switch mainViewModel.voiceInputState {
        case .idle, .available: return "Start Voice Input"
        case .recording: return "Stop Voice Input"
        case .processing: return "Processing Voice Input..."
        case .requestingPermissions: return "Requesting Voice Permissions..."
        case .permissionsDeniedMic: return "Microphone permission denied. Check System Settings."
        case .permissionsDeniedSpeech: return "Speech recognition permission denied. Check System Settings."
        case .speechRecognitionUnavailable: return "Speech recognition is currently unavailable."
        case .error(let specificError): return "Voice input error: \(specificError.prefix(30))..."
        }
    }

    private func performPromptFiltering(query: String) {
        guard showPromptSuggestions else {
            if !filteredPrompts.isEmpty { self.filteredPrompts = [] }
            return
        }
        let allPrompts = promptStore.getAllPrompts()
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
    
    private func handlePromptSelection(_ selectedPrompt: Prompt) {
        logger.info("Prompt selected: \(selectedPrompt.title)")
        guard let rangeToReplace = activePromptTriggerRange else {
            logger.error("Cannot insert prompt tag: activePromptTriggerRange is nil.")
            let currentText = userInput
            let separator = currentText.isEmpty || currentText.last == " " ? "" : " "
            userInput += "\(separator)#\(selectedPrompt.title) "
            clearPromptSuggestionStates()
            return
        }
        let tagText = "#\(selectedPrompt.title)"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.systemBlue,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            NSAttributedString.Key.promptID: selectedPrompt.id
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
        clearPromptSuggestionStates()
        DispatchQueue.main.async { self.isInputFocused.wrappedValue = true }
    }

    private func handlePromptTagTap(_ promptID: UUID) {
        logger.debug("ChatInputAreaView: Received tap on promptID: \(promptID.uuidString)")
        if let prompt = promptStore.getPrompt(withId: promptID) {
            self.tappedPromptDetail = prompt
        } else {
            logger.error("ChatInputAreaView: Tapped prompt with ID \(promptID.uuidString) not found in store.")
            self.tappedPromptDetail = nil
        }
    }
    
    private func clearPromptSuggestionStates() {
        self.showPromptSuggestions = false
        self.activePromptTriggerRange = nil
        self.suggestionQuery = ""
    }

    private func performFileFiltering(query: String) {
        guard showFileSuggestions else {
            if !filteredFiles.isEmpty { self.filteredFiles = [] }
            return
        }
        let files = explorerViewModel.suggestableFiles(query: query)
        self.filteredFiles = Array(files.prefix(10))
        logger.debug("Performed file filtering for @-mention query '\(query)', found \(self.filteredFiles.count) files.")
    }

    private func handleFileSelection(_ selectedFile: FileSystemItem) {
        logger.info("File selected from @-suggestion: \(selectedFile.name). Adding as pill.")
        mainViewModel.addAttachedFile(fileItem: selectedFile)

        if let rangeToReplace = activeFileMentionTriggerRange {
            logger.debug("Requesting deletion of @-query text in range: \(rangeToReplace)")
            self.attributedTextInsertionRequest = .init(
                range: rangeToReplace,
                attributedString: NSAttributedString(string: "")
            )
        } else {
            logger.warning("activeFileMentionTriggerRange was nil when handling file selection. @-query text may not be deleted.")
        }
        
        clearFileSuggestionStates()
        
        DispatchQueue.main.async {
            self.isInputFocused.wrappedValue = true
        }
    }

    private func clearFileSuggestionStates() {
        self.showFileSuggestions = false
        self.activeFileMentionTriggerRange = nil
        self.fileSuggestionQuery = ""
        if !filteredFiles.isEmpty { self.filteredFiles = [] }
    }
}

// MARK: - Preview Provider
struct ChatInputAreaView_Previews_Refactor_AtMention_P2_Cleanup: PreviewProvider { // Renamed
    static var localPromptStore = PromptStore.shared
    @StateObject static var previewExplorerViewModel = ExplorerViewModel()
    
    static func createPreviewMainViewModel(withAttachedFiles files: [FileSystemItem] = []) -> MainApplicationViewModel {
        let vm = MainApplicationViewModel()
        vm.attachedFiles = files
        return vm
    }
    
    static func createDummyFile(name: String, ext: String, isDir: Bool = false) -> FileSystemItem {
        let tempDir = FileManager.default.temporaryDirectory
        let dummyURL = tempDir.appendingPathComponent(name).appendingPathExtension(ext)
        if !isDir && !FileManager.default.fileExists(atPath: dummyURL.path) {
            try? "dummy content".write(to: dummyURL, atomically: true, encoding: .utf8)
        }
        return FileSystemItem(id: dummyURL, name: "\(name).\(ext)", url: dummyURL, isDirectory: isDir)
    }

    static func setupPreviewExplorer() { /* ... */ }

    struct ChatInputAreaInteractivePreview: View {
        @StateObject var mainViewModelForPreview: MainApplicationViewModel
        @FocusState private var isInputFocusedPreview: Bool
        @State private var previewUserInput: String = ""

        init(configure: @escaping (MainApplicationViewModel) -> Void = { _ in }, attachedFiles: [FileSystemItem] = [], initialUserInput: String = "") {
            let vm = MainApplicationViewModel()
            vm.attachedFiles = attachedFiles
            _mainViewModelForPreview = StateObject(wrappedValue: vm)
            _previewUserInput = State(initialValue: initialUserInput)
            configure(vm)
            
            // CORRECTED: Added isUserDefined parameter
            if PromptStore.shared.getAllPrompts().isEmpty {
                 PromptStore.shared.addPrompt(Prompt(title: "ExamplePrompt", text: "Example text", category: "General", isUserDefined: true))
            }
        }

        var body: some View {
            VStack(alignment: .leading) {
                Text("Type '@' for file suggestions. Selecting a file adds it as a pill.")
                     .font(.caption).foregroundColor(.gray).padding(.bottom, 5)
                ChatInputAreaView(
                    userInput: $previewUserInput,
                    showContextArea: .constant(false),
                    activeContextFilePath: .constant(nil),
                    isSending: mainViewModelForPreview.isSending,
                    showSettings: mainViewModelForPreview.showSettings,
                    isInputFocused: $isInputFocusedPreview,
                    onSendMessage: { attrString in
                        print("Preview: Send Tapped. Input: \(attrString.string.prefix(50))")
                        print("Preview: Attached files: \(mainViewModelForPreview.attachedFiles.map { $0.name })")
                        mainViewModelForPreview.isSending = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // Shorter delay
                            mainViewModelForPreview.isSending = false
                            previewUserInput = ""
                            mainViewModelForPreview.attachedFiles.removeAll()
                        }
                    },
                    onToggleContext: {
                        print("Preview: Toggle Context Tapped")
                    }
                )
                .environmentObject(mainViewModelForPreview)
            }
        }
    }

    static var previews: some View {
        setupPreviewExplorer()
        let sampleAttachedFiles = [
            createDummyFile(name: "AIConnect", ext: "swift"),
            createDummyFile(name: "DesignDoc", ext: "pdf")
        ]
        
        return ScrollView {
            VStack(spacing: 30) {
                Text("Chat Input Area (Refactored @-Mention)")
                    .font(.largeTitle).padding(.bottom)
                
                ChatInputAreaInteractivePreview(initialUserInput: "@Pre")
                    .padding().background(Color(NSColor.controlBackgroundColor).opacity(0.3)).cornerRadius(10)
                    .previewDisplayName("Default State (Type @Pre)")

                ChatInputAreaInteractivePreview(attachedFiles: sampleAttachedFiles, initialUserInput: "Message with files ")
                    .padding().background(Color(NSColor.controlBackgroundColor).opacity(0.3)).cornerRadius(10)
                    .previewDisplayName("With Initial Attached Files")
                
                ChatInputAreaInteractivePreview(initialUserInput: "@")
                    .padding().background(Color(NSColor.controlBackgroundColor).opacity(0.8)).cornerRadius(10)
                    .preferredColorScheme(.dark)
                    .previewDisplayName("Dark Scheme (Type @)")

            }
            .padding().frame(width: 480, height: 1200)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .environmentObject(localPromptStore)
        .environmentObject(previewExplorerViewModel)
    }
}
