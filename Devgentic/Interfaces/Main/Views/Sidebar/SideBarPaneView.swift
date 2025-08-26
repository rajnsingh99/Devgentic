//
//  SideBarPaneView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SideBarPaneView")

struct SideBarPaneView: View {
    @Binding var selectedTab: SidebarTab?
    @Binding var sidebarWidth: CGFloat

    @EnvironmentObject var themeManager: ThemeManager
    
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    // State for popovers and hover effects
    @State private var showingAddIntegrationPopover = false
    @State private var isHoveringSettingsButton = false
    @State private var isHoveringAddButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Unified Header ---
            if let tab = selectedTab {
                // Specific, unified header for LLM Integrations
                if tab == .integration {
                    HStack {
                        Text(tab.title) // Displays "LLM Integrations"
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(themeManager.currentTheme.primaryText)
                        
                        Spacer()
                        
                        // Add Button with Popover and Hover Effect
                        Button {
                            showingAddIntegrationPopover = true
                        } label: {
                            Image(systemName: "plus.circle") // Better icon
                                .padding(4)
                                .background(isHoveringAddButton ? Color.secondary.opacity(0.2) : Color.clear)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringAddButton = $0 }
                        .help("Add New LLM Integration")
                        .popover(isPresented: $showingAddIntegrationPopover, arrowEdge: .bottom) {
                            AddLLMIntegrationView()
                                 .environmentObject(viewModel.llmIntegrationStore)
                        }

                        // Settings Button with Hover Effect
                        Button {
                            openWindow(id: "llm-integrations")
                        } label: {
                            Image(systemName: "gearshape.fill") // Better icon
                                .padding(4)
                                .background(isHoveringSettingsButton ? Color.secondary.opacity(0.2) : Color.clear)
                                .cornerRadius(5)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveringSettingsButton = $0 }
                        .help("Manage Backend Profiles & Settings")
                    }
                    .padding(.horizontal).padding(.top, 12).padding(.bottom, 8)
                    
                    Divider()
                        .background(themeManager.currentTheme.dividerColor)
                }
                // Header for other tabs
                else if tab != .explorer && tab != .conversations && tab != .promptLibrary && tab != .settings {
                     HStack {
                         Text(tab.title)
                             .font(.title3)
                             .fontWeight(.semibold)
                             .foregroundColor(themeManager.currentTheme.primaryText)
                         
                         Spacer()
                     }
                     .padding(.horizontal).padding(.top, 12).padding(.bottom, 8)
                     
                     Divider()
                         .background(themeManager.currentTheme.dividerColor)
                }
            }

            // --- Main Content ---
            VStack {
                switch selectedTab {
                case .newChat: NewChatTabView()
                case .explorer: ExplorerSidebarView()
                case .conversations: ConversationSidebarView()
                case .integration: LLMIntegrationsSidebarView(sidebarWidth: $sidebarWidth)
                case .promptLibrary: PromptLibrarySidebarView()
                case .settings, .user, .none:
                    Spacer()
                    Text(selectedTab?.title ?? "Nothing Selected")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .environmentObject(viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.underPageBackgroundColor))
        .frame(maxHeight: .infinity)
    }
}
