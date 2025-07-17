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

    // Computed property to build the temporary in-progress message for display.
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
        // Use ScrollViewReader for all OS versions to get fine-grained anchor control.
        ScrollViewReader { proxy in
            chatScrollView
                .task(id: viewModel.streamingTriggerID) {
                    // When a new stream starts, scroll the user's query to the TOP.
                    if let triggerID = viewModel.streamingTriggerID {
                        scrollTo(proxy: proxy, anchor: triggerID, position: .top)
                    }
                    await consumeStream()
                }
        }
    }
    

    private var chatScrollView: some View {
        ScrollView {
            // Spacing is now handled conditionally inside the messageView builder.
            VStack(alignment: .leading, spacing: 0) {
                if viewModel.selectedConversationID != nil {
                    // Display the full list of messages from the view model.
                    ForEach(viewModel.currentChatMessages) { message in
                        messageView(for: message)
                            .id(message.id)
                    }

                    if viewModel.isSending {
                        // Add more space before the thinking indicator/streaming response.
                        Spacer().frame(height: 25)

                        // If we are waiting for the first token, show the indicator.
                        if streamingText.isEmpty && streamingError == nil {
                            ThinkingIndicatorView()
                                .id("inProgressMessage")
                                .frame(minHeight: 700, alignment: .top)
                        } else if let inProgress = inProgressMessage {
                            // Once tokens arrive, show the streaming message container.
                            AgentMessageContainerView(message: inProgress)
                                .id("inProgressMessage")
                                .frame(minHeight: 700, alignment: .top)
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
    }
    
    /// Consumes the stream from the ViewModel and updates the local state.
    /// This function is called by the .task modifier.
    private func consumeStream() async {
        guard let triggerID = viewModel.streamingTriggerID,
              let conversationID = viewModel.selectedConversationID,
              let lastUserMessage = viewModel.currentChatMessages.last(where: { $0.sender == .user && $0.id == triggerID }),
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
    
    /// A view builder for creating message rows.
    @ViewBuilder
    private func messageView(for message: ChatMessage) -> some View {
        // This Group handles the conditional spacing and dividers between messages.
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

            // Render the actual message view.
            if message.sender == .user {
                UserMessageContainerView(message: message)
            } else {
                AgentMessageContainerView(message: message)
            }
        }
    }

    /// A flexible scroll helper function that scrolls to a given anchor with a specific alignment.
    private func scrollTo(proxy: ScrollViewProxy, anchor: any Hashable, position: UnitPoint) {
           DispatchQueue.main.async {
               withAnimation {
                   proxy.scrollTo(anchor, anchor: position)
               }
           }
       }
}
