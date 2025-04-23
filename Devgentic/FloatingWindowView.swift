//  /Users/alice/Documents/Workspace/mac-projects/Devgentic/Devgentic/FloatingWindowView.swift
//
//  ContentView.swift (Adapted for FloatingWindowView)
//  AgenticDev
//
//  Created by Raj Singh on 19/04/25.
//

import SwiftUI
import AppKit
import os // Import os for logging

// Logger for better debugging
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "FloatingWindowView")

// MARK: - Models & Enums (Assumed to be in separate files now)
// BackendType enum is now defined in Models/BackendType.swift
// Conversation struct is now defined in Models/Conversation.swift
// VisualEffectBlur struct is now defined in Views/VisualEffectBlur.swift
// SettingsSection enum is now defined in Models/SettingsSection.swift
// SettingsKeys struct is now defined in Models/SettingsKeys.swift

// MARK: - Previews (Optional)
struct FloatingWindowView_Previews: PreviewProvider {
    static var previews: some View {
        // Previews now use the ViewModel's default state or can be configured
        // by creating specific ViewModel instances if needed for complex scenarios.
        FloatingWindowView()
            .frame(width: 800, height: 600)
            .previewDisplayName("Default State")

        // Example showing settings panel initially (requires ViewModel modification or separate preview setup)
        // You could create a ViewModel instance specifically for the preview:
        // static var settingsOpenViewModel: FloatingWindowViewModel {
        //     let vm = FloatingWindowViewModel()
        //     vm.showSettings = true
        //     return vm
        // }
        // FloatingWindowView(viewModel: settingsOpenViewModel)
        //    .frame(width: 800, height: 600)
        //    .previewDisplayName("Settings Open")
    }
}


// MARK: - Main View (Refactored with ViewModel)
struct FloatingWindowView: View {
    // --- ViewModel ---
    // The single source of truth for state and logic
    // Use @StateObject to ensure the ViewModel lifecycle is tied to the View
    @StateObject private var viewModel = FloatingWindowViewModel()

    // --- Focus State (Remains in the View) ---
    @FocusState private var isInputFocused: Bool

    // --- Initializer (Optional, for injecting ViewModel in previews/tests) ---
    // Use this if you need to provide a specific ViewModel instance, e.g., for previews
    // init(viewModel: FloatingWindowViewModel = FloatingWindowViewModel()) {
    //     _viewModel = StateObject(wrappedValue: viewModel)
    // }

    // MARK: - Body
    var body: some View {
        // --- ZStack for Overlay ---
        ZStack {
            // --- Main Content HStack (Chat UI) ---
            HStack(spacing: 0) {
                // --- Left Sidebar (Conversations) ---
                if !viewModel.isSidebarCollapsed {
                    // Use the extracted ConversationListView, passing data/bindings from ViewModel
                    ConversationListView(
                        groupedConversations: viewModel.groupedConversations, // Read from ViewModel
                        sortedGroupKeys: viewModel.sortedGroupKeys,         // Read from ViewModel
                        selectedConversationID: $viewModel.selectedConversationID, // Bind to ViewModel
                        onNewConversation: viewModel.startNewConversation       // Pass ViewModel action
                    )
                    // Add transition if desired
                    .transition(.move(edge: .leading))
                }
                // --- End Left Sidebar ---

                // --- Divider ---
                if !viewModel.isSidebarCollapsed {
                     Divider().background(Color.white.opacity(0.2)) // Style divider
                }
                // ------------------------------------------------------

                // --- Main Interaction Area (Right Side) ---
                VStack(alignment: .leading, spacing: 0) { //  *** CORRECT ORDER HERE ***
                    // --- Header ---
                    // Use the extracted ChatHeaderView, passing data/bindings from ViewModel
                    ChatHeaderView(
                        isSidebarCollapsed: $viewModel.isSidebarCollapsed, // Binding for the button state
                        currentConversationTitle: viewModel.currentConversationTitle, // Read from ViewModel
                        onToggleSidebar: { // Provide closure for action, apply animation here
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.toggleSidebar() // Call ViewModel action
                            }
                        },
                        onShowSettings: { // Provide closure for action, apply animation here
                            withAnimation {
                                viewModel.toggleSettings() // Call ViewModel action
                            }
                        }
                    )

                    // --- Chat Message Area ---
                    // Always include the ScrollViewReader structure
                    ScrollViewReader { scrollProxy in
                        ChatHistoryView(
                            history: viewModel.currentChatHistory, // Read from ViewModel
                            isSending: viewModel.isSending,       // Read from ViewModel
                            hasSelectedConversation: viewModel.selectedConversationID != nil // Derived from ViewModel
                        )
                        // --- Scrolling Logic (Remains in View, observes ViewModel) ---
                        .onChange(of: viewModel.currentChatHistory) { _ in
                            // Scroll when history changes (new message added)
                            if viewModel.selectedConversationID != nil {
                                scrollToBottom(scrollProxy: scrollProxy, history: viewModel.currentChatHistory, isSending: viewModel.isSending)
                            }
                        }
                        .onChange(of: viewModel.isSending) { isNowSending in
                             // Scroll when sending stops (agent response received)
                             if viewModel.selectedConversationID != nil && !isNowSending {
                                 scrollToBottom(scrollProxy: scrollProxy, history: viewModel.currentChatHistory, isSending: false)
                             }
                             // Optionally scroll when sending starts if needed (e.g., if thinking indicator is far)
                             // else if viewModel.selectedConversationID != nil && isNowSending {
                             //    scrollToBottom(scrollProxy: scrollProxy, history: viewModel.currentChatHistory, isSending: true)
                             // }
                        }
                        .onChange(of: viewModel.selectedConversationID) { newID in
                            // Scroll when conversation changes, manage focus
                            if newID != nil {
                                // Scroll immediately without animation when switching conversations
                                scrollToBottom(scrollProxy: scrollProxy, history: viewModel.currentChatHistory, isSending: viewModel.isSending, animated: false)
                                // Focus input if settings aren't shown
                                if !viewModel.showSettings {
                                    // Delay slightly to ensure UI updates before focusing
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        isInputFocused = true
                                    }
                                }
                            } else {
                                // If selection is cleared, potentially unfocus
                                isInputFocused = false
                            }
                        }
                        // --- End Scrolling Logic ---
                    }
                    .padding(.bottom, 5) // Space above input area
                    .frame(maxHeight: .infinity, alignment: .top)  //  *** ADD ALIGNMENT HERE ***
                    .overlay { // Apply the overlay for placeholder
                        // Conditionally show the placeholder text based on ViewModel state
                        if viewModel.selectedConversationID == nil && viewModel.conversations.isEmpty {
                            Text("Type a message or press ⌘N to start a new chat.")
                                .foregroundColor(.gray)
                        }
                    }
                    // --- End Chat Message Area ---


                    // --- Input Area ---
                    // Use the extracted ChatInputAreaView, passing data/bindings from ViewModel
                    ChatInputAreaView(
                        userInput: $viewModel.userInput,                  // Bind to ViewModel
                        showContextArea: $viewModel.showContextArea,      // Bind to ViewModel
                        activeContextFilePath: $viewModel.activeContextFilePath, // Bind to ViewModel
                        isSending: viewModel.isSending,                   // Read from ViewModel
                        showSettings: viewModel.showSettings,             // Read from ViewModel
                        isInputFocused: $isInputFocused,                  // Pass FocusState binding
                        onSendMessage: viewModel.sendMessage,             // Pass ViewModel action
                        onToggleContext: { // Apply animation here
                            withAnimation {
                                viewModel.toggleContextArea() // Call ViewModel action
                            }
                        }
                    )
                    // --- End Input Area ---

                    // Hidden Button for Keyboard Shortcut (Cmd+N)
                    Button(action: viewModel.startNewConversation) { EmptyView() }
                        .hidden()
                        .keyboardShortcut("n", modifiers: .command)

                } // End Main Interaction VStack
                .background(VisualEffectBlur()) // Use the extracted blur view
                // --- End Main Interaction Area ---
            } // End Main Content HStack
            .allowsHitTesting(!viewModel.showSettings) // Disable interaction based on ViewModel state

            // --- Settings Panel Overlay ---
            if viewModel.showSettings {
                // Use the extracted SettingsPanelView, passing bindings to ViewModel properties
                SettingsPanelView(
                    showSettings: $viewModel.showSettings, // Binding to allow dismissal from panel
                    selectedSettingsSection: $viewModel.selectedSettingsSection, // Bind section
                    // Pass bindings for settings managed by the ViewModel
                    windowOpacity: $viewModel.windowOpacity,
                    llmModelName: $viewModel.llmModelName,
                    agentBaseURL: $viewModel.agentBaseURL,
                    agentDelegationStrategy: $viewModel.agentDelegationStrategy
                )
                // Add transition if desired
                .transition(.scale.combined(with: .opacity))
            }
            // --- End Settings Panel Overlay ---

        } // End ZStack
        .opacity(viewModel.windowOpacity) // Apply overall opacity from ViewModel
        .frame(minWidth: 800, minHeight: 500) // Keep overall window size constraints
        .onAppear {
            // Initial focus logic (ViewModel handles initial selection)
             if viewModel.conversations.isEmpty && !viewModel.showSettings {
                 // Focus input if there are no conversations at all and settings aren't shown
                 DispatchQueue.main.async { isInputFocused = true }
             } else if viewModel.selectedConversationID != nil && !viewModel.showSettings {
                 // Focus if a conversation is selected and settings aren't shown
                 DispatchQueue.main.async { isInputFocused = true }
             }
         }
        // --- Focus Management ---
        .onChange(of: viewModel.showSettings) { showingSettings in
            // If settings are dismissed and a conversation exists, refocus input
            if !showingSettings && viewModel.selectedConversationID != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { // Slight delay
                    isInputFocused = true
                }
            } else if showingSettings {
                // If settings are shown, ensure input is not focused
                isInputFocused = false
            }
        }
        // Refocus when sending completes, if needed and settings aren't open
        .onChange(of: viewModel.isSending) { isNowSending in
            if !isNowSending && !viewModel.showSettings && viewModel.selectedConversationID != nil {
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                     isInputFocused = true
                 }
            }
        }
        // --- End Focus Management ---
    }

    // MARK: - Helper Functions (View-Specific)

    // Scroll helper remains in the View as it uses ScrollViewProxy
    // It now takes `isSending` as an argument to determine the correct ID
    private func scrollToBottom(scrollProxy: ScrollViewProxy, history: [String], isSending: Bool, animated: Bool = true) {
         // ID of the last message or the thinking indicator
         let lastID: AnyHashable
         if isSending {
             lastID = "thinkingIndicator" // Use the ID defined in ChatHistoryView
         } else if let lastIndex = history.indices.last {
             lastID = lastIndex // Use the index of the last message
         } else {
             logger.debug("scrollToBottom called but history is empty or no indicator needed.")
             return // Nothing to scroll to
         }

         logger.trace("Scrolling to ID \(lastID)")
         if animated {
             withAnimation(.easeOut(duration: 0.2)) {
                 scrollProxy.scrollTo(lastID, anchor: .bottom)
             }
         } else {
             // Use DispatchQueue to ensure scrolling happens after potential layout changes
             DispatchQueue.main.async {
                 scrollProxy.scrollTo(lastID, anchor: .bottom)
             }
         }
     }
}