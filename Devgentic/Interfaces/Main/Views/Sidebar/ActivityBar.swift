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
                .strokeBorder(color.opacity(0.6), lineWidth: 1.5)
                .frame(width: 13, height: 13)
                .scaleEffect(isPulsing ? 1.6 : 0.8)
                .opacity(isPulsing ? 0.0 : 0.9)

            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 3)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
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
            selectedTab = nil
        } label: {
            Image(systemName: "house.fill")
                .font(.system(.title3, weight: .semibold))
                .foregroundColor(isHovering ? theme.primaryText : theme.secondaryText)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHovering ? theme.surfaceOverlayStrong : theme.surfaceOverlay.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isHovering ? theme.secondaryText.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .shadow(color: isHovering ? Color.black.opacity(0.15) : .clear, radius: 4, y: 2)
                .scaleEffect(isHovering ? 1.06 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Home")
        .accessibilityLabel("Home")
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
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
                .font(.system(.title3, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? theme.primaryText : (isHovering ? theme.primaryText : theme.secondaryText))
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive
                              ? theme.surfaceOverlayStrong
                              : (isHovering ? theme.surfaceOverlay : theme.surfaceOverlay.opacity(0.3)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isHovering && !isActive ? theme.secondaryText.opacity(0.2) : Color.clear, lineWidth: 1)
                )
                .shadow(color: isHoverHoverActiveShadow, radius: 4, y: 1)
                .scaleEffect(isHovering ? 1.05 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(theme.accentColor)
                    .frame(width: 3, height: 18)
                    .offset(x: -4)
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
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isActive)
        .animation(.easeInOut(duration: 0.3), value: showBadge)
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }

    private var isHoverHoverActiveShadow: Color {
        isHovering ? Color.black.opacity(0.12) : .clear
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

    private let topTabs: [SidebarTab] = [.conversations, .explorer, .promptLibrary, .scheduler, .backendProfiles, .tools, .downloads]
    private let bottomTabs: [SidebarTab] = [.settings]

    var body: some View {
        VStack(spacing: 7) {
            HomeButton(isSidebarVisible: $isSidebarVisible, selectedTab: $selectedTab)

            // Visual separator between Home and tab buttons
            Capsule()
                .fill(theme.dividerColor.opacity(0.6))
                .frame(width: 22, height: 1)
                .padding(.vertical, 3)

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
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
