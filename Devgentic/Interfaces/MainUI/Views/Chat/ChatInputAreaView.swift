// ChatInputAreaView.swift
// Views/ChatInputAreaView.swift
import SwiftUI
import os
import Combine
import AppKit

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatInputAreaUI_V2")

struct ChatInputAreaView: View {
    @Binding var userInput: String
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
    @State private var activePromptTriggerRange: NSRange? = nil
    
    @State private var showFileSuggestions: Bool = false
    @State private var fileSuggestionQuery: String = ""
    @State private var filteredFiles: [FileSystemItem] = []
    @State private var activeFileMentionTriggerRange: NSRange? = nil

    @State private var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    
    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil

    private let promptStore = PromptStore.shared
    
    private let iconSize: CGFloat = 18
    private let dynamicButtonSize: CGFloat = 26
    private let cornerRadiusValue: CGFloat = 12
    private let textEditorMinHeight: CGFloat = 24
    private let textEditorMaxHeight: CGFloat = 200

    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]
    }
    
    private var hasInputText: Bool {
        !userInput.isEmpty
    }

    // Determines the current mode of the dynamic button
    // Removed 'private' to make it internal and accessible to the PreviewProvider in the same file
    // Made it conform to CustomStringConvertible for Preview debugging
    enum DynamicButtonMode: CustomStringConvertible {
        case mic, stop, send

        var description: String {
            switch self {
            case .mic: return "Mic"
            case .stop: return "Stop"
            case .send: return "Send"
            }
        }
    }

    private var currentDynamicButtonMode: DynamicButtonMode {
        if mainViewModel.voiceInputState == .recording {
            return .stop
        } else if hasInputText {
            return .send
        } else {
            return .mic
        }
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
        .animation(.easeInOut(duration: 0.15), value: currentDynamicButtonMode) // Animate button transition
        .animation(.easeInOut(duration: 0.15), value: mainViewModel.voiceInputState)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: suggestionQuery) { newValue in performPromptFiltering(query: newValue) }
        .onChange(of: showPromptSuggestions) { showState in
            if showState { performPromptFiltering(query: suggestionQuery) }
            else if !filteredPrompts.isEmpty { filteredPrompts = [] }
        }
        .onChange(of: fileSuggestionQuery) { newValue in performFileFiltering(query: newValue) }
        .onChange(of: showFileSuggestions) { showState in
            if showState { performFileFiltering(query: fileSuggestionQuery) }
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
                text: $userInput,
                onCommit: { attributedString in
                    logger.debug("onCommit from CustomTextEditor (Enter pressed). Text to send: \"\(attributedString.string.prefix(50))\"")
                     if !showPromptSuggestions && !showFileSuggestions {
                        self.onSendMessage(attributedString)
                     }
                },
                minHeight: textEditorMinHeight,
                maxHeight: textEditorMaxHeight,
                showPromptSuggestions: $showPromptSuggestions,
                suggestionQuery: $suggestionQuery,
                activePromptTriggerRange: $activePromptTriggerRange,
                showFileSuggestions: $showFileSuggestions,
                fileSuggestionQuery: $fileSuggestionQuery,
                activeFileMentionTriggerRange: $activeFileMentionTriggerRange,
                attributedTextInsertion: $attributedTextInsertionRequest,
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
        // Disable editor if sending text, or if settings are shown.
        // Also disable if voice is processing AND there's text (to prevent editing during finalization of voice input that added text)
        .disabled(isSending || showSettings || (hasInputText && mainViewModel.voiceInputState == .processing) )
    }
    
    private var placeholderText: String {
        if !mainViewModel.attachedFiles.isEmpty { return "Add a message or ask about the files..." }
        if userInput.isEmpty { // Only show voice-related placeholders if input is empty
            switch mainViewModel.voiceInputState {
                case .recording: return "Listening..."
                case .processing: return "Processing audio..."
                case .error(let message): return "Voice error: \(message.prefix(30))..."
                default: return "Type or click mic to talk..." // More inviting
            }
        }
        return "Type or click mic to talk..." // Default when userInput is not empty, but mic button won't be shown
    }

    private var toolbarArea: some View {
        HStack(spacing: 12) {
            Button(action: openFilePicker) {
                Image(systemName: "plus").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSending || showSettings || mainViewModel.voiceInputState == .recording || mainViewModel.voiceInputState == .processing)
            .help("Attach files")

            Button { logger.info("Internet Search (globe) icon tapped - No functionality") } label: {
                Image(systemName: "globe").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSending || showSettings || mainViewModel.voiceInputState == .recording || mainViewModel.voiceInputState == .processing)
            .help("Web Search (Not Implemented)")

            Button(action: onToggleContext) {
                Image(systemName: "paperclip").resizable().scaledToFit().frame(width: iconSize, height: iconSize)
                    .foregroundColor(showContextArea ? Color(NSColor.controlAccentColor) : .secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isSending || showSettings || mainViewModel.voiceInputState == .recording || mainViewModel.voiceInputState == .processing)
            .help(showContextArea ? "Hide Context Area" : "Show Context Area")
            
            Spacer()
            
            dynamicActionButton
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var dynamicActionButton: some View {
        let mode = currentDynamicButtonMode
        
        Button(action: {
            switch mode {
            case .send:
                guard let textView = editorTextView else {
                    logger.error("Send button: editorTextView is nil.");
                    if !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty {
                        onSendMessage(NSAttributedString(string: userInput, attributes: defaultTypingAttributes))
                    }
                    return
                }
                let textToSend = textView.attributedString()
                if !textToSend.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty {
                    onSendMessage(textToSend)
                }
            case .mic, .stop: // Both mic and stop actions trigger toggleVoiceInput
                mainViewModel.toggleVoiceInput()
            }
        }) {
            if isSending && mode == .send { // Show progress only when sending text
                ProgressView().controlSize(.small)
                    .frame(width: dynamicButtonSize, height: dynamicButtonSize)
            } else {
                ZStack {
                    let canSend = mode == .send && (!userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty)
                    let isDisabledBySystem = showSettings || (mode == .send && (mainViewModel.voiceInputState == .processing || mainViewModel.voiceInputState == .recording))

                    Circle()
                        .fill(buttonBackgroundColor(for: mode, canSend: canSend, isDisabledBySystem: isDisabledBySystem))
                    
                    Image(systemName: buttonIconName(for: mode))
                        .resizable().scaledToFit()
                        .fontWeight(buttonIconWeight(for: mode))
                        .frame(width: dynamicButtonSize * buttonIconScale(for: mode), height: dynamicButtonSize * buttonIconScale(for: mode))
                        .foregroundColor(buttonIconForegroundColor(for: mode))
                }
                .frame(width: dynamicButtonSize, height: dynamicButtonSize)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isDynamicButtonDisabled(for: mode))
        .help(buttonHelpText(for: mode))
    }

    private func buttonIconName(for mode: DynamicButtonMode) -> String {
        switch mode {
        case .send:
            return "arrow.up"
        case .stop:
            return "stop.circle.fill"
        case .mic: // This covers .idle, .available, .error, .permissionsDenied*, .speechRecognitionUnavailable, .processing (when input is empty)
            switch mainViewModel.voiceInputState {
            // .recording is handled by .stop mode above
            case .processing: // If input is empty and processing (e.g. initial processing before text appears)
                return "hourglass.circle"
            case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error:
                return "mic.slash.fill"
            case .requestingPermissions:
                return "mic.badge.plus"
            default: // .idle, .available
                return "mic.fill"
            }
        }
    }
    
    private func buttonIconScale(for mode: DynamicButtonMode) -> CGFloat {
        switch mode {
        case .send: return 0.5
        case .stop: return 0.65 // Stop icon can be a bit larger
        case .mic: return 0.6
        }
    }

    private func buttonIconWeight(for mode: DynamicButtonMode) -> Font.Weight {
        mode == .send ? .semibold : .regular
    }

    private func buttonBackgroundColor(for mode: DynamicButtonMode, canSend: Bool, isDisabledBySystem: Bool) -> Color {
        switch mode {
        case .send:
            return (canSend && !isDisabledBySystem) ? Color(NSColor.controlAccentColor) : Color.gray.opacity(0.3)
        case .stop:
            return Color.red.opacity(0.8) // Distinct color for stop
        case .mic:
            // Mic button usually doesn't have a filled background unless active/error
            // For error states, the icon color changes. Here, keep it clear or subtle.
            return Color.clear // Or a very subtle gray if preferred: Color.gray.opacity(0.1)
        }
    }
    
    private func buttonIconForegroundColor(for mode: DynamicButtonMode) -> Color {
        switch mode {
        case .send:
            return .white
        case .stop:
            return .white
        case .mic: // Color depends on the actual voiceInputState when in mic mode
            switch mainViewModel.voiceInputState {
            case .recording: return .white // Should be covered by .stop mode, but for safety
            case .processing: return .orange // If processing and input is empty
            case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error:
                return .red.opacity(0.7)
            case .requestingPermissions:
                return .orange
            default: // .idle, .available
                return .secondary
            }
        }
    }

    private func isDynamicButtonDisabled(for mode: DynamicButtonMode) -> Bool {
        switch mode {
        case .send:
            let isEmptyTextAndNoFiles = userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mainViewModel.attachedFiles.isEmpty
            return isEmptyTextAndNoFiles || isSending || showSettings || mainViewModel.voiceInputState == .recording || mainViewModel.voiceInputState == .processing
        case .stop: // Stop button should generally always be enabled if shown
            return isSending || showSettings
        case .mic:
            // Mic button (when input is empty) is disabled if sending text (shouldn't happen), settings shown,
            // or in a voice state that isn't idle/available (like requesting permissions, or already recording/processing)
            return isSending || showSettings || mainViewModel.voiceInputState == .requestingPermissions || mainViewModel.voiceInputState == .processing || mainViewModel.voiceInputState == .recording
        }
    }

    private func buttonHelpText(for mode: DynamicButtonMode) -> String {
        switch mode {
        case .send:
            return "Send message (Enter)"
        case .stop:
            return "Stop Voice Input"
        case .mic: // Help text for when the button is in "mic mode"
            switch mainViewModel.voiceInputState {
            case .idle, .available: return "Start Voice Input (Mic button)"
            // .recording is handled by .stop mode's help text
            case .processing: return "Processing Voice Input..." // if input is empty
            case .requestingPermissions: return "Requesting Voice Permissions..."
            case .permissionsDeniedMic: return "Microphone permission denied. Click to re-check."
            case .permissionsDeniedSpeech: return "Speech recognition permission denied. Click to re-check."
            case .speechRecognitionUnavailable: return "Speech recognition is currently unavailable. Click to re-check."
            case .error(let specificError): return "Voice input error: \(specificError.prefix(30))... Click to re-check."
            default: return "Voice Input" // Generic fallback
            }
        }
    }
    
    private func openFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = "Attach Files or Folders"
        openPanel.begin { response in
            if response == .OK {
                processSelectedURLs(openPanel.urls)
            }
        }
    }

    private func processSelectedURLs(_ urls: [URL]) {
        var newItems: [FileSystemItem] = []
        for url in urls {
            var fileIsDirectoryObjC: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &fileIsDirectoryObjC) {
                let itemName = url.lastPathComponent
                let isDirectoryBool = fileIsDirectoryObjC.boolValue
                newItems.append(FileSystemItem(id: url, name: itemName, url: url, isDirectory: isDirectoryBool))
            }
        }
        if !newItems.isEmpty {
            mainViewModel.addAttachedFiles(fileItems: newItems)
        }
    }
    
    private func performPromptFiltering(query: String) {
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
        guard let rangeToReplace = activePromptTriggerRange else {
            logger.error("Cannot insert prompt text: activePromptTriggerRange is nil. Current userInput: \"\(userInput)\". Appending text as fallback.")
            let separator = userInput.isEmpty || userInput.last == " " || userInput.last == "\n" ? "" : " "
            userInput += "\(separator)\(selectedPrompt.text) "
            clearPromptSuggestionStates()
            return
        }

        let promptFullText = selectedPrompt.text
        logger.info("ChatInputAreaView: Requesting insertion of prompt '\(selectedPrompt.title)'. Text: \"\(promptFullText.prefix(50))\" to replace range: \(NSStringFromRange(rangeToReplace)) in current text: \"\(userInput.prefix(100))\" (length: \(userInput.count))")

        let attributedPromptText = NSAttributedString(string: promptFullText, attributes: defaultTypingAttributes)
        let trailingSpace = NSAttributedString(string: " ", attributes: defaultTypingAttributes)
        let finalAttributedString = NSMutableAttributedString(attributedString: attributedPromptText)
        finalAttributedString.append(trailingSpace)
        
        attributedTextInsertionRequest = .init(
            range: rangeToReplace,
            attributedString: finalAttributedString
        )
        clearPromptSuggestionStates()
        DispatchQueue.main.async { self.isInputFocused.wrappedValue = true }
    }
    
    private func clearPromptSuggestionStates() {
        showPromptSuggestions = false
        activePromptTriggerRange = nil
        suggestionQuery = ""
    }

    private func performFileFiltering(query: String) {
        let files = explorerViewModel.suggestableFiles(query: query)
        self.filteredFiles = Array(files.prefix(10))
    }

    private func handleFileSelection(_ selectedFile: FileSystemItem) {
        mainViewModel.addAttachedFile(fileItem: selectedFile)
        if let rangeToReplace = activeFileMentionTriggerRange {
            attributedTextInsertionRequest = .init(range: rangeToReplace, attributedString: NSAttributedString(string: ""))
        }
        clearFileSuggestionStates()
        DispatchQueue.main.async { self.isInputFocused.wrappedValue = true }
    }

    private func clearFileSuggestionStates() {
        showFileSuggestions = false
        activeFileMentionTriggerRange = nil
        fileSuggestionQuery = ""
    }
}

struct ChatInputAreaView_Previews_EnhancedMicStopSend: PreviewProvider {
    static var localPromptStore = PromptStore.shared
    @StateObject static var previewExplorerViewModel = ExplorerViewModel()
    
    static func createPreviewMainViewModel(configure: @escaping (MainApplicationViewModel) -> Void = { _ in }) -> MainApplicationViewModel {
         let vm = MainApplicationViewModel()
         configure(vm)
         return vm
    }

    struct ChatInputAreaInteractivePreview: View {
        @StateObject var mainViewModelForPreview: MainApplicationViewModel
        @FocusState private var isInputFocusedPreview: Bool
        @State private var previewUserInput: String

        init(initialUserInput: String = "", configureVM: @escaping (MainApplicationViewModel) -> Void = { _ in }) {
            let vm = MainApplicationViewModel()
            configureVM(vm)
            vm.userInput = initialUserInput
            
            _mainViewModelForPreview = StateObject(wrappedValue: vm)
            _previewUserInput = State(initialValue: initialUserInput)
            
            if PromptStore.shared.getAllPrompts().isEmpty {
                 PromptStore.shared.addPrompt(Prompt(title: "Test Prompt", text: "This is the full test prompt text.", category: "Testing", isUserDefined: true))
            }
        }

        var body: some View {
            VStack(alignment: .leading) {
                Text("Dynamic Button: Mic -> Stop -> Send/Mic. Enter to send, Shift+Enter for newline.")
                     .font(.caption).foregroundColor(.gray).padding(.bottom, 5)
                ChatInputAreaView(
                    userInput: $previewUserInput,
                    showContextArea: .constant(false),
                    activeContextFilePath: .constant(nil),
                    isSending: mainViewModelForPreview.isSending,
                    showSettings: mainViewModelForPreview.showSettings,
                    isInputFocused: $isInputFocusedPreview,
                    onSendMessage: { attrString in
                        print("Preview: Send Tapped/Enter. Input: \(attrString.string.prefix(100))")
                        mainViewModelForPreview.isSending = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                             previewUserInput = ""
                             mainViewModelForPreview.userInput = ""
                             mainViewModelForPreview.isSending = false
                        }
                    },
                    onToggleContext: { print("Preview: Toggle Context Tapped") }
                )
                .environmentObject(mainViewModelForPreview)
                .environmentObject(ChatInputAreaView_Previews_EnhancedMicStopSend.previewExplorerViewModel)
                
                Text("Bound userInput: \"\(previewUserInput)\"")
                Text("VM userInput: \"\(mainViewModelForPreview.userInput)\"")
                Text("VM voiceInputState: \(mainViewModelForPreview.voiceInputState.description)")
                Text("Current Button Mode: \(currentButtonModeForPreview.description)") // Corrected
                
                HStack {
                    Button("Simulate Mic Start") {
                        previewUserInput = ""
                        mainViewModelForPreview.userInput = ""
                        mainViewModelForPreview.voiceInputState = .available
                        mainViewModelForPreview.toggleVoiceInput()
                    }
                    Button("Simulate Mic Stop (by toggle)") {
                        if mainViewModelForPreview.voiceInputState == .recording {
                            mainViewModelForPreview.toggleVoiceInput()
                        }
                    }
                     Button("Simulate Text Input") { previewUserInput = "Hello" }
                     Button("Clear Text Input") { previewUserInput = "" }
                }
                HStack {
                    Button("Set VM State: Error") { mainViewModelForPreview.voiceInputState = .error("Test Error") }
                    Button("Set VM State: Available") { mainViewModelForPreview.voiceInputState = .available }
                }
            }
            .onChange(of: mainViewModelForPreview.userInput) { newValue in
                if previewUserInput != newValue {
                    previewUserInput = newValue
                }
            }
             .onChange(of: previewUserInput) { newValue in
                if mainViewModelForPreview.userInput != newValue {
                    mainViewModelForPreview.userInput = newValue
                }
            }
        }
        
        private var currentButtonModeForPreview: ChatInputAreaView.DynamicButtonMode {
            if mainViewModelForPreview.voiceInputState == .recording {
                return .stop
            } else if !previewUserInput.isEmpty {
                return .send
            } else {
                return .mic
            }
        }
    }

    static var previews: some View {
        ScrollView {
            VStack(spacing: 30) {
                Text("Chat Input Area (Enhanced Mic/Stop/Send)")
                    .font(.largeTitle).padding(.bottom)
                
                ChatInputAreaInteractivePreview(initialUserInput: "")
                    .padding().background(Color(NSColor.windowBackgroundColor).opacity(0.7)).cornerRadius(10)
                
                ChatInputAreaInteractivePreview(initialUserInput: "Some typed text")
                    .padding().background(Color(NSColor.windowBackgroundColor).opacity(0.7)).cornerRadius(10)
                
                ChatInputAreaInteractivePreview(initialUserInput: "", configureVM: { vm in
                    vm.userInput = ""
                    vm.voiceInputState = .available
                    vm.toggleVoiceInput()
                })
                .padding().background(Color(NSColor.windowBackgroundColor).opacity(0.7)).cornerRadius(10)
                .previewDisplayName("Recording State")


            }.padding().frame(width: 480)
        }
    }
}
