// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PromptCategory.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftUI   // `LocalizedStringKey` for the `localizedTitle` members below

/// Concrete category assignable to a prompt.
enum PromptCategory: String, CaseIterable, Identifiable, Codable, Hashable {
    case general      = "General"
    case development  = "Development"
    case productivity = "Productivity"
    case creativity   = "Creativity"
    case writing      = "Writing"
    case education    = "Education"
    case research     = "Research"
    case marketing    = "Marketing"
    case custom       = "Custom"

    var id: String { rawValue }
    // Why: a prompt's category is stored, so the raw strings must not change.
    /// The raw value verbatim, for persistence, logging and `Codable`; use `localizedTitle` for display.
    var displayName: String { rawValue }

    /// Display form. `Text(displayName)` took the non-localizing `Text` overload, so every
    /// category chip and picker row shipped untranslated (audit C2).
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .general:      return "General"
        case .development:  return "Development"
        case .productivity: return "Productivity"
        case .creativity:   return "Creativity"
        case .writing:      return "Writing"
        case .education:    return "Education"
        case .research:     return "Research"
        case .marketing:    return "Marketing"
        case .custom:       return "Custom"
        }
    }

    var systemImage: String {
        switch self {
        case .general:      return "square.stack.3d.up"
        case .development:  return "chevron.left.forwardslash.chevron.right"
        case .productivity: return "checkmark.seal"
        case .creativity:   return "sparkles"
        case .writing:      return "pencil.line"
        case .education:    return "book"
        case .research:     return "magnifyingglass"
        case .marketing:    return "megaphone"
        case .custom:       return "tag"
        }
    }

    /// Tolerant lookup: unknown strings (from imported prompts or legacy data)
    /// map to `.custom` rather than crashing.
    init(tolerant raw: String) {
        self = PromptCategory(rawValue: raw) ?? .custom
    }
}

/// Filters prompts by authorship: `All` (default), `User` (prompts the user created) or `Built-in` (the shipped seeds).
/// Persisted via `UserDefaults` alongside the other browse filters.
enum PromptSourceFilter: String, CaseIterable, Identifiable {
    case all     = "All"
    case user    = "My Prompts"
    case builtIn = "Built-in"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all:     return "tray.full"
        case .user:    return "person.crop.circle"
        case .builtIn: return "sparkles"
        }
    }

    /// Returns `true` if this filter would include the given prompt.
    func matches(_ prompt: DevPrompt) -> Bool {
        switch self {
        case .all:     return true
        case .user:    return prompt.isUserDefined
        case .builtIn: return !prompt.isUserDefined
        }
    }
}

/// UI-level filter scope: adds the `All` pseudo-case used by sidebar chips, so prompts can never be assigned to All.
/// Persisted as a String (`__all__` for `.all`, else the category's rawValue); unknown strings fall back to `.all`.
enum PromptCategoryFilter: Hashable, Identifiable, RawRepresentable {
    case all
    case category(PromptCategory)

    init?(rawValue: String) {
        if rawValue == "__all__" {
            self = .all
        } else if let cat = PromptCategory(rawValue: rawValue) {
            self = .category(cat)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .all:              return "__all__"
        case .category(let c):  return c.rawValue
        }
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:              return "All"
        case .category(let c):  return c.displayName
        }
    }

    /// Display form — see `PromptCategory.localizedTitle`.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .all:              return "All"
        case .category(let c):  return c.localizedTitle
        }
    }

    var systemImage: String? {
        switch self {
        case .all:              return "tray.full"
        case .category(let c):  return c.systemImage
        }
    }

    static let allCases: [PromptCategoryFilter] =
        [.all] + PromptCategory.allCases.map(PromptCategoryFilter.category)

    /// Returns `true` if this filter would include the given prompt.
    /// Case-insensitive so legacy/user-typed category strings still match.
    func matches(_ prompt: DevPrompt) -> Bool {
        switch self {
        case .all:
            return true
        case .category(let target):
            return prompt.category.caseInsensitiveCompare(target.rawValue) == .orderedSame
        }
    }
}
