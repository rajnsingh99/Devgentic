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
// Assume ChatHeaderView definition is updated elsewhere to remove the settings button and closure.

// MARK: - Main View (Refactored with ZStack Layout)
struct MainApplicationView: View {
    // --- ViewModel ---
    @StateObject private var viewModel = MainApplicationViewModel()

    // --- View State ---
    @FocusState private var isInputFocused: Bool
    // State to control sidebar visibility, passed as binding to the container
    @State private var isSidebarVisible: Bool = true
    // Define sidebar width constants for padding calculation
    private let activityBarWidth: CGFloat = 50
    private let sideBarPaneIdealWidth: CGFloat = 280 // Use ideal width for padding calculation
    private var totalSidebarWidth: CGFloat {
        activityBarWidth + sideBarPaneIdealWidth
    }


    // MARK: - Body
    var body: some View {
        // --- ZStack for Layering Sidebar and Content ---
        ZStack(alignment: .leading) { // Align content to the leading edge

            // --- Layer 1: Main Interaction Area (Chat Content) ---
            VStack(alignment: .leading, spacing: 0) {
                
                // --- Chat Message Area ---
                ScrollViewReader { scrollProxy in
                    ChatHistoryView(
                        messages: viewModel.currentChatMessages,
                        isSending: viewModel.isSending,
                        hasSelectedConversation: viewModel.selectedConversationID != nil
                    )
                    // --- Scrolling Logic (Remains the same) ---
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
                            isInputFocused = false // Defocus if no chat selected
                        }
                    }
                    // --- End Scrolling Logic ---
                }
                .padding(.bottom, 5)
                .frame(maxHeight: .infinity, alignment: .top)
                .overlay {
                    if viewModel.selectedConversationID == nil { // Show placeholder when no chat selected
                        Text("Select a conversation or start a new one.")
                            .foregroundColor(.gray)
                    }
                }
                // --- End Chat Message Area ---


                // --- Input Area ---
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
                // --- End Input Area ---

                // Hidden Button for Keyboard Shortcut (Cmd+N) - Remains the same
                Button(action: {
                    // Action for Cmd+N should now match the New Chat button behavior
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

            } // End Main Interaction VStack
            .background(VisualEffectBlur(material: .windowBackground)) // Apply background blur
            // *** ADD CONDITIONAL PADDING ***
            .padding(.leading, isSidebarVisible ? totalSidebarWidth : activityBarWidth) // Use activityBarWidth padding when hidden
            // Animate the padding change along with the sidebar animation
            .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
            // --- End Main Interaction Area ---


            // --- Layer 2: VS Code Style Sidebar ---
            VSCodifiedSidebarContainerView(isSidebarVisible: $isSidebarVisible)
                .environmentObject(viewModel)
                .frame(width: isSidebarVisible ? totalSidebarWidth : activityBarWidth) // Adjust frame width
                .zIndex(1) // Ensure sidebar is visually on top
            // --- End Sidebar ---


            // --- Layer 3: Settings Panel Overlay ---
            if viewModel.showSettings {
                SettingsPanelView(
                    viewModel: viewModel,
                    showSettings: $viewModel.showSettings
                )
                .transition(.scale.combined(with: .opacity))
                .zIndex(2) // Ensure settings are on top of sidebar and chat
            }
            // --- End Settings Panel Overlay ---

        } // End ZStack
        .opacity(viewModel.windowOpacity) // Apply overall window opacity
        .frame(minWidth: 800, minHeight: 500) // Keep overall window size constraints
        // --- Focus Management Logic (Adjustments might be needed based on testing) ---
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

    // Scroll helper function remains unchanged
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
struct MainApplicationView_ZStack_Previews: PreviewProvider { // Renamed preview struct
    static var previews: some View {
        MainApplicationView()
            .frame(width: 900, height: 600) // Adjusted width for new sidebar
            .previewDisplayName("ZStack Layout")
    }
}

// Assume ChatHeaderView definition is updated elsewhere to remove the settings button and closure.
