//
//  ChatHistoryView.swift
//  Devgentic
//
//  Created by Raj Singh
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ChatHistoryView")

fileprivate struct ThinkingIndicatorView: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.accentColor)
                .opacity(isAnimating ? 1.0 : 0.5)
                .animation(Animation.easeInOut(duration: 1).repeatForever(), value: isAnimating)
            
            Text("Thinking...")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
        }
        .onAppear {
            self.isAnimating = true
        }
    }
}


struct ChatHistoryView: View {
    
    @EnvironmentObject private var viewModel: MainApplicationViewModel
    @State private var streamingText: String = ""
    @State private var streamingError: Error? = nil

    private var dividerColor: Color {
        #if os(macOS)
        return Color(NSColor.separatorColor)
        #else
        return Color(UIColor.separator)
        #endif
    }

    private var inProgressMessage: ChatMessage? {
        guard let conversationID = viewModel.selectedConversationID, viewModel.isSending else {
            return nil
        }
        
        let content: MessageContent = if let error = streamingError {
            .error(title: "Streaming Error", details: error.localizedDescription)
        } else {
            .markdownText(streamingText)
        }
        
        return ChatMessage(
            conversationId: conversationID,
            sender: .agent,
            content: content
        )
    }

    var body: some View {
        // --- PHASE 3 CHANGE: Handle initial conversation loading ---
        if viewModel.isInitiallyLoadingConversation {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                chatScrollView
                    .task(id: viewModel.streamingTriggerID) {
                        if let triggerID = viewModel.streamingTriggerID {
                            scrollTo(proxy: proxy, anchor: triggerID, position: .bottom)
                        }
                        await consumeStream()
                    }
            }
        }
    }
    

    private var chatScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // --- PHASE 3 CHANGE: Handle pagination loading indicator ---
                if viewModel.isLoadingPage {
                    ProgressView()
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                        .rotationEffect(.degrees(180))
                        .scaleEffect(x: -1, y: 1, anchor: .center)
                }

                if viewModel.selectedConversationID != nil {
                    ForEach(viewModel.currentChatMessages) { message in
                        messageView(for: message)
                            .id(message.id)
                            .rotationEffect(.degrees(180))
                            .scaleEffect(x: -1, y: 1, anchor: .center)
                            .onAppear {
                                if viewModel.currentChatMessages.last?.id == message.id && viewModel.canLoadMorePages {
                                    logger.debug("Reached top of chat, loading more messages.")
                                    // --- PHASE 3 CHANGE: Call async function in a Task ---
                                    Task {
                                        await viewModel.loadMoreMessages()
                                    }
                                }
                            }
                    }

                    if viewModel.isSending {
                        Spacer().frame(height: 25)

                        if streamingText.isEmpty && streamingError == nil {
                            ThinkingIndicatorView()
                                .id("inProgressMessage")
                                .frame(minHeight: 700, alignment: .top)
                                .rotationEffect(.degrees(180))
                                .scaleEffect(x: -1, y: 1, anchor: .center)
                        } else if let inProgress = inProgressMessage {
                            AgentMessageContainerView(message: inProgress)
                                .id("inProgressMessage")
                                .frame(minHeight: 700, alignment: .top)
                                .rotationEffect(.degrees(180))
                                .scaleEffect(x: -1, y: 1, anchor: .center)
                        }
                    }
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 50)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.clear)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rotationEffect(.degrees(180))
        .scaleEffect(x: -1, y: 1, anchor: .center)
    }
    
    private func consumeStream() async {
        guard let triggerID = viewModel.streamingTriggerID,
              let conversationID = viewModel.selectedConversationID,
              let lastUserMessage = viewModel.currentChatMessages.first(where: { $0.sender == .user && $0.id == triggerID }),
              let userQuery = lastUserMessage.content.textContent
        else {
            return
        }
        
        logger.debug("Task started for trigger ID: \(triggerID.uuidString)")
        
        self.streamingText = ""
        self.streamingError = nil
        var finalFullText = ""
        var finalError: Error?
        
        do {
            let stream = viewModel.streamResponse(
                conversationID: conversationID,
                userQuery: userQuery,
                files: viewModel.attachedFiles
            )
            
            for try await token in stream {
                self.streamingText += token
                finalFullText = self.streamingText
            }
        } catch {
            logger.error("Stream consumption failed: \(error.localizedDescription)")
            self.streamingError = error
            finalError = error
        }
        
        viewModel.finalizeStreaming(
            conversationID: conversationID,
            fullText: finalFullText,
            error: finalError
        )
    }
    
    @ViewBuilder
    private func messageView(for message: ChatMessage) -> some View {
        Group {
            if let index = viewModel.currentChatMessages.firstIndex(where: { $0.id == message.id }), index > 0 {
                let previousMessage = viewModel.currentChatMessages[index - 1]
                
                if message.sender == .user && previousMessage.sender == .agent {
                    Divider()
                        .background(dividerColor)
                        .padding(.vertical, 60)
                } else {
                    Spacer().frame(height: 40)
                }
            }

            if message.sender == .user {
                UserMessageContainerView(message: message)
            } else {
                AgentMessageContainerView(message: message)
            }
        }
    }

    private func scrollTo(proxy: ScrollViewProxy, anchor: any Hashable, position: UnitPoint) {
           DispatchQueue.main.async {
               withAnimation(.easeOut(duration: 0.2)) {
                   proxy.scrollTo(anchor, anchor: position)
               }
           }
       }
}
