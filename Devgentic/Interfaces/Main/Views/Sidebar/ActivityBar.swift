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

private let logger = DGLogger(category: "ActivityBar")

struct PulsingBadgeView: View {
    let color: Color
    @State private var isPulsing = false
    
    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(color.opacity(0.5), lineWidth: 1.5)
                .frame(width: 12, height: 12)
                .scaleEffect(isPulsing ? 1.5 : 0.8)
                .opacity(isPulsing ? 0.0 : 0.8)
            
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

struct HomeButton: View {
    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(MainViewRouter.self) var router
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
            logger.debug("Home button: deselected conversation (mode: \(viewModel.interfaceMode.rawValue)).")

            if isSidebarVisible {
                isSidebarVisible = false
                logger.debug("Hid sidebar pane via Home button.")
            }
            selectedTab = nil // Deselect any active tab
        } label: {
            Image(systemName: "house.fill")
                .font(.system(.title3))
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovering ? theme.surfaceOverlay : Color.clear)
                )
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
        .foregroundColor(theme.secondaryText)
        .help("Home")
        .accessibilityLabel("Home")
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
                isHovering = hovering
            }
        }
    }
}


struct ActivityBarButton: View {
    let tab: SidebarTab
    @Binding var selectedTab: SidebarTab?
    @Binding var isSidebarVisible: Bool

    @Environment(MainApplicationViewModel.self) var viewModel
    var downloadManager = DownloadManager.shared
    @Environment(\.appTheme) private var theme

    @State private var isHovering = false

    private var isActive: Bool {
        return selectedTab == tab && isSidebarVisible
    }

    /// Shows a badge dot on a tab to signal attention-worthy state:
    /// active downloads, or a prompt-library load error. Rendered as a
    /// small accent-color dot in the top-right (see `.overlay` below).
    private var showBadge: Bool {
        switch tab {
        case .downloads:
            return downloadManager.hasActiveDownloads
        case .promptLibrary:
            return PromptService.shared.loadState.isError
        default:
            return false
        }
    }

    /// Tint for the badge — errors use `errorColor`, activity uses `accentColor`.
    /// Keeps the dot visually meaningful at a glance.
    private var badgeColor: Color {
        switch tab {
        case .promptLibrary where PromptService.shared.loadState.isError:
            return theme.errorColor
        default:
            return theme.accentColor
        }
    }

    var body: some View {
        Button {
            handleButtonTap()
        } label: {
            Image(systemName: tab.iconName)
                .font(.system(.title3))
                .frame(width: 38, height: 38)
                .scaleEffect(isHovering ? 1.08 : 1.0)
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
                PulsingBadgeView(color: badgeColor)
                    .offset(x: 4, y: -4)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isActive)
        .animation(.easeInOut(duration: 0.3), value: showBadge)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) {
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
