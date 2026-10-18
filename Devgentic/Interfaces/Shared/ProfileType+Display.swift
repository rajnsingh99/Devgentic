// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileType+Display.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// SwiftUI presentation of `ProfileType`, including the single source of the profile-type identity color.
extension ProfileType {
    /// Identity color used for profile-type dots, node accents, and pickers.
    var displayColor: Color {
        switch self {
        case .bot:      return .blue
        case .agent:    return .green
        case .workflow: return .purple
        case .imageGen: return .orange
        case .code:     return .cyan
        }
    }
}

// MARK: - ProfileType Localization
// Presentation-only properties live here because `ProfileType` is declared in a Foundation-only model file
// whose values are Codable and must not import SwiftUI.
extension ProfileType {
    // Why: `Text(x.rawValue)` binds to the non-localizing `StringProtocol` overload and is invisible to the String Catalog.
    /// User-facing name, separate from `rawValue`, which is for persistence and logging only.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .bot:      return "Bot"
        case .agent:    return "Agent"
        case .workflow: return "Workflow"
        case .imageGen: return "Image Generator"
        case .code:     return "Code"
        }
    }

    // Why: the literals must stay character-identical to `localizedTitle`'s so both bind to the same String Catalog entry.
    /// `String` twin of `localizedTitle`, for call sites that need a `String` (`String(localized:)`, `.accessibilityLabel`).
    /// Never `rawValue`: that is a persisted token reaching SwiftData and JSON.
    var localizedTitleString: String {
        switch self {
        case .bot:      return String(localized: "Bot")
        case .agent:    return String(localized: "Agent")
        case .workflow: return String(localized: "Workflow")
        case .imageGen: return String(localized: "Image Generator")
        case .code:     return String(localized: "Code")
        }
    }
}

