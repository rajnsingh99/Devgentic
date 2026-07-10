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
import AVFoundation // For mic-permission request (voice dictation)

struct QuickAccessContentView: View {
    // --- Callbacks ---
    var dismiss: () -> ()
    var onResize: ((CGFloat) -> Void)?
    var onToggleZoom: (() -> Void)?
    // [QA revival P2e] Hand the current conversation back to the main window.
    var onContinueInMainWindow: ((UUID) -> Void)?
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
    // [QA revival P0] Drives first-responder focus so the panel is ready to type the
    // moment it is summoned. Bound to whichever input field is currently on screen.
    @FocusState private var isInputFocused: Bool
    // [QA revival P1b] Profile picker popover state.
    @State private var showingProfilePopup: Bool = false
    // [QA revival P2a] Files attached to the next message (panel-local; passed to send()).
    @State private var attachedFiles: [FileSystemItem] = []
    // [QA revival P2b] Voice dictation state (drives WhisperRecognitionService.shared directly).
    @State private var isRecording: Bool = false
    @State private var voiceBaseText: String = ""
    @State private var voiceTask: Task<Void, Never>?
    // [QA revival P3] Screen-capture state.
    @State private var isCapturing: Bool = false
    @State private var showCaptureDeniedPopover: Bool = false
    // [L6] Shown when the mic is tapped but no speech model is downloaded yet.
    @State private var showVoiceModelPopover: Bool = false
    // [L3] Shown when microphone permission is denied.
    @State private var showMicDeniedPopover: Bool = false
    @State private var isMenuHovered: Bool = false

    // --- Styling Constants ---
    // [H3] Chrome colors come from the app theme, not hardcoded white, so the panel stays
    // legible in Light Mode. The panel's NSAppearance is pinned to the theme's colorScheme
    // (QuickAccessPanelView.setupContentView) so the Liquid Glass backdrop renders in the same
    // mode these tokens are designed against.
    private var theme: any Theme { themeManager.currentTheme }
    private var iconColor: Color { theme.secondaryText }
    private var placeholderTextColor: Color { theme.placeholderText }
    private var textColor: Color { theme.primaryText }
    let inputBarHeight: CGFloat = 95
    let textFieldHeight: CGFloat = 40
    let buttonRowHeight: CGFloat = 30
    let expandedViewMinHeight: CGFloat = 400
    let topBarHeight: CGFloat = 40
    let panelCornerRadius: CGFloat = 12
    let expandedInputAreaHorizontalMargin: CGFloat = 10
    let contentViewMinWidth: CGFloat = 400
    let expandedInputAreaMaxAllowedWidth: CGFloat = 700

    init(dismiss: @escaping () -> (),
         onResize: ((CGFloat) -> Void)? = nil,
         onToggleZoom: (() -> Void)? = nil,
         onContinueInMainWindow: ((UUID) -> Void)? = nil,
         isExpanded: Bool = false,
         shouldResumeSession: Bool = true,
         mainAppViewModel: MainApplicationViewModel,
         themeManager: ThemeManager,
         onRegisterHITLKeyHandler: ((@escaping (QuickAccessHITLKeyAction) -> Bool) -> Void)? = nil) {
        self.dismiss = dismiss
        self.onResize = onResize
        self.onToggleZoom = onToggleZoom
        self.onContinueInMainWindow = onContinueInMainWindow
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
                inputAreaViewContainer
                    .frame(maxWidth: isExpanded ? expandedInputAreaMaxAllowedWidth : .infinity)
                    .padding(.horizontal, isExpanded ? expandedInputAreaHorizontalMargin : 0)
            }
        }
        .frame(minWidth: contentViewMinWidth)
        // MARK: Liquid Glass — replace material + stroke + shadow with glassEffect
        .background(.clear)
        .clipShape(RoundedRectangle(cornerRadius: isExpanded ? panelCornerRadius : 20, style: .continuous))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: isExpanded ? panelCornerRadius : 20))
        // [L5] Match the window-frame animation (NSAnimationContext 0.3s ease in
        // resizePanelProgrammatically) with a non-overshooting ease of the SAME duration — a spring
        // here overshot the window bounds and clipped the glass edge mid-expand.
        .animation(.easeInOut(duration: 0.3), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: isPanelZoomedToFullScreen)
        .onChange(of: isExpanded) { _, newValue in
            let newIdealHeight = newValue ? expandedViewMinHeight : inputBarHeight
            onResize?(newIdealHeight)
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
             let currentIdealHeight = isExpanded ? expandedViewMinHeight : inputBarHeight
             onResize?(currentIdealHeight)
             // [QA revival P0] Summon-and-type: focus the input once the panel has become
             // key. Deferred a runloop tick so focus lands after the window is shown.
             DispatchQueue.main.async { isInputFocused = true }
             // [QA revival P1a/P1e] Load the persisted QuickAccess conversation (if resuming);
             // a timed-out session starts fresh.
             session.prepareSession(resume: shouldResumeSession)
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
            if isRecording { stopDictation() }
            // [H1] Any still-attached (never-sent) screen captures are orphaned when the panel is
            // rebuilt on the next summon — delete their temp files now.
            for file in attachedFiles {
                QuickAccessScreenCaptureService.deleteCaptureTempFileIfNeeded(file.url)
            }
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
            // [QA revival P1c] Hide Redo/Resume in panel bubbles — they target the main
            // window's conversation state and would no-op here.
            .environment(\.chatActionsSuppressed, true)
            .onChange(of: session.chatHistoryViewModel.currentChatMessages.first?.id) { _, _ in
                scrollToLatest(proxy)
            }
            .onChange(of: session.streamingMessageID) { _, _ in
                scrollToLatest(proxy)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        guard let latestID = session.chatHistoryViewModel.currentChatMessages.first?.id else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(latestID, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var inputAreaViewContainer: some View {
        Group {
            if isExpanded {
                expandedInputAreaLayout
                    .padding(.bottom, 12)
                    .padding(.horizontal, 12)
            } else {
                collapsedInputAreaLayout
                    .padding(.horizontal, 12)
                    .frame(height: inputBarHeight)
            }
        }
    }

    @ViewBuilder
    private var expandedInputAreaLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 1. Text Field
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Ask anything")
                        .foregroundColor(placeholderTextColor)
                        .font(.system(.body))
                        .padding(.top, 8)
                        .padding(.horizontal, 12)
                        .accessibilityHidden(true)
                }
                TextField("", text: $inputText, axis: .vertical)
                    .textFieldStyle(PlainTextFieldStyle())
                    .foregroundColor(textColor)
                    .font(.system(.body))
                    .lineLimit(1...6)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .focused($isInputFocused)
                    .onSubmit { submitQuery() }
                    .accessibilityLabel("Ask anything")
            }
            .frame(minHeight: textFieldHeight)

            // 2. Attached File Chips
            if !attachedFiles.isEmpty {
                AttachedFilesDisplayView(attachedFiles: attachedFiles) { file in
                    attachedFiles.removeAll { $0.id == file.id }
                    QuickAccessScreenCaptureService.deleteCaptureTempFileIfNeeded(file.url)
                }
                .environment(\.appTheme, themeManager.currentTheme)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // 3. Toolbar Row
            HStack(spacing: 8) {
                profilePickerButton

                Button(action: { openFilePicker() }) {
                    Image(systemName: "paperclip")
                        .font(.system(.body, weight: .medium))
                        .foregroundColor(iconColor)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .help("Attach files")
                .accessibilityLabel("Attach files")

                Button(action: { captureScreenshot() }) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(.body, weight: .medium))
                        .foregroundColor(iconColor)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .help("Capture screenshot")
                .accessibilityLabel("Capture screenshot")

                Spacer()

                QuickAccessDictationButton(
                    isRecording: isRecording,
                    isVoiceModelReady: isVoiceModelReady,
                    iconColor: iconColor,
                    hoverColor: textColor,
                    action: { toggleDictation() }
                )
                .popover(isPresented: $showVoiceModelPopover, arrowEdge: .bottom) {
                    voiceModelHelpPopover
                }
                .popover(isPresented: $showMicDeniedPopover, arrowEdge: .bottom) {
                    micDeniedPopover
                }

                QuickAccessSendButton(
                    isSending: session.isSending,
                    isDisabled: !session.isSending && inputText.isEmpty && attachedFiles.isEmpty,
                    iconColor: iconColor,
                    accentColor: themeManager.currentTheme.accentColor,
                    action: {
                        if session.isSending { session.stop() } else { submitQuery() }
                    }
                )
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var collapsedInputAreaLayout: some View {
        HStack(spacing: 8) {
            profilePickerButton

            ZStack(alignment: .leading) {
                if inputText.isEmpty {
                    Text("Ask anything")
                        .foregroundColor(placeholderTextColor)
                        .font(.system(.body))
                        .padding(.horizontal, 8)
                        .accessibilityHidden(true)
                }
                TextField("", text: $inputText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .foregroundColor(textColor)
                    .font(.system(.body))
                    .padding(.horizontal, 8)
                    .focused($isInputFocused)
                    .onSubmit { submitQuery() }
                    .accessibilityLabel("Ask anything")
            }
            .frame(height: textFieldHeight)

            HStack(spacing: 6) {
                Button(action: { openFilePicker() }) {
                    Image(systemName: "paperclip")
                        .font(.system(.body, weight: .medium))
                        .foregroundColor(iconColor)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .help("Attach files")
                .accessibilityLabel("Attach files")

                Button(action: { captureScreenshot() }) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(.body, weight: .medium))
                        .foregroundColor(iconColor)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.04))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .help("Capture screenshot")
                .accessibilityLabel("Capture screenshot")

                QuickAccessDictationButton(
                    isRecording: isRecording,
                    isVoiceModelReady: isVoiceModelReady,
                    iconColor: iconColor,
                    hoverColor: textColor,
                    action: { toggleDictation() }
                )
                .popover(isPresented: $showVoiceModelPopover, arrowEdge: .bottom) {
                    voiceModelHelpPopover
                }
                .popover(isPresented: $showMicDeniedPopover, arrowEdge: .bottom) {
                    micDeniedPopover
                }

                QuickAccessSendButton(
                    isSending: session.isSending,
                    isDisabled: !session.isSending && inputText.isEmpty && attachedFiles.isEmpty,
                    iconColor: iconColor,
                    accentColor: themeManager.currentTheme.accentColor,
                    action: {
                        if session.isSending { session.stop() } else { submitQuery() }
                    }
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
            .overlay(Capsule().stroke(theme.primaryText.opacity(0.18), lineWidth: 1)) // [H3] theme-aware border
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
                allowedProfileTypes: QuickAccessSessionViewModel.allowedProfileTypes
            )
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
                isInputFocused = true
            }
        }
    }

    // [QA revival P2b] Voice dictation. Drives WhisperRecognitionService.shared directly (the
    // app-scoped ChatInputViewModel is single-slot and would cross-wire with the main window).
    // The model must already be loaded (.loaded); the button is disabled otherwise.
    private var isVoiceModelReady: Bool {
        if case .loaded = WhisperRecognitionService.shared.loadingState { return true }
        return false
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

    private func toggleDictation() {
        if isRecording {
            stopDictation()
        } else if isVoiceModelReady {
            startDictation()
        } else {
            // [L6] No speech model downloaded yet — explain, don't silently do nothing.
            showVoiceModelPopover = true
        }
    }

    private func startDictation() {
        let svc = WhisperRecognitionService.shared
        // [C9] Re-entry guard: flip isRecording SYNCHRONOUSLY (this runs on the MainActor from a
        // Button action) so a rapid second tap toggles to Stop instead of launching a second
        // concurrent Whisper session on the shared service.
        guard case .loaded = svc.loadingState, !isRecording else { return }
        isRecording = true
        voiceBaseText = inputText.isEmpty ? "" : inputText + " "
        if !isExpanded { isExpanded = true }

        // One task owns the whole session (permission → stream). @MainActor so the @State
        // writes below (incl. the voiceTask self-clear) are all main-thread safe.
        voiceTask = Task { @MainActor in
            guard await AVAudioApplication.requestRecordPermission() else {
                isRecording = false
                voiceTask = nil
                showMicDeniedPopover = true // [L3] surface the denial instead of silently bailing
                return
            }
            // A stop() during the permission prompt cancels us before the mic ever opens.
            guard !Task.isCancelled else { isRecording = false; return }
            // startStreaming BLOCKS until stopStreaming() or VAD auto-stop.
            try? await svc.startStreaming { state in
                Task { @MainActor in
                    // Live transcription mirrors into the input field as it's spoken.
                    if isRecording { inputText = voiceBaseText + state.fullText }
                }
            }
            // VAD auto-stop path: startStreaming returned on its own.
            isRecording = false
            voiceTask = nil
        }
    }

    private func stopDictation() {
        guard isRecording else { return }
        voiceTask?.cancel() // bail if we're still awaiting the mic-permission prompt
        voiceTask = nil
        isRecording = false
        let base = voiceBaseText
        Task { @MainActor in
            let final = await WhisperRecognitionService.shared.stopStreaming()
            if let final, !final.isEmpty { inputText = base + final }
            isInputFocused = true
        }
    }

    // [QA revival P2a / Q8] File attachment via the shared FileAttachmentPicker.
    private func openFilePicker() {
        FileAttachmentPicker.presentOpenPanel { items in appendAttachments(items) }
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

struct QuickAccessDictationButton: View {
    let isRecording: Bool
    let isVoiceModelReady: Bool
    let iconColor: Color
    let hoverColor: Color
    let action: () -> Void
    @State private var isHovered = false
    @State private var scale: CGFloat = 1.0
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.15)
                            .shadow(.drop(color: Color.red.opacity(0.3), radius: 2)))
                        .frame(width: 28, height: 28)
                        .scaleEffect(scale)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                                scale = 1.25
                            }
                        }
                        .onDisappear {
                            scale = 1.0
                        }
                }
                
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(.body, weight: .medium))
                    .foregroundColor(isRecording ? .red : (isVoiceModelReady ? (isHovered ? hoverColor : iconColor) : iconColor.opacity(0.3)))
                    .frame(width: 28, height: 28)
                    .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    .clipShape(Circle())
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hover in
            isHovered = hover
        }
    }
}

struct QuickAccessSendButton: View {
    let isSending: Bool
    let isDisabled: Bool
    let iconColor: Color
    let accentColor: Color
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if isSending {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 28, height: 28)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.red)
                } else {
                    Circle()
                        .fill(!isDisabled ? (isHovered ? accentColor.opacity(0.9) : accentColor) : Color.primary.opacity(0.03))
                        .frame(width: 28, height: 28)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(!isDisabled ? .white : iconColor.opacity(0.3))
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isDisabled)
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
