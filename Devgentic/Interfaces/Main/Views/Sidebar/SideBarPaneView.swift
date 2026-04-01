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
}

