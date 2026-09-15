// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  QuickAccessContentView.swift
//  Devgentic
//
//  Created by Raj Singh on 07/05/25.
//  [QA revival P1a] Rewired onto the real streaming stack: hosts a live transcript of
//  shared ChatBubbleViews driven by QuickAccessSessionViewModel (which streams through the
//  app-wide ActiveStreamManager). The old dead OllamaConnect view model is gone.
//
import SwiftUI
import AppKit // For NSPasteboard / NSOpenPanel
import UniformTypeIdentifiers // For .fileURL drag-and-drop

struct QuickAccessContentView: View {
    // --- Callbacks ---
    var dismiss: () -> ()
    // [Unified card] (height, expanded) — explicit state intent so the panel's resize machinery
    // never has to infer expand/collapse from the height (a grown collapsed card broke that).
    var onResize: ((CGFloat, Bool) -> Void)?
    var onToggleZoom: (() -> Void)?
    // [QA revival P2e] Hand the current conversation back to the main window.
    var onContinueInMainWindow: ((UUID) -> Void)?
    // [Advisory] Settings deep-link from the panel's advisory banner — reverse-handoff
    // (activate main window → navigate), since the router isn't in the panel's environment.
    var onOpenProfileSettings: ((UUID) -> Void)?
    // [M9] Register a handler that maps the panel's ⌘Return / Escape onto a pending HITL request.
    var onRegisterHITLKeyHandler: ((@escaping (QuickAccessHITLKeyAction) -> Bool) -> Void)?

    // --- Injected shared graph (from AppDelegate → panel) ---
    // Plain lets, not @Environment: this view is hosted in an AppKit NSHostingView built
    // by AppDelegate, outside the SwiftUI environment, so the graph is threaded in by hand.
    private let mainAppViewModel: MainApplicationViewModel
    private let themeManager: ThemeManager
    // [QA revival P1e] false when the panel's last session timed out → start fresh.
    private let shouldResumeSession: Bool

    // --- View Model ---
    @State private var session: QuickAccessSessionViewModel

    // --- UI State ---
    @State private var inputText: String = ""
    @State private var isExpanded: Bool = false
    @State private var isPanelZoomedToFullScreen: Bool = false
    // [Unified card] The one editor instance (CustomTextEditor's NSTextView) — focus is driven
    // via makeFirstResponder (an NSViewRepresentable doesn't reliably take @FocusState).
    @State private var editorTextView: CustomTextEditor.CustomNSTextView?
    // [Unified card] Measured height of the input area (card + its outer padding) — drives the
    // collapsed window height so the panel grows with multi-line text / attachment chips.
    @State private var inputAreaMeasuredHeight: CGFloat = 90
    // [QA revival P1b] Profile picker popover state.
    @State private var showingProfilePopup: Bool = false
    // [QA revival P2a] Files attached to the next message (panel-local; passed to send()).
    @State private var attachedFiles: [FileSystemItem] = []

    /// [Context gauge] Occupancy of the panel model's window for this conversation
    /// (nil = non-chat profile, so the ring self-hides). Recomputed on turn / model /
    /// attachment changes, mirroring the main composer.
    @State private var contextUsage: ContextWindowUsage?
    // [QA revival P2b → Composer P2] Voice dictation via the shared ComposerVoiceController
    // (per-instance; owns the Whisper session lifecycle incl. the C9 re-entry/cancel guards).
    @State private var voice = ComposerVoiceController()
    // [QA revival P3] Screen-capture state.
    @State private var isCapturing: Bool = false
    @State private var showCaptureDeniedPopover: Bool = false
    // [L6] Shown when the mic is tapped but no speech model is downloaded yet.
    @State private var showVoiceModelPopover: Bool = false
    // [L3] Shown when microphone permission is denied.
    @State private var showMicDeniedPopover: Bool = false
    @State private var isMenuHovered: Bool = false

    // [Composer P1] What this surface offers — drives which shared composer buttons render
    // (screenshot is a QuickAccess capability; the main composer has it off).
    private let capabilities = ComposerCapabilities.quickAccess

    // --- Styling Constants ---
    // [H3] Chrome colors come from the app theme, not hardcoded white, so the panel stays
    // legible in Light Mode. The panel's NSAppearance is pinned to the theme's colorScheme
    // (QuickAccessPanelView.setupContentView) so the Liquid Glass backdrop renders in the same
    // mode these tokens are designed against.
    private var theme: any Theme { themeManager.currentTheme }
    /// [CF-21] The shared reader, so this panel can mount its transport while it is speaking.
    /// `SpeechControlIsland` reads the same singleton, so no injection is needed.
    private var speechService = SpeechService.shared
    /// [sa-5] The identity this panel's transcript registers as a speech-transport host under.
    /// Owned by the panel so its close path can deregister the same id.
    private let transportHostID: UUID
    private var iconColor: Color { theme.secondaryText }
    private var placeholderTextColor: Color { theme.placeholderText }
    private var textColor: Color { theme.primaryText }
    let inputBarHeight: CGFloat = 90 // collapsed fallback before the card reports its real height (full-bleed)
    let editorMinHeight: CGFloat = 38 // one line incl. CustomTextEditor's 10pt vertical insets
    let editorMaxHeight: CGFloat = 120 // ~4 lines, then the editor scrolls internally
    let buttonRowHeight: CGFloat = 30
    let expandedViewMinHeight: CGFloat = 400
    let topBarHeight: CGFloat = 40
    let panelCornerRadius: CGFloat = 12
    let expandedInputAreaHorizontalMargin: CGFloat = 10
    let contentViewMinWidth: CGFloat = 400
    let expandedInputAreaMaxAllowedWidth: CGFloat = 700

    init(dismiss: @escaping () -> (),
         onResize: ((CGFloat, Bool) -> Void)? = nil,
         onToggleZoom: (() -> Void)? = nil,
         onContinueInMainWindow: ((UUID) -> Void)? = nil,
         onOpenProfileSettings: ((UUID) -> Void)? = nil,
         isExpanded: Bool = false,
         shouldResumeSession: Bool = true,
         mainAppViewModel: MainApplicationViewModel,
         themeManager: ThemeManager,
         onRegisterHITLKeyHandler: ((@escaping (QuickAccessHITLKeyAction) -> Bool) -> Void)? = nil,
         transportHostID: UUID = UUID()) {
        self.transportHostID = transportHostID
        self.dismiss = dismiss
        self.onResize = onResize
        self.onToggleZoom = onToggleZoom
        self.onContinueInMainWindow = onContinueInMainWindow
        self.onOpenProfileSettings = onOpenProfileSettings
        self.onRegisterHITLKeyHandler = onRegisterHITLKeyHandler
        self.shouldResumeSession = shouldResumeSession
        self.mainAppViewModel = mainAppViewModel
        self.themeManager = themeManager
        _isExpanded = State(initialValue: isExpanded)
        _session = State(wrappedValue: QuickAccessSessionViewModel(mainAppViewModel: mainAppViewModel))
    }

    var body: some View {
        ZStack {
            // [drag-vs-select fix v2] Window-drag surface as a REAL backmost layer. A `.background`
            // NSViewRepresentable did NOT receive empty-area mouse-downs (SwiftUI routed them past
            // it → panel immovable). As a ZStack sibling behind the content, SwiftUI hit-tests
            // empty/chrome areas TO it → it drags the window (performDrag); the text field, buttons,
            // and transcript are in front and keep their own selection/click/scroll. Replaces
            // isMovableByWindowBackground, which stole drags over the input field. Works collapsed +
            // expanded.
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                if isExpanded {
                    topBarView
                    transcriptView
                }
                Spacer(minLength: 0)
                // [QA revival P1c] In-panel HITL banner — shown whenever the panel's conversation
                // has a pending human-in-the-loop request (tool approval, clarification, etc.).
                if let pending = session.pendingInteraction {
                    QuickAccessHITLBanner(pending: pending, session: session)
                        .environment(\.appTheme, themeManager.currentTheme)
                        .frame(maxWidth: isExpanded ? expandedInputAreaMaxAllowedWidth : .infinity)
                        .padding(.horizontal, isExpanded ? expandedInputAreaHorizontalMargin : 8)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // [Advisory] Compact ambient warning — same AdvisoryCenter (and dismissal
                // suppression) as the main window's banner. Same stacking rule too: HITL
                // above, advisory anchored next to the input, so transient HITL banners
                // come and go without displacing it.
                if let advisory = session.conversationID.flatMap({ AdvisoryCenter.shared.current(for: $0) }) {
                    QuickAccessAdvisoryBanner(
                        advisory: advisory,
                        onOpenProfileSettings: { profileID in onOpenProfileSettings?(profileID) }
                    )
                    .environment(\.appTheme, themeManager.currentTheme)
                    .frame(maxWidth: isExpanded ? expandedInputAreaMaxAllowedWidth : .infinity)
                    .padding(.horizontal, isExpanded ? expandedInputAreaHorizontalMargin : 8)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                inputCardView
                    .frame(maxWidth: isExpanded ? expandedInputAreaMaxAllowedWidth : .infinity)
                    // [UI audit B] Collapsed = FULL-BLEED: the input fills the glass window (no
                    // nested card-in-bubble margins); expanded keeps the inset card look.
                    .padding(.horizontal, isExpanded ? 12 : 0)
                    .padding(.bottom, isExpanded ? 12 : 0)
                    .padding(.horizontal, isExpanded ? expandedInputAreaHorizontalMargin : 0)
                    // [Unified card] The collapsed window height IS this measured height (the
                    // card is the only content). Editor growth / chips appearing re-measure and
                    // the window follows; expanded ignores it (the card grows into the transcript).
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        inputAreaMeasuredHeight = newHeight
                        if !isExpanded { onResize?(newHeight, false) }
                    }
            }
        }
        .frame(minWidth: contentViewMinWidth)
        // [Composer P1] The shared composer buttons (ComposerKit) read \.appTheme — set it once at
        // the panel root so every child themes correctly (inner injections become redundant).
        .environment(\.appTheme, themeManager.currentTheme)
        // MARK: Liquid Glass — replace material + stroke + shadow with glassEffect
        .background(.clear)
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? panelCornerRadius : 20, style: .continuous))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: isExpanded ? panelCornerRadius : 20))
        // [L5] Match the window-frame animation (NSAnimationContext 0.3s ease in
        // resizePanelProgrammatically) with a non-overshooting ease of the SAME duration — a spring
        // here overshot the window bounds and clipped the glass edge mid-expand.
        .animation(.easeInOut(duration: 0.3), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: isPanelZoomedToFullScreen)
        // [Pre-send fit hint] Same composer-state advisory as the main window —
        // fires when attachments or the panel's profile change, before a send.
        .onChange(of: attachedFiles.count) { _, _ in
            evaluatePreSendFit()
            recomputeContextGauge()
        }
        .onChange(of: session.backendConfiguration.selectedProfileID) { _, _ in
            evaluatePreSendFit()
            recomputeContextGauge()
        }
        // [Context gauge] Recompute occupancy when a turn is added (history grows) or a
        // send settles (final message + real usage land). Mirrors the main composer.
        .onChange(of: session.chatHistoryViewModel.currentChatMessages.count) { _, _ in recomputeContextGauge() }
        .onChange(of: session.isSending) { _, _ in recomputeContextGauge() }
        .onChange(of: isExpanded) { _, newValue in
            // [Unified card] Pass explicit intent; collapsed target = the card's measured height
            // (geometry re-fires after the transition and fine-corrects if paddings shifted it).
            onResize?(newValue ? expandedViewMinHeight : inputAreaMeasuredHeight, newValue)
            if !newValue {
                isPanelZoomedToFullScreen = false
            }
        }
        // [QA revival P1c] A pending HITL needs room for its banner — expand if collapsed.
        .onChange(of: session.pendingInteraction?.id) { _, newID in
            if newID != nil && !isExpanded { isExpanded = true }
        }
        .animation(.easeInOut(duration: 0.3), value: session.pendingInteraction?.id) // [L5] one clock
        // [QA revival P2a] Drop files anywhere on the panel to attach them.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
        .onAppear {
             onResize?(isExpanded ? expandedViewMinHeight : inputAreaMeasuredHeight, isExpanded)
             // [QA revival P0] Summon-and-type: focus the editor once the panel has become
             // key. Retried a few runloop ticks — the NSTextView ref arrives asynchronously.
             focusEditor()
             // [QA revival P1a/P1e] Load the persisted QuickAccess conversation (if resuming);
             // a timed-out session starts fresh.
             session.prepareSession(resume: shouldResumeSession)
             recomputeContextGauge()
             // [Composer P2] What THIS surface does with dictation events: mirror the transcript
             // into the input field, surface a permission denial, refocus after a stop.
             voice.onTextChange = { inputText = $0 }
             voice.onPermissionDenied = { showMicDeniedPopover = true } // [L3]
             voice.onFinished = { focusEditor() }
             // [M9] Map the panel's ⌘Return / Escape onto the pending HITL request, so a keyboard
             // user can answer a tool/plan/clarification/gate — and Escape no longer just closes
             // the panel while a run stays parked.
             onRegisterHITLKeyHandler? { action in
                 MainActor.assumeIsolated {
                     guard let pending = session.pendingInteraction else { return false }
                     switch action {
                     case .cancel:
                         switch pending.kind {
                         case .toolConfirmation: session.denyTool(pending)
                         case .clarification: session.submitClarification(pending, text: "")
                         case .planReview: session.resolvePlan(pending, approved: false)
                         case .gate: session.chooseGate(pending, option: nil)
                         }
                         return true
                     case .confirm:
                         switch pending.kind {
                         case .toolConfirmation: session.approveTool(pending, allowForChat: false); return true
                         case .planReview: session.resolvePlan(pending, approved: true); return true
                         // Clarification/gate need specific input — leave those to the banner field/chips.
                         case .clarification, .gate: return false
                         }
                     }
                 }
             }
        }
        // [C4] Stop any in-flight dictation when the panel goes away, so the shared Whisper
        // service doesn't keep the mic hot (and cross-wire the main window) after the panel closes.
        .onDisappear {
            voice.stopIfRecording()
            // [H1] Any still-attached (never-sent) screen captures are orphaned when the panel is
            // rebuilt on the next summon — delete their temp files now.
            for file in attachedFiles {
                QuickAccessScreenCaptureService.deleteCaptureTempFileIfNeeded(file.url)
            }
        }
    }

    /// [Pre-send fit hint] Posts/clears the shared context-overflow advisory from
    /// the panel's composer state — same estimator and dedupe key as the main
    /// window, so both surfaces and the send-time check drive one banner.
    private func evaluatePreSendFit() {
        PreSendFitHint.evaluate(
            attachedFiles: attachedFiles,
            typedText: inputText,
            profile: session.selectedProfile,
            conversationID: session.conversationID
        )
    }

    /// [Context gauge] Rebuilds the window-occupancy snapshot for the toolbar ring from the
    /// panel's state. The panel is chat-only (no Code mode), so the profile is simply
    /// `session.selectedProfile`. Synchronous and cheap — called on turn / model / attachment
    /// changes, never per keystroke.
    @State private var contextGaugeTask: Task<Void, Never>?

    private func recomputeContextGauge() {
        let profile = session.selectedProfile
        let files = attachedFiles
        let conversationID = session.conversationID

        contextGaugeTask?.cancel()
        contextGaugeTask = Task { @MainActor in
            // Same contract as the main composer: size the REQUEST's history, not the
            // render window. See `ChatHistoryViewModel.resolveContextHistory(for:)`.
            let history: [ChatMessage]
            if let conversationID {
                history = await session.chatHistoryViewModel.resolveContextHistory(for: conversationID)
            } else {
                history = session.chatHistoryViewModel.currentChatMessages.sorted { $0.timestamp < $1.timestamp }
            }
            guard !Task.isCancelled else { return }

            contextUsage = ContextWindowUsage.resolve(
                profile: profile,
                messages: history,
                attachedFiles: files,
                conversationID: conversationID
            )
        }
    }

    func submitQuery() {
        let query = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty || !attachedFiles.isEmpty else { return }
        // [H2] Only clear the draft when the send is actually accepted; on refusal keep the
        // text + attachments and surface why, instead of silently discarding the user's work.
        switch session.send(query, files: attachedFiles) {
        case .accepted:
            inputText = ""
            attachedFiles = []
            if !isExpanded { isExpanded = true }
        case .rejectedNoProfile:
            // No chat profile resolves (first run / a remembered profile was deleted) — expand
            // and open the picker so the user can choose one, keeping their draft intact.
            if !isExpanded { isExpanded = true }
            showingProfilePopup = true
        case .rejectedBusy, .rejectedEmpty, .rejectedUnavailable:
            // Keep the draft: a stream is in flight (the button is showing Stop) or there is
            // nothing actionable to do.
            break
        }
    }
}

extension QuickAccessContentView {

    @ViewBuilder
    private var topBarView: some View {
        ZStack {
            // [drag] Top bar = the panel's drag handle in expanded mode (title-bar-like). The
            // transcript ScrollView and the decorative tint backgrounds capture drags, so the
            // backmost WindowDragArea can't cover the whole expanded panel. This one sits in front
            // of the top bar's tint but behind the buttons — its empty areas drag the window while
            // the buttons still work.
            WindowDragArea()
            HStack {
            QuickAccessCloseButton(action: {
                if isPanelZoomedToFullScreen {
                    onToggleZoom?()
                    isPanelZoomedToFullScreen = false
                }
                isExpanded = false;
                dismiss()
            }, iconColor: iconColor)
            .padding(.leading, 14)
            .accessibilityLabel("Close panel")

            Spacer()

            QuickAccessTopButton(
                icon: "doc.on.doc",
                action: { copyLastMessageToClipboard() },
                disabled: session.chatHistoryViewModel.currentChatMessages.isEmpty,
                tooltip: "Copy last message",
                normalColor: iconColor,
                hoverColor: textColor
            )
            .accessibilityLabel("Copy last message")

            // --- NEW CHAT / RECENTS MENU (P2c) ---
            Menu {
                Button(action: {
                    session.startNewSession()
                    inputText = ""
                    attachedFiles = []
                }) {
                    Label("New Chat", systemImage: "plus.message")
                }
                let recents = session.recentConversations()
                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents, id: \.id) { chat in
                            Button(chat.title) {
                                session.openConversation(chat.id)
                                if !isExpanded { isExpanded = true }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus.message.fill")
                    .font(.system(.body, weight: .medium))
                    .foregroundColor(isMenuHovered ? textColor : iconColor)
                    .frame(width: 28, height: 28)
                    .background(isMenuHovered ? Color.primary.opacity(0.08) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New chat or open a recent one")
            .accessibilityLabel("New chat or recent chats")
            .onHover { hover in
                isMenuHovered = hover
            }
            // --- END NEW CHAT / RECENTS MENU ---

            // --- CONTINUE IN MAIN WINDOW (P2e) ---
            QuickAccessTopButton(
                icon: "arrow.up.forward.app",
                action: { if let id = session.conversationID { onContinueInMainWindow?(id) } },
                disabled: session.conversationID == nil,
                tooltip: "Continue this chat in the main window",
                normalColor: iconColor,
                hoverColor: textColor
            )
            .accessibilityLabel("Continue this chat in the main window")
            // --- END CONTINUE IN MAIN WINDOW ---

            QuickAccessTopButton(
                icon: isPanelZoomedToFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                action: {
                    onToggleZoom?()
                    isPanelZoomedToFullScreen.toggle()
                },
                tooltip: isPanelZoomedToFullScreen ? "Exit Full Screen" : "Enter Full Screen",
                normalColor: iconColor,
                hoverColor: textColor
            )
            .padding(.trailing, 14)
            .accessibilityLabel(isPanelZoomedToFullScreen ? "Exit Full Screen" : "Enter Full Screen")
            }
        }
        .frame(height: topBarHeight)
        .padding(.top, 6)
        .background(Color.primary.opacity(0.01))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(theme.dividerColor.opacity(0.15)),
            alignment: .bottom
        )
    }

    // [QA revival P1a] Live transcript. Reuses the app's real ChatBubbleView stack — the
    // streamed ChatMessage is the same @Observable class the main chat renders, so markdown,
    // code blocks, tool timelines, thinking indicators, and the streaming cursor all come for
    // free. The four Observable objects the bubble tree requires are injected here (a missing
    // one traps at first render); the transcript is driven by a PANEL-SCOPED
    // ChatHistoryViewModel bound to the shared ActiveStreamManager.
    @ViewBuilder
    private var transcriptView: some View {
        if session.chatHistoryViewModel.currentChatMessages.isEmpty {
            // Empty state — a quiet placeholder instead of a large black void (e.g. the panel
            // auto-expands when a file is attached before anything was sent). Non-hittable so
            // drags in the empty area still reach the WindowDragArea (panel move).
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 30, weight: .light))
                    .foregroundColor(theme.tertiaryText.opacity(0.7))
                Text("New conversation")
                    .font(theme.fontSubheadline.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                Text("Responses will appear here.")
                    .font(.caption)
                    .foregroundColor(theme.tertiaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        } else {
            transcriptScrollView
        }
    }

    @ViewBuilder
    private var transcriptScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack {
                    Spacer(minLength: 0)
                    LazyVStack(spacing: 0) {
                        // currentChatMessages is newest-first; reverse for top→bottom display.
                        ForEach(session.chatHistoryViewModel.currentChatMessages.reversed()) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                                .padding(.horizontal, 16)
                        }
                    }
                    .frame(maxWidth: expandedInputAreaMaxAllowedWidth)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
            }
            .environment(session.chatHistoryViewModel)
            .environment(mainAppViewModel)
            .environment(session.searchViewModel)
            .environment(themeManager)
            .environment(\.appTheme, themeManager.currentTheme)
            .environment(\.buttonAccentStyle, themeManager.buttonAccentStyle)
            // [QA revival P1c] Hide Redo/Resume in panel bubbles — they target the main
            // window's conversation state and would no-op here.
            .environment(\.chatActionsSuppressed, true)
            .onChange(of: session.chatHistoryViewModel.currentChatMessages.first?.id) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: session.streamingMessageID) { _, _ in
                scrollToLatest(proxy)
            }
            // [UI audit B] Scroll depth: fade the top ~16pt of the transcript so messages
            // dissolve under the top bar instead of hard-clipping at the 1px divider.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                    Rectangle().fill(Color.black)
                }
            )
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        // [CF-21] The speech transport. Read Aloud is reachable here — this panel renders the
        // app's real `ChatBubbleView`, whose button is not among the actions
        // `chatActionsSuppressed` hides — but the island was mounted ONLY in `ChatHistoryView`,
        // so starting playback from the panel gave a reader with no Play, Pause, Stop or speed
        // control anywhere on screen. Same placement as the main window: bottom-centred, over
        // the transcript. Deliberately OUTSIDE the `.mask` above, so the island is not faded by
        // the transcript's top-edge gradient.
        .overlay(alignment: .bottom) {
            if speechService.isActive {
                SpeechControlIsland()
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.spring(response: 0.4, dampingFraction: 0.7), value: speechService.isActive)
            }
        }
        // [sa-5] The transcript is this panel's transport host — the island above lives inside
        // it, and it renders only while expanded. Closing the panel (Esc → `orderOut` + `close`)
        // AND collapsing it both tear it down; when no other host (a main-window
        // `ChatHistoryView`) remains, the service stops the reader instead of leaving it
        // speaking with no Stop on screen. Registered here rather than on the panel's
        // `.onDisappear` beside the mic cleanup so the collapsed-panel case is covered too.
        // The id is the PANEL's (`QuickAccessPanelView.transportHostID`), which also deregisters
        // it from `closePanel()` — so the panel closing stops the reader even if AppKit's
        // `orderOut` + `close` on a retained panel does not deliver this `onDisappear`.
        .onAppear { speechService.transportHostDidAppear(transportHostID) }
        .onDisappear { speechService.transportHostDidDisappear(transportHostID) }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let latestID = session.chatHistoryViewModel.currentChatMessages.first?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(latestID, anchor: .bottom)
        }
    }

    // [Unified card] ONE input structure for both states — collapsed shows just this card,
    // expanded shows top bar + transcript + this card. One editor identity (focus and drafts
    // survive expand/collapse), no duplicated layouts for fixes to drift between.
    @ViewBuilder
    private var inputCardView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 1. Attached File Chips — ABOVE the editor, matching the main composer
            // (ChatInputAreaView renders AttachedFilesDisplayView above the input area).
            if !attachedFiles.isEmpty {
                AttachedFilesDisplayView(attachedFiles: attachedFiles) { file in
                    attachedFiles.removeAll { $0.id == file.id }
                    QuickAccessScreenCaptureService.deleteCaptureTempFileIfNeeded(file.url)
                }
                .environment(\.appTheme, themeManager.currentTheme)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            // 2. Editor — the app's real composer editor: Return sends, Shift/Option+Return
            // inserts a newline, auto-grows ~1→4 lines (the window follows via onGeometryChange),
            // list auto-continuation, sanitized paste, real undo. The suggestion/query-history
            // hooks are inert here (the panel has no prompt-library / @-mention data source);
            // Escape passes through to the panel (dismiss / HITL-deny) instead of NSTextView's
            // word-completion.
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Ask anything")
                        .foregroundColor(placeholderTextColor)
                        .font(themeManager.chatFont)
                        .padding(.leading, 12 + 7) // editor h-padding + inset(2)+lineFragmentPadding(5)
                        .padding(.top, 8 + 10)     // editor top padding + textContainerInset
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                CustomTextEditor(
                    text: $inputText,
                    onCommit: { _ in submitQuery() },
                    minHeight: editorMinHeight,
                    maxHeight: editorMaxHeight,
                    fontSize: themeManager.chatFontSize,
                    lineSpacing: themeManager.chatLineSpacing,
                    showPromptSuggestions: .constant(false),
                    suggestionQuery: .constant(""),
                    activePromptTriggerRange: .constant(nil),
                    showFileSuggestions: .constant(false),
                    fileSuggestionQuery: .constant(""),
                    activeFileMentionTriggerRange: .constant(nil),
                    // ⚠️ `/` is Agent-profile only and QuickAccess has no profile context, so the
                    // picker is off here — as `#` and `@` already are. A trigger that opened a
                    // picker QuickAccess cannot act on would be worse than no trigger.
                    showSkillSuggestions: .constant(false),
                    skillSuggestionQuery: .constant(""),
                    activeSkillTriggerRange: .constant(nil),
                    attributedTextInsertion: .constant(nil),
                    textViewRef: { tv in editorTextView = tv },
                    escapePassesThrough: true
                )
                // CONTENT-driven height, not proposal-driven: fixedSize asks the editor for its
                // ideal height (sizeThatFits clamps it to min…max internally). A
                // .frame(minHeight:maxHeight:) here was FLEXIBLE — expanded stretched it to the
                // full maxHeight (huge card), and collapsed clamped it to the fixed window so
                // typed lines never changed the measured height (no window growth, text
                // overflowing onto the toolbar row).
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 12)
                .accessibilityLabel("Ask anything")
            }

            // 3. Toolbar Row — shared composer primitives (ComposerKit), capability-gated.
            HStack(spacing: 8) {
                profilePickerButton
                composerAttachAndCaptureButtons
                Spacer()
                // [Context gauge] Same window-occupancy ring as the main composer.
                if let contextUsage {
                    ContextWindowGauge(usage: contextUsage) { profileID in
                        onOpenProfileSettings?(profileID)
                    }
                }
                composerMicAndSendButtons
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        // [UI audit B] Card chrome only in EXPANDED (inset card over the transcript). Collapsed
        // is full-bleed: the window's glass IS the container — a nested bg/stroke would read as
        // a card-inside-a-bubble with mismatched radii.
        .background(isExpanded ? Color.primary.opacity(0.03) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(isExpanded ? 0.08 : 0), lineWidth: 1)
        )
    }

    /// [Unified card] Focus the editor (summon-and-type, post-dictation, post-capture). The
    /// NSTextView ref arrives asynchronously from the representable, so retry a few ticks.
    private func focusEditor(retriesLeft: Int = 4) {
        DispatchQueue.main.async {
            if let tv = editorTextView, let window = tv.window {
                window.makeFirstResponder(tv)
            } else if retriesLeft > 0 {
                focusEditor(retriesLeft: retriesLeft - 1)
            }
        }
    }

    // [QA revival P1b] Compact profile chip. Presents the app's standard ProfileSelectorPopover
    // (search + type bubbles + list) filtered to chat-type profiles only — the panel is a chat
    // surface and must never offer/run a workflow. The choice is remembered across panel sessions.
    @ViewBuilder
    private var profilePickerButton: some View {
        Button(action: { showingProfilePopup = true }) {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.selectedProfile?.profileType.displayColor ?? Color(white: 0.55))
                    .frame(width: 8, height: 8)
                // [M10] Profile name is user data (verbatim); the fallback is localized.
                Text(session.selectedProfile?.displayName ?? String(localized: "Select profile"))
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(iconColor.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1)) // [UI audit gap 5] uniform stroke weight
        }
        .buttonStyle(PlainButtonStyle())
        .help("Select the chat profile this panel uses")
        .accessibilityLabel("Selected profile: \(session.selectedProfile?.displayName ?? "none"). Change profile")
        .popover(isPresented: $showingProfilePopup, arrowEdge: .bottom) {
            // [selector v2 demo] Redesigned picker: search + type bubbles + single list. The old
            // multi-column BackendSelectorPopup needed 360pt+ for two columns but the popover
            // resolved a smaller width → content clipped on both sides. The new view is fixed-width
            // (320), so NSPopover sizing is deterministic. preferredColorScheme pins the popover
            // (its own window, system-appearance by default) to the app theme, matching the panel.
            ProfileSelectorPopover(
                configuration: session.backendConfiguration,
                isPresented: $showingProfilePopup,
                allowedProfileTypes: QuickAccessSessionViewModel.allowedProfileTypes,
                onManageProfiles: {
                    if let id = session.backendConfiguration.selectedProfileID ?? session.selectedProfile?.id {
                        onOpenProfileSettings?(id)
                    }
                }
            )
            .frame(width: 356, height: 460)
            .environment(\.appTheme, themeManager.currentTheme)
            .tint(themeManager.currentTheme.accentColor)
            .preferredColorScheme(themeManager.currentTheme.colorScheme)
        }
        .onChange(of: session.backendConfiguration.selectedProfileID) { _, _ in
            session.rememberSelectedProfile()
        }
    }

    private func captureScreenshot() {
        guard !isCapturing else { return }
        switch QuickAccessScreenCaptureService.ensurePermission() {
        case .denied:
            showCaptureDeniedPopover = true
        case .granted:
            isCapturing = true
            Task { @MainActor in
                defer { isCapturing = false }
                guard let url = await QuickAccessScreenCaptureService.captureInteractive() else { return }
                appendAttachments([FileSystemItem(id: url, name: url.lastPathComponent, url: url, isDirectory: false)])
                focusEditor()
            }
        }
    }


    /// Shown when screenshot capture is blocked by a denied Screen-Recording permission.
    /// (Rebuilt — the original was lost with the old screenCaptureButton in a row refactor.)
    @ViewBuilder
    private var captureDeniedPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Screen Recording permission needed", systemImage: "exclamationmark.shield")
                .font(.system(.subheadline, weight: .semibold))
            Text("Enable Devgentic under Privacy & Security → Screen Recording, then relaunch the app.")
                .font(.system(.caption))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                QuickAccessScreenCaptureService.openSystemSettings()
                showCaptureDeniedPopover = false
            }
            .font(.system(.caption, weight: .semibold))
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private var voiceModelHelpPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Voice model needed", systemImage: "waveform")
                .font(.system(.subheadline, weight: .semibold))
            Text("Voice dictation needs a speech model. Download one from the main Devgentic window, then reopen this panel.")
                .font(.system(.caption))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Devgentic") {
                showVoiceModelPopover = false
                AppDelegate.shared?.activateMainWindow()
            }
            .font(.system(.caption, weight: .semibold))
        }
        .padding(14)
        .frame(width: 260)
    }

    @ViewBuilder
    private var micDeniedPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Microphone access needed", systemImage: "mic.slash")
                .font(.system(.subheadline, weight: .semibold))
            Text("Enable Microphone access for Devgentic under Privacy & Security to use voice dictation.")
                .font(.system(.caption))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                showMicDeniedPopover = false
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(.caption, weight: .semibold))
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - Shared composer buttons [Composer P1]
    // ComposerKit primitives, gated on this surface's ComposerCapabilities — e.g. screenshot is
    // a capability flip, not view surgery. Used by both the expanded and collapsed rows.

    @ViewBuilder
    private var composerAttachAndCaptureButtons: some View {
        if capabilities.attachments {
            ComposerIconButton(systemName: "paperclip", help: "Attach files") { openFilePicker() }
        }
        if capabilities.screenshot {
            ComposerIconButton(systemName: "camera.viewfinder", help: "Capture screenshot") { captureScreenshot() }
                // Restored: this popover was detached in a row refactor, so a denied
                // Screen-Recording permission silently did nothing.
                .popover(isPresented: $showCaptureDeniedPopover, arrowEdge: .bottom) {
                    captureDeniedPopover
                }
        }
    }

    @ViewBuilder
    private var composerMicAndSendButtons: some View {
        if capabilities.voice {
            ComposerMicButton(
                isRecording: voice.isRecording,
                isReady: voice.isModelReady,
                action: { toggleDictation() }
            )
            .popover(isPresented: $showVoiceModelPopover, arrowEdge: .bottom) {
                voiceModelHelpPopover
            }
            .popover(isPresented: $showMicDeniedPopover, arrowEdge: .bottom) {
                micDeniedPopover
            }
        }
        ComposerSendStopButton(
            isSending: session.isSending,
            isDisabled: !session.isSending && inputText.isEmpty && attachedFiles.isEmpty,
            action: {
                if session.isSending { session.stop() } else { submitQuery() }
            }
        )
    }

    // [Composer P2] Dictation session logic (C9 re-entry guard, permission flow, VAD auto-stop,
    // live mirroring) lives in the shared ComposerVoiceController now — the view only decides
    // WHAT to do with the transcript/denial (callbacks wired in onAppear) and WHEN to toggle.
    private func toggleDictation() {
        if voice.isRecording {
            voice.stop()
        } else if voice.isModelReady {
            // Blur the editor for the dictation session: CustomTextEditor's updateNSView refuses
            // external text while the user is mid-edit (isTyping guard, reset on blur), which
            // would block the live transcript mirror. onFinished refocuses.
            editorTextView?.window?.makeFirstResponder(nil)
            voice.start(baseText: inputText.isEmpty ? "" : inputText + " ")
        } else {
            // [L6] No speech model downloaded yet — explain, don't silently do nothing.
            showVoiceModelPopover = true
        }
    }

    // [QA revival P2a / Q8] File attachment via the shared FileAttachmentPicker. Presented as a
    // SHEET on the panel — a detached picker opens at normal window level BEHIND this floating
    // panel (non-activating app, nothing promotes it) and is barely reachable.
    private func openFilePicker() {
        FileAttachmentPicker.presentOpenPanel(attachedTo: editorTextView?.window) { items in
            appendAttachments(items)
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        FileAttachmentPicker.handleDrop(providers) { item in appendAttachments([item]) }
    }

    private func appendAttachments(_ items: [FileSystemItem]) {
        for item in items where !attachedFiles.contains(where: { $0.id == item.id }) {
            attachedFiles.append(item)
        }
        if !isExpanded { isExpanded = true }
    }

    private func copyLastMessageToClipboard() {
        // [Q9] Reuse the shared VM method (now selected-variant aware) instead of a duplicate.
        guard let lastMessage = session.chatHistoryViewModel.currentChatMessages.first else { return }
        session.chatHistoryViewModel.copyMessageContentToClipboard(message: lastMessage)
    }
}

// MARK: - Premium UI Button Helpers

struct QuickAccessTopButton: View {
    let icon: String
    let action: () -> Void
    var disabled: Bool = false
    var tooltip: String = ""
    let normalColor: Color
    let hoverColor: Color
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(.body, weight: .medium))
                .foregroundColor(disabled ? normalColor.opacity(0.3) : (isHovered ? hoverColor : normalColor))
                .frame(width: 28, height: 28)
                .background(isHovered && !disabled ? Color.primary.opacity(0.08) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
        .help(tooltip)
        .onHover { hover in
            isHovered = hover
        }
    }
}

struct QuickAccessCloseButton: View {
    let action: () -> Void
    let iconColor: Color
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isHovered ? Color.red.opacity(0.15) : Color.primary.opacity(0.05))
                    .frame(width: 24, height: 24)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isHovered ? .red : iconColor)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hover in
            isHovered = hover
        }
    }
}



/// [drag-vs-select fix] An AppKit drag surface for the borderless panel. Placed behind the content
/// (in front of the glass), it lets the user move the window by dragging empty/chrome areas — a
/// bare mouse-down starts `performDrag`, which no-ops if the pointer doesn't actually move. It
/// carries NO drawing and sits under the interactive controls, so the text field / buttons /
/// transcript hit-test in front of it and keep their own selection/click/scroll behavior. This
/// replaces `isMovableByWindowBackground`, which stole drags over the input field.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggingView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        // Purely a drag surface — never becomes first responder / doesn't affect layout hit order
        // beyond being the backmost interactive layer.
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
