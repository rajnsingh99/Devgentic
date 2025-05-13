// ChatInputAreaView.swift
// Views/ChatInputAreaView.swift
import SwiftUI
import os
import Combine
import AppKit

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
    @State private var tappedFileItemForPopover: FileSystemItem? = nil


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
            mainInputArea
        }
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
                onFileTagTapped: { fileURL in
                    logger.info("File tag tapped: \(fileURL.path)")
                    if let existingFileItem = filteredFiles.first(where: { $0.url == fileURL }) {
                        self.tappedFileItemForPopover = existingFileItem
                    } else {
                        self.tappedFileItemForPopover = FileSystemItem(id: fileURL, name: fileURL.lastPathComponent, url: fileURL, isDirectory: false)
                    }
                },
                attributedTextInsertion: $attributedTextInsertionRequest,
                textViewRef: { nsTextViewInstance in
                    self.editorTextView = nsTextViewInstance
                }
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)
            // MODIFICATION: Removed .foregroundColor() modifier. Color is now managed within CustomTextEditor.swift
            .popover(item: $tappedPromptDetail) { promptToShow in
                PromptTagBriefView(
                    prompt: promptToShow,
                    onSave: { updatedPrompt in
                        promptStore.updatePrompt(updatedPrompt)
                        self.tappedPromptDetail = updatedPrompt
                        DispatchQueue.main.async { self.tappedPromptDetail = nil }
                    },
                    onClose: { self.tappedPromptDetail = nil }
                )
            }
            .popover(item: $tappedFileItemForPopover) { fileItem in
                FileTagPopoverView(fileItem: fileItem) {
                    self.tappedFileItemForPopover = nil
                }
            }

            if userInput.isEmpty && !isInputFocused.wrappedValue {
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
        switch mainViewModel.voiceInputState {
        case .recording:
            return "Listening..."
        case .processing:
            return "Processing audio..."
        case .error(let message):
            return "Voice error: \(message.prefix(30))..."
        default:
            return "Ask Devgentic..."
        }
    }


    private var toolbarArea: some View {
        HStack(spacing: 12) {
            Button { logger.info("Plus icon tapped") } label: { Image(systemName: "plus").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(.secondary) }.buttonStyle(PlainButtonStyle()).disabled(isSending || showSettings).help("Attach files (Not Implemented)")
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
                guard let attributedText = editorTextView?.attributedString(), !attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    logger.warning("Send button: Attributed text is nil or empty. NSTextView instance: \(editorTextView != nil)")
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
                        Circle().fill( (editorTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || showSettings ? Color.gray.opacity(0.3) : Color(NSColor.controlAccentColor))
                        Image(systemName: "arrow.up")
                            .resizable().scaledToFit().fontWeight(.semibold)
                            .frame(width: sendButtonSize * 0.5, height: sendButtonSize * 0.5)
                            .foregroundColor(Color.white)
                    }
                    .frame(width: sendButtonSize, height: sendButtonSize)
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled((editorTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || isSending || showSettings)
            .keyboardShortcut(.return, modifiers: .shift)
            .help("Send Message (Shift+Return to send, Alt+Return for newline)")
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
    }

    private var micButtonImage: Image {
        switch mainViewModel.voiceInputState {
        case .recording:
            return Image(systemName: "stop.circle.fill")
        case .processing:
            return Image(systemName: "hourglass.circle")
        case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error:
            return Image(systemName: "mic.slash.fill")
        case .requestingPermissions:
             return Image(systemName: "mic.badge.plus")
        case .available:
            return Image(systemName: "mic.fill")
        default:
            return Image(systemName: "mic.fill")
        }
    }

    private var micButtonColor: Color {
        switch mainViewModel.voiceInputState {
        case .recording:
            return .red
        case .processing:
            return .orange
        case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error:
            return .red.opacity(0.7)
        case .requestingPermissions:
            return .orange
        case .available:
            return .secondary
        default:
            return .secondary
        }
    }
    
    private var micButtonHelpText: String {
        switch mainViewModel.voiceInputState {
        case .idle, .available:
            return "Start Voice Input"
        case .recording:
            return "Stop Voice Input"
        case .processing:
            return "Processing Voice Input..."
        case .requestingPermissions:
            return "Requesting Voice Permissions..."
        case .permissionsDeniedMic:
            return "Microphone permission denied. Check System Settings."
        case .permissionsDeniedSpeech:
            return "Speech recognition permission denied. Check System Settings."
        case .speechRecognitionUnavailable:
            return "Speech recognition is currently unavailable."
        case .error(let specificError):
            return "Voice input error: \(specificError.prefix(30))..."
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
        logger.debug("Performed file filtering for query '\(query)', found \(self.filteredFiles.count) files.")
    }

    private func handleFileSelection(_ selectedFile: FileSystemItem) {
        logger.info("File selected for mention: \(selectedFile.name)")
        guard let rangeToReplace = activeFileMentionTriggerRange else {
            logger.error("Cannot insert file mention tag: activeFileMentionTriggerRange is nil.")
            let currentText = userInput
            let separator = currentText.isEmpty || currentText.last == " " ? "" : " "
            userInput += "\(separator)@\(selectedFile.name) "
            clearFileSuggestionStates()
            return
        }
        let tagText = "@\(selectedFile.name)"
        
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor(calibratedRed: 0.1, green: 0.4, blue: 0.2, alpha: 1.0),
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
            .devgenticFileURL: selectedFile.url,
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
        clearFileSuggestionStates()
        DispatchQueue.main.async { self.isInputFocused.wrappedValue = true }
    }

    private func clearFileSuggestionStates() {
        self.showFileSuggestions = false
        self.activeFileMentionTriggerRange = nil
        self.fileSuggestionQuery = ""
        if !filteredFiles.isEmpty { self.filteredFiles = [] }
    }
}

// MARK: - Preview Provider
struct ChatInputAreaView_Previews_Phase6_Styling: PreviewProvider {
    static var localPromptStore = PromptStore.shared
    @StateObject static var previewExplorerViewModel = ExplorerViewModel()

    static func setupPreviewExplorer() {
    }

    struct ChatInputAreaInteractivePreview: View {
        @StateObject var mainViewModelForPreview: MainApplicationViewModel
        private var configureViewModel: (MainApplicationViewModel) -> Void
        
        @FocusState private var isInputFocusedPreview: Bool

        init(configure: @escaping (MainApplicationViewModel) -> Void = { _ in }) {
            _mainViewModelForPreview = StateObject(wrappedValue: MainApplicationViewModel())
            self.configureViewModel = configure
            
            if Prompt.examplePrompts.isEmpty {
                let defaultExample = Prompt(title: "Example", text: "This is an example prompt.", category: "General", isUserDefined: true)
                ChatInputAreaView_Previews_Phase6_Styling.localPromptStore.addPrompt(defaultExample)
            } else {
                Prompt.examplePrompts.forEach { ChatInputAreaView_Previews_Phase6_Styling.localPromptStore.addPrompt($0) }
            }
        }

        var body: some View {
            VStack(alignment: .leading) {
                Text("Try # for prompts. For @ files, Explorer needs setup. Mic button reflects voice state.")
                     .font(.caption).foregroundColor(.gray).padding(.bottom, 5)
                ChatInputAreaView(
                    userInput: $mainViewModelForPreview.userInput,
                    showContextArea: $mainViewModelForPreview.showContextArea,
                    activeContextFilePath: $mainViewModelForPreview.activeContextFilePath,
                    isSending: mainViewModelForPreview.isSending,
                    showSettings: mainViewModelForPreview.showSettings,
                    isInputFocused: $isInputFocusedPreview,
                    onSendMessage: { attrString in
                        print("Preview: Send Tapped. Attributed input: \(attrString.string.prefix(50))")
                        mainViewModelForPreview.sendMessage(attributedString: attrString)
                    },
                    onToggleContext: {
                        print("Preview: Toggle Context Tapped")
                        mainViewModelForPreview.toggleContextArea()
                    }
                )
                .environmentObject(ChatInputAreaView_Previews_Phase6_Styling.localPromptStore)
                .environmentObject(ChatInputAreaView_Previews_Phase6_Styling.previewExplorerViewModel)
                .environmentObject(mainViewModelForPreview)
            }
            .onAppear {
                configureViewModel(mainViewModelForPreview)
            }
        }
    }

    static var previews: some View {
        setupPreviewExplorer()
        return ScrollView {
            VStack(spacing: 30) {
                Text("Chat Input Area (With Voice UI)")
                    .font(.largeTitle).padding(.bottom)
                
                ChatInputAreaInteractivePreview()
                    .padding().background(Color.gray.opacity(0.1)).cornerRadius(10)
                
                ChatInputAreaInteractivePreview(configure: { vm in
                    vm.voiceInputState = .recording
                })
                .previewDisplayName("Voice Recording State")
                .padding().background(Color.gray.opacity(0.1)).cornerRadius(10)

                ChatInputAreaInteractivePreview(configure: { vm in
                    vm.voiceInputState = .error("Mic not found")
                })
                .previewDisplayName("Voice Error State")
                .padding().background(Color.gray.opacity(0.1)).cornerRadius(10)
                
                ChatInputAreaInteractivePreview()
                    .padding().background(Color.black.opacity(0.8)).cornerRadius(10)
                    .preferredColorScheme(.dark)
                    .previewDisplayName("Dark Scheme Test")

            }
            .padding().frame(width: 480, height: 1200)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .environmentObject(localPromptStore)
        .environmentObject(previewExplorerViewModel)
    }
}
