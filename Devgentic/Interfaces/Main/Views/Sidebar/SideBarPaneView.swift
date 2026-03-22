//
//  SideBarPaneView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SideBarPaneView")

enum SidebarTab: CaseIterable, Identifiable {
    case conversations
    case explorer
    case promptLibrary
    case scheduler
    case backendProfiles
    case downloads
    case settings

    var id: Self { self }

    var iconName: String {
        switch self {
        case .conversations: return "message"
        case .promptLibrary: return "square.stack.3d.up.fill"
        case .scheduler: return "clock.badge"
        case .backendProfiles: return "cpu"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gearshape"
        case .explorer: return "folder"
        }
    }

    var title: String {
        switch self {
        case .conversations: return "Chats"
        case .promptLibrary: return "Prompts"
        case .scheduler: return "Scheduler"
        case .backendProfiles: return "Profiles"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        case .explorer: return "Explorer"
        }
    }
}


struct SideBarPaneView: View {
    @Binding var selectedTab: SidebarTab?
    @Binding var sidebarWidth: CGFloat

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Only show a generic header for tabs that don't have their own rich toolbar/search bar.
            // Explorer, Conversations, and Prompts now handle their own top area.
            if let tab = selectedTab, shouldShowGenericHeader(for: tab) {
                 HStack {
                     Text(tab.title)
                         .font(.system(size: 11, weight: .bold))
                         .foregroundColor(theme.primaryText)
                         .textCase(.uppercase)
                         .tracking(0.5)
                     
                     Spacer()
                 }
                 .padding(.horizontal, 16)
                 .padding(.top, 14)
                 .padding(.bottom, 8)
                 
                 Divider()
                     .background(theme.dividerColor)
            }

            VStack {
                switch selectedTab {
                case .explorer:
                    ExplorerSidebarView()
                case .conversations:
                    ConversationSidebarView()
                case .promptLibrary:
                    PromptLibrarySidebarView()
                case .scheduler:
                    TaskSchedulerSidebarView()
                case .backendProfiles:
                    ProfileSidebarListView()
                case .downloads:
                    DownloadSidebarView()
                case .settings:
                    SettingsSidebarListView()
                case .none:
                    Spacer()
                }
            }
            .environmentObject(viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Use clear background to allow the parent container's material/vibrancy to show through
        .background(Color.clear)
        .frame(maxHeight: .infinity)
    }
    
    private func shouldShowGenericHeader(for tab: SidebarTab) -> Bool {
        // All tabs now have their own headers
        return false
    }
}

// MARK: - Placeholder View for Empty/Future Tabs
struct PlaceholderSidebarView: View {
    let icon: String
    let title: String
    let description: String
    
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(theme.surfaceOverlay)
                    .frame(width: 70, height: 70)
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(theme.secondaryText)
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
