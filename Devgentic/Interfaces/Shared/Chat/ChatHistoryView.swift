//
//  ChatHistoryView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatHistoryView")

// MARK: - ChatHistoryView
/// A standard bottom-up chat interface.
struct ChatHistoryView: View {
    @Environment(\.appTheme) private var theme

    @EnvironmentObject private var mainAppViewModel: MainApplicationViewModel
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel

    // Track the ID of the newest message to handle auto-scrolling for new content.
    @State private var lastNewestMessageID: UUID?

    // MARK: - Initial Scroll State
    /// Hides the ScrollView until the initial scrollTo completes, preventing visible jumps.
    @State private var isContentReady: Bool = true

    // MARK: - Scroll-to-Bottom FAB State
    @State private var showScrollToBottom: Bool = false

    // MARK: - Speech Service
    @ObservedObject private var speechService = SpeechService.shared

    // MARK: - Search State
    @StateObject private var searchViewModel = ChatSearchViewModel()

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .top) {
                    ScrollView {
                        LazyVStack(spacing: 0) {

                            // "Load Previous" Button
                            if mainAppViewModel.selectedConversationID != nil && chatHistoryViewModel.canLoadMorePages {
                                Button(action: {
                                    let anchorID = chatHistoryViewModel.currentChatMessages.last?.id
                                    Task {
                                        await chatHistoryViewModel.loadMoreMessages()
                                        if let anchorID = anchorID {
                                            DispatchQueue.main.async {
                                                proxy.scrollTo(anchorID, anchor: .top)
                                            }
                                        }
                                    }
                                }) {
                                    Text(chatHistoryViewModel.isLoadingPage ? "Loading..." : "Load Previous Messages")
                                        .font(.caption)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity)
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, theme.spacingMedium)
                            }

                            if mainAppViewModel.selectedConversationID != nil {
                                // Messages are stored [Newest -> Oldest], reversed for display [Oldest -> Newest].
                                ForEach(chatHistoryViewModel.currentChatMessages.reversed()) { message in
                                    let isLast = chatHistoryViewModel.currentChatMessages.first?.id == message.id

                                    ChatBubbleView(message: message)
                                        .id(message.id)
                                        .frame(
                                            minHeight: isLast ? (geometry.size.height - 115) : nil,
                                            alignment: .top
                                        )
                                        // Track when the newest message scrolls out of view for FAB visibility
                                        .onAppear { if isLast { showScrollToBottom = false } }
                                        .onDisappear { if isLast { showScrollToBottom = true } }
                                }
                            }
                        }
                        .frame(maxWidth: 1000)
                        .frame(maxWidth: .infinity)
                        .padding(.top, searchViewModel.isSearchActive ? 56 : theme.spacingLarge)
                        .padding(.bottom, theme.spacingLarge)
                        .animation(.easeInOut(duration: 0.2), value: searchViewModel.isSearchActive)
                    }
                    .opacity(isContentReady ? 1 : 0)
                    // MARK: - NEW MESSAGE SCROLLING (Animated)
                    .onChange(of: chatHistoryViewModel.currentChatMessages.count) { _, newCount in
                        if !chatHistoryViewModel.isLoadingPage && !chatHistoryViewModel.isInitiallyLoadingConversation {
                            let currentNewestID = chatHistoryViewModel.currentChatMessages.first?.id

                            if currentNewestID != lastNewestMessageID {
                                lastNewestMessageID = currentNewestID
                                DispatchQueue.main.async {
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
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }
                    // MARK: - Search Query Changes
                    .onChange(of: searchViewModel.searchQuery) { _, _ in
                        searchViewModel.performSearch(in: chatHistoryViewModel.currentChatMessages)
                        if let targetID = searchViewModel.currentMatchMessageID {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }

                    // MARK: - Search Bar Overlay
                    if searchViewModel.isSearchActive {
                        ChatSearchBar(searchViewModel: searchViewModel)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(10)
                    }

                    // MARK: - Scroll-to-Bottom FAB
                    if showScrollToBottom && !chatHistoryViewModel.currentChatMessages.isEmpty {
                        VStack {
                            Spacer()
                            ScrollToBottomFAB {
                                scrollToBottom(proxy: proxy, animated: true)
                            }
                            .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(.easeInOut(duration: 0.2), value: showScrollToBottom)
                        .zIndex(5)
                    }

                    // MARK: - Speech Control Island (independent, always above FAB)
                    if speechService.isActive {
                        VStack {
                            Spacer()
                            SpeechControlIsland()
                                .padding(.bottom, showScrollToBottom ? 52 : 16)
                        }
                        .frame(maxWidth: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: speechService.isActive)
                        .animation(.easeInOut(duration: 0.2), value: showScrollToBottom)
                        .zIndex(6)
                    }

                    // Loading Indicator
                    if chatHistoryViewModel.isInitiallyLoadingConversation {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.ultraThinMaterial)
                            .transition(.opacity)
                            .accessibilityLabel("Loading conversation")
                    }
                }
            }
            .onAppear {
                lastNewestMessageID = chatHistoryViewModel.currentChatMessages.first?.id
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
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searchViewModel.toggleSearch()
                    }
                }) { EmptyView() }
                .hidden()
                .keyboardShortcut("f", modifiers: .command)
            }
            // MARK: - Speech Playback Keyboard Shortcuts
            .background {
                Group {
                    // Option+Space: Pause / Resume
                    Button(action: {
                        guard speechService.isActive else { return }
                        speechService.togglePause()
                    }) { EmptyView() }
                    .hidden()
                    .keyboardShortcut(.space, modifiers: .option)

                    // Option+Right: Skip forward
                    Button(action: {
                        guard speechService.isActive else { return }
                        speechService.skipForward()
                    }) { EmptyView() }
                    .hidden()
                    .keyboardShortcut(.rightArrow, modifiers: .option)

                    // Option+Left: Skip backward
                    Button(action: {
                        guard speechService.isActive else { return }
                        speechService.skipBackward()
                    }) { EmptyView() }
                    .hidden()
                    .keyboardShortcut(.leftArrow, modifiers: .option)
                }
            }
        }
        .environmentObject(searchViewModel)
    }

    // MARK: - Scroll Helper
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let newestMessageID = chatHistoryViewModel.currentChatMessages.first?.id else { return }

        if animated {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
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
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .frame(width: 27, height: 27)
                .background(
                    Circle()
                        .fill(theme.controlBackground)
                        .shadow(color: Color.black.opacity(0.15), radius: 4, x: 0, y: 2)
                )
                .overlay(
                    Circle()
                        .stroke(theme.surfaceOverlay, lineWidth: 1)
                )
                .scaleEffect(isHovering ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel("Scroll to bottom")
    }
}
