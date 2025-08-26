//
//  ChatInputAreaView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os
import Combine
import AppKit
import UniformTypeIdentifiers

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatInputAreaUI_V2")

struct ChatInputAreaView: View {

    @StateObject private var inputViewModel = ChatInputViewModel()

    @Binding var showContextArea: Bool
    @Binding var activeContextFilePath: String?
    
    let isSending: Bool
    let showSettings: Bool
    var isInputFocused: FocusState<Bool>.Binding
    
    @ObservedObject var backendConfiguration: BackendConfiguration
    
    let onSendMessage: (NSAttributedString, BackendRequestConfig) -> Void
    let onToggleContext: () -> Void

    @EnvironmentObject var explorerViewModel: ExplorerViewModel
    @EnvironmentObject var mainViewModel: MainApplicationViewModel

    // MARK: - State for Suggestions & Popups
    @State private var showPromptSuggestions: Bool = false
    @State private var suggestionQuery: String = ""
    @State private var filteredPrompts: [Prompt] = []
    @State private var activePromptTriggerRange: NSRange? = nil
    @State private var selectedPromptSuggestionID: Prompt.ID? = nil
    
    @State private var showFileSuggestions: Bool = false
    @State private var fileSuggestionQuery: String = ""
    @State private var filteredFiles: [FileSystemItem] = []
    @State private var activeFileMentionTriggerRange: NSRange? = nil
    @State private var selectedFileSuggestionID: FileSystemItem.ID? = nil // Keyboard focus
    @State private var fileSuggestion_multiSelectedIDs: Set<FileSystemItem.ID> = [] // Checkbox selections

    @State private var showingBackendSelectorPopup: Bool = false
    @State private var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil

    // MARK: - Hover States for Buttons
    @State private var isPlusButtonHovering: Bool = false
    @State private var isBackendPickerHovering: Bool = false
    @State private var isDynamicButtonHovering: Bool = false


    private let promptStore = PromptStore.shared

    // MARK: - Layout Constants
    private let iconSize: CGFloat = 18
    private let dynamicButtonSize: CGFloat = 28
    private let cornerRadiusValue: CGFloat = 20
    private let textEditorMinHeight: CGFloat = 30
    private let textEditorMaxHeight: CGFloat = 200

    private var isInputEnabled: Bool {
        // The stop button should be enabled even when isSending is true.
        if mainViewModel.streamingMessageID != nil {
            return true
        }
        return !isSending && !showSettings
    }

    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 2),
            .foregroundColor: NSColor.labelColor
        ]
    }

    // MARK: - Dynamic UI Properties

    private enum ProfileType {
        case agent, local, remote, none
    }

    private var currentProfileType: ProfileType {
        switch backendConfiguration.selectedBackend {
        case .agent:
            return .agent
        case .ollama:
            return .local
        case .remote:
            return .remote
        case .none:
            return .none
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
        switch backendConfiguration.selectedBackend {
        case .ollama, .remote:
            if let integrationID = backendConfiguration.selectedIntegrationID,
               let integration = mainViewModel.llmIntegrationStore.integrations.first(where: { $0.id == integrationID }) {
                return integration.displayName
            }
        case .none, .agent:
            break
        }
        return "Select Backend"
    }

    private var hasInputText: Bool {
        !inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum DynamicButtonMode: CustomStringConvertible {
        case mic, stopVoice, send, stopStreaming

        var description: String {
            switch self {
            case .mic: return "Mic"
            case .stopVoice: return "Stop Voice"
            case .send: return "Send"
            case .stopStreaming: return "Stop Streaming"
            }
        }
    }

    private var currentDynamicButtonMode: DynamicButtonMode {
        if mainViewModel.streamingMessageID != nil {
            return .stopStreaming
        }
        if inputViewModel.voiceInputState == .recording {
            return .stopVoice
        }
        if hasInputText {
            return .send
        }
        return .mic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showPromptSuggestions {
                PromptSuggestionView(
                    prompts: filteredPrompts,
                    suggestionQuery: suggestionQuery,
                    onSelectPrompt: handlePromptSelection,
                    selectedItemID: $selectedPromptSuggestionID
                )
                .padding(.horizontal, 15)
                .padding(.bottom, 4)
            }
            
            if showFileSuggestions {
                FileSuggestionView(
                    files: filteredFiles,
                    suggestionQuery: fileSuggestionQuery,
                    selectedItemID: $selectedFileSuggestionID,
                    multiSelectedFileIDs: $fileSuggestion_multiSelectedIDs
                )
                .padding(.horizontal, 15)
                .padding(.bottom, 4)
            }

            AttachedFilesDisplayView(
                attachedFiles: mainViewModel.attachedFiles,
                onRemoveFile: { fileItem in
                    mainViewModel.removeAttachedFile(fileItem: fileItem)
                }
            )
            
            ZStack {
                if inputViewModel.voiceInputState == .recording {
                    RecordingOverlayView(
                        recordingTime: $inputViewModel.recordingTime,
                        powerLevels: $inputViewModel.audioPowerLevels,
                        onCancel: {
                            inputViewModel.cancelRecording()
                        },
                        onConfirm: {
                            inputViewModel.toggleVoiceInput()
                        }
                    )
                } else {
                    mainInputArea
                }
            }
        }
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: showPromptSuggestions) { isShowing in
            if isShowing {
                self.filteredPrompts = promptStore.getAllPrompts().filter {
                    suggestionQuery.isEmpty || $0.title.lowercased().contains(suggestionQuery.lowercased())
                }
                self.selectedPromptSuggestionID = self.filteredPrompts.first?.id
            } else {
                self.selectedPromptSuggestionID = nil
            }
        }
        .onChange(of: suggestionQuery) { newQuery in
            self.filteredPrompts = promptStore.getAllPrompts().filter {
                newQuery.isEmpty || $0.title.lowercased().contains(newQuery.lowercased())
            }
            self.selectedPromptSuggestionID = self.filteredPrompts.first?.id
        }
        .onReceive(promptStore.$prompts) { _ in
            self.filteredPrompts = promptStore.getAllPrompts().filter {
                suggestionQuery.isEmpty || $0.title.lowercased().contains(suggestionQuery.lowercased())
            }
            if selectedPromptSuggestionID == nil {
                self.selectedPromptSuggestionID = self.filteredPrompts.first?.id
            }
        }
        .onChange(of: showFileSuggestions) { isShowing in
            if isShowing {
                updateFilteredFiles(query: self.fileSuggestionQuery)
            } else {
                self.selectedFileSuggestionID = nil
                self.fileSuggestion_multiSelectedIDs = []
            }
        }
        .onChange(of: fileSuggestionQuery) { newQuery in
            updateFilteredFiles(query: newQuery)
        }
        .onReceive(explorerViewModel.objectWillChange) { _ in
            if showFileSuggestions {
                updateFilteredFiles(query: self.fileSuggestionQuery)
            }
        }
        .onReceive(mainViewModel.objectWillChange) { _ in
            if showFileSuggestions {
                updateFilteredFiles(query: self.fileSuggestionQuery)
            }
        }
        .sheet(isPresented: $inputViewModel.showAPIKeyInputPopup, onDismiss: {
            inputViewModel.resetAPIKeyPopupState()
        }) {
            APIKeyInputPopup()
                .environmentObject(mainViewModel)
                .environmentObject(inputViewModel)
        }
        .animation(.spring(), value: mainViewModel.attachedFiles.count)
        .animation(.easeInOut(duration: 0.2), value: inputViewModel.voiceInputState)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: isSending) { newValue in
            if !newValue {
                inputViewModel.userInput = ""
            }
        }
    }

    private var mainInputArea: some View {
        VStack(spacing: 3) {
            editorAndPlaceholderArea
            toolbarArea
        }
        .background(ChatGPTBackgroundView())
        .cornerRadius(cornerRadiusValue)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadiusValue)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .opacity(isInputEnabled ? 1.0 : 0.6)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private var editorAndPlaceholderArea: some View {
        ZStack(alignment: .topLeading) {
            CustomTextEditor(
                text: $inputViewModel.userInput,
                onCommit: { attributedString in
                    if isInputEnabled {
                        let config = backendConfiguration.getRequestConfig()
                        self.onSendMessage(attributedString, config)
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
                },
                onNavigateSuggestions: navigateSuggestions,
                onConfirmSuggestion: confirmSuggestionSelection
            )
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)
            .animation(.easeInOut(duration: 0.2), value: inputViewModel.userInput)
            
            if inputViewModel.userInput.isEmpty {
                Text(placeholderText)
                    .font(Font(defaultTypingAttributes[.font] as! NSFont))
                    .foregroundColor(Color(NSColor.placeholderTextColor))
                    .padding(.leading, 3 + (editorTextView?.textContainer?.lineFragmentPadding ?? 5))
                    .padding(.top, editorTextView?.textContainerInset.height ?? 10)
                    .allowsHitTesting(false)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .focused(isInputFocused)
        .disabled(!isInputEnabled && mainViewModel.streamingMessageID == nil)
    }

    private var placeholderText: String {
        if backendConfiguration.selectedBackend == .none { return "Please select a backend to begin..." }
        if !mainViewModel.attachedFiles.isEmpty { return "Add a message or ask about the files..." }
        if inputViewModel.userInput.isEmpty {
            switch inputViewModel.voiceInputState {
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
                Image(systemName: "plus")
                    .resizable().scaledToFit().frame(width: iconSize, height: iconSize)
                    .foregroundColor(.secondary)
                    .padding(5)
                    .background(
                        Circle()
                            .fill(isPlusButtonHovering ? Color.white.opacity(0.15) : Color.clear)
                    )
                    .clipShape(Circle())
                    .scaleEffect(isPlusButtonHovering ? 1.1 : 1.0)
                    .animation(.easeOut(duration: 0.1), value: isPlusButtonHovering)
            }
            .buttonStyle(.plain)
            .onHover { hover in
                isPlusButtonHovering = hover
            }
            .help("Attach files")

            backendPickerButton()

            Spacer()

            dynamicActionButton
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
        .disabled(!isInputEnabled && mainViewModel.streamingMessageID == nil)
    }

    @ViewBuilder
    private func backendPickerButton() -> some View {
        Button(action: { self.showingBackendSelectorPopup = true }) {
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
            .background(Color.gray.opacity(isBackendPickerHovering ? 0.25 : 0.15))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(profileButtonBorderColor.opacity(isBackendPickerHovering ? 1.0 : 0.7), lineWidth: 0.75)
            )
            .animation(.easeOut(duration: 0.1), value: isBackendPickerHovering)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingBackendSelectorPopup, arrowEdge: .bottom) {
            BackendSelectorPopup(
                configuration: backendConfiguration,
                isPresented: $showingBackendSelectorPopup,
                llmIntegrationStore: mainViewModel.llmIntegrationStore
            )
        }
        .onHover { hover in
            isBackendPickerHovering = hover
        }
        .help("Select a backend (Agent or direct Model)")
    }

    @ViewBuilder
    private var dynamicActionButton: some View {
        let mode = currentDynamicButtonMode

        Button(action: {
            switch mode {
            case .send:
                guard let textView = editorTextView else {
                    logger.error("Send button: editorTextView is nil.");
                    if !inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let config = backendConfiguration.getRequestConfig()
                        onSendMessage(NSAttributedString(string: inputViewModel.userInput, attributes: defaultTypingAttributes), config)
                    }
                    return
                }
                let textToSend = textView.attributedString()
                if !textToSend.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let config = backendConfiguration.getRequestConfig()
                    onSendMessage(textToSend, config)
                }
            case .mic, .stopVoice:
                inputViewModel.toggleVoiceInput()
            case .stopStreaming:
                mainViewModel.cancelStreamingResponse()
            }
        }) {
            if isSending && mainViewModel.streamingMessageID == nil {
                ProgressView().controlSize(.small)
                    .frame(width: dynamicButtonSize, height: dynamicButtonSize)
            } else {
                ZStack {
                    let canSend = mode == .send && !inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let isDisabledBySystem = showSettings || (mode == .send && (inputViewModel.voiceInputState == .processing || inputViewModel.voiceInputState == .recording))

                    Circle()
                        .fill(buttonBackgroundColor(for: mode, canSend: canSend, isDisabledBySystem: isDisabledBySystem))
                        .animation(.easeOut(duration: 0.2), value: mode)

                    // NEW: Animated Icon ZStack
                    ZStack {
                        // Mic and Stop Voice Icons
                        if mode == .mic || mode == .stopVoice {
                            Image(systemName: dynamicActionButtonIconName(for: mode))
                                .resizable().scaledToFit()
                                .fontWeight(buttonIconWeight(for: mode))
                                .frame(width: dynamicButtonSize * buttonIconScale(for: mode), height: dynamicButtonSize * buttonIconScale(for: mode))
                                .foregroundColor(buttonIconForegroundColor(for: mode))
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }

                        // Send Arrow
                        if mode == .send {
                            Image(systemName: "arrow.up")
                                .resizable().scaledToFit()
                                .fontWeight(.semibold)
                                .frame(width: dynamicButtonSize * 0.5, height: dynamicButtonSize * 0.5)
                                .foregroundColor(.white)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }

                        // Stop Streaming Icon
                        if mode == .stopStreaming {
                            Image(systemName: "square.fill") // Using a more modern, solid square
                                .resizable().scaledToFit()
                                .fontWeight(.regular)
                                .frame(width: dynamicButtonSize * 0.45, height: dynamicButtonSize * 0.45)
                                .foregroundColor(.white)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .animation(.interpolatingSpring(stiffness: 300, damping: 15), value: mode)
                }
                .frame(width: dynamicButtonSize, height: dynamicButtonSize)
                .scaleEffect(isDynamicButtonHovering ? 1.1 : 1.0)
                .animation(.easeOut(duration: 0.1), value: isDynamicButtonHovering)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hover in
            isDynamicButtonHovering = hover
        }
        .disabled(isDynamicButtonDisabled(for: mode))
        .help(buttonHelpText(for: mode))
    }

    // MARK: - Helper Methods for Dynamic Button
    private func dynamicActionButtonIconName(for mode: DynamicButtonMode) -> String {
        switch mode {
        // These cases are now handled directly in the ViewBuilder's ZStack
        case .send, .stopStreaming:
            return "" // This won't be used, but a value is required.
        
        case .stopVoice:
            return "stop.circle.fill"
        case .mic:
            switch inputViewModel.voiceInputState {
            case .processing: return "hourglass.circle"
            case .permissionsDeniedMic, .error: return "mic.slash.fill"
            case .requestingPermissions: return "mic.badge.plus"
            default: return "mic.fill"
            }
        }
    }

    private func buttonIconScale(for mode: DynamicButtonMode) -> CGFloat {
        // This method is now only for .mic and .stopVoice
        switch mode {
        case .stopVoice: return 0.65
        case .mic: return 0.6
        default: return 0.5 // Default for send/stop handled inline
        }
    }

    private func buttonIconWeight(for mode: DynamicButtonMode) -> Font.Weight {
        // This method is now only for .mic and .stopVoice
        switch mode {
        case .send, .stopStreaming: return .regular // Default
        default: return .regular
        }
    }

    private func buttonBackgroundColor(for mode: DynamicButtonMode, canSend: Bool, isDisabledBySystem: Bool) -> Color {
        switch mode {
        case .send:
            return (canSend && !isDisabledBySystem) ? Color(NSColor.controlAccentColor) : Color.gray.opacity(0.3)
        case .stopVoice:
            return Color.red.opacity(0.8)
        case .stopStreaming:
            return Color.gray.opacity(0.4)
        case .mic:
            return (isDisabledBySystem || inputViewModel.voiceInputState != .available && inputViewModel.voiceInputState != .idle) ? Color(NSColor.controlAccentColor) : Color.gray.opacity(0.3)
        }
    }

    private func buttonIconForegroundColor(for mode: DynamicButtonMode) -> Color {
        switch mode {
        case .send, .stopVoice, .stopStreaming:
            return .white
        case .mic:
            switch inputViewModel.voiceInputState {
            case .recording: return .white
            case .processing: return .orange
            case .permissionsDeniedMic, .error: return .red.opacity(0.7)
            case .requestingPermissions: return .orange
            default:
                return .white
            }
        }
    }

    private func isDynamicButtonDisabled(for mode: DynamicButtonMode) -> Bool {
        if backendConfiguration.selectedBackend == .none { return true }
        switch mode {
        case .send:
            let isEmptyText = inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return isEmptyText || isSending || showSettings || inputViewModel.voiceInputState == .recording || inputViewModel.voiceInputState == .processing
        case .stopVoice:
            return isSending || showSettings
        case .stopStreaming:
            return false // The stop button should always be enabled when visible
        case .mic:
            return isSending || showSettings || inputViewModel.voiceInputState == .requestingPermissions || inputViewModel.voiceInputState == .processing || inputViewModel.voiceInputState == .recording
        }
    }

    private func buttonHelpText(for mode: DynamicButtonMode) -> String {
        switch mode {
        case .send: return "Send message (Enter)"
        case .stopVoice: return "Stop Voice Input"
        case .stopStreaming: return "Stop generating response"
        case .mic:
            switch inputViewModel.voiceInputState {
            case .idle, .available: return "Start Voice Input (Mic button)"
            case .processing: return "Processing Voice Input..."
            case .requestingPermissions: return "Requesting Voice Permissions..."
            case .permissionsDeniedMic: return "Microphone permission denied. Click to re-check."
            case .error(let specificError): return "Voice input error: \(specificError.prefix(30))... Click to re-check."
            default: return "Voice Input"
            }
        }
    }
    
    // MARK: - File & Prompt Handling

    private func updateFilteredFiles(query: String) {
        let allSuggestions = explorerViewModel.suggestableFiles(query: query)
        let attachedFileIDs = Set(mainViewModel.attachedFiles.map { $0.id })
        let newFilteredFiles = allSuggestions.filter { !attachedFileIDs.contains($0.id) }
        
        if self.filteredFiles != newFilteredFiles {
            self.filteredFiles = newFilteredFiles
        }
        
        if let selectedID = selectedFileSuggestionID, !self.filteredFiles.contains(where: { $0.id == selectedID }) {
            self.selectedFileSuggestionID = self.filteredFiles.first?.id
        } else if selectedFileSuggestionID == nil {
            self.selectedFileSuggestionID = self.filteredFiles.first?.id
        }
    }
    
    private func handlePromptSelection(_ prompt: Prompt) {
        guard let range = activePromptTriggerRange else {
            logger.warning("Attempted to select a prompt, but activePromptTriggerRange was nil.")
            return
        }

        logger.log("Prompt selected: '\(prompt.title)'. Replacing text in range \(NSStringFromRange(range)).")

        let insertionText = NSAttributedString(string: prompt.text + " ", attributes: defaultTypingAttributes)
        self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)

        self.showPromptSuggestions = false
        self.suggestionQuery = ""
        self.activePromptTriggerRange = nil
        self.filteredPrompts = []
    }

    private func openFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = "Attach Files or Folders"

        openPanel.begin { response in
            if response == .OK {
                let selectedURLs = openPanel.urls
                var fileItems: [FileSystemItem] = []

                for url in selectedURLs {
                    // Check the content type of the selected URL.
                    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                       type.conforms(to: .video) || type.conforms(to: .movie) {
                        logger.log("Skipping video file as it's not supported: \(url.lastPathComponent)")
                        continue // Skip this file if it's a video or movie.
                    }

                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                        let newItem = FileSystemItem(
                            id: url,
                            name: url.lastPathComponent,
                            url: url,
                            isDirectory: isDirectory.boolValue
                        )
                        fileItems.append(newItem)
                    }
                }

                if !fileItems.isEmpty {
                    mainViewModel.addAttachedFiles(fileItems: fileItems)
                }
            }
        }
    }
    
    // MARK: - Keyboard Navigation for Suggestions
    
    enum SuggestionNavigationDirection {
        case up, down
    }

    private func navigateSuggestions(direction: SuggestionNavigationDirection) {
        if showFileSuggestions {
            navigateFileSuggestions(direction: direction)
        } else if showPromptSuggestions {
            navigatePromptSuggestions(direction: direction)
        }
    }

    private func confirmSuggestionSelection() {
        if showFileSuggestions {
            confirmFileSuggestionSelection()
        } else if showPromptSuggestions {
            confirmPromptSuggestionSelection()
        }
    }

    private func navigateFileSuggestions(direction: SuggestionNavigationDirection) {
        guard !filteredFiles.isEmpty else { return }

        guard let currentSelectedID = selectedFileSuggestionID,
              let currentIndex = filteredFiles.firstIndex(where: { $0.id == currentSelectedID }) else {
            selectedFileSuggestionID = filteredFiles.first?.id
            return
        }

        var nextIndex: Int
        switch direction {
        case .up:
            nextIndex = currentIndex - 1
            if nextIndex < 0 {
                nextIndex = filteredFiles.count - 1
            }
        case .down:
            nextIndex = currentIndex + 1
            if nextIndex >= filteredFiles.count {
                nextIndex = 0
            }
        }
        
        selectedFileSuggestionID = filteredFiles[nextIndex].id
    }

    private func confirmFileSuggestionSelection() {
        var filesWereAttached = false

        if !fileSuggestion_multiSelectedIDs.isEmpty {
            let filesToAttach = filteredFiles.filter { fileSuggestion_multiSelectedIDs.contains($0.id) }
            if !filesToAttach.isEmpty {
                logger.log("Attaching \(filesToAttach.count) files from multi-selection.")
                mainViewModel.addAttachedFiles(fileItems: filesToAttach)
                filesWereAttached = true
            }
        }
        else if let selectedID = selectedFileSuggestionID,
                let selectedFile = filteredFiles.first(where: { $0.id == selectedID }) {
            logger.log("Attaching single focused file: \(selectedFile.name)")
            mainViewModel.addAttachedFile(fileItem: selectedFile)
            filesWereAttached = true
        }

        if filesWereAttached, let range = activeFileMentionTriggerRange {
            let insertionText = NSAttributedString(string: "", attributes: defaultTypingAttributes)
            self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)
        }
        
        self.showFileSuggestions = false
        self.fileSuggestionQuery = ""
        self.activeFileMentionTriggerRange = nil
        self.filteredFiles = []
    }

    private func navigatePromptSuggestions(direction: SuggestionNavigationDirection) {
        guard !filteredPrompts.isEmpty else { return }

        guard let currentSelectedID = selectedPromptSuggestionID,
              let currentIndex = filteredPrompts.firstIndex(where: { $0.id == currentSelectedID }) else {
            selectedPromptSuggestionID = filteredPrompts.first?.id
            return
        }

        var nextIndex: Int
        switch direction {
        case .up:
            nextIndex = currentIndex - 1
            if nextIndex < 0 {
                nextIndex = filteredPrompts.count - 1
            }
        case .down:
            nextIndex = currentIndex + 1
            if nextIndex >= filteredPrompts.count {
                nextIndex = 0
            }
        }

        selectedPromptSuggestionID = filteredPrompts[nextIndex].id
    }

    private func confirmPromptSuggestionSelection() {
        guard let selectedID = selectedPromptSuggestionID,
              let selectedPrompt = filteredPrompts.first(where: { $0.id == selectedID }) else {
            return
        }
        handlePromptSelection(selectedPrompt)
    }
}
