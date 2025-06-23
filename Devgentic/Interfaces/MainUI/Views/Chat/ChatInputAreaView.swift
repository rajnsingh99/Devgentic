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
    @EnvironmentObject var ollamaProfileStore: OllamaProfileStore

    // MARK: - State for Suggestions & Popups
    @State private var showPromptSuggestions: Bool = false
    @State private var suggestionQuery: String = ""
    @State private var filteredPrompts: [Prompt] = []
    @State private var activePromptTriggerRange: NSRange? = nil
    
    @State private var showFileSuggestions: Bool = false
    @State private var fileSuggestionQuery: String = ""
    @State private var filteredFiles: [FileSystemItem] = []
    @State private var activeFileMentionTriggerRange: NSRange? = nil
    
    // MARK: New: State to control the agent selection pop-up
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
            // Input is disabled if there's no active profile, or during other specific states.
            ollamaProfileStore.currentProfile != nil && !isSending && !showSettings
    }

    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor
        ]
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
                // AttachedFilesDisplayView is not defined in this file. Assuming it exists elsewhere.
                // To make the preview work, we might need a placeholder.
                // For now, leaving it as is.
                // AttachedFilesDisplayView(
                //     attachedFiles: mainViewModel.attachedFiles,
                //     onRemoveFile: { fileItemToRemove in
                //         mainViewModel.removeAttachedFile(fileItem: fileItemToRemove)
                //     }
                // )
                // .padding(.horizontal, 5).padding(.bottom, 8)
                // .transition(.opacity.combined(with: .move(edge: .top)))
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
            // PromptSuggestionView is not defined in this file. Assuming it exists elsewhere.
            // Text("Prompt Suggestions Area")
        }
    }

    @ViewBuilder private var fileSuggestionsArea: some View {
        if showFileSuggestions {
             // FileSuggestionView is not defined in this file. Assuming it exists elsewhere.
            // Text("File Suggestions Area")
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
        // MODIFIED: The editor is directly disabled based on the new computed property.
        .disabled(!isInputEnabled)
    }
    
    private var placeholderText: String {
        if ollamaProfileStore.currentProfile == nil { return "Please configure an Ollama Profile to start..." }
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

                agentPickerButton()

                Spacer()
                
                dynamicActionButton
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 10)
            // MODIFIED: The entire toolbar is disabled if input is not enabled.
            .disabled(!isInputEnabled)
        }

    // MARK: - Agent Picker Button (Updated to trigger pop-up)
    @ViewBuilder
    private func agentPickerButton() -> some View {
        Button(action: {
            self.showingAgentSelectorPopup = true
        }) {
            HStack(spacing: 4) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 12))
                
                if let selectedAgent = mainViewModel.agentStore.agents.first(where: { $0.id == mainViewModel.selectedAgentID }) {
                    Text(selectedAgent.name)
                } else {
                    Text("Select Agent")
                }
                
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingAgentSelectorPopup, arrowEdge: .bottom) {
            AgentSelectorPopup(
                selectedAgentID: $mainViewModel.selectedAgentID,
                agents: mainViewModel.agentStore.agents,
                ollamaProfileStore: mainViewModel.ollamaProfileStore, // Pass the store
                isPresented: $showingAgentSelectorPopup
            )
        }
        .help("Select an agent profile")
    }

    // MARK: - Dynamic Action Button (Send/Mic/Stop)
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

    // MARK: - Helper Methods (Button states, actions, etc.)
    private func buttonIconName(for mode: DynamicButtonMode) -> String {
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
                // newItems.append(FileSystemItem(id: url, name: itemName, url: url, isDirectory: isDirectoryBool))
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
            // filteredPrompts = Array(allPrompts.sorted { $0.title.lowercased() < $1.title.lowercased() }.prefix(10))
        } else {
            let lowercasedQuery = query.lowercased()
            // filteredPrompts = allPrompts.filter { $0.title.lowercased().contains(lowercasedQuery) }
            //                           .sorted { $0.title.lowercased() < $1.title.lowercased() }.prefix(10).map{$0}
        }
    }
    
    private func handlePromptSelection(_ selectedPrompt: Prompt) {
        guard let rangeToReplace = activePromptTriggerRange else {
            logger.error("Cannot insert prompt text: activePromptTriggerRange is nil. Appending text as fallback.")
            let separator = userInput.isEmpty || userInput.last?.isWhitespace ?? true ? "" : " "
            // userInput += "\(separator)\(selectedPrompt.text) "
            clearPromptSuggestionStates()
            return
        }

        // let promptFullText = selectedPrompt.text
        // let attributedString = NSAttributedString(string: "\(promptFullText) ", attributes: defaultTypingAttributes)
        
        // attributedTextInsertionRequest = .init(
        //     range: rangeToReplace,
        //     attributedString: attributedString
        // )
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
        // self.filteredFiles = Array(files.prefix(10))
    }

    private func handleFileSelection(_ selectedFile: FileSystemItem) {
        // mainViewModel.addAttachedFile(fileItem: selectedFile)
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

// MARK: - Agent Selector Popup View (Enhanced)
private struct AgentSelectorPopup: View {
    @Binding var selectedAgentID: UUID?
    let agents: [AgentProfileModel]
    let ollamaProfileStore: OllamaProfileStore // Added to get LLM names
    @Binding var isPresented: Bool

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(agents) { agent in
                        Button(action: {
                            self.selectedAgentID = agent.id
                            self.isPresented = false // Dismiss the popover
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.name)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                    // Display LLM Model Name instead of description
                                    Text(llmName(for: agent))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if agent.id == selectedAgentID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal)
                            .background(agent.id == selectedAgentID ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                    }
                }
        }
        // Removed outer vertical padding to eliminate extra space
        .frame(minWidth: 250, idealWidth: 300, maxHeight: 400)
    }
    
    // Helper function to find the LLM name from the linked profile
    private func llmName(for agent: AgentProfileModel) -> String {
        guard let profileID = agent.linkedOllamaProfileID,
              let profile = ollamaProfileStore.profiles.first(where: { $0.id == profileID }) else {
            return "Default LLM"
        }
        return profile.llmModelName
    }
}
