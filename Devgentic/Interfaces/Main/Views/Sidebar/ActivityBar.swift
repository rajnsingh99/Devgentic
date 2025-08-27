//
//  ActivityBar.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//
//  Refactored on 27/08/25 to remove LLM Integration sidebar.
//  Refactored on 27/08/25 to add Backend Profiles window tab.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ActivityBar")

struct ActivityBarButton: View {
    let tab: SidebarTab
    @Binding var selectedTab: SidebarTab?
    @Binding var isSidebarVisible: Bool

    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    private var isActive: Bool {
        if tab == .settings || tab == .backendProfiles {
            return false
        } else if tab == .promptLibrary {
            return selectedTab == tab && isSidebarVisible
        }
        else {
            return selectedTab == tab && isSidebarVisible
        }
    }

    var body: some View {
        Button {
            handleButtonTap()
        } label: {
            Image(systemName: tab.iconName)
                .font(.title2)
                .frame(width: 40, height: 40)
                .foregroundColor(isActive || (tab == .settings && selectedTab == .settings && isSidebarVisible) ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .padding(.vertical, 5)
    }

    private func handleButtonTap() {
        switch tab {
        case .newChat:
            if viewModel.selectedConversationID != nil {
                 viewModel.selectedConversationID = nil
                 logger.debug("Cleared selected conversation ID via New Chat button.")
             }
             if isSidebarVisible {
                  isSidebarVisible = false
                  logger.debug("Hid sidebar pane via New Chat button.")
             }
            if viewModel.showSettings { viewModel.showSettings = false }
            selectedTab = nil

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


        case .promptLibrary:
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

        default:
            if selectedTab == tab {
                isSidebarVisible.toggle()
                logger.debug("Toggled sidebar visibility via \(tab.title) button. Visible: \(isSidebarVisible)")
            } else {
                selectedTab = tab
                isSidebarVisible = true
                logger.debug("Selected tab \(tab.title) via button. Sidebar pane forced visible.")
                if viewModel.showSettings { // Close old overlay if open
                    viewModel.showSettings = false
                    logger.debug("Hid old settings panel because sidebar tab '\(tab.title)' was selected.")
                }
            }
        }
    }
}

struct ActivityBarView: View {
    
    @Binding var selectedTab: SidebarTab?
    @Binding var isSidebarVisible: Bool

    private let topTabs: [SidebarTab] = [.newChat, .conversations, .explorer, .promptLibrary, .backendProfiles]
    private let bottomTabs: [SidebarTab] = [.settings, .user]


    var body: some View {
        VStack(spacing: 0) {
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
        .frame(width: 50)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        .frame(maxHeight: .infinity)
    }
}
