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
    case quickAccess = "Quick Access"
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
        case .quickAccess:
            return "bolt.circle"
        case .about:
            return "info.circle"
        }
    }

    /// Brief subtitle shown below the category name in the sidebar.
    var subtitle: String {
        switch self {
        case .general: return String(localized: "Appearance and behavior")
        case .coreIntelligence: return String(localized: "On-device intelligence")
        case .account: return String(localized: "API keys and providers")
        case .notifications: return String(localized: "Alerts and sounds")
        case .theme: return String(localized: "Colors and typography")
        case .chatOps: return String(localized: "Remote Telegram control")
        case .quickAccess: return String(localized: "Global shortcut and panel")
        case .about: return String(localized: "Version and licenses")
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
        case .quickAccess:
            QuickAccessSettingsView()
        case .about:
            VStack(spacing: 16) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 48)) // Fixed size: intentional (icon)
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
    
    @Environment(MainApplicationViewModel.self) var mainApplicationViewModel
    @Environment(\.appTheme) private var theme

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                NavigationLink(value: category) {
                    Label {
                        Text(category.rawValue)
                            .font(theme.fontBody.weight(.medium))
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
                
                // Ambient Aura Glows (Provides texture for Liquid Glass refraction)
                if theme.id != "one_light" {
                    GeometryReader { geo in
                        ZStack {
                            Circle()
                                .fill(theme.accentColor.opacity(0.04))
                                .frame(width: geo.size.width * 0.45, height: geo.size.width * 0.45)
                                .blur(radius: 120)
                                .offset(x: -geo.size.width * 0.15, y: -geo.size.height * 0.1)
                            
                            Circle()
                                .fill(Color.orange.opacity(0.025))
                                .frame(width: geo.size.width * 0.4, height: geo.size.width * 0.4)
                                .blur(radius: 100)
                                .offset(x: geo.size.width * 0.35, y: geo.size.height * 0.25)
                        }
                    }
                }
                
                if let category = selectedCategory {
                    category.destination
                        .environment(mainApplicationViewModel)
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
