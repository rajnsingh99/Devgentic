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
        // For settings, it's no longer about viewModel.showSettings.
        // We might need a different way to track if the Command Centre window is open,
        // or simply rely on the button press action. For now, let's assume it's not "active"
        // in the same way an overlay was. If you want to reflect open state, it's more complex
        // and might involve AppDelegate or observing NSApplication.shared.windows.
        // For simplicity, settings button won't show an "active" state based on window presence.
        if tab == .settings {
            // return false // Or some other logic if you want to track window state
            // Let's keep the old logic for promptLibrary if it's still an overlay
            return false // For now, settings button won't have an active state based on window.
        } else if tab == .promptLibrary {
            return viewModel.showPromptLibrary // Assuming prompt library is still an overlay
        } else {
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
                // Adjust active color logic if needed, especially for settings
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
            // Instead of toggling viewModel.showSettings, open the new window.
            logger.debug("Settings button tapped. Attempting to open Command Centre window.")
            openWindow(id: "command-centre") // Use the ID defined in DevgenticApp.swift

            // If the old settings panel was an overlay, ensure it's hidden.
            if viewModel.showSettings {
                viewModel.showSettings = false
                logger.debug("Ensured old settings overlay is closed.")
            }
            // Optionally, hide the sidebar pane if it's open
            // if isSidebarVisible { isSidebarVisible = false }
            // selectedTab = nil // And clear tab selection
            // Decide if clicking settings should also hide the main app's sidebar pane.
            // For now, it won't, to behave like typical multi-window apps.

        case .promptLibrary:
            viewModel.togglePromptLibrary()
            logger.debug("Toggled prompt library panel via button. Show: \(viewModel.showPromptLibrary)")

        default: // For tabs that open the sidebar pane
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
