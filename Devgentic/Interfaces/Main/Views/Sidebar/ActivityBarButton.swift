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
    @Binding var selectedTab: SidebarTab?
    @Binding var isSidebarVisible: Bool

    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    private var isActive: Bool {
        if tab == .settings {
            return false
        } else if tab == .promptLibrary {
            return selectedTab == tab && isSidebarVisible
        } else if tab == .integration {
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
            logger.debug("Settings button tapped. Attempting to open Command Centre window.")
            openWindow(id: "command-centre")

            if viewModel.showSettings {
                viewModel.showSettings = false
                logger.debug("Ensured old settings overlay is closed.")
            }

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

        // MARK: - Reverted: .localModels tab now re-activates sidebar pane, not opens new window
        case .integration:
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
