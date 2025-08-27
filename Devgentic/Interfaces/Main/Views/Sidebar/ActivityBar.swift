//
//  ActivityBar.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//
//  Refactored on 27/08/25 to remove LLM Integration sidebar.
//  Refactored on 27/08/25 to add Backend Profiles window tab.
//  Refactored on 27/08/25 to remove redundant NewChatTabView.
//  Refactored on 27/08/25 to improve UI to match modern standards.
//  Refactored on 27/08/25 to fix text wrapping and standardize names.
//  Refactored on 28/08/25 to create a compact, icon-only activity bar.
//  Refactored on 28/08/25 to fix incorrect new chat button behavior.
//  Refactored on 28/08/25 to rename New Chat button to Home.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ActivityBar")

struct HomeButton: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Binding var isSidebarVisible: Bool
    @Binding var selectedTab: SidebarTab?

    var body: some View {
        Button {
            viewModel.deselectConversationAndShowWelcome()
            logger.debug("Triggered deselect conversation via Home button.")
            
            if isSidebarVisible {
                isSidebarVisible = false
                logger.debug("Hid sidebar pane via Home button.")
            }
            selectedTab = nil // Deselect any active tab
        } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 22))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .help("Home")
    }
}


struct ActivityBarButton: View {
    let tab: SidebarTab
    @Binding var selectedTab: SidebarTab?
    @Binding var isSidebarVisible: Bool

    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    private var isActive: Bool {
        if tab == .settings || tab == .backendProfiles {
            return false
        }
        return selectedTab == tab && isSidebarVisible
    }

    var body: some View {
        Button {
            handleButtonTap()
        } label: {
            Image(systemName: tab.iconName)
                .font(.system(size: 22))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isActive ? Color.accentColor : .secondary)
        .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(8)
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 20)
                    .offset(x: -4)
            }
        }
        .help(tab.title)
    }

    private func handleButtonTap() {
        switch tab {
        case .settings:
            logger.debug("Settings button tapped. Attempting to open Settings window.")
            openWindow(id: "settings")

            if viewModel.showSettings {
                viewModel.showSettings = false
                logger.debug("Ensured old settings overlay is closed.")
            }
        
        case .backendProfiles:
            logger.debug("Backend Profiles button tapped. Attempting to open window.")
            openWindow(id: "backend-profiles")
            if viewModel.showSettings { viewModel.showSettings = false }


        case .promptLibrary, .conversations, .explorer, .user:
            if selectedTab == tab {
                isSidebarVisible.toggle()
                logger.debug("Toggled sidebar visibility via \(tab.title) button. Visible: \(isSidebarVisible)")
            } else {
                selectedTab = tab
                isSidebarVisible = true
                logger.debug("Selected tab \(tab.title) via button. Sidebar pane forced visible.")
            }
            if viewModel.showSettings {
                viewModel.showSettings = false
                logger.debug("Hid old settings panel because sidebar tab '\(tab.title)' was selected.")
            }
        }
    }
}

struct ActivityBarView: View {
    
    @Binding var selectedTab: SidebarTab?
    @Binding var isSidebarVisible: Bool

    private let topTabs: [SidebarTab] = [.conversations, .explorer, .promptLibrary, .backendProfiles]
    private let bottomTabs: [SidebarTab] = [.settings, .user]


    var body: some View {
        VStack(spacing: 10) {
            HomeButton(isSidebarVisible: $isSidebarVisible, selectedTab: $selectedTab)

            ForEach(topTabs) { tab in
                ActivityBarButton(
                    tab: tab,
                    selectedTab: $selectedTab,
                    isSidebarVisible: $isSidebarVisible
                )
            }

            Spacer()

            ForEach(bottomTabs) { tab in
                ActivityBarButton(
                    tab: tab,
                    selectedTab: $selectedTab,
                    isSidebarVisible: $isSidebarVisible
                )
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
    }
}
