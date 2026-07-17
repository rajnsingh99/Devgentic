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

    // MARK: - Speech Service
    private var speechService = SpeechService.shared

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

                            // MARK: - Load-Earlier Pill
                            // Visible affordance + loading indicator for history pagination.
                            // Mostly informational: scrolling near the top auto-loads the next
                            // page (see the onScrollGeometryChange below) — the old gray caption
                            // text read as a label, not a control, and went unnoticed.
                            if mainAppViewModel.selectedConversationID != nil && chatHistoryViewModel.canLoadMorePages {
                                Button {
                                    loadPreviousPage(proxy: proxy)
                                } label: {
                                    HStack(spacing: 6) {
                                        if chatHistoryViewModel.isLoadingPage {
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
                                .disabled(chatHistoryViewModel.isLoadingPage)
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, theme.spacingMedium)
                                .help("Older messages load automatically when you scroll to the top")
                                .accessibilityLabel(chatHistoryViewModel.isLoadingPage ? "Loading earlier messages" : "Load earlier messages")
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
                                ForEach(displayMessages) { message in
                                    let isLast = message.id == chatHistoryViewModel.currentChatMessages.first?.id

                                    ChatBubbleView(message: message)
                                        .id(message.id)
                                        .frame(
                                            minHeight: isLast ? (geometry.size.height - 115) : nil,
                                            alignment: .top
                                        )
                                }
                            }
                        }
                        .frame(maxWidth: ViewLayout.maxContentWidth)
                        .frame(maxWidth: .infinity)
                        .padding(.top, searchViewModel.isSearchActive ? 56 : theme.spacingLarge)
                        .padding(.bottom, theme.spacingLarge)
                        .animation(motionSafe(.easeInOut(duration: 0.2)), value: searchViewModel.isSearchActive)
                    }
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
                    // while a page is loading or at the end of history.
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
                        if searchViewModel.isSearchActive, !searchViewModel.searchQuery.isEmpty {
                            searchViewModel.performSearch(in: chatHistoryViewModel.currentChatMessages)
                        }

                        if !chatHistoryViewModel.isLoadingPage && !chatHistoryViewModel.isInitiallyLoadingConversation {
                            let currentNewestID = chatHistoryViewModel.currentChatMessages.first?.id

                            if currentNewestID != lastNewestMessageID {
                                lastNewestMessageID = currentNewestID
                                Task { @MainActor in
                                    scrollToBottom(proxy: proxy, animated: true)
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
                            // Refresh cached display order after initial load
                            displayMessages = chatHistoryViewModel.currentChatMessages.reversed()
                            lastNewestMessageID = chatHistoryViewModel.currentChatMessages.first?.id
                            // Scroll while content is hidden (opacity 0) — invisible to the user.
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                if let id = lastNewestMessageID {
                                    proxy.scrollTo(id, anchor: .bottom)
                                }
                            }
                            // Reveal content on the next frame, after scroll position is applied.
                            DispatchQueue.main.async {
                                isContentReady = true
                            }
                        }
                    }
                    // MARK: - Search Navigation
                    .onChange(of: searchViewModel.currentMatchIndex) { _, _ in
                        if let targetID = searchViewModel.currentMatchMessageID {
                            withAnimation(motionSafe(.easeInOut(duration: 0.3))) {
                                proxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }
                    // MARK: - Search Query Changes (Debounced)
                    .onChange(of: searchViewModel.debouncedQuery) { _, _ in
                        searchViewModel.performSearch(in: chatHistoryViewModel.currentChatMessages)
                        if let targetID = searchViewModel.currentMatchMessageID {
                            withAnimation(motionSafe(.easeInOut(duration: 0.3))) {
                                proxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }

                    // MARK: - Search Bar Overlay
                    if searchViewModel.isSearchActive {
                        ChatSearchBar(searchViewModel: searchViewModel)
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
            }
            // Stop speech when switching conversations
            .onChange(of: mainAppViewModel.selectedConversationID) { _, _ in
                if speechService.isActive {
                    speechService.stop()
                }
            }
            // MARK: - Cmd+F Keyboard Shortcut
            .background {
                Button(action: {
                    withAnimation(motionSafe(.easeInOut(duration: 0.2))) {
                        searchViewModel.toggleSearch()
                    }
                }) { EmptyView() }
                .hidden()
                .keyboardShortcut("f", modifiers: .command)
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
    /// eagerly — no-ops while a page is in flight or when history is exhausted.
    private func loadPreviousPage(proxy: ScrollViewProxy) {
        guard !chatHistoryViewModel.isLoadingPage,
              chatHistoryViewModel.canLoadMorePages,
              !chatHistoryViewModel.currentChatMessages.isEmpty else { return }

        let anchorID = chatHistoryViewModel.currentChatMessages.last?.id
        Task {
            await chatHistoryViewModel.loadMoreMessages()
            if let anchorID {
                DispatchQueue.main.async {
                    proxy.scrollTo(anchorID, anchor: .top)
                }
            }
        }
    }

    // MARK: - Scroll Helper
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let newestMessageID = chatHistoryViewModel.currentChatMessages.first?.id else { return }

        if animated {
            withAnimation(motionSafe(.spring(response: 0.4, dampingFraction: 0.8))) {
                proxy.scrollTo(newestMessageID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(newestMessageID, anchor: .bottom)
        }
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

/// Shown when a conversation is selected but has no messages yet.
/// Provides contextual guidance so the user knows the conversation is ready for input.
private struct EmptyConversationPlaceholder: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(MainApplicationViewModel.self) private var mainAppViewModel

    /// Whether this conversation was created from a remote source (Telegram, Discord).
    private var isRemoteConversation: Bool {
        guard let convID = mainAppViewModel.selectedConversationID,
              let entity = mainAppViewModel.persistenceService.getConversation(withId: convID) else { return false }
        return entity.userDefinedTitle == "Telegram Chat"
    }

    private var conversationTitle: String {
        guard let convID = mainAppViewModel.selectedConversationID,
              let entity = mainAppViewModel.persistenceService.getConversation(withId: convID),
              let title = entity.userDefinedTitle, !title.isEmpty else { return String(localized: "New Conversation") }
        return title
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // Icon
            Image(systemName: isRemoteConversation ? "paperplane.circle" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 40, weight: .thin)) // Fixed size: intentional (icon)
                .foregroundStyle(theme.secondaryText.opacity(0.5))

            // Title
            Text(conversationTitle)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(theme.primaryText.opacity(0.8))

            // Subtitle / guidance
            Text(isRemoteConversation
                 ? "This conversation was started from Telegram.\nType here or reply from your phone."
                 : "Start the conversation by typing a message below."
            )
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
