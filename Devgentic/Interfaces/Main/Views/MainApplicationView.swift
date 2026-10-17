// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.appTheme) private var theme
    @Environment(\.surfaceStyle) private var surfaceStyle
    @Environment(GitChangesStore.self) private var gitChangesStore
    @Environment(CodeSessionManager.self) private var codeSessionManager

    @FocusState private var isInputFocused: Bool
    
    @AppStorage("sidebar.isVisible") private var isSidebarVisible: Bool = true
    @AppStorage("sidebar.paneWidth") private var currentSidebarPaneWidth: Double = 320
    /// Same key the Code Viewer panel persists its divider width to. Read here so split
    /// mode can inset the chat by the panel's width. Written on drag END only — a
    /// UserDefaults write per mouse move spams the preferences daemon — so it is the
    /// AT-REST width; the in-flight width comes from `codeViewerLiveDragWidth` instead
    /// (see `chatSplitInset`), which is what keeps the chat column pinned to the divider
    /// for the whole drag rather than a full drag behind it.
    @AppStorage("codeViewerPanelWidth") private var codeViewerPanelWidth: Double = 600
    @State private var showModePicker: Bool = true
    @State private var isCommandPalettePresented: Bool = false
    @AppStorage(SidebarTab.storageKey) private var selectedSidebarTab: String = SidebarTab.conversations.rawValue
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

    private var isAnyPanelInSplit: Bool {
        if chatHistoryViewModel.isCodeViewerPanelPresented {
            return chatHistoryViewModel.codeViewerPresentation == .split
        }
        if chatHistoryViewModel.isBackgroundTasksPanelPresented {
            return chatHistoryViewModel.backgroundTasksPresentation == .split
        }
        if isGitChangesPanelMounted {
            return chatHistoryViewModel.gitChangesPresentation == .split
        }
        return false
    }

    /// The Git Changes panel is Code-only; its flag lives on the shared view model.
    private var isGitChangesPanelMounted: Bool {
        GitChangesWiring.shouldMountPanel(interfaceMode: viewModel.interfaceMode,
                                          isPresented: chatHistoryViewModel.isGitChangesPanelPresented)
    }

    /// Trailing inset the chat area yields to the Code Viewer or Background Tasks in split mode.
    /// Zero in overlay/full (overlay covers; full replaces). The desired inset is the
    /// panel's full FOOTPRINT — content width plus its divider — plus a breathing gutter,
    /// so chat text doesn't sit flush against the divider edge. Capped so the chat never
    /// drops below `splitModeMinChatWidth` — past that the panel overlaps the difference,
    /// which is the historic overlay behaviour rather than an unreadable sliver of chat.
    private var chatSplitInset: CGFloat {
        guard isAnyPanelInSplit else { return 0 }
        // [CF-15] The IN-FLIGHT drag width when one is running, else the persisted value.
        // `codeViewerPanelWidth` only updates on drag end (see the doc above), so without
        // this the panel's edge moved live while this inset held still for the whole
        // drag — the panel slid over the chat text, then the chat jumped to its new
        // column in one animated step on release. The panel publishes the
        // live value onto the view model per drag tick for exactly this reader — which
        // only pins the column because `chatSplitInsetAnimation` drops the ease for the
        // duration of the drag; an animated per-tick inset trails just as visibly.
        let liveWidth = chatHistoryViewModel.codeViewerLiveDragWidth ?? codeViewerPanelWidth
        let trailingMargin: CGFloat = 12
        let desired = CGFloat(liveWidth)
            + trailingMargin
            + ChatUIConstants.codeViewerDividerWidth
            + ChatUIConstants.splitModeChatGutter
        // The floor accounts for BOTH gutters (leading one below + this trailing one) so
        // the actual text column, not just the padded region, keeps its minimum width.
        let maxInset = windowContentWidth - totalSidebarWidth - ChatUIConstants.splitModeChatGutter
            - ChatUIConstants.splitModeMinChatWidth - trailingMargin
        return max(0, min(desired, maxInset))
    }

    /// Animation for `chatSplitInset` — deliberately NONE while a divider drag is running.
    private var chatSplitInsetAnimation: Animation? {
        guard isAnyPanelInSplit else {
            return Self.splitInsetAnimation(isDraggingDivider: false)
        }
        return Self.splitInsetAnimation(isDraggingDivider: chatHistoryViewModel.codeViewerLiveDragWidth != nil)
    }

    /// The rule above, as a value — the view can't be instantiated in a test, and this is
    /// the part worth pinning: no animation while the divider is being dragged.
    static func splitInsetAnimation(isDraggingDivider: Bool) -> Animation? {
        isDraggingDivider ? nil : .easeInOut(duration: 0.2)
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
    /// ⚠️ Hoisted out of `body`. Inline, this tipped the ZStack past the type-checker's budget
    /// ("unable to type-check this expression in reasonable time") — that body is already large
    /// enough that one more conditional branch is not free.
    @ViewBuilder
    private var backgroundTasksPanel: some View {
        if chatHistoryViewModel.isBackgroundTasksPanelPresented {
            BackgroundTasksPanelView(conversationID: chatHistoryViewModel.viewerOwningConversationID)
                .environment(chatHistoryViewModel)
                .padding(.leading, chatHistoryViewModel.backgroundTasksPresentation == .overlay ? 0 : totalSidebarWidth)
                .zIndex(2)
        }
    }

    /// Hoisted for the same reason as `backgroundTasksPanel`.
    @ViewBuilder
    private var gitChangesPanel: some View {
        if isGitChangesPanelMounted {
            GitChangesPanelView()
                .environment(chatHistoryViewModel)
                .environment(gitChangesStore)
                .padding(.leading, chatHistoryViewModel.gitChangesPresentation == .overlay ? 0 : totalSidebarWidth)
                .zIndex(2)
        }
    }

    private var isChatInterfaceActive: Bool {
        router.isShowingChat && viewModel.interfaceMode == .chat
    }

    private var shouldShowQuickAccessButton: Bool {
        let isCoveredByOverlayPanel = (chatHistoryViewModel.isCodeViewerPanelPresented && chatHistoryViewModel.codeViewerPresentation != .split)
            || (chatHistoryViewModel.isBackgroundTasksPanelPresented && chatHistoryViewModel.backgroundTasksPresentation != .split)

        return QuickAccessFloatingButton.shouldShow(
            isChatInterfaceActive: isChatInterfaceActive,
            hasSelectedConversation: viewModel.selectedConversationID != nil,
            isQuickAccessEnabled: QuickAccessConfigManager.shared.isEnabled,
            isCoveredByOverlayPanel: isCoveredByOverlayPanel
        )
    }

    private var pillsTrailingInset: CGFloat {
        isAnyPanelInSplit ? chatSplitInset + 18 : 18
    }

    /// The floating pills, STACKED so they can never overlap.
    ///
    /// Dynamically tracks split-mode insets so they stay inside the chat column
    /// without overlapping side panels or each other.
    ///
    /// ⚠️ Mounts EXACTLY what `FloatingPillStack.visible` returns — no gate of its own here. A
    /// shared inline gate is how Build 102.7 dropped the Background Tasks and Code Viewer pills
    /// from Code mode; per-mode membership lives in that function and its tests.
    private var visiblePills: [FloatingPill] {
        FloatingPillStack.visible(
            interfaceMode: viewModel.interfaceMode,
            isShowingChat: router.isShowingChat,
            showsQuickAccess: shouldShowQuickAccessButton,
            showsGitChanges: GitChangesFloatingButton.shouldShow(
                // The flag, NOT `snapshot != nil`: reading the snapshot would make this whole body
                // re-evaluate on every refresh that changes a count.
                hasLoadedRepository: gitChangesStore.hasLoadedRepository,
                anyPanelOpen: chatHistoryViewModel.isGitChangesPanelPresented
                    || chatHistoryViewModel.isCodeViewerPanelPresented
                    || chatHistoryViewModel.isBackgroundTasksPanelPresented),
            isCodeViewerMinimized: chatHistoryViewModel.isCodeViewerMinimized,
            isBackgroundTasksPanelPresented: chatHistoryViewModel.isBackgroundTasksPanelPresented,
            isGitChangesPanelPresented: isGitChangesPanelMounted
        )
    }

    @ViewBuilder
    private var floatingPills: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(visiblePills, id: \.self) { pill in
                switch pill {
                case .quickAccess:
                    QuickAccessFloatingButton()
                        .environment(viewModel)
                case .gitChanges:
                    GitChangesFloatingButton()
                        .environment(chatHistoryViewModel)
                        .environment(gitChangesStore)
                case .backgroundTasks:
                    BackgroundTasksFloatingButton(conversationID: chatHistoryViewModel.viewerOwningConversationID)
                        .environment(chatHistoryViewModel)
                case .codeViewer:
                    CodeViewerFloatingButton()
                        .environment(chatHistoryViewModel)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 14)
        .padding(.trailing, pillsTrailingInset)
        .animation(chatSplitInsetAnimation, value: pillsTrailingInset)
        .animation(.easeInOut(duration: 0.2), value: shouldShowQuickAccessButton)
        .animation(.easeInOut(duration: 0.2), value: chatHistoryViewModel.isCodeViewerMinimized)
        .zIndex(3)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            ZStack {
                theme.primaryBackground
                
                // Ambient Aura Glows (Provides texture for Liquid Glass refraction; suppressed in Solid Matte)
                if surfaceStyle == .glassmorphic {
                    if theme.colorScheme != .light {
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
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSidebarVisible)
            .onReceive(NotificationCenter.default.publisher(for: .requestSidebarVisible)) { _ in
                // The Tool Library's navigation IS the pane; entering it with the pane
                // hidden would leave no way to change category or pick a server.
                guard !isSidebarVisible else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isSidebarVisible = true
                }
            }
            .animation(.easeInOut(duration: 0.1), value: currentSidebarPaneWidth)
            .animation(.easeInOut(duration: 0.2), value: router.activeDestination)
            .animation(chatSplitInsetAnimation, value: chatSplitInset)
            
            VSCodifiedSidebarContainerView(
                isSidebarVisible: $isSidebarVisible,
                sidebarWidth: sidebarPaneWidthCGFloat
            )
            .frame(width: totalSidebarWidth)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSidebarVisible)
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

            // The task list occupies the SAME trailing slot as the Code Viewer, which is why the
            // two flags exclude each other in `ChatHistoryViewModel` rather than here — a rule
            // enforced at the mount site would be a rule this `if` could silently disagree with.
            backgroundTasksPanel

            // Third occupant of the same slot — Code mode only. See `gitChangesPanel`.
            gitChangesPanel

            // Floating pills — reopen-code-viewer and background-tasks. See `floatingPills`.
            floatingPills

            // Hidden shortcut button for Explorer (IDE standard Cmd+Shift+E)
            Button(action: {
                selectSidebarTab(.explorer)
            }) { EmptyView() }
                .hidden()
                .keyboardShortcut("e", modifiers: [.command, .shift])

            // Universal Command Palette overlay (Cmd+K)
            if isCommandPalettePresented {
                CommandPaletteView(
                    isPresented: $isCommandPalettePresented,
                    isSidebarVisible: $isSidebarVisible
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(100)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            windowContentWidth = newWidth
        }
        .preferredColorScheme(theme.colorScheme)
        .onAppear {
             viewModel.explorerViewModel.onOpenFileRequested = { [weak chatHistoryViewModel, weak explorerVM = viewModel.explorerViewModel] item in
                 if let chatHistoryViewModel {
                     FileOpenCoordinator.open(item: item, in: chatHistoryViewModel, fallbackViewModel: explorerVM)
                 } else {
                     explorerVM?.openWithSystemApp(item)
                 }
             }
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
        .onChange(of: isAnyPanelInSplit) { wasSplit, isSplit in
            // Entering split: auto-collapse the sidebar PANE so the chat keeps a readable
            // column — expanded sidebar + panel + chat is one region too many. One-shot on
            // the TRANSITION only: re-expanding afterwards is the user's call and nothing
            // fights them for it (leaving split deliberately does not auto-restore either).
            if isSplit, !wasSplit, isSidebarVisible {
                isSidebarVisible = false
                logger.debug("[MainApplicationView] Split enabled — sidebar pane auto-collapsed.")
            }
        }
        .onChange(of: viewModel.selectedConversationID) { _, newID in
            if newID != nil {
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
        .onReceive(NotificationCenter.default.publisher(for: .toggleCommandPalette)) { _ in
            withAnimation(.easeInOut(duration: 0.15)) {
                isCommandPalettePresented.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isSidebarVisible.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChatSession)) { _ in
            if viewModel.interfaceMode == .workflow {
                viewModel.deselectConversationAndShowWelcome()
                logger.debug("Triggered new workflow (deselect) via newChatSession.")
            } else if viewModel.interfaceMode == .code {
                viewModel.deselectConversationAndShowWelcome()
                logger.debug("Triggered new code session via newChatSession.")
            } else {
                viewModel.startNewConversation()
                logger.debug("Triggered new conversation via newChatSession.")
            }
            if isSidebarVisible {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isSidebarVisible = false
                }
                logger.debug("Hid sidebar pane via newChatSession.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectSidebarTab)) { note in
            if let tab = note.object as? SidebarTab {
                selectSidebarTab(tab)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusChatInput)) { _ in
            if !router.isShowingChat {
                router.returnToChat()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInputFocused = true
            }
            logger.debug("Focused chat input via focusChatInput.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePinActiveConversation)) { _ in
            if let currentID = viewModel.selectedConversationID {
                viewModel.togglePinStatus(for: currentID)
                logger.debug("Toggled pin status for active conversation \(currentID).")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportActiveConversation)) { _ in
            if let currentID = viewModel.selectedConversationID {
                viewModel.exportConversation(conversationID: currentID)
                logger.debug("Triggered export for active conversation \(currentID).")
            }
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
        case .skillLibrary(let profileID):
            SkillLibraryContainerView(routeProfileID: profileID)
        case .skillDetail(let skillID):
            SkillDetailContainerView(skillID: skillID)
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
        // Git Changes: project sync, refresh triggers, close-on-mode-change.
        .modifier(GitChangesWiringModifier(store: gitChangesStore,
                                           chatHistoryViewModel: chatHistoryViewModel,
                                           interfaceMode: viewModel.interfaceMode,
                                           projectPath: codeSessionManager.projectPath))
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

    // MARK: - Navigation & Mode Helpers

    private func selectSidebarTab(_ tab: SidebarTab) {
        guard tab.isVisible(in: viewModel.interfaceMode) else { return }
        if !router.isShowingChat {
            router.returnToChat()
        }
        if !isSidebarVisible {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isSidebarVisible = true
            }
        }
        selectedSidebarTab = tab.rawValue
        logger.debug("Switched sidebar tab to \(tab.rawValue)")
    }

    private func cycleInterfaceMode() {
        let allModes = MainApplicationViewModel.InterfaceMode.allCases
        if let currentIndex = allModes.firstIndex(of: viewModel.interfaceMode) {
            let nextIndex = (currentIndex + 1) % allModes.count
            let nextMode = allModes[nextIndex]
            viewModel.switchInterfaceMode(to: nextMode)
            logger.debug("Cycled interface mode to \(nextMode.rawValue)")
        }
    }
}

// MARK: - Interface Mode Picker (Liquid Glass)

/// Floating Chat/Workflow/Code mode switcher using macOS Liquid Glass.
/// Uses `matchedGeometryEffect` for a sliding active-indicator that
/// glides between tabs on selection change.
private struct InterfaceModePicker: View {
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(\.appTheme) private var theme
    @Environment(\.surfaceStyle) private var surfaceStyle
    @Namespace private var modeAnimation

    var body: some View {
        HStack(spacing: 3) {
            ForEach(MainApplicationViewModel.InterfaceMode.allCases, id: \.self) { mode in
                ModeTabButton(mode: mode, namespace: modeAnimation)
            }
        }
        .padding(3)
        .background(
            Capsule()
                .fill(
                    surfaceStyle == .solid
                        ? (theme.isDark ? Color(hex: "#18181B") : theme.secondaryBackground)
                        : theme.secondaryBackground.opacity(0.75)
                )
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.dividerColor.opacity(0.35), lineWidth: 0.5)
        )
        .shadow(
            color: Color.black.opacity(theme.isDark ? 0.2 : 0.06),
            radius: 8,
            x: 0,
            y: 3
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: viewModel.interfaceMode)
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
    @Environment(\.buttonAccentStyle) private var buttonAccentStyle
    @State private var isHovering = false

    private var isActive: Bool { viewModel.interfaceMode == mode }

    private var activeIconColor: Color {
        if buttonAccentStyle == .accent && !theme.isAccentLight {
            return theme.accentColor
        }
        return theme.primaryText
    }

    var body: some View {
        Button {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                viewModel.switchInterfaceMode(to: mode)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .foregroundColor(isActive ? activeIconColor : (isHovering ? theme.primaryText : theme.secondaryText))

                Text(mode.localizedTitle)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundColor(isActive ? theme.primaryText : (isHovering ? theme.primaryText : theme.secondaryText))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 5.5)
            .background {
                if isActive {
                    Capsule()
                        .fill(theme.surfaceOverlayStrong)
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    buttonAccentStyle == .accent && !theme.isAccentLight
                                        ? theme.accentColor.opacity(0.35)
                                        : theme.dividerColor.opacity(0.4),
                                    lineWidth: 0.5
                                )
                        )
                        .shadow(color: Color.black.opacity(theme.isDark ? 0.22 : 0.05), radius: 4, x: 0, y: 1.5)
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
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: -1)
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
        .help(modeHelpText)
        .accessibilityValue(mode == .workflow && !viewModel.dirtyWorkflowCanvasIDs.isEmpty
                            ? Text("Unsaved canvas edits")
                            : Text(""))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var modeHelpText: String {
        if mode == .workflow && !viewModel.dirtyWorkflowCanvasIDs.isEmpty {
            return "Workflow Canvas (⌃2) · One or more workflow canvases have unsaved edits."
        }
        switch mode {
        case .chat:     return "Chat Mode (⌃1)"
        case .workflow: return "Workflow Canvas (⌃2)"
        case .code:     return "Code Workspace (⌃3)"
        }
    }
}


