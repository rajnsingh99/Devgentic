//  /Users/alice/Documents/Workspace/mac-projects/Devgentic/Devgentic/MainApplicationView.swift
import SwiftUI
import AppKit
import os

// Logger
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainApplicationView")

// MARK: - Main View
struct MainApplicationView: View {
    // --- ViewModel ---
    @StateObject private var viewModel = MainApplicationViewModel()

    // --- View State ---
    @FocusState private var isInputFocused: Bool
    @State private var isSidebarVisible: Bool = true
    private let activityBarWidth: CGFloat = 50
    private let sideBarPaneIdealWidth: CGFloat = 280
    private var totalSidebarWidth: CGFloat { activityBarWidth + sideBarPaneIdealWidth }

    // --- Constants for UI adjustments ---
    private let chatHistoryBottomPadding: CGFloat = 130 // Padding for content above floating input
    private let inputAreaCornerRadius: CGFloat = 12 // Corner radius for input area background

    // MARK: - Body
    var body: some View {
        // --- Overall ZStack for Layering Sidebar and Main Content Area ---
        ZStack(alignment: .leading) {

            // --- Main Content Area (Header, Chat History + Input) ---
            // This VStack now holds the Header and the ZStack for chat content
            VStack(spacing: 0) { // No spacing between Header and Chat ZStack
                
                // --- Chat Header View ---
                ChatHeaderView(
                    chatTitle: viewModel.currentConversationTitle,
                    isFilterActive: viewModel.isUserMessagesOnlyFilterActive, // Pass filter state from ViewModel
                    onEyeButtonTapped: {
                        viewModel.toggleUserMessagesFilter() // Call ViewModel's toggle method
                        logger.info("Header eye button tapped. Filter active: \(viewModel.isUserMessagesOnlyFilterActive)")
                    }
                )
                // ChatHeaderView includes its own bottom border for separation.
                // --- End Chat Header View ---

                // --- ZStack for ChatHistory and Floating Input ---
                // This ZStack layers the scrollable chat history and the floating input area
                ZStack(alignment: .bottom) {
                    
                    // --- Chat Message History ---
                    ScrollViewReader { scrollProxy in
                        ChatHistoryView(
                            messages: viewModel.currentChatMessages, // This data is now potentially filtered by the ViewModel
                            isSending: viewModel.isSending,
                            hasSelectedConversation: viewModel.selectedConversationID != nil,
                            chatHistoryBottomPadding: chatHistoryBottomPadding // Pass padding value
                        )
                        .frame(maxWidth: .infinity)
                        // Update scroll position when messages change (including filtering)
                        .onChange(of: viewModel.currentChatMessages) { newMessages in
                            if viewModel.selectedConversationID != nil {
                                // Use slight delay to ensure layout is updated after filter change
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    scrollToBottom(scrollProxy: scrollProxy, messages: newMessages, isSending: viewModel.isSending)
                                }
                            }
                        }
                        // Update scroll on sending state change
                        .onChange(of: viewModel.isSending) { isNowSending in
                             if viewModel.selectedConversationID != nil {
                                 scrollToBottom(scrollProxy: scrollProxy, messages: viewModel.currentChatMessages, isSending: isNowSending)
                             }
                        }
                        // Update scroll and reset filter on conversation change
                        .onChange(of: viewModel.selectedConversationID) { newID in
                            if newID != nil {
                                // Reset the filter when switching conversations
                                if viewModel.isUserMessagesOnlyFilterActive {
                                    viewModel.isUserMessagesOnlyFilterActive = false
                                    logger.info("Reset user messages filter due to conversation change.")
                                }
                                // Scroll to bottom of new conversation
                                scrollToBottom(scrollProxy: scrollProxy, messages: viewModel.currentChatMessages, isSending: viewModel.isSending, animated: false)
                                // Focus input if settings aren't open
                                if !viewModel.showSettings {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        isInputFocused = true
                                    }
                                }
                            } else {
                                // Clear focus if no conversation is selected
                                isInputFocused = false
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top) // Chat history takes available vertical space
                    .overlay { // Placeholder text logic
                        if viewModel.selectedConversationID == nil && viewModel.conversations.isEmpty {
                            Text("Start a new conversation to begin.")
                                .font(.title3)
                                .foregroundColor(.gray.opacity(0.7))
                        } else if viewModel.selectedConversationID == nil && !viewModel.conversations.isEmpty {
                            Text("Select a conversation or start a new one.")
                                .font(.title3)
                                .foregroundColor(.gray.opacity(0.7))
                        } else if viewModel.isUserMessagesOnlyFilterActive && viewModel.currentChatMessages.isEmpty && viewModel.selectedConversationID != nil {
                            // Placeholder when filter is active and there are no user messages
                            Text("No user messages in this conversation yet.")
                                .font(.callout)
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
                    // --- End Chat Message History ---

                    // --- Floating Input Area Wrapper ---
                    VStack(spacing: 0) { // Wrapper for ChatInputAreaView
                        ChatInputAreaView( // This view manages its own background/border now
                            userInput: $viewModel.userInput,
                            showContextArea: $viewModel.showContextArea,
                            activeContextFilePath: $viewModel.activeContextFilePath,
                            isSending: viewModel.isSending,
                            showSettings: viewModel.showSettings,
                            isInputFocused: $isInputFocused,
                            onSendMessage: viewModel.sendMessage,
                            onToggleContext: {
                                withAnimation { viewModel.toggleContextArea() }
                            }
                        )
                    }
                    // Apply padding to the wrapper to position the floating input
                    .padding(.horizontal) // Inset from left/right edges
                    .padding(.bottom, 8)   // Inset from bottom edge
                    // Background and corner radius are now handled within ChatInputAreaView
                    .frame(maxWidth: 1050) // Max width constraint for the input area content
                    .shadow(color: SwiftUI.Color.black.opacity(0.2), radius: 10, x: 0, y: 5) // Optional shadow
                    // --- End Floating Input Area Wrapper ---

                } // End ZStack for ChatHistory and Input
                .frame(maxWidth: .infinity, maxHeight: .infinity) // This ZStack takes all remaining space
                // This background provides the "glass effect" for the ChatHistoryView area.
                .background(VisualEffectBlur(material: .windowBackground))
                // --- End ZStack for ChatHistory and Input ---

            } // End Main Content VStack (Header + Chat ZStack)
            .padding(.leading, isSidebarVisible ? totalSidebarWidth : activityBarWidth) // Adjust based on sidebar visibility
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            // --- End Main Content Area ---


            // --- Layer 2: VS Code Style Sidebar ---
            VSCodifiedSidebarContainerView(isSidebarVisible: $isSidebarVisible)
                .environmentObject(viewModel)
                .frame(width: isSidebarVisible ? totalSidebarWidth : activityBarWidth)
                .zIndex(1) // Ensure sidebar is above the main content's leading padding
            // --- End Sidebar ---


            // --- Layer 3: Settings Panel Overlay ---
            if viewModel.showSettings {
                SettingsPanelView(
                    viewModel: viewModel,
                    showSettings: $viewModel.showSettings
                )
                .transition(.scale.combined(with: .opacity))
                .zIndex(2) // Settings panel on top of everything
            }
            // --- End Settings Panel Overlay ---

            // Hidden Button for Keyboard Shortcut (Cmd+N)
            Button(action: {
                if viewModel.selectedConversationID != nil {
                     viewModel.selectedConversationID = nil
                     logger.debug("Cleared selected conversation ID via Cmd+N.")
                 }
                 if isSidebarVisible {
                      isSidebarVisible = false
                      logger.debug("Hid sidebar pane via Cmd+N.")
                 }
            }) { EmptyView() }
                .hidden()
                .keyboardShortcut("n", modifiers: .command)

        } // End Overall ZStack
        .opacity(viewModel.windowOpacity)
        .frame(minWidth: 800, minHeight: 500) // Minimum window size
        // --- Focus Management ---
        .onAppear {
             // Initial focus attempt
             if viewModel.selectedConversationID != nil && !viewModel.showSettings {
                 DispatchQueue.main.async { isInputFocused = true }
             }
         }
        .onChange(of: viewModel.showSettings) { showingSettings in
            // Refocus input when settings are closed
            if !showingSettings && viewModel.selectedConversationID != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            } else if showingSettings {
                // Remove focus when settings open
                isInputFocused = false
            }
        }
        .onChange(of: viewModel.isSending) { isNowSending in
            // Refocus input after sending completes
            if !isNowSending && !viewModel.showSettings && viewModel.selectedConversationID != nil {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            }
        }
        // --- End Focus Management ---
    }

    // MARK: - Helper Functions (View-Specific)

    // Scroll helper function updated to handle filter state for thinking indicator
    private func scrollToBottom(scrollProxy: ScrollViewProxy, messages: [ChatMessage], isSending: Bool, animated: Bool = true) {
         let targetID: AnyHashable?

         // Only target the thinking indicator if we are sending AND the filter is not active (so agent messages are visible)
         if isSending && !viewModel.isUserMessagesOnlyFilterActive {
            targetID = "thinkingIndicator"
         } else if let lastMessageId = messages.last?.id { // Otherwise, target the last visible message
             targetID = lastMessageId
         } else {
             targetID = nil // No messages and not sending/filtered
         }

         guard let finalID = targetID else {
             // logger.debug("scrollToBottom called but no target message or indicator found.")
             return
         }

         logger.trace("Scrolling to ID \(finalID)")
         if animated {
             withAnimation(.easeOut(duration: 0.2)) {
                 scrollProxy.scrollTo(finalID, anchor: .bottom)
             }
         } else {
             // Use DispatchQueue for non-animated scroll after state change might need layout update
             DispatchQueue.main.async {
                 scrollProxy.scrollTo(finalID, anchor: .bottom)
             }
         }
     }
}

// MARK: - Previews
struct MainApplicationView_ZStack_Previews: PreviewProvider {
    static var previews: some View {
        MainApplicationView()
            .frame(width: 900, height: 600)
            .previewDisplayName("Main View with Header and Filter")
    }
}
