// Views/Sidebar/ActivityBarButton.swift
import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ActivityBarButton")

struct ActivityBarButton: View {
    let tab: SidebarTab
    @Binding var selectedTab: SidebarTab? // For sidebar pane selection
    @Binding var isSidebarVisible: Bool   // For sidebar pane visibility

    @EnvironmentObject var viewModel: MainApplicationViewModel // For panel toggles

    // Computed property to determine if this button should appear "active"
    // This is true if its the selected tab for a pane, OR if its corresponding panel is shown
    private var isActive: Bool {
        if tab == .settings {
            return viewModel.showSettings
        } else if tab == .promptLibrary {
            return viewModel.showPromptLibrary
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
                .foregroundColor(isActive ? Color.accentColor : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .padding(.vertical, 5)
    }

    private func handleButtonTap() {
        switch tab {
        case .newChat:
            // Clears selected conversation and hides sidebar pane
            if viewModel.selectedConversationID != nil {
                 viewModel.selectedConversationID = nil
                 logger.debug("Cleared selected conversation ID via New Chat button.")
             }
             if isSidebarVisible {
                  isSidebarVisible = false // Hide the VSCodifiedSidebar's pane
                  logger.debug("Hid sidebar pane via New Chat button.")
             }
            // Ensure other panels are closed
            if viewModel.showSettings { viewModel.showSettings = false }
            if viewModel.showPromptLibrary { viewModel.showPromptLibrary = false }
            selectedTab = nil // Clear pane selection

        case .settings:
            // Toggles the settings panel overlay
            viewModel.toggleSettings()
            logger.debug("Toggled settings panel via Settings button. Show: \(viewModel.showSettings)")
            // Do not change selectedTab for sidebar pane, settings is a panel

        // MARK: - Handling for Prompt Library Button
        case .promptLibrary:
            // Toggles the prompt library panel overlay
            viewModel.togglePromptLibrary()
            logger.debug("Toggled prompt library panel via button. Show: \(viewModel.showPromptLibrary)")
            // Do not change selectedTab for sidebar pane, prompt library is a panel

        default: // For tabs that open the sidebar pane (.conversations, .localModels, .agents, .user)
            if selectedTab == tab {
                // If clicking the already selected tab, toggle the sidebar pane's visibility
                isSidebarVisible.toggle()
                logger.debug("Toggled sidebar visibility via \(tab.title) button. Visible: \(isSidebarVisible)")
            } else {
                // If clicking a different tab, select it and ensure the sidebar pane is visible
                selectedTab = tab
                isSidebarVisible = true
                logger.debug("Selected tab \(tab.title) via button. Sidebar pane forced visible.")

                // Ensure overlay panels are hidden if a main sidebar pane tab is selected
                if viewModel.showSettings {
                    viewModel.showSettings = false
                    logger.debug("Hid settings panel because sidebar tab '\(tab.title)' was selected.")
                }
                if viewModel.showPromptLibrary {
                    viewModel.showPromptLibrary = false
                    logger.debug("Hid prompt library panel because sidebar tab '\(tab.title)' was selected.")
                }
            }
        }
    }
}
