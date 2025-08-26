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
struct ChatHistoryView: View {

    @EnvironmentObject private var mainAppViewModel: MainApplicationViewModel
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel
    
    @State private var showScrollToBottomButton = false
    @State private var isContentVisible = false // State to control content visibility

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        chatScrollView(proxy: proxy, geometry: geometry)
                            // Control opacity to prevent showing content before it's ready
                            .opacity(isContentVisible ? 1 : 0)
                            .onChange(of: chatHistoryViewModel.currentChatMessages) { _, newMessages in
                                // Hide content immediately when conversation changes
                                isContentVisible = false
                                
                                if let lastMessage = newMessages.last {
                                    // Defer scroll to allow UI to render
                                    DispatchQueue.main.async {
                                        withAnimation(.none) { // Scroll without animation
                                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                        }
                                        
                                        // Defer showing the content until after the scroll has completed
                                        DispatchQueue.main.async {
                                            withAnimation(.easeIn(duration: 0.2)) {
                                                isContentVisible = true
                                            }
                                        }
                                    }
                                } else {
                                    // If there are no messages, show the (empty) view immediately
                                    isContentVisible = true
                                }
                            }

                        if showScrollToBottomButton {
                            scrollToBottomButton(proxy: proxy)
                        }
                    }
                }
            }
            .onAppear {
                // On initial launch, if no conversation is selected, the view should be considered "visible"
                // to prevent the loading indicator from showing incorrectly.
                if mainAppViewModel.selectedConversationID == nil {
                    isContentVisible = true
                }
            }
            
            // Show a loading spinner on top ONLY when a conversation is actively being loaded.
            if chatHistoryViewModel.isInitiallyLoadingConversation {
                ProgressView()
                    .controlSize(.large)
                    .transition(.opacity)
            }
        }
    }

    private func chatScrollView(proxy: ScrollViewProxy, geometry: GeometryProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if mainAppViewModel.selectedConversationID != nil {
                    ForEach(chatHistoryViewModel.currentChatMessages) { message in
                        ChatBubbleView(message: message)
                            .id(message.id)
                            .onAppear {
                                // Logic to load more messages when the user scrolls to the top.
                                if chatHistoryViewModel.currentChatMessages.first?.id == message.id && chatHistoryViewModel.canLoadMorePages {
                                    logger.debug("Reached top of chat, loading more messages.")
                                    Task {
                                        await chatHistoryViewModel.loadMoreMessages()
                                    }
                                }
                            }
                    }
                }
                
                // This GeometryReader helps in determining the scroll position.
                GeometryReader { innerProxy in
                    Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: innerProxy.frame(in: .named("scrollview")).minY)
                }
            }
            .padding(.top, UITheme.Spacing.large)
            .padding(.bottom, UITheme.Spacing.medium)
        }
        .coordinateSpace(name: "scrollview")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            // Heuristic to show/hide the "scroll to bottom" button.
            let threshold: CGFloat = 100
            let shouldShowButton = value < -threshold
            if showScrollToBottomButton != shouldShowButton {
                withAnimation {
                    showScrollToBottomButton = shouldShowButton
                }
            }
        }
    }
    
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button(action: {
            if let lastMessageId = chatHistoryViewModel.currentChatMessages.last?.id {
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(lastMessageId, anchor: .bottom)
                }
            }
        }) {
            Image(systemName: "arrow.down")
                .font(UITheme.Fonts.headline)
                .foregroundColor(.white)
                .padding(UITheme.Spacing.medium)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.bottom)
        .transition(.scale.combined(with: .opacity))
    }
}

// PreferenceKey to track the scroll offset.
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
