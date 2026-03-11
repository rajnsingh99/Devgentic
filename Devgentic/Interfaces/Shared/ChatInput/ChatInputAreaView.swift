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
    @Environment(\.appTheme) private var theme

    // MARK: - UI State (Cleaned of Business Logic)
    @State private var showingBackendSelectorPopup: Bool = false
    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil
    @State private var showingToolLibrary = false
    @State private var selectedProfile: BackendProfileModel?
    @State private var isToolsHovering = false

    // MARK: - Hover States
    @State private var isPlusButtonHovering: Bool = false
    @State private var isBackendPickerHovering: Bool = false
    @State private var isDynamicButtonHovering: Bool = false

    // MARK: - Layout Constants
    private let iconSize: CGFloat = 16
    private let dynamicButtonSize: CGFloat = 30
    private let textEditorMinHeight: CGFloat = 32
    private let textEditorMaxHeight: CGFloat = 200

    private var isInputEnabled: Bool {
        let isQueryInProgress = isSending || mainViewModel.streamingMessageID != nil
        return !isQueryInProgress && !showSettings
    }

    // MARK: - Typography
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        return [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    // MARK: - Dynamic UI Properties
    private var profileButtonIconName: String {
        guard let profile = selectedProfile else { return "questionmark.circle" }
        switch profile.profileType {
        case .agent: return "person.2.fill"
        case .bot:
            if case .bot(let config, _) = profile.details, config.apiProvider == .ollama { return "cpu" }
            return "cloud.fill"
        case .workflow: return "square.stack.3d.up.fill"
        }
    }

    private var profileThemeColor: Color {
        guard let profile = selectedProfile else { return .secondary }
        switch profile.profileType {
        case .bot: return .blue
        case .agent: return .green
        case .workflow: return .purple
        }
    }

    private var profileButtonText: String {
        return selectedProfile?.displayName ?? "Select Backend"
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
        if mainViewModel.streamingMessageID != nil { return .stopStreaming }
        if inputViewModel.voiceInputState == .recording || inputViewModel.voiceInputState == .finalizingSilence { return .stopVoice }
        if hasInputText { return .send }
        return .mic
    }
    
    // MARK: - Suggestion Enums
    enum SuggestionNavigationDirection { case up, down }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            
            // PROMPT SUGGESTIONS (Driven by VM State)
            if inputViewModel.promptSuggestionState.isShowing {
                PromptSuggestionView(
                    prompts: inputViewModel.promptSuggestionState.filteredItems,
                    suggestionQuery: inputViewModel.promptSuggestionState.query,
                    onSelectPrompt: { prompt in
                        inputViewModel.selectPrompt(prompt)
                    },
                    selectedItemID: $inputViewModel.promptSuggestionState.selectedID
                )
                .padding(.horizontal, 15)
                .padding(.bottom, 6)
            }
            
            // FILE SUGGESTIONS (Driven by VM State)
            if inputViewModel.fileSuggestionState.isShowing {
                FileSuggestionView(
                    files: inputViewModel.fileSuggestionState.filteredItems,
                    suggestionQuery: inputViewModel.fileSuggestionState.query,
                    selectedItemID: $inputViewModel.fileSuggestionState.selectedID,
                    multiSelectedFileIDs: $inputViewModel.fileSuggestionState.multiSelectedIDs
                )
                .padding(.horizontal, 15)
                .padding(.bottom, 6)
            }

            AttachedFilesDisplayView(
                attachedFiles: mainViewModel.attachedFiles,
                onRemoveFile: { fileItem in
                    mainViewModel.removeAttachedFile(fileItem: fileItem)
                }
            )
            .padding(.horizontal, 4)
            
            ZStack {
                if inputViewModel.voiceInputState == .recording
                    || inputViewModel.voiceInputState == .finalizingSilence {
                    RecordingOverlayView(
                        displayStore: inputViewModel.recordingDisplay,
                        onCancel: { inputViewModel.cancelRecording() },
                        onConfirm: { inputViewModel.toggleVoiceInput() }
                    )
                } else {
                    mainInputArea
                }
            }
        }
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity, alignment: .center)
        
        // MARK: - Wiring
        .onAppear {
            updateSelectedProfile(profileID: backendConfiguration.selectedProfileID)
            
            // CONNECT DATA SOURCE TO VM (This fixes the missing file suggestions)
            inputViewModel.onFileSearchRequest = { [weak explorerViewModel, weak mainViewModel] query in
                let candidates = explorerViewModel?.suggestableFiles(query: query) ?? []
                let attached = mainViewModel?.attachedFiles ?? []
                return (candidates, attached)
            }
        }
        .onChange(of: backendConfiguration.selectedProfileID) { newID in updateSelectedProfile(profileID: newID) }
        
        // Refresh files if Explorer/Context changes (Lazy refresh)
        .onReceive(explorerViewModel.objectWillChange) { _ in
            if inputViewModel.fileSuggestionState.isShowing {
                refreshFileSuggestions(query: inputViewModel.fileSuggestionState.query)
            }
        }
        .onReceive(mainViewModel.objectWillChange) { _ in
            if inputViewModel.fileSuggestionState.isShowing {
                refreshFileSuggestions(query: inputViewModel.fileSuggestionState.query)
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
    }
    
    private func refreshFileSuggestions(query: String) {
        // Trigger VM's logic manually for external data changes
        let candidates = explorerViewModel.suggestableFiles(query: query)
        inputViewModel.processFileCandidates(candidates, attachedFiles: mainViewModel.attachedFiles)
    }
    
    private func updateSelectedProfile(profileID: UUID?) {
        if let id = profileID {
            self.selectedProfile = BackendProfileStore.shared.fetchProfiles().first { $0.id == id }
        } else {
            self.selectedProfile = nil
        }
    }

    // MARK: - Main Input Area
    private var mainInputArea: some View {
        VStack(spacing: 6) {
            editorAndPlaceholderArea
            toolbarArea
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(theme.controlBackground)
                .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.surfaceOverlay, lineWidth: 1)
        )
        .transition(.opacity)
    }

    private var editorAndPlaceholderArea: some View {
        ZStack(alignment: .topLeading) {
            CustomTextEditor(
                text: $inputViewModel.userInput,
                onCommit: { attributedString in
                    if isInputEnabled, let config = backendConfiguration.getRequestConfig() {
                        self.onSendMessage(attributedString, config)
                        self.inputViewModel.userInput = ""
                    } else {
                        logger.warning("Commit triggered but no backend profile is selected.")
                    }
                },
                minHeight: textEditorMinHeight,
                maxHeight: textEditorMaxHeight,
                
                // CRITICAL: Bind to VM State, NOT local state
                showPromptSuggestions: $inputViewModel.promptSuggestionState.isShowing,
                suggestionQuery: $inputViewModel.promptSuggestionState.query,
                activePromptTriggerRange: $inputViewModel.promptSuggestionState.triggerRange,
                
                showFileSuggestions: $inputViewModel.fileSuggestionState.isShowing,
                fileSuggestionQuery: $inputViewModel.fileSuggestionState.query,
                activeFileMentionTriggerRange: $inputViewModel.fileSuggestionState.triggerRange,
                
                attributedTextInsertion: $inputViewModel.attributedTextInsertionRequest,
                
                textViewRef: { nsTextViewInstance in
                    self.editorTextView = nsTextViewInstance
                },
                
                // Delegated Logic
                onNavigateSuggestions: { direction in
                    if inputViewModel.promptSuggestionState.isShowing {
                        inputViewModel.navigateSuggestions(direction: direction, type: .prompt)
                    } else if inputViewModel.fileSuggestionState.isShowing {
                        inputViewModel.navigateSuggestions(direction: direction, type: .file)
                    }
                },
                onConfirmSuggestion: confirmSuggestionSelection,
                
                onNavigateQueryHistory: { direction in
                    if let historicalQuery = mainViewModel.getQueryFromHistory(direction: direction) {
                        inputViewModel.userInput = historicalQuery
                        DispatchQueue.main.async {
                            editorTextView?.setSelectedRange(NSRange(location: historicalQuery.count, length: 0))
                        }
                    }
                },
                onTextManuallyChanged: {
                    mainViewModel.resetQueryHistoryIndex()
                }
            )
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)
            
            if inputViewModel.userInput.isEmpty {
                // Use fixed constants matching makeNSView setup (lineFragmentPadding=5,
                // textContainerInset.width=2, textContainerInset.height=10) instead of
                // reading from the optional textView ref which is nil on first render.
                Text(placeholderText)
                    .font(Font(defaultTypingAttributes[.font] as! NSFont))
                    .foregroundColor(theme.placeholderText)
                    .padding(.leading, 3 + 5) // textContainerInset.width(2) + lineFragmentPadding(5) ≈ 8
                    .padding(.top, 10)         // textContainerInset.height
                    .allowsHitTesting(false)
            }
        }
        // Top padding removed — textContainerInset.height (10pt) already provides
        // vertical inset inside the NSTextView. Stacking both caused 20pt top gap.
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 4, trailing: 12))
        .focused(isInputFocused)
        .disabled(!isInputEnabled)
        .opacity(isInputEnabled ? 1.0 : 0.6)
    }

    private var placeholderText: String {
        if backendConfiguration.selectedProfileID == nil { return "Select a backend..." }
        if !mainViewModel.attachedFiles.isEmpty { return "Ask about context..." }
        if inputViewModel.userInput.isEmpty {
            switch inputViewModel.voiceInputState {
                case .recording: return "Listening..."
                case .processing: return "Processing..."
                case .finalizingSilence: return "Finalizing..."
                case .error: return "Voice error..."
                default: return "Type a message..."
            }
        }
        return ""
    }

    private var toolbarArea: some View {
        HStack(spacing: 12) {
            Button(action: openFilePicker) {
                Image(systemName: "paperclip")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundColor(isPlusButtonHovering ? theme.primaryText : theme.secondaryText.opacity(0.8))
                    .padding(7)
                    .background(
                        Circle()
                            .fill(isPlusButtonHovering ? theme.secondaryText.opacity(0.25) : theme.secondaryText.opacity(0.18))
                    )
            }
            .buttonStyle(.plain)
            .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isPlusButtonHovering = hover } }
            .help("Attach files")
            .disabled(!isInputEnabled)
            .opacity(isInputEnabled ? 1.0 : 0.5)

            if selectedProfile?.profileType == .agent {
                Button(action: { self.showingToolLibrary = true }) {
                    Image(systemName: "hammer.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .foregroundColor(isToolsHovering ? theme.primaryText : theme.secondaryText.opacity(0.8))
                        .padding(7)
                        .background(
                            Circle()
                                .fill(isToolsHovering ? theme.secondaryText.opacity(0.25) : theme.secondaryText.opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
                .onHover { hover in withAnimation(.easeInOut(duration: 0.15)) { isToolsHovering = hover } }
                .help("Manage tools for this agent")
                .disabled(!isInputEnabled)
                .opacity(isInputEnabled ? 1.0 : 0.5)
                .sheet(isPresented: $showingToolLibrary) {
                    ToolLibraryView(
                        configuredTools: toolsBinding,
                        instructions: profileInstructions
                    )
                }
            }

            backendPickerButton()
                .disabled(!isInputEnabled)
                .opacity(isInputEnabled ? 1.0 : 0.5)

            Spacer()

            dynamicActionButton
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func backendPickerButton() -> some View {
        Button(action: { self.showingBackendSelectorPopup = true }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(profileThemeColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: profileThemeColor.opacity(0.4), radius: 2, x: 0, y: 0)

                Text(profileButtonText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.secondaryText.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isBackendPickerHovering ? theme.surfaceOverlay : Color.clear)
            )
            .overlay(
                Capsule()
                    .stroke(theme.secondaryText.opacity(isBackendPickerHovering ? 0.3 : 0.15), lineWidth: 1)
            )
            .scaleEffect(isBackendPickerHovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingBackendSelectorPopup, arrowEdge: .bottom) {
            BackendSelectorPopup(
                configuration: backendConfiguration,
                isPresented: $showingBackendSelectorPopup
            )
        }
        .onHover { hover in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isBackendPickerHovering = hover } }
        .help("Select a backend (Bot, Agent, or Workflow)")
    }

    @ViewBuilder
    private var dynamicActionButton: some View {
        let mode = currentDynamicButtonMode

        Button(action: {
            switch mode {
            case .send:
                guard let config = backendConfiguration.getRequestConfig() else {
                    logger.error("Send button: Could not get backend config."); return
                }
                guard let textView = editorTextView else {
                    if !inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onSendMessage(NSAttributedString(string: inputViewModel.userInput, attributes: defaultTypingAttributes), config)
                        inputViewModel.userInput = ""
                    }
                    return
                }
                let textToSend = textView.attributedString()
                if !textToSend.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onSendMessage(textToSend, config)
                    inputViewModel.userInput = ""
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
                        .shadow(color: buttonBackgroundColor(for: mode, canSend: canSend, isDisabledBySystem: isDisabledBySystem).opacity(0.3), radius: 3, x: 0, y: 2)

                    ZStack {
                        if mode == .mic || mode == .stopVoice {
                            Image(systemName: dynamicActionButtonIconName(for: mode))
                                .resizable().scaledToFit()
                                .fontWeight(buttonIconWeight(for: mode))
                                .frame(width: dynamicButtonSize * buttonIconScale(for: mode), height: dynamicButtonSize * buttonIconScale(for: mode))
                                .foregroundColor(buttonIconForegroundColor(for: mode))
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }

                        if mode == .send {
                            Image(systemName: "arrow.up")
                                .resizable().scaledToFit()
                                .fontWeight(.semibold)
                                .frame(width: dynamicButtonSize * 0.5, height: dynamicButtonSize * 0.5)
                                .foregroundColor(.white)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }

                        if mode == .stopStreaming {
                            Image(systemName: "square.fill")
                                .resizable().scaledToFit()
                                .fontWeight(.regular)
                                .frame(width: dynamicButtonSize * 0.45, height: dynamicButtonSize * 0.45)
                                .foregroundColor(.white)
                                .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }

                    // Inline progress spinner overlay during model download/preparation
                    if inputViewModel.voiceInputState == .modelLoading || inputViewModel.voiceInputState == .modelPreparing {
                        Circle()
                            .fill(theme.controlBackground.opacity(0.85))
                            .frame(width: dynamicButtonSize, height: dynamicButtonSize)
                            .overlay {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                            }
                            .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    }
                }
                .frame(width: dynamicButtonSize, height: dynamicButtonSize)
                .scaleEffect(isDynamicButtonHovering ? 1.05 : 1.0)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hover in withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { isDynamicButtonHovering = hover } }
        .disabled(isDynamicButtonDisabled(for: mode))
        .help(buttonHelpText(for: mode))
        .popover(isPresented: $inputViewModel.showModelSelectorPopover, arrowEdge: .top) {
            WhisperModelSelectorPopover(
                isPresented: $inputViewModel.showModelSelectorPopover,
                currentModelName: inputViewModel.currentSpeechModelName,
                onSelectModel: { modelName in
                    inputViewModel.selectAndDownloadModel(modelName)
                }
            )
        }
    }

    private func dynamicActionButtonIconName(for mode: DynamicButtonMode) -> String {
        switch mode {
        case .send, .stopStreaming: return ""
        case .stopVoice: return "stop.circle.fill"
        case .mic:
            switch inputViewModel.voiceInputState {
            case .processing: return "hourglass"
            case .permissionsDeniedMic, .error: return "mic.slash.fill"
            case .requestingPermissions: return "mic.badge.plus"
            case .modelLoading, .modelPreparing: return "arrow.down.circle"
            default: return "waveform"
            }
        }
    }

    private func buttonIconScale(for mode: DynamicButtonMode) -> CGFloat {
        switch mode {
        case .stopVoice: return 0.55
        case .mic: return 0.5
        default: return 0.5
        }
    }

    private func buttonIconWeight(for mode: DynamicButtonMode) -> Font.Weight {
        return .medium
    }

    private func buttonBackgroundColor(for mode: DynamicButtonMode, canSend: Bool, isDisabledBySystem: Bool) -> Color {
        switch mode {
        case .send:
            return (canSend && !isDisabledBySystem) ? theme.controlAccent : theme.secondaryText.opacity(0.2)
        case .stopVoice:
            return theme.errorColor.opacity(0.9)
        case .stopStreaming:
            return theme.primaryText
        case .mic:
            return (isDisabledBySystem || inputViewModel.voiceInputState != .available && inputViewModel.voiceInputState != .idle) ? theme.controlAccent : theme.secondaryText.opacity(0.2)
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
            case .permissionsDeniedMic, .error: return .red.opacity(0.8)
            case .requestingPermissions: return .orange
            case .modelLoading, .modelPreparing: return theme.accentColor
            default: return theme.primaryText
            }
        }
    }

    private func isDynamicButtonDisabled(for mode: DynamicButtonMode) -> Bool {
        if backendConfiguration.selectedProfileID == nil { return true }
        switch mode {
        case .send:
            let isEmptyText = inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return isEmptyText || isSending || showSettings || inputViewModel.voiceInputState == .recording || inputViewModel.voiceInputState == .processing || inputViewModel.voiceInputState == .finalizingSilence
        case .stopVoice: return isSending || showSettings
        case .stopStreaming: return false
        case .mic:
            return isSending || showSettings || inputViewModel.voiceInputState == .requestingPermissions || inputViewModel.voiceInputState == .processing || inputViewModel.voiceInputState == .recording || inputViewModel.voiceInputState == .finalizingSilence || inputViewModel.voiceInputState == .modelLoading || inputViewModel.voiceInputState == .modelPreparing
        }
    }

    private func buttonHelpText(for mode: DynamicButtonMode) -> String {
        switch mode {
        case .send: return "Send message (Enter)"
        case .stopVoice: return "Stop Voice Input"
        case .stopStreaming: return "Stop generating response"
        case .mic: return "Voice Input"
        }
    }
    
    // MARK: - Handlers
    
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
                    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                       type.conforms(to: .video) || type.conforms(to: .movie) {
                        continue
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
    
    private func confirmSuggestionSelection() {
        if inputViewModel.fileSuggestionState.isShowing {
            var filesWereAttached = false
            let multiSelected = inputViewModel.fileSuggestionState.multiSelectedIDs
            
            if !multiSelected.isEmpty {
                let filesToAttach = inputViewModel.fileSuggestionState.filteredItems.filter { multiSelected.contains($0.id) }
                if !filesToAttach.isEmpty {
                    logger.log("Attaching \(filesToAttach.count) files from multi-selection.")
                    mainViewModel.addAttachedFiles(fileItems: filesToAttach)
                    filesWereAttached = true
                    
                    inputViewModel.selectMultipleFiles(filesToAttach)
                }
            }
            else if let selectedID = inputViewModel.fileSuggestionState.selectedID,
                    let selectedFile = inputViewModel.fileSuggestionState.filteredItems.first(where: { $0.id == selectedID }) {
                logger.log("Attaching single focused file: \(selectedFile.name)")
                mainViewModel.addAttachedFile(fileItem: selectedFile)
                filesWereAttached = true
                
                _ = inputViewModel.selectFile(selectedFile)
            }
        }
        else if inputViewModel.promptSuggestionState.isShowing {
            guard let selectedID = inputViewModel.promptSuggestionState.selectedID,
                  let selectedPrompt = inputViewModel.promptSuggestionState.filteredItems.first(where: { $0.id == selectedID }) else { return }
            inputViewModel.selectPrompt(selectedPrompt)
        }
    }

    // MARK: - Tool Management Helpers

    private var toolsBinding: Binding<[Tool]> {
        Binding(
            get: {
                if case .agent(_, _, let tools, _, _, _) = selectedProfile?.details {
                    return tools
                }
                return []
            },
            set: { newTools in
                guard var profile = selectedProfile else { return }
                if case .agent(let config, let arch, _, let desc, let instr, let sources) = profile.details {
                    profile.details = .agent(
                        llmConfig: config,
                        architecture: arch,
                        tools: newTools,
                        description: desc,
                        instructions: instr,
                        knowledgeSources: sources
                    )
                    selectedProfile = profile
                    // Persist change via shared store
                    BackendProfileStore.shared.saveProfile(profile)
                }
            }
        )
    }

    private var profileInstructions: String {
        if case .agent(_, _, _, _, let instructions, _) = selectedProfile?.details {
            return instructions ?? ""
        }
        return ""
    }
}
