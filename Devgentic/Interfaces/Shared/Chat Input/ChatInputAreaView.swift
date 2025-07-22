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
    let isSending: Bool // This binding comes from MainApplicationViewModel
    let showSettings: Bool
    var isInputFocused: FocusState<Bool>.Binding // Corrected: Changed from .Bool to .Binding

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
        if inputViewModel.voiceInputState == .recording {
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
                self.filteredFiles = explorerViewModel.suggestableFiles(query: self.fileSuggestionQuery)
            }
        }
        .onChange(of: fileSuggestionQuery) { newQuery in
            self.filteredFiles = explorerViewModel.suggestableFiles(query: newQuery)
        }
        .onReceive(explorerViewModel.objectWillChange) { _ in
            self.filteredFiles = explorerViewModel.suggestableFiles(query: self.fileSuggestionQuery)
        }
        .animation(.spring(), value: mainViewModel.attachedFiles.count)
        .animation(.easeInOut(duration: 0.15), value: currentDynamicButtonMode)
        .animation(.easeInOut(duration: 0.15), value: inputViewModel.voiceInputState)
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
    }

    private var editorAndPlaceholderArea: some View {
        ZStack(alignment: .topLeading) {
            CustomTextEditor(
                // --- UPDATED: Binds to the new inputViewModel ---
                text: $inputViewModel.userInput,
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
        if mainViewModel.selectedBackend == .none { return "Please select a backend to begin..." }
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
                    .foregroundColor(isPlusButtonHovering ? .accentColor : .secondary) // Hover effect
                    .scaleEffect(isPlusButtonHovering ? 1.1 : 1.0) // Hover effect
                    .animation(.easeOut(duration: 0.1), value: isPlusButtonHovering) // Animation
            }
            .buttonStyle(.plain)
            .onHover { hover in // On hover modifier
                isPlusButtonHovering = hover
            }
            .help("Attach files")

            Button { logger.info("Internet Search (globe) icon tapped - No functionality") } label: {
                Image(systemName: "globe")
                    .resizable().scaledToFit().frame(width: iconSize, height: iconSize)
                    .foregroundColor(isGlobeButtonHovering ? .accentColor : .secondary) // Hover effect
                    .scaleEffect(isGlobeButtonHovering ? 1.1 : 1.0) // Hover effect
                    .animation(.easeOut(duration: 0.1), value: isGlobeButtonHovering) // Animation
            }
            .buttonStyle(.plain)
            .onHover { hover in // On hover modifier
                isGlobeButtonHovering = hover
            }
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
            .background(Color.gray.opacity(isBackendPickerHovering ? 0.25 : 0.15)) // Hover effect
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(profileButtonBorderColor.opacity(isBackendPickerHovering ? 1.0 : 0.7), lineWidth: 1) // Hover effect
            )
            .animation(.easeOut(duration: 0.1), value: isBackendPickerHovering) // Animation
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
        .onHover { hover in // On hover modifier
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
                        onSendMessage(NSAttributedString(string: inputViewModel.userInput, attributes: defaultTypingAttributes))
                    }
                    return
                }
                let textToSend = textView.attributedString()
                if !textToSend.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty {
                    onSendMessage(textToSend)
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
                    // --- UPDATED: Reads from local input view model ---
                    let canSend = mode == .send && (!inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !mainViewModel.attachedFiles.isEmpty)
                    let isDisabledBySystem = showSettings || (mode == .send && (inputViewModel.voiceInputState == .processing || inputViewModel.voiceInputState == .recording))

                    Circle()
                        // Adjust background color based on hover state
                        .fill(buttonBackgroundColor(for: mode, canSend: canSend, isDisabledBySystem: isDisabledBySystem)
                              .opacity(isDynamicButtonHovering ? 0.8 : 1.0)) // Slightly reduce opacity on hover
                        .animation(.easeOut(duration: 0.1), value: isDynamicButtonHovering) // Smooth transition

                    Image(systemName: dynamicActionButtonIconName(for: mode))
                        .resizable().scaledToFit()
                        .fontWeight(buttonIconWeight(for: mode))
                        .frame(width: dynamicButtonSize * buttonIconScale(for: mode), height: dynamicButtonSize * buttonIconScale(for: mode))
                        // Adjust foreground color based on hover state
                        .foregroundColor(buttonIconForegroundColor(for: mode))
                        .scaleEffect(isDynamicButtonHovering ? 1.1 : 1.0) // Subtle scale effect on hover
                        .animation(.easeOut(duration: 0.1), value: isDynamicButtonHovering) // Smooth transition
                }
                .frame(width: dynamicButtonSize, height: dynamicButtonSize)
            }
        }
        .buttonStyle(PlainButtonStyle())
        // Add the .onHover modifier here
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
            return (isDisabledBySystem || inputViewModel.voiceInputState != .idle) ? Color.gray.opacity(0.3) : Color(NSColor.controlAccentColor)
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
            case .permissionsDeniedMic, .permissionsDeniedSpeech, .speechRecognitionUnavailable, .error: return .red.opacity(0.7)
            case .requestingPermissions: return .orange
            default:
                // Changed to white for better contrast with the new background
                return .white
            }
        }
    }

    private func isDynamicButtonDisabled(for mode: DynamicButtonMode) -> Bool {
        if mainViewModel.selectedBackend == .none { return true }
        switch mode {
        case .send:
            // --- UPDATED: Reads from local input view model ---
            let isEmptyTextAndNoFiles = inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mainViewModel.attachedFiles.isEmpty
            return isEmptyTextAndNoFiles || isSending || showSettings || inputViewModel.voiceInputState == .recording || inputViewModel.voiceInputState == .processing
        case .stop:
            return isSending || showSettings
        case .mic:
            // --- UPDATED: Reads from local input view model ---
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
            case .permissionsDeniedSpeech: return "Speech recognition permission denied. Click to re-check."
            case .speechRecognitionUnavailable: return "Speech recognition is currently unavailable. Click to re-check."
            case .error(let specificError): return "Voice input error: \(specificError.prefix(30))... Click to re-check."
            default: return "Voice Input"
            }
        }
    }

    // MARK: - File & Prompt Handling
    private func handleFileSelection(_ file: FileSystemItem) {
        mainViewModel.addAttachedFile(fileItem: file)

        if let range = activeFileMentionTriggerRange {
            let insertionText = NSAttributedString(string: file.name + " ", attributes: defaultTypingAttributes)
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
