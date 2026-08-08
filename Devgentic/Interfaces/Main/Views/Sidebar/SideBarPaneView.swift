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
    /// The `@AppStorage` key the selection persists under.
    ///
    /// ⚠️ Named here so the menu command that needs to CHANGE the tab (register A33) and the
    /// container that owns it cannot drift apart over a string literal.
    static let storageKey = "sidebar.selectedTab"

    case conversations    = "conversations"
    case explorer         = "explorer"
    case promptLibrary    = "promptLibrary"
    case scheduler        = "scheduler"
    case backendProfiles  = "backendProfiles"
    case tools            = "tools"
    case downloads        = "downloads"
    case settings         = "settings"

    var id: Self { self }

    var iconName: String {
        switch self {
        case .conversations:   return "message"
        case .promptLibrary:   return "square.stack.3d.up.fill"
        case .scheduler:       return "clock.badge"
        case .backendProfiles: return "cpu"
        case .tools:           return "wrench.and.screwdriver"
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
        case .tools:           return "Tools"
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
            ZStack {
                switch selectedTab {
                case .explorer:
                    ExplorerSidebarView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                case .conversations:
                    ConversationSidebarView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                case .promptLibrary:
                    PromptLibrarySidebarView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                case .scheduler:
                    TaskSchedulerSidebarView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                case .backendProfiles:
                    ProfileSidebarListView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                case .tools:
                    ToolNavigationPane(host: .toolsTab)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                case .downloads:
                    DownloadSidebarView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                case .settings:
                    SettingsSidebarListView()
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                case .none:
                    noTabSelectedView
                        .transition(.opacity)
                }
            }
            .id(selectedTab)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: selectedTab)
            .environment(viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
        .frame(maxHeight: .infinity)
    }

    // MARK: - No-Tab Empty State

    private var noTabSelectedView: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.14), Color.cyan.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .shadow(color: theme.accentColor.opacity(0.2), radius: 10)

                Image(systemName: "sidebar.left")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [theme.accentColor, Color.cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 6) {
                Text("NO SECTION SELECTED")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundColor(theme.primaryText)

                Text("Select a tab from the activity bar to view details.")
                    .font(theme.fontSubheadline)
                    .foregroundColor(theme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No sidebar section selected")
    }
}
