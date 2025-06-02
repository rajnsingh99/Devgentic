//
//  ActivityBarButton.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ActivityBarButton")

struct ActivityBarButton: View {
    let tab: SidebarTab
    @Binding var selectedTab: SidebarTab? // For sidebar pane selection
    @Binding var isSidebarVisible: Bool   // For sidebar pane visibility

    @EnvironmentObject var viewModel: MainApplicationViewModel // For panel toggles
    @Environment(\.openWindow) var openWindow // Environment action to open new windows

    // Computed property to determine if this button should appear "active"
    private var isActive: Bool {
        if tab == .settings {
            return false
        } else if tab == .promptLibrary {
            return viewModel.showPromptLibrary // Assuming prompt library is still an overlay
        } else if tab == .localModels {
            // For localModels, it's active if its content (LocalModelDiscoveryGridView) is visible in the sidebar
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
            if viewModel.showSettings { viewModel.showSettings = false } // Close old overlay if open
            if viewModel.showPromptLibrary { viewModel.showPromptLibrary = false }
            selectedTab = nil

        case .settings:
            logger.debug("Settings button tapped. Attempting to open Command Centre window.")
            openWindow(id: "command-centre")

            if viewModel.showSettings {
                viewModel.showSettings = false
                logger.debug("Ensured old settings overlay is closed.")
            }

        case .promptLibrary:
            viewModel.togglePromptLibrary()
            logger.debug("Toggled prompt library panel via button. Show: \(viewModel.showPromptLibrary)")

        // MARK: - Reverted: .localModels tab now re-activates sidebar pane, not opens new window
        case .localModels:
            if selectedTab == tab {
                isSidebarVisible.toggle()
                logger.debug("Toggled sidebar visibility via \(tab.title) button. Visible: \(isSidebarVisible)")
            } else {
                selectedTab = tab
                isSidebarVisible = true
                logger.debug("Selected tab \(tab.title) via button. Sidebar pane forced visible.")
                if viewModel.showSettings {
                    viewModel.showSettings = false
                    logger.debug("Hid old settings panel because sidebar tab '\(tab.title)' was selected.")
                }
                if viewModel.showPromptLibrary {
                    viewModel.showPromptLibrary = false
                    logger.debug("Hid prompt library panel because sidebar tab '\(tab.title)' was selected.")
                }
            }


        default: // For other tabs that open the sidebar pane
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
                if viewModel.showPromptLibrary {
                    viewModel.showPromptLibrary = false
                    logger.debug("Hid prompt library panel because sidebar tab '\(tab.title)' was selected.")
                }
            }
        }
    }
}
