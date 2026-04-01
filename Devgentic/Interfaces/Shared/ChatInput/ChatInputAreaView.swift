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

enum SuggestionNavigationDirection { case up, down }

struct ChatInputAreaView: View {

    @StateObject private var inputViewModel = ChatInputViewModel()

    @Binding var showContextArea: Bool
    @Binding var activeContextFilePath: String?

    let isSending: Bool
    var isInputFocused: FocusState<Bool>.Binding

    @ObservedObject var backendConfiguration: BackendConfiguration

    let onSendMessage: (NSAttributedString, BackendRequestConfig) -> Void
    let onToggleContext: () -> Void

    @EnvironmentObject private var explorerViewModel: ExplorerViewModel
    @EnvironmentObject private var mainViewModel: MainApplicationViewModel // retained only for delegate wiring & APIKeyInputPopup sheet
    @EnvironmentObject private var router: MainViewRouter
    @Environment(\.appTheme) private var theme

    // MARK: - UI State
    @State private var showingBackendSelectorPopup: Bool = false
    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil
    @State private var selectedProfile: BackendProfileModel?
    @State private var showingSchedulePopover = false
    @State private var showingFullScheduleCreator = false

    // MARK: - Layout Constants
    private let textEditorMinHeight: CGFloat = 32
    private let textEditorMaxHeight: CGFloat = 200

    private var isInputEnabled: Bool {
        let isQueryInProgress = isSending || inputViewModel.isStreaming
        return !isQueryInProgress
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
    
    // Separate property for placeholder font to avoid creating mutable objects during view updates
    private var placeholderFont: Font {
        Font.system(size: 14)
    }

    // MARK: - Dynamic UI Properties
    private var profileThemeColor: Color {
        guard let profile = selectedProfile else { return .secondary }
        switch profile.profileType {
        case .bot: return .blue
        case .agent: return .green
        case .workflow: return .purple
        case .imageGen: return .orange
        }
    }

    private var profileButtonText: String {
        selectedProfile?.displayName ?? "Select Backend"
    }

    private var hasInputText: Bool {
        !inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentDynamicButtonMode: DynamicButtonMode {
        if inputViewModel.isStreaming { return .stopStreaming }
        if inputViewModel.voiceInputState == .recording || inputViewModel.voiceInputState == .finalizingSilence { return .stopVoice }
        if hasInputText { return .send }
        return .mic
    }

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
                attachedFiles: inputViewModel.attachedFiles,
                onRemoveFile: { fileItem in
                    inputViewModel.removeAttachedFile(fileItem: fileItem)
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
        // MARK: - File Drop Zone (P1)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }

        // MARK: - Wiring
        .onAppear {
            updateSelectedProfile(profileID: backendConfiguration.selectedProfileID)

            // Wire delegate so ChatInputViewModel can mediate MainApplicationViewModel
            inputViewModel.mainDelegate = mainViewModel
            inputViewModel.setupMainDelegateObservers()

            // CONNECT DATA SOURCE TO VM (This fixes the missing file suggestions)
            inputViewModel.onFileSearchRequest = { [weak explorerViewModel, weak inputViewModel] query in
                let candidates = explorerViewModel?.suggestableFiles(query: query) ?? []
                let attached = inputViewModel?.attachedFiles ?? []
                return (candidates, attached)
            }
        }
        .onChange(of: backendConfiguration.selectedProfileID) { _, newID in updateSelectedProfile(profileID: newID) }

        // Refresh files if Explorer/Context changes (Lazy refresh)
        .onReceive(explorerViewModel.objectWillChange) { _ in
            if inputViewModel.fileSuggestionState.isShowing {
                inputViewModel.refreshFileSuggestions(using: explorerViewModel)
            }
        }
        
        .sheet(isPresented: $inputViewModel.showAPIKeyInputPopup, onDismiss: {
            inputViewModel.resetAPIKeyPopupState()
        }) {
            APIKeyInputPopup()
                .environmentObject(mainViewModel)
                .environmentObject(inputViewModel)
        }
        .animation(.spring(), value: inputViewModel.attachedFiles.count)
        .animation(.easeInOut(duration: 0.2), value: inputViewModel.voiceInputState)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingFullScheduleCreator) {
            CreateScheduledTaskView(prefillPrompt: inputViewModel.userInput)
        }
    }
    
    private func updateSelectedProfile(profileID: UUID?) {
        if let id = profileID {
            self.selectedProfile = (try? BackendProfileStore.shared.fetchProfiles())?.first { $0.id == id }
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
                    if let historicalQuery = inputViewModel.getQueryFromHistory(direction: direction) {
                        DispatchQueue.main.async {
                            inputViewModel.userInput = historicalQuery
                            editorTextView?.setSelectedRange(NSRange(location: historicalQuery.count, length: 0))
                        }
                    }
                },
                onTextManuallyChanged: {
                    inputViewModel.resetQueryHistoryIndex()
                }
            )
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)
            
            if inputViewModel.userInput.isEmpty {
                // Use fixed constants matching makeNSView setup (lineFragmentPadding=5,
                // textContainerInset.width=2, textContainerInset.height=10) instead of
                // reading from the optional textView ref which is nil on first render.
                Text(placeholderText)
                    .font(placeholderFont)
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
        if !inputViewModel.attachedFiles.isEmpty { return "Ask about context..." }
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
            InputToolbarView(
                isInputEnabled: isInputEnabled,
                selectedProfile: selectedProfile,
                selectedProfileID: backendConfiguration.selectedProfileID,
                promptText: inputViewModel.userInput,
                onOpenFilePicker: openFilePicker,
                onNavigateToToolLibrary: { profileID in
                    router.navigate(to: .toolLibrary(profileID: profileID))
                },
                showingSchedulePopover: $showingSchedulePopover,
                showingFullScheduleCreator: $showingFullScheduleCreator
            )

            Spacer()

            BackendPickerButton(
                profileThemeColor: profileThemeColor,
                profileButtonText: profileButtonText,
                backendConfiguration: backendConfiguration,
                showingPopup: $showingBackendSelectorPopup
            )
            .disabled(!isInputEnabled)
            .opacity(isInputEnabled ? 1.0 : 0.5)

            DynamicActionButton(
                mode: currentDynamicButtonMode,
                isSending: isSending,
                isStreamingActive: inputViewModel.isStreaming,
                userInput: inputViewModel.userInput,
                voiceInputState: inputViewModel.voiceInputState,
                defaultTypingAttributes: defaultTypingAttributes,
                editorTextView: editorTextView,
                backendProfileSelected: backendConfiguration.selectedProfileID != nil,
                inputViewModel: inputViewModel,
                onSend: { attributedString, _ in
                    guard let config = backendConfiguration.getRequestConfig() else {
                        logger.error("Send button: Could not get backend config."); return
                    }
                    onSendMessage(attributedString, config)
                    inputViewModel.userInput = ""
                },
                onToggleVoice: { inputViewModel.toggleVoiceInput() },
                onStopStreaming: { inputViewModel.cancelStreamingResponse() }
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
    
    // MARK: - Handlers
    
    // MARK: - File Drop Handler (P1)
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var fileItems: [FileSystemItem] = []

        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                // Skip video files
                if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
                   type.conforms(to: .video) || type.conforms(to: .movie) {
                    return
                }
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    let newItem = FileSystemItem(
                        id: url,
                        name: url.lastPathComponent,
                        url: url,
                        isDirectory: isDirectory.boolValue
                    )
                    DispatchQueue.main.async { [self] in
                        inputViewModel.addAttachedFile(fileItem: newItem)
                    }
                }
            }
        }

        return true
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
                    inputViewModel.addAttachedFiles(fileItems: fileItems)
                }
            }
        }
    }
    
    private func confirmSuggestionSelection() {
        if inputViewModel.fileSuggestionState.isShowing {
            let multiSelected = inputViewModel.fileSuggestionState.multiSelectedIDs

            if !multiSelected.isEmpty {
                let filesToAttach = inputViewModel.fileSuggestionState.filteredItems.filter { multiSelected.contains($0.id) }
                if !filesToAttach.isEmpty {
                    logger.log("Attaching \(filesToAttach.count) files from multi-selection.")
                    inputViewModel.addAttachedFiles(fileItems: filesToAttach)
                    inputViewModel.selectMultipleFiles(filesToAttach)
                }
            }
            else if let selectedID = inputViewModel.fileSuggestionState.selectedID,
                    let selectedFile = inputViewModel.fileSuggestionState.filteredItems.first(where: { $0.id == selectedID }) {
                logger.log("Attaching single focused file: \(selectedFile.name)")
                inputViewModel.addAttachedFile(fileItem: selectedFile)
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
                if case .agent(let config) = selectedProfile?.details {
                    return config.tools
                }
                return []
            },
            set: { newTools in
                guard var profile = selectedProfile else { return }
                if case .agent(var config) = profile.details {
                    config.tools = newTools
                    profile.details = .agent(config)
                    selectedProfile = profile
                    // Persist change via shared store
                    try? BackendProfileStore.shared.saveProfile(profile)
                }
            }
        )
    }

    private var profileInstructions: String {
        if case .agent(let config) = selectedProfile?.details {
            return config.instructions ?? ""
        }
        return ""
    }
}
