// MainApplicationView.swift
//
//  Devgentic
//
//  Created by Raj Singh on 15/04/25.
//

import SwiftUI
import AppKit
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainApplicationView")

// MARK: - Main View
struct MainApplicationView: View {
    // --- ViewModel ---
    @StateObject private var viewModel = MainApplicationViewModel()
    @StateObject private var explorerViewModel = ExplorerViewModel()

    // --- View State ---
    @FocusState private var isInputFocused: Bool
    @State private var isSidebarVisible: Bool = true
    @State private var currentSidebarPaneWidth: CGFloat = 280
    
    private let activityBarWidth: CGFloat = 50
    private var totalSidebarWidth: CGFloat {
        activityBarWidth + (isSidebarVisible ? currentSidebarPaneWidth : 0)
    }

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
                                if !viewModel.showSettings && !viewModel.showPromptLibrary {
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
                    .frame(maxWidth: 1050) // Consider if this maxWidth needs to be dynamic
                    .shadow(color: SwiftUI.Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VisualEffectBlur(material: .windowBackground))
            }
            // ** UPDATED PADDING: Use the dynamic totalSidebarWidth **
            .padding(.leading, totalSidebarWidth)
            // Animate the padding change when sidebar visibility or width changes
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            .animation(.easeInOut(duration: 0.1), value: currentSidebarPaneWidth)
            
            VSCodifiedSidebarContainerView(
                isSidebarVisible: $isSidebarVisible,
                sidebarWidth: $currentSidebarPaneWidth // This line is crucial
            )
                .frame(width: totalSidebarWidth)
                .zIndex(1)

            if viewModel.showPromptLibrary {
                PromptLibraryPanelView(showPromptLibrary: $viewModel.showPromptLibrary)
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(3)
            }

            Button(action: {
                viewModel.startNewConversation()
                 logger.debug("Triggered new conversation via Cmd+N.")
                 if isSidebarVisible {
                      isSidebarVisible = false
                      logger.debug("Hid sidebar pane via Cmd+N.")
                 }
            }) { EmptyView() }
                .hidden()
                .keyboardShortcut("n", modifiers: .command)
        }
        .environmentObject(viewModel)
        .environmentObject(explorerViewModel)
        .opacity(viewModel.windowOpacity)
        .frame(minWidth: 800, minHeight: 500) // Adjust minWidth if needed due to resizable sidebar
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
        // ** IMPORTANT: Listen for width changes from VSCodifiedSidebarContainerView **
        // This requires VSCodifiedSidebarContainerView to publish its width.
        // One way is using a custom PreferenceKey.
        // For this example, we'll assume `VSCodifiedSidebarContainerView`'s `sidebarWidth` @State
        // is the source of truth and `MainApplicationView` needs to react.
        // A more robust solution involves a shared binding or a PreferenceKey pattern.
        // If VSCodifiedSidebarContainerView had:
        // @Binding var externalSidebarWidth: CGFloat
        // Then MainApplicationView would pass $currentSidebarPaneWidth.
        // And VSCodifiedSidebarContainerView would update this binding.
        //
        // For now, the currentSidebarPaneWidth in MainApplicationView is illustrative
        // of how the main content padding would react. True synchronization needs a bit more wiring.
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
         logger.trace("Scrolling to ID \(String(describing: finalID))")
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
            .frame(width: 1000, height: 700) // Adjusted for potentially wider sidebar
            .previewDisplayName("Main View with Resizable Sidebar")
    }
}
