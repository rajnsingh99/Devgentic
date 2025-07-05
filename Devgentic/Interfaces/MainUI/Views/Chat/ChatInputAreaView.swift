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

    // MARK: - State for Suggestions & Popups
    @State private var showPromptSuggestions: Bool = false
    @State private var suggestionQuery: String = ""
    @State private var filteredPrompts: [Prompt] = []
    @State private var activePromptTriggerRange: NSRange? = nil
    
    @State private var showFileSuggestions: Bool = false
    @State private var fileSuggestionQuery: String = ""
    @State private var filteredFiles: [FileSystemItem] = []
    @State private var activeFileMentionTriggerRange: NSRange? = nil
    
    @State private var showingAgentSelectorPopup: Bool = false

    @State private var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    
    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil

    private let promptStore = PromptStore.shared
    
    // MARK: - Layout Constants
    private let iconSize: CGFloat = 18
    private let dynamicButtonSize: CGFloat = 26
    private let cornerRadiusValue: CGFloat = 12
    private let textEditorMinHeight: CGFloat = 24
    private let textEditorMaxHeight: CGFloat = 200
    
    private var isInputEnabled: Bool {
        !isSending && !showSettings
    }

    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]
    }
    
    // MARK: - Dynamic UI Properties
    
    private enum ProfileType {
        case agent, local, remote, none
    }

    private var currentProfileType: ProfileType {
        switch mainViewModel.selectedBackend {
        case .agent:
            return .agent
        case .ollama:
            guard let integration = mainViewModel.llmIntegrationStore.currentIntegration else { return .none }
            switch integration.providerType {
            case .ollama:
                return .local
            case .remote:
                return .remote
            }
        }
    }

    private var profileButtonIconName: String {
        switch currentProfileType {
        case .agent: return "person.2.fill"
        case .local: return "cpu"
        case .remote: return "cloud.fill"
        case .none: return "questionmark.circle"
        }
    }

    private var profileButtonBorderColor: Color {
        switch currentProfileType {
        case .agent: return .red
        case .local: return .green
        case .remote: return .blue
        case .none: return .gray.opacity(0.5)
        }
    }
    
    private var profileButtonText: String {
        switch mainViewModel.selectedBackend {
        case .agent:
            if let agent = mainViewModel.agentStore.currentAgent {
                return agent.name
            }
        case .ollama:
            if let integration = mainViewModel.llmIntegrationStore.currentIntegration {
                return integration.displayName
            }
        }
        return "Select Profile"
    }
    
    private var hasInputText: Bool {
        !userInput.isEmpty
    }

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
                // AttachedFilesDisplayView is not defined in this file.
            }

            mainInputArea
        }
        .animation(.spring(), value: mainViewModel.attachedFiles.count)
        .animation(.easeInOut(duration: 0.15), value: currentDynamicButtonMode)
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
            // PromptSuggestionView is not defined in this file.
        }
    }

    @ViewBuilder private var fileSuggestionsArea: some View {
        if showFileSuggestions {
             // FileSuggestionView is not defined in this file.
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
        .opacity(isInputEnabled ? 1.0 : 0.6)
    }

    private var editorAndPlaceholderArea: some View {
            ZStack(alignment: .topLeading) {
                CustomTextEditor(
                text: $userInput,
                onCommit: { attributedString in
                    if isInputEnabled { self.onSendMessage(attributedString) }
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
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)
            if userInput.isEmpty && !isInputFocused.wrappedValue {
                Text(placeholderText)
                    .font(.system(size: NSFont.systemFontSize))
                    .foregroundColor(Color(NSColor.placeholderTextColor))
                    .padding(.leading, 5).padding(.top, 3)
                    .allowsHitTesting(false)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .focused(isInputFocused)
        .disabled(!isInputEnabled)
    }
    
    private var placeholderText: String {
        if mainViewModel.llmIntegrationStore.integrations.isEmpty { return "Please configure an LLM Integration to start..." }
        if !mainViewModel.attachedFiles.isEmpty { return "Add a message or ask about the files..." }
        if userInput.isEmpty {
            switch mainViewModel.voiceInputState {
                case .recording: return "Listening..."
                case .processing: return "Processing audio..."
                case .error(let message): return "Voice error: \(message.prefix(30))..."
                default: return "Type or click mic to talk..."
            }
        }
        return "Type or click mic to talk..."
    }

    private var toolbarArea: some View {
            HStack(spacing: 12) {
                Button(action: openFilePicker) {
                    Image(systemName: "plus").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach files")

                Button { logger.info("Internet Search (globe) icon tapped - No functionality") } label: {
                    Image(systemName: "globe").resizable().scaledToFit().frame(width: iconSize, height: iconSize).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Web Search (Not Implemented)")

                profilePickerButton()

                Spacer()
                
                dynamicActionButton
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 10)
            .disabled(!isInputEnabled)
        }

    @ViewBuilder
    private func profilePickerButton() -> some View {
        Button(action: { self.showingAgentSelectorPopup = true }) {
            HStack(spacing: 5) {
                Image(systemName: profileButtonIconName)
                    .font(.system(size: 12))
                    .foregroundColor(profileButtonBorderColor)
                
                Text(profileButtonText)
                    .lineLimit(1)
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.gray.opacity(0.15))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(profileButtonBorderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingAgentSelectorPopup, arrowEdge: .bottom) {
            BackendSelectorPopup(
                selectedAgentID: $mainViewModel.selectedAgentID,
                selectedIntegrationID: $mainViewModel.llmIntegrationStore.selectedIntegrationID,
                isPresented: $showingAgentSelectorPopup,
                agentStore: mainViewModel.agentStore,
                llmIntegrationStore: mainViewModel.llmIntegrationStore
            )
        }
        .help("Select an agent or model profile")
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
            case .mic, .stop:
                mainViewModel.toggleVoiceInput()
            }
        }) {
            if isSending && mode == .send {
                ProgressView().controlSize(.small)
                    .frame(width: dynamicButtonSize, height: dynamicButtonSize)
            } else {
                ZStack {
                    let canSend = mode == .send && (!userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty)
                    let isDisabledBySystem = showSettings || (mode == .send && (mainViewModel.voiceInputState == .processing || mainViewModel.voiceInputState == .recording))

                    Circle()
                        .fill(buttonBackgroundColor(for: mode, canSend: canSend, isDisabledBySystem: isDisabledBySystem))
                    
                    Image(systemName: dynamicActionButtonIconName(for: mode))
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

    private func dynamicActionButtonIconName(for mode: DynamicButtonMode) -> String {
        switch mode {
        case .send: return "arrow.up"
        case .stop: return "stop.circle.fill"
        case .mic:
            switch mainViewModel.voiceInputState {
            case .processing: return "hourglass.circle"
            case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error: return "mic.slash.fill"
            case .requestingPermissions: return "mic.badge.plus"
            default: return "mic.fill"
            }
        }
    }
    
    private func buttonIconScale(for mode: DynamicButtonMode) -> CGFloat {
        switch mode {
        case .send: return 0.5
        case .stop: return 0.65
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
            return Color.red.opacity(0.8)
        case .mic:
            return Color.clear
        }
    }
    
    private func buttonIconForegroundColor(for mode: DynamicButtonMode) -> Color {
        switch mode {
        case .send: return .white
        case .stop: return .white
        case .mic:
            switch mainViewModel.voiceInputState {
            case .recording: return .white
            case .processing: return .orange
            case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error: return .red.opacity(0.7)
            case .requestingPermissions: return .orange
            default: return .secondary
            }
        }
    }

    private func isDynamicButtonDisabled(for mode: DynamicButtonMode) -> Bool {
        switch mode {
        case .send:
            let isEmptyTextAndNoFiles = userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mainViewModel.attachedFiles.isEmpty
            return isEmptyTextAndNoFiles || isSending || showSettings || mainViewModel.voiceInputState == .recording || mainViewModel.voiceInputState == .processing
        case .stop:
            return isSending || showSettings
        case .mic:
            return isSending || showSettings || mainViewModel.voiceInputState == .requestingPermissions || mainViewModel.voiceInputState == .processing || mainViewModel.voiceInputState == .recording
        }
    }

    private func buttonHelpText(for mode: DynamicButtonMode) -> String {
        switch mode {
        case .send: return "Send message (Enter)"
        case .stop: return "Stop Voice Input"
        case .mic:
            switch mainViewModel.voiceInputState {
            case .idle, .available: return "Start Voice Input (Mic button)"
            case .processing: return "Processing Voice Input..."
            case .requestingPermissions: return "Requesting Voice Permissions..."
            case .permissionsDeniedMic: return "Microphone permission denied. Click to re-check."
            case .permissionsDeniedSpeech: return "Speech recognition permission denied. Click to re-check."
            case .speechRecognitionUnavailable: return "Speech recognition is currently unavailable. Click to re-check."
            case .error(let specificError): return "Voice input error: \(specificError.prefix(30))... Click to re-check."
            default: return "Voice Input"
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
                // Assuming FileSystemItem is defined elsewhere
            }
        }
        if !newItems.isEmpty {
            mainViewModel.addAttachedFiles(fileItems: newItems)
        }
    }
    
    private func performPromptFiltering(query: String) {
        let allPrompts = promptStore.getAllPrompts()
        if query.isEmpty {
            // Assuming Prompt is defined elsewhere
        } else {
            let lowercasedQuery = query.lowercased()
        }
    }
    
    private func handlePromptSelection(_ selectedPrompt: Prompt) {
        guard let rangeToReplace = activePromptTriggerRange else {
            logger.error("Cannot insert prompt text: activePromptTriggerRange is nil. Appending text as fallback.")
            let separator = userInput.isEmpty || userInput.last?.isWhitespace ?? true ? "" : " "
            clearPromptSuggestionStates()
            return
        }
        clearPromptSuggestionStates()
        DispatchQueue.main.async { self.isInputFocused.wrappedValue = true }
    }
    
    private func clearPromptSuggestionStates() {
        showPromptSuggestions = false
        activePromptTriggerRange = nil
        suggestionQuery = ""
    }

    private func performFileFiltering(query: String) {
        // let files = explorerViewModel.suggestableFiles(query: query)
    }

    private func handleFileSelection(_ selectedFile: FileSystemItem) {
        if let rangeToReplace = activeFileMentionTriggerRange {
            // attributedTextInsertionRequest = .init(range: rangeToReplace, attributedString: NSAttributedString(string: ""))
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
