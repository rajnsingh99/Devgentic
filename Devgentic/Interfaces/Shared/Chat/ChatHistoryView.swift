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
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    chatScrollView(proxy: proxy, geometry: geometry)
                        // MARK: - LOGGING ADDED
                        .onChange(of: chatHistoryViewModel.currentChatMessages.first?.id) { oldValue, newValue in
                            logger.debug("STREAM_TRACE: ScrollView onChange(of: message.id) triggered. Old ID: \(oldValue?.uuidString ?? "nil"), New ID: \(newValue?.uuidString ?? "nil"). Scrolling to top of new message.")
                            if let firstMessageId = chatHistoryViewModel.currentChatMessages.first?.id {
                               scrollTo(proxy: proxy, anchor: firstMessageId, position: .top, animated: true)
                            }
                        }
                    
                    if showScrollToBottomButton {
                        scrollToBottomButton(proxy: proxy)
                    }
                }
            }
        }
    }

    private func chatScrollView(proxy: ScrollViewProxy, geometry: GeometryProxy) -> some View {
        ScrollView {
            // MARK: - LOGGING ADDED
            // This GeometryReader will help us track the size of the content inside the ScrollView.
            GeometryReader { contentGeometry in
                Color.clear.onAppear {
                    logger.debug("STREAM_TRACE: ScrollView content GeometryReader appeared. Initial size: \(contentGeometry.size.height)")
                }
                // Log any change in the content's height.
                .onChange(of: contentGeometry.size) { oldSize, newSize in
                    logger.debug("STREAM_TRACE: ScrollView content size changed. Old height: \(oldSize.height), New height: \(newSize.height)")
                }
            }
            
            LazyVStack(alignment: .leading, spacing: 0) {
                if mainAppViewModel.selectedConversationID != nil {
                    ForEach(Array(chatHistoryViewModel.currentChatMessages.enumerated()), id: \.element.id) { index, message in
                        ChatBubbleView(message: message)
                            .id(message.id)
                            .rotationEffect(.degrees(180))
                            .scaleEffect(x: -1, y: 1, anchor: .center)
                            .onAppear {
                                if chatHistoryViewModel.currentChatMessages.last?.id == message.id && chatHistoryViewModel.canLoadMorePages {
                                    logger.debug("Reached top of chat, loading more messages.")
                                    Task {
                                        await chatHistoryViewModel.loadMoreMessages()
                                    }
                                }
                                
                                if index > 5 {
                                    withAnimation(.easeInOut) {
                                        showScrollToBottomButton = true
                                    }
                                }
                                if index < 2 {
                                     withAnimation(.easeInOut) {
                                        showScrollToBottomButton = false
                                    }
                                }
                            }

                        if index < chatHistoryViewModel.currentChatMessages.count - 1 {
                            Spacer().frame(height: UITheme.Spacing.xlarge)
                                .rotationEffect(.degrees(180))
                                .scaleEffect(x: -1, y: 1, anchor: .center)
                        }
                    }
                }
                
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.top, UITheme.Spacing.large)
            .padding(.bottom, UITheme.Spacing.medium)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rotationEffect(.degrees(180))
        .scaleEffect(x: -1, y: 1, anchor: .center)
    }
    
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button(action: {
            if let lastMessageId = chatHistoryViewModel.currentChatMessages.first?.id {
                scrollTo(proxy: proxy, anchor: lastMessageId, position: .top, animated: true)
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

    private func scrollTo(proxy: ScrollViewProxy, anchor: any Hashable, position: UnitPoint, animated: Bool) {
        logger.debug("scrollTo called for anchor: \(String(describing: anchor)), position: \(String(describing: position)), animated: \(animated)")
        if animated {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(anchor, anchor: position)
            }
        } else {
            proxy.scrollTo(anchor, anchor: position)
        }
    }
}
