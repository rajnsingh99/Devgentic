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
        ZStack {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottom) {
                        chatScrollView(proxy: proxy, geometry: geometry)
                            .onChange(of: chatHistoryViewModel.currentChatMessages.count) { _, newCount in
                                // This still helps scroll to the bottom when a new message is added.
                                if let lastMessage = chatHistoryViewModel.currentChatMessages.last {
                                    DispatchQueue.main.async {
                                        withAnimation(.easeOut(duration: 0.3)) {
                                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                        }
                                    }
                                }
                            }

                        if showScrollToBottomButton {
                            scrollToBottomButton(proxy: proxy)
                        }
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
                
                GeometryReader { innerProxy in
                    Color.clear.preference(key: ScrollOffsetPreferenceKey.self, value: innerProxy.frame(in: .named("scrollview")).minY)
                }
            }
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
            .padding(.top, UITheme.Spacing.large)
            .padding(.bottom, UITheme.Spacing.medium)
        }
        .coordinateSpace(name: "scrollview")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
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
