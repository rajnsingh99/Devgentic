// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatHistoryView.swift
//  Devgentic
//
//  Created by Raj Singh
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

    /// Auto-load older messages once the viewport is within this distance of the
    /// top. Kept small on purpose: after a page loads, the previous-oldest message
    /// is re-anchored to the viewport top (the prepend-jump workaround), so a large
    /// prefetch distance would visibly yank the view. Near-zero matches what
    /// clicking the pill at the top always did.
    private static let autoLoadTopThreshold: CGFloat = 60

    /// What the top-of-transcript pagination slot shows (CF-36). `nonisolated static` and
    /// pure — the WF-UI5 shape — because the residency cap is the defect surface:
    /// `canLoadMorePages` deliberately stays TRUE at the cap (the store really has more, and
    /// the history resolver depends on that distinction), so a pill keyed on it alone stayed
    /// enabled forever while `loadMoreMessages` returned before it ever set `isLoadingPage`.
    /// The cap wins over everything but "nothing left to load": it is the state the user
    /// can actually act on (search reaches what scroll-back no longer does).
    enum LoadEarlierAffordance: Equatable {
        /// History is exhausted — nothing to show.
        case hidden
        /// The interactive pill; spinner while a page is in flight.
        case button(loading: Bool)
        /// Non-interactive note: scroll-back stopped at the residency cap.
        case capNotice
    }

    /// [bm-2] Whether an appended newest message should yank the transcript to the bottom.
    ///
    /// It used to be unconditional: ANY change of `currentChatMessages.first?.id` scrolled,
    /// with `showScrollToBottom` — the view's own "the user has scrolled away" signal, which
    /// drives the scroll-to-bottom button — never consulted. So reading back through a long
    /// conversation while a ChatOps message arrived for the conversation on screen, or while a
    /// scheduled run posted into it, threw the reader back to the bottom mid-sentence.
    ///
    /// Two inputs, and BOTH are needed. Following only `sender == .user` does not work: a
    /// ChatOps message IS a user message, just typed in Telegram — `messageSource` is the only
    /// field that separates them, which is why this asks about "locally typed" and not about
    /// the sender. Following only "not away from bottom" does not work either: after a long
    /// streamed answer the button is already showing, so the user's OWN next message would be
    /// inserted off-screen. A message this window typed always wins; anything else defers to
    /// where the reader is.
    ///
    /// The agent placeholder that follows a local send needs no case of its own — the send
    /// scrolled first, so the view is at the bottom and `isAwayFromBottom` is false.
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

    /// Lightweight identity signature for the message list. Changes when a message is
    /// added/removed OR when the first/last message identity changes — e.g. an in-place
    /// replace at an end, or switching to a *same-length* conversation. The cache
    /// previously keyed only on `.count`, so those cases left a stale reversed array
    /// (and a stale search index).
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
                            // Visible affordance + loading indicator for history pagination.
                            // Mostly informational: scrolling near the top auto-loads the next
                            // page (see the onScrollGeometryChange below) — the old gray caption
                            // text read as a label, not a control, and went unnoticed.
                            //
                            // Which of the three states renders is decided by the pure
                            // `loadEarlierAffordance`. At the residency cap the pill used to stay
                            // enabled and inert — `loadMoreMessages` returns before it ever sets
                            // `isLoadingPage`, so not even a spinner flashed — under a tooltip
                            // promising auto-load (CF-36).
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
                                    // Deliberately NOT a control — there is nothing it could do.
                                    // A plain caption with no glass capsule, so it doesn't read as
                                    // a button either.
                                    // ⚠️ "found, not jumped to" — not "searchable", which the
                                    // sibling CF-35 fix makes untrue for exactly these messages:
                                    // ⌘F reaches the store and COUNTS a match past the cap, but
                                    // Next/Previous cannot scroll to one. Promising searchability
                                    // here would send the user after a match they can never read.
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

                                // Messages are stored [Newest -> Oldest], reversed for display [Oldest -> Newest].
                                // Uses cached displayMessages to avoid O(n) reversal on every body evaluation.
                                //
                                // ⚠️ Grouped for DISPLAY: a background task's report is drawn inside
                                // the turn above it, not as a new exchange — see `TranscriptGrouping`.
                                let groupRoles = TranscriptGrouping.roles(oldestFirst: displayMessages)
                                ForEach(displayMessages) { message in
                                    switch groupRoles[message.id] ?? .plain {
                                    case .orphanStub:
                                        // ⚠️ A synthetic row is a turn NOBODY TYPED — the stub a woken
                                        // background-task run persists so its report pairs. With no
                                        // turn in front to continue, it keeps the standalone divider;
                                        // see BackgroundTaskDividerView for why it is not hidden.
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

                                // [B] Says the conversation is not finished: a task is still
                                // running that asked to report here when it ends. Distinct from
                                // the tasks pill, which counts EVERY task in this conversation —
                                // this is only the subset that will speak unprompted.
                                PendingBackgroundReportFooter(
                                    conversationID: mainAppViewModel.selectedConversationID
                                )

                                // A manual compaction ("Compact history" in the context gauge):
                                // running, then its outcome. Its checkpoint card lands where the
                                // summarized turns end — usually above the fold — so without this
                                // the compaction started and finished with nothing on screen.
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
                    // MARK: - Bottom anchoring (2026-09-27)
                    // ⚠️ The scroll view keeps its own place; the code no longer scrolls it after
                    // every change. What this replaced, and why it failed:
                    //   • a near-viewport `minHeight` on the NEWEST row, to lift a new turn to the
                    //     top. It hopped rows on every append (the user message, then the reply
                    //     placeholder a moment later), changing the content height mid-animation —
                    //     the transcript stopped in the middle after a new turn.
                    //   • `proxy.scrollTo(newest, anchor: .bottom)` on load and on send. In a
                    //     LazyVStack the rows below the viewport have ESTIMATED heights, so the
                    //     target was computed against guesses and landed ~90% of the way down.
                    //   • hiding the transcript, scrolling it, then revealing it on every switch.
                    //
                    // Three roles instead:
                    //   .alignment     .top    — a conversation shorter than the window starts at
                    //                            the top and grows downward.
                    //   .initialOffset .bottom — a conversation opens already at its bottom. No
                    //                            scroll happens, so nothing can land short.
                    //   .sizeChanges   bottom while the reader IS at the bottom (so streaming and
                    //                  new turns stay in view, and late row measurements keep it
                    //                  pinned); top while they have scrolled away (so growth at
                    //                  the bottom never drags what they are reading — [bm-2]).
                    .defaultScrollAnchor(.top, for: .alignment)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(Self.sizeChangeAnchor(isAwayFromBottom: showScrollToBottom), for: .sizeChanges)
                    // A fresh scroll view per conversation, so `.initialOffset` applies to each one.
                    // Keyed on the conversation the ROWS belong to — not the sidebar selection, which
                    // leads the rows by the switch debounce and would open the OLD rows "at the
                    // bottom" and then swap content underneath.
                    .id(displayMessages.first?.conversationId)
                    .opacity(isContentReady ? 1 : 0)
                    // MARK: - Scroll-to-Bottom FAB Visibility
                    // "Content extends below the fold" — distance from the viewport bottom to
                    // the content bottom. One signal covers BOTH being scrolled up into history
                    // AND a streaming response growing past the viewport. The previous
                    // onAppear/onDisappear tracking on the newest bubble missed the latter:
                    // a taller-than-viewport bubble stays partially visible, so it never
                    // "disappeared" and the FAB never showed while the tail streamed offscreen.
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
                    // Standard chat-history pagination: reaching the top loads the next
                    // page without hunting for a button (the pill above stays as the
                    // visible affordance + loading indicator). Guards: content revealed,
                    // no conversation load in flight; loadPreviousPage itself no-ops
                    // while a page is loading, at the end of history, or at the residency
                    // cap — the same guard the pill goes through (CF-36).
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
                        // Update cached reversed array to avoid O(n) reversal on every body evaluation.
                        // Keyed on identity (count + first/last id), so a same-count membership change
                        // still refreshes the cache.
                        displayMessages = chatHistoryViewModel.currentChatMessages.reversed()

                        // Search is query-time (no persistent index). While the search bar is open
                        // with a query, re-run it so matches track membership changes (new message,
                        // conversation switch). When the bar is closed this costs nothing — the old
                        // always-rebuild here re-lowercased the whole history on every append.
                        if searchViewModel.isSearchActive, !searchViewModel.effectiveQuery.isEmpty {
                            chatHistoryViewModel.runSearch(searchViewModel)
                        }

                        if !chatHistoryViewModel.isLoadingPage && !chatHistoryViewModel.isInitiallyLoadingConversation {
                            let newest = chatHistoryViewModel.currentChatMessages.first
                            let currentNewestID = newest?.id

                            if currentNewestID != lastNewestMessageID {
                                // [bm-2] The newest id ALWAYS advances, whether or not we follow
                                // it — otherwise the next append would compare against a stale
                                // anchor and scroll for a message the user has already seen.
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
                        // Closing search RELEASES the corpus. It used to live until the
                        // conversation changed, so one ⌘F pinned the whole projection for the
                        // rest of the session.
                        guard !isActive else { return }
                        chatHistoryViewModel.releaseSearchCorpus()
                    }
                    // [CF-38] The fetch is STRUCTURED to this view, not an unstructured `Task`.
                    // Both ways out of an open search cancel a `.task(id:)` — Esc flips the id,
                    // and an interface-mode switch tears the view down — and
                    // `prepareSearchCorpus` refuses to publish into a cancelled task, so
                    // neither ordering can resurrect the corpus behind the release. The
                    // unstructured Task outlived the view: it captured this view's
                    // `searchViewModel` (still `isSearchActive`, because teardown has no false
                    // transition to release on — see `.onDisappear` below), so a fetch in
                    // flight at teardown wrote the full projection back with no chat view
                    // mounted and nothing left able to free it, which is the CH31/AD6/CF-38
                    // retention shape reached through the disappear ordering.
                    // ⚠️ The id carries the CONVERSATION, not just `isSearchActive`. Keyed on the
                    // Bool alone, this task never re-ran across a conversation switch — and
                    // `loadConversation` invalidates the corpus without re-preparing it, so ⌘F
                    // left open across a switch silently fell back to
                    // `currentChatMessages.map(projectedResidentDocument)`: the ~20-message
                    // resident window. The match count collapsed with no indication that search
                    // had stopped reaching the stored history.
                    //
                    // Keyed on the OBSERVED `currentChatMessages` identity rather than on
                    // `loadedConversationID`, which is `@ObservationIgnored` — SwiftUI would not
                    // re-evaluate this id when it changed, leaving the re-run dependent on some
                    // other property happening to invalidate the body. Nil while a load is in
                    // flight (the switch empties the array first), which simply defers the
                    // prepare to the load's completion.
                    //
                    // `prepareSearchCorpus` is idempotent and no-ops when the corpus already
                    // matches `loadedConversationID`, so the extra evaluations cost nothing.
                    .task(id: searchViewModel.isSearchActive
                          ? chatHistoryViewModel.currentChatMessages.first?.conversationId
                          : nil) {
                        guard searchViewModel.isSearchActive else { return }
                        await chatHistoryViewModel.prepareSearchCorpus()
                        // Cancelled means search closed or this view went away — the release
                        // for that already ran and the fetch above published nothing, so
                        // there is nothing to undo. ⚠️ Deliberately NOT a release: a fast
                        // ⌘F → Esc → ⌘F can land this stale continuation AFTER the next
                        // fetch published, and releasing here would free the corpus the
                        // open search bar is about to scan.
                        guard !Task.isCancelled, searchViewModel.isSearchActive else { return }
                        if !searchViewModel.effectiveQuery.isEmpty {
                            chatHistoryViewModel.runSearch(searchViewModel)
                        }
                    }
                    // `ChatHistoryView` is built in two mutually-exclusive places
                    // (`MainApplicationView` and `CodeDedicatedView`), each with its own
                    // `@State searchViewModel` — so switching interface mode tears this view
                    // down without any `isSearchActive` false-transition to release on.
                    .onDisappear { chatHistoryViewModel.releaseSearchCorpus() }

                    // MARK: - Search Bar Overlay
                    if searchViewModel.isSearchActive {
                        ChatSearchBar(searchViewModel: searchViewModel)
                            // Same content lane as the message column and the composer —
                            // a full-bleed bar reads as chrome belonging to the window
                            // rather than to this conversation, and its right edge ran
                            // under the Code Viewer's floating pill.
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
                    // Bottom-trailing WITHIN the content lane (same maxContentWidth cap as the
                    // chat column and the input composer), so it sits at the composer's right
                    // border — not the window edge, and not bottom-center where the floating
                    // Chat/Workflow/Code mode switcher lives.
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
            // Stop speech when switching conversations
            // [sa-4] The speech → Code Viewer hand-off. Observed HERE rather than on the
            // per-message actions row that starts playback: that row lives in the transcript's
            // `LazyVStack` and is released when it scrolls out of the render window, while the
            // reader — a singleton — keeps going. A post into an unmounted row is lost silently
            // (NotificationCenter does not replay, and `pendingCodeBlock` is cleared before the
            // post), so the announcement promised a panel that never opened.
            //
            // ⚠️ No per-message filter is needed or wanted: `SpeechService` runs ONE session at
            // a time and posts only for the message it is reading. Filtering on a message id
            // here would re-introduce the same coupling to a particular row.
            //
            // ⚠️ Both mount sites of this view (Chat mode and Code mode) are fed the SAME
            // app-level view model, so a transient double delivery during a mode switch resolves
            // to one tab — `openTab` refocuses an identical snippet rather than appending.
            // QuickAccess mounts no `ChatHistoryView`, which is correct: its view model does not
            // own a viewer, so `SpeechService` announces a skip there and never posts at all.
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
            //
            // These are gated on `speechService.isActive`. A `keyboardShortcut` in the
            // view hierarchy captures its key combo GLOBALLY within the key window —
            // the in-action `guard` fires too late, AppKit never sees the event. That
            // meant Option+Left / Option+Right (standard word-by-word cursor nav on
            // macOS) were permanently swallowed in the chat input, even with no speech
            // playing. Rendering the buttons only while active frees the combos for
            // normal text-editing use.
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
    /// Loads the next (older) page and re-anchors the previously-oldest message to
    /// the viewport top so prepending rows doesn't jump the scroll position.
    /// Shared by the pill button and the near-top auto-load trigger; safe to call
    /// eagerly — no-ops while a page is in flight, when history is exhausted, or once
    /// the resident window has hit its cap.
    ///
    /// The cap guard and the "only re-anchor if a page landed" check are one fix (CF-36):
    /// at the cap `loadMoreMessages` returns without appending, and an unconditional
    /// `scrollTo` afterwards re-anchored the oldest row to the top on EVERY near-top
    /// scroll tick — yanking the viewport back down each time the user tried to scroll up.
    private func loadPreviousPage(proxy: ScrollViewProxy) {
        guard !chatHistoryViewModel.isLoadingPage,
              chatHistoryViewModel.canLoadMorePages,
              !chatHistoryViewModel.hasReachedResidencyCap,
              !chatHistoryViewModel.currentChatMessages.isEmpty else { return }

        let anchorID = chatHistoryViewModel.currentChatMessages.last?.id
        let countBefore = chatHistoryViewModel.currentChatMessages.count
        Task {
            await chatHistoryViewModel.loadMoreMessages()
            // A page landed only if the window GREW and its oldest row changed. Count alone
            // is also satisfied by a new message arriving at the newest end during the
            // await, and re-anchoring on that would produce the same yank.
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
    /// Scrolls to the active search match, paging older messages in first when the match
    /// lives outside the rendered window. Without the page-in, a store-backed match that
    /// isn't resident has no view to scroll to and the jump silently does nothing.
    ///
    /// Reachability is decided BEFORE any paging (CF-35): a match past the residency cap can
    /// never be made resident, and walking the store to discover that froze the main actor
    /// for seconds on one debounced keystroke. Unreachable is a user-visible state —
    /// `currentMatchUnreachable` drives the search bar's caption — not a bare return.
    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard let targetID = searchViewModel.currentMatchMessageID else { return }

        if chatHistoryViewModel.currentChatMessages.contains(where: { $0.id == targetID }) {
            searchViewModel.currentMatchUnreachable = false
            withAnimation(motionSafe(.easeInOut(duration: 0.3))) {
                proxy.scrollTo(targetID, anchor: .center)
            }
            return
        }

        // [views/bm-5] ONE corpus position for both questions below. `searchCorpusIndex` reads
        // the COMPUTED `searchCorpus` — a dictionary rebuild plus a sort per access — and this
        // path asked it twice for the same message: once to decide reachability, then again
        // inside the paging call. Resolved here, on the main actor, exactly where the first of
        // those two reads already happened.
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

    /// Scrolls to the END of the list — the sentinel after the last row — rather than to the
    /// newest message. The newest message is a lazily measured row whose height may still be an
    /// estimate; the sentinel is always last. Once there, `.sizeChanges` pins the bottom, so any
    /// row that finishes measuring afterwards cannot leave the view short of it.
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

        /// How the copy refers to the service. Proper nouns — deliberately not localized.
        var serviceName: String {
            switch self {
            case .telegram: return "Telegram"
            case .discord:  return "Discord"
            case .slack:    return "Slack"
            }
        }

        /// LEGACY-ONLY fallback: the title a bridge used to stamp on conversations it created,
        /// for rows that predate provenance being recorded.
        ///
        /// ⚠️ The coupling this comment used to assert is GONE. No bridge stamps these titles any
        /// more — `ChatOpsCommandService.newConversation` creates with an empty title so
        /// auto-titling works, and provenance is written to `RemoteConversationOriginStore`
        /// instead. Grepping the tree, these three literals now live in exactly two places: here
        /// and `RemoteConversationOriginStore`. Kept as literals deliberately so the pinning test
        /// catches a fourth bridge; do NOT reintroduce the claim that a bridge writes them.
        var bridgeTitle: String {
            switch self {
            case .telegram: return "Telegram Chat"
            case .discord:  return "Discord Chat"
            case .slack:    return "Slack Chat"
            }
        }
    }

    /// Best-effort origin for a conversation, from the only signal that exists today: the title
    /// its ChatOps bridge stamped on it at creation.
    ///
    /// ⚠️ A HEURISTIC, knowingly. `userDefinedTitle` is user-editable, so renaming a Telegram
    /// conversation drops the hint and naming a local one "Discord Chat" fakes it. It is only
    /// ever consulted for decoration on an EMPTY conversation — an icon and a line of guidance —
    /// so a wrong answer costs one misleading sentence and nothing else. It must never gate an
    /// action. The real fix is a persisted origin on `ConversationSD`; until then this at least
    /// covers all three bridges rather than only Telegram (CF-39).
    nonisolated static func remoteOrigin(forConversationTitle title: String?) -> RemoteOrigin? {
        guard let title else { return nil }
        return RemoteOrigin.allCases.first { $0.bridgeTitle == title }
    }

    /// The origin to show: the one the bridge RECORDED at creation, falling back to the title
    /// guess above.
    ///
    /// ⚠️ The recorded answer is authoritative and survives a rename, which is the half the title
    /// heuristic cannot do. The fallback is kept ONLY for conversations created before origins
    /// were recorded — dropping it would silently degrade every existing remote conversation to
    /// the local hint. It carries the heuristic's false positive with it (a local conversation
    /// the user names "Discord Chat"), unchanged from before and still costing one sentence.
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

    /// The guidance line under the title. Names the service the icon promises instead of telling
    /// every remote user their conversation came from Telegram (CF-39), and says "reply from
    /// <service>" rather than "reply from your phone" — Slack ChatOps is not a phone.
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

    /// ⚠️ Read exactly once per body pass (see `body`), never from a nested view.
    /// `getConversation(withId:)` is a synchronous main-actor SwiftData fetch, and the previous
    /// shape ran one per property ACCESS — three per body pass for the same entity (CF-39).
    private var resolved: Resolved {
        let fallbackTitle = String(localized: "New Conversation")
        guard let convID = mainAppViewModel.selectedConversationID else {
            return Resolved(title: fallbackTitle, origin: nil)
        }
        guard let entity = mainAppViewModel.persistenceService.getConversation(withId: convID) else {
            // [CF-39] The origin recording is keyed by conversation id, not by the store row, so
            // it still answers here. Only the TITLE is lost when the row is missing.
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
