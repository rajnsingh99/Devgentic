//
//  MainApplicationView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import AppKit
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainApplicationView")

// MARK: - Main View
struct MainApplicationView: View {
    @EnvironmentObject private var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    // --- View State ---
    @FocusState private var isInputFocused: Bool
    @State private var isSidebarVisible: Bool = true
    @State private var currentSidebarPaneWidth: CGFloat = 300
    
    private let activityBarWidth: CGFloat = 50
    private var totalSidebarWidth: CGFloat {
        activityBarWidth + (isSidebarVisible ? currentSidebarPaneWidth : 0)
    }

    private let inputAreaCornerRadius: CGFloat = 12
    
    // MARK: - Body
    var body: some View {
        ZStack(alignment: .leading) {
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
                
                // The main chat area, now simplified.
                chatArea
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
        .onChange(of: viewModel.selectedConversationID) { newID in
             if newID != nil {
                 if viewModel.isUserMessagesOnlyFilterActive {
                     viewModel.isUserMessagesOnlyFilterActive = false
                     logger.info("Reset user messages filter due to conversation change.")
                 }
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
    
    // MARK: - Subviews

    @ViewBuilder
    private var chatArea: some View {
        VStack(spacing: 0) {
            // FIX: ChatHistoryView is now self-contained and gets its data
            // from the environment object. No parameters are needed.
            // The scrolling logic is also handled inside ChatHistoryView.
            ChatHistoryView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if viewModel.selectedConversationID == nil {
                        Text(viewModel.conversations.isEmpty ? "Start a new conversation to begin." : "Select or start a conversation.")
                            .font(.title3)
                            .foregroundColor(.gray.opacity(0.7))
                    }
                }

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
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: 1050)
            .shadow(color: SwiftUI.Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBlur(material: .windowBackground))
    }
}

struct MainApplicationView_ZStack_Previews: PreviewProvider {
    static var previews: some View {
        let mockMainViewModel = MainApplicationViewModel()
        
        MainApplicationView()
            .environmentObject(mockMainViewModel)
            .environmentObject(mockMainViewModel.explorerViewModel)
            .frame(width: 1000, height: 700)
            .previewDisplayName("Main View with Resizable Sidebar")
    }
}
