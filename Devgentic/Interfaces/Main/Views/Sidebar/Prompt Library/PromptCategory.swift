//
//  PromptCategory.swift
//  Devgentic
//
//  Single source of truth for prompt categories. Replaces the two hardcoded
//  String arrays that used to live in PromptLibrarySidebarView and
//  CreateEditPromptView (which drifted out of sync — "Custom" existed in the
//  form but not in the sidebar filter).
//

import Foundation

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
    var displayName: String { rawValue }

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

/// Filters prompts by authorship. Seeds shipped with the app (`isUserDefined
/// == false`) are system-curated examples users can't edit away; "All" is
/// the default, "User" shows only prompts the user created, "Built-in" shows
/// only the seeds. Persisted via `UserDefaults` alongside the other browse
/// filters so the sidebar restores it across launches.
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

/// UI-level filter scope — adds the "All" pseudo-case used by sidebar chips.
/// Keeping this separate from `PromptCategory` means prompts can never be
/// *assigned* to "All", only filtered by it.
///
/// `RawRepresentable` with a `String` raw lets us persist the user's chosen
/// filter via `UserDefaults` across launches — `"__all__"` for `.all`, the
/// category's rawValue otherwise. Unknown strings fall back to `.all`.
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
