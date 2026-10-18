// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// The chat input view model, app-scoped via environment injection so recreating this view does not recreate the VM
    /// (mic permission, WhisperKit subscriptions, delegate observers).
    @Environment(ChatInputViewModel.self) private var inputViewModel

    @Binding var showContextArea: Bool
    @Binding var activeContextFilePath: String?

    let isSending: Bool
    var isInputFocused: FocusState<Bool>.Binding

    var backendConfiguration: BackendConfiguration

    let onSendMessage: (NSAttributedString, BackendRequestConfig) -> Void
    let onToggleContext: () -> Void

    @Environment(ExplorerViewModel.self) private var explorerViewModel
    @Environment(MainApplicationViewModel.self) private var mainViewModel // retained only for delegate wiring
    @Environment(CodeSessionManager.self) private var codeSessionManager
    // Source of the conversation's messages (the context gauge's history size) and the newest turn's real token usage;
    // app-scoped and injected at the app root.
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(MainViewRouter.self) private var router
    /// Used only to resolve a profile for the MCP banner's Tool Library navigation, which is
    /// per-profile even though MCP health is not.
    @Environment(BackendProfileService.self) private var profileService
    /// A refused send has to say so somewhere the user is already looking (register A32).
    /// Injected at the `WindowGroup`, which is this view's only call site.
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.appTheme) private var theme
    @Environment(\.surfaceStyle) private var surfaceStyle
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - UI State
    @State private var showingBackendSelectorPopup: Bool = false
    @State private var editorTextView: CustomTextEditor.CustomNSTextView? = nil
    @State private var selectedProfile: BackendProfileModel?
    // Why: not `draftKey`: on a switch both change in one pass and SwiftUI does not order the handlers, so the old
    // conversation's text could be filed under the new one.
    /// The draft key the composer's content belongs to; moved only by the swap below. Save-as-you-type writes under this
    /// key.
    @State private var liveDraftKey: ComposerDraftStore.Key?
    @State private var showingSchedulePopover = false
    @State private var isDropTargeted: Bool = false
    /// [Context gauge] Occupancy of the selected model's window for THIS conversation
    /// (nil = non-chat profile, so the ring self-hides). Recomputed on turn / model /
    /// attachment changes — never per keystroke — so it stays cheap on long transcripts.
    @State private var contextUsage: ContextWindowUsage?

    // Why: read by both the picker and the send-path rewrite so an offered skill is always expandable.
    /// What a `/` command can offer and expand on the selected profile. Computed, not stored, and read only on a trigger
    /// change or a send, never from `body`.
    private var skillCommandOffer: SkillCommandOffer {
        SkillCommandReachability.offer(in: selectedProfile?.details)
    }

    // MARK: - Layout Constants
    private var textEditorMinHeight: CGFloat {
        max(44, themeManager.chatFontSize + 24)
    }
    private let textEditorMaxHeight: CGFloat = 200

    private var isInputEnabled: Bool {
        let isQueryInProgress = isSending || inputViewModel.isStreaming
        return !isQueryInProgress
    }

    // MARK: - Typography
    private var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = themeManager.chatLineSpacing
        return [
            .font: NSFont.systemFont(ofSize: themeManager.chatFontSize),
            .foregroundColor: NSColor(theme.primaryText),
            .paragraphStyle: paragraphStyle
        ]
    }
    
    // Separate property for placeholder font to avoid creating mutable objects during view updates
    private var placeholderFont: Font {
        themeManager.chatFont
    }

    // MARK: - Dynamic UI Properties
    private var profileThemeColor: Color {
        selectedProfile?.profileType.displayColor ?? .secondary
    }

    private var profileButtonText: String {
        selectedProfile?.displayName ?? String(localized: "Select Backend")
    }

    private var hasInputText: Bool {
        !inputViewModel.userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // [Composer parity] The voice button is voice-ONLY now (send split into its own button,
    // matching the QuickAccess panel): .mic or .stopVoice, never .send/.stopStreaming.
    private var voiceButtonMode: DynamicButtonMode {
        (inputViewModel.voiceInputState == .recording || inputViewModel.voiceInputState == .finalizingSilence) ? .stopVoice : .mic
    }

    /// Whether voice is mid-capture or mid-transcription; sending then would race the in-flight transcript into the next
    /// message. Shared by the send button and the Enter key, so their gates cannot diverge.
    private var isVoiceBusy: Bool {
        inputViewModel.voiceInputState == .recording
            || inputViewModel.voiceInputState == .processing
            || inputViewModel.voiceInputState == .finalizingSilence
    }

    private var sendButtonDisabled: Bool {
        if inputViewModel.isStreaming { return false }
        let profileOK = mainViewModel.interfaceMode == .code
            ? codeSessionManager.isConfigured
            : backendConfiguration.selectedProfileID != nil
        return !profileOK || !hasInputText || isSending || isVoiceBusy
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
            
            // Skill command picker, driven by VM state. Gated on the profile kind as well as the trigger: a bot or imageGen run
            // registers no `load_skill`, so offering the picker there promises something it cannot do.
            if inputViewModel.skillSuggestionState.isShowing,
               SkillCommandReachability.pickerApplies(to: selectedProfile?.details) {
                SkillCommandSuggestionView(
                    items: inputViewModel.skillSuggestionState.filteredItems,
                    collisionNotes: inputViewModel.skillSuggestionState.collisionNotes,
                    query: inputViewModel.skillSuggestionState.query,
                    selectedItemID: $inputViewModel.skillSuggestionState.selectedID,
                    onSelect: { inputViewModel.selectSkillCommand($0) }
                )
                .padding(.horizontal, 15)
                .padding(.bottom, 6)
            }

            // FILE SUGGESTIONS (Driven by VM State)
            if inputViewModel.fileSuggestionState.isShowing {
                FileSuggestionView(
                    files: inputViewModel.fileSuggestionState.filteredItems,
                    suggestionQuery: inputViewModel.fileSuggestionState.query,
                    source: inputViewModel.fileSuggestionState.source,
                    hasResults: inputViewModel.fileSuggestionState.hasResults,
                    selectedItemID: $inputViewModel.fileSuggestionState.selectedID,
                    multiSelectedFileIDs: $inputViewModel.fileSuggestionState.multiSelectedIDs
                )
                .padding(.horizontal, 15)
                .padding(.bottom, 6)
            }

            if !inputViewModel.deliveryWarnings.isEmpty {
                DeliveryWarningPanel(warnings: inputViewModel.deliveryWarnings)
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
        .frame(maxWidth: ViewLayout.maxContentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        // Wires the hosting window to the VM so the app-wide ⌘⇧V shortcut applies only when this window is key, and stops
        // live dictation when the composer leaves the hierarchy.
        .background(ComposerWindowReader { window in
            inputViewModel.composerWindow = window
        })
        .onDisappear {
            inputViewModel.handleComposerDismantled()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openFilePicker"))) { _ in
            openFilePicker()
        }
        // MARK: - File Drop Zone
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }

        // MARK: - Wiring
        .onAppear {
            updateSelectedProfile(profileID: backendConfiguration.selectedProfileID)
            recomputeContextGauge()

            // Drafts persist across launches: restore this mode's draft into an empty composer.
            liveDraftKey = draftKey
            if inputViewModel.userInput.isEmpty && mainViewModel.attachedFiles.isEmpty {
                let saved = ComposerDraftStore.shared.draft(for: draftKey)
                if !saved.isEmpty {
                    inputViewModel.userInput = saved.text
                    mainViewModel.attachedFiles = saved.attachments
                }
            }

            // Wire delegate so ChatInputViewModel can mediate MainApplicationViewModel
            inputViewModel.mainDelegate = mainViewModel
            inputViewModel.setupMainDelegateObservers()

            // CONNECT DATA SOURCE TO VM (This fixes the missing file suggestions)
            inputViewModel.onFileSearchRequest = { [weak explorerViewModel, weak inputViewModel] query in
                let candidates = explorerViewModel?.suggestableFiles(query: query) ?? []
                let attached = inputViewModel?.attachedFiles ?? []
                return (candidates, attached, explorerViewModel.map { FileSuggestionSource.of($0) } ?? .noFolder)
            }
        }
        .onChange(of: backendConfiguration.selectedProfileID) { _, newID in
            updateSelectedProfile(profileID: newID)
            evaluatePreSendFit()
            // Model changed → the gauge's DENOMINATOR (window) changed. Same conversation
            // can jump from 24% to 100%+ on a switch to a smaller-window model.
            recomputeContextGauge()
        }
        // Surfaces the context-overflow advisory as soon as attachments imply the prompt will not fit. Count-keyed because
        // `FileSystemItem` is not Equatable.
        .onChange(of: inputViewModel.attachedFiles.count) { _, _ in
            evaluatePreSendFit()
            recomputeContextGauge()
        }

        // Per-conversation drafts: saves under the outgoing key and restores the incoming one, keyed on mode plus
        // conversation (every mode's Home is conversation `nil`).
        .onChange(of: draftKey) { oldKey, newKey in
            guard oldKey != newKey else { return }
            ComposerDraftStore.shared.save(
                .init(text: inputViewModel.userInput, attachments: mainViewModel.attachedFiles),
                for: oldKey
            )
            let incoming = ComposerDraftStore.shared.draft(for: newKey)
            inputViewModel.userInput = incoming.text
            // Write the SOURCE of truth: `ChatInputViewModel.attachedFiles` is a
            // `private(set)` mirror that its observation stream keeps in sync from here.
            mainViewModel.attachedFiles = incoming.attachments
            liveDraftKey = newKey
            // A new conversation has a different history size, so occupancy is recomputed; this clears the outgoing chat's
            // number immediately.
            recomputeContextGauge()
        }

        // Save as you type (the store coalesces writes), so a quit or crash keeps the draft.
        .onChange(of: draftContentSignature) { _, _ in
            ComposerDraftStore.shared.save(
                .init(text: inputViewModel.userInput, attachments: mainViewModel.attachedFiles),
                for: liveDraftKey ?? draftKey)
        }

        // Re-searches an open `@` picker when the folder, its index or the indexing state changes.
        .onChange(of: fileIndexKey) { _, _ in
            if inputViewModel.fileSuggestionState.isShowing {
                inputViewModel.refreshFileSuggestions(using: explorerViewModel)
            }
        }

        // One onChange on a combined signature of the cheap recompute signals (turn added, streaming settled, mode switch,
        // code-folder swap); separate onChanges exceed the type-checker's budget.
        .onChange(of: contextGaugeTriggerKey) { _, _ in recomputeContextGauge() }
        // Re-check attachments whenever the profile a send would use changes, or the set
        // changes underneath intake (a restored draft writes `attachedFiles` directly).
        .onChange(of: attachmentRecheckKey) { _, _ in
            let profile = activeProfile()
            let mode = profile.map { AttachmentDeliveryMode.resolve(for: $0) }
            reportRefusedAttachments(inputViewModel.recheckAttachments(deliveryMode: mode), removed: true)
            // Same trigger: what survives intake may still be CUT — say so before the send.
            inputViewModel.refreshDeliveryWarnings(mode: mode, profileType: profile?.profileType)
        }
        
        .animation(.spring(), value: inputViewModel.attachedFiles.count)
        .animation(.easeInOut(duration: 0.2), value: inputViewModel.voiceInputState)
        // Suggestion panel insertion/removal only animates when the isShowing flip is animated at this container; Reduce
        // Motion keeps the instant swap.
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

    /// [Pre-send fit hint] Posts/clears the shared context-overflow advisory from
    /// composer state (stat-based estimate); the send-time check refines it.
    private func evaluatePreSendFit() {
        // In Code mode `selectedProfile` is not the code profile (`selectedProfileID` points at it only during send), so
        // resolve the real one.
        let profile: BackendProfileModel?
        if mainViewModel.interfaceMode == .code, let codeID = codeSessionManager.codeProfileID {
            profile = try? BackendProfileStore.shared.fetchProfile(byId: codeID)
        } else {
            profile = selectedProfile
        }

        PreSendFitHint.evaluate(
            attachedFiles: inputViewModel.attachedFiles,
            typedText: inputViewModel.userInput,
            profile: profile,
            conversationID: mainViewModel.selectedConversationID
        )
    }

    /// Size of Code mode's per-run project knowledge (`AGENTS.md` plus the memory listing), 0 outside Code mode. Code
    /// adds it to the system prompt on every message, a fixed cost the generic estimate cannot see.
    private var codeProjectContextChars: Int {
        guard mainViewModel.interfaceMode == .code else { return 0 }
        return codeSessionManager.projectKnowledgeContent?.count ?? 0
    }

    /// In-flight gauge resolution, cancelled on each recompute so bursty triggers cannot
    /// land out of order.
    @State private var contextGaugeTask: Task<Void, Never>?

    /// One combined key over every cheap recompute signal (turn count, streaming, mode, code project-context size), so a
    /// single `onChange` covers them. The composer's content, for save-as-you-type.
    private var draftContentSignature: String {
        inputViewModel.userInput + "\u{1}" + mainViewModel.attachedFiles.map(\.url.path).joined(separator: "\u{2}")
    }

    /// Everything that changes what the `@` picker would list.
    private var fileIndexKey: String {
        "\(explorerViewModel.selectedRootURL?.path ?? "-")|\(explorerViewModel.allSuggestableFiles.count)|\(explorerViewModel.isIndexing)|\(explorerViewModel.rootItems.count)"
    }

    /// Which draft the composer holds — see `ComposerDraftStore.Key`.
    private var draftKey: ComposerDraftStore.Key {
        .init(mainViewModel.interfaceMode, mainViewModel.selectedConversationID)
    }

    /// Changes when the ACTIVE profile could have changed — chat selection, interface mode,
    /// code profile — or when the attachment set did. One combined key, one `onChange`, for
    /// the same type-checker-budget reason as `contextGaugeTriggerKey`.
    private var attachmentRecheckKey: String {
        "\(backendConfiguration.selectedProfileID?.uuidString ?? "-")|\(mainViewModel.interfaceMode)|\(codeSessionManager.codeProfileID?.uuidString ?? "-")|\(inputViewModel.attachedFiles.count)"
    }

    private var contextGaugeTriggerKey: String {
        "\(chatHistoryViewModel.contextGaugeTurnKey)|\(inputViewModel.isStreaming)|\(mainViewModel.interfaceMode)|\(codeProjectContextChars)"
    }

    // Why: do not size from `currentChatMessages`, which is only the render window; and keep it off the per-keystroke path.
    /// Resolves the history the next request would carry and sizes that, using the same profile resolution as
    /// `evaluatePreSendFit`. Runs a Task with a persistence round-trip, cancelling the previous one so a slow resolve
    /// cannot land over a newer one.
    private func recomputeContextGauge() {
        let profile: BackendProfileModel?
        if mainViewModel.interfaceMode == .code, let codeID = codeSessionManager.codeProfileID {
            profile = try? BackendProfileStore.shared.fetchProfile(byId: codeID)
        } else {
            profile = selectedProfile
        }

        let conversationID = mainViewModel.selectedConversationID
        let attachedFiles = inputViewModel.attachedFiles
        let knowledgeChars = codeProjectContextChars

        contextGaugeTask?.cancel()
        contextGaugeTask = Task { @MainActor in
            // No conversation yet (fresh chat) — nothing is stored, so the resident window
            // IS the history and a store round-trip would be pure cost.
            let history: [ChatMessage]
            if let conversationID {
                // Waits out the burst of triggers so only the last task in the window pays for the full message resolve.
                try? await Task.sleep(for: ChatHistoryViewModel.contextGaugeSettle)
                guard !Task.isCancelled else { return }
                history = await chatHistoryViewModel.resolveContextHistory(for: conversationID)
            } else {
                history = chatHistoryViewModel.currentChatMessages.sorted { $0.timestamp < $1.timestamp }
            }
            guard !Task.isCancelled else { return }

            contextUsage = ContextWindowUsage.resolve(
                profile: profile,
                messages: history,
                attachedFiles: attachedFiles,
                conversationID: conversationID,
                extraKnowledgeChars: knowledgeChars
            )
        }
    }

    /// The gauge's "Compact history": summarize this conversation's older turns now, with the
    /// Intelligence Core if it is on and otherwise this conversation's own model. Same profile
    /// resolution as `recomputeContextGauge`, so it summarizes with the model the gauge describes.
    private func compactHistoryNow() async -> String {
        let profile: BackendProfileModel?
        if mainViewModel.interfaceMode == .code, let codeID = codeSessionManager.codeProfileID {
            profile = try? BackendProfileStore.shared.fetchProfile(byId: codeID)
        } else {
            profile = selectedProfile
        }
        guard let conversationID = mainViewModel.selectedConversationID,
              let config = profile?.resolvedLLMConfig else {
            return "Nothing to compact — this conversation has no history yet."
        }
        // The transcript row (`ManualCompactionRow`) shows progress, since the popover's status vanishes with it. `begin`
        // refuses a second run per conversation; do not paint `.alreadyRunning` over it.
        let activity = ManualCompactionActivity.shared
        let ownsRow = activity.begin(conversationID)
        let history = await chatHistoryViewModel.resolveContextHistory(for: conversationID)
        let outcome = await HistoryCompactionService.shared.compactNow(
            chatHistory: history,
            conversationID: conversationID,
            contextWindow: contextUsage?.windowTokens ?? 8_192,
            fallbackModel: config
        )
        if ownsRow { activity.finish(conversationID, outcome: outcome) }
        recomputeContextGauge()
        return outcome.message
    }

    // MARK: - Main Input Area
    private var mainInputArea: some View {
        let isFocused = isInputFocused.wrappedValue
        return VStack(spacing: 6) {
            editorAndPlaceholderArea
            toolbarArea
        }
        .padding(.top, 6)
        .appSurface(
            in: .rect(cornerRadius: 18),
            elevation: .elevated,
            strokeWidth: theme.isDark ? 0.5 : 0.75,
            isFocused: isFocused
        )
        .overlay {
            if isDropTargeted {
                ComposerDropZoneOverlay(cornerRadius: 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isFocused)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.78), value: isDropTargeted)
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
                    // Same gate the send button uses — Enter must not bypass the
                    // voice-busy check (see `isVoiceBusy`).
                    guard isInputEnabled, !isVoiceBusy else { return }
                    attemptSend(attributedString)
                },
                minHeight: textEditorMinHeight,
                maxHeight: textEditorMaxHeight,
                fontSize: themeManager.chatFontSize,
                lineSpacing: themeManager.chatLineSpacing,
                
                // CRITICAL: Bind to VM State, NOT local state
                showPromptSuggestions: $inputViewModel.promptSuggestionState.isShowing,
                suggestionQuery: $inputViewModel.promptSuggestionState.query,
                activePromptTriggerRange: $inputViewModel.promptSuggestionState.triggerRange,
                
                showFileSuggestions: $inputViewModel.fileSuggestionState.isShowing,
                fileSuggestionQuery: $inputViewModel.fileSuggestionState.query,
                activeFileMentionTriggerRange: $inputViewModel.fileSuggestionState.triggerRange,

                showSkillSuggestions: $inputViewModel.skillSuggestionState.isShowing,
                skillSuggestionQuery: $inputViewModel.skillSuggestionState.query,
                activeSkillTriggerRange: $inputViewModel.skillSuggestionState.triggerRange,
                
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
                    } else if inputViewModel.skillSuggestionState.isShowing {
                        inputViewModel.navigateSuggestions(direction: direction, type: .skill)
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
                },
                onTriggerStateChanged: {
                    // Filtered here, from `onTriggerStateChanged` rather than `onTextManuallyChanged` (which runs before trigger
                    // analysis and reads a stale query), and not debounced since it reads an in-memory library.
                    inputViewModel.refreshSkillSuggestions(offer: skillCommandOffer)
                }
            )
            .frame(minHeight: textEditorMinHeight, maxHeight: textEditorMaxHeight)
            
            if inputViewModel.userInput.isEmpty {
                // Uses fixed constants matching `makeNSView` setup, since the optional textView ref is nil on first render.
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
        .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
        .focused(isInputFocused)
        .disabled(!isInputEnabled)
        .opacity(isInputEnabled ? 1.0 : 0.6)
        // When an external caller stages text, the VM flips `pendingInputFocusRequest` so this editor grabs focus. The reset
        // is deferred one runloop tick to avoid extra `updateNSView` passes that can race the text-binding sync-back.
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
        if mainViewModel.interfaceMode != .code && backendConfiguration.selectedProfileID == nil { return String(localized: "Select a backend...") }
        if !inputViewModel.attachedFiles.isEmpty { return String(localized: "Ask about context...") }
        if inputViewModel.userInput.isEmpty {
            switch inputViewModel.voiceInputState {
                case .recording: return String(localized: "Listening...")
                case .processing: return String(localized: "Processing...")
                case .finalizingSilence: return String(localized: "Finalizing...")
                case .error: return String(localized: "Voice error...")
                default:
                    switch mainViewModel.interfaceMode {
                    case .workflow: return String(localized: "Enter workflow input...")
                    case .code:     return String(localized: "Ask about your code...")
                    case .chat:     return String(localized: "Type a message...")
                    }
            }
        }
        return ""
    }

    // Matches the QuickAccess panel's arrangement: profile chip first, then action icons, a spacer, then separate voice
    // and send buttons.
    private var toolbarArea: some View {
        HStack(alignment: .center, spacing: 8) {
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
                    onManageProfiles: {
                        if let profileID = backendConfiguration.selectedProfileID ?? profileService.sharedProfiles.first?.id {
                            router.navigate(to: .profileDetail(profileID: profileID))
                        }
                    },
                    showingPopup: $showingBackendSelectorPopup
                )
                .disabled(!isInputEnabled)
                .opacity(isInputEnabled ? 1.0 : 0.5)

                // Quick planning / self-reflection toggles for the selected agent profile
                // (self-gates to agent profiles; renders nothing for bot/workflow/imageGen).
                CapabilityToolbarButtons(profile: $selectedProfile, isEnabled: isInputEnabled)
            }

            // MCP connection summary above the toolbar, so the state of external capabilities is visible when sending. Renders
            // nothing when no servers exist. Not gated on a selected profile: MCP health is a property of the app.
            if !MCPToolStore.shared.sources.isEmpty {
                MCPStatusBanner {
                    // The Tool Library is per-profile, so navigation needs a profile: the selected one, else the first that exists. An
                    // invented UUID would be a dead button.
                    if let profileID = backendConfiguration.selectedProfileID ?? profileService.sharedProfiles.first?.id {
                        router.navigate(to: .toolLibrary(profileID: profileID))
                    } else {
                        logger.warning("""
                            [MCP-STATUS] Tool Library requested from the composer banner but NO backend \
                            profile exists to open it against — the Tool Library is per-profile. \
                            Navigation skipped; the user sees no response to the tap.
                            """)
                    }
                }
            }

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

            // Small window-occupancy ring showing how full the selected model's context window is; tap for the breakdown. Hidden
            // for non-chat profiles.
            if let contextUsage {
                ContextWindowGauge(
                    usage: contextUsage,
                    onOpenTools: { profileID in router.navigate(to: .toolLibrary(profileID: profileID)) },
                    onCompact: { await compactHistoryNow() },
                    canCompact: isInputEnabled,
                    // Code keeps its window in the project's quick settings, not the profile's Advanced panel. Ollama only, the one
                    // provider whose window the app chooses.
                    onRaiseContext: mainViewModel.interfaceMode == .code && codeSessionManager.provider == .ollama
                        ? { codeSessionManager.showQuickSettings = true }
                        : nil
                ) { profileID in
                    router.navigate(to: .profileDetail(profileID: profileID))
                }
            }

            // Voice: `DynamicActionButton` is kept for its voice states, Whisper model picker, download-progress ring and
            // alerts, styled like the QuickAccess mic and pinned to voice-only modes.
            DynamicActionButton(
                mode: voiceButtonMode,
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
                onSend: { _, _ in }, // voice-only: send lives on the button below
                onToggleVoice: { inputViewModel.toggleVoiceInput() },
                onStopStreaming: { inputViewModel.cancelStreamingResponse() }
            )

            // Per-node skip for a live workflow run, the only skip surface when a workflow runs from chat mode. A leaf view, so
            // node events re-render a capsule rather than the composer (see `ComposerSkipResolver`).
            if let conversationID = mainViewModel.selectedConversationID,
               mainViewModel.workflowExecutionStates[conversationID]?.isRunning == true {
                ComposerWorkflowSkipButton(conversationID: conversationID)
            }

            // Send / stop — the shared accent button (same as the QuickAccess panel).
            ComposerSendStopButton(
                isSending: isSending || inputViewModel.isStreaming,
                isDisabled: sendButtonDisabled,
                action: {
                    if inputViewModel.isStreaming {
                        inputViewModel.cancelStreamingResponse()
                    } else {
                        sendViaActionButton()
                    }
                }
            )
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    /// Send from the toolbar button — pulls the ATTRIBUTED text from the editor (preserves
    /// rich content, exactly as the old morphing button's send action did) and hands off to the
    /// shared send path.
    private func sendViaActionButton() {
        let attributedString: NSAttributedString
        if let textView = editorTextView {
            attributedString = textView.attributedString()
        } else {
            attributedString = NSAttributedString(string: inputViewModel.userInput, attributes: defaultTypingAttributes)
        }
        guard !attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        attemptSend(attributedString)
    }

    /// The single send path: pre-send intercepts, profile resolution and hand-off. Enter and the send button both route
    /// through it so an unselected or deleted profile behaves the same.
    private func attemptSend(_ attributedString: NSAttributedString) {
        // Code mode: intercept if model or folder not configured, then point selectedProfileID at
        // the code profile so resolution succeeds.
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
            if let refusal = mainViewModel.codeSendRefusal(openFolder: codeSessionManager.projectPath) {
                logger.warning("[CODE_PROJECT] Send refused for session \(mainViewModel.selectedConversationID?.uuidString ?? "nil") — its bound folder is not the open one (\(codeSessionManager.projectPath?.path ?? "none")). CONSEQUENCE: nothing is sent; the draft stays in the composer.")
                toastManager.show(refusal, style: .warning)
                return
            }
            if let codeID = codeSessionManager.codeProfileID {
                backendConfiguration.selectedProfileID = codeID
            }
        }

        switch backendConfiguration.resolveRequestConfig() {
        case .success(let config):
            onSendMessage(expandSkillCommand(in: attributedString), config)
            inputViewModel.userInput = ""

        case .failure(let reason):
            handleUnsendableProfile(reason)
        }
    }

    /// Rewrites a leading `/skill-name` into the directive actually sent. A directive, not an invocation (see
    /// `SkillCommandParser`); only for agent profiles and names the profile can reach, otherwise the text is left exactly
    /// as typed.
    private func expandSkillCommand(in attributed: NSAttributedString) -> NSAttributedString {
        guard let command = SkillCommandParser.parse(attributed.string) else { return attributed }

        guard let profile = selectedProfile else { return attributed }

        // Uses the same name set the picker was filtered by (see `SkillCommandReachability`).
        let rendered = SkillCommandParser.render(command, availableNames: skillCommandOffer.names)
        guard rendered != attributed.string else { return attributed }

        logger.log("[SKILLS] Expanded /\(command.skillName) into a directive for '\(profile.displayName)'.")
        // Rebuilt with the original's attributes at index 0, since dropping the typing attributes changes how the message
        // renders.
        let attributes = attributed.length > 0 ? attributed.attributes(at: 0, effectiveRange: nil) : [:]
        return NSAttributedString(string: rendered, attributes: attributes)
    }

    /// Turns a resolution failure into something the user can act on. Every arm leaves the typed
    /// message in the composer — the text is the one thing that must survive a refused send.
    private func handleUnsendableProfile(_ reason: BackendConfigUnavailability) {
        switch reason {
        case .noProfileSelected:
            showingBackendSelectorPopup = true

        case .profileDeleted(let id):
            // Clears the dangling selection as well as opening the picker, so the composer stops showing a deleted profile's
            // name. Only this arm clears it: a store read that threw says nothing about whether the profile exists.
            logger.notice(
                "[PROFILE] Clearing the composer's selection of deleted profile \(id). "
                + "CONSEQUENCE: the send button disables and the picker opens; the typed message is kept."
            )
            backendConfiguration.selectedProfileID = nil
            selectedProfile = nil
            toastManager.show(
                String(localized: "That profile was deleted. Choose another to send this message."),
                style: .error
            )
            showingBackendSelectorPopup = true

        case .storeUnavailable(_, let description):
            // The selection is kept, since retrying is the right next action.
            toastManager.show(
                String(localized: "Couldn't read the selected profile: \(description)"),
                style: .error
            )
        }
    }
    
    // MARK: - Handlers
    
    // MARK: - File Drop Handler
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        return FileAttachmentPicker.handleDrop(providers) { item in
            attach([item])
        }
    }

    private func openFilePicker() {
        FileAttachmentPicker.presentOpenPanel(prompt: "Attach Files or Folders") { items in
            attach(items)
        }
    }
    
    private func openCodeFolderPicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = String(localized: "Select Project Folder")
        openPanel.message = String(localized: "Choose a folder for your Code session.")

        openPanel.begin { response in
            if response == .OK, let url = openPanel.url {
                Task { @MainActor in
                    applyCodeFolderSelection(url)
                }
            }
        }
    }

    /// Applies a project folder selection — whether from NSOpenPanel or the Recent list.
    /// Updates the Explorer sidebar, refreshes the project's knowledge and tracks recents.
    @MainActor
    private func applyCodeFolderSelection(_ url: URL) {
        // Through the coordinator: a session already bound to another folder keeps it, and the
        // new folder gets a new session.
        mainViewModel.chooseCodeFolder(url)
    }

    /// Code-mode file attachment picker. Hard-whitelists docs/code/images so the
    /// user can't attach video or unsupported binaries — we'd fail to extract them
    /// and waste a round-trip.
    private func openCodeFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = String(localized: "Attach Files")
        openPanel.message = String(localized: "Attach documents, code, or images.")
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
                    attach(fileItems)
                }
            }
        }
    }

    /// UTTypes accepted by `openCodeFilePicker`: broad buckets (images, source code, plain text, PDF) plus per-extension
    /// entries for supported document formats and code extensions UTType may not recognize.
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

    /// Every composer attach route lands here: intake runs against the ACTIVE profile's
    /// delivery mode (a folder is refused where the profile injects contents — ATT-3), and
    /// refusals are reported.
    private func attach(_ items: [FileSystemItem]) {
        reportRefusedAttachments(inputViewModel.addAttachedFiles(fileItems: items, deliveryMode: activeDeliveryMode()))
    }

    // Why: read from `selectedProfileID`, not the `selectedProfile` @State, which a sibling onChange refreshes in unspecified
    // order.
    /// The delivery mode of the profile a send would use now; nil when none resolves. In Code mode that is the code
    /// profile, resolved as in `evaluatePreSendFit`.
    private func activeDeliveryMode() -> AttachmentDeliveryMode? {
        activeProfile().map { AttachmentDeliveryMode.resolve(for: $0) }
    }

    private func activeProfile() -> BackendProfileModel? {
        let id = mainViewModel.interfaceMode == .code
            ? codeSessionManager.codeProfileID
            : backendConfiguration.selectedProfileID
        guard let id else { return nil }
        return try? BackendProfileStore.shared.fetchProfile(byId: id)
    }

    /// Tells the user which files `AttachmentIntake` refused — without this the refusal is
    /// as invisible as the send-time drop it replaces.
    private func reportRefusedAttachments(_ refused: [AttachmentIntake.Refusal], removed: Bool = false) {
        guard let message = AttachmentIntake.summary(refused, removed: removed) else { return }
        toastManager.show(message, style: .warning)
    }

    private func confirmSuggestionSelection() {
        if inputViewModel.fileSuggestionState.isShowing {
            let multiSelected = inputViewModel.fileSuggestionState.multiSelectedIDs

            if !multiSelected.isEmpty {
                let filesToAttach = inputViewModel.fileSuggestionState.filteredItems.filter { multiSelected.contains($0.id) }
                if !filesToAttach.isEmpty {
                    logger.log("Attaching \(filesToAttach.count) files from multi-selection.")
                    attach(filesToAttach)
                    inputViewModel.selectMultipleFiles(filesToAttach)
                }
            }
            else if let selectedID = inputViewModel.fileSuggestionState.selectedID,
                    let selectedFile = inputViewModel.fileSuggestionState.filteredItems.first(where: { $0.id == selectedID }) {
                logger.log("Attaching single focused file: \(selectedFile.name)")
                attach([selectedFile])
                _ = inputViewModel.selectFile(selectedFile)
            }
        }
        else if inputViewModel.promptSuggestionState.isShowing {
            guard let selectedID = inputViewModel.promptSuggestionState.selectedID,
                  let selectedPrompt = inputViewModel.promptSuggestionState.filteredItems.first(where: { $0.id == selectedID }) else { return }
            inputViewModel.selectPrompt(selectedPrompt)
        }
        else if inputViewModel.skillSuggestionState.isShowing {
            guard let selectedID = inputViewModel.skillSuggestionState.selectedID,
                  let selected = inputViewModel.skillSuggestionState.filteredItems.first(where: { $0.id == selectedID }) else { return }
            inputViewModel.selectSkillCommand(selected)
        }
    }

}

// MARK: - Window Reader ([V3])

/// Resolves the NSWindow hosting the composer and hands it to the caller — same
/// accessor shape as `WindowConfigurator`, but reporting instead of configuring.
/// Used to gate the app-wide toggle-voice shortcut on the composer's window being key.
private struct ComposerWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            onResolve(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            onResolve(nsView?.window)
        }
    }
}
