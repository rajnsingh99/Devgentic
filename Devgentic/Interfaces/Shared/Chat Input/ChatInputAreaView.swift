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
    
    @State private var showingBackendSelectorPopup: Bool = false

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
        switch mainViewModel.selectedBackend {
        case .agent:
            if let agent = mainViewModel.agentStore.currentAgent {
                return agent.name
            }
        case .ollama, .remote:
            if let integration = mainViewModel.llmIntegrationStore.currentIntegration {
                return integration.displayName
            }
        case .none:
            break
        }
        return "Select Backend"
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
            // Suggestion Views
            if showFileSuggestions {
                FileSuggestionView(
                    files: filteredFiles,
                    suggestionQuery: fileSuggestionQuery,
                    onSelectFile: handleFileSelection
                )
                .padding(.horizontal, 15)
                .padding(.bottom, 4)
            }

            // Attached Files Display
            AttachedFilesDisplayView(
                attachedFiles: mainViewModel.attachedFiles,
                onRemoveFile: { fileItem in
                    mainViewModel.removeAttachedFile(fileItem: fileItem)
                }
            )

            mainInputArea
        }
        .onChange(of: showFileSuggestions) { isShowing in
            if isShowing {
                // Pre-populate the list when the suggestion view is about to appear.
                // This avoids a race condition where the view appears with an empty file list initially.
                self.filteredFiles = explorerViewModel.suggestableFiles(query: self.fileSuggestionQuery)
            }
        }
        .onChange(of: fileSuggestionQuery) { newQuery in
            self.filteredFiles = explorerViewModel.suggestableFiles(query: newQuery)
        }
        // --- FIX STARTS HERE ---
        // We now use .onReceive to subscribe to the publisher of the fileCacheID.
        // This is the correct and robust way to react to changes in an ObservableObject
        // from a SwiftUI view, avoiding the previous compiler errors.
        .onReceive(explorerViewModel.objectWillChange) { _ in
            // Re-filter the list of files whenever the underlying view model data changes.
            logger.info("RAJ Updated triggered")
            self.filteredFiles = explorerViewModel.suggestableFiles(query: self.fileSuggestionQuery)
        }
        // --- FIX ENDS HERE ---
        .animation(.spring(), value: mainViewModel.attachedFiles.count)
        .animation(.easeInOut(duration: 0.15), value: currentDynamicButtonMode)
        .animation(.easeInOut(duration: 0.15), value: mainViewModel.voiceInputState)
        .fixedSize(horizontal: false, vertical: true)
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
                // Pass-through bindings for suggestion features
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
        if mainViewModel.selectedBackend == .none { return "Please select a backend to begin..." }
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
            .background(Color.gray.opacity(0.15))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(profileButtonBorderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingBackendSelectorPopup, arrowEdge: .bottom) {
            BackendSelectorPopup(
                selectedBackend: $mainViewModel.selectedBackend,
                selectedAgentID: $mainViewModel.selectedAgentID,
                selectedIntegrationID: $mainViewModel.llmIntegrationStore.selectedIntegrationID,
                isPresented: $showingBackendSelectorPopup,
                agentStore: mainViewModel.agentStore,
                llmIntegrationStore: mainViewModel.llmIntegrationStore
            )
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

    // MARK: - Helper Methods for Dynamic Button
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
        if mainViewModel.selectedBackend == .none { return true }
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
    
    // MARK: - File & Prompt Handling
    private func handleFileSelection(_ file: FileSystemItem) {
        // 1. Add the file to the central list of attachments
        mainViewModel.addAttachedFile(fileItem: file)

        // 2. Create a request to replace the "@query" text in the editor
        if let range = activeFileMentionTriggerRange {
            let insertionText = NSAttributedString(string: file.name + " ", attributes: defaultTypingAttributes)
            self.attributedTextInsertionRequest = .init(range: range, attributedString: insertionText)
        }

        // 3. Reset the suggestion UI state
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
