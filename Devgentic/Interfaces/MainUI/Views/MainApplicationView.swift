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
    @State private var isSidebarVisible: Bool = true // Default to true to show sidebar initially
    private let activityBarWidth: CGFloat = 50
    private let sideBarPaneIdealWidth: CGFloat = 280
    private var totalSidebarWidth: CGFloat { activityBarWidth + (isSidebarVisible ? sideBarPaneIdealWidth : 0) }


    // --- Constants for UI adjustments ---
    private let chatHistoryBottomPadding: CGFloat = 130
    private let inputAreaCornerRadius: CGFloat = 12

    // MARK: - Body
    var body: some View {
        ZStack(alignment: .leading) {

            // --- Main Content Area (Header, Chat History + Input) ---
            VStack(spacing: 0) {
                ChatHeaderView(
                    chatTitle: viewModel.currentConversationTitle,
                    isFilterActive: viewModel.isUserMessagesOnlyFilterActive,
                    onEyeButtonTapped: {
                        viewModel.toggleUserMessagesFilter()
                        logger.info("Header eye button tapped. Filter active: \(viewModel.isUserMessagesOnlyFilterActive)")
                    },
                    onTransferButtonTapped: {
                        viewModel.transferSelectedConversationToOverlay()
                    },
                    isConversationSelected: viewModel.selectedConversationID != nil
                )

                ZStack(alignment: .bottom) {
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
                                if !viewModel.showSettings && !viewModel.showPromptLibrary { // Ensure panels aren't open
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

                    VStack(spacing: 0) {
                        ChatInputAreaView(
                            userInput: $viewModel.userInput,
                            showContextArea: $viewModel.showContextArea,
                            activeContextFilePath: $viewModel.activeContextFilePath,
                            isSending: viewModel.isSending,
                            showSettings: viewModel.showSettings, // Pass this
                            isInputFocused: $isInputFocused,
                            onSendMessage: viewModel.sendMessage,
                            onToggleContext: {
                                withAnimation { viewModel.toggleContextArea() }
                            }
                        )
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .frame(maxWidth: 1050) // Max width for input area
                    .shadow(color: SwiftUI.Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VisualEffectBlur(material: .windowBackground))
            }
            // Adjust padding based on the actual width of the sidebar being displayed
            .padding(.leading, isSidebarVisible ? (activityBarWidth + sideBarPaneIdealWidth) : activityBarWidth)
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)


            // --- Layer 2: VS Code Style Sidebar ---
            VSCodifiedSidebarContainerView(isSidebarVisible: $isSidebarVisible)
                .environmentObject(viewModel)
                // The width of the container should be dynamic based on isSidebarVisible
                .frame(width: isSidebarVisible ? (activityBarWidth + sideBarPaneIdealWidth) : activityBarWidth)
                .zIndex(1) // Ensure sidebar is above main content if overlapping during animation, but below panels


            // --- Layer 3: Settings Panel Overlay ---
            if viewModel.showSettings {
                SettingsPanelView(
                    viewModel: viewModel,
                    showSettings: $viewModel.showSettings
                )
                .transition(.scale.combined(with: .opacity))
                .zIndex(2) // Settings panel on top
            }
            // --- End Settings Panel Overlay ---

            // MARK: - Layer 4: Prompt Library Panel Overlay (Added)
            if viewModel.showPromptLibrary {
                PromptLibraryPanelView(showPromptLibrary: $viewModel.showPromptLibrary)
                    .environmentObject(viewModel) // Pass MainApplicationViewModel
                    .transition(.scale.combined(with: .opacity)) // Similar transition
                    .zIndex(3) // Prompt Library on top of settings if both could be true (though logic prevents it)
            }
            // --- End Prompt Library Panel Overlay ---


            Button(action: {
                viewModel.startNewConversation()
                 logger.debug("Triggered new conversation via Cmd+N.")
                 if isSidebarVisible { // If sidebar pane is open, close it
                      isSidebarVisible = false
                      logger.debug("Hid sidebar pane via Cmd+N.")
                 }
            }) { EmptyView() }
                .hidden()
                .keyboardShortcut("n", modifiers: .command)

        }
        .opacity(viewModel.windowOpacity)
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
             if viewModel.selectedConversationID != nil && !viewModel.showSettings && !viewModel.showPromptLibrary {
                 DispatchQueue.main.async { isInputFocused = true }
             }
         }
        .onChange(of: viewModel.showSettings) { showingSettings in
            if !showingSettings && viewModel.selectedConversationID != nil && !viewModel.showPromptLibrary {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            } else if showingSettings {
                isInputFocused = false
            }
        }
        // MARK: - Added onChange for showPromptLibrary for focus management
        .onChange(of: viewModel.showPromptLibrary) { showingPromptLibrary in
            if !showingPromptLibrary && viewModel.selectedConversationID != nil && !viewModel.showSettings {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            } else if showingPromptLibrary {
                isInputFocused = false
            }
        }
        .onChange(of: viewModel.isSending) { isNowSending in
            if !isNowSending && !viewModel.showSettings && !viewModel.showPromptLibrary && viewModel.selectedConversationID != nil {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            }
        }
    }

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

struct MainApplicationView_ZStack_Previews: PreviewProvider {
    static var previews: some View {
        MainApplicationView()
            .frame(width: 900, height: 600)
            .previewDisplayName("Main View with Header and Filter")
    }
}
