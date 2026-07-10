//
//  ChatInputAreaView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os
import AppKit
import UniformTypeIdentifiers

private let logger = DGLogger(category: "ChatInputAreaUI_V2")

enum SuggestionNavigationDirection { case up, down }

struct ChatInputAreaView: View {

    /// VM is app-scoped via DevgenticApp environment injection. Previously this
    /// was `@State private var inputViewModel = ChatInputViewModel()`, which
    /// caused a fresh VM on every ChatInputAreaView recreation — re-requesting
    /// mic permission, re-subscribing to WhisperKit loading state, and stacking
    /// `setupMainDelegateObservers()` chains on the MainApplicationViewModel.
    @Environment(ChatInputViewModel.self) private var inputViewModel

    @Binding var showContextArea: Bool
    @Binding var activeContextFilePath: String?

    let isSending: Bool
    var isInputFocused: FocusState<Bool>.Binding

    var backendConfiguration: BackendConfiguration

    let onSendMessage: (NSAttributedString, BackendRequestConfig) -> Void
    let onToggleContext: () -> Void

    @Environment(ExplorerViewModel.self) private var explorerViewModel
    @Environment(MainApplicationViewModel.self) private var mainViewModel // retained only for delegate wiring & APIKeyInputPopup sheet
    @Environment(CodeSessionManager.self) private var codeSessionManager
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - UI State
    @State private var showingBackendSelectorPopup: Bool = false
    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil
    @State private var selectedProfile: BackendProfileModel?
    @State private var showingSchedulePopover = false

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
        selectedProfile?.profileType.displayColor ?? .secondary
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
        // Shadow the environment VM with a @Bindable local so `$inputViewModel.foo`
        // binding syntax keeps working exactly as it did with `@State`.
        @Bindable var inputViewModel = inputViewModel

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
        .onChange(of: explorerViewModel.rootItems.count) { _, _ in
            if inputViewModel.fileSuggestionState.isShowing {
                inputViewModel.refreshFileSuggestions(using: explorerViewModel)
            }
        }
        
        .sheet(isPresented: $inputViewModel.showAPIKeyInputPopup, onDismiss: {
            inputViewModel.resetAPIKeyPopupState()
        }) {
            APIKeyInputPopup()
                .environment(mainViewModel)
                .environment(inputViewModel)
        }
        .animation(.spring(), value: inputViewModel.attachedFiles.count)
        .animation(.easeInOut(duration: 0.2), value: inputViewModel.voiceInputState)
        // The suggestion panels declare move+opacity transitions, but insertion/removal
        // only animates when the isShowing flip itself is animated at this container —
        // without these the panels snap in. Reduce Motion keeps the instant swap.
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: inputViewModel.promptSuggestionState.isShowing)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: inputViewModel.fileSuggestionState.isShowing)
        .fixedSize(horizontal: false, vertical: true)
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
        // Liquid Glass material (matches the banners/pickers around it, no longer the one opaque
        // bottom surface) with a quiet hairline for edge definition. The accent focus ring was
        // removed by design choice — with vivid accent colors it read as a loud colored border.
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(theme.surfaceOverlay, lineWidth: 1)
        )
        .transition(.opacity)
    }

    private var editorAndPlaceholderArea: some View {
        // Shadow the environment VM with a @Bindable local so `$inputViewModel.*`
        // binding syntax works inside this computed property scope.
        @Bindable var inputViewModel = inputViewModel

        return ZStack(alignment: .topLeading) {
            CustomTextEditor(
                text: $inputViewModel.userInput,
                onCommit: { attributedString in
                    guard isInputEnabled else { return }
                    // Code mode: intercept if model or folder not configured,
                    // then point selectedProfileID at the code profile so getRequestConfig resolves.
                    if mainViewModel.interfaceMode == .code {
                        if codeSessionManager.modelName.isEmpty {
                            logger.info("[CODE] Send intercepted — model not selected, opening model picker")
                            codeSessionManager.showModelPicker = true
                            return
                        }
                        if codeSessionManager.projectPath == nil {
                            logger.info("[CODE] Send intercepted — folder not selected, opening folder picker")
                            openCodeFolderPicker()
                            return
                        }
                        if let codeID = codeSessionManager.codeProfileID {
                            backendConfiguration.selectedProfileID = codeID
                        }
                    }
                    // Chat / Workflow modes: intercept if no backend profile is
                    // selected so the user isn't silently stuck (previously the
                    // send just logged a warning and nothing happened). Mirrors
                    // the code-mode model/folder picker pattern.
                    if mainViewModel.interfaceMode == .chat || mainViewModel.interfaceMode == .workflow {
                        if backendConfiguration.selectedProfileID == nil {
                            logger.info("[\(mainViewModel.interfaceMode.rawValue)] Send intercepted — no backend selected, opening picker")
                            showingBackendSelectorPopup = true
                            return
                        }
                    }
                    if let config = backendConfiguration.getRequestConfig() {
                        self.onSendMessage(attributedString, config)
                        self.inputViewModel.userInput = ""
                    } else {
                        logger.warning("Commit triggered but no backend profile is selected.")
                        showingBackendSelectorPopup = true
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
        // When an external caller (prompt library "Use in Chat") stages text,
        // the VM flips `pendingInputFocusRequest` so this editor grabs focus
        // on the next render. The reset is deferred one runloop tick so it
        // doesn't fire back into SwiftUI's update cycle inside the same
        // frame — which would cause extra `updateNSView` passes that can
        // race the text-binding sync-back and wipe inserted content.
        .onChange(of: inputViewModel.pendingInputFocusRequest) { _, newValue in
            guard newValue else { return }
            isInputFocused.wrappedValue = true
            DispatchQueue.main.async {
                inputViewModel.pendingInputFocusRequest = false
            }
        }
    }

    private var placeholderText: String {
        // Code mode uses its own profile via CodeSessionManager — skip the "Select a backend" check.
        if mainViewModel.interfaceMode != .code && backendConfiguration.selectedProfileID == nil { return "Select a backend..." }
        if !inputViewModel.attachedFiles.isEmpty { return "Ask about context..." }
        if inputViewModel.userInput.isEmpty {
            switch inputViewModel.voiceInputState {
                case .recording: return "Listening..."
                case .processing: return "Processing..."
                case .finalizingSilence: return "Finalizing..."
                case .error: return "Voice error..."
                default:
                    switch mainViewModel.interfaceMode {
                    case .workflow: return "Enter workflow input..."
                    case .code:     return "Ask about your code..."
                    case .chat:     return "Type a message..."
                    }
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
                interfaceMode: mainViewModel.interfaceMode,
                onOpenFilePicker: openFilePicker,
                onNavigateToToolLibrary: { profileID in
                    router.navigate(to: .toolLibrary(profileID: profileID))
                },
                onSelectFolder: mainViewModel.interfaceMode == .code ? { openCodeFolderPicker() } : nil,
                onSelectRecentFolder: mainViewModel.interfaceMode == .code ? { url in applyCodeFolderSelection(url) } : nil,
                onSelectCodeFile: mainViewModel.interfaceMode == .code ? { openCodeFilePicker() } : nil,
                showingSchedulePopover: $showingSchedulePopover,
                currentConversationID: mainViewModel.selectedConversationID,
                onCustomSchedule: {
                    router.navigateToNewTask(
                        prefillPrompt: inputViewModel.userInput,
                        prefillConversationID: mainViewModel.selectedConversationID
                    )
                }
            )

            Spacer()

            if mainViewModel.interfaceMode == .code {
                CodeModelPickerButton()
                    .disabled(!isInputEnabled)
                    .opacity(isInputEnabled ? 1.0 : 0.5)
            } else {
                BackendPickerButton(
                    profileThemeColor: profileThemeColor,
                    profileButtonText: profileButtonText,
                    backendConfiguration: backendConfiguration,
                    allowedProfileTypes: mainViewModel.interfaceMode.allowedProfileTypes,
                    showingPopup: $showingBackendSelectorPopup
                )
                .disabled(!isInputEnabled)
                .opacity(isInputEnabled ? 1.0 : 0.5)
            }

            DynamicActionButton(
                mode: currentDynamicButtonMode,
                isSending: isSending,
                isStreamingActive: inputViewModel.isStreaming,
                userInput: inputViewModel.userInput,
                voiceInputState: inputViewModel.voiceInputState,
                defaultTypingAttributes: defaultTypingAttributes,
                editorTextView: editorTextView,
                backendProfileSelected: mainViewModel.interfaceMode == .code
                    ? codeSessionManager.isConfigured
                    : backendConfiguration.selectedProfileID != nil,
                inputViewModel: inputViewModel,
                onSend: { attributedString, _ in
                    // Code mode: intercept if model or folder not configured,
                    // then point selectedProfileID at the code profile so getRequestConfig resolves.
                    if mainViewModel.interfaceMode == .code {
                        if codeSessionManager.modelName.isEmpty {
                            logger.info("[CODE] Send button intercepted — model not selected, opening model picker")
                            codeSessionManager.showModelPicker = true
                            return
                        }
                        if codeSessionManager.projectPath == nil {
                            logger.info("[CODE] Send button intercepted — folder not selected, opening folder picker")
                            openCodeFolderPicker()
                            return
                        }
                        if let codeID = codeSessionManager.codeProfileID {
                            backendConfiguration.selectedProfileID = codeID
                        }
                    }
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
    
    // MARK: - File Drop Handler (P1) — [Q8] shared with the QuickAccess panel via FileAttachmentPicker.
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        FileAttachmentPicker.handleDrop(providers) { item in
            inputViewModel.addAttachedFile(fileItem: item)
        }
    }

    private func openFilePicker() {
        FileAttachmentPicker.presentOpenPanel(prompt: "Attach Files or Folders") { items in
            inputViewModel.addAttachedFiles(fileItems: items)
        }
    }
    
    private func openCodeFolderPicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Select Project Folder"
        openPanel.message = "Choose a folder for your Code session."

        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                Task { @MainActor in
                    applyCodeFolderSelection(url)
                }
            }
        }
    }

    /// Applies a project folder selection — whether from NSOpenPanel or the Recent list.
    /// Updates the Explorer sidebar and triggers context.md bootstrap + recents tracking.
    @MainActor
    private func applyCodeFolderSelection(_ url: URL) {
        explorerViewModel.selectedRootURL = url
        explorerViewModel.loadDirectoryContents(for: url)
        codeSessionManager.updateProjectPath(url)
    }

    /// Code-mode file attachment picker. Hard-whitelists docs/code/images so the
    /// user can't attach video or unsupported binaries — we'd fail to extract them
    /// and waste a round-trip.
    private func openCodeFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = "Attach Files"
        openPanel.message = "Attach documents, code, or images."
        openPanel.allowedContentTypes = Self.codeInterfaceAllowedFileTypes

        openPanel.begin { response in
            guard response == .OK else { return }
            let urls = openPanel.urls
            var fileItems: [FileSystemItem] = []
            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                fileItems.append(FileSystemItem(
                    id: url,
                    name: url.lastPathComponent,
                    url: url,
                    isDirectory: false
                ))
            }
            if !fileItems.isEmpty {
                DispatchQueue.main.async {
                    inputViewModel.addAttachedFiles(fileItems: fileItems)
                }
            }
        }
    }

    /// UTTypes accepted by `openCodeFilePicker`: broad buckets (images, source code,
    /// plain text, PDF) plus explicit per-extension entries for document formats
    /// supported by DocumentExtractionRegistry and code extensions UTType may not
    /// recognize on all OS versions (md, yaml, kt, etc.).
    private static let codeInterfaceAllowedFileTypes: [UTType] = {
        var types: [UTType] = [.image, .sourceCode, .text, .plainText, .pdf]

        // Document formats FileProcessor can extract text from.
        let docExtensions = DocumentExtractionRegistry.shared.allSupportedExtensions
        // Code extensions that aren't always caught by UTType.sourceCode.
        let extraCodeExtensions: Set<String> = [
            "swift", "kt", "kts", "scala", "rs", "go", "rb", "php", "lua", "r",
            "md", "markdown", "yaml", "yml", "toml", "hcl", "tf", "dockerfile",
            "gradle", "properties", "gitignore", "sh", "pl", "pm"
        ]

        for ext in docExtensions.union(extraCodeExtensions) {
            if let utType = UTType(filenameExtension: ext) {
                types.append(utType)
            }
        }
        // Deduplicate while preserving first-seen order.
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }()

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

}
