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

    var body: some View {
        // This GeometryReader provides the frame of reference for the ScrollView,
        // allowing us to determine if the content's end is visible.
        GeometryReader { geometry in
            ZStack {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        chatScrollView(proxy: proxy, geometry: geometry)
                            // MARK: - FIX: Removed animation from scrollTo
                            // This prevents an animation conflict between the ScrollView moving
                            // and the new chat bubble animating its height.
                            .onChange(of: chatHistoryViewModel.currentChatMessages.count) { _, newCount in
                                if let lastMessage = chatHistoryViewModel.currentChatMessages.last {
                                    DispatchQueue.main.async {
                                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                    }
                                }
                            }

                        if showScrollToBottomButton {
                            scrollToBottomButton(proxy: proxy)
                        }
                    }
                }
                
                if chatHistoryViewModel.isInitiallyLoadingConversation {
                    ProgressView()
                        .controlSize(.large)
                        .transition(.opacity)
                }
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
                                if chatHistoryViewModel.currentChatMessages.first?.id == message.id && chatHistoryViewModel.canLoadMorePages {
                                    logger.debug("Reached top of chat, loading more messages.")
                                    Task {
                                        await chatHistoryViewModel.loadMoreMessages()
                                    }
                                 }
                            }
                    }
                }
                // We place a clear view at the end of the content to act as an anchor.
                Color.clear
                    .frame(height: 1)
                    .anchorPreference(key: ScrollViewContentEnd.self, value: .bottom) { $0 }
            }
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
            .padding(.top, UITheme.Spacing.large)
            .padding(.bottom, UITheme.Spacing.medium)
        }
        // This modifier watches the position of the anchor we set above.
        .onPreferenceChange(ScrollViewContentEnd.self) { anchor in
            guard let anchor = anchor else { return }
            
            // Get the vertical position of the content's bottom edge within the GeometryReader's coordinate space.
            let contentBottomY = geometry[anchor].y
            
            // Get the vertical position of the ScrollView's bottom edge.
            let scrollViewBottomY = geometry.size.height
            
            // We show the button if the content's bottom edge is more than 150 points
            // below the visible bottom of the scroll view, indicating the user has scrolled up.
            let threshold: CGFloat = 150
            let shouldShowButton = contentBottomY > scrollViewBottomY + threshold
            
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

// A new PreferenceKey to track the anchor at the end of the ScrollView content.
struct ScrollViewContentEnd: PreferenceKey {
    static var defaultValue: Anchor<CGPoint>? = nil
    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = nextValue()
    }
}
