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
/// A "Top-Anchored" implementation of the chat interface.
/// This view treats every new prompt as the header of a new "Document Page" rather than
/// a traditional bottom-up chat stream.
struct ChatHistoryView: View {
    private let verticalListPadding = UITheme.Spacing.large
    
    @EnvironmentObject private var mainAppViewModel: MainApplicationViewModel
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel
    
    // STATE FIX: Track the ID of the newest message to determine if we should auto-scroll.
    // If we load history, the newest message ID stays the same, so we shouldn't scroll.
    // If a new message arrives, the ID changes, so we should scroll.
    @State private var lastNewestMessageID: UUID?
    
    var body: some View {
        // GeometryReader is essential for the "Dynamic Viewport" strategy.
        // It allows us to force the active message to be at least the height of the screen.
        GeometryReader { geometry in
            ZStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        // OPTIMIZATION: Switched to LazyVStack for virtualization.
                        // Standard VStack renders ALL messages at once. LazyVStack renders only what's on screen.
                        LazyVStack(spacing: 0) {
                            
                            // OPTIMIZATION: "Load Previous" Button.
                            // Replaces auto-triggered pagination to prevent scrolling race conditions.
                            if mainAppViewModel.selectedConversationID != nil && chatHistoryViewModel.canLoadMorePages {
                                Button(action: {
                                    // Capture the anchor message (the one currently at the top of the list, which is the oldest loaded so far)
                                    // Since currentChatMessages is [Newest...Oldest], .last is the Oldest.
                                    let anchorID = chatHistoryViewModel.currentChatMessages.last?.id
                                    
                                    Task {
                                        await chatHistoryViewModel.loadMoreMessages()
                                        
                                        if let anchorID = anchorID {
                                            // Restore scroll position to the anchor message after loading.
                                            // This prevents the view from jumping to the very top (showing new messages immediately).
                                            // Instead, we stay at the current content and the user can scroll up to see history.
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
                                // OPTIMIZATION: Reverse the loop for display.
                                // Messages are stored [Newest -> Oldest] for O(1) appending.
                                // We reverse them here [Oldest -> Newest] for correct Top-to-Bottom display.
                                // .reversed() on a collection is a cheap O(1) view projection.
                                ForEach(chatHistoryViewModel.currentChatMessages.reversed()) { message in
                                    // MARK: - DYNAMIC VIEWPORT STRATEGY
                                    // Check if this is the active (last) message in the conversation.
                                    // Since we are iterating reversed, the last item in the loop is the Newest message.
                                    let isLast = chatHistoryViewModel.currentChatMessages.first?.id == message.id
                                    
                                    ChatBubbleView(message: message)
                                        .id(message.id)
                                    // Conditional Frame:
                                    // 1. If it's the active generation, force full screen height.
                                    //    This "pushes" all previous context up and out of view, creating a clean slate.
                                    // 2. If it's history, let it shrink to fit its natural content size.
                                        .frame(
                                            minHeight: isLast ? (geometry.size.height - 115) : nil,
                                            alignment: .top
                                        )
                                    // REMOVED: .onAppear pagination trigger.
                                    // We now use the manual button at the top.
                                }
                            }
                        }
                        // MARK: - CENTERED ALIGNMENT FIX
                        // Constrain the content width to create a central column that matches the input area,
                        // rather than spanning the full window width.
                        .frame(maxWidth: 1000)
                        .frame(maxWidth: .infinity) // This centers the 900pt column in the ScrollView
                        .padding(.top, UITheme.Spacing.large)
                        .padding(.bottom, UITheme.Spacing.large)
                    }
                    // MARK: - THE "PUSH" (SCROLL ANCHORING)
                    // Triggers when a new message is added (e.g., User sends a prompt).
                    .onChange(of: chatHistoryViewModel.currentChatMessages.count) { _, newCount in
                        if !chatHistoryViewModel.isLoadingPage && !chatHistoryViewModel.isInitiallyLoadingConversation {
                            
                            // LOGIC FIX: Check if the NEWEST message has changed.
                            // If we just loaded history (appended to end), the newest message (index 0) stays the same.
                            // We only scroll if the newest message ID has physically changed (new message added).
                            let currentNewestID = chatHistoryViewModel.currentChatMessages.first?.id
                            
                            if currentNewestID != lastNewestMessageID {
                                lastNewestMessageID = currentNewestID
                                
                                // Dispatch to main queue to allow layout updates (minHeight changes) to settle
                                // before animating the scroll. This prevents "instant jumps" and ensures smooth anchoring.
                                DispatchQueue.main.async {
                                    scrollToActiveContext(proxy: proxy)
                                }
                            }
                        }
                    }
                    // MARK: - INITIAL LOAD SCROLLING
                    // Triggers when a conversation finishes loading (e.g., Switching chats).
                    // This ensures we jump to the latest context instead of showing the top (oldest) message.
                    .onChange(of: chatHistoryViewModel.isInitiallyLoadingConversation) { _, isLoading in
                        if !isLoading {
                            // Sync the tracker so we don't double-scroll on next update
                            lastNewestMessageID = chatHistoryViewModel.currentChatMessages.first?.id
                            
                            // Small delay ensures layout is ready before scrolling
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToActiveContext(proxy: proxy)
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
                // Initialize state on first appear
                lastNewestMessageID = chatHistoryViewModel.currentChatMessages.first?.id
            }
        }
    }
    
    // MARK: - Scroll Helper
    /// Scrolls to the "Active Context" (The last User Prompt + Agent Response pair).
    private func scrollToActiveContext(proxy: ScrollViewProxy) {
        // Since messages are stored [Newest...Oldest], the "last" message in time is at index 0.
        // But for .id matching, it doesn't matter where it is in the array, as long as we have the ID.
        let messages = chatHistoryViewModel.currentChatMessages
        // Get the newest message (index 0)
        if let newestMessage = messages.first {
            var anchorID = newestMessage.id
            
            // If the newest message is an Agent response, anchor to the User prompt preceding it.
            // In our [Newest...Oldest] array, the preceding User prompt is at index 1.
            if newestMessage.sender == .agent {
                let count = messages.count
                if count >= 2 {
                    let prevMessage = messages[1] // Index 1 is the user prompt for Index 0
                    if prevMessage.sender == .user {
                        anchorID = prevMessage.id
                    }
                }
            }
            
            // Anchor: .top is crucial.
            // It aligns the prompt (the header of the bubble) to the top of the window.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
        }
    }
}
