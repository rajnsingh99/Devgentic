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
    // [Context gauge] Source of the conversation's messages (history size = the gauge's
    // numerator) and the newest turn's real token usage. App-scoped, injected at the app
    // root and already consumed by this view's parent — safe to read here.
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
    @State private var showingSchedulePopover = false
    @State private var isDropTargeted: Bool = false
    /// [Context gauge] Occupancy of the selected model's window for THIS conversation
    /// (nil = non-chat profile, so the ring self-hides). Recomputed on turn / model /
    /// attachment changes — never per keystroke — so it stays cheap on long transcripts.
    @State private var contextUsage: ContextWindowUsage?

    /// The skills a `/` command can reach on the selected profile.
    ///
    /// ⚠️ Read by BOTH the picker's filter and the send-path rewrite, so the two cannot drift. They
    /// previously computed this separately and disagreed: the picker offered the whole library and
    /// the rewrite accepted only linked names, so an offered-but-unlinked skill sent raw `/name`
    /// text to the model.
    private var reachableSkillNames: Set<String> {
        SkillCommandReachability.reachableNames(in: selectedProfile?.details)
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

    /// Send-button availability — mirrors the old morphing button's `.send` disabled rule
    /// (backend selected, non-empty input, not mid-request, voice not busy). Never disabled
    /// while streaming: the button is the Stop control then.
    /// Voice is mid-capture or mid-transcription. Sending now races the in-flight
    /// transcript into a composer we're about to clear, so it lands as stray text at the
    /// head of the NEXT message.
    ///
    /// Deliberately shared by the send BUTTON and the ENTER key: these were two
    /// independently-computed gates and they had drifted — Enter checked only
    /// `isInputEnabled` and sent straight through while the button was correctly
    /// disabled. One property so they can't diverge again.
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
            
            // SKILL COMMANDS (Driven by VM State)
            // ⚠️ Gated on the profile KIND as well as the trigger. A bot or imageGen run registers
            // no `load_skill`, so offering a skill picker there promises something the run cannot
            // do — distinct from an agent with nothing linked yet, which still gets the picker and
            // an empty state telling it how to link one.
            if inputViewModel.skillSuggestionState.isShowing,
               SkillCommandReachability.pickerApplies(to: selectedProfile?.details) {
                SkillCommandSuggestionView(
                    items: inputViewModel.skillSuggestionState.filteredItems,
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
        .frame(maxWidth: ViewLayout.maxContentWidth)
        .frame(maxWidth: .infinity, alignment: .center)
        // [V3] Wire the hosting window to the VM so the app-wide ⌘⇧V shortcut can be
        // gated on THIS window being key (a recording started from another window has
        // no visible overlay), and stop any live dictation when the composer leaves
        // the hierarchy — a mic session must not outlive its UI.
        .background(ComposerWindowReader { window in
            inputViewModel.composerWindow = window
        })
        .onDisappear {
            inputViewModel.handleComposerDismantled()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("openFilePicker"))) { _ in
            openFilePicker()
        }
        // MARK: - File Drop Zone (P1)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }

        // MARK: - Wiring
        .onAppear {
            updateSelectedProfile(profileID: backendConfiguration.selectedProfileID)
            recomputeContextGauge()

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
        .onChange(of: backendConfiguration.selectedProfileID) { _, newID in
            updateSelectedProfile(profileID: newID)
            evaluatePreSendFit()
            // Model changed → the gauge's DENOMINATOR (window) changed. Same conversation
            // can jump from 24% to 100%+ on a switch to a smaller-window model.
            recomputeContextGauge()
        }
        // [Pre-send fit hint] Surface the context-overflow advisory the moment
        // attachments imply the prompt won't fit — before the turn is spent.
        // Count-keyed: FileSystemItem isn't Equatable, and adds/removes are the
        // events that change the estimate.
        .onChange(of: inputViewModel.attachedFiles.count) { _, _ in
            evaluatePreSendFit()
            recomputeContextGauge()
        }

        // [C2] Per-conversation drafts. The composer's view model is app-scoped and
        // `attachedFiles` lives on the single MainApplicationViewModel, so nothing used to
        // reset either on a conversation switch: the half-typed message and attachments
        // from the conversation you just left stayed in the box, where they could be sent
        // into the new one. Save under the OUTGOING id, restore the INCOMING one's.
        //
        // Observed here because this view is a SIBLING of the content switch — always
        // mounted, even on the welcome screen — so it catches every change to the
        // selection, including the ones the ChatOps bridges make, without having to patch
        // each write site.
        .onChange(of: mainViewModel.selectedConversationID) { oldID, newID in
            guard oldID != newID else { return }
            ComposerDraftStore.shared.save(
                .init(text: inputViewModel.userInput, attachments: mainViewModel.attachedFiles),
                for: oldID
            )
            let incoming = ComposerDraftStore.shared.draft(for: newID)
            inputViewModel.userInput = incoming.text
            // Write the SOURCE of truth: `ChatInputViewModel.attachedFiles` is a
            // `private(set)` mirror that its observation stream keeps in sync from here.
            mainViewModel.attachedFiles = incoming.attachments
            // New conversation → different history size, so recompute occupancy. The
            // message-count change fires too, but only AFTER the load completes; this
            // clears the outgoing chat's number immediately on switch.
            recomputeContextGauge()
        }

        // Refresh files if Explorer/Context changes (Lazy refresh)
        .onChange(of: explorerViewModel.rootItems.count) { _, _ in
            if inputViewModel.fileSuggestionState.isShowing {
                inputViewModel.refreshFileSuggestions(using: explorerViewModel)
            }
        }

        // [Context gauge] Occupancy moves when a turn is added (history grows), when
        // streaming ends (final assistant text + real usage settle), and when the mode
        // switches (Code vs chat resolve different models). Deliberately NOT keyed on
        // keystrokes — the unsent draft is excluded from the ring.
        // [Context gauge] All the cheap recompute signals — a turn added (history grows),
        // streaming settling, mode switch, and a code-folder swap (project-context size) —
        // collapsed into ONE onChange keyed on a combined signature computed outside the
        // body. Four separate onChanges tipped this already-large body over the SwiftUI
        // type-checker's complexity budget; one keeps it under.
        .onChange(of: contextGaugeTriggerKey) { _, _ in recomputeContextGauge() }
        
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

    /// [Pre-send fit hint] Posts/clears the shared context-overflow advisory from
    /// composer state (stat-based estimate); the send-time check refines it.
    private func evaluatePreSendFit() {
        // In Code mode `selectedProfile` is NOT the code profile — `selectedProfileID`
        // is only pointed at it during send (see onCommit), so before that it's nil or
        // the last chat profile. Resolve the real one, else Code silently got no hint.
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

    /// [Context gauge] Size of Code mode's injected project context (`.devgentic/context.md`),
    /// 0 outside Code mode. Code adds it to the system prompt on every message — a real, fixed
    /// cost the generic history/attachment estimate can't see. A plain Int so `onChange(of:)`
    /// keeps the large body's type-checker under budget; shared by the recompute so they can't drift.
    private var codeProjectContextChars: Int {
        guard mainViewModel.interfaceMode == .code else { return 0 }
        return codeSessionManager.projectMemoryContent?.count ?? 0
    }

    /// In-flight gauge resolution, cancelled on each recompute so bursty triggers cannot
    /// land out of order.
    @State private var contextGaugeTask: Task<Void, Never>?

    /// [Context gauge] One combined key over every cheap recompute signal (turn count,
    /// streaming, mode, code project-context size), so a SINGLE `onChange` in the body
    /// covers them all — keeping the large body under the type-checker's budget. Reading
    /// each value here establishes the SwiftUI observation dependency just as separate
    /// `onChange`s would.
    private var contextGaugeTriggerKey: String {
        "\(chatHistoryViewModel.currentChatMessages.count)|\(inputViewModel.isStreaming)|\(mainViewModel.interfaceMode)|\(codeProjectContextChars)"
    }

    /// [Context gauge] Resolves the history the NEXT request would carry and sizes THAT.
    ///
    /// Deliberately NOT `chatHistoryViewModel.currentChatMessages`: that is the render
    /// window (20 on open, +10 per scroll-back), so sizing from it made the ring climb as
    /// the user scrolled while the prompt was unchanged, and made a freshly-opened long
    /// conversation under-read its own history by up to 15×.
    ///
    /// Resolves the active profile the same way `evaluatePreSendFit` does — in Code mode the
    /// real profile is not `selectedProfile` until send, so reading that would size the ring
    /// against whichever chat model happened to be selected instead.
    ///
    /// No longer the synchronous array read it once was: the resolution is store-authoritative,
    /// so this spawns a Task and pays a persistence round-trip. Affordable only because it runs
    /// on turn / model / attachment / conversation / mode changes and never per keystroke. The
    /// in-flight task is cancelled first so a slow earlier resolve cannot land on top of a newer
    /// one — the triggers fire in bursts (message added, streaming toggles, profile switched).
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
        // The transcript row (`ManualCompactionRow`) — the popover's own status vanishes with the
        // popover, and the checkpoint card lands above the fold. `begin` refuses a second run in
        // the same conversation, and then this call must not paint `.alreadyRunning` over it.
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
                    // ⚠️ Filtered HERE rather than on a debounce like `#`/`@`. Those search a
                    // service; this reads an in-memory library of tens of rows, so a debounce would
                    // only add latency between a keystroke and the list narrowing.
                    //
                    // ⚠️⚠️ And filtered from `onTriggerStateChanged`, NOT `onTextManuallyChanged`.
                    // The latter runs before trigger analysis, so this read a query one keystroke
                    // stale and saw `isShowing == false` on the very first `/` — which made a full
                    // library render as "No skills in the library yet".
                    inputViewModel.refreshSkillSuggestions(reachableNames: reachableSkillNames)
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
        .padding(EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 14))
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

    // [Composer parity] Matches the QuickAccess panel's arrangement: profile chip LEADS,
    // then the action icons, then a spacer, then SPLIT voice + send buttons (the single
    // morphing mic/send button is now voice-only; send is the shared accent button).
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

            // MCP connection summary. Sits directly above the toolbar so the state of the
            // agent's external capabilities is visible at the moment of sending, rather
            // than only inside the Tool Library. Renders nothing when no MCP servers are
            // configured, and stays a muted single line unless something is actually down.
            // NOT gated on a selected profile. MCP server health is a property of the app,
            // not of the chosen backend — gating it here meant the banner vanished on the
            // launch screen, which is exactly when the launch sweep has just run and its
            // result is most worth seeing. The banner hides itself when no servers exist.
            if !MCPToolStore.shared.sources.isEmpty {
                MCPStatusBanner {
                    // The Tool Library is per-profile (it edits that profile's tool selection),
                    // so navigation needs *a* profile: the selected one, else the first that
                    // exists. `ToolLibraryContainerView` renders nothing for an id it cannot
                    // find, so an invented UUID would be a dead button.
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

            // [Context gauge] Small window-occupancy ring — how full the selected model's
            // context window is for this conversation. Tap for the breakdown. Self-hides
            // for non-chat profiles (workflow / imageGen have no single window).
            if let contextUsage {
                ContextWindowGauge(
                    usage: contextUsage,
                    onOpenTools: { profileID in router.navigate(to: .toolLibrary(profileID: profileID)) },
                    onCompact: { await compactHistoryNow() },
                    canCompact: isInputEnabled,
                    // Code keeps its window in the project's quick settings, not the profile's
                    // Advanced panel (the Code profile has none a user can reach). Ollama only —
                    // the one provider whose window the app chooses.
                    onRaiseContext: mainViewModel.interfaceMode == .code && codeSessionManager.provider == .ollama
                        ? { codeSessionManager.showQuickSettings = true }
                        : nil
                ) { profileID in
                    router.navigate(to: .profileDetail(profileID: profileID))
                }
            }

            // Voice — DynamicActionButton retained for its main-only machinery (voice states,
            // Whisper model picker via long-press/right-click, download-progress ring, alerts),
            // restyled to the QuickAccess mic look and pinned to voice-only modes.
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

            // Per-node SKIP for a live workflow run (Phase B increment 7, D2.1) — the composer is
            // the only skip surface when a workflow runs from chat mode. A LEAF view on purpose:
            // it reads the observable workflow state in ITS body, so node events re-render a
            // capsule instead of the whole composer. Renders nothing unless the selected
            // conversation has a live run with exactly the right shape (see ComposerSkipResolver).
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

    /// The ONE send path — pre-send intercepts, profile resolution, hand-off.
    ///
    /// ⚠️ Enter and the send button used to implement this separately, and they had drifted
    /// (register A32): Enter intercepted an unselected or deleted profile by opening the backend
    /// picker, while the button's `guard let config = … else { logger.error(…); return }` did
    /// nothing a user could see. Clicking send on a profile deleted from the sidebar looked like a
    /// dead button — the composer still showed the profile's name, because `selectedProfile` is a
    /// stale snapshot that nothing invalidated. `isVoiceBusy` above carries the same warning about
    /// the same two callers; this is that lesson applied to the action instead of the gate. Keep
    /// both entry points routed through here.
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

    /// Rewrites a leading `/skill-name` into the directive actually sent.
    ///
    /// ⚠️ A DIRECTIVE, not an invocation — see `SkillCommandParser`. The model is told to use the
    /// skill and still calls `load_skill` itself. Nothing here pre-loads a body or forces a choice.
    ///
    /// ⚠️ ONLY for agent profiles, and only for a name the profile can actually reach. A command
    /// naming an unlinked or misspelled skill is left EXACTLY as typed: sending an instruction the
    /// model cannot follow would make it apologise for a skill it never had, and the typo would be
    /// hidden from the one person able to fix it.
    private func expandSkillCommand(in attributed: NSAttributedString) -> NSAttributedString {
        guard let command = SkillCommandParser.parse(attributed.string) else { return attributed }

        guard let profile = selectedProfile else { return attributed }

        // ⚠️ The SAME set the picker was filtered by — see `SkillCommandReachability`. Computing it
        // here independently is exactly how the two came to disagree.
        let rendered = SkillCommandParser.render(command, availableNames: reachableSkillNames)
        guard rendered != attributed.string else { return attributed }

        logger.log("[SKILLS] Expanded /\(command.skillName) into a directive for '\(profile.displayName)'.")
        // ⚠️ Rebuilt with the ORIGINAL's attributes at index 0 rather than plain text: the composer
        // hands this string to the send path with typing attributes attached, and dropping them
        // changes how the message renders in the transcript.
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
            // ⚠️ Clear the dangling selection as well as opening the picker. Leaving it set is what
            // kept the composer showing a deleted profile's name and the send button enabled, so
            // every subsequent click failed the same silent way. Only this arm clears it: a store
            // read that THREW says nothing about whether the profile exists.
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
            // The selection is deliberately KEPT — retrying is the right next action.
            toastManager.show(
                String(localized: "Couldn't read the selected profile: \(description)"),
                style: .error
            )
        }
    }
    
    // MARK: - Handlers
    
    // MARK: - File Drop Handler (P1) — [Q8] shared with the QuickAccess panel via FileAttachmentPicker.
    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        return FileAttachmentPicker.handleDrop(providers) { item in
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
    /// Updates the Explorer sidebar and triggers context.md bootstrap + recents tracking.
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
