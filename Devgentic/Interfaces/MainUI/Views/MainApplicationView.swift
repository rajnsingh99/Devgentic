//  /Users/alice/Documents/Workspace/mac-projects/Devgentic/Devgentic/MainApplicationView.swift
//
//  ContentView.swift (Adapted for MainApplicationView)
//  AgenticDev
//
//  Created by Raj Singh on 19/04/25.
//

import SwiftUI
import AppKit
import os // Import os for logging

// Logger for better debugging
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "MainApplicationView")

// MARK: - Models & Enums (Assumed to be in separate files now)
// BackendType enum is now defined in Models/BackendType.swift
// Conversation struct is now defined in Models/Conversation.swift
// ChatMessage struct is now defined in Models/ChatMessage.swift   // ADDED ASSUMPTION
// MessageContent enum is now defined in Models/MessageContent.swift // ADDED ASSUMPTION
// SenderRole enum is now defined in Models/SenderRole.swift     // ADDED ASSUMPTION
// VisualEffectBlur struct is now defined in Views/Shared/VisualEffectBlur.swift
// SettingsSection enum is now defined in Models/SettingsSection.swift
// SettingsKeys struct is now defined in Models/SettingsKeys.swift
// ConversationListView is defined in Views/MainApplication/ConversationListView.swift
// ChatHeaderView is defined in Views/MainApplication/ChatHeaderView.swift
// ChatHistoryView is defined in Views/MainApplication/ChatHistoryView.swift
// ChatInputAreaView is defined in Views/MainApplication/ChatInputAreaView.swift
// SettingsPanelView is defined in Views/Settings/SettingsPanelView.swift

// MARK: - Previews (Optional)
struct FloatingWindowView_Previews: PreviewProvider {
    static var previews: some View {
        // Previews now use the ViewModel's default state or can be configured
        // by creating specific ViewModel instances if needed for complex scenarios.
        MainApplicationView()
            .frame(width: 800, height: 600)
            .previewDisplayName("Default State")

        // Example showing settings panel initially (requires ViewModel modification or separate preview setup)
        // You could create a ViewModel instance specifically for the preview:
        // static var settingsOpenViewModel: MainApplicationViewModel {
        //     let vm = MainApplicationViewModel()
        //     vm.showSettings = true
        //     return vm
        // }
        // MainApplicationView(viewModel: settingsOpenViewModel)
        //    .frame(width: 800, height: 600)
        //    .previewDisplayName("Settings Open")
    }
}


// MARK: - Main View (Refactored with ViewModel)
struct MainApplicationView: View {
    // --- ViewModel ---
    // The single source of truth for state and logic
    @StateObject private var viewModel = MainApplicationViewModel()

    // --- Focus State (Remains in the View) ---
    @FocusState private var isInputFocused: Bool

    // --- Initializer (Optional, for injecting ViewModel in previews/tests) ---
    // init(viewModel: MainApplicationViewModel = MainApplicationViewModel()) {
    //     _viewModel = StateObject(wrappedValue: viewModel)
    // }

    // MARK: - Body
    var body: some View {
        // --- ZStack for Overlay ---
        ZStack {
            // --- Main Content HStack (Chat UI) ---
            HStack(spacing: 0) {
                // --- Left Sidebar (Conversations) ---
                // Logic remains the same, ConversationListView uses the ViewModel
                if !viewModel.isSidebarCollapsed {
                    ConversationListView(onNewConversation: viewModel.startNewConversation)
                                        // Ensure the viewModel is available to ConversationListView and its children
                    .environmentObject(viewModel)
                    .transition(.move(edge: .leading))
                }
                // --- End Left Sidebar ---

                // --- Divider ---
                if !viewModel.isSidebarCollapsed {
                     Divider().background(Color.white.opacity(0.2)) // Style divider
                }
                // ------------------------------------------------------

                // --- Main Interaction Area (Right Side) ---
                VStack(alignment: .leading, spacing: 0) {
                    // --- Header ---
                    // Logic remains the same, ChatHeaderView uses the ViewModel
                    ChatHeaderView(
                        isSidebarCollapsed: $viewModel.isSidebarCollapsed,
                        currentConversationTitle: viewModel.currentConversationTitle,
                        onToggleSidebar: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.toggleSidebar()
                            }
                        },
                        onShowSettings: {
                            withAnimation {
                                viewModel.toggleSettings()
                            }
                        }
                    )

                    // --- Chat Message Area ---
                    ScrollViewReader { scrollProxy in
                        // --- UPDATED ---
                        // Pass the [ChatMessage] array from the ViewModel
                        ChatHistoryView(
                            messages: viewModel.currentChatMessages, // USE NEW PROPERTY
                            isSending: viewModel.isSending,
                            hasSelectedConversation: viewModel.selectedConversationID != nil
                        )
                        // ---------------
                        // --- Scrolling Logic (Updated to use ChatMessage array and IDs) ---
                        .onChange(of: viewModel.currentChatMessages) { newMessages in // Observe the correct property
                            // Scroll when messages array changes
                            if viewModel.selectedConversationID != nil {
                                // Pass the new array to the updated helper
                                scrollToBottom(scrollProxy: scrollProxy, messages: newMessages, isSending: viewModel.isSending)
                            }
                        }
                        .onChange(of: viewModel.isSending) { isNowSending in
                             // Scroll when sending state changes
                             if viewModel.selectedConversationID != nil {
                                 // Pass the *current* message array state to the updated helper
                                 scrollToBottom(scrollProxy: scrollProxy, messages: viewModel.currentChatMessages, isSending: isNowSending)
                             }
                        }
                        .onChange(of: viewModel.selectedConversationID) { newID in
                            // Scroll when conversation changes, manage focus
                            if newID != nil {
                                // Scroll immediately without animation
                                // Pass the *current* message array state to the updated helper
                                scrollToBottom(scrollProxy: scrollProxy, messages: viewModel.currentChatMessages, isSending: viewModel.isSending, animated: false)
                                // Focus logic remains the same
                                if !viewModel.showSettings {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        isInputFocused = true
                                    }
                                }
                            } else {
                                isInputFocused = false
                            }
                        }
                        // --- End Scrolling Logic ---
                    }
                    .padding(.bottom, 5) // Space above input area
                    .frame(maxHeight: .infinity, alignment: .top)
                    .overlay { // Placeholder logic remains the same
                        if viewModel.selectedConversationID == nil && viewModel.conversations.isEmpty {
                            Text("Type a message or press ⌘N to start a new chat.")
                                .foregroundColor(.gray)
                        }
                    }
                    // --- End Chat Message Area ---


                    // --- Input Area ---
                    // Logic remains the same, ChatInputAreaView uses the ViewModel
                    ChatInputAreaView(
                        userInput: $viewModel.userInput,
                        showContextArea: $viewModel.showContextArea,
                        activeContextFilePath: $viewModel.activeContextFilePath,
                        isSending: viewModel.isSending,
                        showSettings: viewModel.showSettings,
                        isInputFocused: $isInputFocused,
                        onSendMessage: viewModel.sendMessage,
                        onToggleContext: {
                            withAnimation {
                                viewModel.toggleContextArea()
                            }
                        }
                    )
                    // --- End Input Area ---

                    // Hidden Button for Keyboard Shortcut (Cmd+N) - Remains the same
                    Button(action: viewModel.startNewConversation) { EmptyView() }
                        .hidden()
                        .keyboardShortcut("n", modifiers: .command)

                } // End Main Interaction VStack
                .background(VisualEffectBlur(material: .windowBackground)) // Use the extracted blur view
                // --- End Main Interaction Area ---
            } // End Main Content HStack
            .allowsHitTesting(!viewModel.showSettings) // Logic remains the same

            // --- Settings Panel Overlay ---
            // Logic remains the same, SettingsPanelView uses the ViewModel
            if viewModel.showSettings {
                SettingsPanelView(
                    viewModel: viewModel, // Pass the ViewModel instance
                    showSettings: $viewModel.showSettings
                )
                .transition(.scale.combined(with: .opacity))
            }
            // --- End Settings Panel Overlay ---

        } // End ZStack
        .opacity(viewModel.windowOpacity) // Logic remains the same
        .frame(minWidth: 800, minHeight: 500) // Keep overall window size constraints
        // --- Focus Management Logic (Remains the same) ---
        .onAppear {
             if viewModel.conversations.isEmpty && !viewModel.showSettings {
                 DispatchQueue.main.async { isInputFocused = true }
             } else if viewModel.selectedConversationID != nil && !viewModel.showSettings {
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
        .onChange(of: viewModel.isSending) { isNowSending in // Ensure this doesn't conflict unduly with scrolling's onChange
            if !isNowSending && !viewModel.showSettings && viewModel.selectedConversationID != nil {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isInputFocused = true }
            }
        }
        // --- End Focus Management ---
    }

    // MARK: - Helper Functions (View-Specific)

    // --- UPDATED ---
    // Scroll helper updated to accept [ChatMessage] and use message IDs
    private func scrollToBottom(scrollProxy: ScrollViewProxy, messages: [ChatMessage], isSending: Bool, animated: Bool = true) {
         let targetID: AnyHashable? // Use optional target ID

         if isSending {
             targetID = "thinkingIndicator" // Target the explicit ID for the indicator
         } else if let lastMessageId = messages.last?.id { // Target the ID of the last ChatMessage
             targetID = lastMessageId
         } else {
             targetID = nil // Nothing to scroll to if not sending and no messages
         }

         // Ensure we have a valid ID before attempting to scroll
         guard let finalID = targetID else {
             logger.debug("scrollToBottom called but no target message or indicator found.")
             return
         }

         logger.trace("Scrolling to ID \(finalID)")
         if animated {
             // Perform scrolling with animation
             withAnimation(.easeOut(duration: 0.2)) {
                 scrollProxy.scrollTo(finalID, anchor: .bottom)
             }
         } else {
             // Perform scrolling without animation, using DispatchQueue for timing
             DispatchQueue.main.async {
                 scrollProxy.scrollTo(finalID, anchor: .bottom)
             }
         }
     }
     // ---------------
}
