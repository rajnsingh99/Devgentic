//
//  SideBarPaneView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "SideBarPaneView")

/// A sidebar route. `String` raw-value + `Codable` so it can be persisted to
/// `@AppStorage` — previously the selected tab reset to `.conversations` on
/// every launch because it lived in `@State`.
enum SidebarTab: String, CaseIterable, Identifiable, Codable {
    case conversations    = "conversations"
    case explorer         = "explorer"
    case promptLibrary    = "promptLibrary"
    case scheduler        = "scheduler"
    case backendProfiles  = "backendProfiles"
    case downloads        = "downloads"
    case settings         = "settings"

    var id: Self { self }

    var iconName: String {
        switch self {
        case .conversations:   return "message"
        case .promptLibrary:   return "square.stack.3d.up.fill"
        case .scheduler:       return "clock.badge"
        case .backendProfiles: return "cpu"
        case .downloads:       return "arrow.down.circle"
        case .settings:        return "gearshape"
        case .explorer:        return "folder"
        }
    }

    var title: String {
        switch self {
        case .conversations:   return "Chats"
        case .promptLibrary:   return "Prompts"
        case .scheduler:       return "Scheduler"
        case .backendProfiles: return "Profiles"
        case .downloads:       return "Downloads"
        case .settings:        return "Settings"
        case .explorer:        return "Explorer"
        }
    }
}


struct SideBarPaneView: View {
    @Binding var selectedTab: SidebarTab?
    @Binding var sidebarWidth: CGFloat

    @Environment(ThemeManager.self) var themeManager
    @Environment(MainApplicationViewModel.self) var viewModel
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
                    noTabSelectedView
                }
            }
            .environment(viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Use clear background to allow the parent container's material/vibrancy to show through
        .background(Color.clear)
        .frame(maxHeight: .infinity)
    }

    // MARK: - No-Tab Empty State
    /// Shown after Home is tapped (which sets `selectedTab = nil`). Previously
    /// this case fell through to a bare `Spacer()`, leaving the pane blank
    /// while still taking up space — confusing if the user later expected the
    /// activity bar toggle to bring content back.
    private var noTabSelectedView: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "sidebar.left")
                .font(.system(size: 34))
                .foregroundStyle(
                    LinearGradient(
                        colors: [theme.accentColor.opacity(0.55), theme.accentColor.opacity(0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 4) {
                Text("No section selected")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                Text("Pick a tab from the activity bar on the left.")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No sidebar section selected")
    }
}
