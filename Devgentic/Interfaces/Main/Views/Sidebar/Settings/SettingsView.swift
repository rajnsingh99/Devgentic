//
//  SettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI

/// Enum to represent the different settings categories for easier navigation and management.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case coreIntelligence = "Core Intelligence"
    case account = "Account"
    case notifications = "Notifications"
    case theme = "Theme"
    case chatOps = "ChatOps"
    case about = "About"

    var id: String { self.rawValue }

    /// Returns the appropriate icon for each settings category.
    var iconName: String {
        switch self {
        case .general:
            return "gear"
        case .coreIntelligence:
            return "cpu.fill"
        case .account:
            return "person.crop.circle"
        case .notifications:
            return "bell.badge"
        case .theme:
            return "paintbrush"
        case .chatOps:
            return "paperplane.fill"
        case .about:
            return "info.circle"
        }
    }

    /// Brief subtitle shown below the category name in the sidebar.
    var subtitle: String {
        switch self {
        case .general: return "Appearance and behavior"
        case .coreIntelligence: return "On-device intelligence"
        case .account: return "API keys and providers"
        case .notifications: return "Alerts and sounds"
        case .theme: return "Colors and typography"
        case .chatOps: return "Remote Telegram control"
        case .about: return "Version and licenses"
        }
    }

    /// Provides the destination view for each category.
    @ViewBuilder
    var destination: some View {
        switch self {
        case .general:
            GeneralSettingsView()
        case .coreIntelligence:
            CoreIntelligenceSettingsView()
        case .account:
            AccountSettingsView()
        case .notifications:
            NotificationSettingsView()
        case .theme:
            ThemeSettingsView()
        case .chatOps:
            ChatOpsSettingsView()
        case .about:
            VStack(spacing: 16) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)
                Text("Devgentic")
                    .font(.largeTitle.weight(.bold))
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// A view that provides a dedicated settings window, replacing the old command-centre.
struct SettingsView: View {
    @State private var selectedCategory: SettingsCategory? = .general
    
    @EnvironmentObject var mainApplicationViewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                NavigationLink(value: category) {
                    Label {
                        Text(category.rawValue)
                            .font(.system(size: 14, weight: .medium))
                    } icon: {
                        Image(systemName: category.iconName)
                            .foregroundStyle(theme.accentColor)
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .scrollContentBackground(.hidden)
            .background(theme.secondaryBackground)
        } detail: {
            ZStack {
                theme.primaryBackground
                    .ignoresSafeArea()
                
                if let category = selectedCategory {
                    category.destination
                        .environmentObject(mainApplicationViewModel)
                } else {
                    Text("Select a category")
                        .font(.title2)
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
        .frame(minWidth: 750, minHeight: 600)
        .tint(theme.accentColor)
        .preferredColorScheme(theme.id == "one_light" ? .light : (theme.id == "dracula" || theme.id == "one_dark" ? .dark : nil))
        .configureWindow(collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary])
    }
}
