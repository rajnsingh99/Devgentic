// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SettingsView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

// Why: the switches over this enum are exhaustive with no `default:`; that is the only thing
// forcing a new case to be handled everywhere.
/// The different settings categories, for navigation and management.
/// Model storage and the HuggingFace token live in General, as does the notifications section at its top.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case theme = "Theme"
    case coreIntelligence = "Core Intelligence"
    case quickAccess = "Quick Access"
    case webSearch = "Web Search"
    case chatOps = "ChatOps"
    case orb = "Orb"
    case mlxModelStore = "MLX Model Store"
    case downloads = "Downloads"
    case about = "About"

    var id: String { self.rawValue }

    // Why: `Text(x.rawValue)` binds to the non-localizing `StringProtocol` overload, so the label is
    // invisible to the String Catalog.
    /// User-facing name, separate from `rawValue`, which is for `id`/persistence and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .general:          return "General"
        case .theme:            return "Theme"
        case .coreIntelligence: return "Core Intelligence"
        case .quickAccess:      return "Quick Access"
        case .webSearch:        return "Web Search"
        case .chatOps:          return "Chat Ops"
        case .orb:              return "Orb (Experimental)"
        case .mlxModelStore:    return "MLX Model Store"
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
        case .webSearch:
            return "globe"
        case .chatOps:
            return "paperplane.fill"
        case .orb:
            return "atom"
        case .mlxModelStore:
            return "shippingbox"
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
        case .webSearch: return String(localized: "Search provider for agents")
        case .chatOps: return String(localized: "Remote Telegram control")
        case .orb: return String(localized: "Voice assistant and listening")
        case .mlxModelStore: return String(localized: "Browse Apple Silicon models")
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
        case .webSearch:
            WebSearchSettingsView()
        case .chatOps:
            ChatOpsSettingsView()
        case .orb:
            OrbSettingsView()
        case .mlxModelStore:
            MLXModelStoreContainerView(filterForTools: false, profileID: nil)
        case .downloads:
            DownloadManagerContainerView(isEmbeddedInSettings: true)
        case .about:
            AboutSettingsView()
        }
    }
}

