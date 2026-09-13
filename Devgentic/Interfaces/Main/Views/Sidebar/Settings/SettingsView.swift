// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI

/// Enum to represent the different settings categories for easier navigation and management.
///
/// ⚠️ TWO CASES WERE REMOVED AND NEITHER REMOVAL WOULD HAVE BEEN CAUGHT BY ANYTHING. There is no
/// test over `allCases`, no persisted rawValue and no deep link, so dropping a case is a silent UX
/// change rather than a build error — the pane simply stops being reachable. The four switches
/// below are exhaustive with no `default:`, which is the only thing that forces a new case to be
/// handled everywhere; keep them that way.
///
/// - `.account` / `.models` were merged into `.general`: model storage and the HuggingFace token
///   now live in GeneralSettingsView directly after the Observability section.
/// - `.notifications` is gone as a category; its content is now a section at the top of General.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case coreIntelligence = "Core Intelligence"
    case theme = "Theme"
    case chatOps = "ChatOps"
    case quickAccess = "Quick Access"
    case jarvis = "Jarvis"
    case about = "About"

    var id: String { self.rawValue }

    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` stays for `id`/persistence and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .general:          return "General"
        case .coreIntelligence: return "Core Intelligence"
        case .theme:            return "Theme"
        case .chatOps:          return "ChatOps"
        case .quickAccess:      return "Quick Access"
        case .jarvis:           return "Jarvis"
        case .about:            return "About"
        }
    }

    /// Returns the appropriate icon for each settings category.
    var iconName: String {
        switch self {
        case .general:
            return "gear"
        case .coreIntelligence:
            return "cpu.fill"
        case .theme:
            return "paintbrush"
        case .chatOps:
            return "paperplane.fill"
        case .quickAccess:
            return "bolt.circle"
        case .jarvis:
            return "atom"
        case .about:
            return "info.circle"
        }
    }

    /// Brief subtitle shown below the category name in the sidebar.
    var subtitle: String {
        switch self {
        case .general: return String(localized: "Speech, notifications, and storage")
        case .coreIntelligence: return String(localized: "On-device intelligence")
        case .theme: return String(localized: "Appearance and Typography")
        case .chatOps: return String(localized: "Remote Telegram control")
        case .quickAccess: return String(localized: "Global shortcut and panel")
        case .jarvis: return String(localized: "Voice assistant and listening")
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
        case .theme:
            ThemeSettingsView()
        case .chatOps:
            ChatOpsSettingsView()
        case .quickAccess:
            QuickAccessSettingsView()
        case .jarvis:
            JarvisSettingsView()
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
                        Text(category.localizedTitle)
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
                if theme.colorScheme != .light {
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
        .preferredColorScheme(theme.colorScheme)
        .configureWindow(collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary])
    }
}
