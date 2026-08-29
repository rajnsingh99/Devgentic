//
//  MainApplicationView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import os

private let logger = DGLogger(category: "MainApplicationView")

// MARK: - Localized Titles

extension MainApplicationViewModel.InterfaceMode {
    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` is a PERSISTENCE key — `SettingsCoordinator`
    /// round-trips it through UserDefaults (`devgentic.interfaceMode`) — so it must never change.
    /// Declared here rather than beside the enum so the view-model file stays view-layer free.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .chat:     return "Chat"
        case .workflow: return "Workflow"
        case .code:     return "Code"
        }
    }
}

// MARK: - Main View
struct MainApplicationView: View {
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    @FocusState private var isInputFocused: Bool
    
    @AppStorage("sidebar.isVisible") private var isSidebarVisible: Bool = true
    @AppStorage("sidebar.paneWidth") private var currentSidebarPaneWidth: Double = 320
    /// Same key the Code Viewer panel persists its divider width to. Read here so split
    /// mode can inset the chat by the panel's width. Updates on drag END (not per tick),
    /// so the chat reflows ONCE per resize instead of re-laying-out every bubble at the
    /// mouse's report rate — the panel overlaps the delta live, exactly like overlay mode.
    @AppStorage("codeViewerPanelWidth") private var codeViewerPanelWidth: Double = 600
    @State private var showModePicker: Bool = true
    /// Window content width, for clamping the split inset (measured, not derived — the
    /// window is user-resizable). `.infinity` until the first geometry pass, which makes
    /// the clamp a no-op rather than squeezing the chat to the floor at startup.
    @State private var windowContentWidth: CGFloat = .infinity
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @State private var scrollDirectionMonitor: Any?
    #endif

    private let activityBarWidth: CGFloat = 50
    private let sidebarGap: CGFloat = 12
    private var totalSidebarWidth: CGFloat {
        (isSidebarVisible ? CGFloat(currentSidebarPaneWidth) : 0) + activityBarWidth + (sidebarGap * 1.5)
    }

    /// Trailing inset the chat area yields to the Code Viewer in split mode (EXPERIMENTAL).
    /// Zero in overlay/full (overlay covers; full replaces). The desired inset is the
    /// panel's full FOOTPRINT — content width plus its divider — plus a breathing gutter,
    /// so chat text doesn't sit flush against the divider edge. Capped so the chat never
    /// drops below `splitModeMinChatWidth` — past that the panel overlaps the difference,
    /// which is the historic overlay behaviour rather than an unreadable sliver of chat.
    private var chatSplitInset: CGFloat {
        guard chatHistoryViewModel.codeViewerPresentation == .split,
              chatHistoryViewModel.isCodeViewerPanelPresented else { return 0 }
        let desired = CGFloat(codeViewerPanelWidth)
            + ChatUIConstants.codeViewerDividerWidth
            + ChatUIConstants.splitModeChatGutter
        // The floor accounts for BOTH gutters (leading one below + this trailing one) so
        // the actual text column, not just the padded region, keeps its minimum width.
        let maxInset = windowContentWidth - totalSidebarWidth - ChatUIConstants.splitModeChatGutter
            - ChatUIConstants.splitModeMinChatWidth
        return max(0, min(desired, maxInset))
    }

    /// Leading breathing room between the sidebar edge and the chat column in split mode
    /// (mirrors `splitModeChatGutter` on the trailing side). Only in split: a squeezed
    /// column runs edge-to-edge, so without this the text sits flush against the activity
    /// bar. In overlay/full the chat is wide/covered and centers its own margins.
    private var chatSplitLeadingGutter: CGFloat {
        chatSplitInset > 0 ? ChatUIConstants.splitModeChatGutter : 0
    }

    /// Binding that bridges the `Double` stored in `@AppStorage` to the
    /// `CGFloat` expected by `VSCodifiedSidebarContainerView`.
    private var sidebarPaneWidthCGFloat: Binding<CGFloat> {
        Binding(
            get: { CGFloat(currentSidebarPaneWidth) },
            set: { currentSidebarPaneWidth = Double($0) }
        )
    }

    private let inputAreaCornerRadius: CGFloat = 12
    
    // MARK: - Body
    var body: some View {
        ZStack(alignment: .leading) {
            ZStack {
                theme.primaryBackground
                
                // Ambient Aura Glows (Provides texture for Liquid Glass refraction)
                if theme.id != "one_light" {
                    GeometryReader { geo in
                        ZStack {
                            Circle()
                                .fill(theme.accentColor.opacity(0.06))
                                .frame(width: geo.size.width * 0.45, height: geo.size.width * 0.45)
                                .blur(radius: 130)
                                .offset(x: -geo.size.width * 0.15, y: -geo.size.height * 0.1)
                            
                            Circle()
                                .fill(Color.orange.opacity(0.035))
                                .frame(width: geo.size.width * 0.4, height: geo.size.width * 0.4)
                                .blur(radius: 110)
                                .offset(x: geo.size.width * 0.35, y: geo.size.height * 0.25)
                        }
                    }
                } else {
                    GeometryReader { geo in
                        ZStack {
                            Circle()
                                .fill(theme.accentColor.opacity(0.04))
                                .frame(width: geo.size.width * 0.4, height: geo.size.width * 0.4)
                                .blur(radius: 100)
                                .offset(x: -geo.size.width * 0.1, y: -geo.size.height * 0.1)
                        }
                    }
                }
            }
            .edgesIgnoringSafeArea(.all)
            
            // Leading-aligned on purpose: the sidebar is the only fixed-width child here,
            // and under the default centre alignment it drifts — then slides off the window
            // entirely once the other layers demand more width than the window has.
            ZStack(alignment: .leading) {
                // LAYER 1: Chat — always alive, visibility toggled via opacity
                chatArea
                    .opacity(router.isShowingChat ? 1 : 0)
                    .allowsHitTesting(router.isShowingChat)

                // LAYER 2: Non-chat destinations — created on demand
                if !router.isShowingChat {
                    destinationView
                        .transition(.opacity)
                }

                // Floating mode switcher is an overlay on chatArea's input VStack
            }
            .padding(.leading, totalSidebarWidth + chatSplitLeadingGutter)
            // EXPERIMENTAL split mode: the chat YIELDS layout space to the Code Viewer
            // instead of being covered by it — a trailing inset, not a re-parent, so the
            // panel keeps its view identity (and the editor its state) across mode flips.
            .padding(.trailing, chatSplitInset)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            .onReceive(NotificationCenter.default.publisher(for: .requestSidebarVisible)) { _ in
                // The Tool Library's navigation IS the pane; entering it with the pane
                // hidden would leave no way to change category or pick a server.
                guard !isSidebarVisible else { return }
                isSidebarVisible = true
            }
            .animation(.easeInOut(duration: 0.1), value: currentSidebarPaneWidth)
            .animation(.easeInOut(duration: 0.2), value: router.activeDestination)
            .animation(.easeInOut(duration: 0.2), value: chatSplitInset)
            
            VSCodifiedSidebarContainerView(
                isSidebarVisible: $isSidebarVisible,
                sidebarWidth: sidebarPaneWidthCGFloat
            )
            .frame(width: totalSidebarWidth)
            .zIndex(1)

            if chatHistoryViewModel.isCodeViewerPanelPresented {
                CodeViewerPanelView()
                    .environment(chatHistoryViewModel)
                    // Full AND split cover the CHAT, never the sidebar: inset by the same
                    // leading width the chat area uses so navigation stays reachable. This
                    // is also what bounds the panel — it measures its own frame for the
                    // drag cap, so excluding the sidebar keeps a wide drag off it.
                    // Overlay alone keeps the historic un-inset trailing overlay.
                    .padding(.leading, chatHistoryViewModel.codeViewerPresentation == .overlay ? 0 : totalSidebarWidth)
                    .zIndex(2)
            }

            // Floating reopen pill — shown only when the viewer was minimized with tabs still
            // open (mutually exclusive with the panel above, so they never overlap).
            if chatHistoryViewModel.isCodeViewerMinimized {
                CodeViewerFloatingButton()
                    .environment(chatHistoryViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 14)
                    .padding(.trailing, 18)
                    .zIndex(3)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            Button(action: {
                if viewModel.interfaceMode == .workflow {
                    viewModel.deselectConversationAndShowWelcome()
                    logger.debug("Triggered new workflow (deselect) via Cmd+N.")
                } else if viewModel.interfaceMode == .code {
                    viewModel.deselectConversationAndShowWelcome()
                    logger.debug("Triggered new code session via Cmd+N.")
                } else {
                    viewModel.startNewConversation()
                    logger.debug("Triggered new conversation via Cmd+N.")
                }
                if isSidebarVisible {
                    isSidebarVisible = false
                    logger.debug("Hid sidebar pane via Cmd+N.")
                }
            }) { EmptyView() }
                .hidden()
                .keyboardShortcut("n", modifiers: .command)
        }
        .frame(minWidth: 800, minHeight: 500)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            windowContentWidth = newWidth
        }
        .preferredColorScheme(theme.id == "one_light" ? .light : (theme.id == "dracula" ? .dark : nil))
        .onAppear {
             if viewModel.selectedConversationID != nil && router.isShowingChat {
                 DispatchQueue.main.async { isInputFocused = true }
             }
             #if canImport(AppKit) && !targetEnvironment(macCatalyst)
             setupScrollDirectionMonitor()
             #endif
         }
        .onDisappear {
             #if canImport(AppKit) && !targetEnvironment(macCatalyst)
             teardownScrollDirectionMonitor()
             #endif
         }
        .onChange(of: router.activeDestination) { _, newDestination in
            if newDestination == .chat && viewModel.selectedConversationID != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            } else if newDestination != .chat {
                isInputFocused = false
            }
        }
        .onChange(of: chatHistoryViewModel.isSending) { _, isNowSending in
            if !isNowSending && router.isShowingChat && viewModel.selectedConversationID != nil {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            }
        }
        .onChange(of: chatHistoryViewModel.codeViewerPresentation) { oldMode, newMode in
            // Entering split: auto-collapse the sidebar PANE so the chat keeps a readable
            // column — expanded sidebar + panel + chat is one region too many. One-shot on
            // the TRANSITION only: re-expanding afterwards is the user's call and nothing
            // fights them for it (leaving split deliberately does not auto-restore either).
            // `isCodeViewerVisible` is load-bearing: restoring a conversation whose saved
            // session was in split mode replays this transition with the panel still hidden,
            // which collapsed the sidebar for a panel the user could not see (field-observed
            // 2026-07-25 — they re-opened it by hand each switch).
            if newMode == .split, oldMode != .split, isSidebarVisible,
               chatHistoryViewModel.isCodeViewerVisible {
                isSidebarVisible = false
                logger.debug("[CodeViewer] Split enabled — sidebar pane auto-collapsed.")
            } else if newMode == .split, oldMode != .split, isSidebarVisible {
                logger.debug("[CodeViewer] Split restored while the panel is hidden — sidebar left expanded.")
            }
        }
        .onChange(of: viewModel.selectedConversationID) { _, newID in
            if newID != nil {
                if chatHistoryViewModel.isUserMessagesOnlyFilterActive {
                    chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
                    logger.info("Reset user messages filter due to conversation change.")
                }
                if router.isShowingChat {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isInputFocused = true
                    }
                }
            } else {
                isInputFocused = false
            }
        }
        // [QA revival P2e] Deep-link + QuickAccess reverse-handoff: select the conversation in
        // the main window and flip back to chat if a non-chat destination is showing. Serves
        // both the notification-tap flow and the panel's "continue in main window" button.
        .onReceive(NotificationCenter.default.publisher(for: GlobalConstants.openConversationNotification)) { note in
            guard let idString = note.userInfo?["conversationID"] as? String,
                  let id = UUID(uuidString: idString) else { return }
            viewModel.navigateToPendingInteraction(conversationID: id, interface: .chat)
            if !router.isShowingChat { router.returnToChat() }
        }
        // Settings deep-link from outside this window's environment (the QuickAccess
        // advisory banner's reverse-handoff) — same route the in-window banner uses.
        .onReceive(NotificationCenter.default.publisher(for: GlobalConstants.openProfileSettingsNotification)) { note in
            guard let idString = note.userInfo?["profileID"] as? String,
                  let id = UUID(uuidString: idString) else { return }
            router.navigate(to: .profileDetail(profileID: id))
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var destinationView: some View {
        switch router.activeDestination {
        case .chat:
            EmptyView()
        case .profileDetail(let profileID):
            ProfileDetailContainerView(profileID: profileID)
        case .settingsDetail(let category):
            SettingsDetailContainerView(category: category)
        case .toolLibrary(let profileID):
            ToolLibraryContainerView(routeProfileID: profileID)
        case .addMCPServer:
            AddMCPServerContainerView(mode: .add)
        case .editMCPServer(let sourceID):
            AddMCPServerContainerView(mode: .edit(sourceID: sourceID))
        case .promptDetail(let promptID):
            PromptDetailContainerView(promptID: promptID)
        case .scheduledTaskDetail(let taskID):
            ScheduledTaskDetailContainerView(taskID: taskID)
        case .scheduledTaskCreate(let prefillPrompt, let prefillConversationID):
            ScheduledTaskCreateContainerView(
                prefillPrompt: prefillPrompt,
                prefillConversationID: prefillConversationID
            )
        case .ollamaModelStore(let profileID):
            OllamaModelStoreContainerView(profileID: profileID)
        case .mlxModelStore(let profileID, let filterForTools):
            MLXModelStoreContainerView(filterForTools: filterForTools, profileID: profileID)
        case .downloadManager:
            DownloadManagerContainerView()
        case .userPersonalProfile:
            UserPersonalContainerView()
        }
    }

    @ViewBuilder
    private var chatArea: some View {
        ZStack(alignment: .bottom) {
            // Content area: switches based on interface mode
            switch viewModel.interfaceMode {
            case .workflow:
                if let profileID = viewModel.backendConfiguration.selectedProfileID {
                    WorkflowDedicatedView(
                        workflowProfileID: profileID,
                        conversationID: viewModel.selectedConversationID
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 115)
                } else {
                    workflowEmptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, 115)
                }

            case .chat:
                ChatHistoryView()
                    .environment(chatHistoryViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Apply the overlay BEFORE the bottom inset so WelcomeView
                    // is inset by the same 115pt and its footer (diagnostics
                    // disclosure) no longer renders under the floating bar.
                    .overlay {
                        if viewModel.selectedConversationID == nil {
                            WelcomeView()
                        }
                    }
                    .padding(.bottom, 115)

            case .code:
                CodeDedicatedView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 115)
            }

            // Input area container
            VStack(spacing: 0) {
                // [HITL/P4] Unified banner stack — the SOLE HITL surface for every mode
                // (chat / code / workflow). Shows InteractionCenter.current(for:) one at a time
                // (FIFO) with source/node titles, plus a cross-conversation "needs input" chip.
                // The legacy StreamingMessageBannerWrapper + the `interfaceMode != .workflow` gate
                // were removed here in the P4 cutover.
                InteractionBannerStack()
                    .environment(viewModel)

                // Ambient, actionable warnings (e.g. context-overflow with a settings
                // deep-link) — deliberately BELOW the HITL stack: the advisory is
                // ambient state, so anchoring it next to the input keeps its position
                // stable while transient HITL banners come and go above it.
                // Order: HITL (top) → advisory (mid) → chat input (bottom).
                AdvisoryBannerView()
                    .environment(viewModel)

                ChatInputAreaView(
                    showContextArea: Bindable(viewModel).showContextArea,
                    activeContextFilePath: Bindable(viewModel).activeContextFilePath,
                    isSending: chatHistoryViewModel.isSending,
                    isInputFocused: $isInputFocused,
                    backendConfiguration: viewModel.backendConfiguration,
                    onSendMessage: viewModel.sendMessage,
                    onToggleContext: {
                        withAnimation { viewModel.toggleContextArea() }
                    }
                )
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 15)
                .shadow(color: SwiftUI.Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
            }
            // Floating mode picker — overlays above the input area
            .overlay(alignment: .top) {
                InterfaceModePicker()
                    .offset(y: -38)
                    .opacity(showModePicker ? 1 : 0)
                    .scaleEffect(showModePicker ? 1 : 0.9)
                    .allowsHitTesting(showModePicker)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: showModePicker)
            }
        }
        // [F2] Cross-conversation "needs input" affordance — floats at the top-center of the chat
        // area, content-hugging, so a HITL waiting in another conversation stays discoverable.
        .overlay(alignment: .top) {
            CrossConversationInputChip()
                .environment(viewModel)
                .padding(.top, 12)
        }
        .onChange(of: viewModel.interfaceMode) { _, _ in
            showModePicker = true
        }
        .onChange(of: viewModel.selectedConversationID) { _, _ in
            showModePicker = true
        }
        // Unsaved workflow-edits guard: raised by `WorkflowEditGuard.attempt` when a
        // navigation (switch conversation / interface / execution) is attempted while the
        // workflow canvas has unsaved changes. Save → persist then proceed; Discard →
        // revert then proceed; Cancel → stay.
        .confirmationDialog(
            "Unsaved Workflow Changes",
            isPresented: Binding(
                get: { viewModel.workflowEditGuard.isPrompting },
                set: { if !$0 { viewModel.workflowEditGuard.cancel() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Save Changes") { viewModel.workflowEditGuard.confirmSave() }
            Button("Discard Changes", role: .destructive) { viewModel.workflowEditGuard.confirmDiscard() }
            Button("Cancel", role: .cancel) { viewModel.workflowEditGuard.cancel() }
        } message: {
            Text("You have unsaved changes to this workflow. Save them before leaving?")
        }
    }

    private var workflowEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40))
                .foregroundColor(.purple.opacity(0.4))
            Text("Select a workflow")
                .font(theme.fontSubheadline)
                .foregroundColor(theme.secondaryText)
            Text("Choose a workflow profile from the picker below.")
                .font(theme.fontCaption)
                .foregroundColor(theme.secondaryText)
        }
    }

    // MARK: - Scroll Direction Monitor

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private func setupScrollDirectionMonitor() {
        scrollDirectionMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            let deltaY = event.scrollingDeltaY
            // Threshold avoids reacting to tiny/incidental scrolls
            guard abs(deltaY) > 3 else { return event }

            // deltaY > 0 → content scrolls toward top (reading older) → hide picker
            // deltaY < 0 → content scrolls toward bottom (back to input) → show picker
            let shouldShow = deltaY < 0
            if shouldShow != showModePicker {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                    showModePicker = shouldShow
                }
            }
            return event
        }
    }

    private func teardownScrollDirectionMonitor() {
        if let monitor = scrollDirectionMonitor {
            NSEvent.removeMonitor(monitor)
            scrollDirectionMonitor = nil
        }
    }
    #endif
}

// MARK: - Interface Mode Picker (Liquid Glass)

/// Floating Chat/Workflow/Code mode switcher using macOS Liquid Glass.
/// Uses `matchedGeometryEffect` for a sliding active-indicator that
/// glides between tabs on selection change.
private struct InterfaceModePicker: View {
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(\.appTheme) private var theme
    @Namespace private var modeAnimation

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MainApplicationViewModel.InterfaceMode.allCases, id: \.self) { mode in
                ModeTabButton(mode: mode, namespace: modeAnimation)
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(theme.secondaryBackground.opacity(0.65))
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.16), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 4)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: viewModel.interfaceMode)
    }
}

/// Individual tab button within the mode picker.
/// Extracted as a separate struct to hold its own @State for hover tracking.
/// The active tab's background capsule is animated via `matchedGeometryEffect`.
private struct ModeTabButton: View {
    let mode: MainApplicationViewModel.InterfaceMode
    var namespace: Namespace.ID
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var isActive: Bool { viewModel.interfaceMode == mode }

    private var modeColor: Color {
        switch mode {
        case .chat:     return Color(hex: "#0A84FF") // Ocean Blue
        case .workflow: return Color(hex: "#8B5CF6") // Royal Violet
        case .code:     return Color(hex: "#06B6D4") // Cosmic Cyan
        }
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                viewModel.switchInterfaceMode(to: mode)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: isActive ? .bold : .medium))
                    .foregroundColor(isActive ? modeColor : (isHovering ? theme.primaryText : theme.secondaryText))

                Text(mode.localizedTitle)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundColor(isActive ? theme.primaryText : (isHovering ? theme.primaryText : theme.secondaryText))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                if isActive {
                    Capsule()
                        .fill(theme.surfaceOverlayStrong)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [modeColor.opacity(0.65), modeColor.opacity(0.25)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: modeColor.opacity(0.22), radius: 6, x: 0, y: 1)
                        .matchedGeometryEffect(id: "activeModeIndicator", in: namespace)
                } else if isHovering {
                    Capsule()
                        .fill(theme.surfaceOverlay.opacity(0.6))
                }
            }
            // Unsaved-changes dot on the Workflow tab so the dirty state is visible even
            // when the user is looking elsewhere (sidebar, other modes).
            .overlay(alignment: .topTrailing) {
                // ⚠️ Reads the view model's MIRROR, not `workflowEditGuard.hasUnsavedChanges`. The
                // guard reflects only the canvas currently ON SCREEN and is cleared by
                // `unregister()` when it goes away — so the dot vanished the moment the user
                // navigated off, which is exactly when it was needed. The mirror is keyed by profile
                // and outlives every view teardown, so it also lights for a workflow the user edited
                // and then switched away from.
                if mode == .workflow && !viewModel.dirtyWorkflowCanvasIDs.isEmpty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -1)
                        .transition(.scale.combined(with: .opacity))
                        // Purely decorative — the meaning is announced on the BUTTON below, not
                        // here. A label on this Circle would sit inside the Button's own label
                        // subtree and never be spoken.
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        // [WF-CS4] The dot had NO tooltip and NO accessibility label, so it read as an unexplained
        // warning — and worse, as one implying the edits were at risk. They are not: the canvas
        // cache is App-scoped, survives every view teardown, and is drained at quit (WF-LC1). What
        // it actually means is "a run right now would not include these", which is the one
        // consequence the user can act on. Said here rather than by adding a navigation prompt,
        // which WF-LC1 closed by explicitly ruling out.
        //
        // ⚠️ WORDED FOR AN APP-WIDE SIGNAL, deliberately. This dot lights when ANY workflow canvas
        // is dirty (`!dirtyWorkflowCanvasIDs.isEmpty` — not scoped to the selected profile), so it
        // must NOT promise anything about the next run in particular. That per-run claim is
        // `WorkflowRunEditDisclosure`'s job, and it is scoped to one profile precisely so it can
        // make it truthfully.
        .help(mode == .workflow && !viewModel.dirtyWorkflowCanvasIDs.isEmpty
              ? "One or more workflow canvases have unsaved edits. They are kept safely, but a workflow always runs its last saved version — save a canvas to include its edits."
              : "")
        .accessibilityValue(mode == .workflow && !viewModel.dirtyWorkflowCanvasIDs.isEmpty
                            ? Text("Unsaved canvas edits")
                            : Text(""))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}


