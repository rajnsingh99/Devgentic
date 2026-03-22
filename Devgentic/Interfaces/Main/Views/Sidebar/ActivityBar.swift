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
//  Modernized on 17/02/26 with hover glow, press animations, and unified surface.
//  Updated on 21/02/26 to add AppKit window-front checks to prevent duplicate spawning.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ActivityBar")

struct HomeButton: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @EnvironmentObject var router: MainViewRouter
    @Binding var isSidebarVisible: Bool
    @Binding var selectedTab: SidebarTab?

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button {
            // Return router to chat first so the welcome view is visible
            if !router.isShowingChat {
                router.returnToChat()
                logger.debug("Router returned to chat via Home button.")
            }

            viewModel.deselectConversationAndShowWelcome()
            logger.debug("Triggered deselect conversation via Home button.")

            if isSidebarVisible {
                isSidebarVisible = false
                logger.debug("Hid sidebar pane via Home button.")
            }
            selectedTab = nil // Deselect any active tab
        } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 20))
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovering ? theme.surfaceOverlay : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .foregroundColor(theme.secondaryText)
        .help("Home")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}


struct ActivityBarButton: View {
    let tab: SidebarTab
    @Binding var selectedTab: SidebarTab?
    @Binding var isSidebarVisible: Bool

    @EnvironmentObject var viewModel: MainApplicationViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false

    private var isActive: Bool {
        return selectedTab == tab && isSidebarVisible
    }

    /// Shows a badge dot on the downloads tab when downloads are active.
    private var showBadge: Bool {
        tab == .downloads && downloadManager.hasActiveDownloads
    }

    var body: some View {
        Button {
            handleButtonTap()
        } label: {
            Image(systemName: tab.iconName)
                .font(.system(size: 18))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? theme.accentColor.opacity(0.15) :
                      isHovering ? theme.surfaceOverlay : Color.clear)
        )
        .shadow(
            color: isActive ? theme.accentColor.opacity(0.2) :
                   isHovering ? theme.accentColor.opacity(0.08) : Color.clear,
            radius: isActive ? 6 : 4, x: 0, y: 0
        )
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(theme.accentColor)
                    .frame(width: 3, height: 24)
                    .offset(x: -5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if showBadge {
                Circle()
                    .fill(theme.accentColor)
                    .frame(width: 8, height: 8)
                    .offset(x: 2, y: -2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isActive)
        .animation(.easeInOut(duration: 0.3), value: showBadge)
        .help(tab.title)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func handleButtonTap() {
        if selectedTab == tab {
            isSidebarVisible.toggle()
            logger.debug("Toggled sidebar visibility via \(tab.title) button. Visible: \(isSidebarVisible)")
        } else {
            selectedTab = tab
            isSidebarVisible = true
            logger.debug("Selected tab \(tab.title) via button. Sidebar pane forced visible.")
        }
    }
}

struct ActivityBarView: View {

    @Binding var selectedTab: SidebarTab?
    @Binding var isSidebarVisible: Bool
    @Environment(\.appTheme) private var theme

    private let topTabs: [SidebarTab] = [.conversations, .explorer, .promptLibrary, .scheduler, .backendProfiles, .downloads]
    private let bottomTabs: [SidebarTab] = [.settings]


    var body: some View {
        VStack(spacing: 6) {
            HomeButton(isSidebarVisible: $isSidebarVisible, selectedTab: $selectedTab)

            // Visual separator between Home and tab buttons
            Capsule()
                .fill(theme.dividerColor)
                .frame(width: 24, height: 1)
                .padding(.vertical, 2)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
