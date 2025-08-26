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
    @EnvironmentObject private var chatHistoryViewModel: ChatHistoryViewModel

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
            ChatGPTBackgroundView()
            
            ZStack {
                VStack(spacing: 0) {
//                    ChatHeaderView(
//                        chatTitle: viewModel.currentConversationTitle,
//                        isFilterActive: chatHistoryViewModel.isUserMessagesOnlyFilterActive,
//                        onEyeButtonTapped: {
//                            chatHistoryViewModel.toggleUserMessagesFilter()
//                            logger.info("Header eye button tapped. Filter active: \(chatHistoryViewModel.isUserMessagesOnlyFilterActive)")
//                        },
//                        onTransferButtonTapped: {
//                            viewModel.transferSelectedConversationToOverlay()
//                        },
//                        isConversationSelected: viewModel.selectedConversationID != nil
//                    )
                    
                    chatArea
                }
            }
            .padding(.leading, totalSidebarWidth)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            .animation(.easeInOut(duration: 0.1), value: currentSidebarPaneWidth)
            
            VSCodifiedSidebarContainerView(
                isSidebarVisible: $isSidebarVisible,
                sidebarWidth: $currentSidebarPaneWidth
            )
            .frame(width: totalSidebarWidth)
            .zIndex(1)

            if chatHistoryViewModel.codeViewerContent != nil {
                CodeViewerPanelView()
                    .environmentObject(chatHistoryViewModel)
                    .zIndex(2)
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
        .onChange(of: chatHistoryViewModel.isSending) { isNowSending in
            if !isNowSending && !viewModel.showSettings && viewModel.selectedConversationID != nil {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            }
        }
        .onChange(of: viewModel.selectedConversationID) { newID in
             if newID != nil {
                 if chatHistoryViewModel.isUserMessagesOnlyFilterActive {
                     chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
                     logger.info("Reset user messages filter due to conversation change.")
                 }
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
    
    // MARK: - Subviews

    @ViewBuilder
    private var chatArea: some View {
        ZStack(alignment: .bottom) {
            ChatHistoryView()
                .environmentObject(chatHistoryViewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 115)
                .overlay {
                    if viewModel.selectedConversationID == nil {
                        WelcomeView()
                    }
                }

            ChatInputAreaView(
                showContextArea: $viewModel.showContextArea,
                activeContextFilePath: $viewModel.activeContextFilePath,
                isSending: chatHistoryViewModel.isSending,
                showSettings: viewModel.showSettings,
                isInputFocused: $isInputFocused,
                backendConfiguration: viewModel.backendConfiguration,
                onSendMessage: viewModel.sendMessage,
                onToggleContext: {
                    withAnimation { viewModel.toggleContextArea() }
                }
            )
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 15)
            .shadow(color: SwiftUI.Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
        }
    }
}
