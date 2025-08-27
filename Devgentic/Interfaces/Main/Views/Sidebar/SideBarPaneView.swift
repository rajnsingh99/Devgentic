//
//  SideBarPaneView.swift
//  Devgentic
//
//  Created by Raj Singh.
//
//  Refactored on 27/08/25 to remove LLM Integration sidebar.
//  Refactored on 27/08/25 to add Backend Profiles window tab.
//  Refactored on 27/08/25 to remove redundant NewChatTabView.
//  Refactored on 27/08/25 to fix text wrapping and standardize names.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SideBarPaneView")

enum SidebarTab: CaseIterable, Identifiable {
    case conversations
    case explorer
    case promptLibrary
    case backendProfiles
    case settings
    case user

    var id: Self { self }

    var iconName: String {
        switch self {
        case .conversations:
            return "message"
        case .promptLibrary:
            return "square.stack.3d.up.fill"
        case .backendProfiles:
            return "cpu"
        case .settings:
            return "gearshape"
        case .user:
            return "person.crop.circle"
        case .explorer:
            return "folder"
        }
    }

    var title: String {
        switch self {
        case .conversations:
            return "Chats"
        case .promptLibrary:
            return "Prompts"
        case .backendProfiles:
            return "Profiles"
        case .settings:
            return "Settings"
        case .user:
            return "Account"
        case .explorer:
            return "Explorer"
        }
    }
}


struct SideBarPaneView: View {
    @Binding var selectedTab: SidebarTab?
    @Binding var sidebarWidth: CGFloat

    @EnvironmentObject var themeManager: ThemeManager
    
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    // State for popovers and hover effects
    @State private var isHoveringSettingsButton = false
    @State private var isHoveringAddButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tab = selectedTab {
                if tab != .explorer && tab != .conversations && tab != .promptLibrary && tab != .settings {
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

            
            VStack {
                switch selectedTab {
                case .explorer: ExplorerSidebarView()
                case .conversations: ConversationSidebarView()
                case .promptLibrary: PromptLibrarySidebarView()
                case .settings, .user, .none, .backendProfiles:
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
