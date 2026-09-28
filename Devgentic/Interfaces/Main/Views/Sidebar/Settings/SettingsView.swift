// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    case theme = "Theme"
    case coreIntelligence = "Core Intelligence"
    case quickAccess = "Quick Access"
    case chatOps = "ChatOps"
    case orb = "Orb"
    case downloads = "Downloads"
    case about = "About"

    var id: String { self.rawValue }

    /// User-facing name. ⚠️ Separate from `rawValue` on purpose: `Text(x.rawValue)` binds to
    /// the non-localizing `StringProtocol` overload, so every rawValue-sourced label was
    /// invisible to the String Catalog extractor and would have shipped untranslated inside
    /// otherwise-translated chrome. `rawValue` stays for `id`/persistence and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .general:          return "General"
        case .theme:            return "Theme"
        case .coreIntelligence: return "Core Intelligence"
        case .quickAccess:      return "Quick Access"
        case .chatOps:          return "Chat Ops"
        case .orb:              return "Orb (Experimental)"
        case .downloads:        return "Downloads"
        case .about:            return "About"
        }
    }

    /// Returns the appropriate icon for each settings category.
    var iconName: String {
        switch self {
        case .general:
            return "gear"
        case .theme:
            return "paintbrush"
        case .coreIntelligence:
            return "cpu.fill"
        case .quickAccess:
            return "bolt.circle"
        case .chatOps:
            return "paperplane.fill"
        case .orb:
            return "atom"
        case .downloads:
            return "arrow.down.circle"
        case .about:
            return "info.circle"
        }
    }

    /// Brief subtitle shown below the category name in the sidebar.
    var subtitle: String {
        switch self {
        case .general: return String(localized: "Speech, notifications, and storage")
        case .theme: return String(localized: "Appearance and Typography")
        case .coreIntelligence: return String(localized: "On-device intelligence")
        case .quickAccess: return String(localized: "Global shortcut and panel")
        case .chatOps: return String(localized: "Remote Telegram control")
        case .orb: return String(localized: "Voice assistant and listening")
        case .downloads: return String(localized: "Model and asset downloads")
        case .about: return String(localized: "Version and licenses")
        }
    }

    /// Provides the destination view for each category.
    @ViewBuilder
    var destination: some View {
        switch self {
        case .general:
            GeneralSettingsView()
        case .theme:
            ThemeSettingsView()
        case .coreIntelligence:
            CoreIntelligenceSettingsView()
        case .quickAccess:
            QuickAccessSettingsView()
        case .chatOps:
            ChatOpsSettingsView()
        case .orb:
            OrbSettingsView()
        case .downloads:
            DownloadManagerContainerView(isEmbeddedInSettings: true)
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

