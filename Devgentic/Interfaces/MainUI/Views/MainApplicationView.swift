//  /Users/alice/Documents/Workspace/mac-projects/Devgentic/Devgentic/MainApplicationView.swift
import SwiftUI
import AppKit
import os

// Logger
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainApplicationView")

// MARK: - Main View
struct MainApplicationView: View {
    // --- ViewModel ---
    // Assuming MainApplicationViewModel is already integrated with ConversationStore
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
            VStack(spacing: 0) {
                
                // --- Chat Header View (MODIFIED) ---
                ChatHeaderView(
                    chatTitle: viewModel.currentConversationTitle,
                    isFilterActive: viewModel.isUserMessagesOnlyFilterActive,
                    onEyeButtonTapped: {
                        viewModel.toggleUserMessagesFilter()
                        logger.info("Header eye button tapped. Filter active: \(viewModel.isUserMessagesOnlyFilterActive)")
                    },
                    // --- NEW: Pass transfer action ---
                    onTransferButtonTapped: {
                        viewModel.transferSelectedConversationToOverlay() // Call new ViewModel method
                    },
                    isConversationSelected: viewModel.selectedConversationID != nil // Pass selection state
                    // --- END NEW ---
                )
                // --- End Chat Header View ---

                // --- ZStack for ChatHistory and Floating Input ---
                ZStack(alignment: .bottom) {
                    
                    // --- Chat Message History ---
                    ScrollViewReader { scrollProxy in
                        ChatHistoryView(
                            messages: viewModel.currentChatMessages,
                            isSending: viewModel.isSending,
                            hasSelectedConversation: viewModel.selectedConversationID != nil,
                            chatHistoryBottomPadding: chatHistoryBottomPadding
                        )
                        .frame(maxWidth: .infinity)
                        .onChange(of: viewModel.currentChatMessages) { newMessages in
                            if viewModel.selectedConversationID != nil {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    scrollToBottom(scrollProxy: scrollProxy, messages: newMessages, isSending: viewModel.isSending)
                                }
                            }
                        }
                        .onChange(of: viewModel.isSending) { isNowSending in
                             if viewModel.selectedConversationID != nil {
                                 scrollToBottom(scrollProxy: scrollProxy, messages: viewModel.currentChatMessages, isSending: isNowSending)
                             }
                        }
                        .onChange(of: viewModel.selectedConversationID) { newID in
                            if newID != nil {
                                if viewModel.isUserMessagesOnlyFilterActive {
                                    viewModel.isUserMessagesOnlyFilterActive = false
                                    logger.info("Reset user messages filter due to conversation change.")
                                }
                                scrollToBottom(scrollProxy: scrollProxy, messages: viewModel.currentChatMessages, isSending: viewModel.isSending, animated: false)
                                if !viewModel.showSettings {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        isInputFocused = true
                                    }
                                }
                            } else {
                                isInputFocused = false
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay {
                        if viewModel.selectedConversationID == nil && viewModel.conversations.isEmpty {
                            Text("Start a new conversation to begin.")
                                .font(.title3)
                                .foregroundColor(.gray.opacity(0.7))
                        } else if viewModel.selectedConversationID == nil && !viewModel.conversations.isEmpty {
                            Text("Select a conversation or start a new one.")
                                .font(.title3)
                                .foregroundColor(.gray.opacity(0.7))
                        } else if viewModel.isUserMessagesOnlyFilterActive && viewModel.currentChatMessages.isEmpty && viewModel.selectedConversationID != nil {
                            Text("No user messages in this conversation yet.")
                                .font(.callout)
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
                    // --- End Chat Message History ---

                    // --- Floating Input Area Wrapper ---
                    VStack(spacing: 0) {
                        ChatInputAreaView(
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
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 1050)
                    .shadow(color: SwiftUI.Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
                    // --- End Floating Input Area Wrapper ---

                } // End ZStack for ChatHistory and Input
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VisualEffectBlur(material: .windowBackground))
                // --- End ZStack for ChatHistory and Input ---

            } // End Main Content VStack (Header + Chat ZStack)
            .padding(.leading, isSidebarVisible ? totalSidebarWidth : activityBarWidth)
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            // --- End Main Content Area ---


            // --- Layer 2: VS Code Style Sidebar ---
            VSCodifiedSidebarContainerView(isSidebarVisible: $isSidebarVisible)
                .environmentObject(viewModel)
                .frame(width: isSidebarVisible ? totalSidebarWidth : activityBarWidth)
                .zIndex(1)
            // --- End Sidebar ---


            // --- Layer 3: Settings Panel Overlay ---
            if viewModel.showSettings {
                SettingsPanelView(
                    viewModel: viewModel,
                    showSettings: $viewModel.showSettings
                )
                .transition(.scale.combined(with: .opacity))
                .zIndex(2)
            }
            // --- End Settings Panel Overlay ---

            // Hidden Button for Keyboard Shortcut (Cmd+N)
            Button(action: {
                viewModel.startNewConversation() // Use the method that handles empty chat reuse
                 logger.debug("Triggered new conversation via Cmd+N.")
                 if isSidebarVisible {
                      isSidebarVisible = false
                      logger.debug("Hid sidebar pane via Cmd+N.")
                 }
            }) { EmptyView() }
                .hidden()
                .keyboardShortcut("n", modifiers: .command)

        } // End Overall ZStack
        .opacity(viewModel.windowOpacity)
        .frame(minWidth: 800, minHeight: 500)
        // --- Focus Management ---
        .onAppear {
             if viewModel.selectedConversationID != nil && !viewModel.showSettings {
                 DispatchQueue.main.async { isInputFocused = true }
             }
         }
        .onChange(of: viewModel.showSettings) { showingSettings in
            if !showingSettings && viewModel.selectedConversationID != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            } else if showingSettings {
                isInputFocused = false
            }
        }
        .onChange(of: viewModel.isSending) { isNowSending in
            if !isNowSending && !viewModel.showSettings && viewModel.selectedConversationID != nil {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            }
        }
        // --- End Focus Management ---
    }

    // MARK: - Helper Functions (View-Specific)

    // Scroll helper function (remains the same)
    private func scrollToBottom(scrollProxy: ScrollViewProxy, messages: [ChatMessage], isSending: Bool, animated: Bool = true) {
         let targetID: AnyHashable?
         if isSending && !viewModel.isUserMessagesOnlyFilterActive {
            targetID = "thinkingIndicator"
         } else if let lastMessageId = messages.last?.id {
             targetID = lastMessageId
         } else {
             targetID = nil
         }
         guard let finalID = targetID else { return }
         logger.trace("Scrolling to ID \(finalID)")
         if animated {
             withAnimation(.easeOut(duration: 0.2)) {
                 scrollProxy.scrollTo(finalID, anchor: .bottom)
             }
         } else {
             DispatchQueue.main.async {
                 scrollProxy.scrollTo(finalID, anchor: .bottom)
             }
         }
     }
}

// MARK: - Previews
struct MainApplicationView_ZStack_Previews: PreviewProvider {
    static var previews: some View {
        // Ensure the preview uses the updated ViewModel if necessary
        // For now, the basic init should work.
        MainApplicationView()
            .frame(width: 900, height: 600)
            .previewDisplayName("Main View with Header and Filter")
    }
}
