// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatHistoryView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "ChatHistoryView")

// MARK: - ChatHistoryView
/// A standard bottom-up chat interface.
struct ChatHistoryView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(MainApplicationViewModel.self) private var mainAppViewModel
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel

    /// `nil` under Reduce Motion, which makes `.animation(_:value:)` and `withAnimation`
    /// apply the change instantly. This is the main content surface — sliding, springing
    /// scroll on every new message is exactly what the setting exists to stop.
    private func motionSafe(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }

    // Track the ID of the newest message to handle auto-scrolling for new content.
    @State private var lastNewestMessageID: UUID?

    // MARK: - Initial Scroll State
    /// Hides the ScrollView until the initial scrollTo completes, preventing visible jumps.
    @State private var isContentReady: Bool = true

    // MARK: - Scroll-to-Bottom FAB State
    @State private var showScrollToBottom: Bool = false
    /// Content must extend at least this far below the viewport bottom before the
    /// FAB appears — slack so it doesn't flicker at the exact bottom (bottom
    /// padding, rubber-banding, sub-pixel layout).
    private static let scrollToBottomThreshold: CGFloat = 100

    /// Auto-loads older messages once the viewport is within this distance of the top.
    /// Kept small: after a page loads the previous-oldest message is re-anchored, so a large distance would yank the
    /// view.
    private static let autoLoadTopThreshold: CGFloat = 60

    /// What the top-of-transcript pagination slot shows. Pure and `nonisolated static`.
    /// The residency cap wins over everything but "nothing left to load", because `canLoadMorePages` stays true at the
    /// cap.
    enum LoadEarlierAffordance: Equatable {
        /// History is exhausted — nothing to show.
        case hidden
        /// The interactive pill; spinner while a page is in flight.
        case button(loading: Bool)
        /// Non-interactive note: scroll-back stopped at the residency cap.
        case capNotice
    }

    /// Whether an appended newest message should scroll the transcript to the bottom.
    /// A locally typed message always follows; others (ChatOps, scheduled runs) follow only if the reader is at the
    /// bottom.
    nonisolated static func shouldFollowNewest(isLocallyTyped: Bool, isAwayFromBottom: Bool) -> Bool {
        isLocallyTyped || !isAwayFromBottom
    }

    /// Whether this message was typed into THIS app, as opposed to arriving from a remote
    /// surface (ChatOps), a voice HUD, or an unattended scheduled run.
    nonisolated static func isLocallyTyped(_ message: ChatMessage) -> Bool {
        guard message.sender == .user else { return false }
        switch message.messageSource {
        case .localUI, .quickAccess: return true
        default: return false
        }
    }

    nonisolated static func loadEarlierAffordance(canLoadMore: Bool, atCap: Bool, isLoading: Bool) -> LoadEarlierAffordance {
        guard canLoadMore else { return .hidden }
        if atCap { return .capNotice }
        return .button(loading: isLoading)
    }

    // MARK: - Grouped continuations

    /// One continuation of a group: its fold row, its lead row or report, and — after the group's
    /// last message — the group's action bar.
    @ViewBuilder
    private func continuationView(_ continuation: TranscriptGrouping.Continuation,
                                  message: ChatMessage,
                                  roles: [UUID: TranscriptGrouping.Role]) -> some View {
        let unfolded = expandedFolds.contains(continuation.headID)
        VStack(alignment: .leading, spacing: 0) {
            if let fold = continuation.fold, fold.isFirst {
                EarlierAttemptFoldRow(count: fold.count, isExpanded: unfolded) {
                    withAnimation(motionSafe(.easeInOut(duration: 0.2))) {
                        if unfolded { expandedFolds.remove(continuation.headID) }
                        else { expandedFolds.insert(continuation.headID) }
                    }
                }
            }
            if continuation.fold == nil || unfolded {
                if continuation.isStub {
                    // A stub is drawn by its report's header; alone, its report has not started.
                    if !continuation.hasReport {
                        ContinuationLeadRow(lead: TranscriptGrouping.leadText(forStub: message), isWaiting: true)
                            .padding(.top, 4)
                    }
                } else if let stub = displayMessages.first(where: { $0.id == continuation.stubID }) {
                    ChatBubbleView(message: message,
                                   groupStyle: .continuation(lead: TranscriptGrouping.leadText(forStub: stub)))
                }
            }
            if continuation.isGroupEnd {
                groupActionBar(headID: continuation.headID, roles: roles)
            }
        }
    }

    /// The group's one action bar: the human turn's own actions, with Copy and Read Aloud covering
    /// the reports shown beneath it. Withheld while any of them is still streaming.
    @ViewBuilder
    private func groupActionBar(headID: UUID, roles: [UUID: TranscriptGrouping.Role]) -> some View {
        let unfolded = expandedFolds.contains(headID)
        let members = displayMessages.filter { candidate in
            if candidate.id == headID { return true }
            guard case .continuation(let c)? = roles[candidate.id], c.headID == headID, !c.isStub else { return false }
            return c.fold == nil || unfolded
        }
        if let head = members.first(where: { $0.id == headID }),
           !members.contains(where: \.isStreaming),
           head.displayedContent.textContent != nil {
            AgentMessageActionsView(message: head, groupMessages: members, mainAppViewModel: mainAppViewModel)
                .environment(chatHistoryViewModel)
                .opacity(0.6)
                .padding(.bottom, 16)
        }
    }

    // MARK: - Speech Service
    private var speechService = SpeechService.shared
    /// [sa-5] This mount's identity as a speech-transport host — stable for the view's life,
    /// fresh for every re-mount, so registration is idempotent.
    @State private var transportHostID = UUID()

    /// Groups whose earlier-attempt reports the user unfolded, by head message id.
    @State private var expandedFolds: Set<UUID> = []

    // MARK: - Cached Reversed Messages
    /// Caches the reversed message array to avoid O(n) recomputation on every body evaluation.
    @State private var displayMessages: [ChatMessage] = []

    // MARK: - Search State
    @State private var searchViewModel = ChatSearchViewModel()

    /// Lightweight identity signature for the message list.
    /// Changes on add/remove or when the first or last message identity changes, so same-length switches invalidate the
    /// cache.
    private struct MessagesToken: Equatable {
        let count: Int
        let firstID: UUID?
        let lastID: UUID?
    }
    private var messagesToken: MessagesToken {
        let m = chatHistoryViewModel.currentChatMessages
        return MessagesToken(count: m.count, firstID: m.first?.id, lastID: m.last?.id)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .top) {
                    ScrollView {
                        LazyVStack(spacing: 0) {

                            // MARK: - Load-Earlier Pill / Cap Notice
                            // Affordance and loading indicator for history pagination; `loadEarlierAffordance` decides which of three states
                            // renders.
                            if mainAppViewModel.selectedConversationID != nil {
                                switch Self.loadEarlierAffordance(
                                    canLoadMore: chatHistoryViewModel.canLoadMorePages,
                                    atCap: chatHistoryViewModel.hasReachedResidencyCap,
                                    isLoading: chatHistoryViewModel.isLoadingPage
                                ) {
                                case .hidden:
                                    EmptyView()
                                case .button(let loading):
                                    Button {
                                        loadPreviousPage(proxy: proxy)
                                    } label: {
                                        HStack(spacing: 6) {
                                            if loading {
                                                ProgressView()
                                                    .controlSize(.small)
                                                Text("Loading earlier messages…")
                                            } else {
                                                Image(systemName: "clock.arrow.circlepath")
                                                    .font(.system(.caption, weight: .semibold))
                                                Text("Load earlier messages")
                                            }
                                        }
                                        .font(theme.fontCaption.weight(.medium))
                                        .foregroundColor(theme.secondaryText)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        // MARK: Liquid Glass
                                        .glassEffect(.regular, in: .capsule)
                                        .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(loading)
                                    .frame(maxWidth: .infinity)
                                    .padding(.bottom, theme.spacingMedium)
                                    .help("Older messages load automatically when you scroll to the top")
                                    .accessibilityLabel(loading ? "Loading earlier messages" : "Load earlier messages")
                                case .capNotice:
                                    // Deliberately not a control, so it is a plain caption: search finds older messages but cannot jump to them.
                                    Text("Older messages aren't loaded here, to keep memory in check — ⌘F still finds them, but can't jump to them.")
                                        .font(theme.fontCaption)
                                        .foregroundColor(theme.tertiaryText)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 12)
                                        .padding(.bottom, theme.spacingMedium)
                                        .help("Scroll-back stops at \(ChatHistoryViewModel.maxResidentMessages) messages to bound memory. Older messages stay in the conversation and are reachable through search.")
                                        .accessibilityLabel("Older messages are not loaded here to keep memory in check; search still finds them but cannot scroll to them")
                                }
                            }

                            if mainAppViewModel.selectedConversationID != nil {
                                // Empty conversation placeholder
                                if chatHistoryViewModel.currentChatMessages.isEmpty
                                    && !chatHistoryViewModel.isInitiallyLoadingConversation {
                                    EmptyConversationPlaceholder()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .frame(minHeight: geometry.size.height - 150)
                                }

                                // Messages are stored newest first and reversed for display via cached `displayMessages`; background reports group
                                // into the turn above.
                                let groupRoles = TranscriptGrouping.roles(oldestFirst: displayMessages)
                                ForEach(displayMessages) { message in
                                    switch groupRoles[message.id] ?? .plain {
                                    case .orphanStub:
                                        // A synthetic row is a turn nobody typed (a woken background task's stub); with no turn above, it keeps the
                                        // standalone divider.
                                        BackgroundTaskDividerView(message: message)
                                            .id(message.id)
                                    case .plain, .head:
                                        ChatBubbleView(message: message,
                                                       groupStyle: groupRoles[message.id] == .plain ? .standalone : .head)
                                            .id(message.id)
                                    case .continuation(let continuation):
                                        continuationView(continuation, message: message, roles: groupRoles)
                                            .id(message.id)
                                    }
                                }

                                // Says the conversation is not finished: a task that asked to report here is still running.
                                // Only the subset of tasks that will speak unprompted, unlike the tasks pill which counts all of them.
                                PendingBackgroundReportFooter(
                                    conversationID: mainAppViewModel.selectedConversationID
                                )

                                // A manual compaction ("Compact history"): running, then its outcome; its checkpoint card usually lands above the
                                // fold.
                                ManualCompactionRow(
                                    conversationID: mainAppViewModel.selectedConversationID,
                                    newestMessageAt: chatHistoryViewModel.currentChatMessages.first?.timestamp,
                                    canShowCheckpoint: { id in
                                        chatHistoryViewModel.currentChatMessages.contains { $0.id == id }
                                    },
                                    onShowCheckpoint: { id in
                                        withAnimation(motionSafe(.easeInOut(duration: 0.3))) {
                                            proxy.scrollTo(id, anchor: .center)
                                        }
                                    }
                                )
                            }

                            // The end of the list — what "scroll to bottom" targets.
                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomSentinelID)
                        }
                        .frame(maxWidth: ViewLayout.maxContentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.top, searchViewModel.isSearchActive ? 56 : theme.spacingLarge)
                        .padding(.bottom, theme.spacingLarge)
                        .animation(motionSafe(.easeInOut(duration: 0.2)), value: searchViewModel.isSearchActive)
                    }
                    // MARK: - Bottom anchoring
                    // `.alignment` top, `.initialOffset` bottom, `.sizeChanges` bottom while the reader is at the bottom: no scroll is
                    // ever issued.
                    .defaultScrollAnchor(.top, for: .alignment)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(Self.sizeChangeAnchor(isAwayFromBottom: showScrollToBottom), for: .sizeChanges)
                    // A fresh scroll view per conversation so `.initialOffset` applies; keyed on the rows' conversation, not the
                    // sidebar selection.
                    .id(displayMessages.first?.conversationId)
                    .opacity(isContentReady ? 1 : 0)
                    // MARK: - Scroll-to-Bottom FAB Visibility
                    // "Content extends below the fold": distance from the viewport bottom to the content bottom.
                    // One signal covers both scrolled-up history and a streaming response growing past the viewport.
                    .onScrollGeometryChange(for: Bool.self) { scrollGeometry in
                        let distanceFromBottom = scrollGeometry.contentSize.height
                            - scrollGeometry.contentOffset.y
                            - scrollGeometry.containerSize.height
                        return distanceFromBottom > Self.scrollToBottomThreshold
                    } action: { _, isBelowFold in
                        if showScrollToBottom != isBelowFold {
                            showScrollToBottom = isBelowFold
                        }
                    }
                    // MARK: - Auto-Load Older Messages Near the Top
                    // Standard history pagination: reaching the top loads the next page.
                    // `loadPreviousPage` itself no-ops while a page loads, at the end of history, or at the residency cap.
                    .onScrollGeometryChange(for: CGFloat.self) { scrollGeometry in
                        scrollGeometry.contentOffset.y
                    } action: { _, offsetY in
                        guard offsetY < Self.autoLoadTopThreshold,
                              isContentReady,
                              !chatHistoryViewModel.isInitiallyLoadingConversation else { return }
                        loadPreviousPage(proxy: proxy)
                    }
                    // MARK: - NEW MESSAGE SCROLLING (Animated) + Cache Update
                    // Trigger on count changes (new/removed messages).
                    .onChange(of: messagesToken) { _, _ in
                        // Refreshes the cached reversed array; keyed on identity (count and first/last id) so same-count changes still
                        // refresh.
                        displayMessages = chatHistoryViewModel.currentChatMessages.reversed()

                        // Search is query-time: while the bar is open with a query, re-run it so matches track membership changes.
                        if searchViewModel.isSearchActive, !searchViewModel.effectiveQuery.isEmpty {
                            chatHistoryViewModel.runSearch(searchViewModel)
                        }

                        if !chatHistoryViewModel.isLoadingPage && !chatHistoryViewModel.isInitiallyLoadingConversation {
                            let newest = chatHistoryViewModel.currentChatMessages.first
                            let currentNewestID = newest?.id

                            if currentNewestID != lastNewestMessageID {
                                // The newest id always advances, whether or not we follow it, so the next append compares against a current
                                // anchor.
                                lastNewestMessageID = currentNewestID
                                if let newest, Self.shouldFollowNewest(
                                    isLocallyTyped: Self.isLocallyTyped(newest),
                                    isAwayFromBottom: showScrollToBottom
                                ) {
                                    Task { @MainActor in
                                        scrollToBottom(proxy: proxy, animated: true)
                                    }
                                }
                            }
                        }
                    }
                    // MARK: - INITIAL LOAD SCROLLING (Hidden → Scroll → Reveal)
                    .onChange(of: chatHistoryViewModel.isInitiallyLoadingConversation) { _, isLoading in
                        if isLoading {
                            // Hide content while messages are being loaded.
                            isContentReady = false
                        } else {
                            // Refresh cached display order after initial load. No scroll: the new
                            // rows get a fresh scroll view (`.id` above) that opens at its bottom.
                            displayMessages = chatHistoryViewModel.currentChatMessages.reversed()
                            lastNewestMessageID = chatHistoryViewModel.currentChatMessages.first?.id
                            isContentReady = true
                        }
                    }
                    // MARK: - Search Navigation
                    .onChange(of: searchViewModel.currentMatchIndex) { _, _ in
                        scrollToCurrentMatch(proxy: proxy)
                    }
                    // MARK: - Search Query Changes (Debounced)
                    .onChange(of: searchViewModel.debouncedQuery) { _, _ in
                        chatHistoryViewModel.runSearch(searchViewModel)
                        scrollToCurrentMatch(proxy: proxy)
                    }
                    // MARK: - Search Corpus (store-backed)
                    // Loaded once when the bar opens so search reaches past the scroll
                    // window; a per-keystroke fetch would decode every message's timeline.
                    .onChange(of: searchViewModel.isSearchActive) { _, isActive in
                        // Closing search releases the corpus rather than keeping the whole projection for the session.
                        guard !isActive else { return }
                        chatHistoryViewModel.releaseSearchCorpus()
                    }
                    // The fetch is structured to this view so a cancelled `.task(id:)` never publishes; the id carries the
                    // conversation for re-prepare.
                    .task(id: searchViewModel.isSearchActive
                          ? chatHistoryViewModel.currentChatMessages.first?.conversationId
                          : nil) {
                        guard searchViewModel.isSearchActive else { return }
                        await chatHistoryViewModel.prepareSearchCorpus()
                        // Cancelled means search closed or the view went away; releasing here could free a corpus the next fetch just
                        // published.
                        guard !Task.isCancelled, searchViewModel.isSearchActive else { return }
                        if !searchViewModel.effectiveQuery.isEmpty {
                            chatHistoryViewModel.runSearch(searchViewModel)
                        }
                    }
                    // `ChatHistoryView` is mounted in two exclusive places, so a mode switch tears it down without an `isSearchActive`
                    // transition.
                    .onDisappear { chatHistoryViewModel.releaseSearchCorpus() }

                    // MARK: - Search Bar Overlay
                    if searchViewModel.isSearchActive {
                        ChatSearchBar(searchViewModel: searchViewModel)
                            // Same content lane as the message column and the composer; a full-bleed bar would run under the Code Viewer's
                            // pill.
                            .frame(maxWidth: ViewLayout.maxContentWidth)
                            // Yield the corner the floating pill floats in, so the two
                            // never collide on a window too narrow for both.
                            .padding(.trailing, chatHistoryViewModel.isCodeViewerMinimized
                                     ? ChatUIConstants.codeViewerPillFootprint : 0)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(ViewZIndex.searchBar)
                    }

                    // MARK: - Scroll-to-Bottom FAB
                    // Bottom-trailing within the content lane, at the composer's right border and clear of the floating mode switcher.
                    if showScrollToBottom && !chatHistoryViewModel.currentChatMessages.isEmpty {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                ScrollToBottomFAB {
                                    scrollToBottom(proxy: proxy, animated: true)
                                }
                                .padding(.trailing, 8)   // small inset from the lane edge
                            }
                            .frame(maxWidth: ViewLayout.maxContentWidth)
                            .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(motionSafe(.easeInOut(duration: 0.2)), value: showScrollToBottom)
                        .zIndex(ViewZIndex.fab)
                    }

                    // MARK: - Speech Control Island
                    // Bottom-centered. No longer dodges the FAB — the FAB moved to
                    // bottom-trailing, so the two occupy different corners.
                    if speechService.isActive {
                        VStack {
                            Spacer()
                            SpeechControlIsland()
                                .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(motionSafe(.spring(response: 0.4, dampingFraction: 0.7)), value: speechService.isActive)
                        .zIndex(ViewZIndex.speechControl)
                    }

                    // Loading Indicator
                    if chatHistoryViewModel.isInitiallyLoadingConversation {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // MARK: Liquid Glass
                            .glassEffect(.regular, in: .rect(cornerRadius: 0))
                            // --- To revert to pre-Liquid-Glass, comment out the line above and uncomment below ---
                            // .background(.ultraThinMaterial)
                            .transition(.opacity)
                            .accessibilityLabel("Loading conversation history")
                            .accessibilityHint("Fetching messages from storage")
                    }
                }
            }
            .onAppear {
                lastNewestMessageID = chatHistoryViewModel.currentChatMessages.first?.id
                displayMessages = chatHistoryViewModel.currentChatMessages.reversed()
                // [sa-5] This view hosts the speech island; the service stops a session that
                // has no host left (⌘W, a switch to Workflow mode, the panel closing).
                speechService.transportHostDidAppear(transportHostID)
            }
            .onDisappear {
                speechService.transportHostDidDisappear(transportHostID)
            }
            // Stops speech when switching conversations.
            // The speech to Code Viewer hand-off is observed here, not on a message row that may be unmounted.
            .onReceive(NotificationCenter.default.publisher(for: .speechOpenCodeViewer)) { notification in
                guard let userInfo = notification.userInfo,
                      let code = userInfo["code"] as? String else { return }
                let language = userInfo["language"] as? String
                chatHistoryViewModel.showCodeInViewer(language: language, code: code)
            }
            .onChange(of: mainAppViewModel.selectedConversationID) { _, _ in
                if speechService.isActive {
                    speechService.stop()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .findInChat)) { _ in
                withAnimation(motionSafe(.easeInOut(duration: 0.2))) {
                    searchViewModel.toggleSearch()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .findNextInChat)) { _ in
                if searchViewModel.isSearchActive {
                    searchViewModel.nextMatch()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .findPreviousInChat)) { _ in
                if searchViewModel.isSearchActive {
                    searchViewModel.previousMatch()
                }
            }
            // MARK: - Speech Playback Keyboard Shortcuts
            // Gated on `speechService.isActive`: a `keyboardShortcut` captures its combo globally in the key window,
            // so rendering the buttons only while speaking keeps Option+Left/Right free for text editing.
            .background {
                if speechService.isActive {
                    Group {
                        // Option+Space: Pause / Resume
                        Button(action: { speechService.togglePause() }) { EmptyView() }
                            .hidden()
                            .keyboardShortcut(.space, modifiers: .option)

                        // Option+Right: Skip forward
                        Button(action: { speechService.skipForward() }) { EmptyView() }
                            .hidden()
                            .keyboardShortcut(.rightArrow, modifiers: .option)

                        // Option+Left: Skip backward
                        Button(action: { speechService.skipBackward() }) { EmptyView() }
                            .hidden()
                            .keyboardShortcut(.leftArrow, modifiers: .option)
                    }
                }
            }
        }
        .environment(searchViewModel)
    }

    // MARK: - History Pagination
    /// Loads the next (older) page and re-anchors the oldest message so prepending does not jump the scroll position.
    /// Shared by the pill and the near-top trigger; no-ops while a page loads, at the end of history, or at the
    /// residency cap.
    private func loadPreviousPage(proxy: ScrollViewProxy) {
        guard !chatHistoryViewModel.isLoadingPage,
              chatHistoryViewModel.canLoadMorePages,
              !chatHistoryViewModel.hasReachedResidencyCap,
              !chatHistoryViewModel.currentChatMessages.isEmpty else { return }

        let anchorID = chatHistoryViewModel.currentChatMessages.last?.id
        let countBefore = chatHistoryViewModel.currentChatMessages.count
        Task {
            await chatHistoryViewModel.loadMoreMessages()
            // A page landed only if the window grew and its oldest row changed; a count change alone can be a new newest
            // message.
            let messages = chatHistoryViewModel.currentChatMessages
            guard messages.count > countBefore, messages.last?.id != anchorID else {
                logger.debug("[PAGINATION] No older page appended (\(messages.count) resident; cap reached: \(chatHistoryViewModel.hasReachedResidencyCap); more in store: \(chatHistoryViewModel.canLoadMorePages)) — viewport left where it is.")
                return
            }
            if let anchorID {
                DispatchQueue.main.async {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
        }
    }

    // MARK: - Scroll Helper
    /// Scrolls to the active search match, paging older messages in first when it lies outside the rendered window.
    /// Reachability is decided before paging, since a match past the residency cap can never become resident.
    /// `currentMatchUnreachable` drives the search bar's caption.
    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard let targetID = searchViewModel.currentMatchMessageID else { return }

        if chatHistoryViewModel.currentChatMessages.contains(where: { $0.id == targetID }) {
            searchViewModel.currentMatchUnreachable = false
            withAnimation(motionSafe(.easeInOut(duration: 0.3))) {
                proxy.scrollTo(targetID, anchor: .center)
            }
            return
        }

        // One corpus position serves both reachability and paging, since `searchCorpusIndex` rebuilds a dictionary per
        // access.
        let corpusIndex = chatHistoryViewModel.searchCorpusIndex(of: targetID)

        guard chatHistoryViewModel.isMatchReachable(messageID: targetID, corpusIndex: corpusIndex) else {
            searchViewModel.currentMatchUnreachable = true
            logger.info("[SEARCH] Match \(targetID.uuidString.prefix(8)) is past the resident window's cap — no page-in attempted; the search bar shows it as older than the loaded history.")
            return
        }

        Task {
            let reachable = await chatHistoryViewModel.ensureMessageIsResident(targetID, corpusIndex: corpusIndex)
            // The user may have moved on (Next/Previous, a query edit) while pages loaded;
            // a stale attempt must neither scroll away from nor relabel the CURRENT match.
            guard searchViewModel.currentMatchMessageID == targetID else { return }
            guard reachable else {
                searchViewModel.currentMatchUnreachable = true
                return
            }
            searchViewModel.currentMatchUnreachable = false
            // Let the newly-loaded rows lay out before scrolling to one of them.
            await Task.yield()
            withAnimation(motionSafe(.easeInOut(duration: 0.3))) {
                proxy.scrollTo(targetID, anchor: .center)
            }
        }
    }

    /// Scrolls to the end of the list (the sentinel after the last row) rather than to the newest message.
    /// The newest row's height may still be an estimate; once at the sentinel, `.sizeChanges` keeps the bottom pinned.
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard !chatHistoryViewModel.currentChatMessages.isEmpty else { return }

        if animated {
            withAnimation(motionSafe(.spring(response: 0.4, dampingFraction: 0.8))) {
                proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomSentinelID, anchor: .bottom)
        }
    }

    static let bottomSentinelID = "chat-history-bottom"

    /// `.sizeChanges` anchor: follow growth at the bottom only while the reader is there.
    nonisolated static func sizeChangeAnchor(isAwayFromBottom: Bool) -> UnitPoint {
        isAwayFromBottom ? .top : .bottom
    }
}

// MARK: - Scroll-to-Bottom FAB
struct ScrollToBottomFAB: View {
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(.caption2, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .frame(width: 27, height: 27)
                .background(
                    Circle()
                        .fill(theme.controlBackground)
                        .shadow(color: theme.shadowColor, radius: 4, x: 0, y: 2)
                )
                .overlay(
                    Circle()
                        .stroke(theme.surfaceOverlay, lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel("Scroll to bottom")
    }
}

// MARK: - Empty Conversation Placeholder

extension ChatHistoryView {

    /// A conversation the user can also answer from somewhere else. Drives the empty-state
    /// icon and its "reply from …" line, so it has to name the service that copy names.
    enum RemoteOrigin: Equatable, CaseIterable {
        case telegram, discord, slack

        /// How the copy refers to the service; proper nouns, not localized.
        var serviceName: String {
            switch self {
            case .telegram: return "Telegram"
            case .discord:  return "Discord"
            case .slack:    return "Slack"
            }
        }

        /// Legacy fallback: the title a bridge stamped on conversations it created, for rows without a recorded origin.
        /// Kept as literals so the pinning test catches a new bridge; no bridge writes them today.
        var bridgeTitle: String {
            switch self {
            case .telegram: return "Telegram Chat"
            case .discord:  return "Discord Chat"
            case .slack:    return "Slack Chat"
            }
        }
    }

    /// Best-effort origin for a conversation, from the title its ChatOps bridge stamped on it at creation.
    /// A heuristic: renaming drops the hint and a local title can fake it, so it only decorates an empty conversation
    /// and never gates an action.
    nonisolated static func remoteOrigin(forConversationTitle title: String?) -> RemoteOrigin? {
        guard let title else { return nil }
        return RemoteOrigin.allCases.first { $0.bridgeTitle == title }
    }

    /// The origin to show: the one the bridge recorded at creation, falling back to the title guess.
    /// The recorded answer survives a rename; the fallback covers conversations created before origins were recorded.
    nonisolated static func remoteOrigin(forConversationID id: UUID?, title: String?) -> RemoteOrigin? {
        if let id, let recorded = RemoteConversationOriginStore.origin(for: id) {
            switch recorded {
            case .telegram: return .telegram
            case .discord:  return .discord
            case .slack:    return .slack
            }
        }
        return remoteOrigin(forConversationTitle: title)
    }

    /// The guidance line under the title; names the service the icon shows.
    /// Says "reply from <service>" rather than "from your phone", since Slack ChatOps is not a phone.
    nonisolated static func placeholderSubtitle(for origin: RemoteOrigin?) -> String {
        guard let origin else {
            return String(localized: "Start the conversation by typing a message below.")
        }
        return String(localized: "This conversation was started from \(origin.serviceName).\nType here or reply from \(origin.serviceName).")
    }
}

/// Shown when a conversation is selected but has no messages yet.
/// Provides contextual guidance so the user knows the conversation is ready for input.
private struct EmptyConversationPlaceholder: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(MainApplicationViewModel.self) private var mainAppViewModel

    /// Everything the placeholder needs out of the store — resolved by ONE fetch.
    private struct Resolved {
        let title: String
        let origin: ChatHistoryView.RemoteOrigin?
    }

    /// Read exactly once per body pass, never from a nested view.
    /// `getConversation(withId:)` is a synchronous main-actor SwiftData fetch.
    private var resolved: Resolved {
        let fallbackTitle = String(localized: "New Conversation")
        guard let convID = mainAppViewModel.selectedConversationID else {
            return Resolved(title: fallbackTitle, origin: nil)
        }
        guard let entity = mainAppViewModel.persistenceService.getConversation(withId: convID) else {
            // The origin recording is keyed by conversation id, not the store row, so it still answers; only the title is
            // lost.
            let recorded = ChatHistoryView.remoteOrigin(forConversationID: convID, title: nil)
            logger.debug("[PLACEHOLDER] Conversation \(convID.uuidString.prefix(8)) is selected but absent from the store. CONSEQUENCE: the empty state falls back to the generic title; its origin hint \(recorded == nil ? "is unavailable too" : "still resolves from the recorded provenance").")
            return Resolved(title: fallbackTitle, origin: recorded)
        }
        let storedTitle: String? = entity.userDefinedTitle.flatMap { $0.isEmpty ? nil : $0 }
        return Resolved(
            title: storedTitle ?? fallbackTitle,
            origin: ChatHistoryView.remoteOrigin(forConversationID: convID, title: storedTitle)
        )
    }

    var body: some View {
        let resolved = self.resolved
        VStack(spacing: 20) {
            Spacer()

            // Icon
            Image(systemName: resolved.origin == nil ? "bubble.left.and.text.bubble.right" : "paperplane.circle")
                .font(.system(size: 40, weight: .thin)) // Fixed size: intentional (icon)
                .foregroundStyle(theme.secondaryText.opacity(0.5))

            // Title
            Text(resolved.title)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(theme.primaryText.opacity(0.8))

            // Subtitle / guidance
            Text(ChatHistoryView.placeholderSubtitle(for: resolved.origin))
                .font(theme.fontSubheadline)
                .foregroundStyle(theme.secondaryText.opacity(0.6))
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            // Quick hints
            VStack(spacing: 8) {
                hintRow(icon: "sparkles", text: "Ask anything — your agent will reason and use tools")
                hintRow(icon: "doc.text.magnifyingglass", text: "Reference files by attaching context")
                hintRow(icon: "keyboard", text: "Press Enter to send, Shift+Enter for a new line")
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 40)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeIn(duration: 0.3), value: mainAppViewModel.selectedConversationID)
    }

    private func hintRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(theme.accentColor.opacity(0.6))
                .frame(width: 16, alignment: .center)

            Text(text)
                .font(.system(.caption))
                .foregroundStyle(theme.secondaryText.opacity(0.5))
        }
    }
}
