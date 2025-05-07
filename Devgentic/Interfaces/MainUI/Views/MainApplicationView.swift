//  /Users/alice/Documents/Workspace/mac-projects/Devgentic/Devgentic/MainApplicationView.swift
//
//  ContentView.swift (Adapted for MainApplicationView)
//  AgenticDev
//
//  Created by Raj Singh on 19/04/25.
//

import SwiftUI
import AppKit
import os

// Logger
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainApplicationView")

// Assume VSCodifiedSidebarContainerView and its dependencies are defined correctly elsewhere

// MARK: - Main View (Refactored with ZStack Layout for Chat Area)
struct MainApplicationView: View {
    // --- ViewModel ---
    @StateObject private var viewModel = MainApplicationViewModel()

    // --- View State ---
    @FocusState private var isInputFocused: Bool
    @State private var isSidebarVisible: Bool = true
    private let activityBarWidth: CGFloat = 50
    private let sideBarPaneIdealWidth: CGFloat = 280
    private var totalSidebarWidth: CGFloat {
        activityBarWidth + sideBarPaneIdealWidth
    }

    // --- Constants for UI adjustments ---
    // Estimate the typical height of the ChatInputAreaView to use for bottom padding
    private let chatHistoryBottomPadding: CGFloat = 130 // Adjusted for potentially taller input area
    // Corner radius for the floating input area's background
    private let inputAreaCornerRadius: CGFloat = 12 // Should match ChatInputAreaView's internal cornerRadiusValue

    // MARK: - Body
    var body: some View {
        // --- ZStack for Layering Sidebar and Content ---
        ZStack(alignment: .leading) {

            // --- Layer 1: Main Interaction Area (Chat Content and Floating Input) ---
            ZStack(alignment: .bottom) {
                
                // --- Chat Message Area ---
                ScrollViewReader { scrollProxy in
                    ChatHistoryView(
                        messages: viewModel.currentChatMessages,
                        isSending: viewModel.isSending,
                        hasSelectedConversation: viewModel.selectedConversationID != nil,
                        // Pass the bottom padding value to ChatHistoryView
                        chatHistoryBottomPadding: chatHistoryBottomPadding
                    )
                    // REMOVED: .padding(.bottom, chatHistoryBottomPadding) from here
                    .frame(maxWidth: .infinity)
                    .onChange(of: viewModel.currentChatMessages) { newMessages in
                        if viewModel.selectedConversationID != nil {
                            scrollToBottom(scrollProxy: scrollProxy, messages: newMessages, isSending: viewModel.isSending)
                        }
                    }
                    .onChange(of: viewModel.isSending) { isNowSending in
                         if viewModel.selectedConversationID != nil {
                             scrollToBottom(scrollProxy: scrollProxy, messages: viewModel.currentChatMessages, isSending: isNowSending)
                         }
                    }
                    .onChange(of: viewModel.selectedConversationID) { newID in
                        if newID != nil {
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
                    if viewModel.selectedConversationID == nil {
                        Text("Select a conversation or start a new one.")
                            .foregroundColor(.gray)
                    }
                }
                // --- End Chat Message Area ---

                // --- Floating Input Area Wrapper ---
                VStack(spacing: 0) {
                    ChatInputAreaView( // ChatInputAreaView will no longer have its own outer padding
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
                .padding(.horizontal) // Apply horizontal padding to the wrapper
                .padding(.bottom, 8)   // Apply bottom padding to the wrapper
                .background(
                    VisualEffectBlur(material: .hudWindow)
                        .opacity(0.9) // Slightly increased opacity for better separation
                        .cornerRadius(inputAreaCornerRadius) // Apply corner radius to the blur background
                )
                .frame(maxWidth: 1050) // Maintain the max width for the input area content
                // --- End Floating Input Area Wrapper ---

            } // End Main Interaction ZStack (ChatHistory + Input)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VisualEffectBlur(material: .windowBackground))
            .padding(.leading, isSidebarVisible ? totalSidebarWidth : activityBarWidth)
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            // --- End Main Interaction Area ---


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
        .onChange(of: viewModel.isSending) { isNowSending in
            if !isNowSending && !viewModel.showSettings && viewModel.selectedConversationID != nil {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            }
        }
    }

    // MARK: - Helper Functions (View-Specific)
    private func scrollToBottom(scrollProxy: ScrollViewProxy, messages: [ChatMessage], isSending: Bool, animated: Bool = true) {
         let targetID: AnyHashable?

         if isSending {
             targetID = "thinkingIndicator"
         } else if let lastMessageId = messages.last?.id {
             targetID = lastMessageId
         } else {
             targetID = nil
         }

         guard let finalID = targetID else {
             logger.debug("scrollToBottom called but no target message or indicator found.")
             return
         }

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
        MainApplicationView()
            .frame(width: 900, height: 600)
            .previewDisplayName("ZStack Layout with Floating Input")
    }
}
