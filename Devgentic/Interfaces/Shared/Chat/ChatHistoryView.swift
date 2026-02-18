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
    private let verticalListPadding = UITheme.Spacing.large
    
    @EnvironmentObject private var mainAppViewModel: MainApplicationViewModel
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel
    
    // Track the ID of the newest message to handle auto-scrolling for new content.
    @State private var lastNewestMessageID: UUID?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            
                            // "Load Previous" Button
                            if mainAppViewModel.selectedConversationID != nil && chatHistoryViewModel.canLoadMorePages {
                                Button(action: {
                                    let anchorID = chatHistoryViewModel.currentChatMessages.last?.id
                                    Task {
                                        await chatHistoryViewModel.loadMoreMessages()
                                        if let anchorID = anchorID {
                                            // Keep position at the older message after loading history
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
                                .padding(.bottom, UITheme.Spacing.medium)
                            }
                            
                            if mainAppViewModel.selectedConversationID != nil {
                                // Messages are stored [Newest -> Oldest], reversed for display [Oldest -> Newest].
                                ForEach(chatHistoryViewModel.currentChatMessages.reversed()) { message in
                                    // MARK: - DYNAMIC VIEWPORT STRATEGY
                                    // Check if this is the active (last) message in the conversation.
                                    let isLast = chatHistoryViewModel.currentChatMessages.first?.id == message.id
                                    
                                    ChatBubbleView(message: message)
                                        .id(message.id)
                                        // 1. If it's the active generation, force full screen height so it doesn't jump around.
                                        // 2. If it's history, let it shrink to fit its natural content size.
                                        .frame(
                                            minHeight: isLast ? (geometry.size.height - 115) : nil,
                                            alignment: .top
                                        )
                                }
                            }
                        }
                        .frame(maxWidth: 1000)
                        .frame(maxWidth: .infinity)
                        .padding(.top, UITheme.Spacing.large)
                        .padding(.bottom, UITheme.Spacing.large)
                    }
                    // MARK: - NEW MESSAGE SCROLLING (Animated)
                    // Triggers when a new message arrives (streaming or user input).
                    .onChange(of: chatHistoryViewModel.currentChatMessages.count) { _, newCount in
                        if !chatHistoryViewModel.isLoadingPage && !chatHistoryViewModel.isInitiallyLoadingConversation {
                            let currentNewestID = chatHistoryViewModel.currentChatMessages.first?.id
                            
                            if currentNewestID != lastNewestMessageID {
                                lastNewestMessageID = currentNewestID
                                // Animate scroll for new interactions to show flow
                                DispatchQueue.main.async {
                                    scrollToBottom(proxy: proxy, animated: true)
                                }
                            }
                        }
                    }
                    // MARK: - INITIAL LOAD SCROLLING (Instant)
                    // Triggers when opening a conversation. Jumps directly to the true bottom.
                    .onChange(of: chatHistoryViewModel.isInitiallyLoadingConversation) { _, isLoading in
                        if !isLoading {
                            lastNewestMessageID = chatHistoryViewModel.currentChatMessages.first?.id
                            
                            // INSTANT JUMP: No animation.
                            // We use a tiny delay to ensure Layout has calculated the minHeight frames.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                scrollToBottom(proxy: proxy, animated: false)
                            }
                        }
                    }
                }
                
                // Loading Indicator
                if chatHistoryViewModel.isInitiallyLoadingConversation {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.ultraThinMaterial)
                        .transition(.opacity)
                }
            }
            .onAppear {
                lastNewestMessageID = chatHistoryViewModel.currentChatMessages.first?.id
            }
        }
    }
    
    // MARK: - Scroll Helper
    /// Scrolls to the true bottom of the chat (the latest message).
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        // Since messages are stored [Newest...Oldest], the "last" message in time is at index 0.
        // In the View loop (reversed), this message is rendered at the very bottom.
        guard let newestMessageID = chatHistoryViewModel.currentChatMessages.first?.id else { return }
            
        if animated {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                proxy.scrollTo(newestMessageID, anchor: .bottom)
            }
        } else {
            // Instant jump to the true bottom
            proxy.scrollTo(newestMessageID, anchor: .bottom)
        }
    }
}
