//
//  ChatHistoryView.swift
//  Devgentic
//
//  Created by Raj Singh
//


import SwiftUI
import os
import Down

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatHistoryView")

// MARK: - ChatHistoryView
struct ChatHistoryView: View {

    @EnvironmentObject private var mainAppViewModel: MainApplicationViewModel
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel // Dedicated view model
    
    @State private var showScrollToBottomButton = false
    @State private var scrollTargetID: UUID?
    @State private var chatInputAreaHeight: CGFloat = 0 // To store the height of the chat input area

    var body: some View {
        GeometryReader { geometry in // Use GeometryReader to get available height
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    chatScrollView(proxy: proxy, geometry: geometry)
                        // Observe streamingTriggerID from chatHistoryViewModel
                        .onChange(of: chatHistoryViewModel.streamingTriggerID) { newTriggerID in
                            if let id = newTriggerID {
                                logger.info("Streaming trigger ID changed. Setting scroll target to \(id.uuidString)")
                                self.scrollTargetID = id
                            }
                        }
                        .onChange(of: scrollTargetID) { targetID in
                            if let id = targetID {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    logger.debug("Attempting to scroll to placeholder ID \(id.uuidString) with position: .top")
                                    scrollTo(proxy: proxy, anchor: id, position: .top, animated: false)
                                    self.scrollTargetID = nil
                                }
                            }
                        }
                        // Observe currentChatMessages from chatHistoryViewModel
                        .onChange(of: chatHistoryViewModel.currentChatMessages.first?.id) {
                            if !chatHistoryViewModel.isSending, let firstMessageId = chatHistoryViewModel.currentChatMessages.first?.id {
                               scrollTo(proxy: proxy, anchor: firstMessageId, position: .top, animated: true)
                            }
                        }
                    
                    if showScrollToBottomButton {
                        scrollToBottomButton(proxy: proxy)
                    }
                }
            }
        }
        // This is a placeholder to simulate the chat input area height.
        // In a real app, you'd measure the actual height of your chat input view.
        .onAppear {
            // Estimate chat input area height. Adjust this value based on your actual UI.
            self.chatInputAreaHeight = 100 // Example: 100 points for input field + padding
        }
    }

    private func chatScrollView(proxy: ScrollViewProxy, geometry: GeometryProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // NEW: Shimmering loading view
                if chatHistoryViewModel.isSending { // Use chatHistoryViewModel here
                    ShimmeringLoadingView(
                        availableHeight: geometry.size.height,
                        chatInputAreaHeight: chatInputAreaHeight
                    )
                    .id("shimmering_loader") // Give it an ID for potential scrolling
                    .transition(.opacity) // Add a fade transition
                }

                if mainAppViewModel.selectedConversationID != nil { // Still depends on MainAppViewModel for selected conversation
                    ForEach(Array(chatHistoryViewModel.currentChatMessages.enumerated()), id: \.element.id) { index, message in // Use chatHistoryViewModel here
                        ChatBubbleView(message: message)
                            .id(message.id)
                            .rotationEffect(.degrees(180))
                            .scaleEffect(x: -1, y: 1, anchor: .center)
                            .onAppear {
                                if chatHistoryViewModel.currentChatMessages.last?.id == message.id && chatHistoryViewModel.canLoadMorePages { // Use chatHistoryViewModel here
                                    logger.debug("Reached top of chat, loading more messages.")
                                    Task {
                                        await chatHistoryViewModel.loadMoreMessages() // Use chatHistoryViewModel here
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

                        if index < chatHistoryViewModel.currentChatMessages.count - 1 { // Use chatHistoryViewModel here
                            Spacer().frame(height: UITheme.Spacing.xlarge)
                                .rotationEffect(.degrees(180))
                                .scaleEffect(x: -1, y: 1, anchor: .center)
                        }
                    }
                }
                
                Spacer(minLength: 0)
            }
            // MODIFIED: Added maxWidth and center alignment to LazyVStack
            .frame(maxWidth: 1100) // Constrain the content width
            .frame(maxWidth: .infinity, alignment: .top) // Center the constrained content
            .padding(.top, UITheme.Spacing.large)
            .padding(.bottom, UITheme.Spacing.medium)
            // Removed .frame(maxWidth: .infinity, alignment: .topLeading) as it's now handled by the two frame modifiers above
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity) // ScrollView itself takes full available width
        .rotationEffect(.degrees(180))
        .scaleEffect(x: -1, y: 1, anchor: .center)
    }
    
    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button(action: {
            if let lastMessageId = chatHistoryViewModel.currentChatMessages.first?.id { // Use chatHistoryViewModel here
                scrollTo(proxy: proxy, anchor: lastMessageId, position: .bottom, animated: true)
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

    // Removed consumeStream() as its logic is now orchestrated by MainApplicationViewModel
    // which updates ChatHistoryViewModel. ChatHistoryView now just observes.

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

// MARK: - NEW: ShimmeringLoadingView
fileprivate struct ShimmeringLoadingView: View {
    let availableHeight: CGFloat
    let chatInputAreaHeight: CGFloat
    @State private var isAnimating = false

    var body: some View {
        let userMessageHeight: CGFloat = 80 // Estimate for user message bubble + padding
        let thinkingIndicatorHeight: CGFloat = 40 // Estimate for thinking indicator + padding
        let contentHeight = userMessageHeight + thinkingIndicatorHeight + UITheme.Spacing.xlarge // Add spacing between messages

        // Calculate the shimmering view height
        let shimmeringHeight = max(0, availableHeight - contentHeight - UITheme.Spacing.large - UITheme.Spacing.medium)

        return VStack {
            Spacer() // Pushes the content below it to the bottom of the shimmering area
            Rectangle()
                .fill(UITheme.Colors.controlBackground)
                .frame(height: 20) // A small bar to simulate content
                .cornerRadius(UITheme.CornerRadius.small)
                .opacity(0.7)
                .padding(.horizontal, 50)
                .padding(.bottom, UITheme.Spacing.medium)

            Rectangle()
                .fill(UITheme.Colors.controlBackground)
                .frame(height: 20)
                .cornerRadius(UITheme.CornerRadius.small)
                .opacity(0.7)
                .padding(.horizontal, 80)
                .padding(.bottom, UITheme.Spacing.medium)
        }
        .frame(height: shimmeringHeight, alignment: .bottom) // Set the calculated height
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    UITheme.Colors.controlBackground.opacity(0.0),
                    UITheme.Colors.controlBackground.opacity(0.3),
                    UITheme.Colors.controlBackground.opacity(0.0)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .offset(x: isAnimating ? availableHeight : -availableHeight) // Move across the view
            .animation(Animation.linear(duration: 1.5).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
        )
        .clipped() // Clip the shimmering effect to its bounds
    }
}


