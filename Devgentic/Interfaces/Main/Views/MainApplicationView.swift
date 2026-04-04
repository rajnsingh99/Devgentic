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
    @Environment(MainApplicationViewModel.self) private var viewModel
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(MainViewRouter.self) private var router
    @Environment(\.appTheme) private var theme

    @FocusState private var isInputFocused: Bool
    
    @State private var isSidebarVisible: Bool = true
    @State private var currentSidebarPaneWidth: CGFloat = 300

    private let activityBarWidth: CGFloat = 50
    private let sidebarGap: CGFloat = 12
    private var totalSidebarWidth: CGFloat {
        (isSidebarVisible ? currentSidebarPaneWidth : 0) + activityBarWidth + (sidebarGap * 1.5)
    }

    private let inputAreaCornerRadius: CGFloat = 12
    
    // MARK: - Body
    var body: some View {
        ZStack(alignment: .leading) {
            ChatGPTBackgroundView()
            
            ZStack {
                // LAYER 1: Chat — always alive, visibility toggled via opacity
                chatArea
                    .opacity(router.isShowingChat ? 1 : 0)
                    .allowsHitTesting(router.isShowingChat)

                // LAYER 2: Non-chat destinations — created on demand
                if !router.isShowingChat {
                    destinationView
                        .transition(.opacity)
                }
            }
            .padding(.leading, totalSidebarWidth)
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            .animation(.easeInOut(duration: 0.1), value: currentSidebarPaneWidth)
            .animation(.easeInOut(duration: 0.2), value: router.activeDestination)
            
            VSCodifiedSidebarContainerView(
                isSidebarVisible: $isSidebarVisible,
                sidebarWidth: $currentSidebarPaneWidth
            )
            .frame(width: totalSidebarWidth)
            .zIndex(1)

            if chatHistoryViewModel.codeViewerContent != nil {
                CodeViewerPanelView()
                    .environment(chatHistoryViewModel)
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
        .preferredColorScheme(theme.id == "one_light" ? .light : (theme.id == "dracula" ? .dark : nil))
        .onAppear {
             if viewModel.selectedConversationID != nil && router.isShowingChat {
                 DispatchQueue.main.async { isInputFocused = true }
             }
         }
        .onChange(of: router.activeDestination) { newDestination in
            if newDestination == .chat && viewModel.selectedConversationID != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            } else if newDestination != .chat {
                isInputFocused = false
            }
        }
        .onChange(of: chatHistoryViewModel.isSending) { isNowSending in
            if !isNowSending && router.isShowingChat && viewModel.selectedConversationID != nil {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            }
        }
        .onChange(of: viewModel.selectedConversationID) { newID in
            if newID != nil {
                if chatHistoryViewModel.isUserMessagesOnlyFilterActive {
                    chatHistoryViewModel.isUserMessagesOnlyFilterActive = false
                    logger.info("Reset user messages filter due to conversation change.")
                }
                if router.isShowingChat {
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
    private var destinationView: some View {
        switch router.activeDestination {
        case .chat:
            EmptyView()
        case .profileDetail(let profileID):
            ProfileDetailContainerView(profileID: profileID)
        case .settingsDetail(let category):
            SettingsDetailContainerView(category: category)
        case .toolLibrary(let profileID):
            ToolLibraryContainerView(profileID: profileID)
        case .promptDetail(let promptID):
            PromptDetailContainerView(promptID: promptID)
        case .scheduledTaskDetail(let taskID):
            ScheduledTaskDetailContainerView(taskID: taskID)
        case .ollamaModelStore:
            OllamaModelStoreContainerView()
        case .mlxModelStore(_, let filterForTools):
            MLXModelStoreContainerView(filterForTools: filterForTools)
        case .downloadManager:
            DownloadManagerContainerView()
        case .userPersonalProfile:
            UserPersonalContainerView()
        }
    }

    @ViewBuilder
    private var chatArea: some View {
        ZStack(alignment: .bottom) {
            ChatHistoryView()
                .environment(chatHistoryViewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 115)
                .overlay {
                    if viewModel.selectedConversationID == nil {
                        WelcomeView()
                    }
                }

            VStack(spacing: 0) {
                // Wrapper observes the ChatMessage directly so banner reacts
                // to pendingClarification/pendingToolConfirmation changes.
                if let streamingMsg = viewModel.streamingMessage {
                    StreamingMessageBannerWrapper(message: streamingMsg)
                        .environment(viewModel)
                }

                ChatInputAreaView(
                    showContextArea: Bindable(viewModel).showContextArea,
                    activeContextFilePath: Bindable(viewModel).activeContextFilePath,
                    isSending: chatHistoryViewModel.isSending,
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
}

// MARK: - Streaming Message Banner Wrapper
/// Wrapper that observes the unified `pendingInteraction` property on ChatMessage
/// to show the sticky HITL banner above the chat input.
private struct StreamingMessageBannerWrapper: View {
    var message: ChatMessage
    @Environment(MainApplicationViewModel.self) var viewModel

    var body: some View {
        Group {
            if message.pendingInteraction != nil {
                AgentInterruptBannerView(message: message)
                    .environment(viewModel)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: message.pendingInteraction != nil)
    }
}
