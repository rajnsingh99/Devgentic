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
    @State private var showFileSuggestions: Bool = false
    @State private var fileSuggestionQuery: String = ""
    @State private var filteredFiles: [FileSystemItem] = []
    @State private var activeFileMentionTriggerRange: NSRange? = nil
    @State private var showingBackendSelectorPopup: Bool = false
    @State private var attributedTextInsertionRequest: CustomTextEditor.AttributedTextInsertionAction? = nil
    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil

    // MARK: - Hover States for Buttons
    @State private var isPlusButtonHovering: Bool = false
    @State private var isGlobeButtonHovering: Bool = false
    @State private var isBackendPickerHovering: Bool = false
    @State private var isDynamicButtonHovering: Bool = false


    private let promptStore = PromptStore.shared

    // MARK: - Layout Constants
    private let iconSize: CGFloat = 20
    private let dynamicButtonSize: CGFloat = 28
    private let cornerRadiusValue: CGFloat = 20
    private let textEditorMinHeight: CGFloat = 30
    private let textEditorMaxHeight: CGFloat = 200

    private var isInputEnabled: Bool {
        !isSending && !showSettings
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
        case .agent:
            if let agentID = backendConfiguration.selectedAgentID,
               let agent = mainViewModel.agentStore.agents.first(where: { $0.id == agentID }) {
                return agent.name
            }
        case .ollama, .remote:
            if let integrationID = backendConfiguration.selectedIntegrationID,
               let integration = mainViewModel.llmIntegrationStore.integrations.first(where: { $0.id == integrationID }) {
                return integration.displayName
            }
        case .none:
            break
        }
        return "Select Backend"
    }

    private var hasInputText: Bool {
        !inputViewModel.userInput.isEmpty
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
        if isSending { return .stop }
        if hasInputText || !mainViewModel.attachedFiles.isEmpty { return .send }
        return .mic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showPromptSuggestions {
                PromptSuggestionView(
                    prompts: filteredPrompts,
                    suggestionQuery: suggestionQuery,
                    onSelectPrompt: handlePromptSelection
                )
                .padding(.horizontal, 15)
                .padding(.bottom, 4)
            }
            
            if showFileSuggestions {
                FileSuggestionView(
                    files: filteredFiles,
                    suggestionQuery: fileSuggestionQuery,
                    onSelectFile: handleFileSelection
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
        // --- FIX: Replicated the working logic from file suggestions for prompt suggestions ---
        .onChange(of: showPromptSuggestions) { isShowing in
            if isShowing {
                // When the view appears, perform an initial filter
                self.filteredPrompts = promptStore.getAllPrompts().filter {
                    suggestionQuery.isEmpty || $0.title.lowercased().contains(suggestionQuery.lowercased())
                }
            }
        }
        .onChange(of: suggestionQuery) { newQuery in
            // As the query changes, update the filtered list
            self.filteredPrompts = promptStore.getAllPrompts().filter {
                newQuery.isEmpty || $0.title.lowercased().contains(newQuery.lowercased())
            }
        }
        .onReceive(promptStore.$prompts) { _ in
             // If the underlying prompts change (e.g., added/deleted), re-filter
            self.filteredPrompts = promptStore.getAllPrompts().filter {
                suggestionQuery.isEmpty || $0.title.lowercased().contains(suggestionQuery.lowercased())
            }
        }
        .onChange(of: showFileSuggestions) { isShowing in
            if isShowing {
                self.filteredFiles = explorerViewModel.suggestableFiles(query: self.fileSuggestionQuery)
            }
        }
        .onChange(of: fileSuggestionQuery) { newQuery in
            self.filteredFiles = explorerViewModel.suggestableFiles(query: newQuery)
        }
        .onReceive(explorerViewModel.objectWillChange) { _ in
            self.filteredFiles = explorerViewModel.suggestableFiles(query: self.fileSuggestionQuery)
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
        .background(VisualEffectBlur(material: .underWindowBackground, blendingMode: .withinWindow))
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
                }
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
        .disabled(!isInputEnabled)
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
                    .foregroundColor(isPlusButtonHovering ? .accentColor : .secondary)
                    .scaleEffect(isPlusButtonHovering ? 1.1 : 1.0)
                    .animation(.easeOut(duration: 0.1), value: isPlusButtonHovering)
            }
            .buttonStyle(.plain)
            .onHover { hover in
                isPlusButtonHovering = hover
            }
            .help("Attach files")

            Button(action: handleGlobeButtonTap) {
                Image(systemName: "globe")
                    .resizable().scaledToFit().frame(width: iconSize, height: iconSize)
                    .foregroundColor(globeButtonColor)
                    .scaleEffect(isGlobeButtonHovering ? 1.1 : 1.0)
                    .animation(.easeOut(duration: 0.1), value: isGlobeButtonHovering)
            }
            .buttonStyle(.plain)
            .onHover { hover in
                isGlobeButtonHovering = hover
            }
            .help(globeButtonHelpText)

            backendPickerButton()

            Spacer()

            dynamicActionButton
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 10)
        .disabled(!isInputEnabled)
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
                    .stroke(profileButtonBorderColor.opacity(isBackendPickerHovering ? 1.0 : 0.7), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.1), value: isBackendPickerHovering)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingBackendSelectorPopup, arrowEdge: .bottom) {
            BackendSelectorPopup(
                configuration: backendConfiguration,
                isPresented: $showingBackendSelectorPopup,
                agentStore: mainViewModel.agentStore,
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
                    if !inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty {
                        let config = backendConfiguration.getRequestConfig()
                        onSendMessage(NSAttributedString(string: inputViewModel.userInput, attributes: defaultTypingAttributes), config)
                    }
                    return
                }
                let textToSend = textView.attributedString()
                if !textToSend.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty {
                    let config = backendConfiguration.getRequestConfig()
                    onSendMessage(textToSend, config)
                }
            case .mic, .stop:
                inputViewModel.toggleVoiceInput()
            }
        }) {
            if isSending && mode == .send {
                ProgressView().controlSize(.small)
                    .frame(width: dynamicButtonSize, height: dynamicButtonSize)
            } else {
                ZStack {
                    let canSend = mode == .send && (!inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty)
                    let isDisabledBySystem = showSettings || (mode == .send && (inputViewModel.voiceInputState == .processing || inputViewModel.voiceInputState == .recording))

                    Circle()
                        .fill(buttonBackgroundColor(for: mode, canSend: canSend, isDisabledBySystem: isDisabledBySystem)
                              .opacity(isDynamicButtonHovering ? 0.8 : 1.0))
                        .animation(.easeOut(duration: 0.1), value: isDynamicButtonHovering)

                    Image(systemName: dynamicActionButtonIconName(for: mode))
                        .resizable().scaledToFit()
                        .fontWeight(buttonIconWeight(for: mode))
                        .frame(width: dynamicButtonSize * buttonIconScale(for: mode), height: dynamicButtonSize * buttonIconScale(for: mode))
                        .foregroundColor(buttonIconForegroundColor(for: mode))
                        .scaleEffect(isDynamicButtonHovering ? 1.1 : 1.0)
                        .animation(.easeOut(duration: 0.1), value: isDynamicButtonHovering)
                }
                .frame(width: dynamicButtonSize, height: dynamicButtonSize)
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
        case .send: return "arrow.up"
        case .stop: return "stop.circle.fill"
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
            return (isDisabledBySystem || inputViewModel.voiceInputState != .available && inputViewModel.voiceInputState != .idle) ? Color(NSColor.controlAccentColor) : Color.gray.opacity(0.3)
        }
    }

    private func buttonIconForegroundColor(for mode: DynamicButtonMode) -> Color {
        switch mode {
        case .send: return .white
        case .stop: return .white
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
            let isEmptyTextAndNoFiles = inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mainViewModel.attachedFiles.isEmpty
            return isEmptyTextAndNoFiles || isSending || showSettings || inputViewModel.voiceInputState == .recording || inputViewModel.voiceInputState == .processing
        case .stop:
            return isSending || showSettings
        case .mic:
            return isSending || showSettings || inputViewModel.voiceInputState == .requestingPermissions || inputViewModel.voiceInputState == .processing || inputViewModel.voiceInputState == .recording
        }
    }

    private func buttonHelpText(for mode: DynamicButtonMode) -> String {
        switch mode {
        case .send: return "Send message (Enter)"
        case .stop: return "Stop Voice Input"
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
    
    private var globeButtonColor: Color {
        if mainViewModel.isWebSearchActive {
            return .accentColor
        }
        return isGlobeButtonHovering ? .accentColor : .secondary
    }

    private var globeButtonHelpText: String {
        if mainViewModel.isWebSearchEnabled {
            return mainViewModel.isWebSearchActive ? "Web Search is Active" : "Web Search is Inactive"
        }
        return "Enable Web Search"
    }

    private func handleGlobeButtonTap() {
        if mainViewModel.isWebSearchEnabled {
            mainViewModel.toggleWebSearch()
        } else {
            inputViewModel.showAPIKeyInputPopup = true
        }
    }

    // MARK: - File & Prompt Handling
    
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
    
    private func handleFileSelection(_ file: FileSystemItem) {
        mainViewModel.addAttachedFile(fileItem: file)

        if let range = activeFileMentionTriggerRange {
            let insertionText = NSAttributedString(string: "", attributes: defaultTypingAttributes)
            self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)
        }

        self.showFileSuggestions = false
        self.fileSuggestionQuery = ""
        self.activeFileMentionTriggerRange = nil
        self.filteredFiles = []
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
}
