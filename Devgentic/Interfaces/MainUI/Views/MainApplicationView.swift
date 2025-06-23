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
    @EnvironmentObject private var viewModel: MainApplicationViewModel
    @EnvironmentObject private var ollamaProfileStore: OllamaProfileStore
    @Environment(\.openWindow) var openWindow
    @StateObject private var explorerViewModel = ExplorerViewModel() // This remains a @StateObject owned by MainApplicationView

    // --- View State ---
    @FocusState private var isInputFocused: Bool
    @State private var isSidebarVisible: Bool = true
    @State private var currentSidebarPaneWidth: CGFloat = 300
    
    private let activityBarWidth: CGFloat = 50
    private var totalSidebarWidth: CGFloat {
        activityBarWidth + (isSidebarVisible ? currentSidebarPaneWidth : 0)
    }

    // --- Constants for UI adjustments ---
    private let chatHistoryBottomPadding: CGFloat = 130
    private let inputAreaCornerRadius: CGFloat = 12
    
    private var isChatReady: Bool {
        ollamaProfileStore.currentProfile != nil
    }

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
                        if !isChatReady {
                            NoProfileConfiguredView(openWindow: openWindow)
                        } else if viewModel.selectedConversationID == nil {
                            // This part handles conversation selection prompts
                            Text(viewModel.conversations.isEmpty ? "Start a new conversation to begin." : "Select or start a conversation.")
                                .font(.title3)
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
                    .frame(maxWidth: 1050)
                    .shadow(color: SwiftUI.Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VisualEffectBlur(material: .windowBackground))
            }
            .padding(.leading, totalSidebarWidth)
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            .animation(.easeInOut(duration: 0.1), value: currentSidebarPaneWidth)
            
            VSCodifiedSidebarContainerView(
                isSidebarVisible: $isSidebarVisible,
                sidebarWidth: $currentSidebarPaneWidth
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
        // .environmentObject(viewModel) // This is not strictly needed here if viewModel is @EnvironmentObject and children access it the same way
        .environmentObject(explorerViewModel) // explorerViewModel is owned by this view, so it's passed to its children here
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

// MARK: - No Profile Configured View
struct NoProfileConfiguredView: View {
    var openWindow: OpenWindowAction

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 50))
                .foregroundColor(.secondary)

            Text("No Ollama Profile Configured")
                .font(.title2)
                .fontWeight(.bold)

            Text("You need to set up an Ollama profile before you can start chatting.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)
            
            Button("Configure Profiles...") {
                // This opens the dedicated window for managing Ollama profiles
                openWindow(id: "ollama-profiles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
    }
}


struct MainApplicationView_ZStack_Previews: PreviewProvider {
    static var previews: some View {
        // MODIFIED: Inject MainApplicationViewModel and ExplorerViewModel for the preview
        MainApplicationView()
            .environmentObject(MainApplicationViewModel())
            .environmentObject(ExplorerViewModel())
            .frame(width: 1000, height: 700)
            .previewDisplayName("Main View with Resizable Sidebar")
    }
}


